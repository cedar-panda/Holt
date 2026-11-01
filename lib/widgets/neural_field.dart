import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 神經網路碎片漂浮背景
///
/// 半透明節點緩慢漂移，距離近的節點間畫淡連線，
/// 節點大小不一帶呼吸閃爍，像冰水裡的氣泡+突觸碎片。
/// 自動根據主題明暗調整可見度。
class NeuralFieldWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int nodeCount;

  // 全主題共用象牙白的低顯著性基準；只統一淡化程度，不統一色相。
  static const double particleColorMix = 0.72;
  static const double particleGlowMix = 0.74;
  static const double particleOpacityBoost = 1.45;
  static const double connectionStrength = 0.42;
  static const double connectionMaxOpacity = 0.52;

  const NeuralFieldWidget({
    super.key,
    required this.clock,
    this.nodeCount = 18,
  });

  @override
  State<NeuralFieldWidget> createState() => _NeuralFieldWidgetState();
}

class _NeuralFieldWidgetState extends State<NeuralFieldWidget> {
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
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _NeuralPainter(
          nodes: _nodes,
          clock: widget.clock,
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
  final ValueListenable<double> clock;
  final bool isDark;
  final Color color;
  final Color glowColor;
  final Color accent;
  final Paint _linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _haloOuterPaint = Paint();
  final Paint _haloInnerPaint = Paint();
  final Paint _corePaint = Paint();

  _NeuralPainter({
    required this.nodes,
    required this.clock,
    required this.isDark,
    required this.color,
    required this.glowColor,
    required this.accent,
  }) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = clock.value; // 連續秒數，不循環
    // 對齊舊版速度：progress(0-1/20s)*20 == seconds；呼吸相位同理 ÷20
    final drift = seconds;
    final t = seconds / 20 * 2 * pi;
    const connectDist = 0.20;

    // 所有主題沿用象牙白的低顯著性基準，保留各自的 accent / 粒子色相。
    final nodeColor = Color.lerp(
      accent,
      color,
      NeuralFieldWidget.particleColorMix,
    )!;
    final haloColor = Color.lerp(
      accent,
      glowColor,
      NeuralFieldWidget.particleGlowMix,
    )!;
    const opBoost = NeuralFieldWidget.particleOpacityBoost;

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
      opacities.add(baseOp.clamp(0.12, 0.85));
    }

    // 連線（距離近的節點）
    _linePaint.strokeWidth = isDark ? 1.0 : 1.2;

    for (int i = 0; i < nodes.length; i++) {
      for (int j = i + 1; j < nodes.length; j++) {
        final dx = (positions[i].dx - positions[j].dx) / size.width;
        final dy = (positions[i].dy - positions[j].dy) / size.height;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < connectDist) {
          final fade = 1.0 - dist / connectDist;
          final lineOp =
              fade *
              NeuralFieldWidget.connectionStrength *
              (opacities[i] + opacities[j]);
          _linePaint.color = nodeColor.withValues(
            alpha: lineOp.clamp(0.0, NeuralFieldWidget.connectionMaxOpacity),
          );
          canvas.drawLine(positions[i], positions[j], _linePaint);
        }
      }
    }

    // 節點（氣泡感：柔光暈 + 實心小圓）
    // 點的不透明度 ×0.8（2026-10-29 昭昭反映粒子太淡，從 ×0.5 提高）；
    // 線的計算用原始 op。
    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final pos = positions[i];
      final op = opacities[i];

      // 外層光暈（氣泡感）
      canvas.drawCircle(
        pos,
        n.r * 2.5,
        _haloOuterPaint
          ..color = haloColor.withValues(alpha: (op * 0.14).clamp(0.0, 0.24)),
      );
      canvas.drawCircle(
        pos,
        n.r * 1.65,
        _haloInnerPaint
          ..color = haloColor.withValues(alpha: (op * 0.22).clamp(0.0, 0.34)),
      );

      // 內核
      canvas.drawCircle(
        pos,
        n.r,
        _corePaint
          ..color = nodeColor.withValues(alpha: (op * 0.8).clamp(0.0, 0.68)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralPainter old) =>
      old.isDark != isDark ||
      old.color != color ||
      old.glowColor != glowColor ||
      old.accent != accent ||
      !identical(old.nodes, nodes);
}
