import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:project_yanci/widgets/api_advanced_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  test(
    'window summary trigger keeps the exact configured token count',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await MemorySettings.saveWindowSummaryTriggerTokens(4321);

      expect(await MemorySettings.getWindowSummaryTriggerTokens(), 4321);
      expect(await MemorySettings.getContextWindowSummaryTriggerTokens(), 4321);
    },
  );

  testWidgets('cache summary exposes its message trigger control', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
      'cache_window_summary_enabled': true,
      'cache_summary_trigger_messages_v1': 18,
    });
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ApiAdvancedSettings(cacheOnly: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('專用窗口摘要'), findsOneWidget);
    expect(find.text('累積至'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '18',
    );
  });

  testWidgets('active Inkling with a key cannot re-enable prompt cache', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'api_provider': 'thinking_machines',
      'thinking_machines_api_key': 'tk_legacy_test',
      'thinking_machines_model': 'thinkingmachines/Inkling',
      'enable_prompt_caching': false,
      'cache_window_summary_enabled': false,
      'context_limit_enabled': false,
    });
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ApiAdvancedSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(L.get('settings_cache_title')));
    await tester.pumpAndSettle();
    final cacheCheckbox = tester.widget<Checkbox>(find.byType(Checkbox).first);
    await tester.runAsync(() async {
      cacheCheckbox.onChanged!(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(await MemorySettings.getEnablePromptCaching(), isFalse);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getContextLimitEnabled(), isTrue);
  });
}
