import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/long_screenshot_options_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long screenshot options choose range and private details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    LongScreenshotOptions? result;
    const messages = <LongScreenshotMessageOption>[
      LongScreenshotMessageOption(
        speaker: '你',
        preview: '第一條',
        time: '07/23 10:00',
      ),
      LongScreenshotMessageOption(
        speaker: '角色',
        preview: '第二條',
        time: '07/23 10:01',
      ),
      LongScreenshotMessageOption(
        speaker: '你',
        preview: '第三條',
        time: '07/23 10:02',
      ),
      LongScreenshotMessageOption(
        speaker: '角色',
        preview: '第四條',
        time: '07/23 10:03',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showLongScreenshotOptionsSheet(
                  context: context,
                  messages: messages,
                  maxSelectionCount: 3,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheetSurface = tester.widget<Material>(
      find.byKey(const ValueKey('longshot-sheet-surface')),
    );
    expect(sheetSurface.color!.a, 1);
    expect(find.text('已選 3 條 · 最多 3 條'), findsOneWidget);
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(
              of: find.byKey(const ValueKey('longshot-thinking-toggle')),
              matching: find.byType(Checkbox),
            ),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(
              of: find.byKey(const ValueKey('longshot-memory-toggle')),
              matching: find.byType(Checkbox),
            ),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(
              of: find.byKey(const ValueKey('longshot-emotion-toggle')),
              matching: find.byType(Checkbox),
            ),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('longshot-thinking-toggle')));
    await tester.tap(find.byKey(const ValueKey('longshot-memory-toggle')));
    await tester.tap(find.byKey(const ValueKey('longshot-emotion-toggle')));
    await tester.tap(find.byKey(const ValueKey('longshot-start-selector')));
    await tester.tap(find.byKey(const ValueKey('longshot-message-0')));
    await tester.tap(find.byKey(const ValueKey('longshot-message-1')));
    await tester.pump();
    expect(find.text('已選 2 條 · 最多 3 條'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('longshot-confirm')));
    await tester.pumpAndSettle();
    expect(result?.startIndex, 0);
    expect(result?.endIndex, 1);
    expect(result?.expandThinking, isTrue);
    expect(result?.includeMemory, isTrue);
    expect(result?.includeEmotion, isTrue);
    expect(tester.takeException(), isNull);
  });
}
