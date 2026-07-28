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
    final cacheSwitch = tester.widget<Switch>(find.byType(Switch).first);
    await tester.runAsync(() async {
      cacheSwitch.onChanged!(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(await MemorySettings.getEnablePromptCaching(), isFalse);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getContextLimitEnabled(), isTrue);
  });
}
