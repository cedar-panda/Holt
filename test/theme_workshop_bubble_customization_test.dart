import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/theme_workshop_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings_manager.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/theme/theme_presets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unwashed ink preset keeps its cool ink semantic palette', () {
    final preset = findPreset('yanci');

    expect(preset.name, '未洗硯');
    expect(preset.isDark, isTrue);
    expect(preset.bg1, const Color(0xFF121214));
    expect(preset.aiBubble, const Color(0xFF1E1E22));
    expect(preset.textPrimary, const Color(0xFFD8D6D2));
    expect(preset.accent, const Color(0xFF8A9AAE));
    expect(presets.where((item) => item.id == 'yanci'), hasLength(1));
  });

  testWidgets('send button previews persist the selected built-in style', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalStyle = YanciTheme.sendButtonStyle;
    final originalPath = YanciTheme.sendButtonCustomPath;
    addTearDown(() async {
      YanciTheme.sendButtonStyle = originalStyle;
      YanciTheme.sendButtonCustomPath = originalPath;
      await tester.binding.setSurfaceSize(null);
    });
    YanciTheme.sendButtonStyle = 'leaf';
    YanciTheme.sendButtonCustomPath = '';
    await tester.binding.setSurfaceSize(const Size(1080, 2400));

    await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
    await tester.pumpAndSettle();

    for (final style in <String>['leaf', 'paw', 'shell', 'custom']) {
      expect(find.byKey(ValueKey('theme-send-button-$style')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('theme-send-button-shell')));
    await tester.pump();
    expect(await ThemeSettings.getSendButtonStyle(), 'shell');
    expect(YanciTheme.sendButtonStyle, 'shell');
  });

  testWidgets(
    'bubble colors preview, persist per theme, and reset to preset defaults',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await L.setLocale('zh_TW');

      final originalPreset = YanciTheme.presetId;
      final originalOpacity = YanciTheme.bubbleOpacity;
      final originalBrightness = YanciTheme.bubbleBrightness;
      final originalAiBubbleFlat = YanciTheme.aiBubbleFlat;
      final originalOverrides = <ThemeBubbleColorRole, Color?>{
        for (final role in ThemeBubbleColorRole.values)
          role: YanciTheme.bubbleColorOverride('ivory', role),
      };
      addTearDown(() async {
        for (final role in ThemeBubbleColorRole.values) {
          YanciTheme.setBubbleColorOverride(
            'ivory',
            role,
            originalOverrides[role],
          );
        }
        YanciTheme.bubbleOpacity = originalOpacity;
        YanciTheme.bubbleBrightness = originalBrightness;
        YanciTheme.aiBubbleFlat = originalAiBubbleFlat;
        YanciTheme.setPreset(originalPreset);
        await tester.binding.setSurfaceSize(null);
      });

      YanciTheme.setPreset('ivory');
      YanciTheme.bubbleOpacity = 1;
      YanciTheme.bubbleBrightness = 0;
      YanciTheme.aiBubbleFlat = false;
      for (final role in ThemeBubbleColorRole.values) {
        YanciTheme.setBubbleColorOverride('ivory', role, null);
      }
      await tester.binding.setSurfaceSize(const Size(1080, 2400));

      await tester.pumpWidget(const MaterialApp(home: ThemeWorkshopScreen()));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('theme-bubble-section-toggle')),
      );
      await tester.pumpAndSettle();

      Future<void> applyColor(ThemeBubbleColorRole role, String hex) async {
        await tester.tap(find.byKey(ValueKey('theme-bubble-${role.name}-row')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('theme-color-hex-input')),
          hex,
        );
        await tester.tap(find.byKey(const ValueKey('theme-color-apply')));
        await tester.pumpAndSettle();
      }

      await applyColor(ThemeBubbleColorRole.aiBubble, '#123456');
      expect(YanciTheme.aiBubble, const Color(0xFF123456));
      final aiPreview = tester.widget<Container>(
        find.byKey(const ValueKey('theme-hero-ai-bubble')),
      );
      expect(
        (aiPreview.decoration! as BoxDecoration).color,
        const Color(0xFF123456),
      );

      await tester.tap(find.text('平鋪'));
      await tester.pumpAndSettle();
      await applyColor(ThemeBubbleColorRole.textOnBubble, '#FEDCBA');
      expect(YanciTheme.textOnBubble, const Color(0xFFFEDCBA));
      final aiText = tester.widget<Text>(
        find.byKey(const ValueKey('theme-hero-ai-text')),
      );
      expect(aiText.style?.color, const Color(0xFFFEDCBA));

      YanciTheme.setPreset('dawn');
      expect(YanciTheme.aiBubble, findPreset('dawn').aiBubble);
      YanciTheme.setPreset('ivory');
      expect(YanciTheme.aiBubble, const Color(0xFF123456));

      YanciTheme.setBubbleColorOverride(
        'ivory',
        ThemeBubbleColorRole.aiBubble,
        null,
      );
      await ThemeSettings.restoreThemeBubbleColors('ivory');
      expect(YanciTheme.aiBubble, const Color(0xFF123456));

      await tester.tap(
        find.byKey(const ValueKey('theme-bubble-aiBubble-reset')),
      );
      await tester.pumpAndSettle();
      expect(YanciTheme.aiBubble, findPreset('ivory').aiBubble);

      await tester.tap(
        find.byKey(const ValueKey('theme-bubble-textOnBubble-reset')),
      );
      await tester.pumpAndSettle();
      expect(YanciTheme.textOnBubble, findPreset('ivory').textOnBubble);
      expect(tester.takeException(), isNull);
    },
  );
}
