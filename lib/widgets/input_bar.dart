import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';

import '../services/scratch_service.dart';

/// 發送按鈕樣式
enum SendButtonStyle { leaf, paw }

/// 輸入欄組件 — ＋按鈕 + 毛玻璃輸入框 + 發送鍵
class InputBar extends StatefulWidget {
  final Function(String) onSend;
  final Function(String)? onImagePicked;
  final VoidCallback? onStickerTap;

  /// 刮刮卡禮物：回傳 scratcher = 'user'（我刮）或 'char'（TA刮）
  final Function(String scratcher)? onScratchGift;

  /// 商店送禮
  final VoidCallback? onShopGift;

  /// 背包（查看/送出物品）
  final VoidCallback? onBackpackTap;

  /// 轉帳：回傳金額
  final Function(int amount)? onTransfer;

  /// 掛起的禮物名（非空時輸入框上方顯示 chip，隨下一條消息送出）
  final String? pendingGiftName;

  /// 取消掛起禮物（退回貝殼/物品）
  final VoidCallback? onCancelGift;

  /// 結婚證彩蛋：解鎖後選單才出現簽署書按鈕
  final bool showMarriageCert;
  final VoidCallback? onMarriageCert;

  /// 結婚證掛起中（chip 顯示，隨下一條消息送出）
  final bool marriageCertPending;
  final VoidCallback? onCancelMarriageCert;
  final bool hasPendingContent;
  final SendButtonStyle sendStyle;
  final bool isGeneratingImage;
  final bool isGeneratingResponse;
  final bool isSendBlocked;
  final VoidCallback? onStopGeneration;
  final TextEditingController? externalController;
  final String? hintText;

  const InputBar({
    super.key,
    required this.onSend,
    this.onImagePicked,
    this.onStickerTap,
    this.onScratchGift,
    this.onShopGift,
    this.onBackpackTap,
    this.onTransfer,
    this.pendingGiftName,
    this.onCancelGift,
    this.showMarriageCert = false,
    this.onMarriageCert,
    this.marriageCertPending = false,
    this.onCancelMarriageCert,
    this.hasPendingContent = false,
    this.sendStyle = SendButtonStyle.leaf,
    this.isGeneratingImage = false,
    this.isGeneratingResponse = false,
    this.isSendBlocked = false,
    this.onStopGeneration,
    this.externalController,
    this.hintText,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> with TickerProviderStateMixin {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _ownsController = false;
  final ImagePicker _picker = ImagePicker();
  bool _drawerOpen = false;

  // ═══ 葉子動效 ═══
  late AnimationController _swayCtrl; // 待機搖擺
  late AnimationController _sendCtrl; // 發送飛出
  late Animation<double> _swayAnim;
  late Animation<double> _sendRotation;
  late Animation<double> _sendScale;
  late Animation<double> _sendOpacity;
  late Animation<Offset> _sendOffset;

  @override
  void initState() {
    super.initState();
    if (widget.externalController != null) {
      _controller = widget.externalController!;
      _ownsController = false;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
    // 待機搖擺：持續循環
    _swayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _swayAnim = Tween(
      begin: -0.06,
      end: 0.06,
    ).animate(CurvedAnimation(parent: _swayCtrl, curve: Curves.easeInOut));

    // 發送動效：一次性
    _sendCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    // 旋轉：飛出轉 1.2 rad，回程繼續同方向轉滿一整圈（2π）落地——
    // 落地角度 = 0，和待機搖擺無縫銜接。
    // 舊版只轉到 1.2 就停，動畫結束瞬間跳回搖擺角，就是那個「復位卡頓」。
    _sendRotation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.2,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 45,
      ),
      TweenSequenceItem(tween: Tween(begin: 1.2, end: 1.2), weight: 15),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.2,
          end: 6.28318530718, // 2π
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
    ]).animate(_sendCtrl);
    // 落地瞬間把搖擺相位歸中（中點 = 0°），徹底消掉接縫的小跳變
    _sendCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _swayCtrl.value = 0.5;
        _swayCtrl.repeat(reverse: true);
      }
    });
    // 縮小後彈回
    _sendScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 45,
      ),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.0), weight: 15),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.1,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
    ]).animate(_sendCtrl);
    // 淡出後淡入
    _sendOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.0), weight: 15),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 40),
    ]).animate(_sendCtrl);
    // 位移飛出
    _sendOffset = TweenSequence<Offset>([
      TweenSequenceItem(
        tween: Tween(
          begin: Offset.zero,
          end: const Offset(20, -25),
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween(begin: const Offset(20, -25), end: const Offset(0, 8)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: const Offset(0, 8),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
    ]).animate(_sendCtrl);
  }

  @override
  void didUpdateWidget(covariant InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.externalController, widget.externalController)) {
      return;
    }

    if (_ownsController) _controller.dispose();
    if (widget.externalController != null) {
      _controller = widget.externalController!;
      _ownsController = false;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    _focusNode.dispose();
    _swayCtrl.dispose();
    _sendCtrl.dispose();
    super.dispose();
  }

  void _handleSend() {
    if (widget.isSendBlocked) return;
    final text = _controller.text.trim();
    if (text.isEmpty && !widget.hasPendingContent) return;
    _sendCtrl.forward(from: 0.0);
    widget.onSend(text);
    if (widget.sendStyle == SendButtonStyle.leaf) {
      // Let the send callback commit its first UI frame before the IME hide
      // animation starts; doing both synchronously causes a frame spike.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.unfocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPad > 0 ? bottomPad : 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ═══ 掛起禮物 chip：隨下一條消息送出，× 取消退回 ═══
          if (widget.pendingGiftName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.3),
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.card_giftcard_rounded,
                        size: 15,
                        color: YanciTheme.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${widget.pendingGiftName}（隨消息送出）',
                        style: TextStyle(
                          fontSize: 12,
                          color: YanciTheme.textPrimary,
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: widget.onCancelGift,
                        child: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // ═══ 掛起結婚證 chip：隨下一條消息送出（右側緩存警告）═══
          if (widget.marriageCertPending)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: YanciTheme.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.3),
                        width: 0.6,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_edu_rounded,
                          size: 15,
                          color: YanciTheme.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          L.pick(
                            en: 'Marriage certificate (sent with message)',
                            zhTW: '結婚證書（隨消息送出）',
                            zhCN: '结婚证书（随消息送出）',
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: YanciTheme.textPrimary,
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: widget.onCancelMarriageCert,
                          child: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      L.pick(
                        en: 'Sending is cache-free; a successful signing rebuilds the cache once',
                        zhTW: '發送本身不影響緩存；簽署成功後將重建一次緩存',
                        zhCN: '发送本身不影响缓存；签署成功后将重建一次缓存',
                      ),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.75),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // ═══ 統一輸入容器（＋ + 輸入框 + 發送鍵）═══
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                      decoration: BoxDecoration(
                        color: YanciTheme.glassInputBg,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: YanciTheme.glassBorder,
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // ＋ 按鈕：在輸入框下方展開雙層玻璃工具盒。
                          Padding(
                            padding: const EdgeInsets.only(bottom: 1),
                            child: Semantics(
                              button: true,
                              expanded: _drawerOpen,
                              label: L.pick(
                                en: 'Open add actions',
                                zhTW: '打開添加工具',
                                zhCN: '打开添加工具',
                              ),
                              child: IconButton(
                                tooltip: L.pick(
                                  en: 'Add content',
                                  zhTW: '添加內容',
                                  zhCN: '添加内容',
                                ),
                                onPressed: _toggleActionPanel,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                icon: AnimatedRotation(
                                  turns: _drawerOpen ? 0.125 : 0,
                                  duration: const Duration(milliseconds: 220),
                                  child: Icon(
                                    Icons.add_rounded,
                                    size: 23,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: _drawerOpen ? 0.78 : 0.55,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 輸入框
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              maxLines: 4,
                              minLines: 1,
                              style: YanciTheme.bodyText,
                              decoration: InputDecoration(
                                hintText:
                                    widget.hintText ?? L.get('input_hint'),
                                hintStyle: YanciTheme.bodyText.copyWith(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              ),
                              textInputAction: TextInputAction.newline,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 發送鍵 / 停止鍵
                          if (widget.isGeneratingImage ||
                              widget.isGeneratingResponse)
                            GestureDetector(
                              key: const ValueKey('input_bar_stop_button'),
                              onTap: widget.onStopGeneration,
                              child: Container(
                                width: 45,
                                height: 45,
                                margin: const EdgeInsets.only(bottom: 1),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.7,
                                    ),
                                    width: 1.5,
                                  ),
                                ),
                                child: Center(
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(2),
                                      border: Border.all(
                                        color: YanciTheme.accent.withValues(
                                          alpha: 0.7,
                                        ),
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _controller,
                                _swayCtrl,
                                _sendCtrl,
                              ]),
                              builder: (_, _) {
                                final hasText = _controller.text
                                    .trim()
                                    .isNotEmpty;
                                return GestureDetector(
                                  key: const ValueKey('input_bar_send_button'),
                                  onTap:
                                      (hasText || widget.hasPendingContent) &&
                                          !widget.isSendBlocked
                                      ? _handleSend
                                      : null,
                                  child: Builder(
                                    builder: (_) {
                                      final isSending = _sendCtrl.isAnimating;
                                      final showBtn =
                                          (hasText ||
                                              widget.hasPendingContent) &&
                                          !widget.isSendBlocked;
                                      return AnimatedOpacity(
                                        opacity: showBtn ? 1.0 : 0.4,
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        child: Transform.translate(
                                          offset: isSending
                                              ? _sendOffset.value
                                              : Offset.zero,
                                          child: Opacity(
                                            opacity: isSending
                                                ? _sendOpacity.value
                                                : 1.0,
                                            child: Transform.rotate(
                                              angle: isSending
                                                  ? _sendRotation.value
                                                  : _swayAnim.value,
                                              child: Transform.scale(
                                                scale: isSending
                                                    ? _sendScale.value
                                                    : 1.0,
                                                child: Container(
                                                  width: 45,
                                                  height: 45,
                                                  margin: const EdgeInsets.only(
                                                    bottom: 1,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: YanciTheme.accent
                                                        .withValues(
                                                          alpha: showBtn
                                                              ? 0.85
                                                              : 0.3,
                                                        ),
                                                    shape: BoxShape.circle,
                                                    boxShadow: showBtn
                                                        ? [
                                                            BoxShadow(
                                                              color: YanciTheme
                                                                  .accent
                                                                  .withValues(
                                                                    alpha: 0.2,
                                                                  ),
                                                              blurRadius: 8,
                                                              offset:
                                                                  const Offset(
                                                                    0,
                                                                    2,
                                                                  ),
                                                            ),
                                                          ]
                                                        : null,
                                                  ),
                                                  child: Center(
                                                    child: Image.asset(
                                                      widget.sendStyle ==
                                                              SendButtonStyle
                                                                  .leaf
                                                          ? 'assets/images/send_leaf.png'
                                                          : 'assets/images/send_paw.png',
                                                      width: 32,
                                                      height: 32,
                                                      fit: BoxFit.contain,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // ＋ 展開盒：固定在輸入框下方，輸入列在上、工具盒在下。
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _drawerOpen
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _buildActionPanel(),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleActionPanel() {
    _focusNode.unfocus();
    setState(() => _drawerOpen = !_drawerOpen);
  }

  Widget _buildActionPanel() {
    final panelColor = YanciTheme.isDark
        ? const Color(0xD91B1820)
        : const Color(0xD9FFFFFF);

    return Semantics(
      container: true,
      label: L.pick(en: 'Message add actions', zhTW: '消息添加工具', zhCN: '消息添加工具'),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: YanciTheme.glassBorder.withValues(alpha: 0.9),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.28 : 0.12,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = (constraints.maxWidth - 27) / 4;
                  return Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          iconData: Icons.image_outlined,
                          label: L.pick(en: 'Photo', zhTW: '圖片', zhCN: '图片'),
                          onTap: () => _runPanelAction(_pickImageFromGallery),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          iconData: Icons.emoji_emotions_outlined,
                          label: L.pick(
                            en: 'Sticker',
                            zhTW: '表情包',
                            zhCN: '表情包',
                          ),
                          onTap: () => _runPanelAction(
                            () => widget.onStickerTap?.call(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          assetPath: 'assets/images/shell_coin.png',
                          label: L.pick(en: 'Transfer', zhTW: '轉帳', zhCN: '转账'),
                          onTap: () => _runPanelAction(_showTransferDialog),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          iconData: Icons.local_activity_outlined,
                          label: L.pick(
                            en: 'Scratch card',
                            zhTW: '刮刮卡',
                            zhCN: '刮刮卡',
                          ),
                          onTap: () => _runPanelAction(_showScratchGiftPicker),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          iconData: Icons.storefront_outlined,
                          label: L.pick(
                            en: 'Gift shop',
                            zhTW: '禮物商店',
                            zhCN: '礼物商店',
                          ),
                          onTap: () =>
                              _runPanelAction(() => widget.onShopGift?.call()),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _drawerAction(
                          iconData: Icons.backpack_outlined,
                          label: L.pick(en: 'Backpack', zhTW: '背包', zhCN: '背包'),
                          onTap: () => _runPanelAction(
                            () => widget.onBackpackTap?.call(),
                          ),
                        ),
                      ),
                      if (widget.showMarriageCert)
                        SizedBox(
                          width: width,
                          child: _drawerAction(
                            iconData: Icons.history_edu_outlined,
                            label: L.pick(
                              en: 'Marriage letter',
                              zhTW: '簽署書',
                              zhCN: '签署书',
                            ),
                            onTap: () => _runPanelAction(
                              () => widget.onMarriageCert?.call(),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawerAction({
    IconData? iconData,
    String? assetPath,
    required String label,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            constraints: const BoxConstraints(minHeight: 66),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: YanciTheme.glassWhite.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: YanciTheme.glassBorder.withValues(alpha: 0.72),
                width: 0.6,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: iconData != null
                      ? Icon(iconData, size: 25, color: YanciTheme.accent)
                      : Image.asset(
                          assetPath!,
                          width: 25,
                          height: 25,
                          filterQuality: FilterQuality.none,
                        ),
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _runPanelAction(VoidCallback action) {
    setState(() => _drawerOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  Future<void> _pickImageFromGallery() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 70,
    );
    if (file != null) widget.onImagePicked?.call(file.path);
  }

  void _showScratchGiftPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF1E1E2E)
            : Colors.white,
        title: Row(
          children: [
            Image.asset(
              'assets/images/shell_coin.png',
              width: 20,
              height: 20,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(width: 8),
            Text(
              L.pick(en: 'Buy Scratch Card', zhTW: '買刮刮卡'),
              style: TextStyle(
                fontSize: 16,
                fontFamily: YanciTheme.fontFamily,
                color: YanciTheme.textPrimary,
              ),
            ),
          ],
        ),
        content: Text(
          L.pick(
            en: 'Costs 30 coins from your balance.\nWho gets to scratch it?',
            zhTW: '從你的餘額扣 30 貝\n誰來刮？',
          ),
          style: TextStyle(
            fontSize: 14,
            fontFamily: YanciTheme.fontFamily,
            color: YanciTheme.textSecondary,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onScratchGift?.call('user');
            },
            child: Text(
              L.pick(en: 'I scratch', zhTW: '我來刮'),
              style: TextStyle(
                color: YanciTheme.accent,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onScratchGift?.call('char');
            },
            child: Text(
              L.pick(en: 'Let them scratch', zhTW: '讓TA刮'),
              style: TextStyle(
                color: YanciTheme.accent,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showTransferDialog() {
    final amountCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? const Color(0xFF1E1C22)
                : const Color(0xFFFDFCFE),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: YanciTheme.isDark
                            ? const Color(0xFF28252C)
                            : const Color(0xFFF3F0F5),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: YanciTheme.accent.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Image.asset(
                            'assets/images/shell_coin.png',
                            width: 18,
                            height: 18,
                            filterQuality: FilterQuality.none,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: amountCtrl,
                              keyboardType: TextInputType.number,
                              autofocus: true,
                              style: TextStyle(
                                fontSize: 16,
                                fontFamily: YanciTheme.fontFamily,
                                color: YanciTheme.textPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                              decoration: InputDecoration(
                                hintText: '0',
                                hintStyle: TextStyle(
                                  fontSize: 16,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () {
                      final amount = int.tryParse(amountCtrl.text.trim()) ?? 0;
                      Navigator.pop(ctx);
                      if (amount > 0) {
                        widget.onTransfer?.call(amount);
                      }
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B2C4F), Color(0xFFC05C7E)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF8B2C4F,
                            ).withValues(alpha: 0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: FutureBuilder<int>(
                  future: ScratchService.getUserCoins(),
                  builder: (ctx, snap) {
                    final coins = snap.data ?? 0;
                    return Text(
                      L.pick(en: 'Balance: $coins', zhTW: '目前餘額：$coins 貝'),
                      style: TextStyle(
                        fontSize: 12,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
