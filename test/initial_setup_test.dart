import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/screens/initial_setup_screen.dart';
import 'package:project_yanci/services/initial_setup_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:project_yanci/services/settings/theme_settings.dart';
import 'package:project_yanci/services/settings/user_settings.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/theme/theme_presets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'zh_TW',
      'first_launch_language_version':
          UserSettings.currentFirstLaunchLanguageVersion,
    });
    await L.load();
    YanciTheme.setPreset('dawn');
  });

  test('minimal TA draft persists into the real character stores', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.createSchemaForTesting(db);
    DatabaseHelper.useDatabaseForTesting(db);

    try {
      await UserSettings.saveUserName('昭昭');
      final id = await InitialSetupService.createCharacter(
        const InitialCharacterDraft(
          name: '林澈',
          gender: '女',
          relationship: '關係待定',
          description: '安靜但有主見的同行者',
        ),
      );

      expect(await UserSettings.getUserName(), '昭昭');
      expect(await UserSettings.getCharacterName(), '林澈');
      expect(await UserSettings.getActiveCharacterId(), id);

      final characters = await DatabaseHelper.getCharacters();
      expect(characters, hasLength(1));
      expect(characters.single['name'], '林澈');
      expect(characters.single['gender'], '女');
      expect(characters.single['relationship'], '關係待定');
      expect(characters.single['description'], '安靜但有主見的同行者');
    } finally {
      DatabaseHelper.useDatabaseForTesting(null);
      await db.close();
    }
  });

  test(
    'theme pair can save both slots while activating the day theme',
    () async {
      await ThemeSettings.saveThemePair(
        lightPresetId: 'latte',
        darkPresetId: 'mist',
        activePresetId: 'latte',
      );

      expect(await ThemeSettings.getLastLightPreset(), 'latte');
      expect(await ThemeSettings.getLastDarkPreset(), 'mist');
      expect(await ThemeSettings.getThemePreset(), 'latte');
      expect(await ThemeSettings.getDarkMode(), isFalse);
    },
  );

  testWidgets('name step saves the name and shows only the minimal TA card', (
    tester,
  ) async {
    await _pumpSetup(tester);
    await _continueFromModeStep(tester);

    expect(find.text('怎麼稱呼你～'), findsOneWidget);
    expect(find.text('無需引導 自我探索'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const ValueKey('initial-user-name')),
      '昭昭',
    );
    await tester.tap(find.byKey(const ValueKey('initial-name-continue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(await UserSettings.getUserName(), '昭昭');
    expect(find.textContaining('與你相伴的那個'), findsOneWidget);
    expect(find.text('跳過'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('initial-character-name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('initial-character-gender')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('initial-character-relationship')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('initial-character-description')),
      findsOneWidget,
    );
    expect(find.text('畫畫錨點'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('initial-skip-step')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('initial-theme-step')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('initial-skip-step')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('home-ready'), findsOneWidget);
    expect(await UserSettings.isWeakGuidanceEnabled(), isTrue);
  });

  testWidgets(
    'top skip advances one step while bottom action opts out of all hints',
    (tester) async {
      await _pumpSetup(tester);
      await _continueFromModeStep(tester);

      await tester.tap(find.byKey(const ValueKey('initial-skip-step')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('initial-character-title')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('initial-skip-all')),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -48));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('initial-skip-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('home-ready'), findsOneWidget);
      expect(await UserSettings.shouldShowInitialSetup(), isFalse);
      expect(await UserSettings.isWeakGuidanceEnabled(), isFalse);
    },
  );

  testWidgets('RP preset disables emotion and bio clock', (tester) async {
    await _pumpSetup(tester);

    expect(find.text('記憶 / 劇情時間線'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('RP'));
    await tester.pump();
    await tester.tap(find.text('繼續'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(await MemorySettings.isAbilityEnabled('emotion'), isFalse);
    expect(await MemorySettings.isAbilityEnabled('bioclock'), isFalse);
    expect(await MemorySettings.getTimelineEnabled(), isTrue);
    expect(await MemorySettings.getTimelinePromptMode(), 'plot');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'theme setup saves day and night slots only after the final choice',
    (tester) async {
      await _startAtThemeStep();
      await _pumpSetup(tester);

      expect(find.text('選擇日間與夜間主題'), findsOneWidget);
      expect(find.text('日間'), findsOneWidget);
      expect(find.text('夜間'), findsOneWidget);
      expect(find.text('象牙白'), findsOneWidget);
      final lightWheel = tester.widget<PageView>(
        find.byKey(const ValueKey('initial-theme-carousel-light')),
      );
      expect(
        lightWheel.childrenDelegate.estimatedChildCount,
        presets.where((preset) => !preset.isDark).length,
      );

      await tester.drag(
        find.byKey(const ValueKey('initial-theme-carousel-light')),
        const Offset(-110, 0),
      );
      await tester.pumpAndSettle();

      expect(find.text('初雪'), findsOneWidget);
      expect(YanciTheme.presetId, 'ivory');
      expect(await ThemeSettings.getThemePreset(), 'ivory');

      await tester.tap(find.byKey(const ValueKey('initial-theme-apply')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('initial-theme-carousel-dark')),
        findsOneWidget,
      );
      expect(find.text('夜燈'), findsOneWidget);
      final darkWheel = tester.widget<PageView>(
        find.byKey(const ValueKey('initial-theme-carousel-dark')),
      );
      expect(
        darkWheel.childrenDelegate.estimatedChildCount,
        presets.where((preset) => preset.isDark).length,
      );
      expect(
        lightWheel.childrenDelegate.estimatedChildCount! +
            darkWheel.childrenDelegate.estimatedChildCount!,
        presets.length,
      );

      await tester.drag(
        find.byKey(const ValueKey('initial-theme-carousel-dark')),
        const Offset(-110, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('微醺'), findsOneWidget);
      expect(YanciTheme.presetId, 'ivory');
      expect(await ThemeSettings.getThemePreset(), 'ivory');

      await tester.tap(find.byKey(const ValueKey('initial-theme-apply')));
      await tester.pumpAndSettle();
      expect(find.text('現在先用哪一種？'), findsOneWidget);
      expect(find.text('初雪'), findsWidgets);
      expect(find.text('微醺'), findsWidgets);
      expect(await ThemeSettings.getLastLightPreset(), 'ivory');
      expect(await ThemeSettings.getLastDarkPreset(), 'nightlamp');

      await tester.tap(find.byKey(const ValueKey('initial-theme-start-dark')));
      await tester.pumpAndSettle();

      expect(find.text('home-ready'), findsOneWidget);
      expect(YanciTheme.presetId, 'tipsy');
      expect(await ThemeSettings.getThemePreset(), 'tipsy');
      expect(await ThemeSettings.getLastLightPreset(), 'snow');
      expect(await ThemeSettings.getLastDarkPreset(), 'tipsy');
      expect(await UserSettings.shouldShowInitialSetup(), isFalse);
      expect(await UserSettings.getInitialSetupStep(), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skipping after preview keeps the default theme', (tester) async {
    await _startAtThemeStep();
    await _pumpSetup(tester);

    await tester.drag(
      find.byKey(const ValueKey('initial-theme-carousel-light')),
      const Offset(-110, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('初雪'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('initial-skip-step')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('home-ready'), findsOneWidget);
    expect(YanciTheme.presetId, 'ivory');
    expect(await ThemeSettings.getThemePreset(), 'ivory');
    expect(await ThemeSettings.getLastLightPreset(), 'ivory');
    expect(await ThemeSettings.getLastDarkPreset(), 'nightlamp');
  });
}

Future<void> _startAtThemeStep() async {
  SharedPreferences.setMockInitialValues({
    'app_locale': 'zh_TW',
    'first_launch_language_version':
        UserSettings.currentFirstLaunchLanguageVersion,
    'initial_setup_step': 3,
    'initial_setup_mode': 'advanced',
  });
  await L.load();
  YanciTheme.setPreset('ivory');
}

Future<void> _continueFromModeStep(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('initial-mode-step')), findsOneWidget);
  await tester.tap(find.text('繼續'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpSetup(WidgetTester tester) async {
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
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 720),
          textScaler: TextScaler.linear(1.3),
          disableAnimations: true,
        ),
        child: const InitialSetupScreen(),
      ),
      routes: {'/home': (_) => const Text('home-ready')},
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}
