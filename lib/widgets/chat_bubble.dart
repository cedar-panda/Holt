import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:gal/gal.dart';
import 'neural_generation_box.dart';
import '../theme/app_theme.dart';
import '../services/sticker_service.dart';
import '../services/locale_strings.dart';
import '../services/tts_service.dart';
import '../services/settings_manager.dart';
import '../memory/database.dart';
import '../services/scratch_service.dart';
import '../services/transfer_service.dart';
import '../services/marriage_service.dart';
import 'gift_card.dart';
import 'marriage_cert_card.dart';
import 'scratch_card.dart';
import 'transfer_card.dart';
import 'tts_play_button.dart';

/// 聊天氣泡 — 思考鏈 + markdown + 表情包圖片 + 長按菜單
class ChatBubble extends StatefulWidget {
  final String text;
  final bool isUser;
  final bool isStreaming;
  final DateTime? timestamp;
  final VoidCallback? onEdit;
  final String? messageId;
  final String? imagePath;
  final String? conversationId;
  final String? conversationTitle;
  final String? characterId;
  final String? avatarPath;
  final bool showAvatar;
  final bool showToolbar;
  final bool cacheHit;
  final bool selectable;
  final bool selected;
  final VoidCallback? onSelectionToggle;

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
    this.conversationId,
    this.conversationTitle,
    this.characterId,
    this.avatarPath,
    this.showAvatar = false,
    this.showToolbar = true,
    this.cacheHit = false,
    this.selectable = false,
    this.selected = false,
    this.onSelectionToggle,
    this.memoryLog = '',
    this.scratchData,
    this.transferData,
    this.onTransferUpdated,
    this.giftName,
    this.giftAccepted = false,
    this.marriageCert,
    this.onCertSignTap,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with SingleTickerProviderStateMixin {
  bool _thinkingExpanded = false;
  bool _memLogExpanded = false;
  bool _emoLogExpanded = false;
  bool _isSaved = false;
  late AnimationController _entryCtrl;

  // ═══ 四階段氣泡動畫 ═══
  // ① 淡入  ② Q彈  ③ 橫向展開  ④ 內容顯現
  late Animation<double> _bubbleOpacity;
  late Animation<double> _scaleY;
  late Animation<double> _scaleX;
  late Animation<double> _contentOpacity;
  late Animation<double> _avatarOpacity; // 頭像原地漸顯，不參與氣泡縮放

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      // 650ms 太拖——全 app 過渡統一 200ms 檔，入場敘事壓到 320ms
      duration: const Duration(milliseconds: 320),
    );

    // ① 氣泡淡入（一瞬）
    _bubbleOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.15, curve: Curves.easeOut),
      ),
    );

    // ② Q彈 — 垂直方向彈起 + 回彈
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

    // ③ 橫向展開 — 從壓縮到全寬，微彈
    _scaleX =
        TweenSequence<double>([
          // 彈跳期間保持窄
          TweenSequenceItem(
            tween: Tween(
              begin: 0.3,
              end: 0.5,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 30,
          ),
          // 展開，輕微過衝
          TweenSequenceItem(
            tween: Tween(
              begin: 0.5,
              end: 1.03,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 30,
          ),
          // 回落
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

    // ④ 內容顯現
    _contentOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.55, 0.85, curve: Curves.easeIn),
      ),
    );

    // 頭像：原地漸顯 ~200ms（320×0.65），不彈不縮，只淡入
    _avatarOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOut),
      ),
    );

    _entryCtrl.forward();
    _checkSaved();
  }

  Future<void> _checkSaved() async {
    if (widget.isUser || widget.messageId == null) return;
    try {
      final saved = await DatabaseHelper.isMessageSaved(widget.messageId!);
      if (mounted) setState(() => _isSaved = saved);
    } catch (_) {
      // 表可能尚未建立
    }
  }

  Future<void> _toggleSave() async {
    if (widget.messageId == null) return;
    HapticFeedback.lightImpact();
    try {
      if (_isSaved) {
        await DatabaseHelper.unsaveMessage(widget.messageId!);
      } else {
        await DatabaseHelper.saveMessage(
          messageId: widget.messageId!,
          content: widget.text
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

  @override
  void dispose() {
    _entryCtrl.dispose();
    super.dispose();
  }

  /// 圖片長按菜單：保存
  void _showImageMenu(BuildContext ctx, String imagePath) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: YanciTheme.isDark ? const Color(0xF0302830) : Colors.white,
          borderRadius: BorderRadius.circular(14),
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

  /// 全屏查看圖片（不壓縮畫質 + 可保存）
  void _openFullScreenImage(BuildContext ctx, String imagePath) {
    Navigator.of(ctx).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (context, anim, secondAnim) {
          return FadeTransition(
            opacity: anim,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  // 點擊背景關閉
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const SizedBox.expand(),
                  ),
                  // 可縮放圖片
                  Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: Image.file(
                        File(imagePath),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                  // 頂部按鈕列
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 8,
                    right: 16,
                    child: Row(
                      children: [
                        // 保存
                        GestureDetector(
                          onTap: () {
                            _saveImage(imagePath);
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.save_alt_rounded,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // 關閉
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  /// 保存圖片到本地相冊
  Future<void> _saveImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) throw Exception('文件不存在');

      await Gal.putImage(imagePath);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.pick(en: 'Saved to Gallery', zhTW: '已保存到相冊')),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1500),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.pick(en: 'Save failed: $e', zhTW: '保存失敗：$e')),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2000),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  Future<void> _speakText(String text) async {
    // v3 保留 [tag] 語氣標記給 TTS（顯示側已剝除）
    final provider = await TtsSettings.getTtsProvider();
    final model = await TtsSettings.getTtsElevenlabsModel();
    final keepTags = provider == 'elevenlabs' && model == 'eleven_v3';
    final clean = TtsService.extractSpeechContent(
      text,
      keepAudioTags: keepTags,
    );
    if (clean.isEmpty) return;
    TtsService.speak(
      clean,
      messageId: widget.messageId,
      conversationId: widget.conversationId,
      conversationTitle: widget.conversationTitle,
      characterId: widget.characterId,
    );
  }

  (String?, String) _parseThinking(String text) {
    // 完整標籤
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
    // 流式輸出中：開標籤存在但未閉合
    if (widget.isStreaming) {
      for (final tag in ['<think>', '<thinking>']) {
        final idx = text.indexOf(tag);
        if (idx >= 0) {
          final before = text.substring(0, idx).trim();
          final thinking = text.substring(idx + tag.length).trim();
          return (thinking.isEmpty ? '……' : thinking, before);
        }
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
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(
                painter: _SquareCopyPainter(color: YanciTheme.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              L.get('chat_copy'),
              style: TextStyle(fontSize: 13, color: YanciTheme.textPrimary),
            ),
          ],
        ),
      ),
    ];
    if (widget.isUser && widget.onEdit != null) {
      items.add(
        PopupMenuItem(
          value: 'edit',
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_outlined,
                size: 16,
                color: YanciTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                L.pick(en: 'Edit and resend', zhTW: '編輯重發'),
                style: TextStyle(fontSize: 13, color: YanciTheme.textPrimary),
              ),
            ],
          ),
        ),
      );
    }
    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: YanciTheme.isDark
          ? const Color(0xF0302830)
          : Colors.white.withValues(alpha: 0.97),
      items: items,
    ).then((v) {
      if (v == 'copy') {
        Clipboard.setData(ClipboardData(text: widget.text));
        if (!ctx.mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text(L.get('chat_copied')),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(milliseconds: 800),
            margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      } else if (v == 'edit') {
        widget.onEdit?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final r = widget.isUser
        ? YanciTheme.bubbleRadiusUser
        : YanciTheme.radiusBubble;
    final (thinking, rawDisplay) = widget.isUser
        ? (null, widget.text)
        : _parseThinking(widget.text);
    // 剝離情緒標記（[sigh] [laughing] 等），TTS 用但不顯示
    var displayText = rawDisplay
        // 語音標籤（v3 audio tags 含中文變體）永不顯示——它們只給 TTS
        .replaceAll(TtsService.audioTagRe, '')
        .replaceAll(RegExp(r'\[call_event:[^\]]*\]'), '') // 通話事件隱藏
        .replaceAll(RegExp(r'\[transfer:\d+\]'), '') // 轉帳標記隱藏（卡片顯示）
        .replaceAll(RegExp(r'\[gift:[^\]\n]{1,40}\]'), '') // 送禮標記隱藏
        .replaceAll(RegExp(r'\[scratch_gift:\w+\]'), '') // 刮刮卡禮物標記隱藏
        // 結婚證標記家族（cert/cert_char/cert_signed，含說明尾巴）隱藏
        .replaceAll(RegExp(r'\[marriage_cert[^\]]*\]（[^）]*）'), '')
        .replaceAll(RegExp(r'\[marriage_cert[^\]]*\]'), '')
        .trim();
    // ═══ 商店同逛邀請：目錄只給模型看，氣泡顯示成邀請文案 ═══
    if (widget.isUser && displayText.startsWith('[shop_invite]')) {
      final name = widget.conversationTitle ?? '';
      displayText = L.pick(
        en: '🛍 Invited ${name.isEmpty ? 'them' : name} to browse the shop together',
        zhTW: '🛍 邀請${name.isEmpty ? '對方' : ' $name '}一起逛商店',
      );
    }
    // 流式期間隱藏記憶動作標籤（落庫時已剝離，這裡防打字機閃現）
    if (!widget.isUser) {
      displayText = displayText
          .replaceAll(RegExp(r'<memo>[\s\S]*?(</memo>|$)'), '')
          .replaceAll(RegExp(r'<memo_del>[\s\S]*?(</memo_del>|$)'), '')
          .replaceAll(RegExp(r'<memo_merge>[\s\S]*?(</memo_merge>|$)'), '')
          .replaceAll(RegExp(r'<memo_update>[\s\S]*?(</memo_update>|$)'), '')
          .replaceAll(RegExp(r'<persona_note>[\s\S]*?(</persona_note>|$)'), '')
          .replaceAll(RegExp(r'<tool_calls?>[\s\S]*?(</tool_calls?>|$)'), '')
          .replaceAll(RegExp(r'<draw>[\s\S]*?(</draw>|$)'), '')
          .replaceAll(RegExp(r'<emo>[\s\S]*?(</emo>|$)'), '')
          .replaceAll(RegExp(r'<emo_resolve>[\s\S]*?(</emo_resolve>|$)'), '')
          .trim();
    }
    final hasBubbleContent =
        widget.imagePath != null ||
        displayText.isNotEmpty ||
        widget.isStreaming;

    // ═══ 分離記憶日誌、畫圖狀態、情緒座標 ═══
    String pureMemoryLog = '';
    String pureEmotionLog = '';
    String emoLine = '';
    if (widget.memoryLog.isNotEmpty) {
      final allLines = widget.memoryLog.split('\n');
      final memLines = <String>[];
      final emotionLines = <String>[];
      var done = false;
      for (final line in allLines) {
        final trimmed = line.trim();
        if (trimmed == 'Done') {
          done = true;
          continue;
        }
        if (line.startsWith('🎨')) {
          continue;
        } else if (line.startsWith('情緒座標')) {
          emoLine = line;
        } else if (_isEmotionLogLine(line)) {
          emotionLines.add(line);
        } else {
          memLines.add(line);
        }
      }
      if (done && memLines.isNotEmpty) memLines.add('Done');
      if (done && emotionLines.isNotEmpty) emotionLines.add('Done');
      pureMemoryLog = memLines.join('\n');
      pureEmotionLog = emotionLines.join('\n');
    }

    final shouldShowScratch =
        widget.scratchData != null &&
        (widget.scratchData!.who == 'user' ? widget.isUser : !widget.isUser);

    final shouldShowTransfer = widget.transferData != null;

    final shouldShowGift = widget.giftName != null && widget.isUser;

    final shouldShowMarriageCert = widget.marriageCert != null;

    final hasAnyContent =
        hasBubbleContent ||
        (!widget.isUser && pureMemoryLog.isNotEmpty) ||
        (!widget.isUser && pureEmotionLog.isNotEmpty) ||
        (!widget.isUser && emoLine.isNotEmpty) ||
        (thinking != null) ||
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
        // 縮放只作用於氣泡本體（下方 Flexible 內），頭像原地漸顯不參與
        return Padding(
          padding: EdgeInsets.only(
            left: widget.isUser
                ? sw * (widget.showAvatar ? 0.15 : 0.2)
                : YanciTheme.spacingMd,
            right: widget.isUser
                ? YanciTheme.spacingMd
                : sw * (widget.showAvatar ? 0.15 : 0.2),
            top: YanciTheme.spacingSm,
            bottom: YanciTheme.spacingSm,
          ),
          child: Align(
            alignment: widget.isUser
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.selectable && !widget.isUser) ...[
                  _buildSelectionMark(),
                  const SizedBox(width: 8),
                ],
                // AI 頭像（左側）：原地漸顯
                if (widget.showAvatar && !widget.isUser) ...[
                  Opacity(opacity: _avatarOpacity.value, child: _buildAvatar()),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  // 外層 Column：禮物/證書卡在 IntrinsicWidth 之外——
                  // 氣泡寬度只由文字決定，不被固定寬的卡片撐開
                  child: Column(
                    crossAxisAlignment: widget.isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
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
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            if (!widget.isUser && pureMemoryLog.isNotEmpty)
                              _buildMemoryLog(pureMemoryLog),
                            if (!widget.isUser && pureEmotionLog.isNotEmpty)
                              _buildEmotionLog(pureEmotionLog),
                            // (V2: 生成狀態已移至輸入欄上方 banner，氣泡不再顯示)
                            if (!widget.isUser && emoLine.isNotEmpty)
                              _buildEmoStatus(emoLine),
                            if (thinking != null) _buildThinking(thinking),
                            if (hasBubbleContent)
                              Builder(
                                builder: (context) {
                                  final bubble = Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: YanciTheme.spacingMd,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          widget.isUser ||
                                              YanciTheme.aiBubbleGradient ==
                                                  null
                                          ? (widget.isUser
                                                ? YanciTheme.userBubble
                                                : YanciTheme.aiBubble)
                                          : null,
                                      gradient: !widget.isUser
                                          ? YanciTheme.aiBubbleGradient
                                          : null,
                                      borderRadius: BorderRadius.only(
                                        topLeft: Radius.circular(r),
                                        topRight: Radius.circular(r),
                                        bottomLeft: Radius.circular(
                                          widget.isUser ? r : 4,
                                        ),
                                        bottomRight: Radius.circular(
                                          widget.isUser ? 4 : r,
                                        ),
                                      ),
                                      border: Border.all(
                                        color: widget.isUser
                                            ? YanciTheme.userBubbleBorder
                                            : YanciTheme.aiBubbleBorder,
                                        width: 0.5,
                                      ),
                                      // 陰影跟主題走：淺色模式輕托一下就好；
                                      // 深色模式黑影在深底上只會發灰，要深一點才成型
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: YanciTheme.isDark
                                                ? 0.20
                                                : 0.05,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Opacity(
                                      opacity: _contentOpacity.value,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: widget.isUser
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        children: [
                                          // ═══ 圖片（用戶發送 / AI 生成）═══
                                          if (widget.imagePath != null)
                                            GestureDetector(
                                              onTap: () =>
                                                  widget.imagePath ==
                                                      'generating'
                                                  ? null
                                                  : _openFullScreenImage(
                                                      context,
                                                      widget.imagePath!,
                                                    ),
                                              onLongPress: () =>
                                                  widget.imagePath ==
                                                      'generating'
                                                  ? null
                                                  : _showImageMenu(
                                                      context,
                                                      widget.imagePath!,
                                                    ),
                                              child: Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: displayText.isNotEmpty
                                                      ? 8
                                                      : 0,
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  child: ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                          maxWidth: 200,
                                                          maxHeight: 200,
                                                        ),
                                                    child:
                                                        widget.imagePath ==
                                                            'generating'
                                                        ? const NeuralGenerationBox()
                                                        : Image.file(
                                                            File(
                                                              widget.imagePath!,
                                                            ),
                                                            fit: BoxFit.contain,
                                                            filterQuality:
                                                                FilterQuality
                                                                    .high,
                                                            errorBuilder: (_, _, _) => Container(
                                                              width: 80,
                                                              height: 80,
                                                              color: YanciTheme
                                                                  .glassInputBg,
                                                              child: Icon(
                                                                Icons
                                                                    .broken_image,
                                                                color: YanciTheme
                                                                    .textSecondary
                                                                    .withValues(
                                                                      alpha:
                                                                          0.3,
                                                                    ),
                                                              ),
                                                            ),
                                                          ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // ═══ 文字內容 ═══
                                          if (displayText.isNotEmpty)
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                Flexible(
                                                  // 雙端混合渲染：markdown + [sticker:ID] 本地圖
                                                  child: _MixedContent(
                                                    text: displayText,
                                                    characterId:
                                                        widget.characterId,
                                                    selectable: !widget.isUser,
                                                  ),
                                                ),
                                                if (widget.isStreaming) ...[
                                                  const SizedBox(width: 4),
                                                  _TypingIndicator(),
                                                ],
                                              ],
                                            ),
                                          if (displayText.isEmpty &&
                                              widget.isStreaming)
                                            _TypingIndicator(),
                                        ],
                                      ),
                                    ),
                                  );
                                  if (!widget.isUser) return bubble;
                                  return GestureDetector(
                                    onLongPressStart: (d) => _showContextMenu(
                                      context,
                                      d.globalPosition,
                                    ),
                                    child: bubble,
                                  );
                                },
                              ),
                            if (hasBubbleContent &&
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
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.4),
                                        ),
                                      ),
                                      // ═══ AI 消息操作按鈕（只在非拆分模式顯示）═══
                                      if (!widget.isUser &&
                                          widget.showToolbar) ...[
                                        const SizedBox(width: 10),
                                        GestureDetector(
                                          onTap: () {
                                            HapticFeedback.lightImpact();
                                            Clipboard.setData(
                                              ClipboardData(text: displayText),
                                            );
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  L.get('chat_copied'),
                                                ),
                                                backgroundColor:
                                                    YanciTheme.accent,
                                                behavior:
                                                    SnackBarBehavior.floating,
                                                duration: const Duration(
                                                  milliseconds: 800,
                                                ),
                                                margin: const EdgeInsets.only(
                                                  bottom: 80,
                                                  left: 16,
                                                  right: 16,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                              ),
                                            );
                                          },
                                          child: _buildCopyIcon(),
                                        ),
                                        const SizedBox(width: 6),
                                        GestureDetector(
                                          onTap: _toggleSave,
                                          child: _buildBookmarkIcon(
                                            color: _isSaved
                                                ? YanciTheme.accent
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        GestureDetector(
                                          onTap: () => _speakText(widget.text),
                                          child: SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: Center(
                                              child: TtsPlayButton(
                                                messageId: widget.messageId,
                                                onTap: () =>
                                                    _speakText(widget.text),
                                                size: 18,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                      // ═══ 緩存命中閃電 ═══
                                      if (widget.cacheHit) ...[
                                        const SizedBox(width: 6),
                                        Icon(
                                          Icons.bolt_rounded,
                                          size: 16,
                                          color: _cacheHitColor(),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            // ═══ 刮刮樂迷你卡片 ═══
                            if (shouldShowScratch &&
                                widget.messageId != null &&
                                widget.characterId != null)
                              ScratchMiniCard(
                                messageId: widget.messageId!,
                                data: widget.scratchData!,
                                characterId: widget.characterId!,
                              ),
                            // ═══ 轉帳卡片 ═══
                            if (shouldShowTransfer &&
                                widget.messageId != null &&
                                widget.characterId != null)
                              TransferMiniCard(
                                messageId: widget.messageId!,
                                data: widget.transferData!,
                                characterId: widget.characterId!,
                                // user 收到角色轉帳 → user 能操作
                                // 角色收到 user 轉帳 → AI 自動決定，不給按鈕
                                canAct:
                                    widget.transferData!.direction ==
                                        'toUser' &&
                                    widget.transferData!.status == 'pending',
                                onUpdated: widget.onTransferUpdated,
                              ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // ═══ 禮物卡片（跟隨氣泡，固定寬不撐氣泡）═══
                      if (shouldShowGift)
                        GiftMiniCard(
                          giftName: widget.giftName!,
                          accepted: widget.giftAccepted,
                        ),
                      // ═══ 結婚證書（一紙證書，跟隨氣泡）═══
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
                // User 頭像（右側）：原地漸顯
                if (widget.showAvatar && widget.isUser) ...[
                  const SizedBox(width: 8),
                  Opacity(opacity: _avatarOpacity.value, child: _buildAvatar()),
                ],
                if (widget.selectable && widget.isUser) ...[
                  const SizedBox(width: 8),
                  _buildSelectionMark(),
                ],
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

  /// 統一工具欄圖標樣式
  bool _isEmotionLogLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('📍') ||
        trimmed.startsWith('🌊') ||
        trimmed.startsWith('🔒') ||
        trimmed.startsWith('情緒') ||
        trimmed.contains('打點 ') ||
        trimmed.contains('消解 ');
  }

  /// 記憶過程塊：折疊式，仿思考鏈
  /// 收起顯示「記憶 · Done」，展開逐行顯示注入/寫入/刪除/合併過程
  Widget _buildMemoryLog(String log) {
    return _buildToolLog(
      log,
      label: L.pick(en: 'Memory', zhTW: '記憶'),
      icon: Icons.auto_awesome_outlined,
      expanded: _memLogExpanded,
      onTap: () => setState(() => _memLogExpanded = !_memLogExpanded),
    );
  }

  /// 情緒打點過程塊：與記憶工具分開顯示。
  Widget _buildEmotionLog(String log) {
    return _buildToolLog(
      log,
      label: L.pick(en: 'Emotion', zhTW: '情緒'),
      icon: Icons.favorite_border_rounded,
      expanded: _emoLogExpanded,
      onTap: () => setState(() => _emoLogExpanded = !_emoLogExpanded),
    );
  }

  Widget _buildToolLog(
    String log, {
    required String label,
    required IconData icon,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    final lines = log.split('\n');
    final done = lines.isNotEmpty && lines.last.trim() == 'Done';
    final bodyLines = done ? lines.sublist(0, lines.length - 1) : lines;
    // 過濾掉空行
    final validLines = bodyLines.where((l) => l.trim().isNotEmpty).toList();
    if (validLines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: YanciTheme.accent.withValues(alpha: 0.12),
              width: 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 11,
                    color: YanciTheme.accent.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '$label${done ? ' · Done' : ''}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: YanciTheme.accent.withValues(alpha: 0.75),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 6),
                ...validLines.map(
                  (l) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      l,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.35,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ),
                if (done)
                  Text(
                    'Done ✓',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: YanciTheme.accent.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 情緒座標塊：獨立於記憶日誌（未來會全隱藏）
  Widget _buildEmoStatus(String emoLine) {
    // 擷取座標值，如「情緒座標: (0.3, -0.2)」→「(0.3, -0.2)」
    final coord = emoLine
        .replaceFirst('情緒座標:', '')
        .replaceFirst('情緒座標：', '')
        .trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: YanciTheme.accent.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: YanciTheme.accent.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.favorite_border_rounded,
              size: 10,
              color: YanciTheme.accent.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                coord,
                style: TextStyle(
                  fontSize: 10,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  fontFamily: YanciTheme.fontFamily,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 方形複製圖標（兩個重疊的正方形線框，跟 Claude 一樣）
  /// 緩存命中閃電顏色：避開主題色，綠色色弱友好
  Color _cacheHitColor() {
    final hue = HSLColor.fromColor(YanciTheme.accent).hue;
    // 主題色偏綠/青 (hue 90~210) → 用琥珀色
    // 其他 → 用 teal（偏青的綠，帶藍調）
    if (hue >= 90 && hue <= 210) {
      return const Color(0xFFE8A735).withValues(alpha: 0.8); // 琥珀
    }
    return const Color(0xFF26A69A).withValues(alpha: 0.75); // teal
  }

  Widget _buildCopyIcon({Color? color}) {
    final c = color ?? YanciTheme.textSecondary.withValues(alpha: 0.4);
    return SizedBox(
      width: 22,
      height: 22,
      child: Center(
        child: SizedBox(
          width: 15,
          height: 15,
          child: CustomPaint(painter: _SquareCopyPainter(color: c)),
        ),
      ),
    );
  }

  /// 星星收藏圖標（kid star，點擊後實心）
  Widget _buildBookmarkIcon({Color? color}) {
    final c = color ?? YanciTheme.textSecondary.withValues(alpha: 0.4);
    return SizedBox(
      width: 22,
      height: 22,
      child: Center(
        child: Icon(
          _isSaved ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 20,
          color: c,
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    final hasAvatar =
        widget.avatarPath != null &&
        widget.avatarPath!.isNotEmpty &&
        File(widget.avatarPath!).existsSync();
    return Container(
      width: 40,
      height: 40,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: YanciTheme.accent.withValues(alpha: 0.08),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.12),
          width: 1,
        ),
        image: hasAvatar
            ? DecorationImage(
                image: FileImage(File(widget.avatarPath!)),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: hasAvatar
          ? null
          : Icon(
              widget.isUser ? Icons.person_rounded : Icons.smart_toy_outlined,
              size: 20,
              color: YanciTheme.accent.withValues(alpha: 0.3),
            ),
    );
  }

  Widget _buildThinking(String thinking) {
    // 思考鏈顏色：比氣泡文字淺一點，跟主題走
    final thinkColor = YanciTheme.textOnBubble.withValues(alpha: 0.55);
    final thinkLabelColor = YanciTheme.textOnBubble.withValues(alpha: 0.45);
    return GestureDetector(
      onTap: () => setState(() => _thinkingExpanded = !_thinkingExpanded),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: YanciTheme.accent.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: YanciTheme.accent.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 12,
                  color: thinkLabelColor,
                ),
                const SizedBox(width: 4),
                Text(
                  L.get('chat_thinking'),
                  style: TextStyle(fontSize: 10, color: thinkLabelColor),
                ),
                const SizedBox(width: 4),
                Icon(
                  _thinkingExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 14,
                  color: thinkLabelColor,
                ),
              ],
            ),
            if (_thinkingExpanded) ...[
              const SizedBox(height: 6),
              Text(
                thinking,
                style: TextStyle(fontSize: 11, color: thinkColor, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 混合渲染：markdown 文字 + [sticker:ID] 本地圖片
class _MixedContent extends StatelessWidget {
  final String text;
  final String? characterId;
  final bool selectable;
  const _MixedContent({
    required this.text,
    this.characterId,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    final segments = StickerService.parseResponse(text);
    final hasStickers = segments.any((s) => s is StickerSegment);

    if (!hasStickers) {
      return _MarkdownBlock(text: text, selectable: selectable);
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
            child: _MarkdownBlock(text: t, selectable: selectable),
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

/// 表情包圖片（從本地加載）
class _StickerImage extends StatelessWidget {
  final int stickerId;
  final String? characterId;
  const _StickerImage({required this.stickerId, this.characterId});

  @override
  Widget build(BuildContext context) {
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
                    width: 100,
                    height: 100,
                    cacheWidth: 128,
                    cacheHeight: 128,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.none,
                  )
                : Container(
                    width: 100,
                    height: 100,
                    color: YanciTheme.glassInputBg,
                    child: const Icon(Icons.broken_image),
                  ),
          ),
        );
      },
    );
  }

  /// 先查角色專屬表情包，再查我的表情，最後兼容舊 default 桶。
  Future<List<StickerInfo>> _findSticker() async {
    final cid = characterId ?? 'default';
    final buckets = <String>[
      cid,
      StickerService.userBucket,
      StickerService.legacyDefaultBucket,
    ];
    final seen = <String>{};
    for (final bucket in buckets) {
      if (!seen.add(bucket)) continue;
      final stickers = await StickerService.getStickers(characterId: bucket);
      final match = stickers.where((s) => s.id == stickerId).toList();
      if (match.isNotEmpty) return match;
    }
    return const [];
  }
}

/// Markdown 渲染塊
class _MarkdownBlock extends StatelessWidget {
  final String text;
  final bool selectable;
  const _MarkdownBlock({required this.text, this.selectable = false});

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
        p: YanciTheme.bodyText,
        strong: YanciTheme.bodyText.copyWith(fontWeight: FontWeight.w600),
        em: YanciTheme.bodyText.copyWith(fontStyle: FontStyle.italic),
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
          color: YanciTheme.textSecondary,
          fontStyle: FontStyle.italic,
        ),
        h1: YanciTheme.headingMedium.copyWith(fontSize: 18),
        h2: YanciTheme.headingMedium.copyWith(fontSize: 16),
        h3: YanciTheme.bodyText.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        listBullet: YanciTheme.bodyText,
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

class _TypingIndicator extends StatefulWidget {
  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => Opacity(
        opacity: _controller.value,
        child: Container(width: 2, height: 16, color: YanciTheme.accent),
      ),
    );
  }
}

/// 方形複製圖標繪製器：兩個重疊的正方形線框
class _SquareCopyPainter extends CustomPainter {
  final Color color;
  const _SquareCopyPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final s = size.width;
    final boxSize = s * 0.7;
    final gap = s * 0.22;
    final r = Radius.circular(s * 0.14);

    final backRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, boxSize, boxSize),
      r,
    );
    final frontRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(gap, gap, boxSize, boxSize),
      r,
    );

    // 用裁剪只畫後方方形不被前方覆蓋的部分（不依賴背景色）
    canvas.save();
    final clip = Path()
      ..addRect(Rect.fromLTWH(-1, -1, s + 2, s + 2))
      ..addRRect(frontRect)
      ..fillType = PathFillType.evenOdd;
    canvas.clipPath(clip);
    canvas.drawRRect(backRect, paint);
    canvas.restore();

    // 前方方形完整繪製
    canvas.drawRRect(frontRect, paint);
  }

  @override
  bool shouldRepaint(covariant _SquareCopyPainter old) => old.color != color;
}
