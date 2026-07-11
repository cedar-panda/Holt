import 'dart:math';
import 'package:flutter/material.dart';

class OrbitLoadingIndicator extends StatefulWidget {
  final double size;
  final Color color;

  const OrbitLoadingIndicator({
    super.key,
    this.size = 20.0,
    required this.color,
  });

  @override
  State<OrbitLoadingIndicator> createState() => _OrbitLoadingIndicatorState();
}

class _OrbitLoadingIndicatorState extends State<OrbitLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: OrbitPainter(progress: _ctrl.value, color: widget.color),
          ),
        );
      },
    );
  }
}

/// 單珠繞正圓 + 長尾跡
class OrbitPainter extends CustomPainter {
  final double progress; // 0.0 ~ 1.0
  final Color color;

  OrbitPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2.0;
    final dotR = 1.6;

    // 不畫靜態軌道圈

    // 珠子角度（從頂部開始順時針轉一整圈）
    final angle = -pi / 2 + progress * 2 * pi;

    // 長尾跡：珠子身後 ~200° 的弧，漸隱漸細
    final tailSweep = pi * 1.1;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const segments = 10;
    for (int i = 0; i < segments; i++) {
      final frac = i / segments;
      final segStart = angle - tailSweep + tailSweep * frac;
      final segSweep = tailSweep / segments;
      canvas.drawArc(
        rect,
        segStart,
        segSweep,
        false,
        Paint()
          ..color = color.withValues(alpha: 0.03 + 0.5 * frac)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6 + 1.2 * frac
          ..strokeCap = StrokeCap.round,
      );
    }

    // 珠子
    final pos = center + Offset(cos(angle) * radius, sin(angle) * radius);
    canvas.drawCircle(pos, dotR, Paint()..color = color.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant OrbitPainter old) =>
      progress != old.progress || color != old.color;
}
