import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../widgets/ambient_particles.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_diagnostic_card.dart';
import '../widgets/input_bar.dart';
import '../widgets/scroll_edge_fade.dart';
import '../widgets/image_card_stack.dart';
import '../widgets/atom_thinking.dart';
import '../services/api_adapter.dart';
import '../services/api_error_localizer.dart';
import '../services/app_error_log_service.dart';
import '../services/stream_presentation_policy.dart';
import '../services/model_stream_decoder.dart';
import '../services/model_action_protocol.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/deferred_prompt.dart';
import '../services/prompt_cache_channels.dart';
import '../services/character_signature_service.dart';
import '../services/model_cost_policy.dart';
import '../services/memory_actions.dart';
import '../services/chat_search_follow_up.dart';
import '../services/memory_guard_service.dart';
import '../services/image_gen_service.dart';
import '../memory/emotion_coordinates.dart';
import '../services/token_tracker.dart';
import '../services/chat_window_stats_service.dart';
import '../services/context_compressor.dart';
import '../services/context_summary_repair_service.dart';
import '../services/sticker_service.dart';
import '../services/image_service.dart';
import '../memory/database.dart';
import '../models/web_search_trace.dart';
import '../models/email_draft.dart';
import '../memory/retriever.dart';
import '../services/bio_clock_service.dart';
import '../services/shop_service.dart';
import '../utils/text_safety.dart';
import '../services/marriage_service.dart';
import '../services/tool_prompts.dart';
import '../services/home_note_service.dart';
import '../services/guide_service.dart';
import '../services/tool_runner.dart';
import '../services/web_search_intent.dart';
import '../services/web_search_follow_up.dart';
import '../services/web_search_service.dart';
import '../services/web_search_tool_bridge.dart';
import '../services/web_search_turn_coordinator.dart';
import '../services/email_draft_launcher.dart';
import '../services/email_draft_repository.dart';
import '../services/email_draft_tool.dart';
import '../services/x_post_service.dart';
import '../services/x_post_settings.dart';
import '../services/character_timeline_service.dart';
import '../services/character_diary_service.dart';
import '../services/rp_character_timeline_service.dart';
import '../services/rp_story_service.dart';
import '../services/rp_story_state_service.dart';
import '../services/rp_worldbook_service.dart';
import '../services/rp_memory_service.dart';
import '../services/rp_identity_lock_prompt.dart';
import '../services/whisper_service.dart';
import '../memory/spider_web_core.dart';
import '../services/spider_web_service.dart';
import '../services/local_model_service.dart';
import '../models/message.dart';
import '../models/chat_diagnostic_event.dart';
import '../models/memory_action_proposal.dart';
import '../models/chat_session_identity.dart';
import '../models/context_mode.dart';
import '../models/background_preset.dart';
import '../services/background_preset_service.dart';
import '../services/background_foreground_service.dart';
import '../services/keep_alive_foreground.dart';
import '../services/keep_alive_service.dart';
import '../services/ios_reply_background_task.dart';
import '../services/manual_summary_service.dart';
import '../services/scratch_service.dart';
import '../services/transfer_service.dart';
import '../services/tool_feature_settings.dart';
import '../widgets/scratch_card.dart';
import '../widgets/shop_backpack_sheets.dart';
import '../widgets/sticker_preview_quality.dart';
import '../widgets/long_screenshot_options_sheet.dart';
import '../widgets/chat_model_picker.dart';
import '../widgets/new_character_draft_card.dart';
import '../widgets/chat_cost_mode_guide.dart';
import '../widgets/chat_window_status.dart';
import '../widgets/reply_variant_controls.dart';
import '../widgets/memory_review_tab.dart';
import '../widgets/web_search_activity_card.dart';
import '../widgets/web_search_result_card.dart';
import '../widgets/web_search_thinking_node.dart';
import '../widgets/email_draft_card.dart';
import '../widgets/context_mode_pill.dart';
import 'call_screen.dart';
import 'manual_summary_clean_screen.dart';
import 'rp_story_relationship_screen.dart';
import 'rp_storyline_screen.dart';
import 'rp_worldbook_screen.dart';
import '../services/call_audio_pipeline.dart';
import '../services/chat_long_screenshot_service.dart';
import '../services/dream_curation_service.dart';
import '../services/user_persona_service.dart';

part 'chat_screen_generation.dart';
part 'chat_screen_actions.dart';
part 'chat_screen_web_search_follow_up.dart';
part 'chat_screen_email_drafts.dart';
part 'chat_screen_reply_variants.dart';
part 'chat_screen_loading.dart';
part 'chat_screen_message_list.dart';
part 'chat_screen_app_bar.dart';
part 'chat_screen_stream.dart';
part 'chat_screen_prompt_parts.dart';
part 'chat_screen_draw.dart';
part 'chat_screen_compression.dart';
part 'chat_screen_failure_retry.dart';
part 'chat_screen_web_search.dart';
part 'chat_screen_rp_continuation.dart';

const String _chatSearchToolName = 'chat.search';

class _ChatToolPermissionPolicy implements ToolPermissionPolicy {
  const _ChatToolPermissionPolicy(this.webSearchToolBridge);

  final WebSearchToolBridge webSearchToolBridge;

  @override
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    final isExistingLocalChatSearch =
        call.name == _chatSearchToolName &&
        definition.permissionForMode(context.mode) ==
            ToolPermissionRequirement.sensitiveRead &&
        context.mode == ToolRunMode.local;
    if (isExistingLocalChatSearch) return ToolPermissionDecision.allow;
    return webSearchToolBridge.requestPermission(
      call: call,
      definition: definition,
      context: context,
      cancellationToken: cancellationToken,
    );
  }
}

ToolRunner _createChatToolRunner(WebSearchToolBridge webSearchToolBridge) {
  final registry = ToolRegistry()
    ..register(
      ToolDefinition(
        name: _chatSearchToolName,
        description: 'Search local chat history for the current character.',
        permission: ToolPermissionRequirement.sensitiveRead,
        timeout: const Duration(seconds: 15),
        retryableOnTimeout: true,
        validateArguments: (arguments) {
          final query = arguments['query'];
          if (query is! String || query.trim().isEmpty) {
            return 'chat.search requires a non-empty query.';
          }
          final scope = arguments['scope'];
          if (scope != null &&
              (scope is! String ||
                  !const <String>{
                    'current',
                    'daily',
                    'rp',
                    'all',
                  }.contains(scope))) {
            return 'chat.search scope must be current, daily, rp, or all.';
          }
          return null;
        },
        localHandler: (call, context, cancellationToken) async {
          final characterId = context.characterId?.trim() ?? '';
          if (characterId.isEmpty) {
            throw const ToolInputException(
              'chat.search requires a character id.',
            );
          }
          cancellationToken.throwIfCancelled();
          final rows = await DatabaseHelper.searchMessages(
            keyword: (call.arguments['query']! as String).trim(),
            characterId: characterId,
            scope: call.arguments['scope']?.toString() ?? 'current',
            currentMode: ContextMode.fromStorage(
              context.metadata['current_context_mode'],
            ),
          );
          cancellationToken.throwIfCancelled();
          return rows;
        },
      ),
    )
    ..register(webSearchToolBridge.createDefinition());
  return ToolRunner(
    registry: registry,
    permissionPolicy: _ChatToolPermissionPolicy(webSearchToolBridge),
  );
}

/// 聊天頁面 — 完整版（2.0：adapter 工廠 + 角色綁定）
class ChatScreen extends StatefulWidget {
  final String conversationId;
  final bool startManualSummarySelection;

  /// 開窗完成後自動作為用戶消息發送（分支對話用：帶著編輯後的
  /// 那句話進新窗，走完整發送管線觸發她的回應）
  final String? initialAutoSendText;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.startManualSummarySelection = false,
    this.initialAutoSendText,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _StaticPromptBundle {
  final String staticPart;
  final String? profilePart;
  final String windowPart;

  const _StaticPromptBundle({
    required this.staticPart,
    this.profilePart,
    required this.windowPart,
  });
}

class _WebSearchActivityState {
  const _WebSearchActivityState({
    required this.status,
    required this.query,
    required this.providers,
    this.safeMessage,
  });

  final WebSearchActivityStatus status;
  final String query;
  final List<String> providers;
  final String? safeMessage;
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  void _refreshChatState(VoidCallback callback) => setState(callback);

  final List<Message> _messages = [];
  final GlobalKey _modelPickerAnchorKey = GlobalKey(
    debugLabel: 'chatModelPickerAnchor',
  );
  final LayerLink _noticeAnchorLink = LayerLink();
  ModelCostModeRecommendation? _costModeRecommendation;
  Timer? _costModeRecommendationTimer;
  Timer? _headerModelDetailsTimer;
  int _costModeGuideRevision = 0;
  bool _showHeaderModelDetails = true;
  bool _headerModelNeedsAttention = true;
  bool _statusButtonNeedsAttention = true;

  /// 渲染起點（_messages 索引）——渲染與發送解耦：
  /// 上下文照常發全窗（緩存前綴不斷），UI 每次只掛最近 50 條，
  /// 點「查看更早」再往上掛一段（50 條一個模塊）。
  int _renderFrom = 0;
  static const int _renderPageSize = 50;

  /// 錨點之前的歷史（純顯示，永不進發送上下文）。
  /// 「查看更早」翻完 _messages 後繼續從這裡往前掛。
  final List<Message> _olderMessages = [];
  bool _olderHasMore = false;
  bool _olderLoading = false;

  /// 分支自動發送只觸發一次（_retryInitialization 重跑 bootstrap 不重發）
  bool _autoSendFired = false;
  static const double _messageListBottomBreathingSpace = 18;
  static const double _chatHeaderHeight = 52;

  /// 讓透明的訊息視窗延伸到輸入框後方，避免訊息區在輸入框上緣形成
  /// 一條可見的矩形裁切線。ListView 會補回相同高度的底部 padding，
  /// 因此最後一條訊息與輸入框之間仍維持原本的 18px 呼吸距離。
  static const double _composerViewportUnderlay = 74;
  static const double _keyboardFollowThreshold = 96;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final TokenTracker _tokenTracker = TokenTracker();
  bool _isGenerating = false;
  bool _visibleReplyComplete = false;
  bool _isGeneratingImage = false;
  bool _streamSurfaceVisible = false;
  bool _isCapturingLongScreenshot = false;

  bool _sendSubmissionInProgress = false;
  bool _isLoading = true;
  bool _isChatReady = false;
  bool _olderButtonReady = false;
  bool _initializationFailed = false;
  String _initializationError = '';
  String _streamingText = '';
  String _currentModel = '';
  String _activeCharacterId = 'default';
  BackgroundPreset? _boundBackgroundPreset;
  Timer? _backgroundPresetRefreshTimer;
  ChatBubblePalette? _boundChatPalette;
  BackgroundForegroundPalette? _boundChatForeground;
  ChatSessionIdentity? _sessionIdentity;
  int _tokensSinceSummary = 0; // token 計數觸發
  Future<int>? _compressionInFlight;
  int? _lastFailedCompressionPendingMessages;
  bool _showScrollToBottom = false;
  bool _userScrolledUp = false; // 流式輸出時用戶手動上滾 → 暫停自動跟隨
  bool _userIsScrolling = false;
  bool _streamScrollAnimating = false;
  bool _streamScrollRequested = false;
  Duration? _streamScrollFrameTime;
  double _lastKeyboardInset = 0;
  bool _followKeyboardViewport = false;
  bool _keyboardFollowScheduled = false;
  bool _shouldAutoName = false;
  String _conversationTitle = '';
  String _characterName = '';
  String _composerHint = '';
  final List<String> _pendingImagePaths = <String>[];
  StickerInfo? _pendingSticker;
  String? _pendingScratchGiftWho;
  bool _splitReply = false;
  bool _isFirstRoundInWindow = true;
  bool _sentMessageInThisSession = false;
  bool _newCharacterWorkshopActive = false;
  bool _showChatAvatar = false;
  String? _userAvatarPath;
  UserPersona? _userPersona;
  String? _charAvatarPath;
  final Set<int> _cacheHitIndices = {};
  final Map<String, ScratchData> _scratchDataMap = {};
  final Map<String, TransferData> _transferDataMap = {};
  final Map<int, ({int total, int unread})> _pendingMemoryActionCounts = {};
  final Map<int, List<MemoryActionProposal>> _pendingMemoryProposals = {};
  final List<ChatDiagnosticEvent> _chatDiagnostics = [];
  final Map<int, int> _summaryRecordedSummaryIds = <int, int>{};
  bool _summaryEditorVisible = false;
  bool _walletChanged = false;
  List<Map<String, String>>? _lastKeepAliveMessages;
  StructuredPrompt? _lastKeepAliveStructuredPrompt;
  ApiAdapter? _lastKeepAliveAdapter;
  String? _lastKeepAliveModel;
  String? _lastKeepAliveProvider;

  ChatSessionIdentity get _requiredSessionIdentity =>
      _sessionIdentity ??
      (throw StateError(
        'Conversation ${widget.conversationId} is not initialized',
      ));
  String get _userPersonaName => _userPersona?.displayName.trim() ?? '';
  int? _coinSnapshotChar;
  int? _coinSnapshotUser;
  String? _windowSummaryId;
  Future<List<Message>>? _previousWindowTurnsFuture;
  Future<List<RpChapterContinuationSource>>?
  _rpChapterContinuationSourcesFuture;
  bool _canContinuePreviousRpChapter = false;
  bool _hasAnyRpWindow = false;
  bool _rpStartChoiceResolved = false;
  List<Map<String, Object?>> _rpStorylines = const <Map<String, Object?>>[];
  String _rpContinuationSummaryPrompt = '';
  String? _rpContinuationSourceConversationId;
  String _rpContinuationSourceTitle = '';
  List<Message> _rpContinuationDisplayMessages = <Message>[];
  bool _rpContinuationSourceExpanded = false;
  bool _rpContinuationSourceLoading = false;
  bool _rpContinuationSourceHasMore = false;
  int? _rpContinuationSourceAnchorMessageId;
  int? _rpContinuationOldestLoadedMessageId;
  double _rpContinuationPullDistance = 0;
  bool _rpContinuationPullTriggered = false;
  String? _cacheWindowSummaryStaticSnapshot;
  String? _promptLocaleSnapshot;
  bool _manualSummarySelecting = false;
  bool _manualSummaryRunning = false;
  final Set<int> _manualSummarySelectedIds = {};

  // ═══ 本地模型預加載 ═══
  bool _localModelLoading = false;

  // ═══ 歷史搜尋卡片狀態 ═══
  bool _chatSearching = false;
  String _chatSearchQuery = '';
  List<Map<String, dynamic>> _chatSearchResults = [];
  int _generationSerial = 0;
  bool _generationThinkingEnabled = false;
  bool? _activeRequestThinkingEnabled;
  int? _activeRequestThinkingGeneration;
  ApiAdapter? _activeGenerationAdapter;
  final HybridWebSearchService _webSearchService =
      const HybridWebSearchService();
  final WebSearchTurnCoordinator _webSearchTurnCoordinator =
      WebSearchTurnCoordinator();
  late final WebSearchToolBridge _webSearchToolBridge;
  late final ToolRunner _toolRunner;
  bool _stopGenerationRequested = false;
  _WebSearchActivityState? _webSearchActivity;
  BuildContext? _webSearchConfirmationContext;
  WebSearchBatchResult? _pendingWebSearchResult;
  String _pendingWebSearchFailureContext = '';
  final Map<int, WebSearchBatchResult> _webSearchResultsByMessageId =
      <int, WebSearchBatchResult>{};

  // ═══ 流式標籤實時剝離 ═══
  // 在流式輸出時隱藏內部標籤，避免 <emo>/<memo>/<draw> 等閃現
  static final _completedToolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*?</tool_calls?>',
    multiLine: true,
    caseSensitive: false,
  );
  static final _openTagRe = RegExp(
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|memo_link|force_recall|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|whisper|search_chat|search_web|call|scratch|transfer|transfer_accept|transfer_decline|buy|x_post|shop_view|pack_star|sign_marriage|propose_marriage|email_draft|holt_diary)\b[\s\S]*$',
  );

  static final _shopViewTagRe = RegExp(
    r'<shop_view\s*/?>',
    caseSensitive: false,
  );

  /// 通話事件開頭的消息 → 渲染成居中分割線（TG 式通話記錄）。
  /// 不錨定結尾：declined_by_you 尾隨動態語義說明（只給模型看，不渲染）
  static final _callDividerRe = RegExp(
    r'^\[call_event:(ended|signal_lost|declined|declined_by_you|missed)'
    r'(?:\s+(\d{2}:\d{2}))?\]',
  );
  static final _callActionRe = RegExp(
    r'^\[call_action:(dial_to_character|accept_character_call)\]$',
  );

  /// 消息尾送禮標記（卡片跟隨氣泡顯示）
  static final _giftTagRe = RegExp(r'\[gift:([^\]\n]{1,40})\]');

  /// 結婚證簽署標籤（她簽字）
  static final _signMarriageRe = RegExp(
    r'<sign_marriage\s*/?>',
    caseSensitive: false,
  );

  /// 結婚證主動遞出標籤（她遞證書）
  static final _proposeMarriageRe = RegExp(
    r'<propose_marriage\s*/?>',
    caseSensitive: false,
  );

  /// 結婚證邀請標記（你遞的，含動態說明尾巴）
  static final _marriageCertTagRe = RegExp(r'\[marriage_cert\]（[^）]*）');

  /// 結婚證遞出標記（她遞的，渲染可簽署證書卡）
  static const _marriageCertCharTag = '[marriage_cert_char]';

  // ═══ 流式絲滑打字機佇列 ═══
  final ListQueue<String> _streamCharQueue = ListQueue<String>();
  final ModelStreamDecoder _modelStreamDecoder = ModelStreamDecoder();
  StreamPresentationMode _streamPresentationMode =
      StreamPresentationMode.nativeBuffered;
  Timer? _streamRevealDelayTimer;
  Timer? _streamRevealTimer;
  DateTime? _streamFirstChunkAt;
  final ValueNotifier<int> _streamRevision = ValueNotifier<int>(0);
  Timer? _streamSurfaceDelayTimer;
  final Random _streamSurfaceRandom = Random();
  Timer? _generationForegroundStartTimer;
  Timer? _generationForegroundEndTimer;

  // ═══ 顯示文本緩存：同一個 _streamingText 只跑一次 regex ═══
  String? _dispCacheSrc;
  String _dispCacheVal = '';

  String get _displayStreamingText {
    if (identical(_dispCacheSrc, _streamingText)) return _dispCacheVal;
    final computed = _computeDisplayStreamingText();
    _dispCacheSrc = _streamingText;
    _dispCacheVal = computed;
    return computed;
  }

  /// 本輪待發的 X 推文內容（每輪 _extractXPostAndStrip 重置）
  String? _pendingXPost;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final implicitView =
        WidgetsBinding.instance.platformDispatcher.implicitView;
    if (implicitView != null) {
      _lastKeyboardInset =
          implicitView.viewInsets.bottom / implicitView.devicePixelRatio;
    }
    _webSearchToolBridge = WebSearchToolBridge(
      service: _webSearchService,
      coordinator: _webSearchTurnCoordinator,
    );
    _toolRunner = _createChatToolRunner(_webSearchToolBridge);
    _manualSummarySelecting = widget.startManualSummarySelection;
    // 窗口短號重置：模型視角的記憶編號按本窗注入順序從 1 重編
    Retriever.resetWindowIds(widget.conversationId);
    final keepAlive = KeepAliveService.instance;
    if (keepAlive.activeConversationId != null &&
        keepAlive.activeConversationId != widget.conversationId) {
      keepAlive.pauseActiveWindowInMemory();
    }
    // 窗口一打開就接管 cache session / 保活歸屬，舊窗口不能繼續 tick。
    // 若新窗口尚無真消息產生的 StructuredPrompt，保活只更新入口，不發 ping。
    unawaited(_initializeChat());
    _scrollController.addListener(_onScroll);
    BackgroundPresetService.revision.addListener(
      _handleBackgroundPresetChanged,
    );
  }

  @override
  void didChangeMetrics() {
    final implicitView =
        WidgetsBinding.instance.platformDispatcher.implicitView;
    if (!mounted || implicitView == null) return;
    final keyboardInset =
        implicitView.viewInsets.bottom / implicitView.devicePixelRatio;
    final keyboardIsRising = keyboardInset > _lastKeyboardInset + 0.5;

    if (keyboardIsRising && _scrollController.hasClients) {
      final position = _scrollController.position;
      final distanceFromBottom = position.maxScrollExtent - position.pixels;
      if (_followKeyboardViewport ||
          distanceFromBottom <= _keyboardFollowThreshold) {
        _followKeyboardViewport = true;
        _scheduleKeyboardViewportFollow();
      }
    }

    if (keyboardInset <= 0.5) {
      _followKeyboardViewport = false;
    }
    _lastKeyboardInset = keyboardInset;
  }

  void _scheduleKeyboardViewportFollow() {
    if (_keyboardFollowScheduled) return;
    _keyboardFollowScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFollowScheduled = false;
      if (!mounted ||
          !_followKeyboardViewport ||
          _userIsScrolling ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      final target = position.maxScrollExtent;
      if ((target - position.pixels).abs() > 0.5) {
        // The keyboard already supplies the movement animation. Following its
        // metrics with a jump keeps the last line visually attached to the
        // composer instead of adding a second, lagging scroll animation.
        _scrollController.jumpTo(target);
      }
    });
  }

  void _handleBackgroundPresetChanged() {
    if (!mounted || _sessionIdentity == null) return;
    _backgroundPresetRefreshTimer?.cancel();
    _backgroundPresetRefreshTimer = Timer(
      const Duration(milliseconds: 90),
      () => unawaited(_reloadBoundBackgroundPreset()),
    );
  }

  void _scheduleHeaderModelDetails({required bool isEmptyWindow}) {
    _headerModelDetailsTimer?.cancel();
    _headerModelDetailsTimer = Timer(
      isEmptyWindow ? const Duration(minutes: 3) : const Duration(seconds: 10),
      _hideHeaderModelDetails,
    );
  }

  void _hideHeaderModelDetails() {
    _headerModelDetailsTimer?.cancel();
    if (!mounted || !_showHeaderModelDetails) return;
    setState(() => _showHeaderModelDetails = false);
  }

  void _showHeaderModelConfirmation() {
    _headerModelDetailsTimer?.cancel();
    if (!mounted) return;
    setState(() => _showHeaderModelDetails = true);
    _headerModelDetailsTimer = Timer(
      const Duration(milliseconds: 1500),
      _hideHeaderModelDetails,
    );
  }

  void _markMessageSentInSession() {
    _sentMessageInThisSession = true;
    _hideHeaderModelDetails();
  }

  Future<void> _reloadBoundBackgroundPreset() async {
    final characterId = _activeCharacterId;
    final preset = await BackgroundPresetService.boundPresetForCharacter(
      characterId,
    );
    final chatPath = preset?.chatPath.trim() ?? '';
    final palette = chatPath.isEmpty
        ? null
        : await BackgroundForegroundService.resolveChatBubblePalette(chatPath);
    final foreground = chatPath.isEmpty
        ? null
        : await BackgroundForegroundService.resolve(chatPath);
    if (!mounted || characterId != _activeCharacterId) return;
    setState(() {
      _boundBackgroundPreset = preset;
      _boundChatPalette = palette;
      _boundChatForeground = foreground;
    });
  }

  /// Resolve the conversation first, then initialize every character-scoped
  /// dependency from that immutable binding. The globally selected character
  /// is intentionally never consulted here.


  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final distanceFromBottom =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    final shouldShow = distanceFromBottom > 200;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
    // Whether streaming should stop following is decided by the
    // ScrollNotification gesture path below. Content growth (for example the
    // assistant avatar appearing) also fires this controller listener and
    // must not be mistaken for a manual upward scroll.
  }


  /// 上下文窗口錨點（per conversation，prefs）。
  ///
  /// 舊做法「每次開窗載入最新 50 條」在對話超過 50 條後，每次重進對話
  /// 頭部都滑一截 → API 前綴整個換血 → 重進第一條必全量重寫緩存。
  /// 錨定後重開窗與上次發送的前綴逐字節一致，直接命中。
  String get _ctxAnchorKey => 'ctx_anchor:${widget.conversationId}';

  /// 錨點窗口的失控兜底（條數）。渲染已分頁（_renderFrom），這裡只防
  /// 內存/請求體無限膨脹；token 成本由「上下文上限」設定管。
  /// 觸頂推進錨點到最新 50 條，那一輪炸一次緩存（預期）。
  static const int _ctxAnchorMaxMessages = 500;


  /// 錨點之前的歷史往前再掛一頁（純顯示，不進上下文）






  String get _tokensSinceSummaryKey =>
      'conversation:${widget.conversationId}:tokensSinceSummary';

  String get _timelineMenstrualScanCursorKey =>
      'conversation:${widget.conversationId}:timelineMenstrualScanCursor:v2';

  /// 本地時間線補掃游標：每個對話只查上次成功掃描後的新消息。
  /// 這是 SQLite/SharedPreferences 狀態，不是 prompt cache。


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BackgroundPresetService.revision.removeListener(
      _handleBackgroundPresetChanged,
    );
    _backgroundPresetRefreshTimer?.cancel();
    _headerModelDetailsTimer?.cancel();
    _clearStreamQueue();
    _streamSurfaceDelayTimer?.cancel();
    _generationForegroundStartTimer?.cancel();
    _generationForegroundEndTimer?.cancel();
    unawaited(GenerationForegroundGuard.end());
    _dismissWebSearchConfirmation();
    _toolRunner.cancelActive(reason: 'Chat screen disposed.');
    // 關窗口：觸發窗口摘要（fire-and-forget）
    final convId = widget.conversationId;
    final charId = _activeCharacterId;
    final shouldMaintainWindow =
        _sentMessageInThisSession || _lastKeepAliveMessages != null;

    final sessionIdentity = _sessionIdentity;
    final closingModel = _lastKeepAliveModel;
    final closingProvider = _lastKeepAliveProvider;
    if (shouldMaintainWindow &&
        sessionIdentity != null &&
        closingModel != null &&
        closingProvider != null) {
      unawaited(
        _generateClosingSignatureOnDispose(
          conversationId: convId,
          characterId: charId,
          identity: sessionIdentity,
          model: closingModel,
          provider: closingProvider,
        ),
      );
    }

    MemorySettings.getWindowSummaryEnabled()
        .then((enabled) {
          if (!enabled) return;
          if (!_sentMessageInThisSession && _lastKeepAliveMessages == null) {
            return;
          }
          Future.microtask(() async {
            try {
              final triggerMessageLimit =
                  await _windowSummaryTriggerMessageLimit();
              if (triggerMessageLimit == null) return;
              final compressedTokens = await ContextCompressor.compressOnClose(
                conversationId: convId,
                characterId: charId,
                triggerMessageLimit: triggerMessageLimit,
                minMessageThreshold: triggerMessageLimit,
                contextMode: _requiredSessionIdentity.contextMode,
                continuityId: _requiredSessionIdentity.continuityId,
              );
              if (compressedTokens > 0) {
                final pendingTokens = await ContextCompressor.pendingTokenCount(
                  convId,
                );
                final p = await SharedPreferences.getInstance();
                await p.setInt(
                  'conversation:$convId:tokensSinceSummary',
                  pendingTokens,
                );
              }
            } catch (e) {
              debugPrint('Background compression failed: $e');
            }
          });
        })
        .catchError((e) {
          debugPrint('Error checking window summary settings: $e');
        });

    if (shouldMaintainWindow && sessionIdentity != null) {
      KeepAliveService.instance.start(
        sessionIdentity: sessionIdentity,
        messages: _lastKeepAliveMessages,
        structuredPrompt: _lastKeepAliveStructuredPrompt,
        adapter: _lastKeepAliveAdapter,
        model: _lastKeepAliveModel,
        provider: _lastKeepAliveProvider,
      );
    } else {
      // 本窗口沒發過真消息（只是進來看了一眼）→ 恢復被 claim
      // 覆蓋掉的原保活窗口。同步段先還原字段，搶在下面空窗口
      // 刪除回調用 activeConversationId 判斷之前。
      KeepAliveService.instance.resumePausedWindow();
    }

    // 沒說過話的空窗口 → 刪除，不留歷史紀錄
    if (!_sentMessageInThisSession) {
      DatabaseHelper.getMessages(convId)
          .then((msgs) async {
            if (msgs.isEmpty) {
              if (KeepAliveService.instance.activeConversationId == convId) {
                await KeepAliveService.instance.stop();
              }
              await DatabaseHelper.deleteConversation(convId);
            }
          })
          .catchError((_) {});
    }

    Retriever.releaseWindowIds(convId);
    MemoryActions.releaseWindow(convId);
    SpiderWebCore.releaseWindow(convId);

    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputController.dispose();
    _streamRevision.dispose();
    _costModeRecommendationTimer?.cancel();
    super.dispose();
  }

  // ═══ B1：記憶桶名唯一事實源（daily/story 兩個世界互不可見）═══

  // ═══ B4：滯後截斷錨點（歷史只在尾部增長，絕對索引跨輪穩定）═══
  int _contextKeepFrom = 0;

  // ═══ 習慣快照（增量方案）：開窗時凍結，窗內新增走動態 ═══
  Set<int>? _habitSnapshotIds;
  String? _habitListSnapshot;
  String? _stickerPromptSnapshot;

  /// 窗內背包快照（角色，行id→數量）——delta 用；開窗首 build 拍
  Map<int, int>? _packQtySnapshot;

  // ═══ 送禮掛起（conversation-scoped durable reservation）═══
  PendingGiftReservation? _pendingGift;

  // ═══ 結婚證彩蛋 ═══
  bool _pendingMarriageCert = false; // 掛起中（隨下一條消息送出）
  bool _marriageUnlocked = false; // 提及達標 → ＋選單出現簽署書
  bool _isMarried = false;
  String? _marriageDate;
  String _userNameCache = ''; // 證書卡顯示用

  /// 邀請後商店清單還跟隨幾輪（動態注入，不入庫——清單永駐歷史太浪費 token）
  int _shopInviteRoundsLeft = 0;
  static const int _shopInviteRounds = 3;

  DeferredPrompt _pendingBuyFailurePrompt() {
    final note = ShopService.pendingBuyFailureNote;
    if (note == null || note.isEmpty) return DeferredPrompt.empty();
    return DeferredPrompt(
      note,
      onCommit: () async {
        if (ShopService.pendingBuyFailureNote == note) {
          ShopService.pendingBuyFailureNote = null;
        }
      },
    );
  }

  // ═══ 自我註記快照（同款增量方案）═══
  // persona_note 每寫一條 self_notes 就變 → staticPart 前綴變 → 緩存全炸。
  // codex 抓到的緩存失效主因。凍結快照進靜態，窗內新增走動態。
  String? _selfNotesSnapshot;
  Set<String>? _selfNotesSnapshotLines;

  /// 用戶主動發起轉帳（從 + 菜單）
  /// 不自動接受——觸發 AI 回覆，讓角色自己決定接受或退還。
  TransferData? _pendingUserTransfer;

  void _scrollToBottom({bool force = false, int settlePass = 0}) {
    // 流式輸出時用戶手動上滾了 → 不強制跟隨（除非 force）
    if (_userIsScrolling || (_userScrolledUp && !force)) return;
    if (_isGenerating && !force) {
      _scheduleStreamScrollFollow();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // callback 排隊後，用戶可能才開始拖曳內容或互動式捲動條。
      // 再檢查一次，避免手放開時被舊的自動到底動作搶回位置。
      if (_scrollController.hasClients &&
          !_userIsScrolling &&
          (force || !_userScrolledUp)) {
        if (force || MediaQuery.disableAnimationsOf(context)) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        // 長窗口的文字換行與 lazy layout 可能在後續幀才增加高度。
        // 初始化到底時短暫重試，直到 maxScrollExtent 穩定；用戶一旦上滑就停止。
        if (force && settlePass < 8) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _scrollToBottom(force: true, settlePass: settlePass + 1);
            }
          });
        }
      }
    });
  }

  void _scheduleStreamScrollFollow() {
    if (_streamScrollRequested) return;
    _streamScrollRequested = true;
    // The streaming bubble changes the list extent during layout. Read its
    // target after that layout has completed so the first avatar frame follows
    // immediately instead of observing the previous maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback(_followStreamScrollFrame);
    WidgetsBinding.instance.scheduleFrame();
  }

  void _followStreamScrollFrame(Duration frameTime) {
    _streamScrollRequested = false;
    if (!mounted ||
        !_isGenerating ||
        !_scrollController.hasClients ||
        _userIsScrolling ||
        _userScrolledUp) {
      _streamScrollFrameTime = null;
      return;
    }

    final position = _scrollController.position;
    final target = position.maxScrollExtent;
    final distance = target - position.pixels;
    if (distance.abs() < 0.5) {
      _streamScrollFrameTime = null;
      return;
    }

    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final previousFrame = _streamScrollFrameTime;
    final elapsedSeconds = previousFrame == null
        ? 1 / 60
        : ((frameTime - previousFrame).inMicroseconds / 1000000).clamp(
            1 / 240,
            0.05,
          );
    _streamScrollFrameTime = frameTime;
    final followFraction = disableAnimations
        ? 1.0
        : 1 - exp(-elapsedSeconds / 0.045);
    final next = distance.abs() < 0.8
        ? target
        : position.pixels + distance * followFraction;

    _streamScrollAnimating = true;
    try {
      _scrollController.jumpTo(next.clamp(0.0, target).toDouble());
    } finally {
      _streamScrollAnimating = false;
    }
    if (!disableAnimations && (target - next).abs() >= 0.5) {
      _scheduleStreamScrollFollow();
    }
  }

  Widget _buildInitializationError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sync_problem_rounded,
              size: 42,
              color: YanciTheme.accent.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 12),
            Text(
              L.pick(
                en: 'This conversation could not be loaded safely.',
                zhTW: '無法安全載入這個對話。',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: YanciTheme.textPrimary, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              L.pick(
                en: 'No message was sent. Retry, or return to the conversation list.',
                zhTW: '目前沒有送出任何訊息。請重試，或返回對話列表。',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: YanciTheme.textSecondary, fontSize: 12),
            ),
            if (_initializationError.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _initializationError,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: YanciTheme.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_walletChanged),
                  child: Text(L.pick(en: 'Back', zhTW: '返回')),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _retryInitialization,
                  child: Text(L.pick(en: 'Retry', zhTW: '重試')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ThemedNoticeAnchorScope(
      link: _noticeAnchorLink,
      child: GradientBackground(
        scope: YanciBackgroundScope.chat,
        presetOverride: _boundBackgroundPreset,
        chatPaletteOverride: _boundChatPalette,
        foregroundOverride: _boundChatForeground,
        // The visual background owns the full window. Only the inner Scaffold
        // responds to IME insets, so particles and custom imagery no longer
        // resize or jump when the keyboard opens.
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 96,
              child: YanciTheme.starEnabled
                  ? AmbientParticleField(
                      starCount: 10,
                      isBusy:
                          _isGenerating ||
                          _userIsScrolling ||
                          _streamScrollAnimating,
                    )
                  : const SizedBox.shrink(),
            ),
            Scaffold(
              backgroundColor: Colors.transparent,
              // Keep the composer above the IME and let the message viewport
              // use the remaining height without resizing the background.
              resizeToAvoidBottomInset: true,
              body: GestureDetector(
                onTap: () => FocusScope.of(context).unfocus(),
                child: SafeArea(
                  child: Column(
                    children: [
                      const SizedBox(height: _chatHeaderHeight),
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _isLoading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : _initializationFailed
                                ? _buildInitializationError()
                                : _messages.isEmpty &&
                                      _streamingText.isEmpty &&
                                      !_isGenerating
                                ? _buildEmptyState()
                                : Positioned(
                                    key: const ValueKey(
                                      'chat-message-viewport-underlay',
                                    ),
                                    top: -_chatHeaderHeight,
                                    left: 0,
                                    right: 0,
                                    bottom: -_composerViewportUnderlay,
                                    child: ScrollEdgeFade(
                                      controller: _scrollController,
                                      topInset: _chatHeaderHeight - 12,
                                      topExtent: _chatHeaderHeight + 70,
                                      bottomExtent: 104,
                                      blurSigma: 0,
                                      topBlurSigma: 0,
                                      bottomBlurSigma: 0,
                                      alwaysFadeTop: true,
                                      alwaysFadeBottom: true,
                                      child: _buildMessageList(),
                                    ),
                                  ),
                            // 一鍵滾底按鈕
                            if (_showScrollToBottom)
                              Positioned(
                                right: YanciTheme.spacingMd,
                                bottom: YanciTheme.spacingSm,
                                child: GestureDetector(
                                  onTap: () {
                                    _userScrolledUp = false;
                                    _scrollToBottom(force: true);
                                  },
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: YanciTheme.glassInputBg,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 22,
                                      color: YanciTheme.accent,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      CompositedTransformTarget(
                        link: _noticeAnchorLink,
                        child: const SizedBox(
                          key: ValueKey('chat-notice-anchor'),
                          width: double.infinity,
                          height: 0,
                        ),
                      ),
                      // ═══ 待發圖片預覽 ═══
                      if (_pendingImagePaths.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                          child: ImageCardStack(
                            paths: _pendingImagePaths,
                            height: 124,
                            removable: true,
                            onTap: _openPendingImagePreview,
                            onLongPress: _openPendingImagePreview,
                            onRemove: (index) {
                              if (index < 0 ||
                                  index >= _pendingImagePaths.length) {
                                return;
                              }
                              setState(
                                () => _pendingImagePaths.removeAt(index),
                              );
                            },
                          ),
                        ),
                      // ═══ 待發表情包預覽 ═══
                      if (_pendingSticker != null)
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(_pendingSticker!.filePath),
                                  width: 48,
                                  height: 48,
                                  cacheWidth:
                                      StickerPreviewQuality.cacheDimension(
                                        context,
                                        logicalSize: 48,
                                        previousMinimum: 64,
                                      ),
                                  cacheHeight:
                                      StickerPreviewQuality.cacheDimension(
                                        context,
                                        logicalSize: 48,
                                        previousMinimum: 64,
                                      ),
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.medium,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 48,
                                    height: 48,
                                    color: YanciTheme.glassInputBg,
                                    child: const Icon(
                                      Icons.broken_image,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _pendingSticker!.line ??
                                      _pendingSticker!.mood ??
                                      '',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _pendingSticker = null),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // ═══ 待發轉帳預覽 ═══
                      if (_pendingUserTransfer != null)
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFF2C96D,
                                  ).withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(
                                      0xFFF2C96D,
                                    ).withValues(alpha: 0.35),
                                    width: 0.8,
                                  ),
                                ),
                                child: Center(
                                  child: Image.asset(
                                    'assets/images/shell_coin.png',
                                    width: 24,
                                    height: 24,
                                    filterQuality: FilterQuality.none,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  L.pick(
                                    en: 'Transfer ${_pendingUserTransfer!.amount} shells',
                                    zhTW: L.pick(
                                      en: 'Pending transfer: ${_pendingUserTransfer!.amount} shells',
                                      zhTW:
                                          '待轉帳 ${_pendingUserTransfer!.amount} 貝殼',
                                    ),
                                  ),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _pendingUserTransfer = null),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // ═══ 待發刮刮卡預覽（讓 TA 刮）═══
                      if (_pendingScratchGiftWho != null)
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.10,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.28,
                                    ),
                                    width: 0.8,
                                  ),
                                ),
                                child: Icon(
                                  Icons.confirmation_number_outlined,
                                  size: 24,
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.78,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  L.pick(
                                    en: 'Scratch card for them',
                                    zhTW: '待發刮刮卡：讓 TA 刮',
                                  ),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () => setState(
                                  () => _pendingScratchGiftWho = null,
                                ),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // ═══ 圖片生成中 banner ═══
                      if (_isGeneratingImage)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: YanciTheme.accent.withValues(alpha: 0.08),
                            border: Border(
                              bottom: BorderSide(
                                color: YanciTheme.accent.withValues(
                                  alpha: 0.12,
                                ),
                                width: 0.5,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                L.pick(
                                  en: 'Generating image...',
                                  zhTW: '圖片生成中……',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_manualSummarySelecting)
                        _buildManualSummarySelectionBar()
                      else
                        IgnorePointer(
                          ignoring: !_isChatReady,
                          child: Opacity(
                            opacity: _isChatReady ? 1 : 0.45,
                            child: ValueListenableBuilder<ToolFeatureState>(
                              valueListenable: ToolFeatureSettings.state,
                              builder: (context, toolFeatures, _) => InputBar(
                                externalController: _inputController,
                                hintText: _composerHint.isEmpty
                                    ? null
                                    : _composerHint,
                                onSend: (text) => _onSendMessage(
                                  text,
                                  clearComposerOnAccept: true,
                                ),
                                isSendBlocked:
                                    !_isChatReady ||
                                    _sendSubmissionInProgress ||
                                    _isGenerating ||
                                    _isGeneratingImage ||
                                    _localModelLoading,
                                hasPendingContent:
                                    _pendingImagePaths.isNotEmpty ||
                                    _pendingSticker != null ||
                                    _pendingUserTransfer != null ||
                                    _pendingScratchGiftWho != null ||
                                    _pendingGift != null,
                                isGeneratingImage: _isGeneratingImage,
                                isGeneratingResponse: _isGenerating,
                                onStopGeneration: () {
                                  if (_isGenerating) {
                                    _stopActiveGeneration();
                                  } else {
                                    setState(() => _isGeneratingImage = false);
                                  }
                                },
                                onImagesPicked: (paths) {
                                  var overflowed = false;
                                  setState(() {
                                    for (final path in paths) {
                                      if (_pendingImagePaths.contains(path)) {
                                        continue;
                                      }
                                      if (_pendingImagePaths.length >= 10) {
                                        overflowed = true;
                                        break;
                                      }
                                      _pendingImagePaths.add(path);
                                    }
                                  });
                                  if (overflowed) {
                                    _showChatNotice(
                                      L.pick(
                                        en: 'You can send up to 10 images at a time.',
                                        zhTW: '每次最多可發送 10 張圖片',
                                        zhCN: '每次最多可发送 10 张图片',
                                      ),
                                    );
                                  }
                                },
                                onStickerTap: _showStickerPicker,
                                onScratchGift: _onScratchGift,
                                onShopGift: _openChatShop,
                                onBackpackTap: _openChatBackpack,
                                onStoryArchiveTap:
                                    _sessionIdentity?.contextMode ==
                                        ContextMode.rp
                                    ? _openRpStoryArchive
                                    : null,
                                onCallTap:
                                    _sessionIdentity?.contextMode ==
                                        ContextMode.daily
                                    ? () => _openCall()
                                    : null,
                                pendingGiftName: _pendingGift?.itemName,
                                onCancelGift: _cancelPendingGift,
                                onTransfer: _onTransferToChar,
                                showTransfer: toolFeatures.transferEnabled,
                                showScratch: toolFeatures.scratchEnabled,
                                showShop: toolFeatures.shopEnabled,
                                showBackpack: toolFeatures.shopEnabled,
                                showMarriageCert:
                                    _marriageUnlocked && !_pendingMarriageCert,
                                onMarriageCert: () =>
                                    setState(() => _pendingMarriageCert = true),
                                marriageCertPending: _pendingMarriageCert,
                                onCancelMarriageCert: () => setState(
                                  () => _pendingMarriageCert = false,
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
            if (_costModeRecommendation != null)
              Positioned.fill(
                child: ChatCostModeGuideTrail(
                  key: ValueKey<int>(_costModeGuideRevision),
                  color: YanciTheme.accent,
                  targetDx: MediaQuery.sizeOf(context).width * 0.59,
                  targetDy: MediaQuery.paddingOf(context).top + 18,
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(bottom: false, child: _buildAppBar()),
            ),
          ],
        ),
      ),
    );
  }

  void _openPendingImagePreview(String imagePath) {
    if (imagePath.trim().isEmpty) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(),
                    child: const SizedBox.expand(),
                  ),
                  Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.file(
                          File(imagePath),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 16,
                    child: IconButton(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showChatNotice(
    String message, {
    Duration duration = const Duration(milliseconds: 3600),
    ThemedNoticeTone tone = ThemedNoticeTone.neutral,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    showThemedPillNotice(
      context,
      message,
      duration: duration,
      tone: tone,
      action: actionLabel != null && onAction != null
          ? ThemedNoticeAction(label: actionLabel, onPressed: onAction)
          : null,
      anchorLink: _noticeAnchorLink,
    );
  }

  /// 歷史搜尋卡片（類似 Claude 搜索網頁的展開卡片）
  Widget _buildSearchCard() {
    final isSearching = _chatSearching;
    final results = _chatSearchResults;
    final query = _chatSearchQuery;
    return Padding(
      padding: EdgeInsets.only(
        left: YanciTheme.spacingMd,
        right: MediaQuery.of(context).size.width * 0.2,
        top: 4,
        bottom: 4,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: YanciTheme.accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: YanciTheme.accent.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 13,
                  color: YanciTheme.accent.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${L.pick(en: 'Searching', zhTW: '搜尋', zhCN: '搜索')}「$query」',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: YanciTheme.accent.withValues(alpha: 0.85),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSearching)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: YanciTheme.accent.withValues(alpha: 0.6),
                    ),
                  )
                else
                  Text(
                    results.isEmpty
                        ? (L.pick(en: 'No results', zhTW: '無結果', zhCN: '无结果'))
                        : '${results.length} ${L.pick(en: 'found', zhTW: '條', zhCN: '条')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: YanciTheme.accent.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
            // Results
            if (!isSearching && results.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...results.take(3).map((r) {
                final who = (r['is_user'] as int) == 1 ? '👤' : '🤖';
                final date = (r['created_at'] as String).substring(0, 10);
                var text = r['text'] as String;
                if (text.length > 60) text = '${text.substring(0, 60)}…';
                final mode = ContextMode.fromStorage(r['context_mode']);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ContextModeLabel(mode: mode, compact: true),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '$who $date  $text',
                          style: TextStyle(
                            fontSize: 10,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.7,
                            ),
                            height: 1.4,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (results.length > 3)
                Text(
                  '…${L.pick(en: 'and ${results.length - 3} more', zhTW: '還有 ${results.length - 3} 條')}',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRpContinuationHeader() {
    final expanded = _rpContinuationSourceExpanded;
    final actionLabel = expanded
        ? L.pick(en: 'Collapse', zhTW: '收起', zhCN: '收起')
        : L.pick(
            en: 'Pull down or tap to open the original window',
            zhTW: '下拉或點擊查看原窗口',
            zhCN: '下拉或点击查看原窗口',
          );
    final title = _rpContinuationSourceTitle.isEmpty
        ? L.pick(en: 'Previous window', zhTW: '上一窗口', zhCN: '上一窗口')
        : _rpContinuationSourceTitle;
    return Semantics(
      button: true,
      label: '$title，$actionLabel',
      child: InkWell(
        key: const ValueKey('rp-continuation-source-header'),
        onTap: _rpContinuationSourceLoading
            ? null
            : () => unawaited(_toggleRpContinuationSourceHistory()),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      L.pick(
                        en: 'FROM THE PREVIOUS WINDOW',
                        zhTW: '來自上一窗口',
                        zhCN: '来自上一窗口',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 9.5,
                        letterSpacing: 0.8,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 12.5,
                        color: YanciTheme.accent.withValues(alpha: 0.82),
                      ),
                    ),
                    if (!expanded) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        L.pick(
                          en: 'Pull down or tap to view earlier messages',
                          zhTW: '下拉或點擊可查看更早原文',
                          zhCN: '下拉或点击可查看更早原文',
                        ),
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 9.5,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.42,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (_rpContinuationSourceLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.2,
                    color: YanciTheme.accent.withValues(alpha: 0.55),
                  ),
                )
              else
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: YanciTheme.accent.withValues(alpha: 0.55),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRpContinuationBoundary() => Semantics(
    label: L.pick(
      en: 'The current window continues from here',
      zhTW: '本窗口從這裡接續',
      zhCN: '本窗口从这里接续',
    ),
    child: Padding(
      key: const ValueKey('rp-continuation-boundary'),
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              height: 0.6,
              color: YanciTheme.accent.withValues(alpha: 0.18),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              L.pick(en: 'continued here', zhTW: '本窗口從這裡接續', zhCN: '本窗口从这里接续'),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10.5,
                letterSpacing: 0.25,
                color: YanciTheme.accent.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 0.6,
              color: YanciTheme.accent.withValues(alpha: 0.18),
            ),
          ),
        ],
      ),
    ),
  );





  // ═══════════════ 通話 ═══════════════


  /// 模型短名

  /// 模型全名（不截斷，供 picker / marquee 使用）



  /// 流式文字拆分（用於拆分回覆時的即時渲染）
  List<String> _streamingSplitParts() {
    final display = _displayStreamingText;
    if (display.isEmpty) return [''];
    final parts = display
        .split('\n\n')
        .where((p) => p.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? [display] : parts;
  }

  (String, Color)? _getCacheDisplay(String provider, ApiUsage usage) {
    final stats = usage.raw;
    switch (provider) {
      case 'xai':
        final read = usage.cacheReadTokens;
        if (read > 0) {
          return (
            '⚡ grok cache hit ${read}t',
            Colors.green.withValues(alpha: 0.6),
          );
        }
        return null;
      case 'openrouter':
        final read = usage.cacheReadTokens;
        final created = usage.cacheCreationTokens;
        if (read > 0) {
          return ('⚡ cache hit ${read}t', Colors.green.withValues(alpha: 0.6));
        }
        if (created > 0) {
          return (
            '📦 cache created ${created}t',
            Colors.orange.withValues(alpha: 0.6),
          );
        }
        return null;
      case 'deepseek':
        final hit = stats['cache_hit'] ?? 0;
        final miss = stats['cache_miss'] ?? 0;
        if (hit > 0) {
          return (
            '⚡ ds cache hit ${hit}t',
            Colors.green.withValues(alpha: 0.6),
          );
        }
        if (miss > 0) {
          return (
            '📦 ds cache miss ${miss}t',
            Colors.orange.withValues(alpha: 0.6),
          );
        }
        return null;
      case 'gemini':
        final cached = usage.cacheReadTokens;
        final status = stats['cache_status'] ?? -2;
        if (cached > 0) {
          return (
            '⚡ gemini cache hit ${cached}t',
            Colors.green.withValues(alpha: 0.6),
          );
        }
        if (status == 1) {
          return (
            '📦 gemini cache created',
            Colors.orange.withValues(alpha: 0.6),
          );
        }
        if (status == 0) {
          final threshold = stats['cache_threshold'] ?? 0;
          return (
            threshold > 0
                ? '💤 gemini prompt < ${threshold}t'
                : '💤 gemini prompt below cache min',
            YanciTheme.textSecondary.withValues(alpha: 0.4),
          );
        }
        return null;
      case 'bedrock':
        final read = usage.cacheReadTokens;
        final created = usage.cacheCreationTokens;
        if (read > 0) {
          return (
            '⚡ bedrock cache hit ${read}t',
            Colors.green.withValues(alpha: 0.6),
          );
        }
        if (created > 0) {
          return (
            '📦 bedrock cache created ${created}t',
            Colors.orange.withValues(alpha: 0.6),
          );
        }
        return null;
      default:
        return null;
    }
  }
}

class _WindowSummaryEditorSheet extends StatefulWidget {
  final String initialContent;

  const _WindowSummaryEditorSheet({required this.initialContent});

  @override
  State<_WindowSummaryEditorSheet> createState() =>
      _WindowSummaryEditorSheetState();
}

class _WindowSummaryEditorSheetState extends State<_WindowSummaryEditorSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final content = _controller.text.trim();
    if (content.isEmpty) return;
    Navigator.pop(context, content);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                L.pick(
                  en: 'Current window summary',
                  zhTW: '目前窗口摘要',
                  zhCN: '当前窗口摘要',
                ),
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 6),
              Text(
                L.pick(
                  en: 'Edits affect later summary recall. The cache snapshot already pinned when this window opened remains unchanged.',
                  zhTW: '修改會套用到後續摘要召回；本窗口開啟時已釘選的 cache 快照不會被改寫。',
                  zhCN: '修改会应用到后续摘要召回；本窗口开启时已固定的 cache 快照不会被改写。',
                ),
                style: YanciTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: TextField(
                  controller: _controller,
                  minLines: 8,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: YanciTheme.bodyText.copyWith(height: 1.5),
                  decoration: InputDecoration(
                    hintText: L.pick(
                      en: 'Summary content',
                      zhTW: '摘要內容',
                      zhCN: '摘要内容',
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _RpContinuationDisplayKind { header, boundary }

enum _ContinuationStartMode { userFirst, characterFirst }

class _ContinuationChoice {
  const _ContinuationChoice({required this.source, required this.mode});

  final RpChapterContinuationSource source;
  final _ContinuationStartMode mode;
}

/// 顯示用消息項（支持拆分回覆）
class _DisplayItem {
  static final streamingAssistant = _DisplayItem(
    text: '',
    isUser: false,
    messageId: 'streaming_group_probe',
    originalIndex: -1,
    showToolbar: false,
  );

  final String text;
  final bool isUser;
  final DateTime? timestamp;
  final String? imagePath;
  final List<String> imagePaths;
  final String messageId;
  final int? dbMessageId;
  final int originalIndex;
  final bool showToolbar;
  final bool cacheHit;
  final bool incomplete;
  final String memoryLog;
  final int pendingMemoryActionCount;
  final bool hasUnreadMemoryActions;

  /// 短生命週期的結構化網搜結果；只掛在本次 session 的最後一個角色氣泡。
  final WebSearchBatchResult? webSearchResult;

  /// 可持久化的最小顯示紀錄；重新進入對話後仍能重建 Thinking。
  final WebSearchDisplayTrace? webSearchTrace;

  /// 模型產生、用戶可編輯的本機郵件草稿；永不進提示詞。
  final EmailDraft? emailDraft;

  /// Local persona proposal attached to this exact assistant reply.
  final PersonaCardState? personaCard;

  /// 非空 → 這項渲染成居中分割線（通話已結束等），不渲染氣泡
  final String? callDivider;

  /// 分割線圖標（結束/拒接/未接各不同）
  final IconData? callDividerIcon;

  /// 非空 → 氣泡下方跟隨禮物卡片（[gift:名] 解析而來）
  final String? giftName;

  /// 禮物之後對方已回覆 → 卡片顯示「已收下」
  final bool giftAccepted;

  /// 消息帶結婚證邀請標記 → 氣泡下跟證書卡
  final bool hasMarriageCert;

  /// 證書是她遞出的（未簽時卡片可點擊簽署）
  final bool certFromChar;

  /// Exact automatic rolling summary shown after this UI anchor message.
  final int? summaryRecordedId;

  /// Non-null items are lightweight controls around the read-only source
  /// transcript virtually joined above an RP continuation.
  final _RpContinuationDisplayKind? continuationKind;

  _DisplayItem({
    required this.text,
    required this.isUser,
    this.timestamp,
    this.imagePath,
    this.imagePaths = const <String>[],
    required this.messageId,
    this.dbMessageId,
    required this.originalIndex,
    this.memoryLog = '',
    this.pendingMemoryActionCount = 0,
    this.hasUnreadMemoryActions = false,
    this.webSearchResult,
    this.webSearchTrace,
    this.emailDraft,
    this.personaCard,
    this.showToolbar = true,
    this.cacheHit = false,
    this.incomplete = false,
    this.callDivider,
    this.callDividerIcon,
    this.giftName,
    this.giftAccepted = false,
    this.hasMarriageCert = false,
    this.certFromChar = false,
    this.summaryRecordedId,
    this.continuationKind,
  });
}

bool _canGroupDisplayItems(_DisplayItem previous, _DisplayItem next) {
  if (previous.isUser != next.isUser) return false;
  if (previous.callDivider != null || next.callDivider != null) return false;
  if (previous.continuationKind != null || next.continuationKind != null) {
    return false;
  }
  if (previous.summaryRecordedId != null ||
      previous.emailDraft != null ||
      previous.personaCard != null) {
    return false;
  }
  return true;
}
