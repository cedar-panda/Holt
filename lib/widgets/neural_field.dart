import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import '../theme/app_theme.dart';

/// 神經網路碎片漂浮背景
///
/// 半透明節點緩慢漂移，距離近的節點間畫淡連線，
/// 節點大小不一帶呼吸閃爍，像冰水裡的氣泡+突觸碎片。
/// 自動根據主題明暗調整可見度。
class NeuralFieldWidget extends StatefulWidget {
  final int nodeCount;

  const NeuralFieldWidget({super.key, this.nodeCount = 18});

  @override
  State<NeuralFieldWidget> createState() => _NeuralFieldWidgetState();
}

class _NeuralFieldWidgetState extends State<NeuralFieldWidget>
    with SingleTickerProviderStateMixin {
  // 連續時鐘：Ticker 的 elapsed 只增不減，永不復位。
  // 舊版用 20s 循環的 AnimationController.value 直接乘位移，
  // repeat 從 1.0 跳回 0.0 時所有粒子瞬間彈回起點——就是那個「卡一下」。
  late final Ticker _ticker;
  final ValueNotifier<double> _t = ValueNotifier(0);
  late List<_Node> _nodes;
  final Random _rng = Random(7);

  @override
  void initState() {
    super.initState();
    _nodes = List.generate(
      widget.nodeCount,
      (_) => _Node(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        // 隨機半徑差異更大：0.8 ~ 4.5
        r: _rng.nextDouble() * 3.7 + 0.8,
        opacity: _rng.nextDouble() * 0.45 + 0.15,
        phase: _rng.nextDouble() * 2 * pi,
        speedX: (_rng.nextDouble() - 0.5) * 0.014,
        speedY: (_rng.nextDouble() - 0.5) * 0.010,
        breatheSpeed: _rng.nextDouble() * 0.7 + 0.25,
      ),
    );
    _ticker = createTicker((elapsed) {
      _t.value = elapsed.inMicroseconds / 1e6;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _t,
      builder: (_, seconds, _) => CustomPaint(
        painter: _NeuralPainter(
          nodes: _nodes,
          seconds: seconds,
          isDark: YanciTheme.isDark,
          color: YanciTheme.starColor,
          glowColor: YanciTheme.starGlow,
          accent: YanciTheme.accent,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _Node {
  double x, y, r, opacity, phase, speedX, speedY, breatheSpeed;
  _Node({
    required this.x,
    required this.y,
    required this.r,
    required this.opacity,
    required this.phase,
    required this.speedX,
    required this.speedY,
    required this.breatheSpeed,
  });
}

class _NeuralPainter extends CustomPainter {
  final List<_Node> nodes;
  final double seconds; // 連續秒數，不循環
  final bool isDark;
  final Color color;
  final Color glowColor;
  final Color accent;

  _NeuralPainter({
    required this.nodes,
    required this.seconds,
    required this.isDark,
    required this.color,
    required this.glowColor,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 對齊舊版速度：progress(0-1/20s)*20 == seconds；呼吸相位同理 ÷20
    final drift = seconds;
    final t = seconds / 20 * 2 * pi;
    const connectDist = 0.20;

    // 淺色主題：用 accent 色混合，提高對比度
    // 暗色主題：用原本的 starColor
    final nodeColor = isDark ? color : Color.lerp(accent, color, 0.3)!;
    final haloColor = isDark ? glowColor : Color.lerp(accent, glowColor, 0.25)!;

    // 淺色主題整體不透明度加成
    final opBoost = isDark ? 1.0 : 1.6;

    // 計算當前位置
    final positions = <Offset>[];
    final opacities = <double>[];

    for (final n in nodes) {
      // 緩慢漂移（wrap around）——drift 連續遞增，% 1.0 只在畫面邊緣繞回，
      // 粒子從一側出、另一側進，永不整體復位
      final nx = ((n.x + n.speedX * drift) % 1.0 + 1.0) % 1.0;
      final ny = ((n.y + n.speedY * drift) % 1.0 + 1.0) % 1.0;
      positions.add(Offset(nx * size.width, ny * size.height));

      // 呼吸
      final breathe = sin(t * n.breatheSpeed + n.phase);
      final baseOp = (n.opacity + breathe * 0.18) * opBoost;
      opacities.add(baseOp.clamp(0.08, 0.75));
    }

    // 連線（距離近的節點）
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isDark ? 0.8 : 1.0
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < nodes.length; i++) {
      for (int j = i + 1; j < nodes.length; j++) {
        final dx = (positions[i].dx - positions[j].dx) / size.width;
        final dy = (positions[i].dy - positions[j].dy) / size.height;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < connectDist) {
          final fade = 1.0 - dist / connectDist;
          final lineOp =
              fade * (isDark ? 0.35 : 0.45) * (opacities[i] + opacities[j]);
          linePaint.color = nodeColor.withValues(
            alpha: lineOp.clamp(0.0, isDark ? 0.5 : 0.55),
          );
          canvas.drawLine(positions[i], positions[j], linePaint);
        }
      }
    }

    // 節點（氣泡感：柔光暈 + 實心小圓）
    // 點的不透明度單獨壓低（×0.5）——線的計算用原始 op，存在感不變；
    // 點退到和線同一層呼吸，不再搶戲。
    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final pos = positions[i];
      final op = opacities[i];

      // 外層光暈（氣泡感）
      canvas.drawCircle(
        pos,
        n.r * 2.5,
        Paint()
          ..color = haloColor.withValues(alpha: (op * 0.22).clamp(0.0, 0.32))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, n.r * 2),
      );

      // 內核
      canvas.drawCircle(
        pos,
        n.r,
        Paint()
          ..color = nodeColor.withValues(alpha: (op * 0.5).clamp(0.0, 0.4)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralPainter old) =>
      old.seconds != seconds || old.isDark != isDark || old.color != color;
}
