import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/splash_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/user_settings.dart';
import 'package:project_yanci/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await L.setLocale('en');
    SharedPreferences.setMockInitialValues({});
    YanciTheme.setPreset('dawn');
  });

  test('fresh installs require a language choice', () async {
    expect(await UserSettings.shouldShowFirstLaunchLanguage(), isTrue);
    expect(await UserSettings.getFirstLaunchLanguageVersion(), 0);

    await UserSettings.completeFirstLaunchLanguage();

    expect(await UserSettings.shouldShowFirstLaunchLanguage(), isFalse);
    expect(
      await UserSettings.getFirstLaunchLanguageVersion(),
      UserSettings.currentFirstLaunchLanguageVersion,
    );
    expect(await UserSettings.getNamePromptCompleted(), isTrue);
    expect(await UserSettings.shouldShowInitialSetup(), isTrue);
  });

  test(
    'existing users are migrated without seeing the language gate',
    () async {
      SharedPreferences.setMockInitialValues({'name_prompt_completed': true});

      expect(await UserSettings.shouldShowFirstLaunchLanguage(), isFalse);
      expect(
        await UserSettings.getFirstLaunchLanguageVersion(),
        UserSettings.currentFirstLaunchLanguageVersion,
      );
      expect(await UserSettings.shouldShowInitialSetup(), isFalse);
      expect(await UserSettings.isWeakGuidanceEnabled(), isFalse);
    },
  );

  testWidgets('first launch chooses language directly under the otter logo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: YanciTheme.themeData,
        routes: {
          '/': (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: const SplashScreen(),
          ),
          '/initial_setup': (_) => const Text('setup-ready'),
          '/home': (_) => const Text('home-ready'),
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.bySemanticsLabel('Holt'), findsOneWidget);
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(
      find.byKey(const ValueKey('splash-star-feather-mask')),
      findsOneWidget,
    );
    expect(find.text('繁體中文'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('first-language-zh_TW')));
    await tester.pump();
    await tester.pump();

    expect(find.text('setup-ready'), findsOneWidget);
    expect(L.locale, 'zh_TW');
    expect(await UserSettings.shouldShowFirstLaunchLanguage(), isFalse);
  });

  test(
    'skip-all preference only changes when the full setup is completed',
    () async {
      SharedPreferences.setMockInitialValues({
        'first_launch_language_version':
            UserSettings.currentFirstLaunchLanguageVersion,
      });

      expect(await UserSettings.shouldShowInitialSetup(), isTrue);
      expect(await UserSettings.isWeakGuidanceEnabled(), isTrue);

      await UserSettings.completeInitialSetup(skipAllGuidance: true);

      expect(await UserSettings.shouldShowInitialSetup(), isFalse);
      expect(await UserSettings.isWeakGuidanceEnabled(), isFalse);
      expect(
        await UserSettings.getInitialSetupVersion(),
        UserSettings.currentInitialSetupVersion,
      );
    },
  );
}
