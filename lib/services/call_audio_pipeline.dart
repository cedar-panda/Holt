import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;
import '../memory/database.dart';
import 'settings_manager.dart';
import 'tts_service.dart';

/// ═══════════════════════════════════════════════════════════
///  通話音頻管線 — 句子級 TTS 流水線 + SoLoud 播放（真實振幅）
///
///  流程：LLM 流式吐字 → pushText() 切句 → 每句並行 HTTP TTS
///        → 按序排隊播放（播第 1 句時第 2 句在後台合成）
///
///  延遲從「全文 + 整段合成」降到「首句 + 首句合成」。
///  v3 不支持 WebSocket 流式輸入，但一句一句發 HTTP 沒有限制。
/// ═══════════════════════════════════════════════════════════

/// SoLoud 全局初始化（通話路徑專用，聊天內點播仍走 audioplayers）
class CallAudio {
  // 用緩存 Future 而非 bool：併發調用共享同一次 init，不會雙重初始化；
  // init 失敗時清掉緩存，下次調用可重試而不是永遠卡在失敗狀態。
  static Future<void>? _initFuture;

  static Future<void> ensureInit() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _doInit();
    _initFuture = future;
    return future;
  }

  static Future<void> _doInit() async {
    try {
      await SoLoud.instance.init();
      SoLoud.instance.setVisualizationEnabled(true);
      SoLoud.instance.setFftSmoothing(0.85);
    } catch (_) {
      _initFuture = null; // 允許重試
      rethrow;
    }
  }

  static Future<void> deinit() async {
    if (_initFuture == null) return;
    _initFuture = null;
    SoLoud.instance.deinit();
  }
}

/// 播放中音頻的實時振幅（0.0-1.0），供聲波動畫使用
class CallAmplitude {
  AudioData? _audioData;
  Timer? _timer;

  /// 平滑後的振幅
  final ValueNotifier<double> level = ValueNotifier(0.0);

  /// _playBytes 播放期間為 true（句間等待為 false）。
  /// 用來區分「正在播卻讀不到波形」和「本來就沒在播」。
  bool playing = false;

  // AGC：跟蹤近期峰值做歸一化。語音 RMS 通常只有 0.05~0.2，
  // 固定增益畫出來只有幾個像素——這就是「動了但幅度太小」的根因。
  double _peak = 0.05;
  int _deadTicks = 0; // 播放中連續讀不到有效樣本的 tick 數
  double _synthPhase = 0;

  void start() {
    _audioData ??= AudioData(GetSamplesKind.wave);
    _timer?.cancel();
    _deadTicks = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      double rms = 0;
      try {
        final samples = _audioData!.getAudioData();
        if (samples.isNotEmpty) {
          double sum = 0;
          for (int i = 0; i < samples.length; i++) {
            sum += samples[i] * samples[i];
          }
          rms = sqrt(sum / samples.length);
        }
      } catch (_) {
        // 讀不到波形（接口異常）→ rms 保持 0，走下面的保底
      }

      double target;
      if (rms >= 0.008) {
        _deadTicks = 0;
        // 峰值快跟漲、緩衰減 → 不同 TTS 音量都拉到可視幅度
        _peak = max(rms, _peak * 0.988);
        if (_peak < 0.05) _peak = 0.05;
        target = pow((rms / _peak).clamp(0.0, 1.0), 0.8).toDouble();
      } else if (playing) {
        // 正在播卻持續讀不到數據（>600ms）：波形接口失效的保底——
        // 退化為合成起伏，動畫至少不僵住
        _deadTicks++;
        if (_deadTicks > 12) {
          _synthPhase += 0.31;
          target =
              (0.42 + 0.30 * sin(_synthPhase) * sin(_synthPhase * 0.37 + 1.3))
                  .clamp(0.12, 0.85)
                  .toDouble();
        } else {
          target = 0.0;
        }
      } else {
        _deadTicks = 0;
        target = 0.0;
      }
      // 攻擊快、釋放慢，視覺更自然
      final cur = level.value;
      level.value = target > cur
          ? cur + (target - cur) * 0.55
          : cur + (target - cur) * 0.25;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    playing = false;
    level.value = 0.0;
  }

  void dispose() {
    stop();
    _audioData?.dispose();
    _audioData = null;
    level.dispose();
  }
}

/// 管線狀態
enum PipelineState { idle, generating, playing, done }

class SentenceTtsPipeline {
  final String? characterId;
  final String? conversationId;
  final String? conversationTitle;

  SentenceTtsPipeline({
    this.characterId,
    this.conversationId,
    this.conversationTitle,
  });

  // TTS 配置（start() 時解析一次）
  String _provider = 'openai';
  String _elModel = 'eleven_multilingual_v2';
  String _elVoiceId = '';
  String _elKey = '';
  double _elStability = 0.5;
  double _elSimilarity = 0.75;
  String _oaVoice = 'nova';
  String _oaKey = '';

  bool get isV3 => _provider == 'elevenlabs' && _elModel == 'eleven_v3';

  // 切句緩衝
  String _buf = '';
  int _sentenceIndex = 0;
  bool _finished = false;
  bool _cancelled = false;
  bool _disposed = false;

  // 已合成音頻（按句序）
  final Map<int, Uint8List?> _audioBySentence = {};
  final Map<int, String> _textBySentence = {};
  int _nextToPlay = 0;
  int _totalSentences = 0;
  bool _playLoopRunning = false;
  Completer<void>? _allDone;
  int _inFlight = 0;
  // ElevenLabs free tier 併發上限 2；OpenAI TTS 放 3。
  // 播第 N 句時後面的句子已在合成，句間不等 HTTP。
  int get _maxConcurrent => _provider == 'elevenlabs' ? 2 : 3;
  final List<int> _pendingGenerate = [];
  String _prevSentence = '';

  /// 完整音頻（存語音庫用，mp3 分段直接串接可播）
  final BytesBuilder _fullAudio = BytesBuilder(copy: false);
  String _spokenText = '';

  /// 播放狀態通知
  final ValueNotifier<bool> speaking = ValueNotifier(false);
  final CallAmplitude amplitude = CallAmplitude();

  /// 首句音頻開播回調（call_screen 切狀態用）
  VoidCallback? onFirstAudio;
  bool _firstAudioFired = false;
  VoidCallback? onAudioFailure;
  bool _audioFailureFired = false;

  // 掛斷容錯：單次 TTS 失敗只跳句，連續 ≥2 次（或整輪一聲沒出）
  // 才通報 onAudioFailure。之前一次失敗就掛斷，網路抖一下電話就沒了。
  int _consecutiveFailures = 0;
  bool _anyAudioOk = false;
  static const _failureThreshold = 2;

  Future<void> start() async {
    await CallAudio.ensureInit();
    _provider = await TtsSettings.getTtsProvider();
    if (_provider == 'elevenlabs') {
      _elKey = await TtsSettings.getTtsElevenlabsKey();
      _elModel = await TtsSettings.getTtsElevenlabsModel();
      _elVoiceId = await TtsService.resolveElevenVoiceId(characterId);
      _elStability = await TtsSettings.getTtsElevenlabsStability();
      _elSimilarity = await TtsSettings.getTtsElevenlabsSimilarity();
    } else {
      _oaKey = await TtsSettings.getTtsOpenaiKey();
      _oaVoice = await TtsService.resolveOpenaiVoice(characterId);
    }
    _buf = '';
    _sentenceIndex = 0;
    _nextToPlay = 0;
    _finished = false;
    _cancelled = false;
    _firstAudioFired = false;
    _audioFailureFired = false;
    _consecutiveFailures = 0;
    _anyAudioOk = false;
    _audioBySentence.clear();
    _textBySentence.clear();
    _pendingGenerate.clear();
    _fullAudio.clear();
    _spokenText = '';
    _prevSentence = '';
    _allDone = Completer<void>();
  }

  // ═══ 切句 ═══
  // 首句門檻低（4 字即發，搶首音延遲），後續句子湊長一點減少請求數。
  static const _sentenceEnd = [
    '。',
    '！',
    '？',
    '!',
    '?',
    '…',
    '～',
    ';',
    '；',
    '\n',
  ];
  static const _softBreak = ['，', ','];

  void pushText(String delta) {
    if (_cancelled || _finished) return;
    _buf += delta;
    _trySplit();
  }

  void _trySplit() {
    while (true) {
      // 首句 4 字即切搶首音；後續句湊滿 30 字再切——
      // 之前「首句之後全部等 finish() 整段轉」會在首句播完後空窗一大段
      // （等整段 LLM + 整段 TTS），流暢度就是死在這裡。
      // 湊長 + 邊流邊切 + 併發預合成 = 首音快、句間不空窗、請求數也少。
      final first = _sentenceIndex == 0;
      final minLen = first ? 4 : 30;
      int cut = -1;
      for (int i = 0; i < _buf.length; i++) {
        final ch = _buf[i];
        if (_sentenceEnd.contains(ch) && i + 1 >= minLen) {
          // 連續標點（如「……」「！？」）一起帶走
          int j = i;
          while (j + 1 < _buf.length &&
              (_sentenceEnd.contains(_buf[j + 1]) ||
                  _softBreak.contains(_buf[j + 1]))) {
            j++;
          }
          cut = j;
          break;
        }
      }
      // 太長沒句號 → 逗號斷
      if (cut == -1 && _buf.length > (first ? 60 : 100)) {
        for (int i = _buf.length - 1; i >= 20; i--) {
          if (_softBreak.contains(_buf[i])) {
            cut = i;
            break;
          }
        }
      }
      if (cut == -1) return;
      final sentence = _buf.substring(0, cut + 1).trim();
      _buf = _buf.substring(cut + 1);
      if (sentence.isNotEmpty) _dispatch(sentence);
    }
  }

  void _dispatch(String sentence) {
    // 送 TTS 的文本：v3 保留 [tag]（模型靠它控制語氣），其他模型剝除
    final speech = TtsService.extractSpeechContent(
      sentence,
      keepAudioTags: isV3,
    );
    if (speech.trim().isEmpty) return;
    final idx = _sentenceIndex++;
    _totalSentences = _sentenceIndex;
    _textBySentence[idx] = speech;
    _pendingGenerate.add(idx);
    _pumpGenerate();
  }

  void _pumpGenerate() {
    while (_inFlight < _maxConcurrent && _pendingGenerate.isNotEmpty) {
      final idx = _pendingGenerate.removeAt(0);
      _inFlight++;
      _generate(idx).whenComplete(() {
        _inFlight--;
        _pumpGenerate();
        _pumpPlayback();
      });
    }
  }

  Future<void> _generate(int idx) async {
    if (_cancelled) {
      _audioBySentence[idx] = null;
      return;
    }
    final text = _textBySentence[idx]!;
    final prev = _prevSentence;
    _prevSentence = text;
    try {
      Uint8List bytes;
      if (_provider == 'elevenlabs') {
        bytes = await _elevenGenerate(text, previousText: prev);
      } else {
        bytes = await _openaiGenerate(text);
      }
      _audioBySentence[idx] = _cancelled ? null : bytes;
      _consecutiveFailures = 0;
    } catch (e) {
      debugPrint('通話 TTS 第 $idx 句失敗: $e');
      _audioBySentence[idx] = null; // 失敗跳過，不卡整條流水線
      _recordFailure();
    }
  }

  /// 失敗計數：連續 ≥2 次才算信號差，單次抖動只跳句
  void _recordFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _failureThreshold) _notifyAudioFailure();
  }

  void _notifyAudioFailure() {
    if (_cancelled || _audioFailureFired) return;
    _audioFailureFired = true;
    onAudioFailure?.call();
  }

  Future<Uint8List> _elevenGenerate(
    String text, {
    String previousText = '',
  }) async {
    if (_elKey.isEmpty) throw Exception('ElevenLabs API Key 未設定');
    if (_elVoiceId.isEmpty) throw Exception('ElevenLabs Voice ID 未設定');
    final resp = await http
        .post(
          Uri.parse(
            'https://api.elevenlabs.io/v1/text-to-speech/$_elVoiceId'
            '?output_format=mp3_44100_128',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
            'xi-api-key': _elKey,
          },
          body: jsonEncode({
            'text': text,
            'model_id': _elModel.isEmpty ? 'eleven_multilingual_v2' : _elModel,
            // previous_text 拼接會讓部分模型直接回 400——正是「第一句有聲、
            // 第二句起 400」的元兇（首句沒 prev 才活）。語氣連貫是小事、能出聲
            // 才是大事，整個拿掉，不再賭型號。
            'voice_settings': {
              'stability': _elStability,
              'similarity_boost': _elSimilarity,
            },
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      // 帶上 body——ElevenLabs 的 400 會在 body 裡寫明真正原因，
      // 別只丟個裸狀態碼，下次還得猜。
      throw Exception('ElevenLabs ${resp.statusCode}: ${resp.body}');
    }
    return resp.bodyBytes;
  }

  Future<Uint8List> _openaiGenerate(String text) async {
    if (_oaKey.isEmpty) throw Exception('OpenAI TTS API Key 未設定');
    final resp = await http
        .post(
          Uri.parse('https://api.openai.com/v1/audio/speech'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $_oaKey',
          },
          body: jsonEncode({
            'model': 'tts-1',
            'voice': _oaVoice.isEmpty ? 'nova' : _oaVoice,
            'input': text.length > 4096 ? text.substring(0, 4096) : text,
            'response_format': 'mp3',
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('OpenAI TTS ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  // ═══ 按序播放 ═══
  Future<void> _pumpPlayback() async {
    if (_playLoopRunning || _cancelled) return;
    _playLoopRunning = true;
    try {
      while (!_cancelled) {
        if (!_audioBySentence.containsKey(_nextToPlay)) {
          // 下一句還沒好：是否全部結束？
          final allGenerated =
              _finished && _pendingGenerate.isEmpty && _inFlight == 0;
          if (allGenerated && _nextToPlay >= _totalSentences) break;
          return; // 等下一次 _pumpGenerate 完成後再進來
        }
        final bytes = _audioBySentence.remove(_nextToPlay);
        final text = _textBySentence[_nextToPlay] ?? '';
        _nextToPlay++;
        if (bytes == null) continue; // 該句失敗，跳過
        _fullAudio.add(bytes);
        _spokenText += text;
        if (!_firstAudioFired) {
          _firstAudioFired = true;
          onFirstAudio?.call();
        }
        speaking.value = true;
        amplitude.start();
        await _playBytes(bytes);
      }
    } finally {
      _playLoopRunning = false;
      final allGenerated =
          _finished && _pendingGenerate.isEmpty && _inFlight == 0;
      if (_cancelled || (allGenerated && _nextToPlay >= _totalSentences)) {
        amplitude.stop();
        speaking.value = false;
        if (!(_allDone?.isCompleted ?? true)) _allDone?.complete();
      }
    }
  }

  SoundHandle? _currentHandle;
  AudioSource? _currentSource;

  Future<void> _playBytes(Uint8List bytes) async {
    AudioSource? source;
    var registered = false; // source 是否已掛到 _currentSource（cancel 可見）
    try {
      if (_cancelled) return;
      source = await SoLoud.instance.loadMem(
        'call_${DateTime.now().microsecondsSinceEpoch}.mp3',
        bytes,
        mode: LoadMode.memory,
      );
      // loadMem 期間被掛斷/打斷：別讓聲音在掛斷後才冒出來（finally 清理）
      if (_cancelled) return;
      _currentSource = source;
      registered = true;
      _currentHandle = SoLoud.instance.play(source);
      _anyAudioOk = true;
      _consecutiveFailures = 0;
      amplitude.playing = true;

      final done = Completer<void>();
      Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (_currentHandle == null ||
            !SoLoud.instance.getIsValidVoiceHandle(_currentHandle!)) {
          timer.cancel();
          if (!done.isCompleted) done.complete();
        }
      });

      await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});
    } catch (e) {
      debugPrint('通話播放失敗: $e');
      _recordFailure();
    } finally {
      // 統一清理：正常播完、播放中拋異常、cancelled 三條路都走這裡，
      // source 不再洩漏。cancel() 若已接管 dispose（_currentSource 已易主/
      // 清空），這裡就不重複 dispose。
      amplitude.playing = false;
      final s = source;
      if (s != null && (!registered || identical(_currentSource, s))) {
        if (registered) {
          _currentSource = null;
          _currentHandle = null;
        }
        try {
          await SoLoud.instance.disposeSource(s);
        } catch (_) {}
      }
    }
  }

  /// LLM 流結束後調用；等全部句子播完
  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    final rest = _buf.trim();
    _buf = '';
    if (rest.isNotEmpty) _dispatch(rest);
    if (_totalSentences == 0) {
      // 整段沒有可說內容
      if (!(_allDone?.isCompleted ?? true)) _allDone?.complete();
    } else {
      _pumpPlayback();
    }
    await _allDone?.future;
    // 有內容卻整輪一聲沒播出來 = 真信號差（單句失敗跳過不算）
    if (!_cancelled && _totalSentences > 0 && !_anyAudioOk) {
      _notifyAudioFailure();
    }
    await _saveToLibrary();
  }

  /// 立即打斷（用戶插話 / 掛斷）
  Future<void> cancel() async {
    _cancelled = true;
    _pendingGenerate.clear();
    amplitude.stop();
    speaking.value = false;
    // 先摘引用再 dispose：_playBytes 的 finally 以 _currentSource 判斷
    // 清理歸屬，摘掉後那邊就不會對同一個 source 重複 dispose。
    final handle = _currentHandle;
    final source = _currentSource;
    _currentHandle = null;
    _currentSource = null;
    try {
      if (handle != null) {
        await SoLoud.instance.stop(handle);
      }
      if (source != null) {
        await SoLoud.instance.disposeSource(source);
      }
    } catch (_) {}
    if (!(_allDone?.isCompleted ?? true)) _allDone?.complete();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(cancel());
    amplitude.dispose();
    speaking.dispose();
  }

  Future<void> _saveToLibrary() async {
    final bytes = _fullAudio.toBytes();
    if (bytes.isEmpty || _spokenText.isEmpty) return;
    try {
      await TtsService.saveBytesToLibrary(
        bytes,
        _spokenText,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        characterId: characterId,
      );
    } catch (_) {}
  }
}

/// ═══ 鈴聲播放（來電用）═══
class RingtonePlayer {
  static const ringtones = <String, String>{
    'gentle': '輕柔',
    'classic': '經典',
    'vibrate': '僅震動',
  };

  AudioSource? _source;
  SoundHandle? _handle;

  // start() 的 await（init/load）期間被 stop() 追過時，靠世代號攔住
  // 後續的 play——否則鈴聲會在掛斷之後才響起來。
  int _generation = 0;

  Future<void> start(String key) async {
    if (key == 'vibrate') return;
    final gen = ++_generation;
    try {
      await CallAudio.ensureInit();
      final data = await rootBundle.load('assets/audio/ringtone_$key.mp3');
      if (gen != _generation) return; // 已被 stop()/新 start() 超越
      final source = await SoLoud.instance.loadMem(
        'ringtone_$key.mp3',
        data.buffer.asUint8List(),
        mode: LoadMode.memory,
      );
      if (gen != _generation) {
        // load 期間被 stop：source 還沒掛上字段，自己收掉
        try {
          await SoLoud.instance.disposeSource(source);
        } catch (_) {}
        return;
      }
      _source = source;
      _handle = SoLoud.instance.play(source, looping: true);
    } catch (e) {
      debugPrint('鈴聲播放失敗: $e');
    }
  }

  Future<void> stop() async {
    _generation++;
    final handle = _handle;
    final source = _source;
    _handle = null;
    _source = null;
    try {
      if (handle != null) await SoLoud.instance.stop(handle);
      if (source != null) await SoLoud.instance.disposeSource(source);
    } catch (_) {}
  }
}

/// 通話結束時傳回 chat_screen 的結果
class CallResult {
  /// 'ended' 正常通話後掛斷｜'declined' 拒接來電｜'missed' 響鈴未接｜'signal_lost' 信號不佳中斷
  final String event;
  final Duration duration;
  final bool anyExchange; // 通話中是否真的說過話
  const CallResult(this.event, this.duration, {this.anyExchange = false});
}

/// DB 輔助：通話開始前撈最近聊天做上下文
class CallContextLoader {
  static Future<List<Map<String, String>>> recentHistory(
    String conversationId, {
    int limit = 12,
  }) async {
    try {
      final tail = await DatabaseHelper.getMessages(
        conversationId,
        limit: limit,
      );
      return tail
          .where((m) => m.text.trim().isNotEmpty)
          .map(
            (m) => {'role': m.isUser ? 'user' : 'assistant', 'content': m.text},
          )
          .toList();
    } catch (_) {
      return [];
    }
  }
}
