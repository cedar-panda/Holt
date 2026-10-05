import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/api_settings_screen.dart';
import 'package:project_yanci/screens/tool_model_screen.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/widgets/api_advanced_settings.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  testWidgets('API settings owns the default window summary model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final advancedButton = tester.getTopLeft(
      find.byKey(const Key('api_settings_advanced_button')),
    );
    expect(advancedButton.dy, lessThan(80));
    expect(advancedButton.dx, greaterThan(200));
    final advancedStyle = tester
        .widget<TextButton>(
          find.byKey(const Key('api_settings_advanced_button')),
        )
        .style;
    expect(advancedStyle?.foregroundColor?.resolve({}), YanciTheme.accent);

    await tester.scrollUntilVisible(
      find.textContaining('gemini-3-flash'),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('gemini-3-flash'), findsOneWidget);

    await tester.tap(find.byKey(const Key('api_settings_advanced_button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('api_settings_advanced_close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('api_settings_model_search_field')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool model screen no longer owns window summary selection', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ToolModelScreen()));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('gemini-3-flash'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite models can be viewed and removed', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const favorite = StarredModelEntry(
      provider: 'openrouter',
      modelId: 'anthropic/claude-sonnet-4',
    );
    await ApiSettings.saveStarredModelEntryOrder(<StarredModelEntry>[favorite]);

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('api_settings_favorite_models_button')),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const Key('api_settings_favorite_models_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('api_settings_favorite_models_dialog')),
      findsOneWidget,
    );
    expect(find.text('anthropic/claude-sonnet-4'), findsOneWidget);
    await tester.tap(
      find.byKey(
        ValueKey<String>('delete_favorite_model_${favorite.identity}'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('anthropic/claude-sonnet-4'), findsNothing);
    expect(await ApiSettings.getStarredModelEntries(), isEmpty);
  });

  testWidgets('cache summary exposes shared Daily and RP custom rules', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
      'cache_window_summary_enabled': true,
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ApiAdvancedSettings(cacheOnly: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('custom_summary_rules_entry_cache')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('custom_summary_rules_dialog_cache')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('custom_summary_rules_daily_field')),
      findsOneWidget,
    );
    expect(find.text('RP'), findsWidgets);
  });
}
