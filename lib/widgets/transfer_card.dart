import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/transfer_service.dart';
import '../services/locale_strings.dart';

/// 轉帳迷你卡片 — 嵌在氣泡下方，類似 ScratchMiniCard
class TransferMiniCard extends StatefulWidget {
  final String messageId;
  final TransferData data;
  final String characterId;

  /// 是否顯示接受/拒絕按鈕（只有接收方才能操作）
  final bool canAct;

  /// 操作完成回調（刷新幣值 + UI）
  final VoidCallback? onUpdated;

  const TransferMiniCard({
    super.key,
    required this.messageId,
    required this.data,
    required this.characterId,
    this.canAct = false,
    this.onUpdated,
  });

  @override
  State<TransferMiniCard> createState() => _TransferMiniCardState();
}

class _TransferMiniCardState extends State<TransferMiniCard>
    with SingleTickerProviderStateMixin {
  bool _processing = false;
  late AnimationController _animCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _flipAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnim = TweenSequence([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 1.15,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.15,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.bounceOut)),
        weight: 70,
      ),
    ]).animate(_animCtrl);

    _flipAnim = Tween(
      begin: 0.0,
      end: 3.141592653589793 * 2,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOutBack));
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    setState(() => _processing = true);
    await _animCtrl.forward(from: 0.0);
    final ok = await TransferService.acceptTransfer(
      widget.messageId,
      widget.characterId,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: widget.data.direction == 'toUser'
                  ? 'The other side lacks enough shells'
                  : 'Not enough shells',
              zhTW: widget.data.direction == 'toUser' ? '對方貝殼不足' : '貝殼不夠了',
            ),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
    widget.onUpdated?.call();
    if (mounted) setState(() => _processing = false);
  }

  Future<void> _decline() async {
    setState(() => _processing = true);
    await TransferService.declineTransfer(widget.messageId);
    widget.onUpdated?.call();
    if (mounted) setState(() => _processing = false);
  }

  @override
  Widget build(BuildContext context) {
    final isPending = widget.data.status == 'pending';
    final isAccepted = widget.data.status == 'accepted';
    final isDeclined = widget.data.status == 'declined';
    final isToUser = widget.data.direction == 'toUser';

    // 依據 Yanci Theme 及狀態決定背景漸層與顏色
    final List<Color> bgGradient;
    final Color iconBoxColor;
    final Color iconColor;
    final String titleText;
    final String statusText;

    if (isAccepted) {
      // 收款後變成半透明深色質感 (類似 WeChat)
      bgGradient = [
        YanciTheme.isDark ? const Color(0xFF2C2433) : const Color(0xFFF3EDF5),
        YanciTheme.isDark ? const Color(0xFF201A25) : const Color(0xFFE8E0EC),
      ];
      iconBoxColor = YanciTheme.isDark
          ? const Color(0xFF3C3145)
          : const Color(0xFFD6C8DE);
      iconColor = const Color(0xFF8B799A);
      titleText = L.pick(
        en: isToUser ? 'Received' : 'Received by the other side',
        zhTW: isToUser ? '已收錢' : '對方已收錢',
      );
      statusText = L.pick(en: 'Added to balance', zhTW: '已存入餘額');
    } else if (isDeclined) {
      bgGradient = [
        YanciTheme.isDark ? const Color(0xFF2A2424) : const Color(0xFFF5EDED),
        YanciTheme.isDark ? const Color(0xFF201A1A) : const Color(0xFFECE0E0),
      ];
      iconBoxColor = YanciTheme.isDark
          ? const Color(0xFF3D2D2D)
          : const Color(0xFFDFCDCD);
      iconColor = const Color(0xFF9A7979);
      titleText = L.pick(
        en: isToUser ? 'Returned' : 'Returned by the other side',
        zhTW: isToUser ? '已退還' : '對方已退還',
      );
      statusText = L.pick(en: 'Returned to balance', zhTW: '已退回餘額');
    } else {
      if (isToUser) {
        bgGradient = YanciTheme.isDark
            ? const [Color(0xFF2A4D35), Color(0xFF365E43)]
            : const [Color(0xFF88D49E), Color(0xFFB1E8C1)];
        iconColor = YanciTheme.isDark
            ? const Color(0xFF88D49E)
            : const Color(0xFF67B57F);
      } else {
        bgGradient = YanciTheme.isDark
            ? const [Color(0xFF682840), Color(0xFF8B3A5A)]
            : const [Color(0xFFFF9A9E), Color(0xFFFECFEF)];
        iconColor = YanciTheme.isDark
            ? const Color(0xFFFF9A9E)
            : const Color(0xFFE58085);
      }
      iconBoxColor = YanciTheme.isDark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.white;
      titleText = L.pick(
        en: isToUser ? 'Transfer to you' : 'Transfer sent',
        zhTW: isToUser ? '轉帳給你' : '發起轉帳',
      );
      statusText = L.pick(en: 'Awaiting collection', zhTW: '請收款');
    }

    return ScaleTransition(
      scale: _scaleAnim,
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        width: 200, // 微信風格的長條比例，縮小版
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: bgGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: isPending
              ? [
                  BoxShadow(
                    color: const Color(0xFFFF9A9E).withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 頂部內容區 (WeChat Layout: Icon left, Text right)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    // Icon
                    AnimatedBuilder(
                      animation: _flipAnim,
                      builder: (ctx, child) {
                        return Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.001)
                            ..rotateY(_flipAnim.value),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: iconBoxColor,
                              shape: BoxShape.circle,
                            ),
                            child: isPending
                                ? Center(
                                    child: Image.asset(
                                      'assets/images/shell_coin.png',
                                      width: 18,
                                      height: 18,
                                      filterQuality: FilterQuality.none,
                                    ),
                                  )
                                : Icon(
                                    Icons.check_rounded,
                                    color: iconColor,
                                    size: 20,
                                  ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 10),
                    // Texts
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                L.pick(
                                  en: '${widget.data.amount} shells',
                                  zhTW: '${widget.data.amount} 貝',
                                ),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isPending
                                      ? (isToUser
                                            ? (YanciTheme.isDark
                                                  ? const Color(0xFF88D49E)
                                                  : const Color(0xFF388E3C))
                                            : const Color(0xFF8B2C4F))
                                      : YanciTheme.textPrimary,
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            titleText,
                            style: TextStyle(
                              fontSize: 12,
                              color: isPending
                                  ? (isToUser
                                        ? (YanciTheme.isDark
                                              ? const Color(
                                                  0xFF88D49E,
                                                ).withValues(alpha: 0.8)
                                              : const Color(
                                                  0xFF388E3C,
                                                ).withValues(alpha: 0.8))
                                        : const Color(
                                            0xFF8B2C4F,
                                          ).withValues(alpha: 0.7))
                                  : YanciTheme.textSecondary,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 分隔線與底部操作區
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: isPending
                    ? Colors.white.withValues(alpha: 0.2)
                    : YanciTheme.isDark
                    ? Colors.black.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.4),
                child: isPending && widget.canAct
                    ? _processing
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    isToUser
                                        ? (YanciTheme.isDark
                                              ? const Color(0xFF88D49E)
                                              : const Color(0xFF388E3C))
                                        : const Color(0xFF8B2C4F),
                                  ),
                                ),
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                GestureDetector(
                                  onTap: _accept,
                                  child: Text(
                                    L.pick(en: 'Accept', zhTW: '收下'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isToUser
                                          ? (YanciTheme.isDark
                                                ? const Color(0xFF88D49E)
                                                : const Color(0xFF388E3C))
                                          : const Color(0xFF8B2C4F),
                                      fontWeight: FontWeight.bold,
                                      fontFamily: YanciTheme.fontFamily,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1,
                                  height: 12,
                                  color: Colors.black12,
                                ),
                                GestureDetector(
                                  onTap: _decline,
                                  child: Text(
                                    L.pick(en: 'Return', zhTW: '退還'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isToUser
                                          ? (YanciTheme.isDark
                                                ? const Color(
                                                    0xFF88D49E,
                                                  ).withValues(alpha: 0.8)
                                                : const Color(
                                                    0xFF388E3C,
                                                  ).withValues(alpha: 0.8))
                                          : const Color(
                                              0xFF8B2C4F,
                                            ).withValues(alpha: 0.7),
                                      fontFamily: YanciTheme.fontFamily,
                                    ),
                                  ),
                                ),
                              ],
                            )
                    : Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 12,
                          color: isPending
                              ? const Color(0xFF8B2C4F).withValues(alpha: 0.5)
                              : YanciTheme.textSecondary.withValues(alpha: 0.5),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
