import 'package:flutter/material.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// 結婚證書卡片 —— 一紙證書的質感（米白紙面、細金邊、壓印感）。
/// 跟隨氣泡顯示（邀請簽署），也用於背包內展示。
class MarriageCertCard extends StatelessWidget {
  final String userName;
  final String charName;

  /// 已簽署 → 顯示簽名與日期；未簽 → 「待簽署」
  final bool signed;
  final String? date;

  /// 背包內展示時稍大
  final bool expanded;

  /// 非空且未簽 → 可點擊簽署（她遞出的證書）
  final VoidCallback? onSignTap;

  const MarriageCertCard({
    super.key,
    required this.userName,
    required this.charName,
    this.signed = false,
    this.date,
    this.expanded = false,
    this.onSignTap,
  });

  @override
  Widget build(BuildContext context) {
    // 紙面色：暗色主題下做舊羊皮紙，亮色下米白
    final paper = YanciTheme.isDark
        ? const Color(0xFF3A342A)
        : const Color(0xFFFBF6EA);
    final paperEdge = YanciTheme.isDark
        ? const Color(0xFF57503F)
        : const Color(0xFFE3D5B3);
    final ink = YanciTheme.isDark
        ? const Color(0xFFE8DFC8)
        : const Color(0xFF5A4A2F);
    final gold = YanciTheme.isDark
        ? const Color(0xFFC9A961)
        : const Color(0xFFB8933F);

    final width = expanded ? 240.0 : 208.0;

    final card = Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      width: width,
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: paperEdge, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: YanciTheme.isDark ? 0.3 : 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Container(
        margin: const EdgeInsets.all(5),
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: expanded ? 16 : 12,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: gold.withValues(alpha: 0.55), width: 0.8),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('❦', style: TextStyle(fontSize: 13, color: gold)),
            const SizedBox(height: 4),
            Text(
              L.pick(
                en: 'Certificate of Marriage',
                zhTW: '結婚證書',
                zhCN: '结婚证书',
              ),
              style: TextStyle(
                fontSize: expanded ? 15 : 13.5,
                fontWeight: FontWeight.w700,
                color: ink,
                letterSpacing: 2.5,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$userName ✕ $charName',
              style: TextStyle(
                fontSize: expanded ? 13 : 12,
                fontWeight: FontWeight.w600,
                color: ink,
                fontFamily: YanciTheme.fontFamily,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            // 分隔細線
            Container(
              width: width * 0.5,
              height: 0.6,
              color: gold.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 6),
            if (signed) ...[
              Text(
                L.pick(en: 'Signed', zhTW: '已簽署', zhCN: '已签署') +
                    (date == null ? '' : ' · $date'),
                style: TextStyle(
                  fontSize: 10.5,
                  color: gold,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ] else ...[
              Text(
                onSignTap != null
                    ? L.pick(
                        en: 'Tap to sign',
                        zhTW: '輕點簽署',
                        zhCN: '轻点签署',
                      )
                    : L.pick(
                        en: 'Awaiting signature…',
                        zhTW: '待簽署⋯⋯',
                        zhCN: '待签署……',
                      ),
                style: TextStyle(
                  fontSize: 10.5,
                  color: onSignTap != null
                      ? gold
                      : ink.withValues(alpha: 0.65),
                  fontStyle: FontStyle.italic,
                  fontWeight: onSignTap != null
                      ? FontWeight.w600
                      : FontWeight.normal,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (onSignTap == null || signed) return card;
    return GestureDetector(onTap: onSignTap, child: card);
  }
}
