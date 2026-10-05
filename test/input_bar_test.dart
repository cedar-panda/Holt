import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/models/background_preset.dart';
import 'package:project_yanci/services/background_foreground_service.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/widgets/gradient_background.dart';
import 'package:project_yanci/widgets/input_bar.dart';

void main() {
  testWidgets('bound input follows palette, then its manual text color', (
    tester,
  ) async {
    const palette = ChatBubblePalette(
      aiBubble: Color(0xFF111111),
      userBubble: Color(0xFF222222),
      bubbleText: Color(0xFF333333),
      thinkingText: Color(0xFF444444),
      bubbleOpacity: 0.8,
      inputBarBg: Color(0xFF555555),
      inputBarBorder: Color(0xFF666666),
      inputBarText: Color(0xFF777777),
    );

    Future<void> pump(BackgroundPreset preset) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatBackgroundPresetScope(
              preset: preset,
              palette: palette,
              child: InputBar(onSend: (_) {}),
            ),
          ),
        ),
      );
    }

    await pump(const BackgroundPreset(slot: 2, chatPath: 'bound.png'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.color,
      const Color(0xFF777777),
    );

    await pump(
      const BackgroundPreset(
        slot: 2,
        chatPath: 'bound.png',
        chatBubbleTextColor: 0xFFABCDEF,
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.color,
      const Color(0xFFABCDEF),
    );

    YanciTheme.chatBackgroundAutoInputBarText = const Color(0xFFFF0000);
    addTearDown(() => YanciTheme.chatBackgroundAutoInputBarText = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBackgroundPresetScope(
            preset: null,
            child: InputBar(onSend: (_) {}),
          ),
        ),
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.color,
      YanciTheme.textOnBubble,
    );
  });

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

  testWidgets('InputBar centers the caret with a character whisper', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(hintText: '慢慢說，我在聽', onSend: (_) {}),
        ),
      ),
    );

    expect(find.text('慢慢說，我在聽'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textAlignVertical, TextAlignVertical.center);
    expect(field.decoration?.hintText, isNull);
    expect(
      (tester.getCenter(find.byKey(const ValueKey('input_bar_surface'))).dy -
              tester
                  .getCenter(find.byKey(const ValueKey('input_bar_text_field')))
                  .dy)
          .abs(),
      lessThanOrEqualTo(1),
    );

    await tester.enterText(find.byType(TextField), '正文');
    await tester.pump(const Duration(milliseconds: 150));
    final whisper = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('composer-whisper')),
    );
    expect(whisper.opacity, 0);
  });

  testWidgets('RP story archive is a half-width add-panel action', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(onStoryArchiveTap: () => opened++, onSend: (_) {}),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add content'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Story archive'), findsOneWidget);
    final archiveAction = find
        .ancestor(
          of: find.text('Story archive'),
          matching: find.byType(InkWell),
        )
        .first;
    tester.widget<InkWell>(archiveAction).onTap?.call();
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('single-line composer is centered and multiline text can grow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const Spacer(),
              InputBar(onSend: (_) {}),
            ],
          ),
        ),
      ),
    );

    final field = find.byType(TextField);
    final addButton = find.byTooltip('Add content');
    final surface = find.byKey(const ValueKey('input_bar_surface'));
    expect(tester.getSize(surface).height, greaterThanOrEqualTo(72));
    expect(
      (tester.getCenter(surface).dy - tester.getCenter(field).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(
      (tester.getCenter(field).dy - tester.getCenter(addButton).dy).abs(),
      lessThanOrEqualTo(2),
    );
    expect(
      (tester.getCenter(addButton).dy -
              tester
                  .getCenter(
                    find.byKey(const ValueKey('input_bar_send_button')),
                  )
                  .dy)
          .abs(),
      lessThanOrEqualTo(1),
    );
    expect(
      tester.widget<TextField>(field).textAlignVertical,
      TextAlignVertical.center,
    );

    final addCenterBefore = tester.getCenter(addButton);
    final sendCenterBefore = tester.getCenter(
      find.byKey(const ValueKey('input_bar_send_button')),
    );

    await tester.enterText(field, 'one\ntwo\nthree\nfour');
    await tester.pump();
    expect(tester.getSize(field).height, greaterThan(48));
    expect(tester.getCenter(addButton).dy, addCenterBefore.dy);
    expect(
      tester.getCenter(find.byKey(const ValueKey('input_bar_send_button'))).dy,
      sendCenterBefore.dy,
    );
  });

  testWidgets('InputBar opens an inline two-layer action panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InputBar(onSend: (_) {})),
      ),
    );

    await tester.tap(find.byTooltip('Add content'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Sticker'), findsOneWidget);
    expect(find.text('Transfer'), findsOneWidget);
    expect(find.text('Scratch card'), findsOneWidget);
    expect(find.text('Gift shop'), findsOneWidget);
    expect(find.text('Backpack'), findsOneWidget);
    expect(find.text('Add to this message'), findsNothing);
    expect(find.text('QUICK ADD'), findsNothing);
    expect(find.text('MORE INTERACTIONS'), findsNothing);
  });
}
