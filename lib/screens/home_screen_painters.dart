part of 'home_screen.dart';

/// 發光心電線 — Light Line 風格，從左往右掃描
class _EcgPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color glowColor;
  final Color lineColor; // 主線：主題色系，與背景有對比
  final Color headColor; // 掃描頭亮點

  _EcgPainter({
    required this.progress,
    required this.color,
    required this.glowColor,
    required this.lineColor,
    required this.headColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final w = size.width;

    // 掃描頭位置（從左到右循環，延長離場距離讓尾跡完全消失再重置）
    final headX = progress * w * 1.8 - w * 0.2;
    // 可見窗口：掃描頭左邊一段距離（加長尾跡，淡出更柔和）
    final trailLen = w * 0.7;

    // 心電圖波形定義（一個週期的關鍵點 [x比例, y偏移]）
    // 平線 → P波 → 平線 → Q → R(主峰) → S → 平線 → T波 → 平線
    final waveLen = w * 0.32;

    // 在 x 位置取波形 y 值
    double waveY(double x) {
      // 對 waveLen 取模得到週期內位置
      double t = (x % waveLen) / waveLen;
      if (t < 0) t += 1;

      if (t < 0.30) return 0; // 平線
      if (t < 0.38) {
        // P波（小圓弧）
        final p = (t - 0.30) / 0.08;
        return -12 * sin(p * 3.14159);
      }
      if (t < 0.42) return 0; // 短平線
      if (t < 0.46) {
        // Q 下降
        final p = (t - 0.42) / 0.04;
        return 10 * p;
      }
      if (t < 0.52) {
        // R 主峰（上衝）
        final p = (t - 0.46) / 0.06;
        return 10 - 60 * sin(p * 3.14159);
      }
      if (t < 0.56) {
        // S 下谷
        final p = (t - 0.52) / 0.04;
        return 15 * (1 - p);
      }
      if (t < 0.62) return 0; // 短平線
      if (t < 0.75) {
        // T波
        final p = (t - 0.62) / 0.13;
        return -18 * sin(p * 3.14159);
      }
      return 0; // 平線
    }

    // 點的亮度：離掃描頭越近越亮，超出 trail 完全消失
    double brightness(double x) {
      final dist = headX - x;
      if (dist < 0 || dist > trailLen) return 0;
      // 靠近頭部最亮，尾巴漸出（三次曲線更柔和）
      final t = 1.0 - (dist / trailLen);
      return t * t * t;
    }

    // 繪製路徑（逐像素取樣）
    final step = 2.0;

    // 第一層：寬光暈
    for (double x = 0; x < w; x += step * 2) {
      final b = brightness(x);
      if (b < 0.02) continue;
      final y = waveY(x);
      final glowP = Paint()
        ..color = color.withValues(alpha: b * 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 25);
      canvas.drawCircle(Offset(x, midY + y), 8, glowP);
    }

    // 第二層：窄光暈
    for (double x = 0; x < w; x += step) {
      final b = brightness(x);
      if (b < 0.03) continue;
      final y = waveY(x);
      final glowP = Paint()
        ..color = color.withValues(alpha: b * 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(Offset(x, midY + y), 3, glowP);
    }

    // 第三層：主線條
    Path? linePath;
    double? lastB;
    for (double x = 0; x < w; x += step) {
      final b = brightness(x);
      if (b < 0.03) {
        if (linePath != null && lastB != null && lastB >= 0.03) {
          final lineP = Paint()
            ..color = lineColor.withValues(alpha: 0.9)
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round;
          canvas.drawPath(linePath, lineP);
          linePath = null;
        }
        lastB = b;
        continue;
      }
      final y = waveY(x);
      if (linePath == null) {
        linePath = Path()..moveTo(x, midY + y);
      } else {
        linePath.lineTo(x, midY + y);
      }
      lastB = b;
    }
    if (linePath != null) {
      final lineP = Paint()
        ..color = lineColor.withValues(alpha: 0.9)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(linePath, lineP);
    }

    // 掃描頭亮點
    if (headX > 0 && headX < w) {
      final hy = waveY(headX);
      final dotP = Paint()
        ..color = headColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(headX, midY + hy), 3, dotP);

      // 頭部額外光暈
      final haloP = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);
      canvas.drawCircle(Offset(headX, midY + hy), 12, haloP);
    }
  }

  @override
  bool shouldRepaint(covariant _EcgPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
