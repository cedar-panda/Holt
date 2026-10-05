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
      expect(
        await WebSearchSettings.getMaxResults(),
        WebSearchSettings.defaultMaxResults,
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

  test(
    'web page limit defaults to 2 and clamps writes to 1 through 20',
    () async {
      expect(await WebSearchSettings.getMaxResults(), 2);
      await WebSearchSettings.saveMaxResults(0);
      expect(await WebSearchSettings.getMaxResults(), 1);
      await WebSearchSettings.saveMaxResults(21);
      expect(await WebSearchSettings.getMaxResults(), 20);
    },
  );

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

  test(
    'custom API source is available to native search as the relay',
    () async {
      await ApiSettings.saveOaiCompatBaseUrl('https://relay.example/v1');
      await ApiSettings.saveOaiCompatApiKey('relay-test-key');
      await ApiSettings.saveProviderModelSelection(
        'openai_compatible',
        'relay/search-capable-model',
      );

      final configuration =
          await const ApiSettingsWebSearchConfigurationSource().load();
      final relay = configuration.providers.singleWhere(
        (provider) => provider.id == WebSearchProviderId.relay,
      );

      expect(relay.apiKey, 'relay-test-key');
      expect(relay.model, 'relay/search-capable-model');
      expect(relay.endpoint, 'https://relay.example/v1/chat/completions');

      final plan = await const HybridWebSearchService().resolvePlan(
        WebSearchMode.auto,
      );
      expect(plan.providers.single.id, WebSearchProviderId.relay);
      expect(plan.providers.single.model, 'relay/search-capable-model');
    },
  );

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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final settingsList = find.byType(ListView).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('api_settings_advanced_button')),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('api_settings_advanced_button')));
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('原生網路搜尋'));
    await tester.pumpAndSettle();

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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final settingsList = find.byType(ListView).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('api_settings_advanced_button')),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('api_settings_advanced_button')));
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('原生網路搜尋'));
    await tester.pumpAndSettle();

    expect(find.text('OpenRouter · 已就緒'), findsOneWidget);
    expect(find.text('Gemini · 已就緒'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider picker and advanced settings remain reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await L.setLocale('zh_TW');
    await ApiSettings.saveGeminiApiKey('gemini-test-key');

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.byKey(const Key('api_settings_provider_toggle')));
    await tester.pump();
    expect(find.byKey(const Key('api_settings_provider_xai')), findsOneWidget);
    await tester.tap(find.byKey(const Key('api_settings_provider_xai')));
    await tester.pumpAndSettle();
    expect(find.text('xAI (Grok)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('api_settings_advanced_button')),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('api_settings_advanced_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('api_settings_model_refresh_button')),
      findsOneWidget,
    );
    expect(find.text('原生網路搜尋'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite model entry opens management dialog and can delete', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await L.setLocale('zh_TW');
    const model = 'relay/model-for-dialog';
    await ApiSettings.toggleStarModel(model, provider: 'openai_compatible');

    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(
      find.byKey(const Key('api_settings_favorite_models_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('api_settings_favorite_models_dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('長按條目拖動'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('api_settings_favorite_models_dialog')),
        matching: find.text('自訂中轉站'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'delete_favorite_model_openai_compatible\u0000$model',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(await ApiSettings.getStarredModels(), isNot(contains(model)));
    expect(tester.takeException(), isNull);
  });
}
