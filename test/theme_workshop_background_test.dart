import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/theme_workshop_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('image background tuning groups start collapsed', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalHomePath = YanciTheme.homeBackgroundImagePath;
    final originalChatPath = YanciTheme.chatBackgroundImagePath;
    addTearDown(() async {
      YanciTheme.homeBackgroundImagePath = originalHomePath;
      YanciTheme.chatBackgroundImagePath = originalChatPath;
      await tester.binding.setSurfaceSize(null);
    });
    YanciTheme.homeBackgroundImagePath = '';
    YanciTheme.chatBackgroundImagePath = '';
    await tester.binding.setSurfaceSize(const Size(1080, 2400));

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    final backgroundEntry = find.byKey(
      const ValueKey('theme-image-background-entry'),
    );
    final backgroundEntrySize = tester.getSize(backgroundEntry);
    expect(backgroundEntrySize, const Size(84, 84));
    expect(
      tester
          .getCenter(
            find.descendant(
              of: backgroundEntry,
              matching: find.byIcon(Icons.image_outlined),
            ),
          )
          .dy,
      lessThan(
        tester
            .getCenter(
              find.descendant(of: backgroundEntry, matching: find.text('背景')),
            )
            .dy,
      ),
    );

    await tester.tap(backgroundEntry);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('background-preset-slots')),
      findsOneWidget,
    );
    for (var slot = 1; slot <= 6; slot++) {
      expect(
        find.byKey(ValueKey('background-preset-slot-$slot')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('background-preset-character-binding')),
      findsOneWidget,
    );
    expect(find.text('綁定角色'), findsOneWidget);

    expect(find.text('圖片位置微調'), findsOneWidget);
    expect(find.text('字體氣泡顏色'), findsNothing);
    await tester.tap(find.text('對話框'));
    await tester.pumpAndSettle();
    expect(find.text('字體氣泡顏色'), findsOneWidget);
    final collapsedPosition = tester.widget<AnimatedCrossFade>(
      find.descendant(
        of: find.byKey(const ValueKey('background-chat-position-section')),
        matching: find.byType(AnimatedCrossFade),
      ),
    );
    expect(collapsedPosition.crossFadeState, CrossFadeState.showFirst);
    final collapsedColors = tester.widget<AnimatedCrossFade>(
      find.descendant(
        of: find.byKey(const ValueKey('background-chat-colors-section')),
        matching: find.byType(AnimatedCrossFade),
      ),
    );
    expect(collapsedColors.crossFadeState, CrossFadeState.showFirst);
    expect(
      find.byKey(const ValueKey('chat-background-more-content-hint')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('background-chat-position-section')),
    );
    await tester.pump();
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('左右'), findsOneWidget);
    expect(find.text('上下'), findsOneWidget);
    expect(find.text('模糊度'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('background-chat-colors-section')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('chat-background-color-preview')),
      findsOneWidget,
    );
    expect(find.text('角色氣泡'), findsOneWidget);
    expect(find.text('用戶氣泡'), findsOneWidget);
    expect(find.text('氣泡內字體顏色'), findsOneWidget);
    expect(find.text('Thinking 字體顏色'), findsOneWidget);
    expect(find.text('氣泡透明度'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-background-more-content-hint')),
      findsOneWidget,
    );
    final opacityValue = tester.widget<Text>(
      find.byKey(const ValueKey('chat-background-bubble-opacity-value')),
    );
    expect(opacityValue.maxLines, 1);
    expect(opacityValue.softWrap, isFalse);
    expect(
      tester.getTopLeft(find.text('氣泡透明度')).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('chat-background-bubble-opacity')),
            )
            .dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('image background slots switch and persist independently', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    await tester.tap(
      find.byKey(const ValueKey('theme-image-background-entry')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('background-preset-slot-4')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('background_presets_active_slot_v1'), 4);
    final selectedCircle = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const ValueKey('background-preset-slot-4')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = selectedCircle.decoration! as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.border?.top.width, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image background color accepts HEX and reset restores default', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalAiColor = YanciTheme.chatBackgroundAiBubbleOverride;
    final originalTextColor = YanciTheme.chatBackgroundBubbleTextOverride;
    final originalOpacity = YanciTheme.chatBackgroundBubbleOpacityOverride;
    final defaultHex = YanciTheme.aiBubble
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2)
        .toUpperCase();
    addTearDown(() async {
      YanciTheme.chatBackgroundAiBubbleOverride = originalAiColor;
      YanciTheme.chatBackgroundBubbleTextOverride = originalTextColor;
      YanciTheme.chatBackgroundBubbleOpacityOverride = originalOpacity;
      await tester.binding.setSurfaceSize(null);
    });
    YanciTheme.chatBackgroundAiBubbleOverride = null;
    YanciTheme.chatBackgroundBubbleTextOverride = null;
    YanciTheme.chatBackgroundBubbleOpacityOverride = null;
    await tester.binding.setSurfaceSize(const Size(1080, 2400));

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    await tester.tap(
      find.byKey(const ValueKey('theme-image-background-entry')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('對話框'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('background-chat-colors-section')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('角色氣泡'));
    await tester.tap(find.text('角色氣泡'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('theme-color-hex-input')),
      '#123456',
    );
    await tester.tap(find.byKey(const ValueKey('theme-color-apply')));
    await tester.pumpAndSettle();
    expect(find.text('#123456'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('chat-background-aiBubble-reset')),
    );
    await tester.pumpAndSettle();
    expect(find.text('#$defaultHex'), findsOneWidget);
    expect(YanciTheme.chatBackgroundAiBubbleOverride, isNull);

    await tester.ensureVisible(find.text('氣泡內字體顏色'));
    await tester.tap(find.text('氣泡內字體顏色'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('theme-color-hex-input')),
      '#FEDCBA',
    );
    await tester.tap(find.byKey(const ValueKey('theme-color-apply')));
    await tester.pumpAndSettle();
    final previewText = tester.widget<Text>(
      find.byKey(const ValueKey('chat-color-preview-ai-text')),
    );
    expect(previewText.style?.color, const Color(0xFFFEDCBA));
    expect(tester.takeException(), isNull);
  });
}
