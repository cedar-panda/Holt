import 'package:flutter/material.dart';

import '../services/character_signature_prompt.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../utils/text_safety.dart';

/// 顯示角色資料中已保存的個性簽名。
class CharacterSignaturePanel extends StatelessWidget {
  final bool compact;
  final String? signature;

  const CharacterSignaturePanel({
    super.key,
    this.compact = false,
    this.signature,
  });

  String _displayText() {
    final fallback = L.pick(
      en: 'ta has nothing to say yet~',
      zhTW: 'ta還沒有想說的～',
      zhCN: 'ta还没有想说的～',
    );
    final value = signature?.trim();
    if (value == null || value.isEmpty) return fallback;
    return truncateGraphemes(
      value,
      compact
          ? CharacterSignaturePrompt.compactMaxCharacters
          : CharacterSignaturePrompt.maxCharacters,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return CustomPaint(
        painter: _SignatureRulePainter(
          color: YanciTheme.accent.withValues(
            alpha: YanciTheme.isDark ? 0.14 : 0.10,
          ),
          lineCount: 1,
        ),
        child: SizedBox(
          height: 24,
          width: double.infinity,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 3, right: 4),
              child: Text(
                _displayText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.45,
                  color: YanciTheme.characterResourceLabel.withValues(
                    alpha: 0.72,
                  ),
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ),
          ),
        ),
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
              color: YanciTheme.textPrimary.withValues(alpha: 0.7),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        ),
        const SizedBox(height: 2),
        CustomPaint(
          painter: _SignatureRulePainter(
            color: YanciTheme.accent.withValues(
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
                    color: YanciTheme.characterResourceLabel.withValues(
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

  const _SignatureRulePainter({required this.color, required this.lineCount});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.75
      ..strokeCap = StrokeCap.round;
    final spacing = size.height / lineCount;
    for (var line = 0; line < lineCount; line++) {
      final baseline = spacing * (line + 1) - 2;
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
      oldDelegate.color != color || oldDelegate.lineCount != lineCount;
}
