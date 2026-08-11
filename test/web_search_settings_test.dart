import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/api_settings_screen.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:project_yanci/services/settings/web_search_settings.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  test('web search defaults are fail-closed and bounded', () async {
    expect(await WebSearchSettings.getEnabled(), isFalse);
    expect(await WebSearchSettings.getMode(), WebSearchMode.auto);
    expect(
      await WebSearchSettings.getDailyProviderLaunchCap(),
      WebSearchSettings.defaultDailyProviderLaunchCap,
    );
  });

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

    for (final mode in WebSearchMode.values) {
      await WebSearchSettings.saveMode(mode);
      expect(await WebSearchSettings.getMode(), mode);
    }
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

  testWidgets(
    'dual mode discloses separate providers, billing, and retention',
    (tester) async {
      await L.setLocale('zh_TW');
      await WebSearchSettings.saveEnabled(true);
      await WebSearchSettings.saveMode(WebSearchMode.dual);

      await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final settingsList = find.byType(ListView).first;
      for (var i = 0; i < 5; i++) {
        await tester.drag(settingsList, const Offset(0, -420));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('雙供應商（分開顯示）'), findsWidgets);
      expect(
        find.textContaining('同一段經確認的請求會送往 Gemini 與 OpenRouter'),
        findsOneWidget,
      );
      expect(find.textContaining('兩家結果使用獨立卡片顯示'), findsOneWidget);
      expect(find.textContaining('費用與留存分別計算'), findsOneWidget);
      expect(find.text('20 次／日'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('provider status rejects Gemini 2.0 and an OpenRouter alias', (
    tester,
  ) async {
    await L.setLocale('zh_TW');
    await WebSearchSettings.saveEnabled(true);
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

    expect(find.text('Gemini · 請選擇目前支援的模型'), findsOneWidget);
    expect(find.text('OpenRouter · 請選擇明確模型'), findsOneWidget);
    expect(find.text('Gemini · 已就緒'), findsNothing);
    expect(find.text('OpenRouter · 已就緒'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
