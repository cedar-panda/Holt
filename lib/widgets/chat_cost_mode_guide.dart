import 'package:flutter/material.dart';

/// One-shot visual handoff from the lower chat area to the temporary
/// cache/context suggestion beside the character name.
class ChatCostModeGuideTrail extends StatefulWidget {
  const ChatCostModeGuideTrail({
    super.key,
    required this.color,
    required this.targetDx,
    required this.targetDy,
  });

  final Color color;
  final double targetDx;
  final double targetDy;

  @override
  State<ChatCostModeGuideTrail> createState() => _ChatCostModeGuideTrailState();
}

class _ChatCostModeGuideTrailState extends State<ChatCostModeGuideTrail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _CostModeTrailPainter(
              progress: Curves.easeInOutCubic.transform(_controller.value),
              color: widget.color,
              targetDx: widget.targetDx,
              targetDy: widget.targetDy,
            ),
          ),
        ),
      ),
    );
  }
}

class _CostModeTrailPainter extends CustomPainter {
  const _CostModeTrailPainter({
    required this.progress,
    required this.color,
    required this.targetDx,
    required this.targetDy,
  });

  final double progress;
  final Color color;
  final double targetDx;
  final double targetDy;

  @override
  void paint(Canvas canvas, Size size) {
    final start = Offset(size.width * 0.5, size.height * 0.82);
    final end = Offset(
      targetDx.clamp(0.0, size.width),
      targetDy.clamp(0.0, size.height),
    );
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        size.width * 0.72,
        size.height * 0.64,
        size.width * 0.68,
        size.height * 0.24,
        end.dx,
        end.dy,
      );
    final metric = path.computeMetrics().first;
    final headDistance = metric.length * progress;
    final tailDistance = (headDistance - metric.length * 0.18).clamp(
      0.0,
      metric.length,
    );
    final visible = metric.extractPath(tailDistance, headDistance);
    final fade = progress < 0.82 ? 1.0 : (1 - progress) / 0.18;
    final opacity = fade.clamp(0.0, 1.0);
    if (opacity <= 0) return;

    canvas.drawPath(
      visible,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.5 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    final tangent = metric.getTangentForOffset(headDistance);
    if (tangent == null) return;
    canvas.drawCircle(
      tangent.position,
      3.2,
      Paint()
        ..color = color.withValues(alpha: 0.88 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
  }

  @override
  bool shouldRepaint(covariant _CostModeTrailPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.targetDx != targetDx ||
        oldDelegate.targetDy != targetDy;
  }
}
