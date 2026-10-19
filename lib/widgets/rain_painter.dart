import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum _RainDepth { far, focus, near }

/// 雨絲粒子資料
class _Raindrop {
  double x; // 0~1 正規化水平位置
  double y; // 0~1 正規化垂直位置（0=頂部）
  double length; // 雨絲長度 px
  double speed; // 下落速率係數
  double opacity;
  double sway; // 微風飄移相位
  double swayAmplitude;
  double strokeWidth;
  _RainDepth depth;

  _Raindrop({
    required this.x,
    required this.y,
    required this.length,
    required this.speed,
    required this.opacity,
    required this.sway,
    required this.swayAmplitude,
    required this.strokeWidth,
    required this.depth,
  });
}

/// 春·燕的雨絲粒子動畫
class RainWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int dropCount;

  const RainWidget({super.key, required this.clock, this.dropCount = 35});

  @override
  State<RainWidget> createState() => _RainWidgetState();
}

class _RainWidgetState extends State<RainWidget> {
  late List<_Raindrop> _drops;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _drops = _generateDrops();
  }

  List<_Raindrop> _generateDrops() {
    final drops = List.generate(widget.dropCount, (_) {
      // 固定景深：每根雨絲只在生成時抽一次層級，整個生命週期不改變，
      // 避免模糊度呼吸或閃爍。中景是對焦面，近景才有明顯散焦。
      final depthRoll = _random.nextDouble();
      late final double lengthScale;
      late final double speedScale;
      late final double opacityScale;
      late final double strokeWidth;
      late final _RainDepth depth;
      late final double swayAmplitude;

      if (depthRoll < 0.40) {
        // 遠景：短、細、慢、稍微柔化。
        depth = _RainDepth.far;
        lengthScale = 0.70 + _random.nextDouble() * 0.20;
        speedScale = 0.76 + _random.nextDouble() * 0.16;
        opacityScale = 0.55 + _random.nextDouble() * 0.20;
        strokeWidth = 0.55 + _random.nextDouble() * 0.17;
        swayAmplitude = 1.8 + _random.nextDouble() * 1.0;
      } else if (depthRoll < 0.85) {
        // 焦點層：最清楚，維持原本輕細雨絲的存在感。
        depth = _RainDepth.focus;
        lengthScale = 0.90 + _random.nextDouble() * 0.15;
        speedScale = 0.90 + _random.nextDouble() * 0.15;
        opacityScale = 0.80 + _random.nextDouble() * 0.20;
        strokeWidth = 0.72 + _random.nextDouble() * 0.16;
        swayAmplitude = 2.4 + _random.nextDouble() * 1.0;
      } else {
        // 近景：粗與散焦會攤開光量，因此中心透明度低於焦點層，
        // 避免掠過文字時形成又粗又亮的白棍。
        depth = _RainDepth.near;
        lengthScale = 1.15 + _random.nextDouble() * 0.30;
        speedScale = 1.08 + _random.nextDouble() * 0.20;
        opacityScale = 0.68 + _random.nextDouble() * 0.14;
        strokeWidth = 0.95 + _random.nextDouble() * 0.30;
        swayAmplitude = 2.8 + _random.nextDouble() * 1.2;
      }

      // 雨絲本身另有固定的短／中／長節奏，不讓「景深」單獨決定長度。
      // 長度只在生成時抽取一次，因此每根雨絲移動期間不會忽長忽短。
      final lengthRoll = _random.nextDouble();
      final double baseLength;
      if (lengthRoll < 0.34) {
        baseLength = 6.0 + _random.nextDouble() * 6.0;
      } else if (lengthRoll < 0.82) {
        baseLength = 13.0 + _random.nextDouble() * 11.0;
      } else {
        baseLength = 26.0 + _random.nextDouble() * 10.0;
      }

      return _Raindrop(
        x: _random.nextDouble(),
        y: _random.nextDouble(), // 初始隨機散佈，不要全從頂部開始
        length: baseLength * lengthScale,
        speed: (_random.nextDouble() * 0.4 + 0.8) * speedScale,
        opacity: (_random.nextDouble() * 0.25 + 0.08) * opacityScale,
        sway: _random.nextDouble() * 2 * pi,
        swayAmplitude: swayAmplitude,
        strokeWidth: strokeWidth,
        depth: depth,
      );
    });
    // CustomPainter 依序覆畫；固定由遠到近，讓遮擋關係符合景深。
    drops.sort((a, b) => a.depth.index.compareTo(b.depth.index));
    return drops;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RainPainter(drops: _drops, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _RainPainter extends CustomPainter {
  final List<_Raindrop> drops;
  final ValueListenable<double> clock;

  _RainPainter({required this.drops, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = clock.value;
    // 雨絲顏色跟主題星光色走，保持視覺協調
    final baseColor = YanciTheme.starColor;

    for (final drop in drops) {
      // 垂直位移：每滴以自己的速度往下移，超出底部就回到頂部
      // 對齊舊版速度，但改用永不整體復位的連續秒數。
      final yProgress = (drop.y + seconds * drop.speed / 4.0) % 1.3;
      if (yProgress > 1.05) continue; // 還沒重新進入畫面

      final currentY = yProgress * size.height;

      // 微風飄移：水平微擺，sin 波模擬風感
      final swayOffset =
          sin(seconds * 2 * pi * 0.1875 + drop.sway) * drop.swayAmplitude;
      final currentX = drop.x * size.width + swayOffset;

      // 接近邊緣淡出（進入和離開時）
      final edgeFade = yProgress < 0.05
          ? yProgress / 0.05
          : yProgress > 0.95
          ? (1.0 - yProgress) / 0.05
          : 1.0;

      // 雨絲：微傾斜的短線段（模擬微風中的雨）
      const angle = 0.06; // ≈3.4° 微傾
      final dx = sin(angle) * drop.length;
      final dy = cos(angle) * drop.length;
      final start = Offset(currentX, currentY);
      final end = Offset(currentX + dx, currentY + dy);
      final alpha = (drop.opacity * edgeFade).clamp(0.0, 1.0);

      // 三段透明度遞增保留上端漸隱，避免每根雨絲每幀建立 gradient
      // shader 與 MaskFilter。近景加一層極淡寬線模擬散焦。
      final delta = end - start;
      final p1 = start + delta * 0.38;
      final p2 = start + delta * 0.72;
      if (drop.depth == _RainDepth.near) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = baseColor.withValues(alpha: alpha * 0.10)
            ..strokeWidth = drop.strokeWidth * 2.3
            ..strokeCap = StrokeCap.round,
        );
      }
      final stroke = Paint()
        ..strokeWidth = drop.strokeWidth
        ..strokeCap = StrokeCap.round;
      stroke.color = baseColor.withValues(alpha: alpha * 0.18);
      canvas.drawLine(start, p1, stroke);
      stroke.color = baseColor.withValues(alpha: alpha * 0.56);
      canvas.drawLine(p1, p2, stroke);
      stroke.color = baseColor.withValues(alpha: alpha);
      canvas.drawLine(p2, end, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _RainPainter oldDelegate) {
    return !identical(oldDelegate.drops, drops);
  }
}
