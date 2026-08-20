import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 雨絲粒子資料
class _Raindrop {
  double x; // 0~1 正規化水平位置
  double y; // 0~1 正規化垂直位置（0=頂部）
  double length; // 雨絲長度 px
  double speed; // 下落速率係數
  double opacity;
  double sway; // 微風飄移相位

  _Raindrop({
    required this.x,
    required this.y,
    required this.length,
    required this.speed,
    required this.opacity,
    required this.sway,
  });
}

/// 春·燕的雨絲粒子動畫
class RainWidget extends StatefulWidget {
  final int dropCount;

  const RainWidget({super.key, this.dropCount = 35});

  @override
  State<RainWidget> createState() => _RainWidgetState();
}

class _RainWidgetState extends State<RainWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Raindrop> _drops;
  final Random _random = Random();
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _drops = _generateDrops();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion && _controller.isAnimating) return;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  List<_Raindrop> _generateDrops() {
    return List.generate(widget.dropCount, (_) {
      return _Raindrop(
        x: _random.nextDouble(),
        y: _random.nextDouble(), // 初始隨機散佈，不要全從頂部開始
        length: _random.nextDouble() * 18 + 8, // 8~26px
        speed: _random.nextDouble() * 0.4 + 0.8, // 0.8~1.2
        opacity: _random.nextDouble() * 0.25 + 0.08, // 0.08~0.33（極淡）
        sway: _random.nextDouble() * 2 * pi,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RainPainter(drops: _drops, progress: _controller),
        size: Size.infinite,
      ),
    );
  }
}

class _RainPainter extends CustomPainter {
  final List<_Raindrop> drops;
  final Animation<double> progress;

  _RainPainter({required this.drops, required this.progress})
    : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    // 雨絲顏色跟主題星光色走，保持視覺協調
    final baseColor = YanciTheme.starColor;

    for (final drop in drops) {
      // 垂直位移：每滴以自己的速度往下移，超出底部就回到頂部
      final yProgress = (drop.y + t * drop.speed * 2) % 1.3;
      if (yProgress > 1.05) continue; // 還沒重新進入畫面

      final currentY = yProgress * size.height;

      // 微風飄移：水平微擺，sin 波模擬風感
      final swayOffset = sin(t * 2 * pi * 1.5 + drop.sway) * 3.0;
      final currentX = drop.x * size.width + swayOffset;

      // 接近邊緣淡出（進入和離開時）
      final edgeFade = yProgress < 0.05
          ? yProgress / 0.05
          : yProgress > 0.95
              ? (1.0 - yProgress) / 0.05
              : 1.0;

      final paint = Paint()
        ..color = baseColor.withValues(alpha: drop.opacity * edgeFade)
        ..strokeWidth = 0.8
        ..strokeCap = StrokeCap.round;

      // 雨絲：微傾斜的短線段（模擬微風中的雨）
      const angle = 0.06; // ≈3.4° 微傾
      final dx = sin(angle) * drop.length;
      final dy = cos(angle) * drop.length;

      canvas.drawLine(
        Offset(currentX, currentY),
        Offset(currentX + dx, currentY + dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RainPainter oldDelegate) {
    return !identical(oldDelegate.drops, drops);
  }
}
