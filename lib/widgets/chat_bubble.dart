import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gal/gal.dart';
import '../theme/app_theme.dart';
import '../services/sticker_service.dart';
import '../services/locale_strings.dart';
import '../services/tts_service.dart';
import '../services/api_adapter.dart';
import '../services/settings_manager.dart';
import '../services/memory_guard_service.dart';
import '../memory/database.dart';
import '../models/memory_action_proposal.dart';
import '../models/web_search_trace.dart';
import '../models/background_preset.dart';
import '../services/scratch_service.dart';
import '../services/transfer_service.dart';
import '../services/marriage_service.dart';
import 'gift_card.dart';
import 'marriage_cert_card.dart';
import 'scratch_card.dart';
import 'transfer_card.dart';
import 'tts_play_button.dart';
import 'sticker_preview_quality.dart';
import 'bubble_action_glyph.dart';
import 'chat_avatar.dart';
import 'web_search_thinking_node.dart';
import 'thinking_detail_sheet.dart';
import 'thinking_context_widgets.dart';
import 'themed_notice.dart';
import 'gradient_background.dart';
import 'message_image_grid.dart';
import '../utils/thinking_blocks.dart';

/// 聊天氣泡 — 思考鏈 + markdown + 表情包圖片 + 長按菜單
class ChatBubble extends StatefulWidget {
  final String text;
  final bool isUser;
  final bool isStreaming;
  final DateTime? timestamp;
  final VoidCallback? onEdit;
  final String? messageId;
  final String? imagePath;
  final List<String> imagePaths;
  final String? conversationId;
  final String? conversationTitle;
  final String? characterId;
  final String? avatarPath;
  final bool showAvatar;
  final bool showAvatarImage;
  final bool groupedWithPrevious;
  final bool groupedWithNext;
  final bool tightGroupWithPrevious;
  final bool tightGroupWithNext;
  final bool showToolbar;
  final String? toolbarText;
  final String? toolbarMessageId;
  final bool cacheHit;
  final bool incomplete;
  final VoidCallback? onRetryIncomplete;
  final bool selectable;
  final bool selected;
  final VoidCallback? onSelectionToggle;
  final bool captureMode;

  /// Whether this widget should play the message entrance animation.
  /// Persisted assistant messages have already animated on the streaming
  /// surface, so replaying here would briefly make completed text invisible.
  final bool animateEntry;

  /// Smoothly reveals metadata that only becomes available after the streamed
  /// reply is parsed and persisted. Historical messages render immediately.
  final bool animateContextReveal;
  final bool forceThemeBubbleColors;
  final bool? thinkingExpandedOverride;
  final bool includeThinkingDetails;
  final bool includeMemoryDetails;
  final bool includeEmotionDetails;
  final int pendingMemoryActionCount;
  final bool hasUnreadMemoryActions;
  final VoidCallback? onMemoryReviewTap;
  final List<MemoryActionProposal> pendingMemoryProposals;
  final Future<void> Function(MemoryActionProposal proposal, String decision)?
  onInlineMemoryProposal;
  final WebSearchDisplayTrace? webSearchTrace;

  /// 記憶過程日誌（注入/寫入/刪除/合併，Done 收尾），空則不顯示
  final String memoryLog;

  /// 刮刮樂數據（非 null 時在氣泡下方顯示迷你卡片）
  final ScratchData? scratchData;

  /// 轉帳數據（非 null 時在氣泡下方顯示轉帳卡片）
  final TransferData? transferData;
  final VoidCallback? onTransferUpdated;

  /// 禮物名稱（非 null 時在氣泡下方顯示禮物卡片）
  final String? giftName;

  /// 對方已回覆 → 禮物卡片顯示「已收下」
  final bool giftAccepted;

  /// 角色從商店送給 user；顯示「已收到」而不是「禮物已送出」。
  final bool giftReceivedFromCharacter;

  /// 結婚證書（非 null 時在氣泡下方顯示證書卡）
  final MarriageCertDisplay? marriageCert;

  /// 她遞的證書未簽時，點擊卡片簽署
  final VoidCallback? onCertSignTap;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.isStreaming = false,
    this.timestamp,
    this.onEdit,
    this.messageId,
    this.imagePath,
    this.imagePaths = const <String>[],
    this.conversationId,
    this.conversationTitle,
    this.characterId,
    this.avatarPath,
    this.showAvatar = false,
    this.showAvatarImage = true,
    this.groupedWithPrevious = false,
    this.groupedWithNext = false,
    this.tightGroupWithPrevious = false,
    this.tightGroupWithNext = false,
    this.showToolbar = true,
    this.toolbarText,
    this.toolbarMessageId,
    this.cacheHit = false,
    this.incomplete = false,
    this.onRetryIncomplete,
    this.selectable = false,
    this.selected = false,
    this.onSelectionToggle,
    this.captureMode = false,
    this.animateEntry = true,
    this.animateContextReveal = false,
    this.forceThemeBubbleColors = false,
    this.thinkingExpandedOverride,
    this.includeThinkingDetails = true,
    this.includeMemoryDetails = true,
    this.includeEmotionDetails = true,
    this.pendingMemoryActionCount = 0,
    this.hasUnreadMemoryActions = false,
    this.onMemoryReviewTap,
    this.pendingMemoryProposals = const [],
    this.onInlineMemoryProposal,
    this.webSearchTrace,
    this.memoryLog = '',
    this.scratchData,
    this.transferData,
    this.onTransferUpdated,
    this.giftName,
    this.giftAccepted = false,
    this.giftReceivedFromCharacter = false,
    this.marriageCert,
    this.onCertSignTap,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with SingleTickerProviderStateMixin {
  static String? _checkedChatBackgroundPath;
  static bool _checkedChatBackgroundExists = false;
  BackgroundPreset? _scopedBackgroundPreset;
  ChatBackgroundPresetScope? _chatBackgroundScope;

  bool _thinkingExpanded = false;
  bool _memLogExpanded = false;
  final ThinkingSheetCoordinator _thinkingSheet = ThinkingSheetCoordinator();
  String? _inlineMemoryBusyId;
  bool _isSaved = false;
  late AnimationController _entryCtrl;

  late Animation<double> _bubbleOpacity;
  late Animation<double> _scaleY;
  late Animation<double> _scaleX;
  late Animation<double> _contentOpacity;
  late Animation<double> _avatarOpacity; // 頭像原地漸顯，不參與氣泡縮放
  bool _didStartEntryAnimation = false;
  late bool _contextRevealVisible;
  bool _didScheduleContextReveal = false;

  @override
  void initState() {
    super.initState();
    _contextRevealVisible = !widget.animateContextReveal;
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );

    _bubbleOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.15, curve: Curves.easeOut),
      ),
    );

    _scaleY =
        TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(
              begin: 0.3,
              end: 1.08,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 35,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.08,
              end: 0.96,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 15,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 0.96,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 10,
          ),
        ]).animate(
          CurvedAnimation(parent: _entryCtrl, curve: const Interval(0.0, 0.6)),
        );

    _scaleX =
        TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(
              begin: 0.3,
              end: 0.5,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 30,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 0.5,
              end: 1.03,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 30,
          ),
          TweenSequenceItem(
            tween: Tween(
              begin: 1.03,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 10,
          ),
        ]).animate(
          CurvedAnimation(parent: _entryCtrl, curve: const Interval(0.0, 0.7)),
        );

    _contentOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.55, 0.85, curve: Curves.easeIn),
      ),
    );

    _avatarOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOut),
      ),
    );

    _checkSaved();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didStartEntryAnimation) return;
    _didStartEntryAnimation = true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!widget.animateEntry || widget.captureMode || reduceMotion) {
      _entryCtrl.value = 1;
    } else {
      _entryCtrl.forward();
    }
    if (!_contextRevealVisible && !_didScheduleContextReveal) {
      _didScheduleContextReveal = true;
      if (widget.captureMode || reduceMotion) {
        _contextRevealVisible = true;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _contextRevealVisible = true);
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant ChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    _thinkingSheet.notify();
  }

  Widget _contextReveal(Widget child) {
    final reduceMotion =
        widget.captureMode || MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final visible =
        !widget.animateContextReveal || _contextRevealVisible || reduceMotion;
    return ClipRect(
      child: AnimatedAlign(
        key: const ValueKey('context-reveal-anchor'),
        alignment: Alignment.topLeft,
        heightFactor: visible ? 1 : 0,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: child,
        ),
      ),
    );
  }

  Future<void> _checkSaved() async {
    final messageId = widget.toolbarMessageId ?? widget.messageId;
    if (widget.isUser || messageId == null) return;
    try {
      final saved = await DatabaseHelper.isMessageSaved(messageId);
      if (mounted) setState(() => _isSaved = saved);
    } catch (_) {}
  }

  Future<void> _toggleSave() async {
    final messageId = widget.toolbarMessageId ?? widget.messageId;
    final text = widget.toolbarText ?? widget.text;
    if (messageId == null) return;
    HapticFeedback.lightImpact();
    try {
      if (_isSaved) {
        await DatabaseHelper.unsaveMessage(messageId);
      } else {
        await DatabaseHelper.saveMessage(
          messageId: messageId,
          content: text
              .replaceAll(TtsService.audioTagRe, '')
              .replaceAll(RegExp(r'\[call_event:[^\]]*\]'), '')
              .trim(),
          characterId: widget.characterId ?? 'default',
          conversationId: widget.conversationId,
        );
      }
      if (mounted) setState(() => _isSaved = !_isSaved);
    } catch (e) {
      debugPrint('收藏失敗: $e');
    }
  }

  void _updateContextState(VoidCallback update) {
    setState(update);
    _thinkingSheet.notify();
  }

  ThinkingContextLogParts _contextLogParts() {
    return parseThinkingContextLog(
      widget.memoryLog,
      includeMemory: widget.includeMemoryDetails,
      includeEmotion: widget.includeEmotionDetails,
    );
  }

  @override
  void dispose() {
    _cacheHitPopover?.remove();
    _cacheHitPopover = null;
    _thinkingSheet.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  void _showImageMenu(BuildContext ctx, String imagePath) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(YanciTheme.radiusInput),
          border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.save_alt_rounded,
                  color: YanciTheme.accent,
                  size: 20,
                ),
                title: Text(
                  L.pick(en: 'Save Image', zhTW: '保存圖片'),
                  style: TextStyle(fontSize: 15, color: YanciTheme.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _saveImage(imagePath);
                },
              ),
              const Divider(height: 0.5),
              ListTile(
                leading: Icon(
                  Icons.close_rounded,
                  color: YanciTheme.textSecondary,
                  size: 20,
                ),
                title: Text(
                  L.get('chat_cancel'),
                  style: TextStyle(
                    fontSize: 15,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全屏查看圖片（不壓縮畫質 + 可保存；多圖可左右滑）
  void _openFullScreenImage(
    BuildContext ctx,
    List<String> paths,
    int initialIndex,
  ) {
    if (paths.isEmpty) return;
    Navigator.of(ctx).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (context, anim, secondAnim) => FadeTransition(
          opacity: anim,
          child: ImageGalleryViewer(
            paths: paths,
            initialIndex: initialIndex.clamp(0, paths.length - 1),
            onSave: _saveImage,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  Future<void> _saveImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) throw Exception('文件不存在');

      await Gal.putImage(imagePath);

      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(en: 'Saved to Gallery', zhTW: '已保存到相冊'),
        duration: const Duration(milliseconds: 1500),
      );
    } catch (e) {
      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(en: 'Save failed: $e', zhTW: '保存失敗：$e'),
        tone: ThemedNoticeTone.error,
        duration: const Duration(milliseconds: 2000),
      );
    }
  }

  Future<void> _speakText(String text) async {
    final provider = await TtsSettings.getTtsProvider();
    final model = await TtsSettings.getTtsElevenlabsModel();
    final keepTags =
        provider == 'elevenlabs' &&
        (model == 'eleven_v3' || model == 'eleven_v4');
    final clean = TtsService.extractSpeechContent(
      text,
      keepAudioTags: keepTags,
    );
    if (clean.isEmpty) return;
    TtsService.speak(
      clean,
      // 必須和 TtsPlayButton 監聽的 id 一致：拆分回覆的最後一段
      // messageId 是 msg_X_N、工具列用 msg_X，不一致時有聲音但沒動畫。
      messageId: widget.toolbarMessageId ?? widget.messageId,
      conversationId: widget.conversationId,
      conversationTitle: widget.conversationTitle,
      characterId: widget.characterId,
    );
  }

  (String?, String) _parseThinking(String rawText) {
    final text = collapseRepeatedThinking(rawText);
    final patterns = [
      RegExp(r'<think>(.*?)</think>', dotAll: true),
      RegExp(r'<thinking>(.*?)</thinking>', dotAll: true),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final t = m.group(1)?.trim() ?? '';
        return (t.isEmpty ? null : t, text.replaceFirst(p, '').trim());
      }
    }
    // 開標籤存在但未閉合：可能仍在串流，也可能是模型在
    // token 上限處正常結束。任何情況都不應把 <think> 原始標籤顯示為正文。
    for (final tag in ['<think>', '<thinking>']) {
      final idx = text.indexOf(tag);
      if (idx >= 0) {
        final before = text.substring(0, idx).trim();
        final thinking = text.substring(idx + tag.length).trim();
        return (thinking.isEmpty ? '……' : thinking, before);
      }
    }
    return (null, text);
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _showContextMenu(BuildContext ctx, Offset pos) {
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: 'copy',
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BubbleActionGlyph(
              type: BubbleActionGlyphType.copy,
              color: YanciTheme.accent.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 8),
            Text(
              L.get('chat_copy'),
              style: TextStyle(
                fontSize: 13,
                color: YanciTheme.textPrimary,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ],
        ),
      ),
    ];
    if (widget.isUser && widget.onEdit != null) {
      items.add(
        PopupMenuItem(
          value: 'edit',
          height: 44,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_outlined,
                size: 16,
                color: YanciTheme.accent.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 8),
              Text(
                L.pick(en: 'Edit and resend', zhTW: '編輯重發'),
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textPrimary,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ],
          ),
        ),
      );
    }
    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      // 跟主題走：主題色調面板＋細邊，不用 Material 預設陰影與色調層。
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: YanciTheme.themedOverlayBorder, width: 0.6),
      ),
      color: YanciTheme.themedOverlaySurface,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      items: items,
    ).then((v) {
      if (v == 'copy') {
        Clipboard.setData(
          ClipboardData(
            text: MarriageService.stripHiddenCertMetadata(widget.text),
          ),
        );
        if (!ctx.mounted) return;
        showThemedPillNotice(
          ctx,
          L.get('chat_copied'),
          duration: const Duration(milliseconds: 800),
        );
      } else if (v == 'edit') {
        widget.onEdit?.call();
      }
    });
  }

  bool _usesSingleLinePill(
    BuildContext context,
    String text,
    double screenWidth,
  ) {
    final value = text.trim();
    if (value.isEmpty || value.contains('\n')) return false;
    // 區塊型 Markdown 與表情標籤即使字面只有一行，也不是短句氣泡。
    if (RegExp(
      r'^(#{1,6}|>|[-*+]\s|\d+[.)]\s|```|\[sticker:)',
    ).hasMatch(value)) {
      return false;
    }
    final maxTextWidth =
        screenWidth * (widget.showAvatar ? 0.62 : 0.72) -
        YanciTheme.spacingMd * 2;
    if (maxTextWidth <= 0) return false;
    final painter = TextPainter(
      text: TextSpan(text: value, style: YanciTheme.bodyText),
      maxLines: 2,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxTextWidth);
    return painter.computeLineMetrics().length == 1;
  }

  BorderRadius _bubbleBorderRadius({
    required bool singleLine,
    required double radius,
  }) {
    final outer = Radius.circular(singleLine ? YanciTheme.radiusPill : radius);
    final softJoined = Radius.circular(
      singleLine ? 14.0 : (radius * 0.70).clamp(8.0, 22.0),
    );
    final tightJoined = Radius.circular((radius * 0.32).clamp(5.5, 7.5));
    final previousJoined = widget.tightGroupWithPrevious
        ? tightJoined
        : softJoined;
    final nextJoined = widget.tightGroupWithNext ? tightJoined : softJoined;
    if (widget.isUser) {
      return BorderRadius.only(
        topLeft: outer,
        bottomLeft: outer,
        topRight: widget.groupedWithPrevious ? previousJoined : outer,
        bottomRight: widget.groupedWithNext ? nextJoined : outer,
      );
    }
    return BorderRadius.only(
      topLeft: widget.groupedWithPrevious ? previousJoined : outer,
      bottomLeft: widget.groupedWithNext ? nextJoined : outer,
      topRight: outer,
      bottomRight: outer,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    _chatBackgroundScope = ChatBackgroundPresetScope.of(context);
    _scopedBackgroundPreset = _chatBackgroundScope?.preset;
    final hasCustomChatBackground =
        !widget.forceThemeBubbleColors &&
        (_chatBackgroundScope == null
            ? _hasCustomChatBackground()
            : _chatBackgroundScope!.hasCustomImage);
    final r = YanciTheme.radiusBubble.clamp(6.0, 32.0);
    final (thinking, rawDisplay) = widget.isUser
        ? (null, widget.text)
        : _parseThinking(widget.text);
    var displayText = MarriageService.stripHiddenCertMetadata(rawDisplay)
        .replaceAll(TtsService.audioTagRe, '')
        .replaceAll(RegExp(r'\[call_event:[^\]]*\]'), '') // 通話事件隱藏
        .replaceAll(RegExp(r'\[call_action:[^\]]*\]'), '') // 通話操作隱藏
        .replaceAll(RegExp(r'\[transfer:\d+\]'), '') // 轉帳標記隱藏（卡片顯示）
        .replaceAll(RegExp(r'\[gift:[^\]\n]{1,40}\]'), '') // 送禮標記隱藏
        .replaceAll(
          RegExp(r'\[gift_received:[^\]\n]{1,40}\]'),
          '',
        ) // 角色送達禮物標記隱藏
        .replaceAll(RegExp(r'\[scratch_gift:\w+\]'), '') // 刮刮卡禮物標記隱藏
        .trim();
    if (widget.isUser && displayText.startsWith('[shop_invite]')) {
      final name = widget.conversationTitle ?? '';
      displayText = L.pick(
        en: '🛍 Invited ${name.isEmpty ? 'them' : name} to browse the shop together',
        zhTW: '🛍 邀請${name.isEmpty ? '對方' : ' $name '}一起逛商店',
      );
    }
    if (!widget.isUser) {
      // 協議標籤清單統一在 ProtocolTags（含殘缺標籤），這裡只是保險層。
      displayText = VisibleModelOutput.protocolStripped(displayText);
    }
    final imagePaths = widget.imagePaths.isNotEmpty
        ? widget.imagePaths
        : (widget.imagePath == null
              ? const <String>[]
              : <String>[widget.imagePath!]);
    final hasImageContent = imagePaths.isNotEmpty;
    final hasBubbleContent = displayText.isNotEmpty || widget.isStreaming;

    final contextLog = _contextLogParts();
    final visibleMemoryLog = contextLog.memoryLog;
    final visibleEmotionLog = contextLog.emotionLog;
    final visibleEmotionCoordinate = contextLog.emotionCoordinate;

    final shouldShowScratch =
        widget.scratchData != null &&
        (widget.scratchData!.who == 'user' ? widget.isUser : !widget.isUser);

    final transferData = widget.transferData;
    final shouldShowTransfer =
        transferData != null &&
        ((transferData.direction == 'toChar' && widget.isUser) ||
            (transferData.direction == 'toUser' && !widget.isUser));

    final shouldShowGift = widget.giftName != null;

    final shouldShowMarriageCert = widget.marriageCert != null;

    final hasContextTree =
        !widget.isUser &&
        ((widget.includeThinkingDetails && thinking != null) ||
            widget.webSearchTrace != null ||
            visibleMemoryLog.isNotEmpty ||
            visibleEmotionLog.isNotEmpty ||
            visibleEmotionCoordinate.isNotEmpty ||
            widget.pendingMemoryActionCount > 0);

    final hasAnyContent =
        hasBubbleContent ||
        hasImageContent ||
        hasContextTree ||
        shouldShowScratch ||
        shouldShowTransfer ||
        shouldShowGift ||
        shouldShowMarriageCert;

    if (!hasAnyContent) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _entryCtrl,
      builder: (context, _) {
        final origin = widget.isUser
            ? Alignment.bottomRight
            : Alignment.bottomLeft;
        final aiFlatMode = !widget.isUser && YanciTheme.aiBubbleFlat;
        return Padding(
          padding: EdgeInsets.only(
            left: widget.isUser
                ? sw * (widget.showAvatar ? 0.15 : 0.2)
                : aiFlatMode
                ? math.max(20.0, sw * 0.055)
                : YanciTheme.spacingMd,
            right: widget.isUser
                ? YanciTheme.spacingMd
                : aiFlatMode
                ? math.max(40.0, sw * 0.115)
                : sw * (widget.showAvatar ? 0.15 : 0.2),
            top: widget.groupedWithPrevious
                ? (widget.tightGroupWithPrevious ? 1.5 : 2)
                : YanciTheme.spacingSm,
            bottom: widget.groupedWithNext
                ? (widget.tightGroupWithNext ? 1.5 : 2)
                : YanciTheme.spacingSm,
          ),
          child: Align(
            alignment: widget.isUser
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: widget.isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.selectable && !widget.isUser) ...[
                      _buildSelectionMark(),
                      const SizedBox(width: 8),
                    ],
                    if (widget.showAvatar && !widget.isUser && !aiFlatMode) ...[
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: widget.showAvatarImage
                            ? Opacity(
                                opacity: _avatarOpacity.value,
                                child: _buildAvatar(),
                              )
                            : null,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Column(
                        crossAxisAlignment: widget.isUser
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (aiFlatMode && widget.showAvatar) ...[
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: widget.showAvatarImage
                                      ? Opacity(
                                          opacity: _avatarOpacity.value,
                                          child: _buildAvatar(),
                                        )
                                      : null,
                                ),
                                if (hasContextTree) ...[
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: _contextReveal(
                                      RepaintBoundary(
                                        key: const ValueKey(
                                          'avatar-side-context-anchor',
                                        ),
                                        child: _buildContextTree(
                                          thinking:
                                              widget.includeThinkingDetails
                                              ? thinking
                                              : null,
                                          memoryLog: visibleMemoryLog,
                                          emotionLog: visibleEmotionLog,
                                          emotionCoordinate:
                                              visibleEmotionCoordinate,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                          ] else if (hasContextTree)
                            _contextReveal(
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: RepaintBoundary(
                                  key: const ValueKey(
                                    'avatar-side-context-anchor',
                                  ),
                                  child: _buildContextTree(
                                    thinking: widget.includeThinkingDetails
                                        ? thinking
                                        : null,
                                    memoryLog: visibleMemoryLog,
                                    emotionLog: visibleEmotionLog,
                                    emotionCoordinate: visibleEmotionCoordinate,
                                  ),
                                ),
                              ),
                            ),
                          Opacity(
                            key: const ValueKey('chat-bubble-entry-opacity'),
                            opacity: _bubbleOpacity.value,
                            child: Transform(
                              alignment: origin,
                              transform: Matrix4.diagonal3Values(
                                _scaleX.value,
                                _scaleY.value,
                                1,
                              ),
                              child: IntrinsicWidth(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (hasImageContent)
                                      // 外層 Column 是 stretch：不包 Align 的話，
                                      // 配文比縮略圖寬時圖會被硬拉到配文寬度。
                                      Align(
                                        alignment: widget.isUser
                                            ? Alignment.centerRight
                                            : Alignment.centerLeft,
                                        child: MessageImageGrid(
                                          paths: imagePaths,
                                          onTap: (path) {
                                            final viewable = imagePaths
                                                .where((p) => p != 'generating')
                                                .toList();
                                            _openFullScreenImage(
                                              context,
                                              viewable,
                                              viewable.indexOf(path),
                                            );
                                          },
                                          onLongPress: (path) =>
                                              _showImageMenu(context, path),
                                        ),
                                      ),
                                    if (hasImageContent && hasBubbleContent)
                                      const SizedBox(height: 6),
                                    if (hasBubbleContent)
                                      _alignBesideImages(
                                        hasImages: hasImageContent,
                                        child: Builder(
                                          builder: (context) {
                                            final overlayAsset = widget.isUser
                                                ? YanciTheme.bubbleUserAsset
                                                : YanciTheme.bubbleAiAsset;
                                            final imageBackgroundBubbleColor =
                                                hasCustomChatBackground
                                                ? (widget.isUser
                                                      ? _chatBackgroundUserBubbleColor()
                                                      : _chatBackgroundAiBubbleColor())
                                                : null;
                                            final imageBackgroundBubbleOpacity =
                                                hasCustomChatBackground
                                                ? _chatBackgroundBubbleOpacity()
                                                : 1.0;
                                            final isSingleLinePill =
                                                _usesSingleLinePill(
                                                  context,
                                                  displayText,
                                                  sw,
                                                );
                                            final bubbleRadius =
                                                _bubbleBorderRadius(
                                                  singleLine: isSingleLinePill,
                                                  radius: r,
                                                );
                                            final baseBubbleColor =
                                                imageBackgroundBubbleColor ??
                                                (widget.isUser
                                                    ? YanciTheme.userBubble
                                                    : YanciTheme.aiBubble);
                                            final presetAiGradient =
                                                imageBackgroundBubbleColor ==
                                                        null &&
                                                    !widget.isUser
                                                ? YanciTheme.aiBubbleGradient
                                                : null;
                                            final baseBorderColor =
                                                widget.isUser
                                                ? YanciTheme.userBubbleBorder
                                                : YanciTheme.aiBubbleBorder;
                                            final bubble = Container(
                                              key: const ValueKey(
                                                'chat-bubble-surface',
                                              ),
                                              padding: EdgeInsets.symmetric(
                                                horizontal: aiFlatMode
                                                    ? 4.0
                                                    : 15.0,
                                                vertical: aiFlatMode ? 6.0 : 12,
                                              ),
                                              decoration: aiFlatMode
                                                  ? null
                                                  : BoxDecoration(
                                                      color: baseBubbleColor,
                                                      gradient:
                                                          presetAiGradient ??
                                                          YanciTheme.bubbleGlazeGradient(
                                                            baseBubbleColor,
                                                            isDark: YanciTheme
                                                                .isDark,
                                                          ),
                                                      borderRadius:
                                                          bubbleRadius,
                                                      border:
                                                          overlayAsset == null
                                                          ? Border.all(
                                                              color: YanciTheme.bubbleGlazeBorderColor(
                                                                baseBorderColor
                                                                    .withValues(
                                                                      alpha:
                                                                          baseBorderColor
                                                                              .a *
                                                                          imageBackgroundBubbleOpacity,
                                                                    ),
                                                                isDark:
                                                                    YanciTheme
                                                                        .isDark,
                                                              ),
                                                              width: 0.65,
                                                            )
                                                          : null,
                                                      boxShadow:
                                                          YanciTheme.bubbleGlazeShadows(
                                                                isDark:
                                                                    YanciTheme
                                                                        .isDark,
                                                              )
                                                              .map(
                                                                (
                                                                  shadow,
                                                                ) => BoxShadow(
                                                                  color: shadow.color.withValues(
                                                                    alpha:
                                                                        shadow
                                                                            .color
                                                                            .a *
                                                                        imageBackgroundBubbleOpacity *
                                                                        (widget.tightGroupWithNext
                                                                            ? 0.45
                                                                            : 1.0),
                                                                  ),
                                                                  blurRadius:
                                                                      shadow
                                                                          .blurRadius *
                                                                      (widget.tightGroupWithNext
                                                                          ? 0.5
                                                                          : 1.0),
                                                                  spreadRadius:
                                                                      shadow
                                                                          .spreadRadius,
                                                                  offset: Offset(
                                                                    shadow
                                                                        .offset
                                                                        .dx,
                                                                    shadow
                                                                            .offset
                                                                            .dy *
                                                                        (widget.tightGroupWithNext
                                                                            ? 0.35
                                                                            : 1.0),
                                                                  ),
                                                                ),
                                                              )
                                                              .toList(),
                                                    ),
                                              child: Opacity(
                                                opacity: _contentOpacity.value,
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      widget.isUser
                                                      ? CrossAxisAlignment.end
                                                      : CrossAxisAlignment
                                                            .start,
                                                  children: [
                                                    if (displayText.isNotEmpty)
                                                      Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          Flexible(
                                                            child: _MixedContent(
                                                              text: displayText,
                                                              characterId: widget
                                                                  .characterId,
                                                              color:
                                                                  hasCustomChatBackground
                                                                  ? _chatBackgroundBubbleTextColor()
                                                                  : YanciTheme
                                                                        .textOnBubble,
                                                              selectable:
                                                                  !widget
                                                                      .isUser,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    if (displayText.isEmpty &&
                                                        widget.isStreaming)
                                                      const _TypingIndicator(),
                                                  ],
                                                ),
                                              ),
                                            );

                                            final bubbleWithOverlay =
                                                overlayAsset != null
                                                ? Stack(
                                                    children: [
                                                      bubble,
                                                      Positioned.fill(
                                                        child: IgnorePointer(
                                                          child: Opacity(
                                                            opacity:
                                                                imageBackgroundBubbleOpacity,
                                                            child: Image.asset(
                                                              overlayAsset,
                                                              key: const ValueKey(
                                                                'themed-bubble-frame',
                                                              ),
                                                              scale: 16,
                                                              fit: BoxFit.fill,
                                                              centerSlice:
                                                                  const Rect.fromLTRB(
                                                                    20,
                                                                    20,
                                                                    60,
                                                                    60,
                                                                  ),
                                                              filterQuality:
                                                                  FilterQuality
                                                                      .high,
                                                              errorBuilder:
                                                                  (_, _, _) =>
                                                                      const SizedBox.shrink(),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : bubble;

                                            if (!widget.isUser ||
                                                widget.captureMode) {
                                              return bubbleWithOverlay;
                                            }
                                            return GestureDetector(
                                              onLongPressStart: (d) =>
                                                  _showContextMenu(
                                                    context,
                                                    d.globalPosition,
                                                  ),
                                              child: bubbleWithOverlay,
                                            );
                                          },
                                        ),
                                      ),
                                    if ((hasBubbleContent || hasImageContent) &&
                                        widget.timestamp != null &&
                                        !widget.isStreaming)
                                      Opacity(
                                        opacity: _contentOpacity.value,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            top: 3,
                                            left: 4,
                                            right: 4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.max,
                                            mainAxisAlignment: widget.isUser
                                                ? MainAxisAlignment.end
                                                : MainAxisAlignment.start,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Text(
                                                _formatTime(widget.timestamp!),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color:
                                                      _chatBackgroundScope
                                                          ?.foreground
                                                          ?.secondary ??
                                                      YanciTheme.textSecondary
                                                          .withValues(
                                                            alpha: 0.4,
                                                          ),
                                                ),
                                              ),
                                              if (!widget.isUser &&
                                                  widget.showToolbar) ...[
                                                const SizedBox(width: 5),
                                                _buildToolbarTapTarget(
                                                  label: L.get('chat_copy'),
                                                  onTap: () {
                                                    HapticFeedback.lightImpact();
                                                    Clipboard.setData(
                                                      ClipboardData(
                                                        text:
                                                            widget
                                                                .toolbarText ??
                                                            displayText,
                                                      ),
                                                    );
                                                    showThemedPillNotice(
                                                      context,
                                                      L.get('chat_copied'),
                                                      duration: const Duration(
                                                        milliseconds: 800,
                                                      ),
                                                    );
                                                  },
                                                  child: _buildCopyIcon(),
                                                ),
                                                _buildToolbarTapTarget(
                                                  label: _isSaved
                                                      ? L.pick(
                                                          en: 'Remove bookmark',
                                                          zhTW: '取消書籤',
                                                          zhCN: '取消书签',
                                                        )
                                                      : L.pick(
                                                          en: 'Bookmark',
                                                          zhTW: '加入書籤',
                                                          zhCN: '加入书签',
                                                        ),
                                                  onTap: _toggleSave,
                                                  child: _buildBookmarkIcon(
                                                    color: _isSaved
                                                        ? YanciTheme.accent
                                                        : null,
                                                  ),
                                                ),
                                                _buildToolbarTapTarget(
                                                  label: L.pick(
                                                    en: 'Read aloud',
                                                    zhTW: '朗讀',
                                                    zhCN: '朗读',
                                                  ),
                                                  onTap: () => _speakText(
                                                    widget.toolbarText ??
                                                        widget.text,
                                                  ),
                                                  child: _buildActionIconSlot(
                                                    key: const ValueKey(
                                                      'bubble-action-tts',
                                                    ),
                                                    child: IgnorePointer(
                                                      child: TtsPlayButton(
                                                        messageId:
                                                            widget
                                                                .toolbarMessageId ??
                                                            widget.messageId,
                                                        idleColor:
                                                            _chatBackgroundScope
                                                                ?.foreground
                                                                ?.secondary,
                                                        onTap: () => _speakText(
                                                          widget.toolbarText ??
                                                              widget.text,
                                                        ),
                                                        size:
                                                            _kToolbarSideIconSize *
                                                            _toolbarGlyphScale(),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              if (widget.cacheHit) ...[
                                                const SizedBox(width: 0),
                                                Semantics(
                                                  button: true,
                                                  label: L.pick(
                                                    en: 'Context cache hit',
                                                    zhTW: '命中上下文緩存',
                                                    zhCN: '命中上下文缓存',
                                                  ),
                                                  child: Builder(
                                                    builder: (anchorContext) =>
                                                        GestureDetector(
                                                          key: const ValueKey(
                                                            'bubble-cache-hit',
                                                          ),
                                                          behavior:
                                                              HitTestBehavior
                                                                  .opaque,
                                                          onTap: () =>
                                                              _showCacheHitPopover(
                                                                anchorContext,
                                                              ),
                                                          child: SizedBox(
                                                            width: 28,
                                                            height: 44,
                                                            child: Center(
                                                              child: Icon(
                                                                Icons
                                                                    .bolt_rounded,
                                                                size:
                                                                    16 *
                                                                    _toolbarGlyphScale(),
                                                                color:
                                                                    _cacheHitColor(),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                  ),
                                                ),
                                              ],
                                              if (widget.incomplete) ...[
                                                const SizedBox(width: 7),
                                                Icon(
                                                  Icons.error_outline_rounded,
                                                  size: 14,
                                                  color: Colors.orange
                                                      .withValues(alpha: 0.8),
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  L.pick(
                                                    en: 'Interrupted',
                                                    zhTW: '回覆中斷',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.orange
                                                        .withValues(alpha: 0.8),
                                                  ),
                                                ),
                                                if (widget.onRetryIncomplete !=
                                                    null) ...[
                                                  const SizedBox(width: 5),
                                                  TextButton(
                                                    onPressed: widget
                                                        .onRetryIncomplete,
                                                    style: TextButton.styleFrom(
                                                      minimumSize: const Size(
                                                        44,
                                                        44,
                                                      ),
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                          ),
                                                      tapTargetSize:
                                                          MaterialTapTargetSize
                                                              .shrinkWrap,
                                                    ),
                                                    child: Text(
                                                      L.pick(
                                                        en: 'Retry',
                                                        zhTW: '重試',
                                                      ),
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color:
                                                            YanciTheme.accent,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (shouldShowScratch || shouldShowTransfer)
                            Opacity(
                              opacity: _bubbleOpacity.value,
                              child: Transform(
                                alignment: origin,
                                transform: Matrix4.diagonal3Values(
                                  _scaleX.value,
                                  _scaleY.value,
                                  1,
                                ),
                                child: Column(
                                  crossAxisAlignment: widget.isUser
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (shouldShowScratch &&
                                        widget.messageId != null &&
                                        widget.characterId != null)
                                      IntrinsicWidth(
                                        child: ScratchMiniCard(
                                          messageId: widget.messageId!,
                                          data: widget.scratchData!,
                                          characterId: widget.characterId!,
                                        ),
                                      ),
                                    if (shouldShowTransfer &&
                                        widget.messageId != null &&
                                        widget.characterId != null)
                                      TransferMiniCard(
                                        messageId: widget.messageId!,
                                        data: widget.transferData!,
                                        characterId: widget.characterId!,
                                        canAct:
                                            widget.transferData!.direction ==
                                                'toUser' &&
                                            widget.transferData!.status ==
                                                'pending',
                                        onUpdated: widget.onTransferUpdated,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          if (shouldShowGift)
                            GiftMiniCard(
                              giftName: widget.giftName!,
                              accepted: widget.giftAccepted,
                              receivedFromCharacter:
                                  widget.giftReceivedFromCharacter,
                            ),
                          if (shouldShowMarriageCert)
                            MarriageCertCard(
                              userName: widget.marriageCert!.userName,
                              charName: widget.marriageCert!.charName,
                              signed: widget.marriageCert!.signed,
                              date: widget.marriageCert!.date,
                              onSignTap: widget.onCertSignTap,
                            ),
                        ],
                      ),
                    ),
                    if (widget.showAvatar && widget.isUser) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: widget.showAvatarImage
                            ? Opacity(
                                opacity: _avatarOpacity.value,
                                child: _buildAvatar(),
                              )
                            : null,
                      ),
                    ],
                    if (widget.selectable && widget.isUser) ...[
                      const SizedBox(width: 8),
                      _buildSelectionMark(),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectionMark() {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      label: L.pick(
        en: selected ? 'Deselect message' : 'Select message',
        zhTW: selected ? '取消選取消息' : '選取消息',
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelectionToggle,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? YanciTheme.accent : Colors.transparent,
              border: Border.all(
                color: selected
                    ? YanciTheme.accent
                    : YanciTheme.textSecondary.withValues(alpha: 0.35),
                width: 1.2,
              ),
            ),
            child: selected
                ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  double _chatBackgroundBubbleOpacity() {
    if (widget.forceThemeBubbleColors) return YanciTheme.bubbleOpacity;
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) {
        return YanciTheme.bubbleOpacity;
      }
      return _scopedBackgroundPreset?.chatBubbleOpacity ??
          _chatBackgroundScope?.palette?.bubbleOpacity ??
          YanciTheme.bubbleOpacity;
    }
    final preset = _scopedBackgroundPreset;
    if (preset == null) return YanciTheme.chatBackgroundBubbleOpacity;
    return preset.chatBubbleOpacity ?? YanciTheme.chatBackgroundBubbleOpacity;
  }

  Color _chatBackgroundAiBubbleColor() {
    if (widget.forceThemeBubbleColors) return YanciTheme.aiBubble;
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) return YanciTheme.aiBubble;
      final custom = _scopedBackgroundPreset?.chatAiBubbleColor == null
          ? YanciTheme.bubbleColorOverride(
                  YanciTheme.presetId,
                  ThemeBubbleColorRole.aiBubble,
                ) ??
                _chatBackgroundScope?.palette?.aiBubble
          : Color(_scopedBackgroundPreset!.chatAiBubbleColor!);
      final base = custom == null
          ? YanciTheme.aiBubble
          : YanciTheme.applyBubbleBrightness(custom);
      return base.withValues(alpha: _chatBackgroundBubbleOpacity());
    }
    final preset = _scopedBackgroundPreset;
    if (preset == null) {
      return YanciTheme.chatBackgroundAiBubbleColor;
    }
    return (preset.chatAiBubbleColor == null
            ? YanciTheme.chatBackgroundAiBubbleColor.withValues(alpha: 1)
            : YanciTheme.applyBubbleBrightness(
                Color(preset.chatAiBubbleColor!),
              ))
        .withValues(alpha: _chatBackgroundBubbleOpacity());
  }

  Color _chatBackgroundUserBubbleColor() {
    if (widget.forceThemeBubbleColors) return YanciTheme.userBubble;
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) return YanciTheme.userBubble;
      final custom = _scopedBackgroundPreset?.chatUserBubbleColor == null
          ? YanciTheme.bubbleColorOverride(
                  YanciTheme.presetId,
                  ThemeBubbleColorRole.userBubble,
                ) ??
                _chatBackgroundScope?.palette?.userBubble
          : Color(_scopedBackgroundPreset!.chatUserBubbleColor!);
      final base = custom == null
          ? YanciTheme.userBubble
          : YanciTheme.applyBubbleBrightness(custom);
      return base.withValues(alpha: _chatBackgroundBubbleOpacity());
    }
    final preset = _scopedBackgroundPreset;
    if (preset == null) {
      return YanciTheme.chatBackgroundUserBubbleColor;
    }
    return (preset.chatUserBubbleColor == null
            ? YanciTheme.chatBackgroundUserBubbleColor.withValues(alpha: 1)
            : YanciTheme.applyBubbleBrightness(
                Color(preset.chatUserBubbleColor!),
              ))
        .withValues(alpha: _chatBackgroundBubbleOpacity());
  }

  Color _chatBackgroundBubbleTextColor() {
    if (widget.forceThemeBubbleColors) return YanciTheme.textOnBubble;
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) return YanciTheme.textOnBubble;
      final manual = _scopedBackgroundPreset?.chatBubbleTextColor;
      return manual == null
          ? YanciTheme.bubbleColorOverride(
                  YanciTheme.presetId,
                  ThemeBubbleColorRole.textOnBubble,
                ) ??
                _chatBackgroundScope?.palette?.bubbleText ??
                YanciTheme.textOnBubble
          : Color(manual);
    }
    final preset = _scopedBackgroundPreset;
    if (preset == null) return YanciTheme.chatBackgroundBubbleTextColor;
    return preset.chatBubbleTextColor == null
        ? YanciTheme.chatBackgroundBubbleTextColor
        : Color(preset.chatBubbleTextColor!);
  }

  Color _chatBackgroundThinkingTextColor() {
    if (widget.forceThemeBubbleColors) {
      return Color.lerp(
        YanciTheme.textSecondary,
        YanciTheme.textPrimary,
        0.34,
      )!;
    }
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) {
        return Color.lerp(
          YanciTheme.textSecondary,
          YanciTheme.textPrimary,
          0.34,
        )!;
      }
      final manual = _scopedBackgroundPreset?.chatThinkingTextColor;
      return manual == null
          ? _chatBackgroundScope?.palette?.thinkingText ??
                Color.lerp(
                  YanciTheme.textSecondary,
                  YanciTheme.textPrimary,
                  0.34,
                )!
          : Color(manual);
    }
    final preset = _scopedBackgroundPreset;
    if (preset == null) return YanciTheme.chatBackgroundThinkingTextColor;
    return preset.chatThinkingTextColor == null
        ? YanciTheme.chatBackgroundThinkingTextColor
        : Color(preset.chatThinkingTextColor!);
  }

  Color _thinkingTreeLabelColor() {
    if (widget.forceThemeBubbleColors) {
      return Color.lerp(
        YanciTheme.textSecondary,
        YanciTheme.textPrimary,
        0.12,
      )!;
    }
    final scopedColor = _scopedBackgroundPreset?.chatThinkingTextColor;
    if (_chatBackgroundScope != null) {
      if (!_chatBackgroundScope!.hasCustomImage) {
        return Color.lerp(
          YanciTheme.textSecondary,
          YanciTheme.textPrimary,
          0.12,
        )!;
      }
      if (scopedColor != null) return Color(scopedColor);
      return _chatBackgroundScope?.palette?.thinkingText ??
          Color.lerp(YanciTheme.textSecondary, YanciTheme.textPrimary, 0.12)!;
    }
    if (YanciTheme.chatBackgroundThinkingTextOverride != null) {
      return YanciTheme.chatBackgroundThinkingTextColor;
    }
    return Color.lerp(YanciTheme.textSecondary, YanciTheme.textPrimary, 0.12)!;
  }

  Color _thinkingTreeBodyColor() => _chatBackgroundThinkingTextColor();

  bool _hasCustomChatBackground([String? overridePath]) {
    final path = overridePath ?? YanciTheme.chatBackgroundImagePath;
    if (path == _checkedChatBackgroundPath) {
      return _checkedChatBackgroundExists;
    }
    _checkedChatBackgroundPath = path;
    _checkedChatBackgroundExists = path.isNotEmpty && File(path).existsSync();
    return _checkedChatBackgroundExists;
  }

  Widget _buildThinkingMarkdown(String text, {Key? key, bool inSheet = false}) {
    return ThinkingMarkdown(
      key: key,
      text: text,
      bodyColor: _thinkingTreeBodyColor(),
      fontSize: inSheet ? 13 : 11,
    );
  }

  Widget? _buildPendingMemoryActionBadge() {
    final count = widget.pendingMemoryActionCount;
    if (count <= 0) return null;
    final badgeColor = widget.hasUnreadMemoryActions
        ? const Color(0xFFD86B72)
        : YanciTheme.textSecondary;
    final label = L.pick(
      en: '$count pending',
      zhTW: '$count 待確認',
      zhCN: '$count 待确认',
    );
    return Semantics(
      button: widget.onMemoryReviewTap != null,
      label: L.pick(
        en: '$count pending memory proposals. Open review.',
        zhTW: '$count 個記憶提案待確認，點擊開啟提案匣。',
        zhCN: '$count 个记忆提案待确认，点击打开提案匣。',
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onMemoryReviewTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: badgeColor.withValues(alpha: 0.28),
              width: 0.6,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: badgeColor,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// Thinking 資訊樹中的 Memory 分支；情緒與記憶同輪時收在這裡。
  Widget _buildMemoryLog(
    String log, {
    String emotionLog = '',
    String emotionCoordinate = '',
    bool inSheet = false,
  }) {
    final forcedExpanded = widget.thinkingExpandedOverride == true;
    final hasInlineProposals = _inlineMemoryProposals.isNotEmpty;
    final logWidget = _buildToolLog(
      log,
      containerKey: const ValueKey('memory-log-container'),
      label: 'Memory',
      icon: Icons.auto_awesome_outlined,
      expanded: forcedExpanded || _memLogExpanded || hasInlineProposals,
      onTap: forcedExpanded || hasInlineProposals
          ? null
          : () => _updateContextState(() => _memLogExpanded = !_memLogExpanded),
      headerTrailing: _buildPendingMemoryActionBadge(),
      inSheet: inSheet,
      trailing: emotionLog.isNotEmpty || emotionCoordinate.isNotEmpty
          ? _buildEmotionBranch(emotionLog, emotionCoordinate, inSheet: inSheet)
          : null,
    );
    final proposals = _inlineMemoryProposals;
    if (proposals.isEmpty) return logWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        logWidget,
        for (final proposal in proposals) _buildInlineMemoryProposal(proposal),
      ],
    );
  }

  List<MemoryActionProposal> get _inlineMemoryProposals => widget
      .pendingMemoryProposals
      .where(
        (proposal) =>
            proposal.action == MemoryActionProposal.actionCreate &&
            proposal.canExecute,
      )
      .toList(growable: false);

  Future<void> _runInlineMemoryProposal(
    MemoryActionProposal proposal,
    String decision,
  ) async {
    final callback = widget.onInlineMemoryProposal;
    if (callback == null || _inlineMemoryBusyId != null) return;
    _updateContextState(() => _inlineMemoryBusyId = proposal.id);
    try {
      await callback(proposal, decision);
    } catch (error) {
      if (mounted) {
        showThemedPillNotice(
          context,
          L.pick(
            en: 'Memory update failed: $error',
            zhTW: '記憶處理失敗：$error',
            zhCN: '记忆处理失败：$error',
          ),
          tone: ThemedNoticeTone.error,
        );
      }
    } finally {
      if (mounted) {
        _updateContextState(() => _inlineMemoryBusyId = null);
      }
    }
  }

  Widget _buildInlineMemoryProposal(MemoryActionProposal proposal) {
    final candidate = proposal.candidatePreview;
    final category = candidate['category']?.toString() ?? '';
    final content = candidate['content']?.toString() ?? '';
    final triggers = candidate['triggers']?.toString() ?? '';
    final existing = proposal.targetSnapshots;
    final hasExisting = existing.isNotEmpty;
    final busy = _inlineMemoryBusyId == proposal.id;
    final buttonDisabled = busy || widget.onInlineMemoryProposal == null;
    final proposalTextColor = _chatBackgroundBubbleTextColor();
    final proposalMutedColor = proposalTextColor.withValues(alpha: 0.68);

    return Container(
      key: ValueKey('inline-memory-proposal-${proposal.id}'),
      width: double.infinity,
      margin: const EdgeInsets.only(right: 8, top: 7),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        // Keep pending memory proposals on the same visual surface as the
        // user's bubble. This respects both the theme and the custom-image
        // bubble-opacity slider instead of becoming illegibly transparent.
        color: _chatBackgroundUserBubbleColor(),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.24),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 15,
                color: YanciTheme.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasExisting
                      ? L.pick(
                          en: 'The model suggests updating a memory',
                          zhTW: '模型建議更新一條記憶',
                          zhCN: '模型建议更新一条记忆',
                        )
                      : L.pick(
                          en: 'The model wants to remember this',
                          zhTW: '模型想記住這件事',
                          zhCN: '模型想记住这件事',
                        ),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: YanciTheme.accent,
                  ),
                ),
              ),
              if (busy)
                const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '[${category.isEmpty ? L.pick(en: 'Memory', zhTW: '記憶', zhCN: '记忆') : category}] $content',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: proposalTextColor,
            ),
          ),
          if (triggers.isNotEmpty)
            Text(
              '@$triggers',
              style: TextStyle(fontSize: 11, color: proposalMutedColor),
            ),
          if (hasExisting) ...[
            const SizedBox(height: 5),
            Text(
              L.pick(en: 'Current: ', zhTW: '目前記憶：', zhCN: '当前记忆：') +
                  (existing.first['content']?.toString() ?? ''),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                height: 1.4,
                color: proposalMutedColor,
              ),
            ),
          ],
          const SizedBox(height: 7),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 5,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: buttonDisabled
                    ? null
                    : () => _runInlineMemoryProposal(proposal, 'reject'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                child: Text(
                  hasExisting
                      ? L.pick(en: 'Keep current', zhTW: '保留目前', zhCN: '保留当前')
                      : L.pick(en: 'Reject', zhTW: '拒絕', zhCN: '拒绝'),
                ),
              ),
              if (hasExisting && proposal.mergePreview.isNotEmpty)
                OutlinedButton(
                  onPressed: buttonDisabled
                      ? null
                      : () => _runInlineMemoryProposal(
                          proposal,
                          MemoryGuardService.createDecisionMerge,
                        ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                  ),
                  child: Text(L.pick(en: 'Merge', zhTW: '合併', zhCN: '合并')),
                ),
              FilledButton.tonal(
                onPressed: buttonDisabled
                    ? null
                    : () => _runInlineMemoryProposal(
                        proposal,
                        MemoryGuardService.createDecisionUseNew,
                      ),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                child: Text(
                  hasExisting
                      ? L.pick(en: 'Use new', zhTW: '使用新記憶', zhCN: '使用新记忆')
                      : L.pick(en: 'Save memory', zhTW: '保存記憶', zhCN: '保存记忆'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToolLog(
    String log, {
    required Key containerKey,
    required String label,
    required IconData icon,
    required bool expanded,
    required VoidCallback? onTap,
    Widget? headerTrailing,
    Widget? trailing,
    bool inSheet = false,
  }) {
    final lines = log.split('\n');
    final done = lines.isNotEmpty && lines.last.trim() == 'Done';
    final bodyLines = done ? lines.sublist(0, lines.length - 1) : lines;
    final validLines = bodyLines.where((l) => l.trim().isNotEmpty).toList();
    if (validLines.isEmpty) return const SizedBox.shrink();
    final bodyColor = _thinkingTreeBodyColor();
    final labelColor = _thinkingTreeLabelColor();
    final fontSize = inSheet ? 13.0 : 11.0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return Semantics(
      button: onTap != null,
      expanded: expanded,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          key: containerKey,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: labelColor),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: fontSize,
                      color: labelColor,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                  if (headerTrailing != null) ...[
                    const SizedBox(width: 6),
                    headerTrailing,
                  ],
                  const SizedBox(width: 3),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.keyboard_arrow_right_rounded,
                      size: 15,
                      color: labelColor,
                    ),
                  ),
                ],
              ),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.only(left: 20, top: 4, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildThinkingMarkdown(
                        validLines.join('\n'),
                        key: const ValueKey('memory-markdown-content'),
                        inSheet: inSheet,
                      ),
                      if (done)
                        Text(
                          'Done ✓',
                          style: TextStyle(
                            fontSize: fontSize,
                            color: bodyColor,
                            height: 1.5,
                          ),
                        ),
                      if (trailing != null) ...[
                        const SizedBox(height: 4),
                        trailing,
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmotionBranch(
    String log,
    String emoLine, {
    bool inSheet = false,
  }) {
    final lines = log.split('\n');
    final done = lines.isNotEmpty && lines.last.trim() == 'Done';
    final bodyLines = done ? lines.sublist(0, lines.length - 1) : lines;
    final validLines = bodyLines.where((l) => l.trim().isNotEmpty).toList();
    final coord = emoLine
        .replaceFirst('情緒座標:', '')
        .replaceFirst('情緒座標：', '')
        .replaceFirst('情绪坐标:', '')
        .replaceFirst('情绪坐标：', '')
        .replaceFirst(
          RegExp(r'^Emotion coordinates\s*:\s*', caseSensitive: false),
          '',
        )
        .trim();
    if (validLines.isEmpty && coord.isEmpty) return const SizedBox.shrink();

    final labelColor = _thinkingTreeLabelColor();
    final bodyColor = _thinkingTreeBodyColor();
    final fontSize = inSheet ? 13.0 : 11.0;
    const label = 'Mood';
    return Semantics(
      container: true,
      label: [
        label,
        if (coord.isNotEmpty) coord,
        ...validLines,
        if (done) 'Done',
      ].join(', '),
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('emotion-log-container'),
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.favorite_border_rounded,
                    size: 13,
                    color: labelColor,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: fontSize,
                      color: labelColor,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                  if (coord.isNotEmpty)
                    Container(
                      key: const ValueKey('emotion-coordinate-container'),
                      padding: const EdgeInsets.only(left: 7),
                      child: Text(
                        coord,
                        style: TextStyle(
                          fontSize: 10,
                          color: labelColor.withValues(alpha: 0.86),
                          fontFamily: YanciTheme.fontFamily,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              if (validLines.isNotEmpty || done)
                Padding(
                  padding: const EdgeInsets.only(left: 20, top: 4, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...validLines.map(
                        (line) => Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            line,
                            style: TextStyle(
                              fontSize: fontSize,
                              color: bodyColor,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                      if (done)
                        Text(
                          'Done ✓',
                          style: TextStyle(
                            fontSize: fontSize,
                            color: bodyColor,
                            height: 1.5,
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

  Widget _buildContextTree({
    required String? thinking,
    required String memoryLog,
    required String emotionLog,
    required String emotionCoordinate,
  }) {
    if (thinking == null && widget.webSearchTrace != null) {
      return _buildThinkingTree(
        thinking: '',
        memoryLog: memoryLog,
        emotionLog: emotionLog,
        emotionCoordinate: emotionCoordinate,
      );
    }
    if (thinking == null) {
      if (memoryLog.isNotEmpty || widget.pendingMemoryActionCount > 0) {
        return _buildStandaloneMemory(
          memoryLog,
          emotionLog: emotionLog,
          emotionCoordinate: emotionCoordinate,
        );
      }
      return _buildStandaloneEmotion(emotionLog, emotionCoordinate);
    }

    return _buildThinkingTree(
      thinking: thinking,
      memoryLog: memoryLog,
      emotionLog: emotionLog,
      emotionCoordinate: emotionCoordinate,
    );
  }

  Widget _buildThinkingTree({
    required String thinking,
    required String memoryLog,
    required String emotionLog,
    required String emotionCoordinate,
  }) {
    if (!widget.captureMode && widget.thinkingExpandedOverride == null) {
      return _buildThinkingSheetLauncher();
    }

    final hasVisibleDetails =
        thinking.isNotEmpty ||
        widget.webSearchTrace != null ||
        memoryLog.isNotEmpty ||
        _inlineMemoryProposals.isNotEmpty ||
        emotionLog.isNotEmpty ||
        emotionCoordinate.isNotEmpty;
    final expanded = widget.thinkingExpandedOverride == true
        ? hasVisibleDetails
        : (widget.thinkingExpandedOverride ?? _thinkingExpanded) ||
              _inlineMemoryProposals.isNotEmpty;
    final labelColor = _thinkingTreeLabelColor();
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) || widget.captureMode;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final onTap = widget.thinkingExpandedOverride == null
        ? () =>
              _updateContextState(() => _thinkingExpanded = !_thinkingExpanded)
        : null;
    final label = L.get('chat_thinking_tree');

    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: onTap != null,
            expanded: expanded,
            label: label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                key: const ValueKey('thinking-chain-container'),
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: labelColor,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    if (widget.pendingMemoryActionCount > 0) ...[
                      const SizedBox(width: 6),
                      _buildPendingMemoryActionBadge()!,
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      key: const ValueKey('thinking-tree-chevron'),
                      turns: expanded ? 0.25 : 0,
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.keyboard_arrow_right_rounded,
                        size: 16,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            _buildThinkingTreeBody(
              thinking: thinking,
              memoryLog: memoryLog,
              emotionLog: emotionLog,
              emotionCoordinate: emotionCoordinate,
            ),
        ],
      ),
    );
  }

  Widget _buildThinkingSheetLauncher() {
    return ThinkingSheetLauncher(
      color: _thinkingTreeLabelColor(),
      onTap: _showThinkingSheet,
      badge: widget.pendingMemoryActionCount > 0
          ? _buildPendingMemoryActionBadge()
          : null,
    );
  }

  Future<void> _showThinkingSheet() async {
    if (!mounted) return;
    await _thinkingSheet.show(
      context: context,
      titleColor: _thinkingTreeLabelColor(),
      contentBuilder: (_) => _buildCurrentThinkingSheetBody(),
    );
  }

  Widget _buildCurrentThinkingSheetBody() {
    final (thinking, _) = _parseThinking(widget.text);
    final contextLog = _contextLogParts();
    return _buildThinkingTreeBody(
      thinking: widget.includeThinkingDetails ? (thinking ?? '') : '',
      memoryLog: contextLog.memoryLog,
      emotionLog: contextLog.emotionLog,
      emotionCoordinate: contextLog.emotionCoordinate,
      inSheet: true,
    );
  }

  Widget _buildThinkingTreeBody({
    required String thinking,
    required String memoryLog,
    required String emotionLog,
    required String emotionCoordinate,
    bool inSheet = false,
  }) {
    final hasContextDetails =
        memoryLog.isNotEmpty ||
        _inlineMemoryProposals.isNotEmpty ||
        emotionLog.isNotEmpty ||
        emotionCoordinate.isNotEmpty;
    final contextDetails = !hasContextDetails
        ? null
        : memoryLog.isNotEmpty || _inlineMemoryProposals.isNotEmpty
        ? _buildMemoryLog(
            memoryLog,
            emotionLog: emotionLog,
            emotionCoordinate: emotionCoordinate,
            inSheet: inSheet,
          )
        : _buildEmotionBranch(emotionLog, emotionCoordinate, inSheet: inSheet);
    return ThinkingTreeBodyLayout(
      inSheet: inSheet,
      webSearch: widget.webSearchTrace == null
          ? null
          : WebSearchThinkingNode.completed(trace: widget.webSearchTrace!),
      contextDetails: contextDetails,
      thinkingContent: thinking.isEmpty
          ? null
          : _buildThinkingMarkdown(
              thinking,
              key: const ValueKey('thinking-chain-content'),
              inSheet: inSheet,
            ),
    );
  }

  Widget _buildStandaloneMemory(
    String log, {
    required String emotionLog,
    required String emotionCoordinate,
  }) {
    final lines = log.split('\n');
    final done = lines.isNotEmpty && lines.last.trim() == 'Done';
    final bodyLines = done ? lines.sublist(0, lines.length - 1) : lines;
    final validLines = bodyLines
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final bodyColor = _thinkingTreeBodyColor();

    return _buildStandaloneContextRoot(
      label: 'Memory',
      containerKey: const ValueKey('memory-root-container'),
      bodyKey: const ValueKey('memory-root-body'),
      icon: Icons.auto_awesome_outlined,
      headerTrailing: _buildPendingMemoryActionBadge(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (validLines.isNotEmpty)
            _buildThinkingMarkdown(
              validLines.join('\n'),
              key: const ValueKey('memory-root-markdown-content'),
            ),
          for (final proposal in _inlineMemoryProposals)
            _buildInlineMemoryProposal(proposal),
          if (done)
            Text(
              'Done ✓',
              style: TextStyle(fontSize: 11, color: bodyColor, height: 1.5),
            ),
          if (validLines.isEmpty &&
              widget.pendingMemoryActionCount > 0 &&
              _inlineMemoryProposals.isEmpty)
            Text(
              L.pick(
                en: 'A memory change is waiting for your review.',
                zhTW: '有記憶變更正在等待你確認。',
              ),
              style: TextStyle(fontSize: 11, color: bodyColor, height: 1.5),
            ),
          if (emotionLog.isNotEmpty || emotionCoordinate.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildEmotionBranch(emotionLog, emotionCoordinate),
          ],
        ],
      ),
    );
  }

  Widget _buildStandaloneEmotion(String log, String emoLine) {
    final lines = log.split('\n');
    final done = lines.isNotEmpty && lines.last.trim() == 'Done';
    final bodyLines = done ? lines.sublist(0, lines.length - 1) : lines;
    final validLines = bodyLines
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final coord = emoLine
        .replaceFirst('情緒座標:', '')
        .replaceFirst('情緒座標：', '')
        .replaceFirst('情绪坐标:', '')
        .replaceFirst('情绪坐标：', '')
        .replaceFirst(
          RegExp(r'^Emotion coordinates\s*:\s*', caseSensitive: false),
          '',
        )
        .trim();
    final bodyColor = _thinkingTreeBodyColor();

    return _buildStandaloneContextRoot(
      label: 'Mood',
      subtitle: coord,
      containerKey: const ValueKey('emotion-root-container'),
      bodyKey: const ValueKey('emotion-root-body'),
      icon: Icons.favorite_border_rounded,
      expandable: validLines.isNotEmpty || done,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in validLines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(fontSize: 11, color: bodyColor, height: 1.5),
              ),
            ),
          if (done)
            Text(
              'Done ✓',
              style: TextStyle(fontSize: 11, color: bodyColor, height: 1.5),
            ),
        ],
      ),
    );
  }

  Widget _buildStandaloneContextRoot({
    required String label,
    required Key containerKey,
    required Key bodyKey,
    required IconData icon,
    required Widget child,
    String subtitle = '',
    bool expandable = true,
    Widget? headerTrailing,
  }) {
    final forcedExpanded = widget.thinkingExpandedOverride == true;
    final expanded =
        expandable &&
        (forcedExpanded ||
            (widget.thinkingExpandedOverride ?? _thinkingExpanded));
    final canToggle =
        expandable &&
        !forcedExpanded &&
        widget.thinkingExpandedOverride == null;
    final labelColor = _thinkingTreeLabelColor();
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) || widget.captureMode;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final onTap = canToggle
        ? () =>
              _updateContextState(() => _thinkingExpanded = !_thinkingExpanded)
        : null;
    final semanticLabel = subtitle.isEmpty ? label : '$label, $subtitle';

    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: onTap != null,
            expanded: expandable ? expanded : null,
            label: semanticLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                key: containerKey,
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 13, color: labelColor),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: labelColor,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 10,
                              color: labelColor.withValues(alpha: 0.86),
                              fontFamily: YanciTheme.fontFamily,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    if (headerTrailing != null) ...[
                      const SizedBox(width: 6),
                      headerTrailing,
                    ],
                    if (expandable) ...[
                      const SizedBox(width: 3),
                      AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.keyboard_arrow_right_rounded,
                          size: 16,
                          color: labelColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Container(
              key: bodyKey,
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.only(left: 30, right: 8, bottom: 4),
              child: child,
            ),
        ],
      ),
    );
  }

  /// 書籤、朗讀比複製再大一些（15→21，昭昭依真機視覺調整）。
  static const double _kToolbarSideIconSize = 21;

  /// 工具列 icon 跟旁邊時間文字（fontSize 10，吃系統字體縮放）同比例。
  /// 寫死 dp 的話，系統字體調小的手機上字縮了 icon 沒縮，看起來就巨大。
  /// 夾在 [0.75, 1.3]：太小點不中、太大擠爆一行；點擊槽固定 44 不跟著縮。
  static const double _kToolbarScaleMin = 0.75;
  static const double _kToolbarScaleMax = 1.3;
  double _toolbarScale() => (MediaQuery.textScalerOf(context).scale(10) / 10)
      .clamp(_kToolbarScaleMin, _kToolbarScaleMax);

  /// 工具列圖標的視覺大小。真機回饋將 1.2 縮小三分之一回到 0.8；
  /// 橫向操作槽與 44pt 高度、語意標籤維持不變，不犧牲點擊命中。
  static const double _kToolbarGlyphFactor = 0.8;

  double _toolbarGlyphScale() => _toolbarScale() * _kToolbarGlyphFactor;

  OverlayEntry? _cacheHitPopover;

  void _dismissCacheHitPopover() {
    _cacheHitPopover?.remove();
    _cacheHitPopover = null;
  }

  /// 點閃電：閃電正上方冒出一顆小提示，點任何空白處收起。
  void _showCacheHitPopover(BuildContext anchorContext) {
    HapticFeedback.selectionClick();
    _dismissCacheHitPopover();
    final overlay = Overlay.of(context, rootOverlay: true);
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (anchorBox == null ||
        overlayBox == null ||
        !anchorBox.hasSize ||
        !overlayBox.hasSize) {
      return;
    }
    final anchorTopCenter = anchorBox.localToGlobal(
      Offset(anchorBox.size.width / 2, 8),
      ancestor: overlayBox,
    );
    // 提示泡泡跟主題走（閃電本身仍用與主題色區隔的琥珀／青綠）。
    final accent = YanciTheme.accent;
    final entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('cache-hit-popover-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: _dismissCacheHitPopover,
            ),
          ),
          Positioned(
            left: anchorTopCenter.dx,
            top: anchorTopCenter.dy,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -1),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  key: const ValueKey('cache-hit-popover'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.themedOverlaySurface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: YanciTheme.themedOverlayBorder,
                      width: 0.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt_rounded, size: 12, color: accent),
                      const SizedBox(width: 3),
                      Text(
                        L.pick(en: 'Cache hit', zhTW: '已命中緩存', zhCN: '已命中缓存'),
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _cacheHitPopover = entry;
    overlay.insert(entry);
  }

  Color _cacheHitColor() {
    final hue = HSLColor.fromColor(YanciTheme.accent).hue;
    if (hue >= 90 && hue <= 210) {
      return const Color(0xFFE8A735).withValues(alpha: 0.8); // 琥珀
    }
    return const Color(0xFF26A69A).withValues(alpha: 0.75); // teal
  }

  Widget _buildCopyIcon({Color? color}) {
    final c =
        color ??
        _chatBackgroundScope?.foreground?.secondary ??
        YanciTheme.textSecondary.withValues(alpha: 0.4);
    return _buildActionIconSlot(
      key: const ValueKey('bubble-action-copy'),
      child: BubbleActionGlyph(
        type: BubbleActionGlyphType.copy,
        color: c,
        size: 15 * _toolbarGlyphScale(),
      ),
    );
  }

  Widget _buildBookmarkIcon({Color? color}) {
    final c =
        color ??
        _chatBackgroundScope?.foreground?.secondary ??
        YanciTheme.textSecondary.withValues(alpha: 0.4);
    return _buildActionIconSlot(
      key: const ValueKey('bubble-action-bookmark'),
      child: BubbleActionGlyph(
        type: BubbleActionGlyphType.bookmark,
        color: c,
        selected: _isSaved,
        size: _kToolbarSideIconSize * _toolbarGlyphScale(),
      ),
    );
  }

  Widget _buildActionIconSlot({required Key key, required Widget child}) {
    return SizedBox.square(
      key: key,
      dimension: 22 * _toolbarScale(),
      child: Center(child: child),
    );
  }

  Widget _buildToolbarTapTarget({
    required String label,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(width: 38, height: 44, child: Center(child: child)),
        ),
      ),
    );
  }

  /// 有圖時文字氣泡貼邊、按文字長短決定寬度；外層 Column 是 stretch，
  /// 不包的話短配文會被拉成跟縮略圖一樣寬。沒圖時維持原本行為。
  Widget _alignBesideImages({required bool hasImages, required Widget child}) {
    if (!hasImages) return child;
    return Align(
      alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );
  }

  Widget _buildAvatar() {
    return ChatAvatar(avatarPath: widget.avatarPath, isUser: widget.isUser);
  }
}

/// Three-dot waiting state shown only before the first streamed character.
/// The second dot is the geometric center of the bubble's content area.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  /// 等待超過 [_showSecondsAfter] 秒才顯示秒數；每秒只更新那行小字。
  static const int _showSecondsAfter = 5;
  final Stopwatch _waited = Stopwatch()..start();
  final ValueNotifier<int> _seconds = ValueNotifier<int>(0);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _seconds.value = _waited.elapsed.inSeconds;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _waited.stop();
    _seconds.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = YanciTheme.bodyText;
    final fontSize = textStyle.fontSize ?? 15;
    final dotSize = (fontSize * 0.27).clamp(3.0, 6.0).toDouble();
    final gap = (fontSize * 0.2).clamp(2.0, 4.0).toDouble();
    final lineHeight = fontSize * (textStyle.height ?? 1.5);
    final dots = SizedBox(
      width: dotSize * 3 + gap * 2,
      height: lineHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List<Widget>.generate(3, (index) {
            final phase = (_controller.value + index * 0.18) % 1.0;
            final wave = _reduceMotion ? 0.0 : math.sin(phase * math.pi * 2);
            return Padding(
              padding: EdgeInsets.only(right: index == 2 ? 0 : 3),
              child: Transform.translate(
                offset: Offset(0, -wave * fontSize * 0.22),
                child: Opacity(
                  opacity: (0.65 + wave * 0.25).clamp(0.35, 0.9),
                  child: Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: YanciTheme.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        dots,
        ValueListenableBuilder<int>(
          valueListenable: _seconds,
          builder: (context, s, _) {
            final visible = s >= _showSecondsAfter;
            final label = s < 60
                ? '${s}s'
                : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
            return AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: _reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 300),
              child: visible
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        label,
                        key: const ValueKey('typing-indicator-elapsed'),
                        style: TextStyle(
                          fontSize: fontSize * 0.75,
                          height: 1,
                          color: YanciTheme.accent.withValues(alpha: 0.55),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
      ],
    );
  }
}

class _MixedContent extends StatelessWidget {
  final String text;
  final String? characterId;
  final bool selectable;
  final Color? color;
  const _MixedContent({
    required this.text,
    this.characterId,
    this.selectable = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final segments = StickerService.parseResponse(text);
    final hasStickers = segments.any((s) => s is StickerSegment);

    if (!hasStickers) {
      return _MarkdownBlock(text: text, selectable: selectable, color: color);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: segments.map((seg) {
        if (seg is TextSegment) {
          final t = seg.text.trim();
          if (t.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _MarkdownBlock(
              text: t,
              selectable: selectable,
              color: color,
            ),
          );
        } else if (seg is StickerSegment) {
          return _StickerImage(
            stickerId: seg.stickerId,
            characterId: characterId,
          );
        }
        return const SizedBox.shrink();
      }).toList(),
    );
  }
}

class _StickerImage extends StatelessWidget {
  final int stickerId;
  final String? characterId;
  const _StickerImage({required this.stickerId, this.characterId});

  @override
  Widget build(BuildContext context) {
    const displaySize = 100.0;
    final cacheDimension = StickerPreviewQuality.cacheDimension(
      context,
      logicalSize: displaySize,
      previousMinimum: 128,
    );
    return FutureBuilder<List<StickerInfo>>(
      future: _findSticker(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox(width: 80, height: 80);
        final match = snap.data!;
        if (match.isEmpty) {
          return Text(
            '[sticker:$stickerId]',
            style: TextStyle(
              fontSize: 11,
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
          );
        }
        final path = match.first.filePath;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: File(path).existsSync()
                ? Image.file(
                    File(path),
                    width: displaySize,
                    height: displaySize,
                    cacheWidth: cacheDimension,
                    cacheHeight: cacheDimension,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  )
                : Container(
                    width: displaySize,
                    height: displaySize,
                    color: YanciTheme.glassInputBg,
                    child: const Icon(Icons.broken_image),
                  ),
          ),
        );
      },
    );
  }

  Future<List<StickerInfo>> _findSticker() async {
    final sticker = await StickerService.getStickerById(stickerId);
    return sticker == null ? const [] : <StickerInfo>[sticker];
  }
}

class _MarkdownBlock extends StatelessWidget {
  final String text;
  final bool selectable;
  final Color? color;
  const _MarkdownBlock({
    required this.text,
    this.selectable = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: text,
      selectable: false,
      softLineBreak: true,
      onTapLink: (_, href, _) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet(
        p: YanciTheme.bodyText.copyWith(color: color),
        strong: YanciTheme.bodyText.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
        em: YanciTheme.bodyText.copyWith(
          color: color,
          fontStyle: FontStyle.italic,
        ),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: YanciTheme.bodyText.fontSize! * 0.9,
          color: YanciTheme.accent,
          backgroundColor: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
        ),
        codeblockDecoration: BoxDecoration(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: YanciTheme.accent.withValues(alpha: 0.4),
              width: 3,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        blockquote: YanciTheme.bodyText.copyWith(
          color: color ?? YanciTheme.textSecondary,
          fontStyle: FontStyle.italic,
        ),
        h1: YanciTheme.headingMedium.copyWith(fontSize: 18, color: color),
        h2: YanciTheme.headingMedium.copyWith(fontSize: 16, color: color),
        h3: YanciTheme.bodyText.copyWith(
          fontSize: 15,
          color: color,
          fontWeight: FontWeight.w600,
        ),
        listBullet: YanciTheme.bodyText.copyWith(color: color),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: YanciTheme.textSecondary.withValues(alpha: 0.15),
            ),
          ),
        ),
        a: YanciTheme.bodyText.copyWith(
          color: YanciTheme.accent,
          decoration: TextDecoration.underline,
          decorationColor: YanciTheme.accent.withValues(alpha: 0.3),
        ),
        pPadding: const EdgeInsets.only(bottom: 4),
        blockSpacing: 8,
      ),
    );
    if (!selectable) return body;

    return SelectionArea(child: body);
  }
}
