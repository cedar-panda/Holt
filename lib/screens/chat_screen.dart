import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../widgets/starfield_painter.dart';
import '../widgets/neural_field.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/input_bar.dart';
import '../widgets/atom_thinking.dart';
import '../services/api_adapter.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/deferred_prompt.dart';
import '../services/prompt_cache_channels.dart';
import '../services/model_cost_policy.dart';
import '../services/memory_actions.dart';
import '../services/memory_guard_service.dart';
import '../services/image_gen_service.dart';
import '../memory/emotion_coordinates.dart';
import '../services/token_tracker.dart';
import '../services/context_compressor.dart';
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
import '../services/whisper_service.dart';
import '../memory/spider_web_core.dart';
import '../services/spider_web_service.dart';
import '../services/local_model_service.dart';
import '../models/message.dart';
import '../models/chat_session_identity.dart';
import '../services/keep_alive_foreground.dart';
import '../services/keep_alive_service.dart';
import '../services/manual_summary_service.dart';
import '../services/scratch_service.dart';
import '../services/transfer_service.dart';
import '../widgets/scratch_card.dart';
import '../widgets/shop_backpack_sheets.dart';
import '../widgets/sticker_preview_quality.dart';
import '../widgets/long_screenshot_options_sheet.dart';
import '../widgets/chat_model_picker.dart';
import '../widgets/memory_review_tab.dart';
import '../widgets/web_search_activity_card.dart';
import '../widgets/web_search_result_card.dart';
import '../widgets/web_search_thinking_node.dart';
import '../widgets/email_draft_card.dart';
import 'call_screen.dart';
import 'manual_summary_clean_screen.dart';
import '../services/call_audio_pipeline.dart';
import '../services/chat_long_screenshot_service.dart';
import '../services/dream_curation_service.dart';

part 'chat_screen_generation.dart';
part 'chat_screen_actions.dart';
part 'chat_screen_web_search_follow_up.dart';
part 'chat_screen_email_drafts.dart';

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
          return query is String && query.trim().isNotEmpty
              ? null
              : 'chat.search requires a non-empty query.';
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

class _ChatScreenState extends State<ChatScreen> {
  void _refreshChatState(VoidCallback callback) => setState(callback);

  final List<Message> _messages = [];
  final GlobalKey _modelPickerAnchorKey = GlobalKey(
    debugLabel: 'chatModelPickerAnchor',
  );

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
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final TokenTracker _tokenTracker = TokenTracker();
  bool _isGenerating = false;
  bool _isGeneratingImage = false;
  bool _streamSurfaceVisible = false;
  bool _isCapturingLongScreenshot = false;

  bool _sendSubmissionInProgress = false;
  bool _isLoading = true;
  bool _isChatReady = false;
  bool _initializationFailed = false;
  String _initializationError = '';
  String _streamingText = '';
  String _currentModel = '';
  String _activeCharacterId = 'default';
  int _tokensSinceSummary = 0; // token 計數觸發
  Future<int>? _compressionInFlight;
  bool _showScrollToBottom = false;
  bool _userScrolledUp = false; // 流式輸出時用戶手動上滾 → 暫停自動跟隨
  bool _userIsScrolling = false;
  bool _shouldAutoName = false;
  String _conversationTitle = '';
  String _characterName = '';
  String _composerHint = '';
  String? _pendingImagePath;
  StickerInfo? _pendingSticker;
  String? _pendingScratchGiftWho;
  bool _splitReply = false;
  bool _isFirstRoundInWindow = true;
  bool _sentMessageInThisSession = false;
  bool _showChatAvatar = false;
  String? _userAvatarPath;
  String? _charAvatarPath;
  final Set<int> _cacheHitIndices = {};
  final Map<String, ScratchData> _scratchDataMap = {};
  final Map<String, TransferData> _transferDataMap = {};
  final Map<int, ({int total, int unread})> _pendingMemoryActionCounts = {};
  bool _walletChanged = false;
  List<Map<String, String>>? _lastKeepAliveMessages;
  StructuredPrompt? _lastKeepAliveStructuredPrompt;
  ApiAdapter? _lastKeepAliveAdapter;
  String? _lastKeepAliveModel;
  String? _lastKeepAliveProvider;
  int? _coinSnapshotChar;
  int? _coinSnapshotUser;
  String? _windowSummaryId;
  String? _cacheWindowSummaryStaticSnapshot;
  String? _promptLocaleSnapshot;
  OverlayEntry? _modelHintOverlay;
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
  static final _openToolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*$',
    multiLine: true,
    caseSensitive: false,
  );
  static final _completedTagRe = RegExp(
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|memo_link|force_recall|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|whisper|search_chat|search_web|call|scratch|transfer|transfer_accept|transfer_decline|x_post|pack_star|email_draft)\b[^>]*>'
    r'[\s\S]*?'
    r'</\1>',
    multiLine: true,
  );
  static final _openTagRe = RegExp(
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|memo_link|force_recall|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|whisper|search_chat|search_web|call|scratch|transfer|transfer_accept|transfer_decline|buy|x_post|shop_view|pack_star|sign_marriage|propose_marriage|email_draft)\b[\s\S]*$',
  );

  static final _scratchTagRe = RegExp(
    r'<scratch\s+[^>]*/>',
    caseSensitive: false,
  );
  static final _transferTagRe = RegExp(
    r'<transfer\s+[^>]*/>',
    caseSensitive: false,
  );
  static final _transferResponseRe = RegExp(
    r'<transfer_(accept|decline)\s*/>',
    caseSensitive: false,
  );
  static final _buyTagRe = RegExp(r'<buy\s+[^>]*/?>', caseSensitive: false);
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
  final List<String> _streamCharQueue = [];
  Timer? _streamPopTimer;
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
  }

  /// Resolve the conversation first, then initialize every character-scoped
  /// dependency from that immutable binding. The globally selected character
  /// is intentionally never consulted here.
  Future<void> _initializeChat() async {
    try {
      final conversation = await DatabaseHelper.getConversation(
        widget.conversationId,
      );
      final identity = ChatSessionIdentity.fromConversation(
        expectedConversationId: widget.conversationId,
        conversation: conversation,
      );
      if (!mounted) return;

      _activeCharacterId = identity.characterId;
      _pendingGift = await ShopService.getPendingGift(
        scopeId: widget.conversationId,
        targetCharacterId: _activeCharacterId,
      );
      await Future.wait<void>([_loadSettings(conversation!), _loadMessages()]);
      unawaited(_refreshMarriageState());
      if (!mounted) return;

      setState(() {
        _isChatReady = true;
        _isLoading = false;
        _initializationFailed = false;
      });
      _scrollToBottom();
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _scrollToBottom();
      });
      // 分支對話：帶進來的編輯文本自動發出（走完整管線）
      final autoSend = widget.initialAutoSendText?.trim();
      if (autoSend != null && autoSend.isNotEmpty && !_autoSendFired) {
        _autoSendFired = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onSendMessage(autoSend);
        });
      }
      unawaited(
        _claimVisibleKeepAliveWindow().catchError((Object error) {
          debugPrint('Unable to claim keep-alive window: $error');
        }),
      );
    } catch (error, stackTrace) {
      debugPrint('Chat initialization failed: $error\n$stackTrace');
      if (KeepAliveService.instance.activeConversationId ==
          widget.conversationId) {
        await KeepAliveService.instance.stop();
      }
      if (!mounted) return;
      setState(() {
        _isChatReady = false;
        _isLoading = false;
        _initializationFailed = true;
        _initializationError = '$error';
      });
    }
  }

  void _retryInitialization() {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _isChatReady = false;
      _initializationFailed = false;
      _initializationError = '';
      _messages.clear();
      _cacheHitIndices.clear();
      _scratchDataMap.clear();
      _transferDataMap.clear();
      _pendingMemoryActionCounts.clear();
      _tokensSinceSummary = 0;
      _charAvatarPath = null;
    });
    unawaited(_initializeChat());
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final distanceFromBottom =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    final shouldShow = distanceFromBottom > 200;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
    // 流式輸出中用戶手動上滾 → 暫停自動跟隨
    if (_isGenerating && distanceFromBottom > 80) {
      _userScrolledUp = true;
    }
  }

  Future<void> _loadSettings(Conversation conversation) async {
    _currentModel = await ApiSettings.getModel();
    _splitReply = await MemorySettings.getSplitReply();
    _showChatAvatar = await UserSettings.getShowChatAvatar();

    // 用戶頭像
    final uAvatar = await UserSettings.getUserAvatarPath();
    if (uAvatar.isNotEmpty) _userAvatarPath = uAvatar;

    // 角色頭像與蛛網背景引擎
    var char = await DatabaseHelper.getCharacter(_activeCharacterId);
    if (char == null) {
      // 角色 ID 失效（可能是 'default' 或已刪除）→ 嘗試恢復到第一個角色
      debugPrint(
        'Character $_activeCharacterId not found for conversation '
        '${conversation.id}, attempting recovery…',
      );
      final allChars = await DatabaseHelper.getCharacters();
      if (allChars.isEmpty) {
        throw StateError(
          'No characters exist. Character $_activeCharacterId for '
          'conversation ${conversation.id} could not be resolved.',
        );
      }
      final fallbackChar = allChars.first;
      final fallbackId = fallbackChar['id'] as String;
      // 修正對話的角色綁定 + 全域偏好
      await DatabaseHelper.updateConversationCharacter(
        conversation.id,
        fallbackId,
      );
      await UserSettings.saveActiveCharacterId(fallbackId);
      _activeCharacterId = fallbackId;
      char = fallbackChar;
      debugPrint('Recovered to character $fallbackId');
    }
    _characterName = char['name'] as String? ?? '';
    _charAvatarPath = char['avatar_path'] as String?;
    _composerHint = CharacterWhisperState.fromCharacter(char).displayText;

    // 背景執行：蛛網封存引擎 (清理30天未觸發的孤島記憶)
    if ((char['is_spider_web_enabled'] as int? ?? 0) == 1) {
      SpiderWebCore.runArchiveEngine(characterId: _activeCharacterId).then((
        archivedCount,
      ) {
        if (archivedCount > 0) {
          debugPrint(
            'SpiderWeb Engine: Archived $archivedCount fading memories.',
          );
        }
      });
    }

    if (!mounted) return;
    if (conversation.title != null && conversation.title!.isNotEmpty) {
      _conversationTitle = conversation.title!;
    }

    // ═══ 本地模型預加載：進聊天頁就開始，不等發送 ═══
    if (LocalModelService.isLocalModelId(_currentModel)) {
      setState(() => _localModelLoading = true);
      try {
        await ApiSettings.buildAdapter();
      } catch (e) {
        debugPrint('Local model pre-load failed: $e');
      }
      if (mounted) setState(() => _localModelLoading = false);
    }
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

  Future<void> _persistContextAnchor(int messageId) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_ctxAnchorKey, messageId);
    } catch (_) {}
  }

  /// 錨點之前的歷史往前再掛一頁（純顯示，不進上下文）
  Future<void> _loadOlderForDisplay() async {
    if (_olderLoading || !_olderHasMore) return;
    _olderLoading = true;
    try {
      final beforeId = _olderMessages.isNotEmpty
          ? _olderMessages.first.id
          : (_messages.isNotEmpty ? _messages.first.id : null);
      if (beforeId == null) {
        _olderHasMore = false;
        return;
      }
      final older = await DatabaseHelper.getMessagesBeforeId(
        widget.conversationId,
        beforeId,
        limit: _renderPageSize,
      );
      // 這批消息的刮卡/轉帳卡數據順帶載入
      for (final m in older) {
        if (m.id != null) {
          final key = 'msg_${m.id}';
          final sd = await ScratchService.getData(key);
          if (sd != null) _scratchDataMap[key] = sd;
          final td = await TransferService.getData(key);
          if (td != null) _transferDataMap[key] = td;
        }
      }
      if (!mounted) return;
      setState(() {
        if (older.isEmpty) {
          _olderHasMore = false;
        } else {
          _olderMessages.insertAll(0, older);
          if (older.length < _renderPageSize) _olderHasMore = false;
        }
      });
    } finally {
      _olderLoading = false;
    }
  }

  Future<void> _loadMessages() async {
    final p = await SharedPreferences.getInstance();
    final anchorId = p.getInt(_ctxAnchorKey);

    List<Message> messages;
    if (anchorId != null) {
      messages = await DatabaseHelper.getMessagesFromId(
        widget.conversationId,
        anchorId,
      );
      if (messages.isEmpty) {
        // 錨點失效（消息被清/導入重建）→ 回退最新 50 並重錨
        messages = await DatabaseHelper.getMessages(
          widget.conversationId,
          limit: 50,
        );
        final firstId = messages.isNotEmpty ? messages.first.id : null;
        if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
      } else if (messages.length > _ctxAnchorMaxMessages) {
        // 窗口太長：推進錨點（此輪炸一次緩存，換 UI/token 不無限膨脹）
        messages = messages.sublist(messages.length - 50);
        final firstId = messages.first.id;
        if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
      }
    } else {
      messages = await DatabaseHelper.getMessages(
        widget.conversationId,
        limit: 50,
      );
      final firstId = messages.isNotEmpty ? messages.first.id : null;
      if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
    }
    if (!mounted) return;
    // 載入已有的刮刮樂 / 轉帳數據
    for (final msg in messages) {
      if (msg.id != null) {
        final key = 'msg_${msg.id}';
        final sd = await ScratchService.getData(key);
        if (sd != null) _scratchDataMap[key] = sd;
        final td = await TransferService.getData(key);
        if (td != null) _transferDataMap[key] = td;
      }
    }
    // 錨點之前是否還有歷史（決定翻完窗口後「查看更早」是否繼續）
    final windowFirstId = messages.isNotEmpty ? messages.first.id : null;
    final hasBefore = windowFirstId != null
        ? await DatabaseHelper.hasMessagesBefore(
            widget.conversationId,
            windowFirstId,
          )
        : false;
    final pendingMemoryActions =
        await MemoryGuardService.pendingCountsByMessage(widget.conversationId);

    if (!mounted) return;
    setState(() {
      // 清空重建而非 addAll：通話結束等場景會再次調用本方法，
      // 疊加會讓整窗消息雙份（UI 重複 + 發送歷史前綴變 → 炸緩存）
      _messages
        ..clear()
        ..addAll(messages);
      // 渲染窗：只掛最近一頁，更早的點按鈕再掛（發送仍用全窗）
      _renderFrom = (_messages.length - _renderPageSize).clamp(
        0,
        _messages.length,
      );
      _olderMessages.clear();
      _olderHasMore = hasBefore;
      _pendingMemoryActionCounts
        ..clear()
        ..addAll(pendingMemoryActions);
      _cacheHitIndices.clear();
      for (int i = 0; i < _messages.length; i++) {
        if (_messages[i].cacheHit) {
          _cacheHitIndices.add(i);
        }
      }
    });

    // 非同步還原 _tokensSinceSummary，防止退出窗口導致 token 重新歸零
    await _restoreTokensSinceSummary();

    // 舊消息可能已經完成摘要但被模型漏掉生理週期候選；開窗時用本地
    // 游標補掃一次，之後只查新增消息，不新增摘要模型請求。
    try {
      await _scanExplicitMenstrualTimeline();
    } catch (error) {
      debugPrint('開窗補記生理期時間線失敗：$error');
    }
  }

  Future<void> _refreshPendingMemoryActionCounts({bool notify = true}) async {
    final counts = await MemoryGuardService.pendingCountsByMessage(
      widget.conversationId,
    );
    if (!mounted) return;
    if (notify) {
      setState(() {
        _pendingMemoryActionCounts
          ..clear()
          ..addAll(counts);
      });
    } else {
      _pendingMemoryActionCounts
        ..clear()
        ..addAll(counts);
    }
  }

  Future<void> _bindMemoryProposalsToMessage(int messageId) async {
    final proposalIds = MemoryActions.lastProposalIdsFor(widget.conversationId);
    if (proposalIds.isEmpty) return;
    await MemoryGuardService.bindToMessage(
      proposalIds: proposalIds,
      conversationId: widget.conversationId,
      messageId: messageId,
    );
    await _refreshPendingMemoryActionCounts(notify: false);
  }

  Future<void> _openMemoryReview(int sourceMessageId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.86,
        child: Container(
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'Memory proposals from this reply',
                          zhTW: '這則回覆的記憶提案',
                          zhCN: '这则回复的记忆提案',
                        ),
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: MemoryReviewTab(
                  characterId: _activeCharacterId,
                  sourceMessageId: sourceMessageId,
                  onChanged: () => _refreshPendingMemoryActionCounts(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _refreshPendingMemoryActionCounts();
  }

  String get _tokensSinceSummaryKey =>
      'conversation:${widget.conversationId}:tokensSinceSummary';

  String get _timelineMenstrualScanCursorKey =>
      'conversation:${widget.conversationId}:timelineMenstrualScanCursor';

  /// 本地時間線補掃游標：每個對話只查上次成功掃描後的新消息。
  /// 這是 SQLite/SharedPreferences 狀態，不是 prompt cache。
  Future<void> _scanExplicitMenstrualTimeline() async {
    final prefs = await SharedPreferences.getInstance();
    final cursor = prefs.getInt(_timelineMenstrualScanCursorKey) ?? 0;
    final messages = await DatabaseHelper.getMessagesAfterId(
      widget.conversationId,
      cursor,
    );
    if (messages.isEmpty) return;

    final maxId = messages
        .map((message) => message.id ?? 0)
        .fold<int>(cursor, (max, id) => id > max ? id : max);
    await CharacterTimelineService.storeExplicitMenstrualMessages(
      characterId: _activeCharacterId,
      messages: messages,
    );
    await prefs.setInt(_timelineMenstrualScanCursorKey, maxId);
  }

  @override
  void dispose() {
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

    MemorySettings.getWindowSummaryEnabled()
        .then((enabled) {
          if (!enabled) return;
          if (!_sentMessageInThisSession && _lastKeepAliveMessages == null) {
            return;
          }
          Future.microtask(() async {
            try {
              final triggerTokenLimit = await _windowSummaryTriggerTokenLimit();
              final minTokenThreshold =
                  await _windowSummaryCloseMinTokenThreshold();
              final compressedTokens = await ContextCompressor.compressOnClose(
                conversationId: convId,
                characterId: charId,
                triggerTokenLimit: triggerTokenLimit,
                minTokenThreshold: minTokenThreshold,
                thresholdTokenCount: _tokensSinceSummary,
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

    if (shouldMaintainWindow) {
      KeepAliveService.instance.start(
        conversationId: convId,
        characterId: charId,
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
    _modelHintOverlay?.remove();
    _modelHintOverlay = null;
    _scrollController.dispose();
    _inputController.dispose();
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

  void _scrollToBottom({bool force = false}) {
    // 流式輸出時用戶手動上滾了 → 不強制跟隨（除非 force）
    if (_userIsScrolling || (_userScrolledUp && !force)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // callback 排隊後，用戶可能才開始拖曳內容或互動式捲動條。
      // 再檢查一次，避免手放開時被舊的自動到底動作搶回位置。
      if (_scrollController.hasClients &&
          !_userIsScrolling &&
          (force || !_userScrolledUp)) {
        if (_isGenerating) {
          // 流式輸出中：直接跳轉，不做動畫（避免每個 token 都觸發 300ms 動畫卡頓）
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        } else {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    });
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
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: GradientBackground(
          scope: YanciBackgroundScope.chat,
          child: Stack(
            children: [
              Positioned.fill(
                child: YanciTheme.starEnabled
                    ? (YanciTheme.bgEffect == 'stars'
                          ? const StarfieldWidget(starCount: 10)
                          : const NeuralFieldWidget(nodeCount: 18))
                    : const SizedBox.shrink(),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _buildAppBar(),
                    Expanded(
                      child: Stack(
                        children: [
                          _isLoading
                              ? const Center(child: CircularProgressIndicator())
                              : _initializationFailed
                              ? _buildInitializationError()
                              : _messages.isEmpty &&
                                    _streamingText.isEmpty &&
                                    !_isGenerating
                              ? _buildEmptyState()
                              : _buildMessageList(),
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
                    // ═══ 待發圖片預覽 ═══
                    if (_pendingImagePath != null)
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(_pendingImagePath!),
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
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
                                L.get('chat_image_hint'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _pendingImagePath = null),
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
                              onTap: () =>
                                  setState(() => _pendingScratchGiftWho = null),
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
                              color: YanciTheme.accent.withValues(alpha: 0.12),
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
                                color: YanciTheme.accent.withValues(alpha: 0.6),
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
                                color: YanciTheme.accent.withValues(alpha: 0.7),
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
                          child: InputBar(
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
                                _pendingImagePath != null ||
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
                            onImagePicked: (path) {
                              setState(() => _pendingImagePath = path);
                            },
                            onStickerTap: _showStickerPicker,
                            onScratchGift: _onScratchGift,
                            onShopGift: _openChatShop,
                            onBackpackTap: _openChatBackpack,
                            pendingGiftName: _pendingGift?.itemName,
                            onCancelGift: _cancelPendingGift,
                            onTransfer: _onTransferToChar,
                            showMarriageCert:
                                _marriageUnlocked && !_pendingMarriageCert,
                            onMarriageCert: () =>
                                setState(() => _pendingMarriageCert = true),
                            marriageCertPending: _pendingMarriageCert,
                            onCancelMarriageCert: () =>
                                setState(() => _pendingMarriageCert = false),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '$who $date  $text',
                    style: TextStyle(
                      fontSize: 10,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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

  Widget _buildMessageList() {
    final hasWebSearchActivity = _webSearchActivity != null;
    // Search owns the pending assistant surface. The model's tool-call preface
    // must not appear as a second bubble above Thinking/search status.
    // 建立生成任務時就掛上流式氣泡，而不是等第一個可見字元到達後才插入。
    // 各來源首包大小不同，但都共用同一個 ChatBubble，因而能走一致的 QQ
    // 彈彈入場動畫；內容仍由既有 stream queue 逐字填入。
    final hasStreamingBubble =
        _isGenerating &&
        _streamSurfaceVisible &&
        !_isGeneratingImage &&
        !hasWebSearchActivity;
    final pendingWebSearchTrace = _pendingWebSearchResult?.toDisplayTrace();
    // Web search owns the active Thinking surface. Avoid rendering the generic
    // atom above it, which otherwise looks like an empty assistant bubble.
    // 文字生成使用上方的 QQ 流式氣泡；原子動畫只保留給圖片生成。
    final showAtom =
        _isGenerating &&
        _isGeneratingImage &&
        _streamingText.isEmpty &&
        !hasWebSearchActivity;

    // 構建顯示列表（拆分回覆時 AI 消息按段落拆開）
    // 渲染窗：只掛 _renderFrom 起的消息；i 保持全量索引（editMessage 等依賴）
    final renderFrom = _renderFrom.clamp(0, _messages.length);
    final hasOlderButton = renderFrom > 0 || _olderHasMore;
    // 渲染源 = 錨點前純顯示段（永不進上下文）+ 發送窗的渲染段。
    // 純顯示段 originalIndex 為 -1：編輯/重發等窗內索引操作不適用。
    final renderSource = <(Message, int)>[
      for (final m in _olderMessages) (m, -1),
      for (int i = renderFrom; i < _messages.length; i++) (_messages[i], i),
    ];
    // 預計算：renderSource[k] 之後是否還有角色的非空回覆（禮物「已收下」判定）
    final charReplyAfter = List<bool>.filled(renderSource.length, false);
    var seenCharReply = false;
    for (var k = renderSource.length - 1; k >= 0; k--) {
      charReplyAfter[k] = seenCharReply;
      final m = renderSource[k].$1;
      if (!m.isUser && m.text.trim().isNotEmpty) seenCharReply = true;
    }

    final displayItems = <_DisplayItem>[];
    for (var srcIdx = 0; srcIdx < renderSource.length; srcIdx++) {
      final (msg, i) = renderSource[srcIdx];

      // 通話操作是模型可見的 user action，入庫以維持跨模式 append-only
      // cache prefix；純協議標記不在聊天 UI 顯示。
      if (_callActionRe.hasMatch(msg.text.trim())) continue;

      // ═══ 通話結束/中斷 → 居中分割線（declined/missed 維持隱藏）═══
      final callMatch = _callDividerRe.firstMatch(msg.text.trim());
      if (callMatch != null) {
        final kind = callMatch.group(1)!;
        final dur = callMatch.group(2);
        final (label, icon) = switch (kind) {
          'ended' => (
            L.pick(en: 'Call ended', zhTW: '通話已結束'),
            Icons.call_end_rounded,
          ),
          'signal_lost' => (
            L.pick(en: 'Call dropped', zhTW: '通話中斷'),
            Icons.signal_cellular_connected_no_internet_0_bar_rounded,
          ),
          // 她打來、你拒接
          'declined' => (
            L.pick(en: 'Call declined', zhTW: '已拒絕來電'),
            Icons.phone_disabled_rounded,
          ),
          // 你打去、她拒接
          'declined_by_you' => (
            L.pick(en: 'Declined by them', zhTW: '對方已拒絕'),
            Icons.phone_disabled_rounded,
          ),
          // 她打來、響鈴未接
          _ => (
            L.pick(en: 'Missed call', zhTW: '未接來電'),
            Icons.phone_missed_rounded,
          ),
        };
        displayItems.add(
          _DisplayItem(
            text: '',
            isUser: msg.isUser,
            messageId: 'msg_${msg.id}',
            dbMessageId: msg.id,
            originalIndex: i,
            callDivider: dur == null ? label : '$label · $dur',
            callDividerIcon: icon,
          ),
        );
        continue;
      }

      if (_splitReply &&
          !msg.isUser &&
          msg.splitMode &&
          msg.text.contains('\n\n')) {
        final parts = msg.text
            .split('\n\n')
            .where((p) => p.trim().isNotEmpty)
            .toList();
        final splitHasCert = msg.text.contains(_marriageCertCharTag);
        for (int j = 0; j < parts.length; j++) {
          final isLast = j == parts.length - 1;
          displayItems.add(
            _DisplayItem(
              text: parts[j].trim(),
              isUser: false,
              timestamp: isLast ? msg.createdAt : null,
              imagePath: j == 0 ? msg.imagePath : null,
              messageId: 'msg_${msg.id}_$j',
              dbMessageId: msg.id,
              originalIndex: i,
              showToolbar: false,
              memoryLog: j == 0 ? msg.memoryLog : '',
              pendingMemoryActionCount: j == 0 && msg.id != null
                  ? (_pendingMemoryActionCounts[msg.id]?.total ?? 0)
                  : 0,
              hasUnreadMemoryActions: j == 0 && msg.id != null
                  ? (_pendingMemoryActionCounts[msg.id]?.unread ?? 0) > 0
                  : false,
              cacheHit:
                  isLast &&
                  !msg.isUser &&
                  (msg.cacheHit || _cacheHitIndices.contains(i)),
              incomplete: isLast && msg.isIncomplete,
              webSearchResult: isLast && msg.id != null
                  ? _webSearchResultsByMessageId[msg.id]
                  : null,
              webSearchTrace: isLast ? msg.webSearchTrace : null,
              emailDraft: isLast ? msg.emailDraft : null,
              // 她遞的證書卡跟在拆分回覆的最後一段
              hasMarriageCert: isLast && splitHasCert,
              certFromChar: isLast && splitHasCert,
            ),
          );
        }
      } else {
        // ═══ 送禮標記 → 禮物卡片跟隨氣泡；對方之後回了話 = 已收下 ═══
        final giftMatch = msg.isUser ? _giftTagRe.firstMatch(msg.text) : null;
        displayItems.add(
          _DisplayItem(
            text: msg.text,
            isUser: msg.isUser,
            timestamp: msg.createdAt,
            imagePath: msg.imagePath,
            messageId: 'msg_${msg.id}',
            dbMessageId: msg.id,
            originalIndex: i,
            cacheHit:
                !msg.isUser && (msg.cacheHit || _cacheHitIndices.contains(i)),
            memoryLog: msg.memoryLog,
            pendingMemoryActionCount: msg.id == null
                ? 0
                : (_pendingMemoryActionCounts[msg.id]?.total ?? 0),
            hasUnreadMemoryActions:
                msg.id != null &&
                (_pendingMemoryActionCounts[msg.id]?.unread ?? 0) > 0,
            incomplete: msg.isIncomplete,
            webSearchResult: !msg.isUser && msg.id != null
                ? _webSearchResultsByMessageId[msg.id]
                : null,
            webSearchTrace: msg.isUser ? null : msg.webSearchTrace,
            emailDraft: msg.isUser ? null : msg.emailDraft,
            giftName: giftMatch?.group(1)?.trim(),
            giftAccepted: giftMatch != null && charReplyAfter[srcIdx],
            hasMarriageCert:
                (msg.isUser && _marriageCertTagRe.hasMatch(msg.text)) ||
                (!msg.isUser && msg.text.contains(_marriageCertCharTag)),
            certFromChar:
                !msg.isUser && msg.text.contains(_marriageCertCharTag),
          ),
        );

        if (msg.isUser && msg.id != null) {
          final msgKey = 'msg_${msg.id}';
          final sd = _scratchDataMap[msgKey];
          if (sd != null && sd.who == 'char') {
            displayItems.add(
              _DisplayItem(
                text: '',
                isUser: false, // Force it to the left side
                timestamp: msg.createdAt,
                imagePath: null,
                messageId: msgKey,
                dbMessageId: null,
                originalIndex: i,
                cacheHit: false,
                memoryLog: '',
              ),
            );
          }
        }
      }
    }

    final hasSearchCard = _chatSearchQuery.isNotEmpty;
    final itemCount =
        (hasOlderButton ? 1 : 0) +
        displayItems.length +
        (hasStreamingBubble
            ? (_splitReply ? _streamingSplitParts().length : 1)
            : 0) +
        (hasSearchCard ? 1 : 0) +
        (hasWebSearchActivity ? 1 : 0) +
        (showAtom ? 1 : 0);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _userIsScrolling = true;
          _userScrolledUp = true;
        } else if (notification is UserScrollNotification) {
          _userIsScrolling = notification.direction != ScrollDirection.idle;
        } else if (notification is ScrollEndNotification) {
          _userIsScrolling = false;
        }
        return false;
      },
      child: RawScrollbar(
        controller: _scrollController,
        interactive: true,
        thickness: 5,
        minThumbLength: 72.0,
        radius: const Radius.circular(8),
        thumbColor: YanciTheme.accent.withValues(alpha: 0.38),
        child: ListView.builder(
          controller: _scrollController,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          scrollCacheExtent: ScrollCacheExtent.pixels(800.0),
          padding: const EdgeInsets.only(
            top: YanciTheme.spacingSm,
            bottom: YanciTheme.spacingSm,
          ),
          itemCount: itemCount,
          itemBuilder: (context, rawIndex) {
            // 頭部「查看更早」：先翻完發送窗的渲染段，再從 DB 往前掛
            // 純顯示段（錨點前歷史，永不進上下文）
            if (hasOlderButton && rawIndex == 0) {
              final page = renderFrom > 0 && renderFrom < _renderPageSize
                  ? renderFrom
                  : _renderPageSize;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: GestureDetector(
                    onTap: () {
                      if (renderFrom > 0) {
                        setState(() {
                          _renderFrom = (renderFrom - _renderPageSize).clamp(
                            0,
                            _messages.length,
                          );
                        });
                      } else {
                        _loadOlderForDisplay();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: YanciTheme.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: YanciTheme.accent.withValues(alpha: 0.25),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        L.pick(
                          en: '↑ Show $page earlier',
                          zhTW: '↑ 查看更早的 $page 條',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: YanciTheme.accent.withValues(alpha: 0.9),
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
            final index = hasOlderButton ? rawIndex - 1 : rawIndex;
            if (index < displayItems.length) {
              final item = displayItems[index];
              // ═══ 通話結束分割線：線 — 文字 — 線，主題色低調款 ═══
              if (item.callDivider != null) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 0.6,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                YanciTheme.accent.withValues(alpha: 0.35),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              item.callDividerIcon ?? Icons.call_end_rounded,
                              size: 12,
                              color: YanciTheme.accent.withValues(alpha: 0.55),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              item.callDivider!,
                              style: TextStyle(
                                fontSize: 11,
                                color: YanciTheme.accent.withValues(
                                  alpha: 0.65,
                                ),
                                fontFamily: YanciTheme.fontFamily,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 0.6,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                YanciTheme.accent.withValues(alpha: 0.35),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              final selectable =
                  _manualSummarySelecting &&
                  item.dbMessageId != null &&
                  item.text.trim().isNotEmpty;
              final bubble = ChatBubble(
                text: item.text,
                isUser: item.isUser,
                timestamp: item.timestamp,
                memoryLog: item.memoryLog,
                pendingMemoryActionCount: item.pendingMemoryActionCount,
                hasUnreadMemoryActions: item.hasUnreadMemoryActions,
                onMemoryReviewTap:
                    item.pendingMemoryActionCount > 0 &&
                        item.dbMessageId != null
                    ? () => _openMemoryReview(item.dbMessageId!)
                    : null,
                webSearchTrace: item.webSearchTrace,
                // 窗內消息 → 原地編輯重發；
                // 純顯示段（originalIndex -1）→ 編輯即開分支對話，原時間線不動
                onEdit: item.isUser
                    ? (item.originalIndex >= 0
                          ? () => _editMessage(item.originalIndex)
                          : (item.dbMessageId != null
                                ? () => _editAsBranch(item.dbMessageId!)
                                : null))
                    : null,
                messageId: item.messageId,
                imagePath: item.imagePath,
                conversationId: widget.conversationId,
                conversationTitle: _characterName,
                characterId: _activeCharacterId,
                showAvatar: _showChatAvatar,
                avatarPath: item.isUser ? _userAvatarPath : _charAvatarPath,
                showToolbar: item.showToolbar,
                cacheHit: item.cacheHit,
                incomplete: item.incomplete,
                onRetryIncomplete:
                    item.incomplete &&
                        item.dbMessageId != null &&
                        item.originalIndex == _messages.length - 1
                    ? () =>
                          unawaited(_retryIncompleteMessage(item.dbMessageId!))
                    : null,
                scratchData: _scratchDataMap[item.messageId],
                transferData: _transferDataMap[item.messageId],
                giftName: item.giftName,
                giftAccepted: item.giftAccepted,
                marriageCert: item.hasMarriageCert
                    ? MarriageCertDisplay(
                        userName: _userNameCache,
                        charName: _characterName,
                        signed: _isMarried,
                        date: _marriageDate,
                      )
                    : null,
                onCertSignTap: item.certFromChar && !_isMarried
                    ? _signCharCert
                    : null,
                onTransferUpdated: () => _refreshTransfer(item.messageId),
                selectable: selectable,
                selected:
                    item.dbMessageId != null &&
                    _manualSummarySelectedIds.contains(item.dbMessageId),
                onSelectionToggle: item.dbMessageId == null
                    ? null
                    : () => _toggleManualSummaryMessage(item.dbMessageId!),
              );
              final geminiDisplayResult = item.webSearchResult == null
                  ? null
                  : WebSearchFollowUp.geminiDisplayResultFor(
                      item.webSearchResult!,
                    );
              final attachments = <Widget>[];
              final emailDraft = item.emailDraft;
              if (emailDraft != null && item.dbMessageId != null) {
                attachments.add(
                  EmailDraftCard(
                    draft: emailDraft,
                    showAvatar: _showChatAvatar,
                    onEdit: () => unawaited(
                      _editEmailDraft(item.dbMessageId!, emailDraft),
                    ),
                    onOpen: () => unawaited(_openEmailDraft(emailDraft)),
                    onDelete: () =>
                        unawaited(_deleteEmailDraft(item.dbMessageId!)),
                  ),
                );
              }
              if (geminiDisplayResult != null) {
                attachments.add(
                  WebSearchResultCard(result: geminiDisplayResult),
                );
              }
              if (attachments.isEmpty) return bubble;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[bubble, ...attachments],
              );
            } else if (showAtom && index == displayItems.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AtomThinkingWidget(size: 36, color: YanciTheme.accent),
                ),
              );
            } else {
              // ═══ 搜索卡片（streaming 後、最末尾）═══
              final streamSlots = hasStreamingBubble
                  ? (_splitReply ? _streamingSplitParts().length : 1)
                  : 0;
              final searchCardIdx =
                  displayItems.length + (showAtom ? 1 : 0) + streamSlots;
              if (hasSearchCard && index == searchCardIdx) {
                return _buildSearchCard();
              }
              final webSearchActivityIdx =
                  searchCardIdx + (hasSearchCard ? 1 : 0);
              final webSearchActivity = _webSearchActivity;
              if (hasWebSearchActivity &&
                  webSearchActivity != null &&
                  index == webSearchActivityIdx) {
                return WebSearchThinkingActivity(
                  status: webSearchActivity.status,
                  query: webSearchActivity.query,
                  providers: webSearchActivity.providers,
                  safeMessage: webSearchActivity.safeMessage,
                  showAvatar: _showChatAvatar,
                  avatarPath: _charAvatarPath,
                );
              }
              // ═══ 流式氣泡（拆分回覆時按段落拆）═══
              if (_splitReply) {
                final parts = _streamingSplitParts();
                final streamIdx =
                    index - displayItems.length - (showAtom ? 1 : 0);
                if (streamIdx < 0 || streamIdx >= parts.length) {
                  return const SizedBox.shrink();
                }
                final isLast = streamIdx == parts.length - 1;
                return ChatBubble(
                  text: parts[streamIdx],
                  isUser: false,
                  isStreaming: isLast,
                  messageId: 'streaming_$streamIdx',
                  conversationId: widget.conversationId,
                  conversationTitle: _characterName,
                  characterId: _activeCharacterId,
                  showAvatar: _showChatAvatar,
                  avatarPath: _charAvatarPath,
                  webSearchTrace: isLast ? pendingWebSearchTrace : null,
                );
              } else {
                return ChatBubble(
                  text: _displayStreamingText,
                  isUser: false,
                  isStreaming: true,
                  messageId: 'streaming',
                  conversationId: widget.conversationId,
                  conversationTitle: _characterName,
                  characterId: _activeCharacterId,
                  showAvatar: _showChatAvatar,
                  avatarPath: _charAvatarPath,
                  webSearchTrace: pendingWebSearchTrace,
                );
              }
            }
          },
        ),
      ),
    );
  }

  Widget _buildManualSummarySelectionBar() {
    final count = _manualSummarySelectedIds.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg,
        border: Border(
          top: BorderSide(
            color: YanciTheme.textSecondary.withValues(alpha: 0.10),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                L.pick(
                  en: count == 0
                      ? 'Select messages to summarize'
                      : '$count messages selected',
                  zhTW: count == 0 ? '勾選要摘要的消息' : '已選 $count 條消息',
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textPrimary.withValues(alpha: 0.78),
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ),
            TextButton(
              onPressed: _manualSummaryRunning
                  ? null
                  : () {
                      setState(() {
                        _manualSummarySelecting = false;
                        _manualSummarySelectedIds.clear();
                      });
                    },
              child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: count == 0 || _manualSummaryRunning
                  ? null
                  : _confirmManualSummarySelected,
              icon: _manualSummaryRunning
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    )
                  : const Icon(Icons.edit_note_rounded, size: 18),
              label: Text(
                L.pick(
                  en: _manualSummaryRunning ? 'Summarizing' : 'Summarize',
                  zhTW: _manualSummaryRunning ? '摘要中' : '摘要',
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: YanciTheme.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 通話 ═══════════════

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingSm,
        vertical: YanciTheme.spacingXs,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ═══ 置中的標題區域 ═══
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ═══ 角色名（加粗）═══
              Text(
                _characterName.isNotEmpty ? _characterName : 'Holt',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: YanciTheme.textPrimary,
                  fontFamily: YanciTheme.fontFamily,
                  letterSpacing: 0.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              // ═══ 模型 + token ═══
              GestureDetector(
                key: _modelPickerAnchorKey,
                onTap: _showModelPicker,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_localModelLoading) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: YanciTheme.accent.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      _localModelLoading
                          ? (L.pick(en: 'Loading…', zhTW: '加載中…'))
                          : _shortModelName(_currentModel),
                      style: TextStyle(
                        fontSize: 11,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    if (_tokenTracker.totalTokens > 0) ...[
                      Text(
                        ' · ',
                        style: TextStyle(
                          fontSize: 11,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      Text(
                        '${_tokenTracker.formatTokens()} tokens',
                        style: TextStyle(
                          fontSize: 11,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 3),
                    Icon(
                      Icons.unfold_more_rounded,
                      size: 10,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // ═══ 左右按鈕 ═══
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_rounded,
                  size: 20,
                  color: YanciTheme.textPrimary,
                ),
                onPressed: () => Navigator.of(context).pop(_walletChanged),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ═══ 語音通話 ═══
                  Semantics(
                    button: true,
                    label: L.pick(en: 'Voice call', zhTW: '語音通話'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _isChatReady ? () => _openCall() : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Icon(
                          Icons.call_rounded,
                          size: 21,
                          color: YanciTheme.accent.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  // ═══ 長截圖（取代低頻的新窗口入口）═══
                  Semantics(
                    button: true,
                    enabled: _isChatReady && !_isCapturingLongScreenshot,
                    label: L.pick(en: 'Long screenshot', zhTW: '長截圖'),
                    child: Tooltip(
                      message: L.pick(en: 'Long screenshot', zhTW: '長截圖'),
                      excludeFromSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _isChatReady && !_isCapturingLongScreenshot
                            ? _captureLongScreenshot
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: _isCapturingLongScreenshot
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.7,
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                )
                              : Icon(
                                  Icons.panorama_vertical_outlined,
                                  size: 22,
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 1),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 模型短名
  String _shortModelName(String model) {
    if (model.isEmpty) return '選模型';
    // 本地模型：local:qwen3-1.7b-q4 → 📱 Qwen3 1.7B
    if (model.startsWith('local:')) {
      final key = model.substring(6);
      final info = LocalModelService.availableModels
          .where((m) => m.key == key)
          .firstOrNull;
      var localName = info != null
          ? L.pick(en: info.nameEn, zhTW: info.name)
          : LocalModelService.fallbackDisplayNameForKey(key);
      if (localName.length > 16) localName = '${localName.substring(0, 14)}…';
      return '📱 $localName';
    }
    if (ApiSettings.isLocalApiModelId(model)) {
      var localApiName = ApiSettings.extractLocalApiModel(model);
      if (localApiName.length > 16) {
        localApiName = '${localApiName.substring(0, 14)}…';
      }
      return '🖥 $localApiName';
    }
    var name = model;
    if (name.contains('/')) name = name.split('/').last;
    // 去掉日期後綴
    name = name.replaceAll(RegExp(r'-\d{8}$'), '');
    // 簡化 Claude 模型名：claude-sonnet-4.5 → sonnet 4.5
    name = name.replaceAll('claude-', '');
    // 簡化其他常見前綴
    name = name.replaceAll('gpt-', 'gpt');
    name = name.replaceAll('gemini-', 'gemini ');
    name = name.replaceAll('deepseek-', 'ds-');
    // 頂欄空間有限，太長就截
    if (name.length > 18) name = '${name.substring(0, 16)}…';
    return name;
  }

  /// 模型全名（不截斷，供 picker / marquee 使用）
  String _fullModelName(String model) {
    if (model.isEmpty) return '選模型';
    if (model.startsWith('local:')) {
      final key = model.substring(6);
      final info = LocalModelService.availableModels
          .where((m) => m.key == key)
          .firstOrNull;
      return info != null
          ? L.pick(en: info.nameEn, zhTW: info.name)
          : LocalModelService.fallbackDisplayNameForKey(key);
    }
    if (ApiSettings.isLocalApiModelId(model)) {
      return ApiSettings.extractLocalApiModel(model);
    }
    var name = model;
    if (name.contains('/')) name = name.split('/').last;
    name = name.replaceAll(RegExp(r'-\d{8}$'), '');
    name = name.replaceAll('claude-', '');
    name = name.replaceAll('gpt-', 'gpt');
    name = name.replaceAll('gemini-', 'gemini ');
    name = name.replaceAll('deepseek-', 'ds-');
    return name;
  }

  Color? _savedThemeColor(String? hex) {
    if (hex == null) return null;
    final normalized = hex.replaceAll('#', '').trim();
    final value = int.tryParse(
      normalized.length == 6 ? 'FF$normalized' : normalized,
      radix: 16,
    );
    return value == null ? null : Color(value);
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 48,
            color: YanciTheme.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: YanciTheme.spacingMd),
          Text(
            L.get('chat_placeholder'),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

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

/// 顯示用消息項（支持拆分回覆）
class _DisplayItem {
  final String text;
  final bool isUser;
  final DateTime? timestamp;
  final String? imagePath;
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

  _DisplayItem({
    required this.text,
    required this.isUser,
    this.timestamp,
    this.imagePath,
    required this.messageId,
    this.dbMessageId,
    required this.originalIndex,
    this.memoryLog = '',
    this.pendingMemoryActionCount = 0,
    this.hasUnreadMemoryActions = false,
    this.webSearchResult,
    this.webSearchTrace,
    this.emailDraft,
    this.showToolbar = true,
    this.cacheHit = false,
    this.incomplete = false,
    this.callDivider,
    this.callDividerIcon,
    this.giftName,
    this.giftAccepted = false,
    this.hasMarriageCert = false,
    this.certFromChar = false,
  });
}
