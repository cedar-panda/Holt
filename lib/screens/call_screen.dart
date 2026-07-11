import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/tts_service.dart';
import '../services/api_adapter.dart';
import '../services/token_tracker.dart';
import '../services/call_audio_pipeline.dart';
import '../services/cache_stats_helper.dart';
import '../memory/retriever.dart';
import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import '../models/message.dart';
import '../widgets/call_visual.dart';

/// ═══════════════════════════════════════════════════════════
///  語音通話 v2
///
///  · 低延遲管線：LLM 流式 → 句子級 TTS 流水線（首句即播）
///  · 中央頭像 + 真實振幅聲波（SoLoud / STT soundLevel）
///  · 兩種麥克風模式：按住說話 / 自動聆聽（停頓自動發送 + 靜音）
///  · 來電模式：鈴聲 + 震動 + 接聽/掛斷動畫（接聽後掛斷鍵居中）
///  · 通話事件以 CallResult 回傳 chat_screen（隱藏注入告知模型）
/// ═══════════════════════════════════════════════════════════

enum _CallPhase { ringing, dialing, inCall }

enum _MicState { idle, listening, thinking, speaking }

class CallScreen extends StatefulWidget {
  final String characterName;
  final String conversationId;

  /// true = 模型發起的來電（先響鈴，接聽才進通話）
  final bool incoming;

  final String openingLine;
  final String? cacheStaticSnapshot;

  /// 聊天路徑構建的同款靜態前綴（_buildCommonStaticParts 產物）。
  /// 傳入後通話與聊天共用同一個緩存 namespace——接通第一輪就吃
  /// 聊天已建好的緩存；沒傳則退回通話自拼的舊前綴。
  final String? staticPart;
  final String? profilePart;

  const CallScreen({
    super.key,
    required this.characterName,
    required this.conversationId,
    this.incoming = false,
    this.openingLine = '',
    this.cacheStaticSnapshot,
    this.staticPart,
    this.profilePart,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();

  late _CallPhase _phase;
  _MicState _micState = _MicState.idle;
  String _statusText = '';
  String _currentTranscript = '';

  String _characterId = 'default';
  String? _avatarPath;
  String _sttLocale = 'zh_TW';
  String _micMode = 'hold'; // 'hold' | 'auto'
  bool _muted = false;
  bool _speechAvailable = false;
  bool _popped = false;
  bool _endingForPoorSignal = false;

  final List<Map<String, String>> _callHistory = [];
  final List<_CallMessage> _chatLog = [];
  static const int _maxCallHistoryEntries = 40;
  bool _logExpanded = true;
  final ScrollController _logScroll = ScrollController();
  final TokenTracker _tokenTracker = TokenTracker();

  // 通話計時
  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;
  bool _anyExchange = false;

  // 聲波振幅（speaking 時來自 SoLoud，listening 時來自 STT soundLevel）
  final ValueNotifier<double> _level = ValueNotifier(0.0);

  // 緩存提示
  String? _cacheLabel;

  // TTS 流水線（每輪一條）
  SentenceTtsPipeline? _pipeline;
  int _turnSerial = 0;
  late final Future<void> _bootstrapFuture;
  bool _bootstrapReady = false;
  bool _bootstrapFailed = false;
  bool _sendingUserTurn = false;

  // 來電
  final RingtonePlayer _ringtone = RingtonePlayer();
  Timer? _ringVibrateTimer;
  Timer? _ringEchoTimer;
  Timer? _ringTimeoutTimer;
  Timer? _autoListenRestartTimer;
  Timer? _poorSignalFinishTimer;
  late final AnimationController _acceptPulse;
  bool _accepted = false; // 接聽動畫觸發

  bool _firstIncomingTurn = false;

  // ── STT 停頓推斷標點 ──
  // 系統 STT（SpeechRecognizer）不回傳標點，插件也沒暴露格式化開關。
  // 靠 partial result 之間的時間間隙推斷：停頓 ≥900ms 補「，」，
  // 結束時按句尾字補「？」或「。」。
  String _puncFixedRaw = ''; // 已定段的引擎原文
  String _puncFixedOut = ''; // 已定段的帶標點文本
  String _lastPartialRaw = '';
  DateTime _lastPartialAt = DateTime.now();
  static const _kCommaGapMs = 900;
  static const _endPunc = '。！？!?…～，,、；;：:';

  // 長按放開後 STT 回調失蹤的保底（Android 常只發 notListening 不發 done）
  Timer? _sttStopFallback;

  @override
  void initState() {
    super.initState();
    _phase = widget.incoming ? _CallPhase.ringing : _CallPhase.dialing;
    _statusText = widget.incoming
        ? L.get('call_incoming')
        : (L.pick(en: 'Dialing…', zhTW: '正在撥號'));
    _acceptPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.94,
      upperBound: 1.06,
    );
    if (widget.incoming) {
      _acceptPulse.repeat(reverse: true);
    } else {
      _acceptPulse.value = 1;
    }
    _bootstrapFuture = _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final conv = await DatabaseHelper.getConversation(widget.conversationId);
      final activeId = await UserSettings.getActiveCharacterId();
      final cid = conv?.characterId ?? activeId;
      final char = await DatabaseHelper.getCharacter(cid);
      final locale = await TtsSettings.getSttLocale();
      final micMode = await TtsSettings.getCallMicMode();
      if (!mounted || _popped) return;
      setState(() {
        _characterId = cid;
        _avatarPath = char?['avatar_path'] as String?;
        _sttLocale = locale;
        _micMode = micMode;
      });

      // 最近聊天做上下文——通話中她記得剛剛聊了什麼
      final recent = await CallContextLoader.recentHistory(
        widget.conversationId,
      );
      if (!mounted || _popped) return;
      _callHistory.addAll(recent);
      _trimCallHistory();

      await _initSpeech();
      if (!mounted || _popped) return;
      _bootstrapReady = true;

      if (widget.incoming) {
        await _startRinging();
      } else {
        await _startDialing();
      }
    } catch (error) {
      _bootstrapFailed = true;
      if (!mounted || _popped) return;
      setState(() {
        _statusText = L.get('call_error');
        _chatLog.add(
          _CallMessage(
            text: '⚠ ${error.toString()}',
            isUser: false,
            isError: true,
          ),
        );
      });
    }
  }

  void _appendCallHistory(String role, String content) {
    _callHistory.add({'role': role, 'content': content});
    _trimCallHistory();
  }

  void _trimCallHistory() {
    final overflow = _callHistory.length - _maxCallHistoryEntries;
    if (overflow > 0) _callHistory.removeRange(0, overflow);
  }

  String _idleHint() =>
      _micMode == 'auto' ? L.get('call_auto_hint') : L.get('call_hold');

  // ═══════════════ 來電與撥號 ═══════════════

  Future<void> _startDialing() async {
    if (!mounted || _popped || !_bootstrapReady) return;
    // 回鈴音：對方還沒接起時的「嘟——」等待音（接通/拒接/掛斷即停）
    _ringtone.start('ringback');
    _ringVibrateTimer = Timer.periodic(const Duration(milliseconds: 2000), (_) {
      if (!_popped) HapticFeedback.lightImpact();
    });
    // 隱藏對話回合：決定接聽或掛斷
    await _generateTurn(
      hiddenNote:
          '【通話】你打電話給對方。如果你不想接（例如你在忙、生氣、或是現在不想講話），請回覆 <decline_call/> 拒絕接聽。如果願意接聽，請直接說話（這將是你接起電話的第一句話）。',
    );
  }

  void _declineUserCall() {
    _ringVibrateTimer?.cancel();
    HapticFeedback.heavyImpact();
    _finish(const CallResult('declined', Duration.zero));
  }

  Future<void> _startRinging() async {
    final tone = await TtsSettings.getCallRingtone();
    if (!mounted || _popped || !_bootstrapReady) return;
    _ringtone.start(tone);
    // 節奏震動：噠噠 ── 噠噠 ──
    _ringVibrateTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      if (_popped) return;
      HapticFeedback.heavyImpact();
      _ringEchoTimer?.cancel();
      _ringEchoTimer = Timer(const Duration(milliseconds: 180), () {
        if (!_popped) HapticFeedback.heavyImpact();
      });
    });
    HapticFeedback.heavyImpact();
    // 45 秒未接 → 未接來電
    _ringTimeoutTimer = Timer(const Duration(seconds: 45), () {
      _finish(const CallResult('missed', Duration.zero));
    });
  }

  void _stopRinging() {
    _ringtone.stop();
    _ringVibrateTimer?.cancel();
    _ringEchoTimer?.cancel();
    _ringTimeoutTimer?.cancel();
    _acceptPulse.stop();
  }

  Future<void> _acceptCall() async {
    if (_accepted) return;
    await _bootstrapFuture;
    if (!mounted || _popped || !_bootstrapReady || _bootstrapFailed) return;
    _stopRinging();
    HapticFeedback.mediumImpact();
    setState(() => _accepted = true);
    // 等掛斷鍵滑到中央再切畫面
    await Future.delayed(const Duration(milliseconds: 420));
    if (!mounted) return;
    setState(() {
      _phase = _CallPhase.inCall;
      _statusText = _idleHint();
    });
    _startCallTimer();
    _firstIncomingTurn = true;

    // 開場白：標籤裡帶了就直接說，沒帶就讓她自己開口
    final opening = widget.openingLine.trim();
    if (opening.isNotEmpty) {
      await _speakDirect(opening);
      if (_micMode == 'auto' && mounted) _startAutoListen();
    } else {
      await _generateTurn(userText: null, hiddenNote: '【通話】對方接了你打的電話。你先開口。');
    }
  }

  void _declineCall() {
    _stopRinging();
    HapticFeedback.mediumImpact();
    _finish(const CallResult('declined', Duration.zero));
  }

  // ═══════════════ 通話計時 ═══════════════

  void _startCallTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _elapsed += const Duration(seconds: 1));
      }
    });
  }

  String get _durationText {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ═══════════════ STT ═══════════════

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onError: (error) {
          debugPrint('STT 錯誤: ${error.errorMsg}');
          if (!mounted || _popped) return;
          if (_micState == _MicState.listening) {
            setState(() {
              _micState = _MicState.idle;
              _statusText = L.get('call_stt_error');
            });
            _maybeRestartAutoListen();
          }
        },
        onStatus: (status) {
          // Android 上引擎結束常只發 'notListening' 不發 'done'——
          // 只等 done 會讓按鍵永遠卡在 listening
          if ((status == 'done' || status == 'notListening') &&
              mounted &&
              !_popped) {
            _onSttDone();
          }
        },
      );
      if (!_speechAvailable && mounted) {
        setState(() => _statusText = L.get('call_stt_unavailable'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _statusText = L.get('call_stt_init_fail'));
      }
    }
  }

  void _resetPunctuation() {
    _puncFixedRaw = '';
    _puncFixedOut = '';
    _lastPartialRaw = '';
    _lastPartialAt = DateTime.now();
  }

  /// partial 間隙 ≥900ms → 在停頓處補「，」。
  /// 引擎若整體重寫前文（不再是前綴）就放棄該段標點，用引擎全文。
  String _withPausePunc(String raw) {
    final now = DateTime.now();
    if (raw != _lastPartialRaw) {
      final gapMs = now.difference(_lastPartialAt).inMilliseconds;
      if (gapMs >= _kCommaGapMs &&
          _lastPartialRaw.isNotEmpty &&
          raw.startsWith(_lastPartialRaw) &&
          raw.length > _lastPartialRaw.length &&
          _lastPartialRaw.length > _puncFixedRaw.length) {
        var seg = _lastPartialRaw.startsWith(_puncFixedRaw)
            ? _puncFixedOut + _lastPartialRaw.substring(_puncFixedRaw.length)
            : _lastPartialRaw;
        if (seg.isNotEmpty && !_endPunc.contains(seg[seg.length - 1])) {
          seg += '，';
        }
        _puncFixedRaw = _lastPartialRaw;
        _puncFixedOut = seg;
      }
      _lastPartialRaw = raw;
      _lastPartialAt = now;
    }
    return (_puncFixedRaw.isNotEmpty && raw.startsWith(_puncFixedRaw))
        ? _puncFixedOut + raw.substring(_puncFixedRaw.length)
        : raw;
  }

  /// 句尾標點：疑問語氣字 →「？」，其餘 →「。」
  String _finalizePunc(String text) {
    final t = text.trim();
    if (t.isEmpty) return t;
    if (_endPunc.contains(t[t.length - 1])) return t;
    const questionTail = ['嗎', '呢', '吧', '么'];
    return questionTail.contains(t[t.length - 1]) ? '$t？' : '$t。';
  }

  void _listen({required bool auto}) {
    if (!mounted || _popped || !_bootstrapReady) return;
    _resetPunctuation();
    _speech.listen(
      onResult: (result) {
        if (!mounted || _popped) return;
        final display = _withPausePunc(result.recognizedWords);
        setState(() => _currentTranscript = display);
        if (result.finalResult && _currentTranscript.trim().isNotEmpty) {
          final text = _finalizePunc(_currentTranscript);
          _currentTranscript = '';
          _speech.stop();
          // 同步進入 thinking：晚到的 done/notListening 回調看到的
          // 不再是 listening，不會把狀態拉回 idle 重啟聆聽（重疊回合）
          setState(() {
            _micState = _MicState.thinking;
            _statusText = L.get('call_thinking');
          });
          _sendToAI(text);
        }
      },
      onSoundLevelChange: (db) {
        // 音波只反映角色（TTS 播放）的聲音，不再被你自己的麥克風帶動。
        // 錄音時保持平靜，char 開口才起伏。
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: _sttLocale,
        listenMode: stt.ListenMode.dictation,
        listenFor: Duration(seconds: auto ? 120 : 60),
        pauseFor: Duration(milliseconds: auto ? 2200 : 3000),
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  void _onSttDone() {
    if (!mounted || _popped) return;
    _sttStopFallback?.cancel();
    _sttStopFallback = null;
    if (_currentTranscript.trim().isNotEmpty) {
      final text = _finalizePunc(_currentTranscript);
      _currentTranscript = '';
      // 同步進 thinking（同 onResult 的 finalResult 路徑）：
      // 防第二個 status 回調把狀態拉回 idle 造成重疊聆聽
      setState(() {
        _micState = _MicState.thinking;
        _statusText = L.get('call_thinking');
      });
      _sendToAI(text);
    } else if (_micState == _MicState.listening) {
      setState(() {
        _micState = _MicState.idle;
        _statusText = _micMode == 'auto' ? _idleHint() : L.get('call_no_hear');
        _level.value = 0;
      });
      _maybeRestartAutoListen();
    }
  }

  // ── 按住說話 ──
  Future<void> _onMicDown() async {
    await _bootstrapFuture;
    if (!mounted || _popped || !_bootstrapReady) return;
    if (!_speechAvailable || _micState == _MicState.thinking) return;
    if (_micState == _MicState.listening) return; // 重複按下
    if (_micState == _MicState.speaking) _interrupt();
    _sttStopFallback?.cancel();
    // 上一段還沒完全停：先停乾淨再開，否則 listen() 會 error_busy
    if (_speech.isListening) {
      await _speech.stop();
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted || _micState == _MicState.thinking) return;
    }
    setState(() {
      _micState = _MicState.listening;
      _currentTranscript = '';
      _statusText = L.get('call_listening');
    });
    _listen(auto: false);
  }

  void _onMicUp() {
    if (_micState != _MicState.listening) return;
    _speech.stop(); // onStatus:'done'/'notListening' → _onSttDone
    // 回調失蹤保底：1.5s 沒等到就強制收尾，按鍵不再卡死
    _sttStopFallback?.cancel();
    _sttStopFallback = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && !_popped && _micState == _MicState.listening) {
        _onSttDone();
      }
    });
  }

  // ── 自動聆聽 ──
  void _startAutoListen() {
    if (!mounted ||
        _popped ||
        !_bootstrapReady ||
        !_speechAvailable ||
        _muted ||
        _micMode != 'auto' ||
        _phase != _CallPhase.inCall) {
      return;
    }
    if (_micState == _MicState.thinking || _micState == _MicState.speaking) {
      return;
    }
    setState(() {
      _micState = _MicState.listening;
      _currentTranscript = '';
      _statusText = L.get('call_listening');
    });
    _listen(auto: true);
  }

  void _maybeRestartAutoListen() {
    _autoListenRestartTimer?.cancel();
    if (_micMode == 'auto' && !_muted && mounted && !_popped) {
      _autoListenRestartTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted && !_popped && _micState == _MicState.idle) {
          _startAutoListen();
        }
      });
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    HapticFeedback.selectionClick();
    if (_muted) {
      _speech.stop();
      if (_micState == _MicState.listening) {
        setState(() {
          _micState = _MicState.idle;
          _statusText = L.get('call_muted');
          _level.value = 0;
        });
      } else {
        setState(() => _statusText = L.get('call_muted'));
      }
    } else {
      setState(() => _statusText = _idleHint());
      _startAutoListen();
    }
  }

  Future<void> _toggleMicMode() async {
    final next = _micMode == 'hold' ? 'auto' : 'hold';
    await TtsSettings.saveCallMicMode(next);
    if (!mounted) return;
    setState(() {
      _micMode = next;
      _muted = false;
      _statusText = _idleHint();
    });
    HapticFeedback.selectionClick();
    if (next == 'auto') {
      _startAutoListen();
    } else {
      _speech.stop();
      if (_micState == _MicState.listening) {
        setState(() => _micState = _MicState.idle);
      }
    }
  }

  void _cycleSttLocale() {
    final next = TtsSettings.nextSttLocale(_sttLocale);
    setState(() => _sttLocale = next);
    TtsSettings.saveSttLocale(next);
  }

  // ═══════════════ LLM + TTS 流水線 ═══════════════

  // 通話內部標籤剝離（流式安全）
  static final _completedTagRe = RegExp(
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|think|thinking|search_chat|call|tool_calls?)\b[^>]*>'
    r'[\s\S]*?'
    r'</\1>',
    multiLine: true,
  );
  static final _selfClosingTagRe = RegExp(
    r'<(scratch|transfer|transfer_accept|transfer_decline|call)\b[^>]*/>',
  );
  static final _openTagRe = RegExp(r'<[a-z_]*(\s[^>]*)?$');

  String _filterStream(String raw) {
    var text = raw
        .replaceAll(_completedTagRe, '')
        .replaceAll(_selfClosingTagRe, '');
    // 截掉可能正在輸出中的半截標籤
    final open = _openTagRe.firstMatch(text);
    if (open != null) text = text.substring(0, open.start);
    // 保守：任何殘留 '<' 之後的內容先扣住不發
    final lt = text.indexOf('<');
    if (lt != -1) text = text.substring(0, lt);
    return text;
  }

  Future<void> _sendToAI(String userText) async {
    final normalized = userText.trim();
    if (normalized.isEmpty || _sendingUserTurn || _popped) return;
    // 鎖必須在第一個 await 之前同步取得，否則兩個近乎同時的觸發源
    // （onResult finalResult 與 onStatus done）都能通過上面的檢查
    _sendingUserTurn = true;
    try {
      await _bootstrapFuture;
      if (!mounted || _popped || !_bootstrapReady || _bootstrapFailed) return;
      _anyExchange = true;
      setState(() {
        _chatLog.add(_CallMessage(text: normalized, isUser: true));
        _level.value = 0;
      });
      _scrollLogToBottom();

      // 寫入主 DB
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: widget.conversationId,
          characterId: _characterId,
          text: normalized,
          isUser: true,
        ),
      );
      if (!mounted || _popped) return;
      await _generateTurn(userText: normalized);
    } finally {
      _sendingUserTurn = false;
    }
  }

  Future<void> _generateTurn({String? userText, String? hiddenNote}) async {
    if (!mounted || _popped || !_bootstrapReady) return;
    final serial = ++_turnSerial;
    setState(() {
      _micState = _MicState.thinking;
      // 撥號階段（對方還沒接）顯示「正在撥號」，別露出「思考中」
      _statusText = _phase == _CallPhase.dialing
          ? (L.pick(en: 'Dialing…', zhTW: '正在撥號'))
          : L.get('call_thinking');
    });

    if (userText != null) {
      _appendCallHistory('user', userText);
    }

    SentenceTtsPipeline? turnPipeline;
    VoidCallback? amplitudeListener;
    try {
      final model = await ApiSettings.getModel();
      final providerName = await ApiSettings.getApiProviderName();
      final adapter = await ApiSettings.buildAdapter();
      final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');

      // 靜態前綴：優先用聊天傳入的同款 bundle（同 namespace，直接命中
      // 聊天已建緩存；emotion ability 等工具段已在 bundle 內，不重複加）。
      // 沒傳（保底）才退回舊自拼前綴——那個前綴獨立且體量常低於
      // 緩存門檻（Sonnet 1024 / Opus 4096），基本不會命中。
      final String staticPrompt;
      final String? profilePrompt;
      if (widget.staticPart?.isNotEmpty == true) {
        staticPrompt = widget.staticPart!;
        profilePrompt = widget.profilePart;
      } else {
        final baseSystemPrompt = await ApiSettings.getSystemPrompt();
        staticPrompt = [
          if (baseSystemPrompt.isNotEmpty) baseSystemPrompt,
          if (widget.cacheStaticSnapshot?.isNotEmpty == true)
            widget.cacheStaticSnapshot!,
          if (emotionEnabled) EmotionCoordinates.abilityPrompt(),
        ].join('\n\n');
        profilePrompt = null;
      }

      final dynamicParts = <String>[];
      final memoryPrompt = await Retriever.buildMemoryPrompt(
        mode: 'romance',
        currentMessage: userText ?? '',
        characterId: _characterId,
        windowId: widget.conversationId,
      );
      if (memoryPrompt.isNotEmpty) dynamicParts.add(memoryPrompt);
      if (emotionEnabled) {
        final emoState = await EmotionCoordinates.statePrompt(_characterId);
        if (emoState.isNotEmpty) dynamicParts.add(emoState);
      }

      // v3 才允許語音標籤，其他 TTS 模型明確禁用（不然標籤會被讀出來/漏顯示）
      final ttsProvider = await TtsSettings.getTtsProvider();
      final elModel = await TtsSettings.getTtsElevenlabsModel();
      final v3 = ttsProvider == 'elevenlabs' && elModel == 'eleven_v3';

      final structured = StructuredPrompt(
        staticPart: staticPrompt,
        profilePart: profilePrompt,
        dynamicPart: dynamicParts.join('\n\n'),
      );

      // ── 流水線就緒 ──
      final pipeline = SentenceTtsPipeline(
        characterId: _characterId,
        conversationId: widget.conversationId,
        conversationTitle: widget.characterName,
      );
      turnPipeline = pipeline;
      await pipeline.start();
      if (!mounted || _popped || serial != _turnSerial) {
        await pipeline.cancel();
        return;
      }

      final previousPipeline = _pipeline;
      if (previousPipeline != null && !identical(previousPipeline, pipeline)) {
        await previousPipeline.cancel();
      }
      _pipeline = pipeline;
      pipeline.onFirstAudio = () {
        if (mounted && serial == _turnSerial) {
          setState(() {
            _micState = _MicState.speaking;
            _statusText = L.get('call_speaking');
          });
        }
      };
      pipeline.onAudioFailure = () {
        if (mounted &&
            !_popped &&
            serial == _turnSerial &&
            identical(_pipeline, pipeline)) {
          _handlePoorSignal();
        }
      };
      // 播放振幅 → 聲波
      void levelSync() {
        if (_micState == _MicState.speaking || pipeline.speaking.value) {
          _level.value = pipeline.amplitude.level.value;
        }
      }

      amplitudeListener = levelSync;
      pipeline.amplitude.level.addListener(levelSync);

      // ── LLM 流式 → 過濾 → 切句餵 TTS ──
      // 空歷史保護：部分 provider 不接受空 messages
      final outgoing = List<Map<String, String>>.from(_callHistory);
      if (outgoing.isEmpty) {
        outgoing.add({'role': 'user', 'content': '（電話接通了）'});
      }

      final now = DateTime.now();
      final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
      final callInstructions = <String>[
        '【系統提示】',
        '現在時間：${now.year}年${now.month}月${now.day}日 週${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        '模式：語音通話中 — 口語化、簡短自然，像講電話。一句一句說，不要一大段。不要 markdown、不要動作描述或旁白，只說出口的話。',
        if (v3)
          '標記：可在句前加 [laughing], [sigh] 等英文標記控制語氣。'
        else
          '注意：不要輸出任何方括號標記（如 [sigh]）。',
        '通話結束：如果你不想聊了（例如去忙、或是生氣），請回覆 <hangup/> 主動掛斷。',
        ?hiddenNote,
        if (_firstIncomingTurn && hiddenNote == null) '（你主動打的電話，對方接了）',
      ].join('\n');

      if (outgoing.isNotEmpty && outgoing.last['role'] == 'user') {
        outgoing[outgoing.length - 1] = {
          'role': 'user',
          'content': '${outgoing.last['content']}\n\n$callInstructions',
        };
      } else {
        outgoing.add({'role': 'user', 'content': callInstructions});
      }
      _firstIncomingTurn = false;

      final rawBuf = StringBuffer();
      var emitted = 0;
      String filtered = '';
      await for (final chunk in adapter.sendMessageStream(
        messages: outgoing,
        model: model,
        structuredPrompt: structured,
      )) {
        if (serial != _turnSerial) {
          // 已被打斷/掛斷
          await pipeline.cancel();
          return;
        }
        rawBuf.write(chunk);
        final currentResponse = rawBuf.toString();

        if (_phase == _CallPhase.dialing &&
            (currentResponse.contains('<decline_call/>') ||
                currentResponse.contains('<decline_call>'))) {
          _declineUserCall();
          return;
        }

        if (_phase == _CallPhase.inCall &&
            (currentResponse.contains('<hangup/>') ||
                currentResponse.contains('<hangup>'))) {
          _endCall();
          return;
        }

        filtered = _filterStream(currentResponse);

        if (_phase == _CallPhase.dialing && filtered.trim().isNotEmpty) {
          _ringtone.stop(); // 接起 → 回鈴音立停
          _ringVibrateTimer?.cancel();
          if (mounted) {
            setState(() {
              _phase = _CallPhase.inCall;
              _statusText = L.get('call_speaking');
            });
          }
          _startCallTimer();
        }

        if (filtered.length > emitted) {
          pipeline.pushText(filtered.substring(emitted));
          emitted = filtered.length;
        }
      }

      final response = rawBuf.toString();
      if (!mounted || _popped || serial != _turnSerial) return;
      final processedResponse = emotionEnabled
          ? await EmotionCoordinates.processReply(
              response,
              characterId: _characterId,
            )
          : response;
      final rawDisplayText = _filterStream(processedResponse).trim();
      final cleanText = rawDisplayText
          .replaceAll(RegExp(r'\[[a-zA-Z0-9_]+\]'), '')
          .trim();

      if (!mounted || _popped || serial != _turnSerial) return;
      _appendCallHistory('assistant', processedResponse);

      // 緩存提示（通話內 chip + 消息 ⚡）
      final cacheRead = CacheStatsHelper.readTokens(providerName);
      final label = CacheStatsHelper.shortLabel(providerName);
      if (mounted && serial == _turnSerial) {
        setState(() {
          _cacheLabel = label;
          if (cleanText.isNotEmpty) {
            _chatLog.add(_CallMessage(text: cleanText, isUser: false));
          }
        });
        _scrollLogToBottom();
      }

      // 寫入主 DB（帶 cacheHit，聊天氣泡會顯示 ⚡）
      // 過濾掉所有語氣標籤 (例如 [laughing])，避免污染文字對話歷史
      if (cleanText.isNotEmpty) {
        await DatabaseHelper.insertMessage(
          Message(
            conversationId: widget.conversationId,
            characterId: _characterId,
            text: cleanText,
            isUser: false,
            cacheHit: cacheRead > 0,
          ),
        );
      }
      if (!mounted || _popped || serial != _turnSerial) return;

      // 記錄用量
      _tokenTracker.addEstimated(completion: response);
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        characterId: _characterId,
      );

      // 等音頻播完
      await pipeline.finish();

      if (!mounted || _popped || serial != _turnSerial) return;
      setState(() {
        _micState = _MicState.idle;
        _statusText = _muted ? L.get('call_muted') : _idleHint();
        _level.value = 0;
      });
      _maybeRestartAutoListen();
    } catch (e) {
      final failedPipeline = turnPipeline;
      if (failedPipeline != null) await failedPipeline.cancel();
      if (!mounted || _popped || serial != _turnSerial) return;
      setState(() {
        _micState = _MicState.idle;
        _statusText = L.get('call_error');
        _level.value = 0;
        _chatLog.add(
          _CallMessage(
            text:
                '⚠ ${e.toString().length > 60 ? '${e.toString().substring(0, 60)}…' : e}',
            isUser: false,
            isError: true,
          ),
        );
      });
      _scrollLogToBottom();
      _maybeRestartAutoListen();
    } finally {
      final pipeline = turnPipeline;
      final listener = amplitudeListener;
      if (pipeline != null && listener != null) {
        pipeline.amplitude.level.removeListener(listener);
      }
      if (pipeline != null && identical(_pipeline, pipeline)) {
        _pipeline = null;
      }
      pipeline?.dispose();
    }
  }

  /// 直接說一段話（來電開場白）
  Future<void> _speakDirect(String text) async {
    if (!mounted || _popped || !_bootstrapReady) return;
    final serial = ++_turnSerial;
    _anyExchange = true;
    _appendCallHistory('assistant', text);
    setState(() {
      _chatLog.add(_CallMessage(text: text, isUser: false));
    });
    _scrollLogToBottom();
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: widget.conversationId,
        characterId: _characterId,
        text: text,
        isUser: false,
      ),
    );
    if (!mounted || _popped || serial != _turnSerial) return;

    final pipeline = SentenceTtsPipeline(
      characterId: _characterId,
      conversationId: widget.conversationId,
      conversationTitle: widget.characterName,
    );
    VoidCallback? amplitudeListener;
    try {
      await pipeline.start();
      if (!mounted || _popped || serial != _turnSerial) {
        await pipeline.cancel();
        return;
      }
      final previousPipeline = _pipeline;
      if (previousPipeline != null && !identical(previousPipeline, pipeline)) {
        await previousPipeline.cancel();
      }
      _pipeline = pipeline;
      pipeline.onFirstAudio = () {
        if (mounted && serial == _turnSerial) {
          setState(() {
            _micState = _MicState.speaking;
            _statusText = L.get('call_speaking');
          });
        }
      };
      pipeline.onAudioFailure = () {
        if (mounted &&
            !_popped &&
            serial == _turnSerial &&
            identical(_pipeline, pipeline)) {
          _handlePoorSignal();
        }
      };
      void levelSync() => _level.value = pipeline.amplitude.level.value;
      amplitudeListener = levelSync;
      pipeline.amplitude.level.addListener(levelSync);
      pipeline.pushText(text);
      await pipeline.finish();
    } catch (e) {
      debugPrint('開場白播放失敗: $e');
      await pipeline.cancel();
    } finally {
      final listener = amplitudeListener;
      if (listener != null) {
        pipeline.amplitude.level.removeListener(listener);
      }
      if (identical(_pipeline, pipeline)) _pipeline = null;
      pipeline.dispose();
    }
    if (!mounted || _popped || serial != _turnSerial) return;
    setState(() {
      _micState = _MicState.idle;
      _statusText = _idleHint();
      _level.value = 0;
    });
  }

  /// 打斷當前播放（點頭像）
  void _interrupt() {
    if (_micState != _MicState.speaking) return;
    _turnSerial++;
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) unawaited(pipeline.cancel());
    HapticFeedback.lightImpact();
    setState(() {
      _micState = _MicState.idle;
      _statusText = _idleHint();
      _level.value = 0;
    });
    _maybeRestartAutoListen();
  }

  // ═══════════════ 結束 ═══════════════

  void _endCall() {
    HapticFeedback.mediumImpact();
    _finish(CallResult('ended', _elapsed, anyExchange: _anyExchange));
  }

  void _handlePoorSignal() {
    if (_endingForPoorSignal || _popped || !mounted) return;
    _endingForPoorSignal = true;
    _turnSerial++;
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) unawaited(pipeline.cancel());
    _speech.stop();
    HapticFeedback.mediumImpact();
    setState(() {
      _micState = _MicState.idle;
      _currentTranscript = '';
      _statusText = L.get('call_signal_lost');
      _level.value = 0;
    });
    _poorSignalFinishTimer?.cancel();
    _poorSignalFinishTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted || _popped) return;
      _finish(CallResult('signal_lost', _elapsed, anyExchange: _anyExchange));
    });
  }

  void _finish(CallResult result) {
    if (_popped || !mounted) return;
    _popped = true;
    _turnSerial++;
    _autoListenRestartTimer?.cancel();
    _poorSignalFinishTimer?.cancel();
    _sttStopFallback?.cancel();
    _durationTimer?.cancel();
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) unawaited(pipeline.cancel());
    _speech.stop();
    _stopRinging();
    Navigator.pop(context, result);
  }

  @override
  void dispose() {
    _turnSerial++;
    _sttStopFallback?.cancel();
    _autoListenRestartTimer?.cancel();
    _poorSignalFinishTimer?.cancel();
    _speech.stop();
    _stopRinging();
    final pipeline = _pipeline;
    _pipeline = null;
    pipeline?.dispose();
    _durationTimer?.cancel();
    _acceptPulse.dispose();
    _logScroll.dispose();
    _level.dispose();
    super.dispose();
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ═══════════════ UI ═══════════════

  @override
  Widget build(BuildContext context) {
    final ringing = _phase == _CallPhase.ringing;
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              YanciTheme.backgroundGradient[1],
              YanciTheme.backgroundGradient[2],
              YanciTheme.backgroundGradient[3],
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scaledBody = MediaQuery.textScalerOf(context).scale(14);
              final compact = constraints.maxHeight < 700 || scaledBody > 17;
              final veryCompact = constraints.maxHeight < 560;
              final content = Column(
                mainAxisSize: veryCompact ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  SizedBox(height: compact ? 8 : 20),
                  _buildHeader(ringing),
                  if (veryCompact)
                    const SizedBox(height: 8)
                  else
                    const Spacer(flex: 2),
                  GestureDetector(
                    onTap: _micState == _MicState.speaking ? _interrupt : null,
                    child: CallCenterVisual(
                      avatarPath: _avatarPath,
                      fallbackName: widget.characterName,
                      level: _level,
                      ringing: ringing,
                      avatarSize: compact ? 96 : 132,
                    ),
                  ),
                  if (veryCompact)
                    const SizedBox(height: 6)
                  else
                    const Spacer(flex: 2),
                  if (!ringing) ..._buildInCallMiddle(compact: compact),
                  SizedBox(height: compact ? 6 : 12),
                  ringing
                      ? _buildRingButtons(compact: compact)
                      : _buildInCallButtons(compact: compact),
                  SizedBox(height: compact ? 10 : 28),
                ],
              );
              if (!veryCompact) return content;
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: content,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool ringing) {
    final bool showStatus =
        ringing || (_statusText.isNotEmpty && _statusText != _idleHint());
    return Column(
      children: [
        Text(
          widget.characterName,
          style: YanciTheme.headingLarge.copyWith(fontSize: 24),
        ),
        const SizedBox(height: 6),
        // 狀態 + 計時（≥13sp、對比拉高）
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!ringing)
              Text(
                _durationText,
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.85),
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            if (!ringing && showStatus)
              Text(
                '  ·  ',
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
              ),
            if (showStatus)
              Text(
                _statusText == _idleHint() ? '' : _statusText,
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.85),
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (!ringing)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _chip(
                label: TtsSettings.sttLocaleName(_sttLocale),
                onTap: _cycleSttLocale,
              ),
              if (_cacheLabel != null) ...[
                const SizedBox(width: 10),
                Text(
                  _cacheLabel!.replaceAll('cache ', ''),
                  style: TextStyle(
                    fontSize: 12,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _chip({
    required String label,
    VoidCallback? onTap,
    bool accent = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: YanciTheme.accent.withValues(alpha: accent ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: YanciTheme.accent.withValues(alpha: 0.22),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: YanciTheme.accent.withValues(alpha: 0.95),
            letterSpacing: 0.3,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInCallMiddle({required bool compact}) {
    return [
      // 閒置提示：按著麥克風說話
      if (_statusText == _idleHint() && _currentTranscript.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
          child: Text(
            _idleHint(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textSecondary.withValues(alpha: 0.6),
            ),
          ),
        ),
      // 即時識別文字
      if (_currentTranscript.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
          child: Text(
            _currentTranscript,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: YanciTheme.bodyText.copyWith(
              color: YanciTheme.textPrimary.withValues(alpha: 0.75),
              fontSize: 14,
            ),
          ),
        ),
      // 字幕開關
      Semantics(
        button: true,
        label: L.get('call_log'),
        child: GestureDetector(
          onTap: () => setState(() => _logExpanded = !_logExpanded),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _logExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  size: 18,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 4),
                Text(
                  _logExpanded
                      ? (L.pick(en: 'Hide', zhTW: '收起'))
                      : (L.pick(en: 'Subtitles', zhTW: '字幕')),
                  style: TextStyle(
                    fontSize: 12,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_logExpanded)
        Container(
          height: compact ? 76 : 132,
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? Colors.black.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(16),
          ),
          child: _chatLog.isEmpty
              ? Center(
                  child: Text(
                    L.get('call_log'),
                    style: TextStyle(
                      fontSize: 12,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _logScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _chatLog.length,
                  itemBuilder: (_, i) => _buildLogItem(_chatLog[i]),
                ),
        ),
    ];
  }

  // ── 來電按鈕列：拒接（紅）← → 接聽（綠，脈動）──
  // 接聽後：接聽鍵淡出，紅鍵滑到中央變掛斷
  Widget _buildRingButtons({required bool compact}) {
    final red = CallPalette.hangupRed;
    final green = CallPalette.answerGreen;
    return SizedBox(
      height: compact ? 96 : 118,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 拒接/掛斷（紅）：接聽後滑到中央
          AnimatedAlign(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            alignment: _accepted ? Alignment.center : const Alignment(-0.55, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CallActionButton(
                  icon: Icons.call_end_rounded,
                  color: red,
                  size: compact ? 58 : 68,
                  semanticLabel: L.get('call_hangup'),
                  onTap: _accepted ? _endCall : _declineCall,
                ),
                const SizedBox(height: 8),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _accepted ? 0 : 1,
                  child: Text(
                    L.get('call_hangup'),
                    style: TextStyle(
                      fontSize: 12,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 接聽（綠，響鈴時脈動）：接聽後縮小淡出
          AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            alignment: const Alignment(0.55, 0),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 280),
              scale: _accepted ? 0.0 : 1.0,
              curve: Curves.easeInBack,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: _accepted ? 0 : 1,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ScaleTransition(
                      scale: _acceptPulse,
                      child: CallActionButton(
                        icon: Icons.call_rounded,
                        color: green,
                        size: compact ? 58 : 68,
                        semanticLabel: L.get('call_accept'),
                        onTap: _acceptCall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      L.get('call_accept'),
                      style: TextStyle(
                        fontSize: 12,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 通話中按鈕列 ──
  // 上排：模式切換 ｜ 麥克風 ｜ 靜音（自動模式）
  // 下排：掛斷（紅，居中）
  Widget _buildInCallButtons({required bool compact}) {
    final red = CallPalette.hangupRed;
    final listening = _micState == _MicState.listening;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 模式切換
            CallActionButton(
              icon: _micMode == 'auto'
                  ? Icons.graphic_eq_rounded
                  : Icons.touch_app_rounded,
              color: YanciTheme.accent,
              outlined: true,
              size: 52,
              semanticLabel: _micMode == 'auto'
                  ? L.get('call_mode_auto')
                  : L.get('call_mode_hold'),
              onTap: _toggleMicMode,
            ),
            SizedBox(width: compact ? 16 : 24),
            // 麥克風主鍵
            if (_micMode == 'hold')
              // Listener 而非 GestureDetector：指針事件不進手勢競技場，
              // 手指微滑不會被判 tapCancel，長按多久都不會失效
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _onMicDown(),
                onPointerUp: (_) => _onMicUp(),
                onPointerCancel: (_) => _onMicUp(),
                child: Semantics(
                  button: true,
                  label: L.get('call_mode_hold'),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: listening ? 78 : 70,
                    height: listening ? 78 : 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: listening
                          ? YanciTheme.accent
                          : YanciTheme.accent.withValues(alpha: 0.14),
                      border: Border.all(
                        color: YanciTheme.accent.withValues(
                          alpha: listening ? 0.9 : 0.4,
                        ),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                      size: 30,
                      color: listening
                          ? Colors.white
                          : YanciTheme.accent.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              )
            else
              // 自動模式：靜音鍵為主鍵
              CallActionButton(
                icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                color: _muted ? YanciTheme.textSecondary : YanciTheme.accent,
                outlined: !listening && !_muted,
                size: compact ? 60 : 70,
                semanticLabel: _muted
                    ? L.get('call_unmute')
                    : L.get('call_mute'),
                onTap: _toggleMute,
              ),
            SizedBox(width: compact ? 16 : 24),
            // 佔位對稱（保持麥克風真正居中）
            const SizedBox(width: 52, height: 52),
          ],
        ),
        SizedBox(height: compact ? 10 : 22),
        CallActionButton(
          icon: Icons.call_end_rounded,
          color: red,
          size: compact ? 56 : 64,
          semanticLabel: L.get('call_hangup'),
          onTap: _endCall,
        ),
      ],
    );
  }

  Widget _buildLogItem(_CallMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 20),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: msg.isError
                  ? CallPalette.hangupRed.withValues(alpha: 0.14)
                  : msg.isUser
                  ? YanciTheme.userBubble.withValues(alpha: 0.35)
                  : YanciTheme.accent.withValues(alpha: 0.14),
            ),
            child: Text(
              msg.isUser ? L.get('call_pronoun_me') : L.get('call_pronoun_her'),
              style: TextStyle(
                fontSize: 10,
                color: msg.isUser
                    ? YanciTheme.textSecondary
                    : YanciTheme.accent,
              ),
            ),
          ),
          Expanded(
            child: Text(
              msg.isUser ? msg.text : TtsService.extractSpeechContent(msg.text),
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                fontFamily: YanciTheme.fontFamily,
                color: msg.isError
                    ? CallPalette.hangupRed.withValues(alpha: 0.85)
                    : YanciTheme.textPrimary.withValues(
                        alpha: msg.isUser ? 0.65 : 0.85,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CallMessage {
  final String text;
  final bool isUser;
  final bool isError;
  _CallMessage({
    required this.text,
    required this.isUser,
    this.isError = false,
  });
}
