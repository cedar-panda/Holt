import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum YanciBackgroundScope { none, home, chat }

/// 全 app 共用的漸變背景（帶 dithering 消除色帶）
class GradientBackground extends StatelessWidget {
  final Widget child;
  final YanciBackgroundScope scope;

  const GradientBackground({
    super.key,
    required this.child,
    this.scope = YanciBackgroundScope.none,
  });

  @override
  Widget build(BuildContext context) {
    final base = YanciTheme.backgroundGradient;
    final smoothColors = <Color>[];
    final smoothStops = <double>[];
    final baseStops = [0.0, 0.35, 0.65, 1.0];
    const subdivisions = 4;

    for (int i = 0; i < base.length - 1; i++) {
      for (int j = 0; j < subdivisions; j++) {
        final t = j / subdivisions;
        smoothColors.add(Color.lerp(base[i], base[i + 1], t)!);
        smoothStops.add(baseStops[i] + (baseStops[i + 1] - baseStops[i]) * t);
      }
    }
    smoothColors.add(base.last);
    smoothStops.add(1.0);

    final customBackground = _customBackground();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: smoothColors,
          stops: smoothStops,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?customBackground,
          CustomPaint(painter: _DitherPainter(), child: child),
        ],
      ),
    );
  }

  Widget? _customBackground() {
    final path = switch (scope) {
      YanciBackgroundScope.home => YanciTheme.homeBackgroundImagePath,
      YanciBackgroundScope.chat => YanciTheme.chatBackgroundImagePath,
      YanciBackgroundScope.none => '',
    };
    if (path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;

    final scale = switch (scope) {
      YanciBackgroundScope.home => YanciTheme.homeBackgroundImageScale,
      YanciBackgroundScope.chat => YanciTheme.chatBackgroundImageScale,
      YanciBackgroundScope.none => 1.0,
    };
    final offsetX = switch (scope) {
      YanciBackgroundScope.home => YanciTheme.homeBackgroundImageOffsetX,
      YanciBackgroundScope.chat => YanciTheme.chatBackgroundImageOffsetX,
      YanciBackgroundScope.none => 0.0,
    };
    final offsetY = switch (scope) {
      YanciBackgroundScope.home => YanciTheme.homeBackgroundImageOffsetY,
      YanciBackgroundScope.chat => YanciTheme.chatBackgroundImageOffsetY,
      YanciBackgroundScope.none => 0.0,
    };

    return Positioned.fill(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Transform.translate(
              offset: Offset(
                offsetX.clamp(-0.5, 0.5).toDouble() * constraints.maxWidth,
                offsetY.clamp(-0.5, 0.5).toDouble() * constraints.maxHeight,
              ),
              child: Transform.scale(
                scale: scale.clamp(0.8, 2.0).toDouble(),
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 極輕的噪點層 — 打破色帶的視覺邊界
class _DitherPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(42); // 固定種子，避免每次重繪閃爍
    final paint = Paint();
    const density = 0.12; // 噪點密度
    final total = (size.width * size.height * density / 100).toInt();

    for (int i = 0; i < total; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final bright = random.nextBool();
      paint.color = bright
          ? Colors.white.withValues(alpha: 0.015)
          : Colors.black.withValues(alpha: 0.012);
      canvas.drawCircle(Offset(x, y), 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
