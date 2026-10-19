import 'package:flutter/material.dart';

/// Prevents a single CJK character from being stranded on the final visual
/// line. The stored text is never changed; word joiners only affect layout.
class WidowSafeText extends StatelessWidget {
  const WidowSafeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.balanceLines = false,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool balanceLines;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final balancedWidth = balanceLines
            ? _balancedTextWidth(
                text: text,
                style: effectiveStyle,
                textScaler: MediaQuery.textScalerOf(context),
                textDirection: Directionality.of(context),
                locale: Localizations.maybeLocaleOf(context),
                maxWidth: constraints.maxWidth,
                maxLines: maxLines,
              )
            : constraints.maxWidth;
        final rendered = _protectTrailingOrphan(
          text: text,
          style: effectiveStyle,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          locale: Localizations.maybeLocaleOf(context),
          maxWidth: balancedWidth,
          maxLines: maxLines,
        );
        return Align(
          alignment: textAlign == TextAlign.center
              ? Alignment.center
              : AlignmentDirectional.centerStart,
          child: SizedBox(
            width: balancedWidth,
            child: Text(
              rendered,
              style: style,
              textAlign: textAlign,
              maxLines: maxLines,
              overflow: overflow,
              semanticsLabel: text,
            ),
          ),
        );
      },
    );
  }
}

double _balancedTextWidth({
  required String text,
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  required double maxWidth,
  required int? maxLines,
}) {
  if (text.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return maxWidth;

  List<LineMetrics>? layoutAt(double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      maxLines: maxLines,
    )..layout(maxWidth: width);
    if (painter.didExceedMaxLines) return null;
    return painter.computeLineMetrics();
  }

  final fullWidthLines = layoutAt(maxWidth);
  if (fullWidthLines == null || fullWidthLines.length < 2) return maxWidth;
  final targetLineCount = fullWidthLines.length;
  var bestWidth = maxWidth;
  var bestScore = double.infinity;

  // Keep the original line count, then choose the width whose visual lines are
  // closest in length. This avoids one short, dangling final line without
  // changing the stored greeting or forcing manual line breaks.
  for (var step = 0; step <= 12; step++) {
    final factor = 1.0 - step * 0.025;
    final width = maxWidth * factor;
    final lines = layoutAt(width);
    if (lines == null || lines.length != targetLineCount) continue;
    final widths = lines.map((line) => line.width).toList(growable: false);
    final widest = widths.reduce((a, b) => a > b ? a : b);
    final narrowest = widths.reduce((a, b) => a < b ? a : b);
    final lastGap = (widths.last - widths.first).abs();
    final score = (widest - narrowest) + lastGap * 0.35;
    if (score < bestScore) {
      bestScore = score;
      bestWidth = width;
    }
  }
  return bestWidth;
}

String _protectTrailingOrphan({
  required String text,
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  required double maxWidth,
  required int? maxLines,
}) {
  if (text.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return text;

  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.start,
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  final lines = painter.computeLineMetrics();
  if (lines.length < 2 || painter.didExceedMaxLines) return text;

  final lastLine = painter.getLineBoundary(
    TextPosition(offset: text.length, affinity: TextAffinity.upstream),
  );
  final graphemes = text.characters.toList(growable: false);
  final offsets = <int>[];
  var offset = 0;
  for (final grapheme in graphemes) {
    offsets.add(offset);
    offset += grapheme.length;
  }

  final meaningfulOnLastLine = <int>[];
  for (var i = 0; i < graphemes.length; i++) {
    if (offsets[i] < lastLine.start) continue;
    if (_isMeaningfulGrapheme(graphemes[i])) meaningfulOnLastLine.add(i);
  }
  if (meaningfulOnLastLine.length > 1) return text;

  var lastMeaningful = -1;
  var previousMeaningful = -1;
  for (var i = graphemes.length - 1; i >= 0; i--) {
    if (!_isMeaningfulGrapheme(graphemes[i])) continue;
    if (lastMeaningful < 0) {
      lastMeaningful = i;
    } else {
      previousMeaningful = i;
      break;
    }
  }
  if (previousMeaningful < 0 || lastMeaningful < 0) return text;

  final protectedTail = graphemes.sublist(previousMeaningful).join('\u2060');
  final tailPainter = TextPainter(
    text: TextSpan(text: protectedTail, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: 1,
  )..layout(maxWidth: double.infinity);
  if (tailPainter.width > maxWidth) return text;

  return '${graphemes.take(previousMeaningful).join()}$protectedTail';
}

bool _isMeaningfulGrapheme(String grapheme) {
  if (grapheme.trim().isEmpty) return false;
  return !RegExp(r'^[\p{P}\p{S}]+$', unicode: true).hasMatch(grapheme);
}
