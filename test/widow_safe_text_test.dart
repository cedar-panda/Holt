import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/widow_safe_text.dart';

void main() {
  testWidgets(
    'protects a single final-line character without changing semantics',
    (tester) async {
      const original = '甲乙丙丁';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 70,
                child: WidowSafeText(
                  original,
                  style: TextStyle(fontSize: 20, height: 1),
                ),
              ),
            ),
          ),
        ),
      );

      final rendered = tester.widget<Text>(find.byType(Text));
      expect(rendered.data, contains('\u2060'));
      expect(rendered.semanticsLabel, original);
      expect(rendered.data!.replaceAll('\u2060', ''), original);
    },
  );
}
