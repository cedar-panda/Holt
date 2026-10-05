import 'package:flutter/material.dart';

import '../services/character_signature_prompt.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../utils/text_safety.dart';

/// 顯示角色資料中已保存的個性簽名。
class CharacterSignaturePanel extends StatelessWidget {
  final bool compact;
  final String? signature;
  final VoidCallback? onShowHistory;
  final Color? foregroundColor;
  final Color? ruleColor;

  const CharacterSignaturePanel({
    super.key,
    this.compact = false,
    this.signature,
    this.onShowHistory,
    this.foregroundColor,
    this.ruleColor,
  });

  String _displayText() {
    final fallback = L.pick(
      en: 'ta has nothing to say yet~',
      zhTW: 'ta還沒有想說的～',
      zhCN: 'ta还没有想说的～',
    );
    final value = signature?.trim();
    if (value == null || value.isEmpty) return fallback;
    return truncateGraphemes(value, CharacterSignaturePrompt.maxCharacters);
  }

  @override
  Widget build(BuildContext context) {
    final child = _buildPanel(context);
    if (onShowHistory == null) return child;
    return Semantics(
      button: true,
      label: L.pick(
        en: 'View signature history',
        zhTW: '查看個性簽名歷史',
        zhCN: '查看个性签名历史',
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onShowHistory,
        child: child,
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    if (compact) {
      final text = _displayText();
      final textStyle = TextStyle(
        fontSize: 10,
        height: 1.45,
        color:
            foregroundColor ??
            YanciTheme.characterResourceLabel.withValues(alpha: 0.72),
        fontFamily: YanciTheme.fontFamily,
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? (constraints.maxWidth - 4).clamp(1.0, double.infinity)
              : 240.0;
          final measure = TextPainter(
            text: TextSpan(text: text, style: textStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 2,
            ellipsis: '…',
          )..layout(maxWidth: maxWidth);
          final lineCount = measure.computeLineMetrics().length.clamp(1, 2);
          final height = (measure.preferredLineHeight * lineCount + 8)
              .clamp(32.0, 46.0)
              .toDouble();

          return CustomPaint(
            painter: _SignatureRulePainter(
              color:
                  ruleColor?.withValues(alpha: 0.42) ??
                  YanciTheme.accent.withValues(
                    alpha: YanciTheme.isDark ? 0.14 : 0.10,
                  ),
              lineCount: lineCount,
              verticalOffset: 8,
            ),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 2, 4, 3),
                  child: Text(
                    text,
                    maxLines: lineCount,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 0),
          child: Text(
            L.pick(en: 'Signature', zhTW: '個性簽名', zhCN: '个性签名'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color:
                  foregroundColor ??
                  YanciTheme.textPrimary.withValues(alpha: 0.7),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        ),
        const SizedBox(height: 2),
        CustomPaint(
          painter: _SignatureRulePainter(
            color:
                ruleColor?.withValues(alpha: 0.42) ??
                YanciTheme.accent.withValues(
                  alpha: YanciTheme.isDark ? 0.14 : 0.10,
                ),
            lineCount: CharacterSignaturePrompt.maxLines,
          ),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 4, 3),
                child: Text(
                  _displayText(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.55,
                    color:
                        foregroundColor ??
                        YanciTheme.characterResourceLabel.withValues(
                          alpha: 0.72,
                        ),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SignatureRulePainter extends CustomPainter {
  final Color color;
  final int lineCount;
  final double verticalOffset;

  const _SignatureRulePainter({
    required this.color,
    required this.lineCount,
    this.verticalOffset = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.75
      ..strokeCap = StrokeCap.round;
    final drawableHeight = size.height - verticalOffset;
    final spacing = drawableHeight / lineCount;
    for (var line = 0; line < lineCount; line++) {
      final baseline = verticalOffset + spacing * (line + 1) - 5;
      var x = 0.0;
      var dash = 0;
      while (x < size.width) {
        final length = switch (dash % 3) {
          0 => 8.0,
          1 => 11.0,
          _ => 6.0,
        };
        final wobble = switch (dash % 4) {
          0 => -0.25,
          1 => 0.15,
          2 => 0.3,
          _ => -0.1,
        };
        final end = (x + length).clamp(0.0, size.width);
        canvas.drawLine(
          Offset(x, baseline + wobble),
          Offset(end, baseline - wobble),
          paint,
        );
        x = end + 4.5;
        dash++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignatureRulePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.lineCount != lineCount ||
      oldDelegate.verticalOffset != verticalOffset;
}
