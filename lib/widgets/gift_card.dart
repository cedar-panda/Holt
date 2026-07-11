import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../services/locale_strings.dart';
import '../services/shop_service.dart';
import '../theme/app_theme.dart';

/// 禮物迷你卡片 — 跟隨在送禮氣泡下方（不嵌入氣泡內），類似 TransferMiniCard。
/// 顯示物品圖片與名稱；對方回覆後顯示「已收下」。
class GiftMiniCard extends StatelessWidget {
  final String giftName;

  /// 對方之後已回覆 → 視為已收下
  final bool accepted;

  const GiftMiniCard({
    super.key,
    required this.giftName,
    this.accepted = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgGradient = YanciTheme.isDark
        ? [
            YanciTheme.accent.withValues(alpha: 0.16),
            YanciTheme.accent.withValues(alpha: 0.08),
          ]
        : [
            YanciTheme.accent.withValues(alpha: 0.12),
            YanciTheme.accent.withValues(alpha: 0.05),
          ];

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      width: 200,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: bgGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            // 物品圖片（像素圖），查不到就退回禮物圖標
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: YanciTheme.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: FutureBuilder<String?>(
                future: ShopService.findItemImagePathByName(giftName),
                builder: (context, snap) {
                  final path = snap.data;
                  if (!kIsWeb &&
                      path != null &&
                      path.isNotEmpty &&
                      File(path).existsSync()) {
                    return Padding(
                      padding: const EdgeInsets.all(4),
                      child: Image.file(
                        File(path),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none,
                      ),
                    );
                  }
                  return Icon(
                    Icons.card_giftcard_rounded,
                    size: 20,
                    color: YanciTheme.accent.withValues(alpha: 0.75),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    giftName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: YanciTheme.textPrimary,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (accepted) ...[
                        Icon(
                          Icons.check_rounded,
                          size: 11,
                          color: YanciTheme.accent.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 3),
                      ],
                      Flexible(
                        child: Text(
                          accepted
                              ? L.pick(
                                  en: '$giftName received',
                                  zhTW: '$giftName 已收下',
                                )
                              : L.pick(en: 'Gift sent', zhTW: '禮物已送出'),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.8,
                            ),
                            fontFamily: YanciTheme.fontFamily,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
