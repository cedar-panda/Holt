import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/api_settings_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:project_yanci/services/settings/web_search_settings.dart';
import 'package:project_yanci/services/web_search_service.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  test(
    'web search defaults are enabled in developer preview and bounded',
    () async {
      expect(await WebSearchSettings.getEnabled(), isTrue);
      expect(await WebSearchSettings.getMode(), WebSearchMode.auto);
      expect(
        await WebSearchSettings.getDailyProviderLaunchCap(),
        WebSearchSettings.defaultDailyProviderLaunchCap,
      );
    },
  );

  test('compile-time developer-preview gate controls live state', () async {
    await WebSearchSettings.saveEnabled(true);
    expect(
      await WebSearchSettings.getEnabled(),
      webSearchLiveDeveloperPreviewEnabled,
    );
  });

  test('web search mode and enabled state round-trip', () async {
    await WebSearchSettings.saveEnabled(true);
    expect(await WebSearchSettings.getEnabled(), isTrue);

    for (final mode in WebSearchMode.values.where(
      (mode) => mode != WebSearchMode.dual,
    )) {
      await WebSearchSettings.saveMode(mode);
      expect(await WebSearchSettings.getMode(), mode);
    }

    await WebSearchSettings.saveMode(WebSearchMode.dual);
    expect(await WebSearchSettings.getMode(), WebSearchMode.auto);
  });

  test('daily provider-launch cap clamps writes to 1 through 100', () async {
    await WebSearchSettings.saveDailyProviderLaunchCap(0);
    expect(await WebSearchSettings.getDailyProviderLaunchCap(), 1);

    await WebSearchSettings.saveDailyProviderLaunchCap(101);
    expect(await WebSearchSettings.getDailyProviderLaunchCap(), 100);
  });

  test('unknown persisted mode falls back to auto', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'web_search_mode_v1': 'future-mode',
    });

    expect(await WebSearchSettings.getMode(), WebSearchMode.auto);
  });

  test(
    'retired OpenRouter default resolves in memory without rewriting it',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'web_search_openrouter_model_v1': 'google/gemini-2.0-flash-001',
      });
      await ApiSettings.saveOpenRouterApiKey('openrouter-test-key');

      final configuration =
          await const ApiSettingsWebSearchConfigurationSource().load();
      final openRouter = configuration.providers.singleWhere(
        (provider) => provider.id == WebSearchProviderId.openRouter,
      );

      expect(openRouter.model, openRouterWebSearchPreviewModel);
      expect(
        await WebSearchSettings.getOpenRouterSearchModel(),
        'google/gemini-2.0-flash-001',
        reason: 'read-time migration must not mutate existing preferences',
      );
    },
  );

  test('legacy dual source migrates to auto', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'web_search_mode_v1': 'dual',
    });

    expect(await WebSearchSettings.getMode(), WebSearchMode.auto);
  });

  testWidgets('auto source lists every starred model for its resolved source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await L.setLocale('zh_TW');
    await WebSearchSettings.saveEnabled(true);
    await WebSearchSettings.saveMode(WebSearchMode.auto);
    await ApiSettings.saveGeminiApiKey('gemini-test-key');
    await ApiSettings.saveProviderModelSelection('gemini', 'gemini-2.5-flash');
    await ApiSettings.toggleStarModel('gemini-2.5-flash', provider: 'gemini');
    await ApiSettings.toggleStarModel(
      'gemini-3.1-flash-preview',
      provider: 'gemini',
    );

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final settingsList = find.byType(ListView).first;
    for (var i = 0; i < 5; i++) {
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Gemini · 已就緒'), findsOneWidget);
    final modelDropdowns = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<String>,
    );
    final searchDropdown = tester
        .widgetList<DropdownButton<String>>(modelDropdowns)
        .singleWhere(
          (dropdown) => dropdown.items!.any(
            (item) => item.value == 'gemini-3.1-flash-preview',
          ),
        );
    final choices = searchDropdown.items!.map((item) => item.value);
    expect(choices, contains('gemini-2.5-flash'));
    expect(choices, contains('gemini-3.1-flash-preview'));
    expect(find.textContaining('請先在上方替此來源的模型加上星標'), findsOneWidget);
    expect(find.text('雙供應商（分開顯示）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider status rejects Gemini 2.0 and an OpenRouter alias', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await L.setLocale('zh_TW');
    await WebSearchSettings.saveEnabled(true);
    await WebSearchSettings.saveMode(WebSearchMode.openRouter);
    await ApiSettings.saveOpenRouterApiKey('openrouter-test-key');
    await ApiSettings.saveGeminiApiKey('gemini-test-key');
    await ApiSettings.saveModelForProvider('openrouter', 'openrouter/auto');
    await ApiSettings.saveProviderModelSelection('gemini', 'gemini-2.0-flash');

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final settingsList = find.byType(ListView).first;
    for (var i = 0; i < 5; i++) {
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('OpenRouter · 已就緒'), findsOneWidget);
    expect(find.text('Gemini · 已就緒'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('model-list errors stay with the provider that produced them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await L.setLocale('zh_TW');
    await ApiSettings.saveGeminiApiKey('gemini-test-key');

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(
      find.byKey(const Key('api_settings_model_section_toggle')),
    );
    await tester.pump();
    await tester.tap(find.byTooltip(L.get('settings_model_refresh')).first);
    await tester.pump();
    expect(find.text('請先輸入 OpenRouter API Key'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Gemini').last);
    await tester.pumpAndSettle();

    expect(find.text('請先輸入 OpenRouter API Key'), findsNothing);

    Future<void> expectProviderConfigurationError(
      String menuLabel,
      String expectedError,
    ) async {
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(menuLabel).last);
      await tester.pump();
      expect(find.text(expectedError), findsOneWidget);
      expect(find.text('請先輸入 OpenRouter API Key'), findsNothing);
    }

    await expectProviderConfigurationError('xAI (Grok)', '請先輸入 xAI API Key');
    await expectProviderConfigurationError('DeepSeek', '請先輸入 DeepSeek API Key');
    await expectProviderConfigurationError(
      'OpenAI Compatible (Custom)',
      '請先輸入 Base URL',
    );
    expect(tester.takeException(), isNull);
  });
}
