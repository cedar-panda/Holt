import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
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
import '../services/asr_vocabulary_service.dart';
import '../services/local_asr_service.dart';
import '../services/call_prompt_composer.dart';
import '../services/deferred_prompt.dart';
import '../services/bio_clock_service.dart';
import '../services/prompt_cache_channels.dart';
import '../models/chat_session_identity.dart';
import '../services/cache_stats_helper.dart';
import '../memory/retriever.dart';
import '../services/rp_memory_service.dart';
import '../models/context_mode.dart';
import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import '../models/message.dart';
import '../models/background_preset.dart';
import '../services/background_preset_service.dart';
import '../services/background_foreground_service.dart';
import '../widgets/call_visual.dart';
import '../widgets/ambient_particles.dart';
import '../widgets/gradient_background.dart';
import '../services/user_persona_service.dart';
import '../services/speech_locale_resolver.dart';
import '../services/model_action_protocol.dart';
import '../services/model_stream_decoder.dart';
import '../services/mood_glow_service.dart';
import '../services/rp_identity_lock_prompt.dart';
import '../services/call_audio_route_service.dart';

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
  final String? windowPart;
  final List<Map<String, String>> initialHistory;

  const CallScreen({
    super.key,
    required this.characterName,
    required this.conversationId,
    this.incoming = false,
    this.openingLine = '',
    this.cacheStaticSnapshot,
    this.staticPart,
    this.profilePart,
    this.windowPart,
    this.initialHistory = const <Map<String, String>>[],
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

  /// 剛送出的那句：思考中繼續顯示，讓你知道自己說了什麼。
  String _submittedTranscript = '';
  String _liveCharacterCaption = '';

  /// 本輪是否已改由「正在播放的句子」驅動字幕。開播前（或 TTS 失敗時）
  /// 仍沿用生成進度的最新一句；一旦有聲音，就只跟著聲音走。
  bool _captionFollowsAudio = false;

  /// 本輪預期會出聲、但聲音還沒開始：字幕保持空白，不先把文字跑一遍。
  /// TTS 設定錯誤或整輪沒出聲時才退回顯示文字。
  bool _captionWaitForAudio = false;

  // ── 自動聆聽：別在使用者剛開口時把 session 切掉 ──
  /// 最近一次麥克風音量像人聲的時間。辨識結果有延遲（尤其 Apple Speech），
  /// 只看「有沒有文字」會在使用者剛開口時誤判沒人說話而輪換 session，
  /// 開頭那半句就掉了。
  DateTime? _lastVoiceLikeSoundAt;
  DateTime? _autoListenStartedAt;

  static const double _voiceLikeLevel = 0.45;
  // 自動聆聽一次開久一點：Apple 單次辨識上限約 1 分鐘，留 10 秒餘量。
  // 舊值（6 秒輪換＋2.2 秒 pauseFor）讓安靜時每兩三秒就斷一次重開，
  // 重開的空檔說的話會漏。說完一句仍由 _autoSpeechSilenceTimer 1.35 秒送出。
  static const Duration _autoNoSpeechRotate = Duration(seconds: 50);
  static const Duration _autoListenFor = Duration(seconds: 58);
  static const Duration _autoPauseFor = Duration(seconds: 50);

  /// 自動模式：最後一個字之後安靜這麼久才送出（昭昭定 2 秒）。
  /// 中途辨識器自己斷句（final／done）只接續，不送出。
  static const Duration _autoSendAfterSilence = Duration(seconds: 2);

  /// 安靜輪換時不閃「準備聆聽…」／待機提示，畫面保持「聆聽中」。
  bool _quietRelisten = false;
  static const Duration _autoRotateVoiceGrace = Duration(milliseconds: 1500);
  static const Duration _autoRotateRecheck = Duration(seconds: 1);
  static const Duration _autoRotateMaxDeferral = Duration(seconds: 30);
  Timer? _captionLineTimer;

  String _characterId = 'default';
  String _promptCharacterName = '';

  /// 通話「常用詞彙」（每個角色一份）；角色名字另外自動算進去。
  List<String> _asrVocab = const [];

  /// 粵語模式不校正：比對用的是普通話拼音，粵語讀音對不上，會越改越錯。
  bool get _asrVocabSupported => _sttLocale != 'zh_HK';
  Iterable<String> get _asrTerms => _asrVocabSupported
      ? [_promptCharacterName, ..._asrVocab]
      : const <String>[];
  String _userPersonaName = '';
  String? _avatarPath;
  BackgroundPreset? _callBackgroundPreset;
  String _callBackgroundScope = 'none';
  BackgroundForegroundPalette? _callForeground;
  String _sttLocale = 'zh_TW';

  /// 目前 TTS 來源唸不唸得出粵語（決定語言選單有沒有粵語）。
  bool _cantoneseAvailable = false;
  String _micMode = 'hold'; // 'hold' | 'auto'
  bool _naturalCall = true;
  bool _muted = false;
  bool _speechAvailable = false;
  bool _localAsrAvailable = false;
  List<String> _speechLocaleIds = const [];
  StreamSubscription<String>? _localAsrSubscription;
  bool _popped = false;
  bool _endingForPoorSignal = false;
  String? _ttsConfigurationError;
  ApiAdapter? _activeAdapter;

  final List<Map<String, String>> _callHistory = [];
  final List<_CallMessage> _chatLog = [];
  static const int _maxCallHistoryEntries = 500;
  bool _captionsEnabled = true;
  final TokenTracker _tokenTracker = TokenTracker();

  // 通話計時
  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;
  bool _anyExchange = false;

  // 聲波振幅（speaking 時來自 SoLoud，listening 時來自 STT soundLevel）
  final ValueNotifier<double> _level = ValueNotifier(0.0);
  final ValueNotifier<double> _userMicLevel = ValueNotifier(0.0);

  // TTS 流水線（每輪一條）
  SentenceTtsPipeline? _pipeline;
  int _turnSerial = 0;
  late final Future<void> _bootstrapFuture;
  bool _bootstrapReady = false;
  bool _bootstrapFailed = false;
  bool _sendingUserTurn = false;
  String? _pendingUserText;

  // 來電
  final RingtonePlayer _ringtone = RingtonePlayer();
  Timer? _ringVibrateTimer;
  Timer? _ringEchoTimer;
  Timer? _ringTimeoutTimer;
  Timer? _autoListenRestartTimer;
  Timer? _poorSignalFinishTimer;
  late final AnimationController _acceptPulse;
  bool _accepted = false; // 接聽動畫觸發
  ChatSessionIdentity? _sessionIdentity;

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
  // Apple Speech 在 stop() 後可能先發 done/notListening，最後一筆
  // onResult 才稍後抵達。保留一個很短的收尾窗口，避免把有效錄音判成空白。
  Timer? _appleSpeechFinalGrace;
  // 按住模式的實際指針狀態。Android SpeechRecognizer 仍可能因停頓
  // 結束一個 session；只要手指還按著，就自動接續而不提交。
  bool _micPressed = false;
  bool _captureFinalized = false;
  String _heldTranscript = '';
  String _activeTranscript = '';
  Timer? _holdRestartTimer;
  Timer? _autoNoSpeechTimer;
  Timer? _autoSpeechSilenceTimer;

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
      final sessionIdentity = ChatSessionIdentity.fromConversation(
        expectedConversationId: widget.conversationId,
        conversation: conv,
      );
      final cid = sessionIdentity.characterId;
      final char = await DatabaseHelper.getCharacter(cid);
      final persona = await UserPersonaService.personaForConversation(conv!);
      final storedCharacterName = char?['name']?.toString().trim() ?? '';
      final promptCharacterName = storedCharacterName.isNotEmpty
          ? storedCharacterName
          : widget.characterName.trim();
      final userPersonaName = persona.displayName.trim().isNotEmpty
          ? persona.displayName.trim()
          : L.pick(en: 'the user role', zhTW: '當前 user 角色', zhCN: '当前 user 角色');
      final backgroundPreset =
          await BackgroundPresetService.boundPresetForCharacter(cid) ??
          await BackgroundPresetService.loadSlot(
            await BackgroundPresetService.getActiveSlot(),
          );
      final callBackgroundScope = backgroundPreset.callBackgroundScope;
      final callBackgroundPath = callBackgroundScope == 'home'
          ? backgroundPreset.homePath
          : callBackgroundScope == 'chat'
          ? backgroundPreset.chatPath
          : '';
      final callForeground = callBackgroundPath.isEmpty
          ? null
          : await BackgroundForegroundService.resolve(callBackgroundPath);
      final cantoneseAvailable = TtsSettings.supportsCantonese(
        provider: await TtsSettings.getTtsProvider(),
        elevenlabsModel: await TtsSettings.getTtsElevenlabsModel(),
      );
      final locale = TtsSettings.effectiveSttLocale(
        await TtsSettings.getSttLocale(),
        cantonese: cantoneseAvailable,
      );
      final micMode = await TtsSettings.getCallMicMode();
      final naturalCall = await TtsSettings.getCallNaturalMode();
      final asrVocab = await AsrVocabularyService.load(cid);
      if (!mounted || _popped) return;
      _sessionIdentity = sessionIdentity;
      CacheSession.bind(sessionIdentity);
      unawaited(
        MoodGlowService.bindConversation(
          widget.conversationId,
          mode: sessionIdentity.contextMode,
        ),
      );
      setState(() {
        _characterId = cid;
        _promptCharacterName = promptCharacterName;
        _userPersonaName = userPersonaName;
        _avatarPath = char?['avatar_path'] as String?;
        _callBackgroundPreset = backgroundPreset;
        _callBackgroundScope = callBackgroundScope;
        _callForeground = callForeground;
        _sttLocale = locale;
        _cantoneseAvailable = cantoneseAvailable;
        _micMode = micMode;
        _naturalCall = naturalCall;
        _asrVocab = asrVocab;
      });

      // 優先沿用文字窗口的有效錨點歷史，讓 text/call 兩條 cache 都建立在
      // 同一條 append-only messages 上。獨立開啟 CallScreen 才走 DB 保底。
      final recent = widget.initialHistory.isNotEmpty
          ? widget.initialHistory
                .map((message) => Map<String, String>.from(message))
                .toList(growable: false)
          : await CallContextLoader.recentHistory(
              widget.conversationId,
              limit: _maxCallHistoryEntries,
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

  String _idleHint() {
    if (_ttsConfigurationError != null) {
      return L.pick(en: 'Voice output is not configured', zhTW: '尚未設定語音輸出');
    }
    return _micMode == 'auto' ? L.get('call_auto_hint') : L.get('call_hold');
  }

  String get _recognizerLocale {
    final appleSpeech =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    return SpeechLocaleResolver.resolve(
      configuredLocale: _sttLocale,
      availableLocaleIds: _speechLocaleIds,
      preferAppleStyle: appleSpeech,
    );
  }

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
      hiddenUserEvent: CallPromptComposer.dialToCharacterAction,
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

    // 開場白：標籤裡帶了就直接說，沒帶就讓她自己開口
    final opening = widget.openingLine.trim();
    if (opening.isNotEmpty) {
      await _recordHiddenUserEvent(
        CallPromptComposer.acceptCharacterCallAction,
      );
      if (!mounted || _popped) return;
      await _speakDirect(opening);
      if (_micMode == 'auto' && mounted) _startAutoListen();
    } else {
      await _generateTurn(
        userText: null,
        hiddenUserEvent: CallPromptComposer.acceptCharacterCallAction,
      );
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
    // speech_to_text 7.4.0 only requests Android 12+ BLUETOOTH_CONNECT when
    // RECORD_AUDIO is also missing. Existing users usually granted the mic
    // earlier, so ask for the Bluetooth permission explicitly before STT init.
    await CallAudioRouteService.ensureBluetoothPermission();

    // iOS 使用 Apple Speech。App 內的 Sherpa-ONNX 僅供 Android 的
    // 按住說話模式使用，避免 iOS 誤走本地模型而無法辨識。
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        if (!LocalAsrService.instance.isInitialized) {
          if (mounted && !_popped) {
            setState(
              () => _statusText = L.pick(
                en: 'Preparing local voice model…',
                zhTW: '正在準備本機中文語音模型…',
              ),
            );
          }
          _localAsrAvailable = await LocalAsrService.instance.initialize(
            onProgress: (percent) {
              if (!mounted || _popped) return;
              setState(
                () => _statusText = L.pick(
                  en: 'Preparing local voice model $percent%…',
                  zhTW: '正在準備本機中文語音模型 $percent%…',
                ),
              );
            },
          );
        } else {
          _localAsrAvailable = true;
        }
      } catch (error) {
        _localAsrAvailable = false;
        debugPrint('Local ASR init failed: $error');
      }
    } else {
      _localAsrAvailable = false;
    }

    // iOS 的按住說話與自動聆聽都使用 Apple Speech；Android 自動聆聽
    // 仍使用系統引擎，按住說話則優先使用上面的本地引擎。
    try {
      _speechAvailable = await _speech.initialize(
        onError: (error) {
          debugPrint('STT 錯誤: ${error.errorMsg}');
          if (!mounted || _popped) return;
          _appleSpeechFinalGrace?.cancel();
          _appleSpeechFinalGrace = null;
          if (_micMode == 'hold' && _micPressed && !error.permanent) {
            _commitActiveTranscript();
            setState(() => _statusText = L.get('call_listening'));
            _scheduleHoldRestart();
            return;
          }
          if (error.permanent) {
            _micPressed = false;
            _holdRestartTimer?.cancel();
          }
          if (_micState == _MicState.listening) {
            if (_hasCapturedTranscript) {
              _submitCapturedTranscript();
            } else {
              setState(() {
                _micState = _MicState.idle;
                _statusText = L.get('call_stt_error');
              });
              _maybeRestartAutoListen();
            }
          }
        },
        onStatus: (status) {
          // 辨識器真的開始收音才顯示「聆聽中」（之前是「準備聆聽…」）。
          if (status == 'listening' && mounted && !_popped) {
            if (_micState == _MicState.listening && _micMode == 'auto') {
              setState(() => _statusText = L.get('call_listening'));
            }
          }
          // Android 上引擎結束常只發 'notListening' 不發 'done'——
          // 只等 done 會讓按鍵永遠卡在 listening
          if ((status == 'done' || status == 'notListening') &&
              mounted &&
              !_popped) {
            _handleSttTerminalStatus();
          }
        },
      );
      if (_speechAvailable) {
        try {
          _speechLocaleIds = (await _speech.locales())
              .map((locale) => locale.localeId)
              .toList(growable: false);
          debugPrint('STT locale resolved: $_recognizerLocale');
        } catch (error) {
          _speechLocaleIds = const [];
          debugPrint('STT locale lookup failed: $error');
        }
      }
      if (!_speechAvailable && mounted) {
        if (!_localAsrAvailable) {
          setState(() => _statusText = L.get('call_stt_unavailable'));
        }
      }
    } catch (_) {
      if (mounted && !_localAsrAvailable) {
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

  bool get _hasCapturedTranscript =>
      _heldTranscript.trim().isNotEmpty || _activeTranscript.trim().isNotEmpty;

  String _joinTranscript(String left, String right) {
    final a = left.trim();
    final b = right.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final needsSpace =
        RegExp(r'[A-Za-z0-9]$').hasMatch(a) &&
        RegExp(r'^[A-Za-z0-9]').hasMatch(b);
    return needsSpace ? '$a $b' : '$a$b';
  }

  void _commitActiveTranscript() {
    if (_activeTranscript.trim().isEmpty) return;
    _heldTranscript = _joinTranscript(_heldTranscript, _activeTranscript);
    _activeTranscript = '';
    _currentTranscript = _heldTranscript;
  }

  void _clearCapturedTranscript() {
    _heldTranscript = '';
    _activeTranscript = '';
    _currentTranscript = '';
  }

  void _submitCapturedTranscript() {
    if (_captureFinalized) return;
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
    _appleSpeechFinalGrace?.cancel();
    _appleSpeechFinalGrace = null;
    final text = _finalizePunc(
      _joinTranscript(_heldTranscript, _activeTranscript),
    );
    _clearCapturedTranscript();
    _userMicLevel.value = 0;
    if (text.isEmpty) return;
    _submittedTranscript = text;
    _captureFinalized = true;
    setState(() {
      _micState = _MicState.thinking;
      _statusText = L.get('call_thinking');
    });
    _sendToAI(text);
  }

  void _scheduleHoldRestart() {
    _holdRestartTimer?.cancel();
    if (!mounted || _popped || !_micPressed || _micMode != 'hold') return;
    _holdRestartTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || _popped || !_micPressed || _micMode != 'hold') return;
      if (_micState != _MicState.listening) return;
      if (_speech.isListening) {
        _scheduleHoldRestart();
        return;
      }
      unawaited(_listen(auto: false));
    });
  }

  Future<void> _startLocalListen() async {
    await _localAsrSubscription?.cancel();
    try {
      await CallAudioRouteService.activateBluetoothMicrophone();
      final stream = await LocalAsrService.instance.startRecognition();
      if (!mounted || _popped || !_micPressed) {
        await LocalAsrService.instance.cancelRecognition();
        await CallAudioRouteService.releaseBluetoothMicrophone();
        return;
      }
      _localAsrSubscription = stream.listen(
        (text) {
          if (!mounted || _popped || _captureFinalized) return;
          final display = AsrVocabularyService.correct(
            _withPausePunc(text),
            _asrTerms,
          );
          _activeTranscript = display;
          setState(() {
            _currentTranscript = _joinTranscript(_heldTranscript, display);
          });
          _userMicLevel.value = display.trim().isEmpty ? 0.12 : 0.26;
        },
        onError: (error) {
          debugPrint('Local ASR error: $error');
          if (!mounted || _popped || !_micPressed) return;
          setState(() => _statusText = L.get('call_stt_error'));
        },
        onDone: () {
          _userMicLevel.value = 0;
          _localAsrSubscription = null;
          unawaited(CallAudioRouteService.releaseBluetoothMicrophone());
          _onSttDone();
        },
        cancelOnError: true,
      );
    } catch (error) {
      await CallAudioRouteService.releaseBluetoothMicrophone();
      debugPrint('Local ASR start failed: $error');
      if (!mounted || _popped) return;
      setState(() {
        _micState = _MicState.idle;
        _statusText = L.get('call_stt_error');
      });
    }
  }

  Future<void> _listen({required bool auto}) async {
    if (!mounted || _popped || !_bootstrapReady) return;
    _resetPunctuation();
    if (_localAsrAvailable && _micMode == 'hold' && !auto) {
      await _startLocalListen();
      return;
    }
    if (!_speechAvailable) return;
    // iOS：每次開始聽之前重新確認 playAndRecord + 藍牙（Android 為 no-op）。
    // speech_to_text 停止時會還原它開始前記下的 category，所以這裡設好，
    // 收音結束後播放也會留在藍牙通話通道。
    await CallAudioRouteService.configureCallAudioSession();
    try {
      await _speech.listen(
        onResult: (result) {
          if (!mounted || _popped || _captureFinalized) return;
          final display = AsrVocabularyService.correct(
            _withPausePunc(result.recognizedWords),
            _asrTerms,
          );
          _activeTranscript = display;
          setState(() {
            _currentTranscript = _joinTranscript(_heldTranscript, display);
          });
          if (auto && result.recognizedWords.trim().isNotEmpty) {
            // Ambient sound levels never count as speech. Only an actual ASR
            // transcript opens the send gate, then 5 s of silence after the
            // last recognised word submits the whole turn.
            _autoNoSpeechTimer?.cancel();
            _autoSpeechSilenceTimer?.cancel();
            _autoSpeechSilenceTimer = Timer(_autoSendAfterSilence, () {
              if (!mounted ||
                  _popped ||
                  _micMode != 'auto' ||
                  !_hasCapturedTranscript) {
                return;
              }
              unawaited(_speech.stop());
              _submitCapturedTranscript();
            });
          }
          if (result.finalResult) {
            if (_micMode == 'hold' && _micPressed) {
              // Android / iOS 都可能把停頓當成 final；手指仍按著時只接續，
              // 不把這一小段當成完整使用者回合送出。
              _commitActiveTranscript();
              _speech.stop();
              _scheduleHoldRestart();
            } else if (_hasCapturedTranscript) {
              _speech.stop();
              if (auto && _micMode == 'auto') {
                _continueAutoListen();
              } else {
                _submitCapturedTranscript();
              }
            }
          }
        },
        onSoundLevelChange: (db) {
          final normalized = ((db + 50) / 50).clamp(0.0, 1.0);
          _userMicLevel.value = _userMicLevel.value * 0.72 + normalized * 0.28;
          if (normalized >= _voiceLikeLevel) {
            _lastVoiceLikeSoundAt = DateTime.now();
          }
        },
        listenOptions: stt.SpeechListenOptions(
          localeId: _recognizerLocale,
          listenMode: stt.ListenMode.dictation,
          // 按住模式由鬆開事件控制；系統仍可能因 endpoint 結束單次
          // session，_onSttDone 會在手指未鬆開時接續。
          listenFor: auto ? _autoListenFor : null,
          pauseFor: auto ? _autoPauseFor : null,
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (error) {
      debugPrint('STT listen failed: $error');
      if (!mounted || _popped) return;
      _micPressed = false;
      _holdRestartTimer?.cancel();
      setState(() {
        _micState = _MicState.idle;
        _statusText = L.get('call_stt_error');
      });
    }
  }

  void _onSttDone() {
    if (!mounted || _popped) return;
    _appleSpeechFinalGrace?.cancel();
    _appleSpeechFinalGrace = null;
    _sttStopFallback?.cancel();
    _sttStopFallback = null;
    if (_micMode == 'hold' && _micPressed) {
      _commitActiveTranscript();
      _scheduleHoldRestart();
      return;
    }
    if (_hasCapturedTranscript) {
      if (_micMode == 'auto' &&
          !_captureFinalized &&
          _micState == _MicState.listening) {
        _continueAutoListen();
        return;
      }
      _submitCapturedTranscript();
    } else if (_micState == _MicState.listening) {
      final quiet = _micMode == 'auto' && !_muted;
      _quietRelisten = quiet;
      setState(() {
        _micState = _MicState.idle;
        if (!quiet) {
          _statusText = _micMode == 'auto'
              ? _idleHint()
              : L.get('call_no_hear');
        }
        _level.value = 0;
        _userMicLevel.value = 0;
      });
      _maybeRestartAutoListen();
    }
  }

  bool get _usesAppleSpeech =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  void _handleSttTerminalStatus() {
    if (_usesAppleSpeech &&
        _micMode == 'hold' &&
        !_micPressed &&
        _micState == _MicState.listening) {
      _appleSpeechFinalGrace?.cancel();
      _appleSpeechFinalGrace = Timer(
        const Duration(milliseconds: 450),
        _onSttDone,
      );
      return;
    }
    _onSttDone();
  }

  // ── 按住說話 ──
  Future<void> _onMicDown() async {
    await _bootstrapFuture;
    if (!mounted || _popped || !_bootstrapReady) return;
    if ((!_speechAvailable && !_localAsrAvailable) ||
        _micState == _MicState.thinking) {
      return;
    }
    if (_micState == _MicState.listening) return; // 重複按下
    if (_micState == _MicState.speaking) _interrupt();
    _micPressed = false;
    _holdRestartTimer?.cancel();
    _sttStopFallback?.cancel();
    _appleSpeechFinalGrace?.cancel();
    // 上一段還沒完全停：先停乾淨再開，否則 listen() 會 error_busy
    if (_speech.isListening || LocalAsrService.instance.isListening) {
      await _speech.stop();
      if (LocalAsrService.instance.isListening) {
        await LocalAsrService.instance.stopRecognition();
      }
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted || _micState == _MicState.thinking) return;
    }
    _micPressed = true;
    setState(() {
      _micState = _MicState.listening;
      _captureFinalized = false;
      _heldTranscript = '';
      _activeTranscript = '';
      _currentTranscript = '';
      _statusText = L.get('call_listening');
    });
    await _listen(auto: false);
  }

  void _onMicUp() {
    _micPressed = false;
    _holdRestartTimer?.cancel();
    if (_micState != _MicState.listening) return;
    if (_localAsrAvailable && LocalAsrService.instance.isListening) {
      // 本機 ASR 由放開手指明確結束；Stream 完成後進入同一個提交流程。
      unawaited(LocalAsrService.instance.stopRecognition());
    } else {
      unawaited(_speech.stop());
    }
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
      _captureFinalized = false;
      _heldTranscript = '';
      _activeTranscript = '';
      _currentTranscript = '';
      // 辨識器啟動（切換音訊 session）要幾百毫秒；真的開始收音前
      // 不顯示「聆聽中」，免得一看到就開口、開頭沒錄到。
      // 安靜輪換例外：畫面一直是「聆聽中」，不要閃。
      if (!_quietRelisten) {
        _statusText = L.pick(
          en: 'Getting ready…',
          zhTW: '準備聆聽…',
          zhCN: '准备聆听…',
        );
      }
    });
    _quietRelisten = false;
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
    _lastVoiceLikeSoundAt = null;
    _autoListenStartedAt = DateTime.now();
    _armAutoNoSpeechTimer(_autoNoSpeechRotate);
    unawaited(_listen(auto: true));
  }

  /// 很久沒聽到文字時輪換 session；但最近麥克風有像人聲的音量
  /// （使用者可能剛開口、辨識結果還沒回來）就先延後，最多延 30 秒。
  void _armAutoNoSpeechTimer(Duration delay) {
    _autoNoSpeechTimer?.cancel();
    _autoNoSpeechTimer = Timer(delay, () {
      if (!mounted ||
          _popped ||
          _micMode != 'auto' ||
          _micState != _MicState.listening ||
          _hasCapturedTranscript) {
        return;
      }
      final now = DateTime.now();
      final lastVoice = _lastVoiceLikeSoundAt;
      final startedAt = _autoListenStartedAt ?? now;
      if (lastVoice != null &&
          now.difference(lastVoice) < _autoRotateVoiceGrace &&
          now.difference(startedAt) < _autoRotateMaxDeferral) {
        _armAutoNoSpeechTimer(_autoRotateRecheck);
        return;
      }
      // A noisy room may keep the platform recognizer alive forever without
      // producing words. Rotate the session quietly instead of showing a
      // false "didn't hear" error or sending an empty turn.
      unawaited(_speech.stop());
      _quietRelisten = true;
      setState(() {
        _micState = _MicState.idle;
        _userMicLevel.value = 0;
      });
      _maybeRestartAutoListen();
    });
  }

  /// 辨識器自己斷句了但你還沒說完（安靜不到 5 秒）：保留已辨識的部分，
  /// 立刻接著聽。送出只由 _autoSpeechSilenceTimer 決定。
  void _continueAutoListen() {
    _commitActiveTranscript();
    _autoListenRestartTimer?.cancel();
    _autoListenRestartTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted ||
          _popped ||
          _muted ||
          _micMode != 'auto' ||
          _captureFinalized ||
          _micState != _MicState.listening ||
          _speech.isListening) {
        return;
      }
      unawaited(_listen(auto: true));
    });
  }

  void _maybeRestartAutoListen() {
    _autoListenRestartTimer?.cancel();
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
    if (_micMode == 'auto' && !_muted && mounted && !_popped) {
      _autoListenRestartTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted && !_popped && _micState == _MicState.idle) {
          _startAutoListen();
        }
      });
    }
  }

  void _toggleMute() {
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
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
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
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

  Future<void> _setNaturalCall(bool value) async {
    if (value == _naturalCall) return;
    setState(() => _naturalCall = value);
    HapticFeedback.selectionClick();
    await TtsSettings.saveCallNaturalMode(value);
  }

  Future<void> _setSttLocale(String locale) async {
    if (locale == _sttLocale) return;
    setState(() => _sttLocale = locale);
    await TtsSettings.saveSttLocale(locale);
    // 辨識語言只在 listen() 開始時讀一次。自動聆聽中途切換時，
    // 正在跑的 session 仍是舊語言，切完說的第一段會被舊辨識器吃掉。
    // 停掉它：_onSttDone 會用新語言接續（已聽到的字保留在 held 裡）。
    if (mounted && !_popped && _micMode == 'auto' && _speech.isListening) {
      await _speech.stop();
    }
  }

  // ═══════════════ LLM + TTS 流水線 ═══════════════

  // 通話最終文字與聊天、標題、TTS 共用同一個可見輸出邊界。
  // 流式階段仍由 ModelStreamDecoder 增量攔截；這一層負責攔住動作
  // 處理器之後才出現或格式略有差異的 <call> 等內部標籤。
  String _filterStream(String raw) => VisibleModelOutput.finalOnly(raw);

  Future<void> _sendToAI(String userText) async {
    final normalized = userText.trim();
    if (normalized.isEmpty || _popped) return;
    if (_sendingUserTurn) {
      // 按住模式鬆開時，上一輪可能還在取消/收尾；先排隊，
      // 不再讓辨識成功的文字靜默消失。
      _pendingUserText = normalized;
      return;
    }
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
      final pending = _pendingUserText;
      _pendingUserText = null;
      if (pending != null && mounted && !_popped) {
        unawaited(_sendToAI(pending));
      }
    }
  }

  Future<void> _generateTurn({
    String? userText,
    String? hiddenUserEvent,
  }) async {
    if (!mounted || _popped || !_bootstrapReady) return;
    final serial = ++_turnSerial;
    setState(() {
      _micState = _MicState.thinking;
      _liveCharacterCaption = '';
      _captionFollowsAudio = false;
      _captionWaitForAudio = _ttsConfigurationError == null;
      _captionLineTimer?.cancel();
      // 撥號階段（對方還沒接）顯示「正在撥號」，別露出「思考中」
      _statusText = _phase == _CallPhase.dialing
          ? (L.pick(en: 'Dialing…', zhTW: '正在撥號'))
          : L.get('call_thinking');
    });

    if (userText != null) {
      _appendCallHistory('user', userText);
    }
    if (hiddenUserEvent != null && hiddenUserEvent.trim().isNotEmpty) {
      await _recordHiddenUserEvent(hiddenUserEvent);
      if (!mounted || _popped || serial != _turnSerial) return;
    }

    SentenceTtsPipeline? turnPipeline;
    VoidCallback? amplitudeListener;
    ApiAdapter? turnAdapter;
    try {
      final model = await ApiSettings.getModel();
      final providerName = await ApiSettings.getApiProviderName();
      final adapter = await ApiSettings.buildAdapter();
      turnAdapter = adapter;
      _activeAdapter = adapter;
      final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
      final bioclockEnabled = await MemorySettings.isAbilityEnabled('bioclock');

      // 靜態前綴：優先用聊天傳入的同款 bundle（同 namespace，直接命中
      // 聊天已建緩存；emotion ability 等工具段已在 bundle 內，不重複加）。
      // 沒傳（保底）才退回舊自拼前綴——那個前綴獨立且體量常低於
      // 緩存門檻（Sonnet 1024 / Opus 4096），基本不會命中。
      final String staticPrompt;
      final String? profilePrompt;
      final String windowPrompt;
      if (widget.staticPart?.isNotEmpty == true) {
        staticPrompt = widget.staticPart!;
        profilePrompt = widget.profilePart;
        windowPrompt = widget.windowPart ?? '';
      } else {
        final conversation = await DatabaseHelper.getConversation(
          widget.conversationId,
        );
        final persona = await UserPersonaService.personaForConversation(
          conversation!,
        );
        final baseSystemPrompt = persona.promptContent;
        staticPrompt = [
          RpIdentityLockPrompt.build(
            characterName: _promptCharacterName,
            userName: _userPersonaName,
          ),
          if (baseSystemPrompt.isNotEmpty) baseSystemPrompt,
          if (widget.cacheStaticSnapshot?.isNotEmpty == true)
            widget.cacheStaticSnapshot!,
          if (emotionEnabled || bioclockEnabled)
            ModelActionProtocol.promptHeader(),
          if (emotionEnabled) EmotionCoordinates.abilityPrompt(),
          if (bioclockEnabled) BioClockService.abilityPrompt(),
        ].join('\n\n');
        profilePrompt = UserPersonaService.buildIdentityPrompt(persona);
        windowPrompt = widget.cacheStaticSnapshot ?? '';
      }

      final dynamicParts = <String>[];
      final conversation = await DatabaseHelper.getConversation(
        widget.conversationId,
      );
      final identity = ChatSessionIdentity.fromConversation(
        expectedConversationId: widget.conversationId,
        conversation: conversation,
      );
      if (await MoodGlowService.isEnabledFor(identity.contextMode)) {
        dynamicParts
          ..add(MoodGlowService.abilityPrompt())
          ..add(await MoodGlowService.statusPrompt(widget.conversationId));
      }
      final configuredMemoryMode = await MemorySettings.getMemoryMode();
      final memoryBucket = configuredMemoryMode == 'story'
          ? 'story'
          : 'romance';
      final memoryPrompt = identity.contextMode == ContextMode.rp
          ? await RpMemoryService.buildPrompt(
              mode: memoryBucket,
              currentMessage: userText ?? '',
              characterId: _characterId,
              windowId: widget.conversationId,
              continuityId: identity.continuityId,
            )
          : await Retriever.buildMemoryPrompt(
              mode: memoryBucket,
              currentMessage: userText ?? '',
              characterId: _characterId,
              windowId: widget.conversationId,
              contextMode: ContextMode.daily,
              continuityId: identity.continuityId,
            );
      final turnEffects = DeferredPromptBatch()..add(memoryPrompt);
      if (memoryPrompt.isNotEmpty) {
        dynamicParts.add(
          SystemContextMarkdown.section(
            enTitle: 'Memory',
            zhTWTitle: '記憶',
            zhCNTitle: '记忆',
            content: memoryPrompt.text,
          ),
        );
      }
      if (emotionEnabled) {
        final emoState = await EmotionCoordinates.statePrompt(_characterId);
        if (emoState.isNotEmpty) dynamicParts.add(emoState);
      }
      if (bioclockEnabled) {
        final clockPrompt = await BioClockService.turnPrompt(_characterId);
        if (clockPrompt.isNotEmpty) {
          dynamicParts.add(
            SystemContextMarkdown.section(
              enTitle: 'Bio Clock',
              zhTWTitle: '生物鐘',
              zhCNTitle: '生物钟',
              content: clockPrompt.text,
            ),
          );
          turnEffects.add(clockPrompt);
        }
      }
      // v3/v4 允許語音標籤，其他 TTS 模型剝除標籤。
      final ttsProvider = await TtsSettings.getTtsProvider();
      final elModel = await TtsSettings.getTtsElevenlabsModel();
      final allowsAudioTags =
          ttsProvider == 'elevenlabs' &&
          (elModel == 'eleven_v3' || elModel == 'eleven_v4');

      // ── 流水線就緒 ──
      final pipeline = SentenceTtsPipeline(
        characterId: _characterId,
        conversationId: widget.conversationId,
        conversationTitle: widget.characterName,
        sttLocale: _sttLocale,
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
      pipeline.onSentencePlaying = (text, duration) {
        if (mounted && !_popped && serial == _turnSerial) {
          _showSpokenSentence(text, duration);
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
      pipeline.onConfigurationFailure = (reason) {
        if (!mounted ||
            _popped ||
            serial != _turnSerial ||
            !identical(_pipeline, pipeline)) {
          return;
        }
        final firstFailure = _ttsConfigurationError == null;
        setState(() {
          _ttsConfigurationError = reason;
          _captionWaitForAudio = false;
          _statusText = _idleHint();
          if (firstFailure) {
            _chatLog.add(
              _CallMessage(
                text: L.pick(
                  en: '⚠ Voice output needs attention: $reason',
                  zhTW: '⚠ 語音輸出需要設定：$reason',
                ),
                isUser: false,
                isError: true,
              ),
            );
          }
        });
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
      final now = DateTime.now();
      final turnPayload = CallPromptComposer.compose(
        history: _callHistory,
        dynamicParts: dynamicParts,
        now: now,
        allowAudioTags: allowsAudioTags,
        characterName: _promptCharacterName,
        userName: _userPersonaName,
        callElapsed: _elapsed,
        replyLocale: _sttLocale,
        naturalCall: _naturalCall,
      );
      final outgoing = turnPayload.messages;
      final structured = StructuredPrompt(
        sessionIdentity:
            _sessionIdentity ??
            (throw StateError('Call conversation identity is unavailable')),
        staticPart: staticPrompt,
        profilePart: profilePrompt,
        windowPart: windowPrompt,
        controlPart: turnPayload.controlPart,
        liveStatePart: turnPayload.liveStatePart,
        cacheChannel: PromptCacheChannel.call,
      );

      if (!mounted || _popped || serial != _turnSerial) return;
      final rawBuf = StringBuffer();
      final streamDecoder = ModelStreamDecoder();
      var requestUsage = const ApiUsage();
      String filtered = '';
      await for (final chunk in adapter.sendMessageStream(
        messages: outgoing,
        model: model,
        structuredPrompt: structured,
        onUsage: (usage) => requestUsage = usage,
      )) {
        if (serial != _turnSerial) {
          // 已被打斷/掛斷
          await pipeline.cancel();
          return;
        }
        rawBuf.write(chunk);
        await turnEffects.commit();
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

        final visibleChunk = streamDecoder.add(chunk);
        if (visibleChunk.isNotEmpty) {
          filtered += visibleChunk;
          final sentence = _lastCompletedSentence(filtered);
          if (!_captionFollowsAudio &&
              !_captionWaitForAudio &&
              sentence.isNotEmpty &&
              sentence != _liveCharacterCaption) {
            setState(() => _liveCharacterCaption = sentence);
          }
        }

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

        if (visibleChunk.isNotEmpty) {
          pipeline.pushText(visibleChunk);
        }
      }

      final visibleTail = streamDecoder.close();
      if (visibleTail.isNotEmpty) {
        filtered += visibleTail;
        pipeline.pushText(visibleTail);
      }

      await turnEffects.commit();
      final response = rawBuf.toString();
      if (!mounted || _popped || serial != _turnSerial) return;
      final normalizedResponse =
          ModelActionProtocol.normalizeForLegacyProcessors(response);
      if (_phase == _CallPhase.dialing &&
          (normalizedResponse.contains('<decline_call/>') ||
              normalizedResponse.contains('<decline_call>'))) {
        _declineUserCall();
        return;
      }
      if (_phase == _CallPhase.inCall &&
          (normalizedResponse.contains('<hangup/>') ||
              normalizedResponse.contains('<hangup>'))) {
        _endCall();
        return;
      }
      var processedResponse = emotionEnabled
          ? await EmotionCoordinates.processReply(
              normalizedResponse,
              characterId: _characterId,
            )
          : EmotionCoordinates.stripReply(normalizedResponse);
      // 心情流光：與文字聊天同一份窗口狀態（計輪、冷卻、換色）。
      processedResponse = await MoodGlowService.processReply(
        processedResponse,
        conversationId: widget.conversationId,
        mode: _sessionIdentity?.contextMode ?? ContextMode.daily,
      );
      if (bioclockEnabled) {
        processedResponse = await BioClockService.processReply(
          processedResponse,
          characterId: _characterId,
        );
      }
      // 模型自我修正（「Wait — I need to redo this cleanly.」）時只存正式版。
      final rawDisplayText = VisibleModelOutput.dropSelfCorrectionDraft(
        _filterStream(processedResponse),
      ).trim();
      var cleanText = rawDisplayText
          .replaceAll(RegExp(r'\[[a-zA-Z0-9_]+\]'), '')
          .trim();

      // Some OpenRouter/OpenAI-compatible models occasionally return only a
      // reasoning/tool block. The old path silently accepted that as an empty
      // assistant turn, so STT looked successful but the other side said
      // nothing. Retry exactly once in the request-only live layer; the stable
      // cache prefix and persisted conversation history remain untouched.
      var recoveryUsage = const ApiUsage();
      var recoveryResponse = '';
      if (cleanText.isEmpty && mounted && !_popped && serial == _turnSerial) {
        final recoveryBuffer = StringBuffer();
        final recoveryDecoder = ModelStreamDecoder();
        var recoveryVisible = '';
        final recoveryPrompt = structured.copyWith(
          liveStatePart: [
            structured.liveStatePart,
            CallPromptComposer.emptyReplyRecoveryInstruction(
              characterName: _promptCharacterName,
              userName: _userPersonaName,
            ),
          ].where((part) => part.trim().isNotEmpty).join('\n\n'),
        );
        await for (final chunk in adapter.sendMessageStream(
          messages: outgoing,
          model: model,
          structuredPrompt: recoveryPrompt,
          onUsage: (usage) => recoveryUsage = usage,
        )) {
          if (serial != _turnSerial) {
            await pipeline.cancel();
            return;
          }
          recoveryBuffer.write(chunk);
          final visibleChunk = recoveryDecoder.add(chunk);
          if (visibleChunk.isEmpty) continue;
          recoveryVisible += visibleChunk;
          pipeline.pushText(visibleChunk);
          if (_phase == _CallPhase.dialing &&
              recoveryVisible.trim().isNotEmpty) {
            _ringtone.stop();
            _ringVibrateTimer?.cancel();
            if (mounted) {
              setState(() {
                _phase = _CallPhase.inCall;
                _statusText = L.get('call_speaking');
              });
            }
            _startCallTimer();
          }
        }
        final recoveryTail = recoveryDecoder.close();
        if (recoveryTail.isNotEmpty) {
          recoveryVisible += recoveryTail;
          pipeline.pushText(recoveryTail);
        }
        recoveryResponse = recoveryBuffer.toString();
        cleanText = VisibleModelOutput.finalOnly(
          recoveryResponse,
        ).replaceAll(RegExp(r'\[[a-zA-Z0-9_]+\]'), '').trim();
      }

      if (!mounted || _popped || serial != _turnSerial) return;
      await _recordCallUsage(
        provider: providerName,
        model: model,
        usage: requestUsage,
        response: response,
      );
      if (recoveryResponse.isNotEmpty || recoveryUsage.hasTokenCounts) {
        await _recordCallUsage(
          provider: providerName,
          model: model,
          usage: recoveryUsage,
          response: recoveryResponse,
        );
      }

      final cacheRead =
          CacheStatsHelper.readTokens(requestUsage) +
          CacheStatsHelper.readTokens(recoveryUsage);
      if (cacheRead > 0) {
        CacheSession.markCacheHit(widget.conversationId);
      }

      if (cleanText.isEmpty) {
        await pipeline.finish();
        if (!mounted || _popped || serial != _turnSerial) return;
        setState(() {
          _captionWaitForAudio = false;
          _micState = _MicState.idle;
          _statusText = L.pick(
            en: 'No spoken reply · try again',
            zhTW: '沒有收到語音回覆 · 請再試一次',
            zhCN: '没有收到语音回复 · 请再试一次',
          );
          _level.value = 0;
          _chatLog.add(
            _CallMessage(
              text: L.pick(
                en: '⚠ No audible reply was received. Please try again.',
                zhTW: '⚠ 沒有收到可朗讀的回覆，請再試一次。',
                zhCN: '⚠ 没有收到可朗读的回复，请再试一次。',
              ),
              isUser: false,
              isError: true,
            ),
          );
        });
        _maybeRestartAutoListen();
        return;
      }

      // 下一輪只回放真正說出口的內容。把 protocol 原文放回 history
      // 會讓模型模仿 <call>，也是通話標籤反覆偷跑的來源之一。
      _appendCallHistory('assistant', cleanText);

      // 緩存提示（通話內 chip + 消息 ⚡）
      if (mounted && serial == _turnSerial) {
        setState(() {
          if (cleanText.isNotEmpty) {
            _chatLog.add(_CallMessage(text: cleanText, isUser: false));
            // 聲音還在播前面的句子時，不要讓字幕直接跳到最後一句。
            if (!_captionFollowsAudio && !_captionWaitForAudio) {
              _liveCharacterCaption = _lastCaptionSentence(cleanText);
            }
          }
        });
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

      // 等音頻播完
      await pipeline.finish();

      if (!mounted || _popped || serial != _turnSerial) return;
      setState(() {
        // 整輪一聲沒出（TTS 全失敗）：退回顯示文字最後一句。
        if (!_captionFollowsAudio && cleanText.isNotEmpty) {
          _liveCharacterCaption = _lastCaptionSentence(cleanText);
        }
        _captionWaitForAudio = false;
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
      _maybeRestartAutoListen();
    } finally {
      if (identical(_activeAdapter, turnAdapter)) _activeAdapter = null;
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

  Future<void> _recordCallUsage({
    required String provider,
    required String model,
    required ApiUsage usage,
    required String response,
  }) async {
    if (!usage.hasTokenCounts) {
      _tokenTracker.addEstimated(completion: response);
    }
    await _tokenTracker.recordRealUsage(
      provider: provider,
      model: model,
      usage: usage,
      characterId: _characterId,
      conversationId: widget.conversationId,
      requestKind: ApiRequestKind.call,
    );
  }

  Future<void> _recordHiddenUserEvent(String event) async {
    final normalized = event.trim();
    if (normalized.isEmpty) return;
    _appendCallHistory('user', normalized);
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: widget.conversationId,
        characterId: _characterId,
        text: normalized,
        isUser: true,
      ),
    );
  }

  /// 直接說一段話（來電開場白）
  Future<void> _speakDirect(String text) async {
    if (!mounted || _popped || !_bootstrapReady) return;
    final serial = ++_turnSerial;
    _anyExchange = true;
    _appendCallHistory('assistant', text);
    setState(() {
      _chatLog.add(_CallMessage(text: text, isUser: false));
      _liveCharacterCaption = '';
      _captionFollowsAudio = false;
      _captionWaitForAudio = _ttsConfigurationError == null;
      _captionLineTimer?.cancel();
    });
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
      sttLocale: _sttLocale,
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
      pipeline.onSentencePlaying = (text, duration) {
        if (mounted && !_popped && serial == _turnSerial) {
          _showSpokenSentence(text, duration);
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
      if (!_captionFollowsAudio) {
        _liveCharacterCaption = _lastCaptionSentence(text);
      }
      _captionWaitForAudio = false;
      _micState = _MicState.idle;
      _statusText = _idleHint();
      _level.value = 0;
    });
  }

  /// 打斷當前播放（點頭像）
  void _interrupt() {
    if (_micState != _MicState.speaking) return;
    _turnSerial++;
    final adapter = _activeAdapter;
    _activeAdapter = null;
    adapter?.cancelActive();
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
    final adapter = _activeAdapter;
    _activeAdapter = null;
    adapter?.cancelActive();
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) unawaited(pipeline.cancel());
    _localAsrSubscription?.cancel();
    _localAsrSubscription = null;
    if (LocalAsrService.instance.isListening) {
      unawaited(LocalAsrService.instance.cancelRecognition());
    }
    unawaited(CallAudioRouteService.releaseBluetoothMicrophone());
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
    final adapter = _activeAdapter;
    _activeAdapter = null;
    adapter?.cancelActive();
    _autoListenRestartTimer?.cancel();
    _poorSignalFinishTimer?.cancel();
    _sttStopFallback?.cancel();
    _appleSpeechFinalGrace?.cancel();
    _holdRestartTimer?.cancel();
    _durationTimer?.cancel();
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) unawaited(pipeline.cancel());
    _localAsrSubscription?.cancel();
    _localAsrSubscription = null;
    if (LocalAsrService.instance.isListening) {
      unawaited(LocalAsrService.instance.cancelRecognition());
    }
    unawaited(CallAudioRouteService.releaseBluetoothMicrophone());
    _speech.stop();
    _stopRinging();
    Navigator.pop(context, result);
  }

  @override
  void dispose() {
    _turnSerial++;
    _captionLineTimer?.cancel();
    final adapter = _activeAdapter;
    _activeAdapter = null;
    adapter?.cancelActive();
    _sttStopFallback?.cancel();
    _appleSpeechFinalGrace?.cancel();
    _holdRestartTimer?.cancel();
    _autoListenRestartTimer?.cancel();
    _autoNoSpeechTimer?.cancel();
    _autoSpeechSilenceTimer?.cancel();
    _poorSignalFinishTimer?.cancel();
    _localAsrSubscription?.cancel();
    _localAsrSubscription = null;
    if (LocalAsrService.instance.isListening) {
      unawaited(LocalAsrService.instance.cancelRecognition());
    }
    unawaited(CallAudioRouteService.releaseBluetoothMicrophone());
    _speech.stop();
    _stopRinging();
    final pipeline = _pipeline;
    _pipeline = null;
    pipeline?.dispose();
    _durationTimer?.cancel();
    _acceptPulse.dispose();
    _level.dispose();
    _userMicLevel.dispose();
    super.dispose();
  }

  // ═══════════════ UI ═══════════════

  bool get _usesCustomCallBackground {
    final preset = _callBackgroundPreset;
    if (preset == null) return false;
    return _callBackgroundScope == 'home'
        ? preset.hasHomeImage
        : _callBackgroundScope == 'chat'
        ? preset.hasChatImage
        : false;
  }

  Color get _callPrimary => _callForeground?.primary ?? YanciTheme.textPrimary;
  Color get _callSecondary =>
      _callForeground?.secondary ?? YanciTheme.textSecondary;

  /// 按鍵色：有背景時跟背景取色走，沒背景回到主題色。掛斷鍵固定紅色不走這裡。
  Color get _callAccent => _callForeground?.primary ?? YanciTheme.accent;

  @override
  Widget build(BuildContext context) {
    final ringing = _phase == _CallPhase.ringing;
    final hasCallBackground = _usesCustomCallBackground;
    final callScope = _callBackgroundScope == 'chat'
        ? YanciBackgroundScope.chat
        : _callBackgroundScope == 'home'
        ? YanciBackgroundScope.home
        : YanciBackgroundScope.none;
    return Scaffold(
      body: GradientBackground(
        scope: callScope,
        presetOverride: _callBackgroundPreset,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!hasCallBackground &&
                _avatarPath != null &&
                _avatarPath!.isNotEmpty &&
                File(_avatarPath!).existsSync())
              RepaintBoundary(
                child: Opacity(
                  opacity: YanciTheme.isDark ? 0.22 : 0.16,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 52, sigmaY: 52),
                    child: Image.file(File(_avatarPath!), fit: BoxFit.cover),
                  ),
                ),
              ),
            const RepaintBoundary(
              child: IgnorePointer(child: AmbientParticleField(isBusy: true)),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scaledBody = MediaQuery.textScalerOf(context).scale(14);
                  final compact =
                      constraints.maxHeight < 700 || scaledBody > 17;
                  final veryCompact = constraints.maxHeight < 560;
                  final content = Column(
                    mainAxisSize: veryCompact
                        ? MainAxisSize.min
                        : MainAxisSize.max,
                    children: [
                      SizedBox(height: compact ? 12 : 24),
                      // 來電時名字跟頭像是一組：名字往下貼近頭像，
                      // 整組放在畫面中上方，不再一個在頂、一個在中間。
                      if (ringing && !veryCompact) const Spacer(flex: 2),
                      _buildHeader(ringing),
                      if (veryCompact)
                        const SizedBox(height: 8)
                      else if (ringing)
                        SizedBox(height: compact ? 22 : 30)
                      else
                        const Spacer(flex: 2),
                      GestureDetector(
                        onTap: _micState == _MicState.speaking
                            ? _interrupt
                            : null,
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            MoodGlowService.activeColor,
                            MoodGlowService.blendMode,
                          ]),
                          builder: (context, _) => CallCenterVisual(
                            avatarPath: _avatarPath,
                            fallbackName: widget.characterName,
                            level: _level,
                            ringing: ringing,
                            thinking: _micState == _MicState.thinking,
                            avatarSize: compact ? 124 : 172,
                            // 獨立流光＝模型色號；融入主題＝混進主題色。沒有就是主題色。
                            glowColor: MoodGlowService.activeColor.value == null
                                ? null
                                : MoodGlowService.displayColor(
                                    MoodGlowService.activeColor.value!,
                                  ),
                          ),
                        ),
                      ),
                      if (veryCompact)
                        const SizedBox(height: 6)
                      else
                        Spacer(flex: ringing ? 3 : 1),
                      if (!ringing) ..._buildInCallMiddle(compact: compact),
                      // 通話中字幕放在頭像與按鍵正中間：上下各一份 Spacer。
                      if (!ringing && !veryCompact)
                        const Spacer(flex: 1)
                      else
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
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: content,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool ringing) {
    final bool showStatus =
        ringing || (_statusText.isNotEmpty && _statusText != _idleHint());
    return SizedBox(
      width: double.infinity,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Padding(
            // Reserve the language control's hit area on both sides so a long
            // character name remains visually centred without overlapping it.
            padding: const EdgeInsets.fromLTRB(86, 12, 86, 0),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              child: Column(
                children: [
                  Text(
                    widget.characterName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: YanciTheme.headingLarge.copyWith(
                      fontSize: 23,
                      color: _callPrimary,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!ringing)
                        Text(
                          _durationText,
                          style: TextStyle(
                            fontSize: 13,
                            color: _callSecondary.withValues(alpha: 0.85),
                            fontFeatures: const [FontFeature.tabularFigures()],
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                      if (!ringing && showStatus)
                        Text(
                          '  ·  ',
                          style: TextStyle(
                            fontSize: 13,
                            color: _callSecondary.withValues(alpha: 0.5),
                          ),
                        ),
                      if (showStatus)
                        Text(
                          _statusText == _idleHint() ? '' : _statusText,
                          style: TextStyle(
                            fontSize: 13,
                            color: _callSecondary.withValues(alpha: 0.85),
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!ringing)
            Positioned(right: 12, top: 0, child: _callSettingsButton()),
        ],
      ),
    );
  }

  /// 右上角三條拉桿：聆聽方式、辨識語言、自然電話都收在這裡。
  /// 無底色、無邊框，只有一個淡色小圖示，不跟角色名與字幕搶視線；熱區 44pt。
  Widget _callSettingsButton() {
    final label = L.pick(en: 'Call settings', zhTW: '通話設定', zhCN: '通话设置');
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          key: const ValueKey('call-settings-button'),
          behavior: HitTestBehavior.opaque,
          onTap: _openCallSettings,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(
              Icons.tune_rounded,
              size: 18,
              color: _callSecondary.withValues(alpha: 0.62),
            ),
          ),
        ),
      ),
    );
  }

  /// 通話頁的底部面板：沒背景用主題面板色；有背景時面板透明，
  /// 背景的顏色透上來、整片重度模糊（毛玻璃）。
  Future<void> _showCallSheet({required WidgetBuilder builder}) {
    final radius = BorderRadius.vertical(
      top: Radius.circular(YanciTheme.radiusCard),
    );
    if (!_usesCustomCallBackground) {
      return showModalBottomSheet<void>(
        context: context,
        backgroundColor: YanciTheme.surfacePanel.withValues(alpha: 0.98),
        shape: RoundedRectangleBorder(borderRadius: radius),
        builder: builder,
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      builder: (sheetContext) => ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _callSheetBlurSigma,
            sigmaY: _callSheetBlurSigma,
          ),
          child: ColoredBox(
            color: YanciTheme.surfacePanel.withValues(
              alpha: YanciTheme.isDark ? 0.30 : 0.38,
            ),
            child: builder(sheetContext),
          ),
        ),
      ),
    );
  }

  static const double _callSheetBlurSigma = 40;

  void _openCallSettings() {
    _showCallSheet(
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // 外層 State 改完後同步刷新 sheet。
          Future<void> apply(Future<void> Function() change) async {
            await change();
            if (sheetContext.mounted) setSheetState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L.pick(
                                en: 'Natural call',
                                zhTW: '自然電話',
                                zhCN: '自然电话',
                              ),
                              style: _sheetTitleStyle(),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              L.pick(
                                en: 'Short turns, about 1–5 sentences, like a real call',
                                zhTW: '像真的打電話，一次 1–5 句短句',
                                zhCN: '像真的打电话，一次 1–5 句短句',
                              ),
                              style: _sheetHintStyle(),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        key: const ValueKey('call-natural-switch'),
                        value: _naturalCall,
                        activeThumbColor: YanciTheme.accent,
                        activeTrackColor: YanciTheme.accent.withValues(
                          alpha: 0.3,
                        ),
                        onChanged: (v) => apply(() => _setNaturalCall(v)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    L.pick(en: 'Listening', zhTW: '聆聽方式', zhCN: '聆听方式'),
                    style: _sheetTitleStyle(),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in const ['hold', 'auto'])
                        _sheetPill(
                          key: ValueKey('call-mic-mode-$mode'),
                          label: mode == 'hold'
                              ? L.pick(
                                  en: 'Push to talk',
                                  zhTW: '按鍵說話',
                                  zhCN: '按键说话',
                                )
                              : L.pick(
                                  en: 'Auto listen',
                                  zhTW: '自動聆聽',
                                  zhCN: '自动聆听',
                                ),
                          icon: mode == 'hold'
                              ? Icons.touch_app_rounded
                              : Icons.graphic_eq_rounded,
                          selected: _micMode == mode,
                          onTap: _micMode == mode
                              ? null
                              : () => apply(_toggleMicMode),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    L.pick(
                      en: 'Recognition language',
                      zhTW: '語音辨識語言',
                      zhCN: '语音识别语言',
                    ),
                    style: _sheetTitleStyle(),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in TtsSettings.sttLocalesFor(
                        cantonese: _cantoneseAvailable,
                      ))
                        _sheetPill(
                          key: ValueKey('call-locale-${entry.$1}'),
                          label: entry.$2,
                          selected: entry.$1 == _sttLocale,
                          onTap: entry.$1 == _sttLocale
                              ? null
                              : () => apply(() => _setSttLocale(entry.$1)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    L.pick(en: 'Common words', zhTW: '常用詞彙', zhCN: '常用词汇'),
                    style: _sheetTitleStyle(),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    L.pick(
                      en: 'Similar-sounding words are recognized as these (Chinese, 2–8 characters). The character name is included automatically.',
                      zhTW: '讀音相近時優先辨識成這些詞（2–8 個漢字）。角色名字會自動加入。',
                      zhCN: '读音相近时优先识别成这些词（2–8 个汉字）。角色名字会自动加入。',
                    ),
                    style: _sheetHintStyle(),
                  ),
                  if (!_asrVocabSupported) ...[
                    const SizedBox(height: 4),
                    Text(
                      L.pick(
                        en: 'Cantonese is not supported yet.',
                        zhTW: '粵語暫時無法支持。',
                        zhCN: '粤语暂时无法支持。',
                      ),
                      key: const ValueKey('call-vocab-cantonese-note'),
                      style: _sheetHintStyle().copyWith(
                        color: YanciTheme.accent.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final term in _asrVocab)
                        _sheetPill(
                          key: ValueKey('call-vocab-$term'),
                          label: term,
                          icon: Icons.close_rounded,
                          selected: false,
                          onTap: () => apply(() => _removeAsrTerm(term)),
                        ),
                      if (_asrVocab.length < AsrVocabularyService.maxTerms)
                        _sheetPill(
                          key: const ValueKey('call-vocab-add'),
                          label: L.pick(en: 'Add', zhTW: '新增', zhCN: '新增'),
                          icon: Icons.add_rounded,
                          selected: false,
                          onTap: () =>
                              apply(() => _promptAddAsrTerm(sheetContext)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _removeAsrTerm(String term) async {
    final next = await AsrVocabularyService.remove(_characterId, term);
    if (mounted) setState(() => _asrVocab = next);
  }

  Future<void> _promptAddAsrTerm(BuildContext sheetContext) async {
    // 不用 TextEditingController：對話框關閉動畫期間 TextField 還在樹上，
    // 立刻 dispose controller 會報錯；用 onChanged 記住文字就夠了。
    var draft = '';
    {
      final input = await showDialog<String>(
        context: sheetContext,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: YanciTheme.surfacePanel,
          title: Text(
            L.pick(en: 'Add common word', zhTW: '新增常用詞彙', zhCN: '新增常用词汇'),
            style: _sheetTitleStyle(),
          ),
          content: TextField(
            autofocus: true,
            onChanged: (v) => draft = v,
            maxLength: AsrVocabularyService.maxTermLength,
            decoration: InputDecoration(
              hintText: L.pick(en: 'e.g. 辭辭', zhTW: '例如：辭辭', zhCN: '例如：辞辞'),
            ),
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(draft),
              child: Text(L.pick(en: 'Add', zhTW: '新增', zhCN: '新增')),
            ),
          ],
        ),
      );
      final term = input?.trim() ?? '';
      if (term.isEmpty) return;
      if (!AsrVocabularyService.isUsableTerm(term)) {
        if (sheetContext.mounted) {
          ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
            SnackBar(
              content: Text(
                L.pick(
                  en: 'Use 2–8 Chinese characters.',
                  zhTW: '請輸入 2–8 個漢字。',
                  zhCN: '请输入 2–8 个汉字。',
                ),
              ),
            ),
          );
        }
        return;
      }
      final next = await AsrVocabularyService.add(_characterId, term);
      if (mounted) setState(() => _asrVocab = next);
    }
  }

  TextStyle _sheetTitleStyle() => TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: YanciTheme.textPrimary.withValues(alpha: 0.88),
    fontFamily: YanciTheme.fontFamily,
  );

  TextStyle _sheetHintStyle() => TextStyle(
    fontSize: 11.5,
    color: YanciTheme.textSecondary.withValues(alpha: 0.75),
    fontFamily: YanciTheme.fontFamily,
  );

  Widget _sheetPill({
    required Key key,
    required String label,
    IconData? icon,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final accent = YanciTheme.accent;
    final secondary = YanciTheme.textSecondary;
    final color = selected ? accent : secondary.withValues(alpha: 0.8);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.5)
                    : secondary.withValues(alpha: 0.25),
                width: 0.6,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 跟著語音逐行顯示的字幕 ──

  /// 一行最多幾個字：中日韓字寬，拉丁字母大約一半寬。
  static const int _captionLineMaxCjk = 16;
  static const int _captionLineMaxLatin = 34;

  /// 取不到音頻長度時的估算語速（每字毫秒）。
  static const int _captionFallbackMsPerChar = 210;

  /// 每行至少停留多久，避免短句一閃而過。
  static const Duration _captionMinLineDuration = Duration(milliseconds: 650);

  void _showSpokenSentence(String rawText, Duration? duration) {
    final text = rawText.replaceAll(RegExp(r'\[[^\]\n]{1,40}\]'), '').trim();
    _captionLineTimer?.cancel();
    _captionFollowsAudio = true;
    if (text.isEmpty) return;
    final lines = _splitCaptionLines(text);
    if (lines.isEmpty) return;

    final totalChars = lines.fold<int>(0, (sum, line) => sum + line.length);
    final totalMs = (duration != null && duration > Duration.zero)
        ? duration.inMilliseconds
        : totalChars * _captionFallbackMsPerChar;

    var index = 0;
    void showLine() {
      if (!mounted || _popped) return;
      final line = lines[index];
      setState(() => _liveCharacterCaption = line);
      if (index >= lines.length - 1) return;
      final share = totalChars == 0
          ? totalMs ~/ lines.length
          : (totalMs * line.length / totalChars).round();
      final wait = Duration(
        milliseconds: math.max(share, _captionMinLineDuration.inMilliseconds),
      );
      index++;
      _captionLineTimer = Timer(wait, showLine);
    }

    showLine();
  }

  /// 依子句標點切行，再把太短的合併、太長的硬切，讓每行都是一口氣。
  List<String> _splitCaptionLines(String text) {
    final cjkCount = RegExp(
      r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
    ).allMatches(text).length;
    final maxLen = cjkCount * 3 >= text.length
        ? _captionLineMaxCjk
        : _captionLineMaxLatin;

    final clauses = RegExp(r'[^，,、；;：:。！？!?…\n]+[，,、；;：:。！？!?…]*')
        .allMatches(text)
        .map((m) => m.group(0)!.trim())
        .where((clause) => clause.isNotEmpty)
        .toList();

    final lines = <String>[];
    var current = '';
    for (final clause in clauses) {
      var piece = clause;
      while (piece.length > maxLen) {
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        lines.add(piece.substring(0, maxLen));
        piece = piece.substring(maxLen).trim();
      }
      if (piece.isEmpty) continue;
      final joiner = maxLen == _captionLineMaxLatin && current.isNotEmpty
          ? ' '
          : '';
      if (current.isNotEmpty &&
          current.length + joiner.length + piece.length <= maxLen) {
        current = '$current$joiner$piece';
      } else {
        if (current.isNotEmpty) lines.add(current);
        current = piece;
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  String _lastCompletedSentence(String text) {
    final matches = RegExp(r'[^。！？!?…\n]+[。！？!?…]').allMatches(text);
    if (matches.isEmpty) return '';
    return matches.last.group(0)?.trim() ?? '';
  }

  String _lastCaptionSentence(String text) {
    final completed = _lastCompletedSentence(text);
    if (completed.isNotEmpty) return completed;
    final lines = text
        .split(RegExp(r'[\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return lines.isEmpty ? text.trim() : lines.last;
  }

  List<Widget> _buildInCallMiddle({required bool compact}) {
    final latestCharacter = _chatLog.reversed
        .where((message) => !message.isUser && !message.isError)
        .map((message) => TtsService.extractSpeechContent(message.text).trim())
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');
    // 你說話中顯示即時辨識；送出後到角色開口前（思考中）留著那一句。
    final liveUser = _currentTranscript.trim();
    final userCaption = liveUser.isNotEmpty
        ? liveUser
        : _micState == _MicState.thinking
        ? _submittedTranscript.trim()
        : '';
    final isUserCaption = userCaption.isNotEmpty;
    final waitingForVoice =
        !isUserCaption &&
        _captionsEnabled &&
        _captionWaitForAudio &&
        !_captionFollowsAudio &&
        _liveCharacterCaption.isEmpty;
    final caption = isUserCaption
        ? userCaption
        : waitingForVoice
        ? ''
        : _captionsEnabled && _liveCharacterCaption.isNotEmpty
        ? _liveCharacterCaption
        : _captionsEnabled && latestCharacter.isNotEmpty
        ? _lastCaptionSentence(latestCharacter)
        : _idleHint();
    // 使用者字幕用固定 key：即時辨識每 100ms 更新一次，若 key 跟著文字變，
    // AnimatedSwitcher 會不停重播淡入（前 40% 透明），字幕永遠浮不出來。
    final captionKey = isUserCaption
        ? 'user-caption'
        : waitingForVoice
        ? 'waiting-caption'
        : (latestCharacter.isNotEmpty || _liveCharacterCaption.isNotEmpty) &&
              _captionsEnabled
        ? 'character-caption-$caption'
        : 'idle-caption';
    return [
      Semantics(
        button: _chatLog.isNotEmpty,
        label: L.get('call_log'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _chatLog.isEmpty ? null : _openTranscriptHistory,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 58 : 66),
            child: Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: [
                if (_usesCustomCallBackground && _callBackgroundPreset != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -_CallCaptionBackdrop.feather,
                    bottom: -_CallCaptionBackdrop.feather,
                    child: _CallCaptionBackdrop(
                      preset: _callBackgroundPreset!,
                      scope: _callBackgroundScope,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 8,
                  ),
                  child: Center(
                    child: AnimatedSize(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 220),
                        // 上一句先在前 60% 淡出、下一句在後 60% 淡入並微微上浮，
                        // 中間只重疊一小段，換行快但不糊在一起。
                        switchInCurve: const Interval(
                          0.4,
                          1,
                          curve: Curves.easeOutCubic,
                        ),
                        switchOutCurve: const Interval(
                          0.4,
                          1,
                          curve: Curves.easeInCubic,
                        ),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.18),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: isUserCaption
                            // 自己說的話：最多露 4 行，跟著最新的字往下捲，
                            // 更早的內容在頂部淡出，可以手動往上捲回去看。
                            ? _UserLiveCaption(
                                key: ValueKey<String>(captionKey),
                                text: caption,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.48,
                                  color: _callSecondary.withValues(alpha: 0.88),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              )
                            : Text(
                                caption,
                                key: ValueKey<String>(captionKey),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  height: 1.48,
                                  color: _callPrimary.withValues(
                                    alpha: captionKey == 'idle-caption'
                                        ? 0.58
                                        : 0.88,
                                  ),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  void _openTranscriptHistory() {
    _showCallSheet(
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.62,
          ),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            itemCount: _chatLog.length,
            itemBuilder: (_, index) => _buildLogItem(_chatLog[index]),
          ),
        ),
      ),
    );
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
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _callControlSlot(
              width: 94,
              label: _micMode == 'hold'
                  ? L.get('call_mode_hold')
                  : (_muted ? L.get('call_unmute') : L.get('call_mute')),
              child: _buildMicControl(compact: compact),
            ),
            SizedBox(width: compact ? 16 : 28),
            _callControlSlot(
              label: L.pick(en: 'Subtitles', zhTW: '字幕', zhCN: '字幕'),
              child: CallActionButton(
                icon: _captionsEnabled
                    ? Icons.closed_caption_rounded
                    : Icons.closed_caption_off_rounded,
                color: _callAccent,
                outlined: !_captionsEnabled,
                size: 52,
                semanticLabel: L.pick(en: 'Subtitles', zhTW: '字幕', zhCN: '字幕'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _captionsEnabled = !_captionsEnabled);
                },
              ),
            ),
          ],
        ),
        // 掛斷與上排控制拉開距離，避免想按字幕／說話時誤觸掛斷。
        SizedBox(height: compact ? 20 : 38),
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

  Widget _callControlSlot({
    required String label,
    required Widget child,
    double width = 84,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: _callSecondary.withValues(alpha: 0.78),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMicControl({required bool compact}) {
    final listening = _micState == _MicState.listening;
    final size = compact ? 64.0 : 70.0;
    final button = ValueListenableBuilder<double>(
      valueListenable: _userMicLevel,
      builder: (context, level, child) {
        final halo = listening ? level.clamp(0.0, 1.0) : 0.0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: size + halo * 14,
          height: size + halo * 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: halo <= 0
                ? null
                : [
                    BoxShadow(
                      color: _callAccent.withValues(alpha: 0.12 + halo * 0.18),
                      blurRadius: 8 + halo * 14,
                      spreadRadius: halo * 4,
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: child,
        );
      },
      child: CallActionButton(
        icon: _micMode == 'auto' && _muted
            ? Icons.mic_off_rounded
            : listening
            ? Icons.mic_rounded
            : Icons.mic_none_rounded,
        color: _muted ? _callSecondary : _callAccent,
        outlined: !listening && !_muted,
        size: size,
        semanticLabel: _micMode == 'hold'
            ? L.get('call_mode_hold')
            : (_muted ? L.get('call_unmute') : L.get('call_mute')),
        onTap: _micMode == 'auto' ? _toggleMute : () {},
      ),
    );
    if (_micMode != 'hold') return button;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _onMicDown(),
      onPointerUp: (_) => _onMicUp(),
      onPointerCancel: (_) => _onMicUp(),
      child: IgnorePointer(child: button),
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

class _CallCaptionBackdrop extends StatefulWidget {
  const _CallCaptionBackdrop({required this.preset, required this.scope});

  final BackgroundPreset preset;
  final String scope;

  /// 模糊帶往字幕上下各多鋪這麼高，用來做羽化，邊緣不再有硬線。
  static const double feather = 28;

  @override
  State<_CallCaptionBackdrop> createState() => _CallCaptionBackdropState();
}

class _CallCaptionBackdropState extends State<_CallCaptionBackdrop> {
  Offset? _offset;
  Size? _viewport;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _CallCaptionBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final nextOffset = box.localToGlobal(Offset.zero);
      final nextViewport = MediaQuery.sizeOf(context);
      if (_offset == nextOffset && _viewport == nextViewport) return;
      setState(() {
        _offset = nextOffset;
        _viewport = nextViewport;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final home = widget.scope == 'home';
    final path = home ? widget.preset.homePath : widget.preset.chatPath;
    final offset = _offset;
    final viewport = _viewport;
    if (path.isEmpty || offset == null || viewport == null) {
      return const SizedBox.expand();
    }
    // 橫向整條鋪滿（螢幕左右邊緣自然切掉），只在上下羽化。
    // 之前用 RadialGradient：半徑按短邊算，寬扁的字幕條只剩中間一小團，
    // 上下又直接被盒子切掉，就是「範圍太小＋硬邊」。
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final stop =
            (_CallCaptionBackdrop.feather / math.max(1.0, bounds.height))
                .clamp(0.15, 0.45)
                .toDouble();
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: <double>[0, stop, 1 - stop, 1],
        ).createShader(bounds);
      },
      child: ClipRect(
        child: BakedCardRegionBlur(
          file: File(path),
          scale: home ? widget.preset.homeScale : widget.preset.chatScale,
          offsetX: home ? widget.preset.homeOffsetX : widget.preset.chatOffsetX,
          offsetY: home ? widget.preset.homeOffsetY : widget.preset.chatOffsetY,
          blur: (home ? widget.preset.homeBlur : widget.preset.chatBlur)
              .clamp(8.0, 20.0)
              .toDouble(),
          viewportSize: viewport,
          regionOffset: offset,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          overlayColor: YanciTheme.surfacePanel.withValues(
            alpha: YanciTheme.isDark ? 0.32 : 0.42,
          ),
        ),
      ),
    );
  }
}

/// 使用者即時辨識字幕：短的時候照常置中；超過 [maxVisibleLines] 行就變成
/// 固定高度、貼底捲動的小窗，頂部淡出，往上滑可以看前面說了什麼。
class _UserLiveCaption extends StatelessWidget {
  const _UserLiveCaption({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  static const int maxVisibleLines = 4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final body = Text(text, textAlign: TextAlign.center, style: style);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textAlign: TextAlign.center,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final lineCount = painter.computeLineMetrics().length;
        final lineHeight = painter.preferredLineHeight;
        painter.dispose();
        if (lineCount <= maxVisibleLines) return body;
        return SizedBox(
          height: lineHeight * maxVisibleLines,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Colors.transparent, Colors.white],
              stops: <double>[0, 0.3],
            ).createShader(bounds),
            child: SingleChildScrollView(
              // reverse：永遠貼著最新的字，不用自己算捲動位置。
              reverse: true,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(width: double.infinity, child: body),
            ),
          ),
        );
      },
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
