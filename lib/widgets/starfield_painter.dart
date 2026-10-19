import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 星光粒子資料
class _Star {
  double x;
  double y;
  double size;
  double opacity;
  double speed;
  double phase;

  _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.opacity,
    required this.speed,
    required this.phase,
  });
}

/// 星光粒子動畫 Widget
class StarfieldWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int starCount;

  const StarfieldWidget({super.key, required this.clock, this.starCount = 25});

  @override
  State<StarfieldWidget> createState() => _StarfieldWidgetState();
}

class _StarfieldWidgetState extends State<StarfieldWidget> {
  late List<_Star> _stars;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _stars = _generateStars();
  }

  List<_Star> _generateStars() {
    return List.generate(widget.starCount, (_) {
      return _Star(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: _random.nextDouble() * 2.5 + 0.5,
        opacity: _random.nextDouble() * 0.6 + 0.2,
        // 呼吸速度取整數（1 或 2）：sin(progress·2π·speed+φ) 在 10s 循環
        // 邊界 progress 1→0 時，整數倍相位差恰為 2π，無縫銜接。
        // 舊版隨機小數 speed 在每次循環結尾都會亮度跳變。
        speed: (_random.nextInt(2) + 1).toDouble(),
        phase: _random.nextDouble() * 2 * pi,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _StarfieldPainter(stars: _stars, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _StarfieldPainter extends CustomPainter {
  final List<_Star> stars;
  final ValueListenable<double> clock;

  _StarfieldPainter({required this.stars, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final animationValue = (clock.value / 10.0) % 1.0;
    for (final star in stars) {
      // 呼吸閃爍效果
      final breathe = sin(animationValue * 2 * pi * star.speed + star.phase);
      final currentOpacity = (star.opacity + breathe * 0.3).clamp(0.05, 0.9);

      final offset = Offset(star.x * size.width, star.y * size.height);

      // 兩層半透明光圈替代逐星高斯模糊，保留柔光感但避免每幀
      // 為每顆星執行昂貴的 blur convolution。
      canvas.drawCircle(
        offset,
        star.size * 2.1,
        Paint()
          ..color = YanciTheme.starColor.withValues(
            alpha: currentOpacity * 0.12,
          ),
      );
      canvas.drawCircle(
        offset,
        star.size,
        Paint()..color = YanciTheme.starColor.withValues(alpha: currentOpacity),
      );

      // 十字光芒（較大的星星才畫）
      if (star.size > 1.5) {
        final crossPaint = Paint()
          ..color = YanciTheme.starColor.withValues(alpha: currentOpacity * 0.4)
          ..strokeWidth = 0.5
          ..strokeCap = StrokeCap.round;

        final crossLen = star.size * 3;
        canvas.drawLine(
          Offset(offset.dx - crossLen, offset.dy),
          Offset(offset.dx + crossLen, offset.dy),
          crossPaint,
        );
        canvas.drawLine(
          Offset(offset.dx, offset.dy - crossLen),
          Offset(offset.dx, offset.dy + crossLen),
          crossPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StarfieldPainter oldDelegate) {
    return !identical(oldDelegate.stars, stars);
  }
}
