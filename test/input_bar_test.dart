import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/input_bar.dart';

void main() {
  testWidgets('InputBar does not erase a draft before Chat accepts it', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'keep this draft');
    String? submitted;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            externalController: controller,
            onSend: (text) => submitted = text,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('input_bar_send_button')));
    await tester.pump();

    expect(submitted, 'keep this draft');
    expect(controller.text, 'keep this draft');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('InputBar blocks send without erasing the draft', (tester) async {
    final controller = TextEditingController(text: 'still here');
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            externalController: controller,
            isSendBlocked: true,
            onSend: (_) => calls++,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('input_bar_send_button')));
    await tester.pump();

    expect(calls, 0);
    expect(controller.text, 'still here');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
