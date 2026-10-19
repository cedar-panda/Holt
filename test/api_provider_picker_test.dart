import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/api_provider_picker.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
  });

  testWidgets('API source selector expands and selects one provider', (
    tester,
  ) async {
    var selectedId = 'openrouter';
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ApiProviderPicker(
              options: const <ApiProviderOption>[
                ApiProviderOption(id: 'openrouter', label: 'OpenRouter'),
                ApiProviderOption(id: 'gemini', label: 'Gemini'),
              ],
              selectedId: selectedId,
              showOtherProviders: expanded,
              onExpandedChanged: (value) => setState(() => expanded = value),
              onChanged: (id) => setState(() => selectedId = id),
            ),
          ),
        ),
      ),
    );

    expect(find.text('OpenRouter'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('api_settings_provider_gemini')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('api_settings_provider_selector')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('api_settings_provider_gemini')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('api_settings_provider_gemini')),
    );
    await tester.pump();
    expect(selectedId, 'gemini');
    expect(expanded, isFalse);
    expect(find.text('Gemini'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty API source uses the requested placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiProviderPicker(
            options: const <ApiProviderOption>[
              ApiProviderOption(id: 'openrouter', label: 'OpenRouter'),
            ],
            selectedId: '',
            showOtherProviders: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('請選擇 API 來源'), findsOneWidget);
  });
}
