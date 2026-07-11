import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class CoinAmountText extends StatelessWidget {
  const CoinAmountText(this.amount, {super.key});

  final int amount;

  @override
  Widget build(BuildContext context) {
    final text = amount.toString();
    final style = TextStyle(
      fontSize: 15,
      fontFamily: YanciTheme.fontFamily,
      fontWeight: FontWeight.w500,
      color: const Color(0xFFF2C96D),
      fontFeatures: const [
        FontFeature.liningFigures(),
        FontFeature.tabularFigures(),
      ],
    );

    return Semantics(
      label: text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            for (final char in text.split('')) Text(char, style: style),
          ],
        ),
      ),
    );
  }
}
