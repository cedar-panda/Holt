import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/transfer_service.dart';
import '../services/locale_strings.dart';
import 'themed_notice.dart';
import 'shell_coin_icon.dart';

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
    if (MediaQuery.disableAnimationsOf(context)) {
      _animCtrl.value = 1;
    } else {
      await _animCtrl.forward(from: 0.0);
    }
    final ok = await TransferService.acceptTransfer(
      widget.messageId,
      widget.characterId,
    );
    if (!ok && mounted) {
      showThemedPillNotice(
        context,
        L.pick(
          en: widget.data.direction == 'toUser'
              ? 'The other side lacks enough shells'
              : 'Not enough shells',
          zhTW: widget.data.direction == 'toUser' ? '對方貝殼不足' : '貝殼不夠了',
        ),
        tone: ThemedNoticeTone.error,
        duration: const Duration(seconds: 2),
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

    // 跟主題走：待收款＝主題色調較濃的卡；已收＝淡主題色；已退＝中性。
    // 以前寫死綠色（給你）／粉紅（你發出）與紫灰，換主題就很出戲。
    final accent = YanciTheme.accent;
    final panel = YanciTheme.surfacePanel;
    final strong = YanciTheme.isDark
        ? Color.lerp(accent, Colors.white, 0.28)!
        : Color.lerp(accent, Colors.black, 0.30)!;
    if (isAccepted) {
      bgGradient = [
        Color.lerp(panel, accent, 0.10)!,
        Color.lerp(panel, accent, 0.05)!,
      ];
      iconBoxColor = accent.withValues(alpha: 0.14);
      iconColor = accent.withValues(alpha: 0.8);
      titleText = L.pick(
        en: isToUser ? 'Received' : 'Received by the other side',
        zhTW: isToUser ? '已收錢' : '對方已收錢',
      );
      statusText = L.pick(en: 'Added to balance', zhTW: '已存入餘額');
    } else if (isDeclined) {
      bgGradient = [
        Color.lerp(panel, YanciTheme.textSecondary, 0.06)!,
        Color.lerp(panel, YanciTheme.textSecondary, 0.02)!,
      ];
      iconBoxColor = YanciTheme.textSecondary.withValues(alpha: 0.12);
      iconColor = YanciTheme.textSecondary.withValues(alpha: 0.75);
      titleText = L.pick(
        en: isToUser ? 'Returned' : 'Returned by the other side',
        zhTW: isToUser ? '已退還' : '對方已退還',
      );
      statusText = L.pick(en: 'Returned to balance', zhTW: '已退回餘額');
    } else {
      // 給你的轉帳顏色更濃一點，你發出的淡一點，方向一眼看得出來。
      bgGradient = isToUser
          ? [
              Color.lerp(panel, accent, 0.34)!,
              Color.lerp(panel, accent, 0.20)!,
            ]
          : [
              Color.lerp(panel, accent, 0.22)!,
              Color.lerp(panel, accent, 0.12)!,
            ];
      iconBoxColor = YanciTheme.isDark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.white.withValues(alpha: 0.85);
      iconColor = strong;
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
                    color: accent.withValues(alpha: 0.28),
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
                                    child: ShellCoinIcon(size: 18),
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
                                  color: isPending ? strong : YanciTheme.textPrimary,
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
                                  ? strong.withValues(alpha: 0.75)
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
                                  valueColor: AlwaysStoppedAnimation(strong),
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
                                      color: strong,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: YanciTheme.fontFamily,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1,
                                  height: 12,
                                  color: strong.withValues(alpha: 0.2),
                                ),
                                GestureDetector(
                                  onTap: _decline,
                                  child: Text(
                                    L.pick(en: 'Return', zhTW: '退還'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: strong.withValues(alpha: 0.7),
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
                              ? strong.withValues(alpha: 0.5)
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
