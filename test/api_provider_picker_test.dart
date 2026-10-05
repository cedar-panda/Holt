import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/api_provider_picker.dart';

void main() {
  testWidgets('API source cards use shadows without outer borders', (
    tester,
  ) async {
    var selectedId = 'openrouter';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ApiProviderPicker(
              options: const [
                ApiProviderOption(id: 'openrouter', label: 'OpenRouter'),
                ApiProviderOption(id: 'gemini', label: 'Gemini'),
              ],
              selectedId: selectedId,
              showOtherProviders: true,
              onChanged: (id) => setState(() => selectedId = id),
            ),
          ),
        ),
      ),
    );

    final selectedSurface = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const ValueKey('api_settings_provider_openrouter')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final unselectedSurface = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const ValueKey('api_settings_provider_gemini')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final selectedDecoration = selectedSurface.decoration! as BoxDecoration;
    final unselectedDecoration = unselectedSurface.decoration! as BoxDecoration;
    expect(selectedDecoration.border, isNull);
    expect(selectedDecoration.color, isNull);
    expect(selectedDecoration.boxShadow, isEmpty);
    expect(unselectedDecoration.border, isNull);
    expect(unselectedDecoration.color, isNull);
    expect(unselectedDecoration.boxShadow, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey('api_settings_provider_gemini')),
    );
    await tester.pumpAndSettle();
    expect(selectedId, 'gemini');
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed API sources show only the selected source', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiProviderPicker(
            options: const [
              ApiProviderOption(id: 'openrouter', label: 'OpenRouter'),
              ApiProviderOption(id: 'gemini', label: 'Gemini'),
            ],
            selectedId: 'gemini',
            showOtherProviders: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('api_settings_provider_gemini')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('api_settings_provider_openrouter')),
      findsNothing,
    );
  });
}
