import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:project_yanci/models/background_preset.dart';
import 'package:project_yanci/services/background_foreground_service.dart';
import 'package:project_yanci/services/image_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings_manager.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/widgets/gradient_background.dart';
import 'package:project_yanci/widgets/input_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('en');
  });

  test(
    'send button preference persists shell and rejects unknown styles',
    () async {
      await ThemeSettings.saveSendButtonStyle('shell');
      expect(await ThemeSettings.getSendButtonStyle(), 'shell');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('send_button_style', 'unexpected-style');
      expect(await ThemeSettings.getSendButtonStyle(), 'leaf');
    },
  );

  test('custom send button accepts only square PNG data', () {
    final square = img.encodePng(img.Image(width: 24, height: 24));
    final rectangle = img.encodePng(img.Image(width: 32, height: 20));

    expect(
      ImageService.validateSendButtonPngBytes(square),
      SendButtonImageValidation.valid,
    );
    expect(
      ImageService.validateSendButtonPngBytes(rectangle),
      SendButtonImageValidation.notSquare,
    );
    expect(
      ImageService.validateSendButtonPngBytes(<int>[0xFF, 0xD8, 0xFF]),
      SendButtonImageValidation.notPng,
    );
  });

  testWidgets('missing custom send button path falls back to leaf', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            sendStyle: SendButtonStyle.custom,
            sendCustomPath: '/missing/custom-send-button.png',
            onSend: (_) {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('send-button-image-leaf')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('send-button-image-custom')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lit paw contrasts with both light and dark theme accents', (
    tester,
  ) async {
    final originalPreset = YanciTheme.presetId;
    addTearDown(() => YanciTheme.setPreset(originalPreset));
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);

    for (final presetId in ['ivory', 'nightlamp']) {
      YanciTheme.setPreset(presetId);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              key: ValueKey(presetId),
              externalController: controller,
              sendStyle: SendButtonStyle.paw,
              onSend: (_) {},
            ),
          ),
        ),
      );

      final pawFilter = tester.widget<ColorFiltered>(
        find.ancestor(
          of: find.byKey(const ValueKey('send-button-image-paw')),
          matching: find.byType(ColorFiltered),
        ),
      );
      final expectedInk = YanciTheme.accent.computeLuminance() > 0.179
          ? Colors.black
          : Colors.white;
      expect(
        pawFilter.colorFilter,
        ColorFilter.mode(expectedInk, BlendMode.modulate),
      );
    }

    controller.clear();
    await tester.pump();
    final idleFilter = tester.widget<ColorFiltered>(
      find.ancestor(
        of: find.byKey(const ValueKey('send-button-image-paw')),
        matching: find.byType(ColorFiltered),
      ),
    );
    expect(
      idleFilter.colorFilter,
      ColorFilter.mode(YanciTheme.accent, BlendMode.modulate),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bound input follows palette, then its manual text color', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('holt-input-bg-');
    final background = File('${tempDir.path}/bound.png')..writeAsBytesSync([0]);
    addTearDown(() => tempDir.deleteSync(recursive: true));
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

    await pump(BackgroundPreset(slot: 2, chatPath: background.path));
    expect(
      tester.widget<TextField>(find.byType(TextField)).style?.color,
      const Color(0xFF777777),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).keyboardAppearance,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const ValueKey('input_bar_add_button')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<Text>(find.text('Photo')).style?.color,
      const Color(0xFF777777),
    );

    await pump(
      BackgroundPreset(
        slot: 2,
        chatPath: background.path,
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
      YanciTheme.textPrimary,
    );
  });

  testWidgets('marriage certificate keeps cache details out of the ritual', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            marriageCertPending: true,
            onCancelMarriageCert: () {},
            onSend: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('結婚證書'), findsOneWidget);
    expect(find.textContaining('重建一次緩存'), findsNothing);

    // InputBar owns an idle animation; unmount it so the test can finalize.
    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('daily call is available from the add panel', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(onCallTap: () => calls++, onSend: (_) {}),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add content'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Call'), findsOneWidget);
    final callAction = find
        .ancestor(of: find.text('Call'), matching: find.byType(InkWell))
        .first;
    tester.widget<InkWell>(callAction).onTap?.call();
    await tester.pump();
    expect(calls, 1);
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
