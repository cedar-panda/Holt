import 'dart:math';
import 'package:flutter/material.dart';

/// 原子軌道等待動畫
/// 展開 → 旋轉 → 脈動 → 旋轉 → 收回 → 循環
class AtomThinkingWidget extends StatefulWidget {
  final double size;
  final Color color;

  const AtomThinkingWidget({
    super.key,
    this.size = 32,
    this.color = const Color(0xFFB8956A), // 默認 accent 金棕色
  });

  @override
  State<AtomThinkingWidget> createState() => _AtomThinkingWidgetState();
}

class _AtomThinkingWidgetState extends State<AtomThinkingWidget>
    with TickerProviderStateMixin {
  late AnimationController _phaseController; // 控制展開/脈動/收回
  late AnimationController _orbitController; // 控制軌道旋轉（持續）

  @override
  void initState() {
    super.initState();

    // 整體動畫週期：3秒一輪
    _phaseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    // 軌道旋轉：持續旋轉，1.5秒一圈
    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _phaseController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary：把每幀重繪隔離在這個小部件內——
    // 沒有它，動畫每一幀都會把所在的氣泡/列表一起拖進重繪，
    // 流式輸出時互相搶幀就是「不流暢」的來源。樣式零改動。
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: Listenable.merge([_phaseController, _orbitController]),
          builder: (context, _) {
            return CustomPaint(
              isComplex: true,
              willChange: true,
              painter: _AtomPainter(
                phase: _phaseController.value,
                orbitAngle: _orbitController.value * 2 * pi,
                color: widget.color,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AtomPainter extends CustomPainter {
  final double phase; // 0.0 ~ 1.0 整體階段
  final double orbitAngle; // 軌道旋轉角度
  final Color color;

  _AtomPainter({
    required this.phase,
    required this.orbitAngle,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width * 0.35;

    // ═══ 階段計算 ═══
    // 0.00 - 0.12  展開（線 → 軌道）
    // 0.12 - 0.42  旋轉
    // 0.42 - 0.58  脈動放大
    // 0.58 - 0.88  旋轉
    // 0.88 - 1.00  收回（軌道 → 線）

    double openness; // 0=線，1=完全展開
    double pulse; // 1=正常，>1=放大

    if (phase < 0.12) {
      // 展開
      openness = Curves.easeOutBack.transform(phase / 0.12);
      pulse = 1.0;
    } else if (phase < 0.42) {
      // 旋轉（完全展開）
      openness = 1.0;
      pulse = 1.0;
    } else if (phase < 0.58) {
      // 脈動
      openness = 1.0;
      final t = (phase - 0.42) / 0.16;
      pulse = 1.0 + 0.2 * sin(t * pi); // 最大放大 1.2 倍
    } else if (phase < 0.88) {
      // 旋轉（完全展開）
      openness = 1.0;
      pulse = 1.0;
    } else {
      // 收回
      openness = Curves.easeInBack.transform(1.0 - (phase - 0.88) / 0.12);
      pulse = 1.0;
    }

    final radius = baseRadius * pulse;

    // ═══ 畫軌道 ═══
    final orbitPaint = Paint()
      ..color = color.withValues(alpha: 0.3 * openness)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    // 三條軌道，每條傾斜角度不同
    final orbitAngles = [0.0, pi / 3, -pi / 3];

    for (int i = 0; i < 3; i++) {
      final tilt = orbitAngles[i] + orbitAngle * 0.3; // 慢速擺動
      final ry = radius * 0.45 * openness; // 更圓潤

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(tilt);

      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: radius * 2,
        height: ry * 2,
      );

      if (ry > 0.5) {
        canvas.drawOval(rect, orbitPaint);
      } else {
        // 太扁就畫線
        canvas.drawLine(Offset(-radius, 0), Offset(radius, 0), orbitPaint);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _AtomPainter old) =>
      old.phase != phase || old.orbitAngle != orbitAngle || old.color != color;
}
