import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 語音通話中心視覺化 — 單體呼吸
///
/// 畫面中央一團柔軟的不規則形體，邊緣持續微微流動變形。
/// - [VoiceState.idle]      緩慢呼吸，形狀安靜地變化
/// - [VoiceState.listening] 形體擴張，變形幅度加大
/// - [VoiceState.speaking]  跟隨語音節奏起伏
/// - [VoiceState.thinking]  收縮變小，變形放緩
enum VoiceState { idle, listening, speaking, thinking }

class VoiceVisualizer extends StatefulWidget {
  final VoiceState state;
  final double size;

  const VoiceVisualizer({super.key, required this.state, this.size = 390});

  @override
  State<VoiceVisualizer> createState() => _VoiceVisualizerState();
}

class _VoiceVisualizerState extends State<VoiceVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 10000),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _BlobPainter(
              state: widget.state,
              time: _ctrl.value * 2 * pi,
              accent: YanciTheme.accent,
              bgBase: YanciTheme.backgroundGradient.length > 2
                  ? YanciTheme.backgroundGradient[2]
                  : YanciTheme.accent.withValues(alpha: 0.1),
              isDark: YanciTheme.isDark,
            ),
          );
        },
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  final VoiceState state;
  final double time;
  final Color accent;
  final Color bgBase;
  final bool isDark;

  _BlobPainter({
    required this.state,
    required this.time,
    required this.accent,
    required this.bgBase,
    required this.isDark,
  });

  // 多組諧波 — 角頻率、時間速度互不相同，形狀不會明顯重複
  static const _harmonics = [
    (2, 0.70, 0.40, 0.00),
    (3, 1.10, 0.28, 1.30),
    (5, 0.50, 0.15, 2.70),
    (4, 0.85, 0.12, 0.80),
    (7, 0.35, 0.08, 3.50),
    (6, 0.55, 0.05, 1.90),
  ];

  // 內層諧波（更慢、更柔）
  static const _innerHarmonics = [
    (2, 0.45, 0.30, 0.50),
    (3, 0.65, 0.20, 2.10),
    (5, 0.30, 0.10, 1.40),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final p = _params();

    // ── 最外層：背景色融合光暈（跟頁面底色呼應）──
    final outerGlowR = maxR * p.radius * 1.6;
    final blendColor = Color.lerp(accent, bgBase, 0.55) ?? accent;
    canvas.drawCircle(
      center,
      outerGlowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            blendColor.withValues(alpha: p.glowOpacity * 0.6),
            blendColor.withValues(alpha: p.glowOpacity * 0.15),
            blendColor.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: outerGlowR)),
    );

    // ── 主色光暈 ──
    final glowR = maxR * p.radius * 1.3;
    canvas.drawCircle(
      center,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: p.glowOpacity),
            accent.withValues(alpha: p.glowOpacity * 0.25),
            accent.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: glowR)),
    );

    // ── 內層 blob（更小、更柔、偏移相位，製造層次感）──
    final innerPath = _buildBlobPath(
      center,
      maxR,
      p.copyWith(radius: p.radius * 0.72, amplitude: p.amplitude * 0.7),
      harmonics: _innerHarmonics,
      timeOffset: 1.2,
    );
    final innerColor = isDark
        ? Color.lerp(accent, Colors.white, 0.15) ?? accent
        : Color.lerp(accent, bgBase, 0.3) ?? accent;
    canvas.drawPath(
      innerPath,
      Paint()
        ..color = innerColor.withValues(alpha: p.coreOpacity * 0.5)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );

    // ── 主 blob 路徑 ──
    final path = _buildBlobPath(center, maxR, p);

    // 柔邊填充
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: p.fillOpacity)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    // 核心填充
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: p.coreOpacity)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // 邊緣描邊
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: p.strokeOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0),
    );
  }

  Path _buildBlobPath(
    Offset center,
    double maxR,
    _BlobParams p, {
    List<(int, double, double, double)>? harmonics,
    double timeOffset = 0.0,
  }) {
    final path = Path();
    const steps = 180;
    final baseR = maxR * p.radius;
    final h = harmonics ?? _harmonics;
    final t = time + timeOffset;

    for (int i = 0; i <= steps; i++) {
      final theta = (i / steps) * 2 * pi;
      double r = baseR;

      for (final harm in h) {
        final (angFreq, tSpeed, ampScale, phase) = harm;
        r +=
            baseR *
            p.amplitude *
            ampScale *
            sin(theta * angFreq + t * tSpeed + phase);
      }

      final x = center.dx + r * cos(theta);
      final y = center.dy + r * sin(theta);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  _BlobParams _params() {
    switch (state) {
      case VoiceState.idle:
        final breath = sin(time * 0.6) * 0.5 + 0.5;
        return _BlobParams(
          radius: 0.52 + breath * 0.03,
          amplitude: 0.12 + breath * 0.02,
          fillOpacity: 0.05 + breath * 0.015,
          coreOpacity: 0.08 + breath * 0.02,
          strokeOpacity: 0.15 + breath * 0.05,
          strokeWidth: 1.2,
          glowOpacity: 0.03 + breath * 0.015,
        );

      case VoiceState.listening:
        final pulse = sin(time * 2.0) * 0.5 + 0.5;
        return _BlobParams(
          radius: 0.58 + pulse * 0.05,
          amplitude: 0.18 + pulse * 0.06,
          fillOpacity: 0.06 + pulse * 0.025,
          coreOpacity: 0.10 + pulse * 0.03,
          strokeOpacity: 0.20 + pulse * 0.10,
          strokeWidth: 1.5,
          glowOpacity: 0.04 + pulse * 0.025,
        );

      case VoiceState.speaking:
        final wave = sin(time * 1.5) * 0.5 + 0.5;
        final wave2 = sin(time * 2.8 + 1.0) * 0.5 + 0.5;
        final mix = wave * 0.55 + wave2 * 0.45;
        return _BlobParams(
          radius: 0.55 + mix * 0.06,
          amplitude: 0.15 + mix * 0.08,
          fillOpacity: 0.06 + mix * 0.02,
          coreOpacity: 0.09 + mix * 0.03,
          strokeOpacity: 0.18 + mix * 0.10,
          strokeWidth: 1.4,
          glowOpacity: 0.035 + mix * 0.02,
        );

      case VoiceState.thinking:
        final slow = sin(time * 0.35) * 0.5 + 0.5;
        return _BlobParams(
          radius: 0.40 + slow * 0.02,
          amplitude: 0.08 + slow * 0.015,
          fillOpacity: 0.04 + slow * 0.01,
          coreOpacity: 0.06 + slow * 0.015,
          strokeOpacity: 0.10 + slow * 0.04,
          strokeWidth: 1.0,
          glowOpacity: 0.02 + slow * 0.01,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _BlobPainter old) => true;
}

class _BlobParams {
  final double radius;
  final double amplitude;
  final double fillOpacity;
  final double coreOpacity;
  final double strokeOpacity;
  final double strokeWidth;
  final double glowOpacity;

  const _BlobParams({
    required this.radius,
    required this.amplitude,
    required this.fillOpacity,
    required this.coreOpacity,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.glowOpacity,
  });

  _BlobParams copyWith({double? radius, double? amplitude}) {
    return _BlobParams(
      radius: radius ?? this.radius,
      amplitude: amplitude ?? this.amplitude,
      fillOpacity: fillOpacity,
      coreOpacity: coreOpacity,
      strokeOpacity: strokeOpacity,
      strokeWidth: strokeWidth,
      glowOpacity: glowOpacity,
    );
  }
}
