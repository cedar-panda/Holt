import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../memory/database.dart';
import 'settings_manager.dart';

/// TTS 播放狀態
enum TtsState { idle, connecting, playing }

/// TTS 統一服務 — OpenAI + ElevenLabs
class TtsService {
  static final AudioPlayer _player = AudioPlayer();
  static bool _listenerBound = false;

  /// 三態通知 — idle → connecting → playing → idle
  static final ValueNotifier<TtsState> stateNotifier = ValueNotifier(
    TtsState.idle,
  );

  /// 當前正在播放的訊息 ID（用來讓特定氣泡高亮）
  static final ValueNotifier<String?> playingMessageId = ValueNotifier(null);

  // 向下相容
  static final ValueNotifier<bool> playingNotifier = _PlayingProxy();

  static bool get isPlaying => stateNotifier.value == TtsState.playing;
  static bool get isConnecting => stateNotifier.value == TtsState.connecting;

  static void _ensureListener() {
    if (_listenerBound) return;
    _listenerBound = true;
    _player.onPlayerComplete.listen((_) {
      stateNotifier.value = TtsState.idle;
      playingMessageId.value = null;
    });
    _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.stopped || state == PlayerState.completed) {
        stateNotifier.value = TtsState.idle;
        playingMessageId.value = null;
      }
    });
  }

  /// 朗讀文字（帶訊息 ID 用於 UI 高亮）
  /// [conversationId] / [conversationTitle] 用於語音庫標注來源
  static Future<void> speak(
    String text, {
    String? messageId,
    String? conversationId,
    String? conversationTitle,
    String? characterId,
  }) async {
    _ensureListener();

    if (text.isEmpty) return;
    if (isPlaying || isConnecting) {
      await stop();
      return;
    }

    // ═══ 緩存命中 → 直接播本地文件 ═══
    if (messageId != null) {
      final cachedPath = await DatabaseHelper.getVoicePathByMessageId(
        messageId,
      );
      if (cachedPath != null) {
        stateNotifier.value = TtsState.playing;
        playingMessageId.value = messageId;
        await _player.play(DeviceFileSource(cachedPath));
        return;
      }
    }

    final provider = await TtsSettings.getTtsProvider();

    if (provider == 'elevenlabs') {
      // TODO: WebSocket 流式暫時停用（Android dart:io 兼容問題）
      await _serialSpeakElevenLabs(
        text,
        messageId: messageId,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        characterId: characterId,
      );
    } else {
      await _serialSpeak(
        text,
        messageId: messageId,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        characterId: characterId,
      );
    }
  }

  /// ElevenLabs HTTP 串行播放（v3 等不支持 WebSocket 的模型）
  static Future<void> _serialSpeakElevenLabs(
    String text, {
    String? messageId,
    String? conversationId,
    String? conversationTitle,
    String? characterId,
  }) async {
    try {
      stateNotifier.value = TtsState.connecting;
      playingMessageId.value = messageId;

      final bytes = await _elevenLabsGenerate(text, characterId: characterId);

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(bytes);

      _saveToLibrary(
        bytes,
        text,
        messageId: messageId,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        characterId: characterId,
      );

      stateNotifier.value = TtsState.playing;
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      stateNotifier.value = TtsState.idle;
      playingMessageId.value = null;
      rethrow;
    }
  }

  /// 串行播放（OpenAI TTS）
  static Future<void> _serialSpeak(
    String text, {
    String? messageId,
    String? conversationId,
    String? conversationTitle,
    String? characterId,
  }) async {
    try {
      stateNotifier.value = TtsState.connecting;
      playingMessageId.value = messageId;

      final bytes = await _openaiGenerate(text, characterId: characterId);

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(bytes);

      _saveToLibrary(
        bytes,
        text,
        messageId: messageId,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        characterId: characterId,
      );

      stateNotifier.value = TtsState.playing;
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      stateNotifier.value = TtsState.idle;
      playingMessageId.value = null;
      rethrow;
    }
  }

  /// 保存語音 bytes 到語音庫（通話管線也用）
  static Future<void> saveBytesToLibrary(
    Uint8List bytes,
    String text, {
    String? messageId,
    String? conversationId,
    String? conversationTitle,
    String? characterId,
  }) => _saveToLibrary(
    bytes,
    text,
    messageId: messageId,
    conversationId: conversationId,
    conversationTitle: conversationTitle,
    characterId: characterId,
  );

  /// 角色卡優先的 ElevenLabs voice id 解析
  static Future<String> resolveElevenVoiceId(String? characterId) async {
    if (characterId != null) {
      final char = await DatabaseHelper.getCharacter(characterId);
      final v = char?['tts_voice_id'] as String?;
      if (v != null && v.isNotEmpty) return v;
    }
    return TtsSettings.getTtsElevenlabsVoiceId();
  }

  /// 角色卡優先的 OpenAI voice 解析
  static Future<String> resolveOpenaiVoice(String? characterId) async {
    if (characterId != null) {
      final char = await DatabaseHelper.getCharacter(characterId);
      final v = char?['tts_voice_id'] as String?;
      if (v != null && v.isNotEmpty) return v;
    }
    return TtsSettings.getTtsVoice();
  }

  /// 後台保存語音到持久目錄 + DB
  static Future<void> _saveToLibrary(
    Uint8List bytes,
    String text, {
    String? messageId,
    String? conversationId,
    String? conversationTitle,
    String? characterId,
  }) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final voiceDir = Directory('${appDir.path}/voices');
      if (!await voiceDir.exists()) await voiceDir.create(recursive: true);

      final ts = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${voiceDir.path}/voice_$ts.mp3';
      await File(filePath).writeAsBytes(bytes);

      // 語音名稱：取前 20 字
      final name = text.length > 20 ? '${text.substring(0, 20)}…' : text;

      await DatabaseHelper.saveVoice(
        filePath: filePath,
        name: name,
        messageId: messageId,
        sourceConversationId: conversationId,
        sourceConversationTitle: conversationTitle,
        characterId: characterId ?? 'default',
        fileSize: bytes.length,
      );
    } catch (_) {
      // 保存失敗不影響播放
    }
  }

  static Future<void> stop() async {
    await _player.stop();
    stateNotifier.value = TtsState.idle;
    playingMessageId.value = null;
  }

  // ═══════════════════════════════════════════
  //  語音文字預處理 — 只保留說話內容
  // ═══════════════════════════════════════════

  /// 從 AI 回覆中擷取「說話內容」，剝除動作描述
  ///
  /// 剝除順序：
  /// 1. `<think>` / `<thinking>` 思考鏈
  /// 2. [sticker:N] 表情包標記
  /// 2.5 情緒標記 [sigh] 等
  /// 2.7 括號動作描寫 () （）
  /// 3. *動作描寫*（markdown 斜體整行）— 明確標記
  /// 4. 動作描述行（啟發式匹配）
  /// 5. 殘留 markdown 符號
  /// 語音標籤（ElevenLabs v3 audio tags 及模型自造的中文變體）
  /// 排除功能性標記 [sticker:] [transfer:] [scratch_gift:] [call_event:]
  static final audioTagRe = RegExp(
    r'\[(?!sticker:|transfer:|scratch_gift:|call_event)[^\[\]\n]{1,20}\]\s?',
  );

  /// [keepAudioTags] = true 時保留 [sigh]/[happy] 等語音標籤——
  /// ElevenLabs v3 靠這些控制語氣，剝掉反而失去表現力。
  /// 顯示用文本永遠剝（chat_bubble 那邊處理）。
  static String extractSpeechContent(String raw, {bool keepAudioTags = false}) {
    var text = raw;

    // 1) 思考鏈
    text = text.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    text = text.replaceAll(
      RegExp(r'<thinking>.*?</thinking>', dotAll: true),
      '',
    );

    // 1.5) 內部標籤（情緒 / 記憶 / 畫圖 / 自我註記）
    text = text.replaceAll(RegExp(r'<emo>.*?</emo>', dotAll: true), '');
    text = text.replaceAll(
      RegExp(r'<emo_resolve>.*?</emo_resolve>', dotAll: true),
      '',
    );
    text = text.replaceAll(RegExp(r'<memo>.*?</memo>', dotAll: true), '');
    text = text.replaceAll(
      RegExp(r'<memo_del>.*?</memo_del>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<memo_merge>.*?</memo_merge>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<memo_update>.*?</memo_update>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<persona_note>.*?</persona_note>', dotAll: true),
      '',
    );
    text = text.replaceAll(RegExp(r'<draw>.*?</draw>', dotAll: true), '');
    text = text.replaceAll(RegExp(r'<clock>.*?</clock>', dotAll: true), '');
    text = text.replaceAll(
      RegExp(r'<clock_keep>.*?</clock_keep>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<clock_update\b[^>]*>.*?</clock_update>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<clock_del>.*?</clock_del>', dotAll: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<life_fix>.*?</life_fix>', dotAll: true),
      '',
    );
    text = text.replaceAll(RegExp(r'<home>.*?</home>', dotAll: true), '');

    // 2) 功能性標記一律剝除
    text = text.replaceAll(RegExp(r'\[sticker:\d+\]'), '');
    text = text.replaceAll(RegExp(r'\[transfer:\d+\]'), '');
    text = text.replaceAll(RegExp(r'\[call_event:[^\]]*\]'), '');

    // 2.5) 情緒標記（[sigh] [laughing] [whispers] 等）
    //      v3 模式保留——它們是給 TTS 的演出指令
    if (!keepAudioTags) {
      text = text.replaceAll(audioTagRe, '');
    }

    // 2.7) 括號動作描寫（半形 () 和全形 （）中的動作指示）
    text = text.replaceAll(RegExp(r'[（(][^)）]*[)）]\s?'), '');

    // 3) *動作描寫* 整行（明確標記的動作）
    //    匹配整行被 * 包裹的內容，如 *低頭不語*、*輕輕笑了*
    text = text.replaceAll(RegExp(r'^\*[^*]+\*\s*$', multiLine: true), '');

    // 4) 啟發式動作行剝除
    final lines = text.split('\n');
    final speechLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_isActionLine(trimmed)) continue;
      speechLines.add(trimmed);
    }

    text = speechLines.join('\n');

    // 5) 清理殘留 markdown（粗體、代碼、標題、引用）
    text = text.replaceAll(RegExp(r'\*{2,3}'), ''); // **粗體** 但不動單個 *
    text = text.replaceAll(RegExp(r'`{1,3}'), '');
    text = text.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\>\s*', multiLine: true), '');

    return text.trim();
  }

  /// 判斷是否為動作描述行
  ///
  /// 兩層匹配：
  /// A. 明確動作模式（高信度）
  /// B. 敘事風格判斷（中信度）
  ///
  /// 不匹配：直接對話中的「你」（你是我的、你怎麼了）
  static bool _isActionLine(String line) {
    // ══ A. 明確動作模式 ══

    // ── 第二人稱感官敘事 ──
    if (RegExp(
      r'^你(感覺|感受|看到|看見|望見|瞥見|聽到|聽見|'
      r'注意到|發現|能感|能看|能聽|能聞|嗅到|聞到|'
      r'被[^\s，。]+[了著过])',
    ).hasMatch(line)) {
      return true;
    }

    // ── 純動作起始（放寬：不要求特定結尾）──
    if (RegExp(
      r'^(低[下了]|抬[起頭眼了]|伸[手出了]|縮[回了]|轉[過身頭了]|'
      r'側[過頭身了]|靠[過近了]|退[後開了]|湊[過近了]|'
      r'閉[上了]|張[開了]|握[住了]|放[開下了]|鬆[開了]|'
      r'拉[住過了]|推[開了]|按[住了]|碰[了到]|摸[了到]|'
      r'拍[了到]|搖[了頭]|點[了頭]|挪[開了]|移[開了]|'
      r'坐[下了在]|站[起了在]|蹲[下了]|躺[下了在]|'
      r'趴[下了在]|跪[下了在]|歪[了著]|垂[下了著])',
    ).hasMatch(line)) {
      return true;
    }

    // ── 副詞開頭的動作描寫 ──
    if (RegExp(
      r'^(微微|輕輕|慢慢|緩緩|悄悄|偷偷|默默|靜靜|'
      r'輕聲|低聲|小聲|無聲|柔聲|啞聲|含糊|'
      r'安靜地|沉默地|小聲地|無聲地|輕聲地|低聲地)'
      r'(笑|歎|嘆|吸|呼|捏|碰|摸|拍|握|放|拉|推|按|'
      r'低|抬|伸|縮|轉|側|靠|退|湊|閉|張|搖|點|挪|移|'
      r'吻|親|蹭|靠|貼|摟|抱|牽|勾|扯|撥|掃|撫|揉|捲|'
      r'彎|曲|仰|俯|傾|斜|偏|歪|垂|落|滑|'
      r'應|嗯|哼|嘟|噘|咬|舔|眨|瞇|皺|蹙|愣|頓|'
      r'說|道|問|答|回|喚|喊|呢喃|嘀咕|囁嚅|咕噥)',
    ).hasMatch(line)) {
      return true;
    }

    // ── 身體部位起始的動作描寫 ──
    if (RegExp(
      r'^(手指|指尖|指腹|手掌|手背|手腕|手臂|'
      r'嘴唇|唇|嘴角|鼻尖|額頭|額|眼睫|睫毛|眉|眼|目光|視線|'
      r'肩膀|肩|鎖骨|脖頸|頸|下巴|臉頰|頰|'
      r'腰|背|胸口|膝|腳|髮絲|髮尾|瀏海|呼吸|心跳|脈搏|體溫)',
    ).hasMatch(line)) {
      return true;
    }

    // ── 環境/氛圍描寫 ──
    if (RegExp(
      r'^(空氣|房間|窗外|光線|風|陽光|月光|燈光|'
      r'影子|氣氛|沉默|安靜|寂靜|溫度|氣息|聲音)',
    ).hasMatch(line)) {
      return true;
    }

    // ══ B. 敘事風格判斷 ══

    // ── 以「——」破折號結尾的敘事句（常見動作描寫斷句）──
    // 不剝除，因為說話也可能用破折號

    // ── 整行是 *斜體*（已在上面處理）──

    // ── 「沒有說話」「沒有回答」等描寫沉默的行 ──
    if (RegExp(
      r'^(沒有說話|沒有回答|沒有出聲|沒說話|不說話|不出聲|'
      r'沒回答|沒接話|沒開口|不開口|不回答)',
    ).hasMatch(line)) {
      return true;
    }

    return false;
  }

  // ═══ OpenAI TTS ═══
  static Future<Uint8List> _openaiGenerate(
    String text, {
    String? characterId,
  }) async {
    final apiKey = await TtsSettings.getTtsOpenaiKey();
    if (apiKey.isEmpty) throw Exception('OpenAI TTS API Key 未設定');

    String voice = '';
    if (characterId != null) {
      final char = await DatabaseHelper.getCharacter(characterId);
      if (char != null) {
        final charVoice = char['tts_voice_id'] as String?;
        if (charVoice != null && charVoice.isNotEmpty) {
          voice = charVoice;
        }
      }
    }
    if (voice.isEmpty) {
      voice = await TtsSettings.getTtsVoice();
    }

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/audio/speech'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'tts-1',
        'voice': voice.isEmpty ? 'nova' : voice,
        'input': text.length > 4096 ? text.substring(0, 4096) : text,
        'response_format': 'mp3',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('OpenAI TTS 錯誤 ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  // ═══ ElevenLabs TTS ═══
  static Future<Uint8List> _elevenLabsGenerate(
    String text, {
    String? characterId,
  }) async {
    final apiKey = await TtsSettings.getTtsElevenlabsKey();
    if (apiKey.isEmpty) throw Exception('ElevenLabs API Key 未設定');

    String voiceId = '';
    if (characterId != null) {
      final char = await DatabaseHelper.getCharacter(characterId);
      if (char != null) {
        final charVoiceId = char['tts_voice_id'] as String?;
        if (charVoiceId != null && charVoiceId.isNotEmpty) {
          voiceId = charVoiceId;
        }
      }
    }
    if (voiceId.isEmpty) {
      voiceId = await TtsSettings.getTtsElevenlabsVoiceId();
    }
    if (voiceId.isEmpty) throw Exception('ElevenLabs Voice ID 未設定');
    final model = await TtsSettings.getTtsElevenlabsModel();
    final stability = await TtsSettings.getTtsElevenlabsStability();
    final similarity = await TtsSettings.getTtsElevenlabsSimilarity();

    final response = await http.post(
      Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
        'xi-api-key': apiKey,
      },
      body: jsonEncode({
        'text': text,
        'model_id': model.isEmpty ? 'eleven_multilingual_v2' : model,
        'voice_settings': {
          'stability': stability,
          'similarity_boost': similarity,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'ElevenLabs 錯誤 ${response.statusCode}: '
        '${response.body.length > 100 ? response.body.substring(0, 100) : response.body}',
      );
    }
    return response.bodyBytes;
  }

  /// ElevenLabs 可選模型
  static const elevenlabsModels = {
    'eleven_flash_v2_5': 'Flash v2.5（低延遲）',
    'eleven_multilingual_v2': 'Multilingual v2（高品質）',
    'eleven_v3': 'Eleven v3（最新）',
  };

  /// OpenAI 可選聲音
  static const openaiVoices = [
    'alloy',
    'echo',
    'fable',
    'onyx',
    'nova',
    'shimmer',
  ];
}

/// 向下相容：讓 `playingNotifier.value` 回傳 bool
/// call_screen 用 `TtsService.playingNotifier.addListener` 監聽結束
class _PlayingProxy extends ValueNotifier<bool> {
  _PlayingProxy() : super(false) {
    TtsService.stateNotifier.addListener(_sync);
  }
  void _sync() {
    value = TtsService.stateNotifier.value == TtsState.playing;
  }
}
