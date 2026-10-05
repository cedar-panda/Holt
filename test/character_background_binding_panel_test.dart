import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/background_preset_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/character_background_binding_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('character panel expands six previews and stores one binding', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CharacterBackgroundBindingPanel(characterId: 'char-a'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('窗口背景預設綁定'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('character-background-binding-toggle')),
    );
    await tester.pumpAndSettle();

    for (var slot = 1; slot <= 6; slot++) {
      expect(
        find.byKey(ValueKey('character-background-slot-$slot')),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const ValueKey('character-background-slot-3')));
    await tester.pumpAndSettle();

    expect(await BackgroundPresetService.getCharacterBinding('char-a'), 3);
    expect(find.text('已綁定第 3 套'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
