import 'package:flutter/material.dart';

enum BubbleActionGlyphType { copy, bookmark, soundWave }

/// 氣泡工具列共用的細線圖標。
///
/// 視覺尺寸刻意小於外層點擊槽：筆畫跟 Thinking 的小型 outline icon
/// 同層級，但不縮小既有的操作範圍。
class BubbleActionGlyph extends StatelessWidget {
  static const double defaultSize = 15;
  static const double strokeWidth = 1;

  final BubbleActionGlyphType type;
  final Color color;
  final bool selected;
  final double size;

  const BubbleActionGlyph({
    super.key,
    required this.type,
    required this.color,
    this.selected = false,
    this.size = defaultSize,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BubbleActionGlyphPainter(
          type: type,
          color: color,
          selected: selected,
        ),
      ),
    );
  }
}

class _BubbleActionGlyphPainter extends CustomPainter {
  final BubbleActionGlyphType type;
  final Color color;
  final bool selected;

  const _BubbleActionGlyphPainter({
    required this.type,
    required this.color,
    required this.selected,
  });

  Paint _strokePaint() => Paint()
    ..isAntiAlias = true
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = BubbleActionGlyph.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    switch (type) {
      case BubbleActionGlyphType.copy:
        _paintCopy(canvas, size);
      case BubbleActionGlyphType.bookmark:
        _paintBookmark(canvas, size);
      case BubbleActionGlyphType.soundWave:
        _paintSoundWave(canvas, size);
    }
  }

  void _paintCopy(Canvas canvas, Size size) {
    final paint = _strokePaint();
    final side = size.shortestSide;
    final boxSize = side * 0.67;
    final gap = side * 0.18;
    final origin = (side - boxSize - gap) / 2;
    final radius = Radius.circular(side * 0.05);

    final backRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(origin, origin, boxSize, boxSize),
      radius,
    );
    final frontRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(origin + gap, origin + gap, boxSize, boxSize),
      radius,
    );

    canvas.save();
    final clip = Path()
      ..addRect(Rect.fromLTWH(-1, -1, side + 2, side + 2))
      ..addRRect(frontRect)
      ..fillType = PathFillType.evenOdd;
    canvas.clipPath(clip);
    canvas.drawRRect(backRect, paint);
    canvas.restore();
    canvas.drawRRect(frontRect, paint);
  }

  void _paintBookmark(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final path = Path()
      ..moveTo(side * 0.29, side * 0.18)
      ..quadraticBezierTo(side * 0.25, side * 0.18, side * 0.25, side * 0.24)
      ..lineTo(side * 0.25, side * 0.84)
      ..lineTo(side * 0.5, side * 0.68)
      ..lineTo(side * 0.75, side * 0.84)
      ..lineTo(side * 0.75, side * 0.24)
      ..quadraticBezierTo(side * 0.75, side * 0.18, side * 0.71, side * 0.18)
      ..close();

    if (selected) {
      canvas.drawPath(
        path,
        Paint()
          ..isAntiAlias = true
          ..color = color.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      );
    }
    canvas.drawPath(path, _strokePaint());
  }

  void _paintSoundWave(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final paint = _strokePaint();
    final lines = <(double, double, double)>[
      (0.28, 0.38, 0.66),
      (0.5, 0.2, 0.82),
      (0.72, 0.32, 0.7),
    ];
    for (final line in lines) {
      canvas.drawLine(
        Offset(side * line.$1, side * line.$2),
        Offset(side * line.$1, side * line.$3),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BubbleActionGlyphPainter oldDelegate) =>
      oldDelegate.type != type ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected;
}
