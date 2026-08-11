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

  testWidgets('InputBar unlocks an existing draft without leaving the screen', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'send after recovery');
    var blocked = true;
    var calls = 0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return InputBar(
                externalController: controller,
                isSendBlocked: blocked,
                onSend: (_) => calls++,
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('input_bar_send_button')));
    expect(calls, 0);

    updateHost(() => blocked = false);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('input_bar_send_button')));

    expect(calls, 1);
    expect(controller.text, 'send after recovery');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('InputBar follows a replaced external controller', (
    tester,
  ) async {
    final first = TextEditingController();
    final second = TextEditingController(text: 'replacement draft');
    var submitted = '';

    Widget build(TextEditingController controller) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          externalController: controller,
          onSend: (text) => submitted = text,
        ),
      ),
    );

    await tester.pumpWidget(build(first));
    await tester.pumpWidget(build(second));
    await tester.tap(find.byKey(const ValueKey('input_bar_send_button')));

    expect(submitted, 'replacement draft');

    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    second.dispose();
  });

  testWidgets('InputBar exposes a stop button during response streaming', (
    tester,
  ) async {
    var stopped = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            isGeneratingResponse: true,
            isSendBlocked: true,
            onStopGeneration: () => stopped++,
            onSend: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('input_bar_stop_button')));

    expect(stopped, 1);
  });

  testWidgets('InputBar shows a character-specific whisper', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(hintText: '慢慢說，我在聽', onSend: (_) {}),
        ),
      ),
    );

    expect(find.text('慢慢說，我在聽'), findsOneWidget);
  });
}
