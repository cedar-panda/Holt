import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import '../services/memory_actions.dart';
import '../services/image_gen_service.dart';
import '../memory/emotion_coordinates.dart';
import '../services/token_tracker.dart';
import '../services/context_compressor.dart';
import '../services/sticker_service.dart';
import '../services/image_service.dart';
import '../services/openrouter_service.dart';
import '../services/deepseek_service.dart';
import '../services/gemini_service.dart';
import '../services/aws_bedrock_service.dart';
import '../memory/database.dart';
import '../memory/retriever.dart';
import '../services/bio_clock_service.dart';
import '../services/shop_service.dart';
import '../services/marriage_service.dart';
import '../services/tool_prompts.dart';
import '../services/x_post_service.dart';
import '../services/x_post_settings.dart';
import '../services/character_timeline_service.dart';
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
import 'call_screen.dart';
import 'manual_summary_clean_screen.dart';
import '../services/call_audio_pipeline.dart';

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

  const _StaticPromptBundle({required this.staticPart, this.profilePart});
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Message> _messages = [];

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

  /// 生成態統一入口：熄屏/退後台會凍結流式回覆，
  /// 生成期間掛前台服務保護（GenerationForegroundGuard），結束即撤
  void _setGenerating(bool v) {
    if (_isGenerating == v) return;
    _isGenerating = v;
    if (v) {
      unawaited(GenerationForegroundGuard.begin());
    } else {
      unawaited(GenerationForegroundGuard.end());
    }
  }

  bool _sendSubmissionInProgress = false;
  bool _isLoading = true;
  bool _isChatReady = false;
  bool _initializationFailed = false;
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
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|memo_link|force_recall|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|search_chat|call|scratch|transfer|transfer_accept|transfer_decline|x_post|pack_star)\b[^>]*>'
    r'[\s\S]*?'
    r'</\1>',
    multiLine: true,
  );
  static final _openTagRe = RegExp(
    r'<(emo|emo_resolve|memo|memo_del|memo_merge|memo_update|memo_link|force_recall|persona_note|draw|clock|clock_keep|clock_update|clock_del|life_fix|home|search_chat|call|scratch|transfer|transfer_accept|transfer_decline|buy|x_post|shop_view|pack_star|sign_marriage|propose_marriage)\b[\s\S]*$',
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

  void _onStreamChunk(String chunk) {
    if (!mounted) return;
    for (int i = 0; i < chunk.length; i++) {
      _streamCharQueue.add(chunk[i]);
    }
    _startStreamPopTimer();
  }

  void _startStreamPopTimer() {
    if (_streamPopTimer?.isActive == true) return;
    _streamPopTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted || _streamCharQueue.isEmpty) {
        timer.cancel();
        return;
      }
      int popCount = 1;
      if (_streamCharQueue.length > 20) popCount = 2;
      if (_streamCharQueue.length > 50) popCount = 4;
      if (_streamCharQueue.length > 100) popCount = 8;

      final buf = StringBuffer();
      for (int i = 0; i < popCount && _streamCharQueue.isNotEmpty; i++) {
        buf.write(_streamCharQueue.removeAt(0));
      }
      _streamingText += buf.toString();
      setState(() {});
      _scrollToBottom();
    });
  }

  void _clearStreamQueue() {
    _streamCharQueue.clear();
    _streamPopTimer?.cancel();
    _streamingText = '';
  }

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

  String _computeDisplayStreamingText() {
    // 1. 剝離已完成的標籤
    var text = _streamingText
        .replaceAll(_completedToolCallsRe, '')
        .replaceAll(_completedTagRe, '')
        .replaceAll(_scratchTagRe, '')
        .replaceAll(_shopViewTagRe, '')
        .replaceAll(_transferTagRe, '')
        .replaceAll(_transferResponseRe, '')
        .replaceAll(_signMarriageRe, '')
        .replaceAll(_proposeMarriageRe, '')
        .replaceAll(_buyTagRe, '');
    // 2. 截斷未關閉的標籤（正在接收中）
    final toolCallMatch = _openToolCallsRe.firstMatch(text);
    if (toolCallMatch != null) {
      text = text.substring(0, toolCallMatch.start);
    }
    final openMatch = _openTagRe.firstMatch(text);
    if (openMatch != null) {
      text = text.substring(0, openMatch.start);
    }
    // 3. 截斷剛剛開始輸入的疑似標籤前綴，例如 `<m`, `<emo` 等（不帶空格的純字母組合）
    final partialTagMatch = RegExp(r'<[a-zA-Z_]*$').firstMatch(text);
    if (partialTagMatch != null) {
      text = text.substring(0, partialTagMatch.start);
    }
    return text.trim();
  }

  int _beginGeneration() => ++_generationSerial;

  bool _isCurrentGeneration(int serial) => serial == _generationSerial;

  void _invalidateGenerationState() {
    _clearStreamQueue();
    _generationSerial++;
    _streamingText = '';
    _setGenerating(false);
    _chatSearching = false;
    _chatSearchQuery = '';
    _chatSearchResults = [];
  }

  /// 本輪待發的 X 推文內容（每輪 _extractXPostAndStrip 重置）
  String? _pendingXPost;

  /// 提取 `<x_post>` 內容並剝離，再走通用殘尾清理。
  /// 必須在 _stripInternalToolCalls 之前提取——_openTagRe 已含 x_post，
  /// 先 strip 會把標籤連同後文一起截掉。text/image 雙路徑共用。
  String _extractXPostAndStrip(String text) {
    _pendingXPost = null;
    final m = RegExp(r'<x_post>([\s\S]*?)</x_post>').firstMatch(text);
    if (m != null) {
      final content = m.group(1)!.trim();
      if (content.isNotEmpty) _pendingXPost = content;
      text = text.replaceAll(RegExp(r'<x_post>[\s\S]*?</x_post>'), '').trim();
    }
    return _stripInternalToolCalls(text);
  }

  /// 發推流程：限額/連接檢查 → 確認卡（承諾過「先過目」）→ 發送。
  Future<void> _handleXPost() async {
    final content = _pendingXPost;
    _pendingXPost = null;
    if (content == null) return;
    final charId = _activeCharacterId;
    if (!await XPostSettings.canPost(charId)) return; // 未啟用/超限：靜默
    if (!mounted) return;
    if (!await XPostService.isConnected(charId)) {
      if (!mounted) return; // await 後 context 需重新確認
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: '$_characterName wanted to post, but the X account is not connected.',
              zhTW: '【$_characterName】起念發了條推文，但 X 帳號尚未連接',
            ),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(
            en: '$_characterName wants to post',
            zhTW: '$_characterName 想發一則推文',
          ),
          style: YanciTheme.headingMedium,
        ),
        content: Text(content, style: YanciTheme.bodyText),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Not now', zhTW: '先不發')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: YanciTheme.accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Post', zhTW: '發送')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await XPostService.postTweet(charId, content);
    if (err == null) await XPostSettings.incrementToday(charId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? L.pick(en: 'Posted to X 🦦', zhTW: '已發布到 X 🦦')),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _stripInternalToolCalls(String text) {
    return text
        .replaceAll(_completedToolCallsRe, '')
        .replaceAll(_openTagRe, '')
        .trim();
  }

  String _appendTransferTag(String text, TransferData? transfer) {
    final trimmed = text.trim();
    if (transfer == null) return trimmed;
    final tag = '[transfer:${transfer.amount}]';
    return trimmed.isEmpty ? tag : '$trimmed\n$tag';
  }

  String _appendScratchGiftTag(String text, ScratchData? scratch) {
    final trimmed = text.trim();
    if (scratch == null) return trimmed;
    final tag = '[scratch_gift:${scratch.who}]';
    return trimmed.isEmpty ? tag : '$trimmed\n$tag';
  }

  String _titleTextForFirstMessage(
    String text,
    TransferData? transfer,
    ScratchData? scratch,
  ) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (scratch != null) {
      return L.pick(en: 'Scratch card gift', zhTW: '刮刮卡禮物');
    }
    if (transfer == null) return '';
    return L.pick(
      en: 'Transfer ${transfer.amount} shells',
      zhTW: '轉帳 ${transfer.amount} 貝殼',
    );
  }

  String _scratchGiftDynamicPrompt(ScratchData? scratch) {
    if (scratch == null || scratch.who != 'char') return '';
    final resultsZh = scratch.prizes
        .map((p) => p.coins > 0 ? '+${p.coins} 貝殼' : p.label)
        .join(' ➝ ');
    if (L.locale == 'en') {
      final resultsEn = scratch.prizes
          .map((p) => p.coins > 0 ? '+${p.coins} shells' : p.label)
          .join(' ➝ ');
      return '【Scratch Card Gift】The user bought a scratch card and let you scratch it. The app has already scratched it locally. Result: $resultsEn. If shells were won, they have already been added to your current balance. React naturally to being given the card and to the result.';
    }
    return '${L.pick(en: '', zhTW: '【刮刮卡禮物】用戶買了一張刮刮卡讓你刮。App 已在本地完成刮卡，結果：')}$resultsZh${L.pick(en: '', zhTW: '。若中了貝殼，已經加到你目前餘額。請自然回應「對方讓你刮」這件事，以及這次刮出的結果。')}';
  }

  Future<String> _coinStaticPrompt(String characterId) async {
    _coinSnapshotChar ??= await ScratchService.getCoins(characterId);
    _coinSnapshotUser ??= await ScratchService.getUserCoins();

    if (L.locale == 'en') {
      return '【Shell Balance Snapshot】At the start of this chat window: your balance is $_coinSnapshotChar shells; the user balance is $_coinSnapshotUser shells. This static snapshot is kept stable for prompt caching. Later transfer/scratch changes are provided as deltas in dynamic context; always follow the latest delta when present.';
    }

    return L.pick(
      en: '',
      zhTW:
          '【貝殼餘額快照】本聊天窗口開篇時：你的餘額 $_coinSnapshotChar 貝殼；用戶餘額 $_coinSnapshotUser 貝殼。此靜態快照為了穩定 prompt cache 不再改動；後續轉帳/刮刮卡變動會在動態上下文以增減量補充，有變動時以最新增減量為準。',
    );
  }

  Future<String> _coinDeltaPrompt(String characterId) async {
    _coinSnapshotChar ??= await ScratchService.getCoins(characterId);
    _coinSnapshotUser ??= await ScratchService.getUserCoins();

    final currentChar = await ScratchService.getCoins(characterId);
    final currentUser = await ScratchService.getUserCoins();
    final charDelta = currentChar - _coinSnapshotChar!;
    final userDelta = currentUser - _coinSnapshotUser!;
    if (charDelta == 0 && userDelta == 0) return '';

    String signed(int value) => value >= 0 ? '+$value' : '$value';
    if (L.locale == 'en') {
      return '【Shell Balance Delta】Since this window opened: your balance ${signed(charDelta)} → now $currentChar shells; user balance ${signed(userDelta)} → now $currentUser shells. Use these current balances for transfer/scratch decisions.';
    }

    return L.pick(
      en: '',
      zhTW:
          '【貝殼餘額變動】自本窗口開篇後：你的餘額 ${signed(charDelta)}，目前 $currentChar 貝殼；用戶餘額 ${signed(userDelta)}，目前 $currentUser 貝殼。轉帳與刮刮卡判斷請以目前餘額為準。',
    );
  }

  String _timePrompt(DateTime now) {
    if (L.locale == 'en') {
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return '【Time】${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    }
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return L.pick(
      en: '',
      zhTW:
          '【時間】${now.year}年${now.month}月${now.day}日 週${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );
  }

  /// 消費本輪 `<buy>` 結果：送 user 成功 → 系統訊息落庫並即時上屏；
  /// 失敗 → SnackBar 提示（模型側回饋走 pendingBuyFailureNote 動態注入）。
  /// text / image 雙路徑共用此消費點。
  Future<void> _consumeBuyResults(String conversationId) async {
    if (ShopService.lastBuyResults.isEmpty) return;
    final results = List<Map<String, String>>.from(ShopService.lastBuyResults);
    ShopService.lastBuyResults.clear();
    for (final r in results) {
      if (r['success'] == '1' && r['target'] == 'user') {
        final sysMsg = Message(
          conversationId: conversationId,
          characterId: _activeCharacterId,
          text: '*(TA從商店買了「${r['name']}」送給你，已放入背包)*',
          isUser: false,
          createdAt: DateTime.now(),
        );
        final id = await DatabaseHelper.insertMessage(sysMsg);
        if (mounted) {
          setState(() {
            _messages.add(
              Message(
                id: id,
                conversationId: sysMsg.conversationId,
                characterId: sysMsg.characterId,
                text: sysMsg.text,
                isUser: false,
                createdAt: sysMsg.createdAt,
              ),
            );
          });
          _scrollToBottom();
        }
      } else if (r['success'] == '0' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '【$_characterName】想買「${r['name']}」沒成功：${r['reason']}',
            ),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<_StaticPromptBundle> _buildCommonStaticParts({
    required String characterId,
    required String systemPrompt,
    required String charDesc,
    required String characterName,
    required String userProfile,
    required String selfNotes,
    required String userNickname,
    required bool isSpiderWebEnabled,
    required bool memoryWriteEnabled,
    required bool emotionEnabled,
    required bool bioclockEnabled,
    required bool imagegenEnabled,
    required String providerName,
    required bool conciseOn,
    required bool freeformOn,
    required String staticWindowSummary,
  }) async {
    if (bioclockEnabled &&
        (_habitSnapshotIds == null || _habitListSnapshot == null)) {
      _habitSnapshotIds = await BioClockService.habitIds(characterId);
      _habitListSnapshot = await BioClockService.habitListPrompt(characterId);
    }
    final habitList = bioclockEnabled ? (_habitListSnapshot ?? '') : '';

    _selfNotesSnapshot ??= selfNotes;
    _selfNotesSnapshotLines ??= selfNotes.isEmpty
        ? <String>{}
        : selfNotes.split('\n').toSet();

    _stickerPromptSnapshot ??= await StickerService.buildStickerPrompt(
      characterId: characterId,
    );
    // 背包窗內快照（delta 基準），與其他快照同點初始化
    _packQtySnapshot ??= await ShopService.packQtySnapshot(characterId);

    final staticParts = <String>[];
    final normalizedSystemPrompt = systemPrompt.trim();
    final normalizedCharacterDescription = charDesc.trim();
    // Older builds copied the selected character description into the global
    // system prompt. Keep custom global instructions, but do not inject that
    // legacy mirror twice into every request.
    if (normalizedSystemPrompt.isNotEmpty &&
        normalizedSystemPrompt != normalizedCharacterDescription) {
      staticParts.add(normalizedSystemPrompt);
    }
    if (normalizedCharacterDescription.isNotEmpty) {
      staticParts.add(
        '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$normalizedCharacterDescription',
      );
    } else if (normalizedSystemPrompt.isNotEmpty) {
      staticParts.add(normalizedSystemPrompt);
    }
    if (_selfNotesSnapshot!.isNotEmpty) {
      staticParts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$_selfNotesSnapshot',
      );
    }
    // 已婚狀態（僅已簽角色注入；未簽空串＝前綴逐字節不變。
    // 簽署瞬間變一次＝一次性重建，之後永久命中）
    final marriageNote = await MarriageService.staticPrompt(characterId);
    if (marriageNote.isNotEmpty) staticParts.add(marriageNote);
    staticParts.add(await _coinStaticPrompt(characterId));
    if (staticWindowSummary.isNotEmpty) {
      staticParts.add(staticWindowSummary);
    }

    final toolSections = <String>[];
    if (isSpiderWebEnabled) {
      toolSections.add(
        await SpiderWebService.abilityPrompt(
          userNickname: userNickname,
          characterId: characterId,
          characterName: characterName,
        ),
      );
    } else {
      if (memoryWriteEnabled) {
        toolSections.add(
          MemoryActions.abilityPrompt(
            userNickname: userNickname,
            characterName: characterName,
          ),
        );
      }
      if (emotionEnabled) {
        toolSections.add(EmotionCoordinates.abilityPrompt());
      }
      if (bioclockEnabled) {
        toolSections.add(BioClockService.abilityPrompt());
      }
    }
    if (providerName == 'openrouter' && imagegenEnabled) {
      toolSections.add(ImageGenService.abilityPrompt());
    }
    // 商店（全語言/全模式；固定文本零緩存污染；清單走 two-pass 按需查詢）
    if (await ShopService.isEnabled()) {
      toolSections.add(ToolPrompts.shop());
    }
    toolSections.add(ToolPrompts.homeNote());
    toolSections.add(ToolPrompts.scratchCard());
    toolSections.add(ToolPrompts.transfer());
    toolSections.add(ToolPrompts.voiceCall());
    // X 發文（開關開啟才注入說明；剩餘條數等動態信息走 dynamicParts）
    if (await XPostSettings.isEnabled(characterId)) {
      toolSections.add(ToolPrompts.xPost());
    }
    if (_stickerPromptSnapshot!.isNotEmpty) {
      toolSections.add(_stickerPromptSnapshot!);
    }

    staticParts.add(
      '${ToolPrompts.toolHeader()}\n\n${toolSections.join('\n\n')}',
    );

    if (habitList.isNotEmpty) staticParts.add(habitList);

    if (conciseOn || freeformOn) {
      final parts = <String>[];
      if (conciseOn) {
        parts.add(ToolPrompts.concise(emotionEnabled: emotionEnabled));
      }
      if (freeformOn) {
        final maxLines = await ApiSettings.getFreeformMaxLines();
        parts.add(ToolPrompts.freeform(maxLines));
      }
      staticParts.add('${ToolPrompts.replyStyleHeader()}\n${parts.join('\n')}');
    }

    return _StaticPromptBundle(
      staticPart: staticParts.join('\n\n'),
      profilePart: userProfile.isNotEmpty ? userProfile : null,
    );
  }

  @override
  void initState() {
    super.initState();
    _manualSummarySelecting = widget.startManualSummarySelection;
    // 窗口短號重置：模型視角的記憶編號按本窗注入順序從 1 重編
    Retriever.resetWindowIds(widget.conversationId);
    final keepAlive = KeepAliveService.instance;
    if (keepAlive.activeConversationId != null &&
        keepAlive.activeConversationId != widget.conversationId) {
      keepAlive.pauseActiveWindow();
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
      if (!mounted) return;
      setState(() {
        _isChatReady = false;
        _isLoading = false;
        _initializationFailed = true;
      });
    }
  }

  void _retryInitialization() {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _isChatReady = false;
      _initializationFailed = false;
      _messages.clear();
      _cacheHitIndices.clear();
      _scratchDataMap.clear();
      _transferDataMap.clear();
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
    final char = await DatabaseHelper.getCharacter(_activeCharacterId);
    if (char == null) {
      throw StateError(
        'Character $_activeCharacterId for conversation '
        '${conversation.id} does not exist',
      );
    }
    _characterName = char['name'] as String? ?? '';
    _charAvatarPath = char['avatar_path'] as String?;

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
      _cacheHitIndices.clear();
      for (int i = 0; i < _messages.length; i++) {
        if (_messages[i].cacheHit) {
          _cacheHitIndices.add(i);
        }
      }
    });

    // 非同步還原 _tokensSinceSummary，防止退出窗口導致 token 重新歸零
    await _restoreTokensSinceSummary();
  }

  Future<void> _restoreTokensSinceSummary() async {
    try {
      final p = await SharedPreferences.getInstance();
      final count = p.getInt(_tokensSinceSummaryKey);
      if (count != null) {
        if (mounted) {
          setState(() {
            _tokensSinceSummary = count;
          });
        }
        return;
      }

      final allMsgs = await DatabaseHelper.getMessages(widget.conversationId);
      final summaries = await DatabaseHelper.getLatestContextSummaries(
        _activeCharacterId,
        limit: 1,
      );
      DateTime? lastTime;
      if (summaries.isNotEmpty) {
        lastTime = DateTime.tryParse(summaries.first['created_at']);
      }
      int calcCount = 0;
      for (final m in allMsgs) {
        if (lastTime == null || m.createdAt.isAfter(lastTime)) {
          calcCount += TokenEstimator.estimate(m.text);
        }
      }
      if (mounted) {
        setState(() {
          _tokensSinceSummary = calcCount;
        });
      }
      await _saveTokensSinceSummary();
    } catch (e) {
      debugPrint('Error restoring tokensSinceSummary: $e');
    }
  }

  Future<void> _saveTokensSinceSummary() async {
    try {
      final p = await SharedPreferences.getInstance();
      final value = _tokensSinceSummary;
      await p.setInt(_tokensSinceSummaryKey, value);
    } catch (e) {
      debugPrint('Error saving tokensSinceSummary: $e');
    }
  }

  String get _tokensSinceSummaryKey =>
      'conversation:${widget.conversationId}:tokensSinceSummary';

  Future<void> _claimVisibleKeepAliveWindow() async {
    if (!mounted || !_isChatReady) return;
    final convId = widget.conversationId;
    CacheSession.conversationId = convId;

    final charId = _activeCharacterId;
    final history = _messages
        .where((m) => m.text.trim().isNotEmpty)
        .map(
          (m) => <String, String>{
            'role': m.isUser ? 'user' : 'assistant',
            'content': m.text,
          },
        )
        .toList();

    await KeepAliveService.instance.claimVisibleWindow(
      conversationId: convId,
      characterId: charId,
      messages: history,
    );
  }

  @override
  void dispose() {
    _clearStreamQueue();
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
                final p = await SharedPreferences.getInstance();
                await p.setInt('conversation:$convId:tokensSinceSummary', 0);
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
  Future<String> _memoryBucket() async =>
      (await MemorySettings.getMemoryMode()) == 'story' ? 'story' : 'romance';

  // ═══ B4：滯後截斷錨點（歷史只在尾部增長，絕對索引跨輪穩定）═══
  int _contextKeepFrom = 0;

  // ═══ 習慣快照（增量方案）：開窗時凍結，窗內新增走動態 ═══
  Set<int>? _habitSnapshotIds;
  String? _habitListSnapshot;
  String? _stickerPromptSnapshot;

  /// Language changes are an explicit one-time static-prefix invalidation.
  /// Refresh only language-bearing snapshots; keep data baselines intact so
  /// deltas, summary pins, and append-only history semantics do not change.
  void _syncPromptLocaleCaches() {
    if (_promptLocaleSnapshot == L.locale) return;
    final hadLocale = _promptLocaleSnapshot != null;
    _promptLocaleSnapshot = L.locale;
    if (!hadLocale) return;
    _stickerPromptSnapshot = null;
    _habitListSnapshot = null;
    _cacheWindowSummaryStaticSnapshot = null;
  }

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

  Future<void> _refreshMarriageState() async {
    final unlocked = await MarriageService.isUnlocked(_activeCharacterId);
    final married = await MarriageService.isMarried(_activeCharacterId);
    final date = married
        ? await MarriageService.marriageDate(_activeCharacterId)
        : null;
    if (_userNameCache.isEmpty) {
      final nick = await UserSettings.getUserName();
      _userNameCache = nick.isNotEmpty ? nick : '對方';
    }
    if (!mounted) return;
    if (unlocked != _marriageUnlocked ||
        married != _isMarried ||
        date != _marriageDate) {
      setState(() {
        _marriageUnlocked = unlocked;
        _isMarried = married;
        _marriageDate = date;
      });
    }
  }

  Future<void> _openChatShop() async {
    // 先選對象：給自己買（普通模式）or 送TA（掛起隨消息）
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          L.pick(en: 'Browse shop', zhTW: '逛商店'),
          style: TextStyle(
            fontSize: 15,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'self'),
            child: Row(
              children: [
                Icon(
                  Icons.person_outline_rounded,
                  size: 18,
                  color: YanciTheme.accent,
                ),
                const SizedBox(width: 10),
                Text(
                  L.pick(en: 'Buy for myself', zhTW: '給自己買'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'char'),
            child: Row(
              children: [
                Icon(
                  Icons.card_giftcard_rounded,
                  size: 18,
                  color: YanciTheme.accent,
                ),
                const SizedBox(width: 10),
                Text(
                  L.pick(en: 'Gift with next message', zhTW: '送給TA（隨下一條消息）'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => target == 'self'
          ? ShopBottomSheet(
              mode: ShopMode.normal,
              inviteCharName: _characterName,
              onInviteBrowse: _sendShopInvite,
            )
          : ShopBottomSheet(
              mode: ShopMode.giftPending,
              targetCharId: _activeCharacterId,
              pendingScopeId: widget.conversationId,
              onGiftPending: (reservation) {
                setState(() => _pendingGift = reservation);
              },
              inviteCharName: _characterName,
              onInviteBrowse: _sendShopInvite,
            ),
    );
  }

  /// 邀請後商店清單還跟隨幾輪（動態注入，不入庫——清單永駐歷史太浪費 token）
  int _shopInviteRoundsLeft = 0;
  static const int _shopInviteRounds = 3;

  /// 邀請角色一起逛商店：邀請標記入庫（帶短說明），
  /// 商品清單走動態注入跟隨接下來 3 輪 user 消息——有連續性、不永駐歷史。
  Future<void> _sendShopInvite() async {
    if (!_isChatReady || _isGenerating || _isGeneratingImage) return;
    if (!await ShopService.isEnabled()) return;
    _shopInviteRoundsLeft = _shopInviteRounds;
    const text =
        '[shop_invite]'
        '（系統說明：對方邀請你一起逛商店，商品清單會隨接下來幾輪消息附上。'
        '想逛就陪著逛，不想逛也可以用你自己的方式拒絕。這段說明對方看不到）';
    await _onSendMessage(text);
  }

  /// 她遞的證書：點卡片 → 簽字/拒絕/再想想。
  /// 簽字落狀態；拒絕需二次確認；兩者都以隱藏事件告知她、觸發反應。
  Future<void> _signCharCert() async {
    if (_isMarried || _isGenerating || !_isChatReady) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          L.pick(en: 'Sign the certificate?', zhTW: '在證書上簽字？', zhCN: '在证书上签字？'),
          style: TextStyle(
            fontSize: 16,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        content: Text(
          L.pick(
            en: 'Sign your name next to $_characterName\'s. This cannot be undone.',
            zhTW: '在 $_characterName 的名字旁簽下你的名字。簽了就不能反悔了。',
            zhCN: '在 $_characterName 的名字旁签下你的名字。签了就不能反悔了。',
          ),
          style: TextStyle(
            fontSize: 13,
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: Text(
              L.pick(en: 'Not yet', zhTW: '再想想', zhCN: '再想想'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'decline'),
            child: Text(
              L.pick(en: 'Decline', zhTW: '拒絕', zhCN: '拒绝'),
              style: TextStyle(
                color: YanciTheme.textSecondary.withValues(alpha: 0.9),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'sign'),
            child: Text(
              L.pick(en: 'Sign', zhTW: '簽字', zhCN: '签字'),
              style: TextStyle(
                color: YanciTheme.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'later') return;

    if (choice == 'decline') {
      // 拒絕二次確認：她會知道
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: YanciTheme.surfacePanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            L.pick(en: 'Decline for real?', zhTW: '確定拒絕？', zhCN: '确定拒绝？'),
            style: TextStyle(
              fontSize: 16,
              color: YanciTheme.textPrimary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          content: Text(
            L.pick(
              en: '$_characterName will know you declined.',
              zhTW: '$_characterName 會知道你拒絕了。',
              zhCN: '$_characterName 会知道你拒绝了。',
            ),
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                L.pick(en: 'Back', zhTW: '返回', zhCN: '返回'),
                style: TextStyle(color: YanciTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                L.pick(en: 'Decline', zhTW: '拒絕', zhCN: '拒绝'),
                style: TextStyle(
                  color: YanciTheme.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
      // 隱藏事件：她知道你拒了，立刻反應。證書留在原地，反悔還能簽
      await _onSendMessage(MarriageService.declinedEventNote());
      return;
    }

    await MarriageService.sign(_activeCharacterId);
    await _refreshMarriageState();
    // 隱藏事件：她知道你簽了，立刻反應
    await _onSendMessage(MarriageService.signedEventNote());
  }

  /// 同逛期間的動態清單注入（text/image 雙路徑共用），注入即遞減
  Future<String> _shopBrowsePrompt() async {
    if (_shopInviteRoundsLeft <= 0) return '';
    if (!await ShopService.isEnabled()) {
      _shopInviteRoundsLeft = 0;
      return '';
    }
    _shopInviteRoundsLeft--;
    final catalog = await ShopService.buildShopListPromptText();
    final header = L.pick(
      en: '【Browsing the Shop Together】You are browsing the shop together. Current catalog:',
      zhTW: '【一起逛商店】你們正在一起逛商店，當前商品清單：',
    );
    final instruction = L.pick(
      en: 'Talk about the items, offer suggestions, or buy something you like with <buy item="full-id" target="self or user"/>. You may also show no interest. The catalog is invisible to the other person; do not mention the catalog or system.',
      zhTW:
          '聊商品、給建議、看上什麼用 <buy item="完整id" target="self或user"/> 買，或不感興趣都隨你。清單對方看不到，正文不要提清單或系統本身。',
    );
    return '$header\n$catalog\n$instruction';
  }

  void _openChatBackpack() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BackpackBottomSheet(
        ownerId: 'user',
        pendingScopeId: widget.conversationId,
        targetCharId: _activeCharacterId,
        onGiftOut: (reservation) => setState(() => _pendingGift = reservation),
      ),
    );
  }

  Future<void> _cancelPendingGift() async {
    if (_pendingGift == null) return;
    final canceled = await ShopService.cancelPendingGift(widget.conversationId);
    if (canceled && mounted) setState(() => _pendingGift = null);
  }

  /// 發送時消費掛起禮物：入角色背包 + 返回消息尾標記
  Future<String> _consumePendingGift() async {
    if (_pendingGift == null) return '';
    final nick = await UserSettings.getUserName();
    final giver = nick.isNotEmpty ? nick : '對方';
    final delivered = await ShopService.deliverPendingGift(
      widget.conversationId,
      giverName: giver,
    );
    if (delivered == null) {
      if (mounted) setState(() => _pendingGift = null);
      return '';
    }
    if (mounted) setState(() => _pendingGift = null);
    return '\n[gift:${delivered.itemName}]';
  }

  // ═══ 自我註記快照（同款增量方案）═══
  // persona_note 每寫一條 self_notes 就變 → staticPart 前綴變 → 緩存全炸。
  // codex 抓到的緩存失效主因。凍結快照進靜態，窗內新增走動態。
  String? _selfNotesSnapshot;
  Set<String>? _selfNotesSnapshotLines;

  /// 滯後截斷：平時錨點固定（前綴穩定，不打斷緩存）；
  /// 超限時一次砍到限額 60%，然後再次固定，直到下次超限。
  /// 舊版每輪重算截斷點 → 前綴每輪變 → 開上下文限制 = 關緩存。
  Future<int> _hysteresisKeepFrom(List<String> contents) async {
    final enabled = await MemorySettings.getContextLimitEnabled();
    final limit = await MemorySettings.getContextTokenLimit();
    if (!enabled || limit <= 0 || contents.length <= 1) return 0;
    var from = _contextKeepFrom;
    if (from >= contents.length) from = contents.length - 1;
    if (from < 0) from = 0;
    int total = 0;
    for (int i = from; i < contents.length; i++) {
      total += TokenEstimator.estimate(contents[i]);
    }
    if (total <= limit) return from;
    final target = (limit * 0.6).round();
    int acc = 0;
    int keep = contents.length - 1;
    for (int i = contents.length - 1; i >= from; i--) {
      acc += TokenEstimator.estimate(contents[i]);
      if (acc > target) {
        keep = i + 1;
        break;
      }
      keep = i;
    }
    if (keep >= contents.length) keep = contents.length - 1;
    _contextKeepFrom = keep;
    return keep;
  }

  /// 後台畫圖：不阻塞回覆顯示，完成後更新消息的圖與日誌
  Future<void> _runDrawAsync(
    int messageId,
    String prompt,
    String baseLog,
  ) async {
    if (mounted) {
      setState(() {
        _isGeneratingImage = true;
        final idx = _messages.indexWhere((m) => m.id == messageId);
        if (idx >= 0) {
          final m = _messages[idx];
          _messages[idx] = Message(
            id: m.id,
            conversationId: m.conversationId,
            characterId: m.characterId,
            text: m.text,
            isUser: false,
            imagePath: 'generating',
            splitMode: m.splitMode,
            cacheHit: m.cacheHit,
            memoryLog: m.memoryLog,
            createdAt: m.createdAt,
          );
        }
      });
    }
    String note;
    String? path;
    try {
      // 讀取角色卡綁定的畫畫錨點
      final anchors = await DatabaseHelper.getDrawAnchors(_activeCharacterId);
      path = await ImageGenService.generate(
        prompt,
        userAnchor: anchors.user,
        charAnchor: anchors.char,
        style: anchors.style,
      );
      note = '🎨 生成圖片 ✓';
    } catch (e) {
      final msg = e.toString();
      note = '🎨 畫圖失敗：${msg.length > 140 ? msg.substring(0, 140) : msg}';
    }
    final newLog = baseLog.contains('🎨 生成中…')
        ? baseLog.replaceFirst('🎨 生成中…', note)
        : baseLog;
    await DatabaseHelper.updateMessageDraw(messageId, path, newLog);
    if (!mounted) return;
    setState(() {
      _isGeneratingImage = false;
      final idx = _messages.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        final m = _messages[idx];
        _messages[idx] = Message(
          id: m.id,
          conversationId: m.conversationId,
          characterId: m.characterId,
          text: m.text,
          isUser: false,
          imagePath: path ?? m.imagePath,
          splitMode: m.splitMode,
          cacheHit: m.cacheHit,
          memoryLog: newLog,
          createdAt: m.createdAt,
        );
      }
    });
  }

  /// 窗口摘要壓縮
  Future<int> _triggerContextCompression({
    String? conversationId,
    String? characterId,
    int? triggerTokenLimit,
  }) async {
    final running = _compressionInFlight;
    if (running != null) return running;

    final future = _performContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerTokenLimit: triggerTokenLimit,
    );
    _compressionInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_compressionInFlight, future)) {
        _compressionInFlight = null;
      }
    }
  }

  Future<int> _performContextCompression({
    String? conversationId,
    String? characterId,
    int? triggerTokenLimit,
  }) async {
    final convId = conversationId ?? widget.conversationId;
    final charId = characterId ?? _activeCharacterId;
    final tokenLimit = triggerTokenLimit ?? ContextCompressor.triggerTokens;
    final messages = await DatabaseHelper.getMessages(convId);
    if (messages.isEmpty) return 0;

    // 取最近一段觸發窗口內的消息；單條最新消息超過上限時仍保留它，
    // 避免長訊息讓摘要觸發後收成空窗口。
    final recentMsgs = <Map<String, String>>[];
    int accum = 0;
    for (int i = messages.length - 1; i >= 0; i--) {
      final t = TokenEstimator.estimate(messages[i].text);
      if (accum + t > tokenLimit && recentMsgs.isNotEmpty) break;
      accum += t;
      recentMsgs.insert(0, {
        'role': messages[i].isUser ? 'user' : 'assistant',
        'content': messages[i].text,
      });
      if (accum >= tokenLimit) break;
    }

    if (recentMsgs.isEmpty) return 0;

    final result = await ContextCompressor.compress(
      messages: recentMsgs,
      characterId: charId,
      conversationId: convId,
    );
    if (result > 0) {
      await _refreshWindowSummaryStateAfterCompression(convId);
      debugPrint('窗口摘要完成：$result tokens');
    }
    return result;
  }

  Future<void> _refreshWindowSummaryStateAfterCompression(String convId) async {
    // 壓縮後只更新動態路徑用的 window id（excludeWindowId）。
    // 靜態摘要 pin 綁對話 ID、已凍死，絕不在此失效——否則又炸緩存。
    _windowSummaryId = await DatabaseHelper.getConversationWindowSummaryId(
      convId,
    );
  }

  Future<String> _currentWindowSummaryId() async {
    final existing = _windowSummaryId;
    if (existing != null && existing.isNotEmpty) return existing;
    final id = await DatabaseHelper.ensureConversationWindowSummaryId(
      widget.conversationId,
    );
    _windowSummaryId = id;
    return id;
  }

  /// 靜態摘要 pin：綁對話 ID、出生釘一塊（最新滾動摘要原文）、存庫永凍。
  /// 之後不管壓縮 rotate、重開對話、摘要增刪，都讀這份釘死的複本——
  /// 前綴恆定，緩存不炸。詳見 cache_fix_定案清單.md。
  Future<String> _buildStaticWindowSummaryPrompt(String characterId) async {
    _syncPromptLocaleCaches();
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final summaryEnabled = await MemorySettings.getCacheWindowSummaryEnabled();
    if (!cacheEnabled || !summaryEnabled) {
      _cacheWindowSummaryStaticSnapshot = null;
      return '';
    }

    // 記憶體快照優先：本窗生命週期內只查一次庫。
    if (_cacheWindowSummaryStaticSnapshot != null) {
      return _cacheWindowSummaryStaticSnapshot!;
    }

    final convId = widget.conversationId;
    String? pinned = await DatabaseHelper.getConversationPinnedSummary(convId);

    if (pinned == null) {
      // 首建＝出生：抓「最新一塊」滾動摘要原文釘死（排除本對話自己的窗口）。
      // 可能為空（出生前無前情）——空也釘，之後永不再變。
      final windowId = await _currentWindowSummaryId();
      final rows = await DatabaseHelper.getLatestContextSummaries(
        characterId,
        excludeWindowId: windowId,
        limit: 1,
      );
      final text = rows.isNotEmpty
          ? (rows.first['content'] as String? ?? '')
          : '';
      await DatabaseHelper.setConversationPinnedSummary(convId, text);
      pinned = text;
    }

    final prompt = pinned.trim().isEmpty
        ? ''
        : _formatWindowSummaryPrompt(summary: pinned, keywordSummary: '');
    _cacheWindowSummaryStaticSnapshot = prompt;
    return prompt;
  }

  Future<String> _buildDynamicWindowSummaryPrompt(
    String characterId, {
    String currentMessage = '',
  }) async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final cacheSummaryEnabled =
        await MemorySettings.getCacheWindowSummaryEnabled();
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final contextSummaryEnabled =
        await MemorySettings.getContextWindowSummaryEnabled();

    final useCacheKeywordRecall = cacheEnabled && cacheSummaryEnabled;
    final useContextDynamic =
        !cacheEnabled && contextLimitEnabled && contextSummaryEnabled;
    if (!useCacheKeywordRecall && !useContextDynamic) return '';

    final windowId = await _currentWindowSummaryId();
    final pack = await ContextCompressor.loadSummaryPack(
      characterId,
      currentMessage: currentMessage,
      excludeWindowId: windowId,
      includeLatestSummaries: useContextDynamic,
      includeKeywordRecall: useCacheKeywordRecall || useContextDynamic,
    );
    final summary = (pack['summary'] ?? '').trim();
    final keywordSummaries = (pack['keywordSummaries'] ?? '').trim();
    return _formatWindowSummaryPrompt(
      summary: summary,
      keywordSummary: keywordSummaries,
    );
  }

  String _formatWindowSummaryPrompt({
    required String summary,
    required String keywordSummary,
  }) {
    final trimmedSummary = summary.trim();
    final trimmedKeyword = keywordSummary.trim();
    if (trimmedSummary.isEmpty && trimmedKeyword.isEmpty) return '';

    if (L.locale == 'en') {
      final parts = <String>[];
      if (trimmedSummary.isNotEmpty) {
        parts.add('Recent summaries:\n$trimmedSummary');
      }
      if (trimmedKeyword.isNotEmpty) {
        parts.add('Keyword-matched old summary:\n$trimmedKeyword');
      }
      return '【Window Summary】\n${parts.join('\n\n')}';
    }

    final parts = <String>[];
    if (trimmedSummary.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '最近窗口摘要：')}\n$trimmedSummary');
    }
    if (trimmedKeyword.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '命中關鍵詞召回的舊摘要：')}\n$trimmedKeyword');
    }
    return '${L.pick(en: '', zhTW: '【窗口摘要】')}\n${parts.join('\n\n')}';
  }

  Future<int> _windowSummaryTriggerTokenLimit() async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final contextSummaryEnabled =
        await MemorySettings.getContextWindowSummaryEnabled();
    if (!cacheEnabled && contextLimitEnabled && contextSummaryEnabled) {
      return MemorySettings.getContextWindowSummaryTriggerTokens();
    }
    return ContextCompressor.triggerTokens;
  }

  Future<int> _windowSummaryCloseMinTokenThreshold() async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final cacheSummaryEnabled =
        await MemorySettings.getCacheWindowSummaryEnabled();
    if (cacheEnabled && cacheSummaryEnabled) {
      return ContextCompressor.minCompressTokens;
    }
    return _windowSummaryTriggerTokenLimit();
  }

  Future<void> _recordCompletedRound({
    required String conversationId,
    required String userText,
    required String assistantText,
    required List<Map<String, String>> heartbeatHistory,
    required StructuredPrompt structuredPrompt,
    required ApiAdapter adapter,
    required String model,
    required String provider,
  }) async {
    _tokensSinceSummary +=
        TokenEstimator.estimate(userText) +
        TokenEstimator.estimate(assistantText);
    await _saveTokensSinceSummary();
    final keepAliveMessages = heartbeatHistory
        .where((m) => (m['content'] ?? '').trim().isNotEmpty)
        .map(
          (m) => <String, String>{
            'role': m['role'] ?? 'user',
            'content': m['content'] ?? '',
          },
        )
        .toList();
    if (assistantText.trim().isNotEmpty) {
      keepAliveMessages.add({
        'role': 'assistant',
        'content': assistantText.trim(),
      });
    }
    _lastKeepAliveMessages = keepAliveMessages;
    _lastKeepAliveStructuredPrompt = structuredPrompt;
    _lastKeepAliveAdapter = adapter;
    _lastKeepAliveModel = model;
    _lastKeepAliveProvider = provider;
    await KeepAliveService.instance.rememberActiveWindow(
      conversationId: conversationId,
      characterId: _activeCharacterId,
      messages: keepAliveMessages,
      structuredPrompt: structuredPrompt,
      adapter: adapter,
      model: model,
      provider: provider,
    );

    await _maybeRunTokenTriggeredMaintenance(
      conversationId: conversationId,
      characterId: _activeCharacterId,
    );
  }

  Future<void> _maybeRunTokenTriggeredMaintenance({
    String? conversationId,
    String? characterId,
  }) async {
    final triggerTokenLimit = await _windowSummaryTriggerTokenLimit();
    if (_tokensSinceSummary < triggerTokenLimit) return;

    final enabled = await MemorySettings.getWindowSummaryEnabled();
    if (!enabled) {
      return;
    }

    final compressedTokens = await _triggerContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerTokenLimit: triggerTokenLimit,
    );
    if (compressedTokens > 0) {
      _tokensSinceSummary = 0;
      await _saveTokensSinceSummary();
    }
  }

  /// 找到最近一條 pending 的 toChar 轉帳 key
  String? _findPendingToCharTransfer() {
    // 從後往前找（最近的 pending toChar）
    for (final msg in _messages.reversed) {
      if (msg.id == null) continue;
      final key = 'msg_${msg.id}';
      final td = _transferDataMap[key];
      if (td != null && td.direction == 'toChar' && td.status == 'pending') {
        return key;
      }
    }
    return null;
  }

  /// 轉帳操作完成後刷新 map + UI
  Future<void> _refreshTransfer(String? messageId) async {
    if (messageId == null) return;
    final previous = _transferDataMap[messageId];
    final updated = await TransferService.getData(messageId);
    if (updated != null) {
      _transferDataMap[messageId] = updated;
      if (updated.direction == 'toUser' &&
          updated.status == 'accepted' &&
          previous?.status != 'accepted') {
        _walletChanged = true;
      }
    }
    if (mounted) setState(() {});
  }

  /// 用戶主動發起轉帳（從 + 菜單）
  /// 不自動接受——觸發 AI 回覆，讓角色自己決定接受或退還。
  TransferData? _pendingUserTransfer;

  Future<void> _onTransferToChar(int amount) async {
    if (amount <= 0) return;
    final userCoins = await ScratchService.getUserCoins();
    if (userCoins < amount) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // 掛上 pending，等用戶按發送時和輸入文字一起出去。
    // 真正扣款仍在對方接受時發生，維持原本轉帳狀態機。
    if (mounted) {
      setState(() {
        _pendingUserTransfer = TransferData(
          amount: amount,
          direction: 'toChar',
        );
      });
    } else {
      _pendingUserTransfer = TransferData(amount: amount, direction: 'toChar');
    }
  }

  Future<ScratchData?> _createScratchGiftData(String scratcher) async {
    final ok = await ScratchService.spendUser(ScratchService.ticketCost);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return null;
    }
    _walletChanged = true;

    final prizes = ScratchService.rollPrizes();
    final autoReveal = scratcher == 'char'; // 讓 TA 刮 → 自動揭曉
    final scratchData = ScratchData(
      cost: ScratchService.ticketCost,
      who: scratcher,
      prizes: prizes,
      scratched: autoReveal,
    );

    // 如果是讓 TA 刮，App 本地直接揭曉並把獎勵加到角色幣。
    if (autoReveal) {
      int totalCoins = prizes.fold(0, (sum, p) => sum + p.coins);
      if (totalCoins > 0) {
        await ScratchService.earn(_activeCharacterId, totalCoins);
      }
    }

    return scratchData;
  }

  /// 用戶從 + 菜單購買刮刮卡。
  /// user 自己刮：立即建立本地刮卡；
  /// char 刮：像轉帳一樣掛到待發，送出時本地揭曉並讓 AI 回應。
  Future<void> _onScratchGift(String scratcher) async {
    if (scratcher == 'char') {
      final userCoins = await ScratchService.getUserCoins();
      if (userCoins < ScratchService.ticketCost) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
              backgroundColor: YanciTheme.accent,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      if (mounted) {
        setState(() => _pendingScratchGiftWho = 'char');
      } else {
        _pendingScratchGiftWho = 'char';
      }
      return;
    }

    final scratchData = await _createScratchGiftData(scratcher);
    if (scratchData == null) return;

    // 存入消息（user 側）
    final msg = Message(
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: '',
      isUser: true,
    );
    final insertedId = await DatabaseHelper.insertMessage(msg);
    _sentMessageInThisSession = true;
    final msgKey = 'msg_$insertedId';
    await ScratchService.saveData(msgKey, scratchData);
    _scratchDataMap[msgKey] = scratchData;

    // 帶 id 的完整 Message
    final savedMsg = Message(
      id: insertedId,
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: '',
      isUser: true,
    );
    if (mounted) {
      setState(() {
        _messages.add(savedMsg);
      });

      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        showScratchDialog(
          context,
          messageId: msgKey,
          data: scratchData,
          characterId: _activeCharacterId,
        ).then((_) async {
          final updated = await ScratchService.getData(msgKey);
          if (updated != null) _scratchDataMap[msgKey] = updated;
          if (mounted) setState(() {});
        });
      });
    }
  }

  void _clearComposerIfUnchanged(String submittedDraft) {
    if (_inputController.text.trim() == submittedDraft.trim()) {
      _inputController.clear();
    }
  }

  Future<void> _onSendMessage(
    String text, {
    bool clearComposerOnAccept = false,
  }) async {
    if (!_isChatReady ||
        _sendSubmissionInProgress ||
        _isGenerating ||
        _isGeneratingImage) {
      return;
    }

    if (mounted) {
      setState(() => _sendSubmissionInProgress = true);
    } else {
      _sendSubmissionInProgress = true;
    }
    try {
      await _sendMessageLocked(
        text,
        composerDraft: text,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    } finally {
      if (mounted) {
        setState(() => _sendSubmissionInProgress = false);
      } else {
        _sendSubmissionInProgress = false;
      }
    }
  }

  Future<void> _sendMessageLocked(
    String text, {
    required String composerDraft,
    required bool clearComposerOnAccept,
  }) async {
    if (!_isChatReady) return;
    final conversationId = widget.conversationId;
    // 新窗口第一句話 → 停止舊窗口保活 + 切換緩存會話
    if (_messages.where((m) => m.isUser).isEmpty) {
      KeepAliveService.instance.stop();
      CacheSession.conversationId = conversationId;
    }
    // 情緒衰減 tick（冪等：未到刷新間隔的點不會被動）
    EmotionCoordinates.tickDecay(_activeCharacterId);
    if (_isGenerating) return;
    if (_isGeneratingImage) return; // 圖片生成中不允許發送
    // 本地模型還在加載中 → 提示用戶稍候
    if (_localModelLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local model is loading, please wait...',
              zhTW: '本地模型加載中，請稍候……',
            ),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
      return;
    }
    _userScrolledUp = false; // 新消息 → 重新跟隨

    // 有待發圖片 → 圖文一起送
    if (_pendingImagePath != null) {
      final imgPath = _pendingImagePath!;
      setState(() => _pendingImagePath = null);
      return _sendImageLocked(
        imgPath,
        caption: text,
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    }

    // 有待發表情包 → 文字 + 表情包一起送
    if (_pendingSticker != null) {
      final sticker = _pendingSticker!;
      setState(() => _pendingSticker = null);
      final stickerTag = '[sticker:${sticker.id}]';
      final combined = text.isNotEmpty ? '$text\n$stickerTag' : stickerTag;
      // 遞迴回 _onSendMessage，此時 _pendingSticker 已清空不會再進來
      return _sendMessageLocked(
        combined,
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    }

    // 有掛起禮物 → 入對方背包 + 消息尾附 [gift:名稱]（氣泡隱藏、模型可見）
    final giftTag = await _consumePendingGift();
    if (giftTag.isNotEmpty) {
      return _sendMessageLocked(
        text.isNotEmpty ? '$text$giftTag' : giftTag.trim(),
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    }

    // 有掛起結婚證 → 消息尾附邀請標記＋動態語義說明（偶發事件不進靜態；簡繁英三語）
    if (_pendingMarriageCert) {
      setState(() => _pendingMarriageCert = false);
      final certTag = MarriageService.certTagNote();
      return _sendMessageLocked(
        text.isNotEmpty ? '$text$certTag' : certTag.trim(),
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    }

    final pendingTransfer = _pendingUserTransfer;
    final pendingScratchGiftWho = _pendingScratchGiftWho;
    final pendingScratchGift = pendingScratchGiftWho == null
        ? null
        : await _createScratchGiftData(pendingScratchGiftWho);
    if (pendingScratchGiftWho != null && pendingScratchGift == null) return;

    var outboundText = _appendTransferTag(text, pendingTransfer);
    outboundText = _appendScratchGiftTag(outboundText, pendingScratchGift);
    if (outboundText.isEmpty) return;
    if (pendingTransfer != null) {
      if (mounted) {
        setState(() => _pendingUserTransfer = null);
      } else {
        _pendingUserTransfer = null;
      }
    }
    if (pendingScratchGift != null) {
      if (mounted) {
        setState(() => _pendingScratchGiftWho = null);
      } else {
        _pendingScratchGiftWho = null;
      }
    }

    final userMsg = Message(
      conversationId: conversationId,
      characterId: _activeCharacterId,
      text: outboundText,
      isUser: true,
    );
    final userId = await DatabaseHelper.insertMessage(userMsg);
    unawaited(MarriageService.scanMessage(userMsg.text, _activeCharacterId));
    _sentMessageInThisSession = true;
    if (clearComposerOnAccept) {
      _clearComposerIfUnchanged(composerDraft);
    }

    // 如果有 pending 轉帳，掛到這條消息上
    if (pendingTransfer != null) {
      final msgKey = 'msg_$userId';
      await TransferService.saveData(msgKey, pendingTransfer);
      _transferDataMap[msgKey] = pendingTransfer;
    }
    if (pendingScratchGift != null) {
      final msgKey = 'msg_$userId';
      await ScratchService.saveData(msgKey, pendingScratchGift);
      _scratchDataMap[msgKey] = pendingScratchGift;
    }

    final userMsgWithId = Message(
      id: userId,
      conversationId: userMsg.conversationId,
      characterId: userMsg.characterId,
      text: userMsg.text,
      isUser: true,
      createdAt: userMsg.createdAt,
    );
    final workingMessages = <Message>[..._messages, userMsgWithId];
    final generationSerial = _beginGeneration();
    if (mounted) {
      setState(() {
        _messages.add(userMsgWithId);
        _setGenerating(true);
        _streamingText = '';
      });
      _scrollToBottom();
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    if (workingMessages.where((m) => m.isUser).length == 1) {
      // 先用前 20 字佔位
      final titleText = _titleTextForFirstMessage(
        text,
        pendingTransfer,
        pendingScratchGift,
      );
      final tempTitle = titleText.length > 20
          ? '${titleText.substring(0, 20)}...'
          : titleText;
      await DatabaseHelper.updateConversation(conversationId, title: tempTitle);
      _shouldAutoName = true; // 等 AI 回覆後自動命名
    }

    // ═══ 並行化：一次發射所有獨立的異步調用，大幅減少等待 ═══
    final charId = _activeCharacterId;
    final systemPromptF = ApiSettings.getSystemPrompt();
    final modelF = ApiSettings.getModel();
    final bucketF = _memoryBucket();
    final userProfileF = _buildUserProfilePrompt();
    final selfNotesF = DatabaseHelper.getSelfNotes(charId);
    final userNicknameF = UserSettings.getUserName();
    final emotionEnabledF = MemorySettings.isAbilityEnabled('emotion');
    final imagegenEnabledF = MemorySettings.isAbilityEnabled('imagegen');
    final bioclockEnabledF = MemorySettings.isAbilityEnabled('bioclock');
    final memoryWriteEnabledF = MemorySettings.getMemoryWriteEnabled();
    final providerNameF = ApiSettings.getApiProviderName();
    final conciseOnF = ApiSettings.getConciseMode();
    final freeformOnF = ApiSettings.getFreeformMode();
    final thinkingEnabledF = ApiSettings.getThinkingChain();
    final enableVibrationF = UserSettings.getEnableVibration();
    final adapterF = ApiSettings.buildAdapter();
    final charDataF = DatabaseHelper.getCharacter(charId);
    final isSpiderWebEnabledF = charDataF.then(
      (c) => (c?['is_spider_web_enabled'] as int? ?? 0) == 1,
    );
    final staticWindowSummaryF = _buildStaticWindowSummaryPrompt(charId);
    final dynamicWindowSummaryF = _buildDynamicWindowSummaryPrompt(
      charId,
      currentMessage: outboundText,
    );

    // 記憶注入依賴 bucket，先 await bucket 再發射
    final bucket = await bucketF;
    final memoryPromptF = Retriever.buildMemoryPrompt(
      mode: bucket,
      currentMessage: outboundText,
      characterId: charId,
      windowId: widget.conversationId,
    );

    // 動態部分：也提前發射
    final emoStateF = emotionEnabledF.then(
      (enabled) async =>
          enabled ? await EmotionCoordinates.statePrompt(charId) : '',
    );
    final clockDedupF = BioClockService.dedupPrompt(charId);
    final recallPromptF = CharacterTimelineService.recallPrompt(charId, text);
    final fatiguePromptF = bioclockEnabledF.then(
      (enabled) async =>
          enabled ? await BioClockService.fatiguePrompt(charId) : '',
    );

    // 收集結果
    final systemPrompt = await systemPromptF;
    final model = await modelF;
    _currentModel = model;
    final memoryPrompt = await memoryPromptF;
    final userProfile = await userProfileF;
    final selfNotes = await selfNotesF;
    final userNicknameStr = await userNicknameF;
    final isSpiderWebEnabled = await isSpiderWebEnabledF;
    final charData = await charDataF;
    final charDesc = charData?['description'] as String? ?? '';
    final charName = charData?['name'] as String? ?? '';
    final emotionEnabled = await emotionEnabledF;
    final imagegenEnabled = await imagegenEnabledF;
    final bioclockEnabled = await bioclockEnabledF;
    final memoryWriteEnabled = await memoryWriteEnabledF;
    final providerName = await providerNameF;
    final conciseOn = await conciseOnF;
    final freeformOn = await freeformOnF;
    final thinkingEnabled = await thinkingEnabledF;

    final staticBundle = await _buildCommonStaticParts(
      characterId: charId,
      systemPrompt: systemPrompt,
      charDesc: charDesc,
      characterName: charName,
      userProfile: userProfile,
      selfNotes: selfNotes,
      userNickname: userNicknameStr,
      isSpiderWebEnabled: isSpiderWebEnabled,
      memoryWriteEnabled: memoryWriteEnabled,
      emotionEnabled: emotionEnabled,
      bioclockEnabled: bioclockEnabled,
      imagegenEnabled: imagegenEnabled,
      providerName: providerName,
      conciseOn: conciseOn,
      freeformOn: freeformOn,
      staticWindowSummary: await staticWindowSummaryF,
    );

    final dynamicParts = <String>[];
    final now = DateTime.now();
    if (memoryPrompt.isNotEmpty) dynamicParts.add(memoryPrompt);
    final contextSummary = await dynamicWindowSummaryF;
    if (contextSummary.isNotEmpty) dynamicParts.add(contextSummary);

    final coinDelta = await _coinDeltaPrompt(charId);
    if (coinDelta.isNotEmpty) dynamicParts.add(coinDelta);
    // 背包窗內變動（「杯子+1（昭昭送的）」式增減量）
    if (_packQtySnapshot != null) {
      final packDelta = await ShopService.buildPackDelta(
        charId,
        _packQtySnapshot!,
      );
      if (packDelta.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Backpack Changes】', zhTW: '【背包變動】')}$packDelta',
        );
      }
    }
    final scratchGiftPrompt = _scratchGiftDynamicPrompt(pendingScratchGift);
    if (scratchGiftPrompt.isNotEmpty) dynamicParts.add(scratchGiftPrompt);

    // 上輪購買失敗回饋（消費即清，防止她以為禮物送出去了）
    final buyFailNote = ShopService.pendingBuyFailureNote;
    if (buyFailNote != null) {
      dynamicParts.add(buyFailNote);
      ShopService.pendingBuyFailureNote = null;
    }

    // 同逛商店：邀請後清單跟隨 3 輪（動態注入不入庫）
    final browsePrompt = await _shopBrowsePrompt();
    if (browsePrompt.isNotEmpty) dynamicParts.add(browsePrompt);

    // 結婚證：解鎖後她也可主動遞（未簽＋未遞過才注入）
    final proposeHint = await MarriageService.proposeHintPrompt(charId);
    if (proposeHint.isNotEmpty) dynamicParts.add(proposeHint);

    // X 發文動態狀態（剩餘條數每日變，不能進靜態）
    final xHint = await XPostSettings.promptHint(charId);
    if (xHint.isNotEmpty) {
      dynamicParts.add(
        '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$xHint',
      );
    }

    // 情緒狀態（已提前發射）
    final emoState = await emoStateF;
    if (emoState.isNotEmpty) dynamicParts.add(emoState);

    // 生物鐘（觸發 / 去重 / 校準，優先級：去重 > 校準 > 觸發）
    final clockDedup = await clockDedupF;
    if (clockDedup.isNotEmpty) {
      dynamicParts.add(clockDedup);
    } else {
      final clockCal = await BioClockService.calibratePrompt(charId);
      if (clockCal.isNotEmpty) {
        dynamicParts.add(clockCal);
      } else {
        final clockTrigger = await BioClockService.triggerPrompt(charId);
        if (clockTrigger.isNotEmpty) dynamicParts.add(clockTrigger);
      }
    }

    // 本窗口新記的習慣（相對開窗快照的增量，靜態快照不動保緩存）
    if (bioclockEnabled && _habitSnapshotIds != null) {
      final habitDelta = await BioClockService.habitDeltaPrompt(
        charId,
        _habitSnapshotIds!,
      );
      if (habitDelta.isNotEmpty) dynamicParts.add(habitDelta);
    }

    // 本窗口新記的自我註記（persona_note 增量，同上原理）
    if (selfNotes.isNotEmpty && _selfNotesSnapshotLines != null) {
      final freshNotes = selfNotes
          .split('\n')
          .where(
            (l) => l.trim().isNotEmpty && !_selfNotesSnapshotLines!.contains(l),
          )
          .toList();
      if (freshNotes.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Self-notes added this window】', zhTW: '【本窗口你新記的自我註記】')}\n${freshNotes.join('\n')}',
        );
      }
    }

    // 角色生活化（每個對話框第一條注入狀態快照）
    if (_isFirstRoundInWindow) {
      // 背包：有新增→全量+請重標星；無新增→只注星標（隨歷史進緩存前綴）
      if (await ShopService.isEnabled()) {
        final packPrompt = await ShopService.buildPackPrompt(charId);
        if (packPrompt.isNotEmpty) dynamicParts.add(packPrompt);
      }
      final snapshot = await CharacterTimelineService.stateSnapshotPrompt(
        charId,
      );
      if (snapshot.isNotEmpty) dynamicParts.add(snapshot);

      if (bioclockEnabled) {
        final setup = await BioClockService.setupPrompt(charId);
        if (setup.isNotEmpty) dynamicParts.add(setup);
      }
    }

    // 回憶觸發（已提前發射）
    final recallPrompt = await recallPromptF;
    if (recallPrompt.isNotEmpty) dynamicParts.add(recallPrompt);

    // 疲勞提示（已提前發射）
    final fatiguePrompt = await fatiguePromptF;
    if (fatiguePrompt.isNotEmpty) dynamicParts.add(fatiguePrompt);

    // 時間（變動最頻繁，放在動態區塊最後面以保護前面的 Cache）
    dynamicParts.add(_timePrompt(now));

    // 思考鏈
    if (thinkingEnabled) {
      dynamicParts.add(
        L.pick(
          en: '【Thinking Mode】Before replying, show your inner thought process in <think>...</think> tags (first person), then reply normally.',
          zhTW: '【思考模式】在回覆前，用 <think>...</think> 標籤展示你的內心思考過程（第一人稱），思考完再正常回覆。',
        ),
      );
    }

    // 拆分回覆模式
    if (_splitReply) {
      dynamicParts.add(
        L.pick(
          en: '【Split Reply Mode】Reply using speech only — no action descriptions, no narration, no *asterisk actions*. Use line breaks between separate thoughts. Keep each paragraph concise.',
          zhTW: '【拆分回覆模式】只用說話內容回覆，不要使用動作描述、旁白敘事、*星號動作*。不同的話之間用換行分段。每段簡短自然。',
        ),
      );
    }

    final structured = StructuredPrompt(
      staticPart: staticBundle.staticPart,
      profilePart: staticBundle.profilePart,
      dynamicPart: dynamicParts.join('\n\n'),
    );

    if (mounted) {
      setState(() {
        _setGenerating(true);
        _clearStreamQueue();
      });
    } else {
      _setGenerating(true);
      _clearStreamQueue();
    }

    try {
      final enableVibration = await enableVibrationF;
      final adapter = await adapterF;

      final nonEmpty = workingMessages.where((m) => m.text.isNotEmpty).toList();
      var history = nonEmpty
          .map(
            (m) => {'role': m.isUser ? 'user' : 'assistant', 'content': m.text},
          )
          .toList();

      // ═══ 系統底層神經元通知 (動態注入潛意識) ═══
      if (isSpiderWebEnabled &&
          Retriever.triggeredCountFor(widget.conversationId) >= 3 &&
          history.isNotEmpty &&
          history.last['role'] == 'user') {
        history.last['content'] =
            '${history.last['content']}\n\n[系統底層神經元通知：偵測到多重關鍵字碰撞，請評估是否觸發 <memo_link> 標籤將相關記憶串聯。]';
      }

      // ═══ B4 滯後截斷（保護前綴緩存）═══
      final keepFrom = await _hysteresisKeepFrom(
        history.map((m) => (m['content'] ?? '').toString()).toList(),
      );
      if (keepFrom > 0 && keepFrom < history.length) {
        var start = keepFrom;
        history = history.sublist(keepFrom);
        // 截斷後保證從 user 開頭（部分 provider 嚴格要求交替）
        while (history.length > 1 && history.first['role'] != 'user') {
          history.removeAt(0);
          start++;
        }
        // 砍頭點同步為窗口錨點：重開窗按同一起點載入，
        // 砍頭與重開窗的炸點合併成同一次
        final anchorMsgId = start < nonEmpty.length ? nonEmpty[start].id : null;
        if (anchorMsgId != null) {
          unawaited(_persistContextAnchor(anchorMsgId));
        }
      }

      final rawReply = StringBuffer();
      await for (final chunk in adapter.sendMessageStream(
        messages: history,
        model: model,
        structuredPrompt: structured,
      )) {
        if (!_isCurrentGeneration(generationSerial)) return;
        rawReply.write(chunk);
        if (mounted) _onStreamChunk(chunk);
      }
      final replyText = rawReply.toString();
      if (!_isCurrentGeneration(generationSerial)) return;

      // ═══ 記錄真實 API 用量（不再用估算，避免雙重計算）═══
      final provider = await ApiSettings.getApiProvider();
      await _tokenTracker.recordRealUsage(
        provider: provider,
        model: model,
        characterId: _activeCharacterId,
      );

      // 檢查本次是否命中緩存
      final cacheRead = _cacheReadForProvider(provider);

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = (memoryWriteEnabled || isSpiderWebEnabled)
          ? await MemoryActions.processReply(
              replyText,
              characterId: _activeCharacterId,
              mode: await _memoryBucket(),
              windowId: widget.conversationId,
            )
          : MemoryActions.stripReply(
              replyText,
              windowId: widget.conversationId,
            );

      // ═══ 蛛網專屬標籤：<memo_link> 與 <force_recall> 處理 ═══
      if (isSpiderWebEnabled) {
        processedText = await SpiderWebCore.processReply(
          processedText,
          characterId: _activeCharacterId,
          windowId: widget.conversationId,
        );
      }

      // ═══ 商店系統：<buy> 處理 ═══
      processedText = await ShopService.processReply(
        processedText,
        characterName: _characterName,
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
      );

      // ═══ 情緒座標：<emo> 打點入庫並剝離 ═══
      // 同輪有 <memo> 時，點綁定那條記憶（同一輪 = 同一情緒時刻），
      // 翻舊帳由此能撈回「點 + 原記憶」
      processedText = await EmotionCoordinates.processReply(
        processedText,
        characterId: _activeCharacterId,
        memoryId: MemoryActions.lastInsertedMemoryIdFor(widget.conversationId),
      );
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      processedText = await BioClockService.processReply(
        processedText,
        characterId: _activeCharacterId,
      );
      // ═══ 角色生活化：<life_fix> 處理 + 關鍵詞掃描 ═══
      processedText = await CharacterTimelineService.processLifeFix(
        _activeCharacterId,
        processedText,
      );
      await CharacterTimelineService.scanReply(
        _activeCharacterId,
        processedText,
      );
      await BioClockService.recordLastChatTime(_activeCharacterId);
      _isFirstRoundInWindow = false;
      // ═══ 便箋：<home> 標籤處理（存入 sticky_notes）═══
      final homeMatch = RegExp(
        r'<home>([\s\S]*?)</home>',
      ).firstMatch(processedText);
      if (homeMatch != null) {
        var homeText = homeMatch.group(1)!.trim();
        if (homeText.length > 12) homeText = homeText.substring(0, 12);
        await DatabaseHelper.addNote(homeText, characterId: _activeCharacterId);
        processedText = processedText
            .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
            .trim();
      }
      // ═══ 刮刮樂：<scratch> 標籤處理 ═══
      ScratchData? pendingScratch;
      final scratchMatch = RegExp(
        r'<scratch\s+who="(\w+)"\s*/>',
      ).firstMatch(processedText);
      if (scratchMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<scratch\s+[^>]*/>'), '')
            .trim();
        final who = scratchMatch.group(1) ?? 'char';
        // AI 觸發 → 扣角色的幣
        final ok = await ScratchService.spend(
          _activeCharacterId,
          ScratchService.ticketCost,
        );
        if (ok) {
          pendingScratch = ScratchData(
            cost: ScratchService.ticketCost,
            who: who,
            prizes: ScratchService.rollPrizes(),
            scratched: false,
          );
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(
                    en: '$_characterName does not have enough shells to send a scratch card.',
                    zhTW: '【$_characterName】貝殼不足，無法送出刮刮樂',
                  ),
                ),
                backgroundColor: YanciTheme.accent,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
      // ═══ 生成 UI memoryLog 之前清理殘餘標籤 ═══
      String? drawPrompt;
      final drawEventMatch = RegExp(r'<draw\s*/>').firstMatch(processedText);
      if (drawEventMatch != null) {
        drawPrompt = L.pick(
          en: '(reference image uploaded manually by the user / or retained by the system)',
          zhTW: '(由用戶手動上傳參考圖 / 或系統保留)',
        );
        processedText = processedText
            .replaceAll(RegExp(r'<draw\s*/>'), '')
            .trim();
      }
      // ═══ 轉帳：<transfer> 標籤處理 ═══
      TransferData? pendingTransfer;
      final transferMatch = RegExp(
        r'<transfer\s+amount="(\d+)"\s*/>',
      ).firstMatch(processedText);
      if (transferMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer\s+[^>]*/>'), '')
            .trim();
        final amount = int.tryParse(transferMatch.group(1) ?? '') ?? 0;
        if (amount > 0) {
          pendingTransfer = TransferData(
            amount: amount,
            direction: 'toUser', // AI 觸發 → 角色轉給 user
          );
        }
      }
      // ═══ 轉帳回應：<transfer_accept/> / <transfer_decline/> ═══
      // AI 對用戶發起的 toChar 轉帳做出回應
      final hasAccept = RegExp(
        r'<transfer_accept\s*/>',
      ).hasMatch(processedText);
      final hasDecline = RegExp(
        r'<transfer_decline\s*/>',
      ).hasMatch(processedText);
      if (hasAccept || hasDecline) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer_accept\s*/>'), '')
            .replaceAll(RegExp(r'<transfer_decline\s*/>'), '')
            .trim();
        // 找到最近一條 pending 的 toChar 轉帳
        final pendingKey = _findPendingToCharTransfer();
        if (pendingKey != null) {
          if (hasAccept) {
            final accepted = await TransferService.acceptTransfer(
              pendingKey,
              _activeCharacterId,
            );
            if (accepted) _walletChanged = true;
          } else {
            await TransferService.declineTransfer(pendingKey);
          }
          final updated = await TransferService.getData(pendingKey);
          if (updated != null) _transferDataMap[pendingKey] = updated;
        }
      }
      // ═══ 結婚證簽署：<sign_marriage/>（text/image 雙路徑同款）═══
      if (_signMarriageRe.hasMatch(processedText)) {
        processedText = processedText.replaceAll(_signMarriageRe, '').trim();
        await MarriageService.sign(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 結婚證主動遞出：<propose_marriage/> → 她的消息尾掛可簽證書 ═══
      if (_proposeMarriageRe.hasMatch(processedText)) {
        processedText = processedText.replaceAll(_proposeMarriageRe, '').trim();
        processedText = '$processedText\n$_marriageCertCharTag';
        await MarriageService.markCharProposed(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 模型發起通話：<call>開場白</call> / <call/> ═══
      String? pendingCallOpening;
      final callMatch = RegExp(
        r'<call>([\s\S]*?)</call>|<call\s*/>',
      ).firstMatch(processedText);
      if (callMatch != null) {
        pendingCallOpening = (callMatch.group(1) ?? '').trim();
        processedText = processedText
            .replaceAll(RegExp(r'<call>[\s\S]*?</call>'), '')
            .replaceAll(RegExp(r'<call\s*/>'), '')
            .trim();
      }
      // ═══ 模型畫畫：先出字後出圖（圖在後台生成，好了自己掛上）═══
      final drawMatch = RegExp(
        r'<draw>([\s\S]*?)</draw>',
      ).firstMatch(processedText);
      if (drawMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
            .trim();
        drawPrompt = drawMatch.group(1)!.trim();
      }
      // ═══ 歷史搜尋：<search_chat> 觸發可視化搜索 + 自動追加回覆 ═══
      final searchQuery = MemoryActions.lastSearchQueryFor(
        widget.conversationId,
      );
      if (searchQuery != null) {
        // Phase 1: 顯示搜索中狀態
        if (mounted) {
          setState(() {
            _chatSearching = true;
            _chatSearchQuery = searchQuery;
            _chatSearchResults = [];
            _streamingText = processedText;
          });
          _scrollToBottom();
        }
        final searchResults = await DatabaseHelper.searchMessages(
          keyword: searchQuery,
          characterId: _activeCharacterId,
        );
        // Phase 2: 顯示搜索結果
        if (mounted) {
          setState(() {
            _chatSearching = false;
            _chatSearchResults = searchResults;
          });
          _scrollToBottom();
        }
        if (searchResults.isNotEmpty) {
          final nick = userNicknameStr.isNotEmpty
              ? userNicknameStr
              : L.pick(en: 'the other person', zhTW: '對方');
          final resultLines = searchResults.map((r) {
            final who = (r['is_user'] as int) == 1
                ? nick
                : L.pick(en: 'you', zhTW: '你');
            final date = (r['created_at'] as String).substring(0, 10);
            var t = r['text'] as String;
            if (t.length > 200) t = '${t.substring(0, 200)}…';
            return '[$date] $who${L.pick(en: ': ', zhTW: '：')}$t';
          }).toList();
          final searchHeader = L.pick(
            en: '【Hidden Chat Retrieval Results | invisible to user】\nQuery: ',
            zhTW: '【隱藏歷史檢索結果｜user 不可見】\n查詢詞：',
          );
          final searchRules = L.pick(
            en: 'Rules: This is internal reference material only. Do not say “I searched”, mention chat records, keywords, browsers, or reveal the retrieval process; do not output a list. Weave useful information naturally into the next visible reply while continuing the prior tone and relationship state.',
            zhTW:
                '規則：這些內容只是系統給你的內部參考。不要說「我搜尋到了」「聊天記錄」「關鍵詞」「瀏覽器」或展示檢索過程；不要列清單。請把有用資訊自然融入下一句正式回覆，延續先前語氣與關係狀態。',
          );
          final injection =
              '$searchHeader「$searchQuery」\n${resultLines.join('\n')}\n---\n$searchRules';
          final followHistory = [
            ...history,
            if (processedText.trim().isNotEmpty)
              {'role': 'assistant', 'content': processedText},
            {'role': 'user', 'content': injection},
          ];
          // Phase 3: 二次流式生成
          final buf = StringBuffer();
          if (mounted) {
            _onStreamChunk('\n\n');
          }
          await for (final chunk in adapter.sendMessageStream(
            messages: followHistory,
            model: model,
            structuredPrompt: structured,
          )) {
            if (!_isCurrentGeneration(generationSerial)) return;
            buf.write(chunk);
            if (mounted) _onStreamChunk(chunk);
          }
          var followUp = memoryWriteEnabled
              ? await MemoryActions.processReply(
                  buf.toString(),
                  characterId: _activeCharacterId,
                  mode: await _memoryBucket(),
                  windowId: widget.conversationId,
                )
              : MemoryActions.stripReply(
                  buf.toString(),
                  windowId: widget.conversationId,
                );
          // ═══ 蛛網：follow-up 也需要處理 <memo_link>/<force_recall> ═══
          if (isSpiderWebEnabled) {
            followUp = await SpiderWebCore.processReply(
              followUp,
              characterId: _activeCharacterId,
              windowId: widget.conversationId,
            );
          }
          followUp = await ShopService.processReply(
            followUp,
            characterName: _characterName,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
          );
          followUp = await EmotionCoordinates.processReply(
            followUp,
            characterId: _activeCharacterId,
            memoryId: MemoryActions.lastInsertedMemoryIdFor(
              widget.conversationId,
            ),
          );
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
              .trim();
          if (followUp.isNotEmpty) {
            processedText = '$processedText\n\n$followUp'.trim();
          }
        }
        // Phase 4: 清除搜索卡片
        MemoryActions.clearSearchQuery(widget.conversationId);
        if (mounted) {
          setState(() {
            _chatSearching = false;
            _chatSearchQuery = '';
            _chatSearchResults = [];
          });
        }
      }

      // ═══ 商店瀏覽：<shop_view/> two-pass（清單只在起念時注入，零緩存污染）═══
      if (_shopViewTagRe.hasMatch(processedText)) {
        processedText = processedText.replaceAll(_shopViewTagRe, '').trim();
        if (await ShopService.isEnabled()) {
          final catalog = await ShopService.buildShopListPromptText();
          final injection =
              '${L.pick(en: '【Hidden Shop Catalog | invisible to user】', zhTW: '【隱藏商店清單｜user 不可見】')}\n$catalog\n---\n${L.pick(en: 'Use the latest shell-balance context. To buy, put <buy item="full-id" target="self or user"/> at the end of the next reply (use user to gift it). Otherwise continue naturally. Do not mention the catalog or system.', zhTW: '餘額以上下文最新的貝殼提示為準。想買就在接下來的回覆末尾用 <buy item="完整id" target="self或user"/>（送對方用 user）；不想買就自然繼續。不要提清單或系統本身。')}';
          final followHistory = [
            ...history,
            if (processedText.trim().isNotEmpty)
              {'role': 'assistant', 'content': processedText},
            {'role': 'user', 'content': injection},
          ];
          final buf = StringBuffer();
          if (mounted) _onStreamChunk('\n\n');
          await for (final chunk in adapter.sendMessageStream(
            messages: followHistory,
            model: model,
            structuredPrompt: structured,
          )) {
            if (!_isCurrentGeneration(generationSerial)) return;
            buf.write(chunk);
            if (mounted) _onStreamChunk(chunk);
          }
          var followUp = MemoryActions.stripReply(
            buf.toString(),
            windowId: widget.conversationId,
          );
          followUp = await ShopService.processReply(
            followUp,
            characterName: _characterName,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
          );
          followUp = await EmotionCoordinates.processReply(
            followUp,
            characterId: _activeCharacterId,
            memoryId: null,
          );
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .trim();
          if (followUp.isNotEmpty) {
            processedText = '$processedText\n\n$followUp'.trim();
          }
        }
      }

      processedText = _extractXPostAndStrip(processedText);

      // ═══ 記憶過程日誌：只記寫入本地的操作 ═══
      // （注入給模型的內容不顯示——那是給她看的，不是給你看的）
      final memLogLines = <String>[
        ...MemoryActions.lastActionLogFor(widget.conversationId),
        ...EmotionCoordinates.lastPointLog,
        ...BioClockService.lastActionLog,
        if (drawPrompt != null) '🎨 生成中…',
      ];
      final memLog = memLogLines.isEmpty
          ? ''
          : '${memLogLines.join('\n')}\nDone';
      if (!_isCurrentGeneration(generationSerial)) return;
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: cacheRead > 0,
        memoryLog: memLog,
      );
      final insertedId = await DatabaseHelper.insertMessage(aiMsg);
      unawaited(
        MarriageService.scanMessage(
          aiMsg.text,
          _activeCharacterId,
        ).then((_) => _refreshMarriageState()),
      );
      // 用插入後的 id 重建（避免 msg_null 導致收藏串連）
      final aiMsgWithId = Message(
        id: insertedId,
        conversationId: aiMsg.conversationId,
        characterId: aiMsg.characterId,
        text: aiMsg.text,
        isUser: false,
        splitMode: aiMsg.splitMode,
        cacheHit: aiMsg.cacheHit,
        createdAt: aiMsg.createdAt,
        imagePath: aiMsg.imagePath,
        memoryLog: aiMsg.memoryLog,
      );

      // 記錄命中的 messageId
      if (cacheRead > 0 && mounted) {
        _cacheHitIndices.add(_messages.length);
      }

      if (mounted) {
        setState(() {
          _messages.add(aiMsgWithId);
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _clearStreamQueue();
        _setGenerating(false);
      }
      if (drawPrompt != null && aiMsgWithId.id != null) {
        _runDrawAsync(aiMsgWithId.id!, drawPrompt, memLog);
      }

      // ═══ 商店：消費本輪 <buy> 結果（送禮系統訊息即時上屏 + 失敗提示）═══
      await _consumeBuyResults(widget.conversationId);

      // ═══ X 發文：確認卡 → 發送 ═══
      await _handleXPost();

      // ═══ 模型來電：停 2.5 秒再響鈴（像她想了想才撥）═══
      if (pendingCallOpening != null) {
        _scheduleIncomingCall(pendingCallOpening);
      }

      // ═══ 刮刮樂：存數據 + 彈出刮卡 ═══
      if (pendingScratch != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await ScratchService.saveData(msgId, pendingScratch);
        _scratchDataMap[msgId] = pendingScratch;
        if (mounted) {
          // 稍等氣泡動畫完成再彈出
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            showScratchDialog(
              context,
              messageId: msgId,
              data: pendingScratch!,
              characterId: _activeCharacterId,
            ).then((_) async {
              // 刮完後更新本地 map + 刷新氣泡
              final updated = await ScratchService.getData(msgId);
              if (updated != null) _scratchDataMap[msgId] = updated;
              if (mounted) setState(() {});
            });
          });
        }
      }

      // ═══ 轉帳：存數據 ═══
      if (pendingTransfer != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await TransferService.saveData(msgId, pendingTransfer);
        _transferDataMap[msgId] = pendingTransfer;
        if (mounted) setState(() {});
      }

      // ═══ 回覆完成震動 + Cache 命中震動 ═══
      final cacheDisplay = _getCacheDisplay(provider);
      if (mounted) {
        if (cacheDisplay != null && cacheDisplay.$1.contains('hit')) {
          HapticFeedback.heavyImpact(); // cache 命中用重震動
        } else if (enableVibration) {
          HapticFeedback.mediumImpact(); // 普通回覆用中震動
        }
      }

      await _recordCompletedRound(
        conversationId: conversationId,
        userText: outboundText,
        assistantText: aiMsgWithId.text,
        heartbeatHistory: history,
        structuredPrompt: structured,
        adapter: adapter,
        model: model,
        provider: provider,
      );

      // ═══ AI 自動命名 ═══
      if (_shouldAutoName) {
        _shouldAutoName = false;
        _autoNameConversation(
          _titleTextForFirstMessage(text, pendingTransfer, pendingScratchGift),
          aiMsg.text,
          conversationId: conversationId,
        );
      }
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final errorText = '出錯了：${e.toString()}';
      final errorMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: errorText,
        isUser: false,
        splitMode: _splitReply,
      );
      final errorId = await DatabaseHelper.insertMessage(errorMsg);
      final savedErrorMsg = Message(
        id: errorId,
        conversationId: errorMsg.conversationId,
        characterId: errorMsg.characterId,
        text: errorMsg.text,
        isUser: errorMsg.isUser,
        splitMode: errorMsg.splitMode,
        createdAt: errorMsg.createdAt,
      );

      if (mounted) {
        setState(() {
          _messages.add(savedErrorMsg);
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _clearStreamQueue();
        _setGenerating(false);
      }
    }
    if (mounted) _scrollToBottom();
  }

  /// 發送圖片（相冊 or 表情包）
  Future<void> _sendImageLocked(
    String path, {
    String caption = '',
    required String composerDraft,
    required bool clearComposerOnAccept,
  }) async {
    if (!_isChatReady) return;
    final conversationId = widget.conversationId;
    if (_messages.where((m) => m.isUser).isEmpty) {
      KeepAliveService.instance.stop();
      CacheSession.conversationId = conversationId;
    }
    if (_isGenerating) return;
    if (_isGeneratingImage) return;
    if (_localModelLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local model is loading, please wait...',
              zhTW: '本地模型加載中，請稍候……',
            ),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
      return;
    }

    // 複製到 app 目錄
    final saved = await ImageService.copyToAppDir(path);
    final pendingTransfer = _pendingUserTransfer;
    final pendingScratchGiftWho = _pendingScratchGiftWho;
    final pendingScratchGift = pendingScratchGiftWho == null
        ? null
        : await _createScratchGiftData(pendingScratchGiftWho);
    if (pendingScratchGiftWho != null && pendingScratchGift == null) return;

    var outboundCaption = _appendTransferTag(caption, pendingTransfer);
    outboundCaption = _appendScratchGiftTag(
      outboundCaption,
      pendingScratchGift,
    );
    if (pendingTransfer != null) {
      if (mounted) {
        setState(() => _pendingUserTransfer = null);
      } else {
        _pendingUserTransfer = null;
      }
    }
    if (pendingScratchGift != null) {
      if (mounted) {
        setState(() => _pendingScratchGiftWho = null);
      } else {
        _pendingScratchGiftWho = null;
      }
    }

    final userMsg = Message(
      conversationId: conversationId,
      characterId: _activeCharacterId,
      text: outboundCaption,
      isUser: true,
      imagePath: saved,
    );
    final imgUserId = await DatabaseHelper.insertMessage(userMsg);
    unawaited(MarriageService.scanMessage(userMsg.text, _activeCharacterId));
    _sentMessageInThisSession = true;
    if (clearComposerOnAccept) {
      _clearComposerIfUnchanged(composerDraft);
    }
    if (pendingTransfer != null) {
      final msgKey = 'msg_$imgUserId';
      await TransferService.saveData(msgKey, pendingTransfer);
      _transferDataMap[msgKey] = pendingTransfer;
    }
    if (pendingScratchGift != null) {
      final msgKey = 'msg_$imgUserId';
      await ScratchService.saveData(msgKey, pendingScratchGift);
      _scratchDataMap[msgKey] = pendingScratchGift;
    }
    final userMsgWithId = Message(
      id: imgUserId,
      conversationId: userMsg.conversationId,
      characterId: userMsg.characterId,
      text: userMsg.text,
      isUser: true,
      imagePath: userMsg.imagePath,
      createdAt: userMsg.createdAt,
    );
    final workingMessages = <Message>[..._messages, userMsgWithId];
    final generationSerial = _beginGeneration();
    if (mounted) {
      setState(() {
        _messages.add(userMsgWithId);
        _setGenerating(true);
        _streamingText = '';
      });
      _scrollToBottom();
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    // ── 構建 API 消息 ──
    final systemPrompt = await ApiSettings.getSystemPrompt();
    final model = await ApiSettings.getModel();
    _currentModel = model;
    final imgMemoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();

    final memoryPrompt = await Retriever.buildMemoryPrompt(
      mode: await _memoryBucket(),
      currentMessage: outboundCaption.isNotEmpty
          ? outboundCaption
          : '（用戶發送了一張圖片）',
      characterId: _activeCharacterId,
      windowId: widget.conversationId,
    );
    final imgUserProfile = await _buildUserProfilePrompt();
    final imgSelfNotes = await DatabaseHelper.getSelfNotes(_activeCharacterId);
    final userNickname = await UserSettings.getUserName();
    final charDataImg = await DatabaseHelper.getCharacter(_activeCharacterId);
    final imgCharDesc = charDataImg?['description'] as String? ?? '';
    final imgCharName = charDataImg?['name'] as String? ?? '';
    final isSpiderWebEnabledImg =
        (charDataImg?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
    final imgBioclockEnabled = await MemorySettings.isAbilityEnabled(
      'bioclock',
    );
    final imgImagegenEnabled = await MemorySettings.isAbilityEnabled(
      'imagegen',
    );
    final imgProviderName = await ApiSettings.getApiProviderName();
    final imgConciseOn = await ApiSettings.getConciseMode();
    final imgFreeformOn = await ApiSettings.getFreeformMode();

    final staticBundle = await _buildCommonStaticParts(
      characterId: _activeCharacterId,
      systemPrompt: systemPrompt,
      charDesc: imgCharDesc,
      characterName: imgCharName,
      userProfile: imgUserProfile,
      selfNotes: imgSelfNotes,
      userNickname: userNickname,
      isSpiderWebEnabled: isSpiderWebEnabledImg,
      memoryWriteEnabled: imgMemoryWriteEnabled,
      emotionEnabled: emotionEnabled,
      bioclockEnabled: imgBioclockEnabled,
      imagegenEnabled: imgImagegenEnabled,
      providerName: imgProviderName,
      conciseOn: imgConciseOn,
      freeformOn: imgFreeformOn,
      staticWindowSummary: await _buildStaticWindowSummaryPrompt(
        _activeCharacterId,
      ),
    );

    final now = DateTime.now();
    final dynamicParts = <String>[_timePrompt(now)];
    if (memoryPrompt.isNotEmpty) dynamicParts.add(memoryPrompt);
    final imgContextSummary = await _buildDynamicWindowSummaryPrompt(
      _activeCharacterId,
      currentMessage: outboundCaption.isNotEmpty
          ? outboundCaption
          : L.pick(en: 'The user sent an image.', zhTW: '用戶發送了一張圖片'),
    );
    if (imgContextSummary.isNotEmpty) dynamicParts.add(imgContextSummary);
    final imgCoinDelta = await _coinDeltaPrompt(_activeCharacterId);
    if (imgCoinDelta.isNotEmpty) dynamicParts.add(imgCoinDelta);
    // 背包窗內變動（與 text path 同步）
    if (_packQtySnapshot != null) {
      final imgPackDelta = await ShopService.buildPackDelta(
        _activeCharacterId,
        _packQtySnapshot!,
      );
      if (imgPackDelta.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Backpack Changes】', zhTW: '【背包變動】')}$imgPackDelta',
        );
      }
    }
    final imgScratchGiftPrompt = _scratchGiftDynamicPrompt(pendingScratchGift);
    if (imgScratchGiftPrompt.isNotEmpty) {
      dynamicParts.add(imgScratchGiftPrompt);
    }
    // 上輪購買失敗回饋（與 text path 同步）
    final imgBuyFailNote = ShopService.pendingBuyFailureNote;
    if (imgBuyFailNote != null) {
      dynamicParts.add(imgBuyFailNote);
      ShopService.pendingBuyFailureNote = null;
    }
    // 同逛商店清單跟隨（與 text path 同步）
    final imgBrowsePrompt = await _shopBrowsePrompt();
    if (imgBrowsePrompt.isNotEmpty) dynamicParts.add(imgBrowsePrompt);
    // 結婚證主動遞提示（與 text path 同步）
    final imgProposeHint = await MarriageService.proposeHintPrompt(
      _activeCharacterId,
    );
    if (imgProposeHint.isNotEmpty) dynamicParts.add(imgProposeHint);
    // X 發文動態狀態（與 text path 同步）
    final imgXHint = await XPostSettings.promptHint(_activeCharacterId);
    if (imgXHint.isNotEmpty) {
      dynamicParts.add(
        '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$imgXHint',
      );
    }
    // 情緒狀態回饋（餵狀態不餵機制，空狀態零開銷）
    if (emotionEnabled) {
      final emoState = await EmotionCoordinates.statePrompt(_activeCharacterId);
      if (emoState.isNotEmpty) dynamicParts.add(emoState);
    }

    // 生物鐘
    if (imgBioclockEnabled) {
      final imgClockTrigger = await BioClockService.triggerPrompt(
        _activeCharacterId,
      );
      if (imgClockTrigger.isNotEmpty) dynamicParts.add(imgClockTrigger);

      final fatigueP = await BioClockService.fatiguePrompt(_activeCharacterId);
      if (fatigueP.isNotEmpty) dynamicParts.add(fatigueP);

      if (_habitSnapshotIds != null) {
        final habitDelta = await BioClockService.habitDeltaPrompt(
          _activeCharacterId,
          _habitSnapshotIds!,
        );
        if (habitDelta.isNotEmpty) dynamicParts.add(habitDelta);
      }
    }

    if (imgSelfNotes.isNotEmpty && _selfNotesSnapshotLines != null) {
      final freshNotes = imgSelfNotes
          .split('\n')
          .where(
            (l) => l.trim().isNotEmpty && !_selfNotesSnapshotLines!.contains(l),
          )
          .toList();
      if (freshNotes.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Self-notes added this window】', zhTW: '【本窗口你新記的自我註記】')}\n${freshNotes.join('\n')}',
        );
      }
    }

    // 思考鏈
    final thinkingOn = await ApiSettings.getThinkingChain();
    if (thinkingOn) {
      dynamicParts.add(
        L.pick(
          en: '【Thinking Mode】Before replying, show your inner thought process in <think>...</think> tags (first person), then reply normally.',
          zhTW: '【思考模式】在回覆前，用 <think>...</think> 標籤展示你的內心思考過程（第一人稱），思考完再正常回覆。',
        ),
      );
    }

    // 拆分回覆模式
    if (_splitReply) {
      dynamicParts.add(
        L.pick(
          en: '【Split Reply Mode】Reply using speech only — no action descriptions, no narration, no *asterisk actions*. Use line breaks between separate thoughts. Keep each paragraph concise.',
          zhTW: '【拆分回覆模式】只用說話內容回覆，不要使用動作描述、旁白敘事、*星號動作*。不同的話之間用換行分段。每段簡短自然。',
        ),
      );
    }

    final structured = StructuredPrompt(
      staticPart: staticBundle.staticPart,
      profilePart: staticBundle.profilePart,
      dynamicPart: dynamicParts.join('\n\n'),
    );

    if (mounted) {
      setState(() {
        _setGenerating(true);
        _streamingText = '';
      });
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    try {
      final adapter = await ApiSettings.buildAdapter();

      // 構建歷史消息（文字部分）
      // ═══ 歷史圖片降級：只有最新一張真實上傳 ═══
      // 舊版每輪把全部歷史圖片重新 base64 上傳，
      // token 成本隨圖片數量線性暴漲（一張圖 ≈ 上千 tokens × 每輪）。
      // 更早的圖片降級為文字佔位，內容靠記憶系統承接。
      final filtered = workingMessages
          .where((m) => m.text.isNotEmpty || m.imagePath != null)
          .toList();
      int lastImageIdx = -1;
      for (int i = filtered.length - 1; i >= 0; i--) {
        if (filtered[i].imagePath != null) {
          lastImageIdx = i;
          break;
        }
      }
      var history = <Map<String, dynamic>>[];
      for (int i = 0; i < filtered.length; i++) {
        final m = filtered[i];
        final degraded = m.imagePath != null && i != lastImageIdx;
        history.add(<String, dynamic>{
          'role': m.isUser ? 'user' : 'assistant',
          'content': degraded
              ? '（這裡曾發送一張圖片${m.text.isNotEmpty ? '：${m.text}' : ''}）'
              : (m.text.isNotEmpty ? m.text : '（圖片）'),
          if (m.imagePath != null && i == lastImageIdx)
            'imagePath': m.imagePath,
        });
      }

      // ═══ B4 滯後截斷（保護前綴緩存）═══
      final keepFrom2 = await _hysteresisKeepFrom(
        history.map((m) => (m['content'] ?? '').toString()).toList(),
      );
      if (keepFrom2 > 0 && keepFrom2 < history.length) {
        var start2 = keepFrom2;
        history = history.sublist(keepFrom2);
        while (history.length > 1 && history.first['role'] != 'user') {
          history.removeAt(0);
          start2++;
        }
        // 砍頭點同步窗口錨點（同 text path）
        final anchorMsgId2 = start2 < filtered.length
            ? filtered[start2].id
            : null;
        if (anchorMsgId2 != null) {
          unawaited(_persistContextAnchor(anchorMsgId2));
        }
      }

      // 轉換為 API 格式（含 base64 圖片）
      final apiMessages = <Map<String, String>>[];
      for (final m in history) {
        final role = m['role'] as String;
        final content = m['content'] as String;
        final imgPath = m['imagePath'] as String?;

        if (imgPath != null && role == 'user') {
          final dataUrl = await ImageService.toBase64DataUrl(imgPath);
          if (dataUrl != null) {
            // 用特殊標記讓 adapter 識別多模態
            apiMessages.add({
              'role': role,
              'content': content,
              'image_data_url': dataUrl,
            });
            continue;
          }
        }
        apiMessages.add({'role': role, 'content': content});
      }

      final rawReply = StringBuffer();
      await for (final chunk in adapter.sendMessageStream(
        messages: apiMessages,
        model: model,
        structuredPrompt: structured,
      )) {
        if (!_isCurrentGeneration(generationSerial)) return;
        rawReply.write(chunk);
        if (mounted) _onStreamChunk(chunk);
      }
      final replyText = rawReply.toString();
      if (!_isCurrentGeneration(generationSerial)) return;

      // ═══ 記錄真實 API 用量 ═══
      final imgProvider = await ApiSettings.getApiProvider();
      await _tokenTracker.recordRealUsage(
        provider: imgProvider,
        model: model,
        characterId: _activeCharacterId,
      );

      final imgCacheRead = _cacheReadForProvider(imgProvider);

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = imgMemoryWriteEnabled
          ? await MemoryActions.processReply(
              replyText,
              characterId: _activeCharacterId,
              mode: await _memoryBucket(),
              windowId: widget.conversationId,
            )
          : MemoryActions.stripReply(
              replyText,
              windowId: widget.conversationId,
            );
      // ═══ 蛛網專屬標籤：<memo_link> 與 <force_recall> 處理 ═══
      if (isSpiderWebEnabledImg) {
        processedText = await SpiderWebCore.processReply(
          processedText,
          characterId: _activeCharacterId,
          windowId: widget.conversationId,
        );
      }
      processedText = await ShopService.processReply(
        processedText,
        characterName: _characterName,
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
      );
      // ═══ 情緒座標：<emo> 打點入庫並剝離 ═══
      // 同輪有 <memo> 時，點綁定那條記憶（同一輪 = 同一情緒時刻），
      // 翻舊帳由此能撈回「點 + 原記憶」
      processedText = await EmotionCoordinates.processReply(
        processedText,
        characterId: _activeCharacterId,
        memoryId: MemoryActions.lastInsertedMemoryIdFor(widget.conversationId),
      );
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      processedText = await BioClockService.processReply(
        processedText,
        characterId: _activeCharacterId,
      );
      // ═══ 角色生活化：<life_fix> 處理 + 關鍵詞掃描 ═══
      processedText = await CharacterTimelineService.processLifeFix(
        _activeCharacterId,
        processedText,
      );
      await CharacterTimelineService.scanReply(
        _activeCharacterId,
        processedText,
      );
      await BioClockService.recordLastChatTime(_activeCharacterId);
      _isFirstRoundInWindow = false;
      // ═══ 便箋：<home> 標籤處理（存入 sticky_notes）═══
      final homeMatch = RegExp(
        r'<home>([\s\S]*?)</home>',
      ).firstMatch(processedText);
      if (homeMatch != null) {
        var homeText = homeMatch.group(1)!.trim();
        if (homeText.length > 12) homeText = homeText.substring(0, 12);
        await DatabaseHelper.addNote(homeText, characterId: _activeCharacterId);
        processedText = processedText
            .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
            .trim();
      }
      // 圖片路徑無 two-pass：<shop_view/> 僅剝離（下條文字消息她可再逛）
      processedText = processedText.replaceAll(_shopViewTagRe, '').trim();
      // ═══ 刮刮樂：<scratch> 標籤處理（圖片路徑）═══
      ScratchData? pendingScratch;
      final scratchMatch = RegExp(
        r'<scratch\s+who="(\w+)"\s*/>',
      ).firstMatch(processedText);
      if (scratchMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<scratch\s+[^>]*/>'), '')
            .trim();
        final who = scratchMatch.group(1) ?? 'char';
        // AI 觸發 → 扣角色的幣
        final ok = await ScratchService.spend(
          _activeCharacterId,
          ScratchService.ticketCost,
        );
        if (ok) {
          pendingScratch = ScratchData(
            cost: ScratchService.ticketCost,
            who: who,
            prizes: ScratchService.rollPrizes(),
            scratched: false,
          );
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(
                    en: '$_characterName does not have enough shells to send a scratch card.',
                    zhTW: '【$_characterName】貝殼不足，無法送出刮刮樂',
                  ),
                ),
                backgroundColor: YanciTheme.accent,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
      // ═══ 轉帳：<transfer> 標籤處理（圖片路徑）═══
      TransferData? pendingTransfer;
      final transferMatch = RegExp(
        r'<transfer\s+amount="(\d+)"\s*/>',
      ).firstMatch(processedText);
      if (transferMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer\s+[^>]*/>'), '')
            .trim();
        final amount = int.tryParse(transferMatch.group(1) ?? '') ?? 0;
        if (amount > 0) {
          pendingTransfer = TransferData(amount: amount, direction: 'toUser');
        }
      }
      // ═══ 轉帳回應（圖片路徑）═══
      final hasAcceptImg = RegExp(
        r'<transfer_accept\s*/>',
      ).hasMatch(processedText);
      final hasDeclineImg = RegExp(
        r'<transfer_decline\s*/>',
      ).hasMatch(processedText);
      if (hasAcceptImg || hasDeclineImg) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer_accept\s*/>'), '')
            .replaceAll(RegExp(r'<transfer_decline\s*/>'), '')
            .trim();
        final pendingKey = _findPendingToCharTransfer();
        if (pendingKey != null) {
          if (hasAcceptImg) {
            final accepted = await TransferService.acceptTransfer(
              pendingKey,
              _activeCharacterId,
            );
            if (accepted) _walletChanged = true;
          } else {
            await TransferService.declineTransfer(pendingKey);
          }
          final updated = await TransferService.getData(pendingKey);
          if (updated != null) _transferDataMap[pendingKey] = updated;
        }
      }
      // ═══ 結婚證簽署：<sign_marriage/>（text/image 雙路徑同款）═══
      if (_signMarriageRe.hasMatch(processedText)) {
        processedText = processedText.replaceAll(_signMarriageRe, '').trim();
        await MarriageService.sign(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 結婚證主動遞出：<propose_marriage/> → 她的消息尾掛可簽證書 ═══
      if (_proposeMarriageRe.hasMatch(processedText)) {
        processedText = processedText.replaceAll(_proposeMarriageRe, '').trim();
        processedText = '$processedText\n$_marriageCertCharTag';
        await MarriageService.markCharProposed(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 模型發起通話：<call>開場白</call> / <call/> ═══
      String? pendingCallOpening;
      final callMatch = RegExp(
        r'<call>([\s\S]*?)</call>|<call\s*/>',
      ).firstMatch(processedText);
      if (callMatch != null) {
        pendingCallOpening = (callMatch.group(1) ?? '').trim();
        processedText = processedText
            .replaceAll(RegExp(r'<call>[\s\S]*?</call>'), '')
            .replaceAll(RegExp(r'<call\s*/>'), '')
            .trim();
      }
      // ═══ 模型畫畫：先出字後出圖（圖在後台生成，好了自己掛上）═══
      String? drawPrompt;
      final drawMatch = RegExp(
        r'<draw>([\s\S]*?)</draw>',
      ).firstMatch(processedText);
      if (drawMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
            .trim();
        drawPrompt = drawMatch.group(1)!.trim();
      }

      processedText = _extractXPostAndStrip(processedText);

      // ═══ 記憶過程日誌：只記寫入本地的操作 ═══
      // （注入給模型的內容不顯示——那是給她看的，不是給你看的）
      final memLogLines = <String>[
        ...MemoryActions.lastActionLogFor(widget.conversationId),
        ...EmotionCoordinates.lastPointLog,
        ...BioClockService.lastActionLog,
        if (drawPrompt != null) '🎨 生成中…',
      ];
      final memLog = memLogLines.isEmpty
          ? ''
          : '${memLogLines.join('\n')}\nDone';
      if (!_isCurrentGeneration(generationSerial)) return;
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: imgCacheRead > 0,
        memoryLog: memLog,
      );
      final imgAiId = await DatabaseHelper.insertMessage(aiMsg);
      unawaited(
        MarriageService.scanMessage(
          aiMsg.text,
          _activeCharacterId,
        ).then((_) => _refreshMarriageState()),
      );
      final aiMsgWithId = Message(
        id: imgAiId,
        conversationId: aiMsg.conversationId,
        characterId: aiMsg.characterId,
        text: aiMsg.text,
        isUser: false,
        splitMode: aiMsg.splitMode,
        cacheHit: aiMsg.cacheHit,
        createdAt: aiMsg.createdAt,
        imagePath: aiMsg.imagePath,
        memoryLog: aiMsg.memoryLog,
      );

      if (imgCacheRead > 0 && mounted) {
        _cacheHitIndices.add(_messages.length);
      }

      if (mounted) {
        setState(() {
          _messages.add(aiMsgWithId);
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _clearStreamQueue();
        _setGenerating(false);
      }
      if (drawPrompt != null && aiMsgWithId.id != null) {
        _runDrawAsync(aiMsgWithId.id!, drawPrompt, memLog);
      }

      // ═══ 商店：消費本輪 <buy> 結果（送禮系統訊息即時上屏 + 失敗提示）═══
      await _consumeBuyResults(widget.conversationId);

      // ═══ X 發文：確認卡 → 發送 ═══
      await _handleXPost();

      // ═══ 模型來電：停 2.5 秒再響鈴（像她想了想才撥）═══
      if (pendingCallOpening != null) {
        _scheduleIncomingCall(pendingCallOpening);
      }

      // ═══ 刮刮樂：存數據 + 彈出刮卡（圖片路徑）═══
      if (pendingScratch != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await ScratchService.saveData(msgId, pendingScratch);
        _scratchDataMap[msgId] = pendingScratch;
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            showScratchDialog(
              context,
              messageId: msgId,
              data: pendingScratch!,
              characterId: _activeCharacterId,
            ).then((_) async {
              final updated = await ScratchService.getData(msgId);
              if (updated != null) _scratchDataMap[msgId] = updated;
              if (mounted) setState(() {});
            });
          });
        }
      }

      // ═══ 轉帳：存數據（圖片路徑）═══
      if (pendingTransfer != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await TransferService.saveData(msgId, pendingTransfer);
        _transferDataMap[msgId] = pendingTransfer;
        if (mounted) setState(() {});
      }

      await _recordCompletedRound(
        conversationId: conversationId,
        userText: outboundCaption.isNotEmpty ? outboundCaption : '（圖片）',
        assistantText: aiMsgWithId.text,
        heartbeatHistory: apiMessages,
        structuredPrompt: structured,
        adapter: adapter,
        model: model,
        provider: imgProvider,
      );
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final errorMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: '出錯了：${e.toString()}',
        isUser: false,
        splitMode: _splitReply,
      );
      final errorId = await DatabaseHelper.insertMessage(errorMsg);
      final savedErrorMsg = Message(
        id: errorId,
        conversationId: errorMsg.conversationId,
        characterId: errorMsg.characterId,
        text: errorMsg.text,
        isUser: errorMsg.isUser,
        splitMode: errorMsg.splitMode,
        createdAt: errorMsg.createdAt,
      );
      if (mounted) {
        setState(() {
          _messages.add(savedErrorMsg);
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _clearStreamQueue();
        _setGenerating(false);
      }
    }
    if (mounted) _scrollToBottom();
  }

  /// 表情包選擇器
  void _showStickerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: YanciTheme.isDark
          ? const Color(0xFF1A1520)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FutureBuilder<List<StickerInfo>>(
        future: StickerService.getUserStickers(),
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return SizedBox(
              height: 200,
              child: Center(
                child: Text(
                  L.get('sticker_empty'),
                  style: TextStyle(
                    fontSize: 13,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            );
          }
          final stickers = snap.data!;
          return Container(
            height: 280,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L.get('sticker_pick'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: stickers.length,
                    itemBuilder: (_, i) {
                      final s = stickers[i];
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          // 標籤制：選表情包後掛在輸入欄上方，
                          // 等用戶打完文字按發送一起出去
                          setState(() => _pendingSticker = s);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(s.filePath),
                            cacheWidth: 128,
                            cacheHeight: 128,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                            errorBuilder: (_, _, _) => Container(
                              color: YanciTheme.glassInputBg,
                              child: const Icon(Icons.broken_image, size: 20),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 構建用戶檔案 prompt
  Future<String> _buildUserProfilePrompt() async {
    final nickname = await UserSettings.getUserName();
    final pronouns = await UserSettings.getUserPronouns();
    final bio = await UserSettings.getUserBio();
    if (nickname.isEmpty && pronouns.isEmpty && bio.isEmpty) return '';
    final parts = <String>[];
    if (L.locale == 'en') {
      if (nickname.isNotEmpty) parts.add('Name: $nickname');
      if (pronouns.isNotEmpty) parts.add('Pronouns: $pronouns');
      if (bio.isNotEmpty) parts.add('About: $bio');
      return '【User Profile】${parts.join(', ')}';
    } else {
      if (nickname.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '暱稱：')}$nickname');
      }
      if (pronouns.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '稱謂：')}$pronouns');
      }
      if (bio.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '自我介紹：')}$bio');
      }
      return '${L.pick(en: '', zhTW: '【用戶檔案】')}${parts.join(L.pick(en: '', zhTW: '，'))}';
    }
  }

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
                                cacheWidth: 64,
                                cacheHeight: 64,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.none,
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
                            onStopGeneration: () {
                              setState(() => _isGeneratingImage = false);
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
                    '${L.pick(en: 'Searching', zhTW: '搜尋')}「$query」',
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
                        ? (L.pick(en: 'No results', zhTW: '無結果'))
                        : '${results.length} ${L.pick(en: 'found', zhTW: '條')}',
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
    final hasStreamingBubble = _streamingText.isNotEmpty;
    final showAtom = _isGenerating && _streamingText.isEmpty;

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
              cacheHit:
                  isLast &&
                  !msg.isUser &&
                  (msg.cacheHit || _cacheHitIndices.contains(i)),
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
              return ChatBubble(
                text: item.text,
                isUser: item.isUser,
                timestamp: item.timestamp,
                memoryLog: item.memoryLog,
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

  void _toggleManualSummaryMessage(int messageId) {
    setState(() {
      if (_manualSummarySelectedIds.contains(messageId)) {
        _manualSummarySelectedIds.remove(messageId);
      } else {
        _manualSummarySelectedIds.add(messageId);
      }
    });
  }

  Future<void> _confirmManualSummarySelected() async {
    final selected = _messages
        .where(
          (message) =>
              message.id != null &&
              _manualSummarySelectedIds.contains(message.id),
        )
        .toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Summarize selected messages', zhTW: '摘要選取消息'),
          style: TextStyle(color: YanciTheme.textPrimary),
        ),
        content: Text(
          L.pick(
            en: 'Summarizes the selected user and character messages without changing the original chat.',
            zhTW: '會把已勾選的 user / char 消息打包摘要，不會改動原聊天內容。',
          ),
          style: TextStyle(color: YanciTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Start', zhTW: '開始摘要')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await _runManualSummaryForMessages(selected);
  }

  Future<void> _runManualSummaryForMessages(List<Message> messages) async {
    setState(() => _manualSummaryRunning = true);
    final conv = await DatabaseHelper.getConversation(widget.conversationId);
    final characterId = conv?.characterId ?? _activeCharacterId;
    try {
      await ManualSummaryService.summarizeMessages(
        conversationId: widget.conversationId,
        characterId: characterId,
        messages: messages,
      );
      if (!mounted) return;
      setState(() {
        _manualSummarySelecting = false;
        _manualSummarySelectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'Manual summary completed.', zhTW: '手動摘要已完成。'),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: YanciTheme.accent,
        ),
      );
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      _showManualSummaryFailureSnack(
        excerpt: e.excerpt,
        characterId: characterId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${L.pick(en: 'Summary failed', zhTW: '摘要失敗')}：$e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: YanciTheme.accent,
        ),
      );
    } finally {
      if (mounted) setState(() => _manualSummaryRunning = false);
    }
  }

  void _showManualSummaryFailureSnack({
    required String excerpt,
    required String characterId,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Summary failed. Please edit it manually.',
            zhTW: '摘要失敗，請手動摘要。',
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
        action: SnackBarAction(
          label: L.pick(en: 'Edit', zhTW: '編輯'),
          textColor: Colors.white,
          onPressed: () => _openManualSummaryCleanPage(
            excerpt: excerpt,
            characterId: characterId,
          ),
        ),
      ),
    );
  }

  Future<void> _openManualSummaryCleanPage({
    required String excerpt,
    required String characterId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ManualSummaryCleanScreen(
          conversationId: widget.conversationId,
          characterId: characterId,
          title: _conversationTitle.isNotEmpty
              ? _conversationTitle
              : _characterName,
          initialExcerpt: excerpt,
        ),
      ),
    );
  }

  /// 編輯消息
  Future<void> _deleteMessagesFrom(
    int index, {
    required bool includeIndex,
  }) async {
    _invalidateGenerationState();
    final start = includeIndex ? index : index + 1;
    if (start < 0 || start >= _messages.length) return;

    final toDelete = _messages.sublist(start);
    for (final m in toDelete) {
      if (m.id != null) {
        final key = 'msg_${m.id}';
        _scratchDataMap.remove(key);
        _transferDataMap.remove(key);
        await DatabaseHelper.deleteMessageById(m.id!);
      } else {
        await DatabaseHelper.deleteMessageByFingerprint(m);
      }
    }
    _cacheHitIndices.clear();
    if (!mounted) return;
    setState(() {
      _messages.removeRange(start, _messages.length);
    });
  }

  /// 編輯發送窗之外的老消息 → 自動開分支對話：
  /// 複製該消息之前的全部前文到新對話，帶著編輯後的文本進新窗自動發送。
  /// 原對話一字不動。
  void _editAsBranch(int dbMessageId) {
    Message? msg;
    for (final m in _olderMessages) {
      if (m.id == dbMessageId) {
        msg = m;
        break;
      }
    }
    if (msg == null) return;
    final branchFromId = msg.id!;
    final ctrl = TextEditingController(text: msg.text);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Edit & branch', zhTW: '編輯並開分支'),
          style: YanciTheme.headingMedium,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              maxLines: null,
              minLines: 2,
              autofocus: true,
              style: YanciTheme.bodyText.copyWith(fontSize: 14),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              L.pick(
                en: 'A new branch conversation will start from here. The original stays untouched.',
                zhTW: '將以這裡為起點開一個新的分支對話，原對話原封不動。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 12,
                color: YanciTheme.textSecondary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('chat_cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final newText = ctrl.text.trim();
              if (newText.isEmpty) return;
              final branchId = await DatabaseHelper.branchConversation(
                sourceConversationId: widget.conversationId,
                beforeMessageId: branchFromId,
                title:
                    '⑂ ${_conversationTitle.isNotEmpty ? _conversationTitle : _characterName}',
              );
              if (!mounted) return;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    conversationId: branchId,
                    initialAutoSendText: newText,
                  ),
                ),
              );
              // 回到原窗：緩存會話歸屬還原（分支窗接管過 CacheSession）
              if (mounted) {
                CacheSession.conversationId = widget.conversationId;
              }
            },
            child: Text(
              L.pick(en: 'Branch', zhTW: '開分支'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _editMessage(int index) {
    final msg = _messages[index];
    final ctrl = TextEditingController(text: msg.text);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(L.get('chat_edit'), style: YanciTheme.headingMedium),
        content: TextField(
          controller: ctrl,
          maxLines: null,
          minLines: 2,
          autofocus: true,
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('chat_cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          // 覆蓋保存：保留這條 user 消息，但清掉它後面的舊回覆/錯誤。
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final newText = ctrl.text.trim();
              if (newText.isEmpty || msg.id == null) return;
              await DatabaseHelper.updateMessageText(msg.id!, newText);
              await _deleteMessagesFrom(index, includeIndex: false);
              if (!mounted) return;
              setState(() {
                _messages[index] = Message(
                  id: msg.id,
                  conversationId: msg.conversationId,
                  characterId: msg.characterId,
                  text: newText,
                  isUser: msg.isUser,
                  imagePath: msg.imagePath,
                  splitMode: msg.splitMode,
                  cacheHit: msg.cacheHit,
                  memoryLog: msg.memoryLog,
                  createdAt: msg.createdAt,
                );
              });
            },
            child: Text(
              L.get('chat_save'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
          // 重新發送（刪後續 + 重新送 AI）
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final newText = ctrl.text.trim();
              if (newText.isEmpty) return;

              await _deleteMessagesFrom(index, includeIndex: true);
              if (!mounted) return;
              _onSendMessage(newText);
            },
            child: Text(
              L.get('chat_resend'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════ 通話 ═══════════════

  /// 打開通話界面（outgoing = 用戶主動；incoming = 模型 `<call>` 發起）
  Future<void> _openCall({
    bool incoming = false,
    String openingLine = '',
  }) async {
    if (!_isChatReady) return;
    // 通話與聊天共用同一份靜態前綴（_buildCommonStaticParts 同款）——
    // 前綴一致 = 同一個緩存 namespace，接通第一輪就命中聊天已建的緩存。
    // 各快照字段（習慣/自我註記/表情包/背包）走 ??= 初始化，
    // 與聊天窗口天然同一份，不會分叉。構建失敗退回 CallScreen 舊拼法。
    String? callStaticPart;
    String? callProfilePart;
    try {
      final charId = _activeCharacterId;
      final systemPrompt = await ApiSettings.getSystemPrompt();
      final userProfile = await _buildUserProfilePrompt();
      final selfNotes = await DatabaseHelper.getSelfNotes(charId);
      final userNickname = await UserSettings.getUserName();
      final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
      final imagegenEnabled = await MemorySettings.isAbilityEnabled('imagegen');
      final bioclockEnabled = await MemorySettings.isAbilityEnabled('bioclock');
      final memoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();
      final providerName = await ApiSettings.getApiProviderName();
      final conciseOn = await ApiSettings.getConciseMode();
      final freeformOn = await ApiSettings.getFreeformMode();
      final charData = await DatabaseHelper.getCharacter(charId);
      final isSpiderWebEnabled =
          (charData?['is_spider_web_enabled'] as int? ?? 0) == 1;
      final staticWindowSummary = await _buildStaticWindowSummaryPrompt(charId);
      final bundle = await _buildCommonStaticParts(
        characterId: charId,
        systemPrompt: systemPrompt,
        charDesc: charData?['description'] as String? ?? '',
        characterName: charData?['name'] as String? ?? '',
        userProfile: userProfile,
        selfNotes: selfNotes,
        userNickname: userNickname,
        isSpiderWebEnabled: isSpiderWebEnabled,
        memoryWriteEnabled: memoryWriteEnabled,
        emotionEnabled: emotionEnabled,
        bioclockEnabled: bioclockEnabled,
        imagegenEnabled: imagegenEnabled,
        providerName: providerName,
        conciseOn: conciseOn,
        freeformOn: freeformOn,
        staticWindowSummary: staticWindowSummary,
      );
      callStaticPart = bundle.staticPart;
      callProfilePart = bundle.profilePart;
    } catch (e) {
      debugPrint('通話靜態前綴構建失敗，退回舊前綴: $e');
    }
    if (!mounted) return;
    final result = await Navigator.push<CallResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          characterName: _characterName.isEmpty
              ? L.pick(en: 'Character', zhTW: '角色')
              : _characterName,
          conversationId: widget.conversationId,
          incoming: incoming,
          openingLine: openingLine,
          cacheStaticSnapshot: _cacheWindowSummaryStaticSnapshot,
          staticPart: callStaticPart,
          profilePart: callProfilePart,
        ),
      ),
    );
    await _loadMessages();
    if (result != null) await _handleCallResult(result, incoming: incoming);
  }

  /// 模型來電：延遲 2.5s 響鈴
  void _scheduleIncomingCall(String openingLine) {
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      _openCall(incoming: true, openingLine: openingLine);
    });
  }

  /// 通話結果 → 隱藏事件注入（模型可見、氣泡不顯示）
  /// 拒接 → 立刻觸發她的反應；正常掛斷/未接/信號中斷 → 靜默入庫，下次她自然知道
  Future<void> _handleCallResult(
    CallResult result, {
    required bool incoming,
  }) async {
    String? eventText;
    switch (result.event) {
      case 'declined':
        // 方向分開：她打來你拒 = declined（她讀到「對方掛了你的電話」）；
        // 你打去她拒 = declined_by_you（她讀到「你拒接了對方的電話」）——
        // 混用一個標記時她自己拒的那條語義是反的
        // declined_by_you 語義隨事件動態帶上（偶發，不進靜態工具區）
        eventText = incoming
            ? '[call_event:declined]'
            : '[call_event:declined_by_you]'
                  '（系統說明：你剛拒接了對方打來的電話，對方看得到你拒接了；'
                  '想的話可以用文字補一句為什麼沒接。這段說明對方看不到）';
        break;
      case 'missed':
        eventText = '[call_event:missed]';
        break;
      case 'ended':
        final m = result.duration.inMinutes.toString().padLeft(2, '0');
        final s = (result.duration.inSeconds % 60).toString().padLeft(2, '0');
        // 沒說上話就掛 = 也算掛她電話
        if (incoming && !result.anyExchange) {
          eventText = '[call_event:declined]';
        } else {
          eventText = '[call_event:ended $m:$s]';
        }
        break;
      case 'signal_lost':
        final m = result.duration.inMinutes.toString().padLeft(2, '0');
        final s = (result.duration.inSeconds % 60).toString().padLeft(2, '0');
        eventText = '[call_event:signal_lost $m:$s]';
        break;
    }
    if (eventText == null) return;

    if (eventText.startsWith('[call_event:declined')) {
      // 拒接（不論哪邊拒的）→ 她立刻有反應：
      // 你拒她 = 她對被掛反應；她拒你 = 她補一句文字說明為什麼沒接
      await _onSendMessage(eventText);
    } else {
      // 靜默入庫：進歷史（她下次說話時知道），不觸發回覆
      final msg = Message(
        conversationId: widget.conversationId,
        characterId: _activeCharacterId,
        text: eventText,
        isUser: true,
      );
      final id = await DatabaseHelper.insertMessage(msg);
      if (mounted) {
        setState(() {
          _messages.add(
            Message(
              id: id,
              conversationId: msg.conversationId,
              characterId: msg.characterId,
              text: msg.text,
              isUser: true,
              createdAt: msg.createdAt,
            ),
          );
        });
      }
    }
  }

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
                  // ═══ 開新窗口 ═══
                  GestureDetector(
                    onTap: !_isChatReady
                        ? null
                        : () async {
                            final convId = DateTime.now().millisecondsSinceEpoch
                                .toString();
                            final conv = Conversation(
                              id: convId,
                              characterId: _activeCharacterId,
                            );
                            await DatabaseHelper.createConversation(conv);
                            // V2：開新窗口 → 慾望 ÷2
                            await EmotionCoordinates.onNewWindow(
                              _activeCharacterId,
                            );
                            if (mounted) {
                              Navigator.of(context).pushReplacementNamed(
                                '/chat',
                                arguments: convId,
                              );
                            }
                          },
                    child: Icon(
                      Icons.add_circle_outline_rounded,
                      size: 22,
                      color: YanciTheme.accent.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(width: 8),
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
      return '📱 ${info != null ? L.pick(en: info.nameEn, zhTW: info.name) : LocalModelService.fallbackDisplayNameForKey(key)}';
    }
    if (ApiSettings.isLocalApiModelId(model)) {
      return '🖥 ${ApiSettings.extractLocalApiModel(model)}';
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

  String _providerForStarredModel(String modelId) {
    if (ApiSettings.isLocalApiModelId(modelId)) return 'local_api';
    if (LocalModelService.isLocalModelId(modelId)) return 'local';
    return 'openrouter';
  }

  void _showNonBlockingModelHint(String message) {
    _modelHintOverlay?.remove();
    _modelHintOverlay = null;

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (ctx) {
        final top = MediaQuery.of(ctx).padding.top + 12;
        return Positioned(
          top: top,
          left: 16,
          right: 16,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? const Color(0xF02B2430)
                        : Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    border: Border.all(
                      color: YanciTheme.glassBorder,
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: 12,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _modelHintOverlay = entry;
    Future.delayed(const Duration(milliseconds: 2600), () {
      if (_modelHintOverlay == entry) {
        _modelHintOverlay?.remove();
        _modelHintOverlay = null;
      }
    });
  }

  /// 星標模型快速切換
  void _showModelPicker() async {
    final starred = await ApiSettings.getStarredModels();
    if (!mounted) return;

    if (starred.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.get('chat_api_star_hint')),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
      return;
    }

    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierDismissible: true,
      barrierLabel: 'ModelPicker',
      transitionDuration: const Duration(milliseconds: 350),
      transitionBuilder: (context, anim1, anim2, child) {
        return ScaleTransition(
          alignment: Alignment.topCenter,
          scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
          child: FadeTransition(opacity: anim1, child: child),
        );
      },
      pageBuilder: (ctx, anim1, anim2) {
        final height = MediaQuery.of(ctx).size.height;
        final width = MediaQuery.of(ctx).size.width;
        bool? localThinking;

        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: width * (2 / 3),
                  constraints: BoxConstraints(maxHeight: height * 0.5),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? const Color(0xF0252228)
                        : Colors.white.withValues(alpha: 0.97),
                    borderRadius: BorderRadius.circular(YanciTheme.radiusLg),
                    border: Border.all(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.1),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: StatefulBuilder(
                    builder: (ctx, setDialogState) {
                      return FutureBuilder<bool>(
                        future: ApiSettings.getThinkingChain(),
                        builder: (ctx, snap) {
                          final currentThinking =
                              localThinking ?? snap.data ?? false;
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 思考鏈開關
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () async {
                                    final newVal = !currentThinking;
                                    setDialogState(
                                      () => localThinking = newVal,
                                    );
                                    await ApiSettings.saveThinkingChain(newVal);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          L.pick(
                                            en: 'Thinking Chain',
                                            zhTW: '思考鏈',
                                          ),
                                          style: YanciTheme.bodyText.copyWith(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Transform.scale(
                                          scale: 0.85,
                                          child: Switch(
                                            value: currentThinking,
                                            activeThumbColor: YanciTheme.accent,
                                            activeTrackColor: YanciTheme.accent
                                                .withValues(alpha: 0.3),
                                            onChanged: (val) async {
                                              setDialogState(
                                                () => localThinking = val,
                                              );
                                              await ApiSettings.saveThinkingChain(
                                                val,
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Divider(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.2,
                                  ),
                                  height: 1,
                                ),
                                const SizedBox(height: 12),
                                // 模型列表
                                Flexible(
                                  child: ListView(
                                    shrinkWrap: true,
                                    padding: EdgeInsets.zero,
                                    children: starred.map((modelId) {
                                      final isActive = modelId == _currentModel;
                                      final displayName = _fullModelName(
                                        modelId,
                                      );
                                      return GestureDetector(
                                        onTap: () async {
                                          final provider =
                                              _providerForStarredModel(modelId);
                                          await ApiSettings.saveModel(modelId);
                                          if (provider == 'local_api') {
                                            await ApiSettings.saveApiProvider(
                                              'local_api',
                                            );
                                          } else if (provider == 'openrouter') {
                                            await ApiSettings.saveApiProvider(
                                              'openrouter',
                                            );
                                          }
                                          final supportsRenewal =
                                              TokenEstimator.supportsCloseWindowKeepAlive(
                                                provider: provider,
                                                model: modelId,
                                              );
                                          if (!supportsRenewal) {
                                            await MemorySettings.saveKeepAliveEnabled(
                                              false,
                                            );
                                          }
                                          if (!mounted) return;
                                          setState(
                                            () => _currentModel = modelId,
                                          );
                                          if (ctx.mounted) Navigator.pop(ctx);
                                          if (!supportsRenewal) {
                                            _showNonBlockingModelHint(
                                              L.pick(
                                                en: 'This model has no confirmed 1h cache TTL, so auto cache renewal stays off.',
                                                zhTW: L.pick(
                                                  en: 'This model has no confirmed one-hour cache TTL, so automatic renewal remains off.',
                                                  zhTW:
                                                      '此模型沒有已確認的 1 小時緩存 TTL，自動延續命中已保持關閉。',
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                        child: Container(
                                          width: double.infinity,
                                          margin: const EdgeInsets.only(
                                            bottom: 6,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isActive
                                                ? YanciTheme.accent.withValues(
                                                    alpha: 0.12,
                                                  )
                                                : Colors.transparent,
                                            borderRadius: BorderRadius.circular(
                                              YanciTheme.radiusSm,
                                            ),
                                            border: isActive
                                                ? Border.all(
                                                    color: YanciTheme.accent
                                                        .withValues(alpha: 0.3),
                                                  )
                                                : null,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.star_rounded,
                                                size: 14,
                                                color: YanciTheme.accent
                                                    .withValues(alpha: 0.6),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: _MarqueeText(
                                                  text: displayName,
                                                  style: YanciTheme.bodyText
                                                      .copyWith(
                                                        fontSize: 13,
                                                        color: isActive
                                                            ? YanciTheme.accent
                                                            : YanciTheme
                                                                  .textPrimary,
                                                      ),
                                                ),
                                              ),
                                              if (isActive)
                                                Icon(
                                                  Icons.check_rounded,
                                                  size: 16,
                                                  color: YanciTheme.accent,
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// AI 自動命名（異步，不阻塞聊天）
  Future<void> _autoNameConversation(
    String userText,
    String aiText, {
    String? conversationId,
  }) async {
    try {
      final convId = conversationId ?? widget.conversationId;
      final adapter = await ApiSettings.buildAdapter();
      final model = await ApiSettings.getModel();

      final response = await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content':
                '${L.pick(en: 'User: ', zhTW: '用戶：')}$userText\n${L.pick(en: 'Character: ', zhTW: '角色：')}${aiText.length > 100 ? aiText.substring(0, 100) : aiText}',
          },
        ],
        model: model,
        systemPrompt: L.pick(
          en: 'Summarize the topic of this conversation as a short 3–8 word title. Output only the title, with no punctuation, quotation marks, or explanation.',
          zhTW: '用6-10個字總結這段對話的主題，作為對話標題。只輸出標題文字，不加標點、引號或解釋。',
        ),
      );

      final title = response.trim().replaceAll(
        RegExp(
          r'[「」""'
          '".]',
        ),
        '',
      );
      if (title.isNotEmpty && title.length <= 20) {
        await DatabaseHelper.updateConversation(convId, title: title);
        if (!mounted) return;
        setState(() => _conversationTitle = title);
      }
    } catch (_) {
      // 命名失敗不影響聊天
    }
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

  (String, Color)? _getCacheDisplay(String provider) {
    switch (provider) {
      case 'openrouter':
        final stats = OpenRouterService.lastCacheStats;
        if (stats.isEmpty) return null;
        final read = stats['cache_read'] ?? 0;
        final created = stats['cache_creation'] ?? 0;
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
        final stats = DeepSeekService.lastCacheStats;
        if (stats.isEmpty) return null;
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
        final stats = GeminiService.lastCacheStats;
        if (stats.isEmpty) return null;
        final cached = stats['cached_tokens'] ?? 0;
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
        final stats = BedrockService.lastCacheStats;
        if (stats.isEmpty) return null;
        final read = stats['cache_read'] ?? 0;
        final created = stats['cache_creation'] ?? 0;
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

  int _cacheReadForProvider(String provider) {
    switch (provider) {
      case 'openrouter':
        return OpenRouterService.lastCacheStats['cache_read'] ?? 0;
      case 'deepseek':
        return DeepSeekService.lastCacheStats['cache_hit'] ?? 0;
      case 'gemini':
        return GeminiService.lastCacheStats['cached_tokens'] ?? 0;
      case 'bedrock':
        return BedrockService.lastCacheStats['cache_read'] ?? 0;
      default:
        return 0;
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
  final String memoryLog;

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
    this.showToolbar = true,
    this.cacheHit = false,
    this.callDivider,
    this.callDividerIcon,
    this.giftName,
    this.giftAccepted = false,
    this.hasMarriageCert = false,
    this.certFromChar = false,
  });
}

/// 文字過長時慢速水平滾動，短文字靜態顯示
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollCtrl;
  AnimationController? _animCtrl;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  void _checkOverflow() {
    if (!mounted) return;
    if (_scrollCtrl.hasClients && _scrollCtrl.position.maxScrollExtent > 0) {
      setState(() => _needsScroll = true);
      _startScrolling();
    }
  }

  void _startScrolling() {
    _animCtrl?.dispose();
    final extent = _scrollCtrl.position.maxScrollExtent;
    // 每秒滾動 20 像素（慢速）
    final durationMs = (extent / 20 * 1000).round().clamp(2000, 15000);
    _animCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: durationMs),
    );
    _animCtrl!.addListener(() {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(
          _animCtrl!.value * _scrollCtrl.position.maxScrollExtent,
        );
      }
    });
    // 來回滾動
    _animCtrl!.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _animCtrl?.stop();
      _needsScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  @override
  void dispose() {
    _animCtrl?.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollCtrl,
      scrollDirection: Axis.horizontal,
      physics: _needsScroll
          ? const NeverScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
