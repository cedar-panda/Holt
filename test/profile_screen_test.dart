import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/screens/profile_screen.dart';
import 'package:project_yanci/services/user_persona_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'system_prompt': 'daily guide',
      'system_prompt_rp_v1': 'rp guide',
    });
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    await UserPersonaService.ensureDefaultPersona();
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  testWidgets('Profile migrates the legacy guide into the selected persona', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProfileScreen(initialMode: ContextMode.daily)),
    );
    await _waitForAsyncScreen(tester);

    final field = find.byKey(const Key('profile_system_prompt_field'));
    expect(tester.widget<TextField>(field).controller?.text, 'daily guide');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets(
    'RP Profile field and storage preserve the complete multiline guide',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ProfileScreen(initialMode: ContextMode.rp)),
      );
      await _waitForAsyncScreen(tester);

      const guide = '第一行身分\n第二行行為邊界\n第三行敘事偏好';
      final field = find.byKey(const Key('profile_system_prompt_field'));
      await tester.enterText(field, guide);
      expect(tester.widget<TextField>(field).controller?.text, guide);

      await tester.runAsync(
        () => UserPersonaService.saveProfileGuide(
          UserPersonaService.defaultPersonaId,
          ContextMode.rp,
          guide,
        ),
      );

      final stored = await tester.runAsync(
        () => UserPersonaService.profileGuide(
          UserPersonaService.defaultPersonaId,
          ContextMode.rp,
        ),
      );
      expect(stored, guide);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
    },
  );

  testWidgets('communication guide opens the expanded editor', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProfileScreen(initialMode: ContextMode.daily)),
    );
    await _waitForAsyncScreen(tester);

    await tester.tap(find.byKey(const Key('profile-expand-guide-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('profile_system_prompt_expanded_field')),
      findsOneWidget,
    );
    final expanded = tester.widget<TextField>(
      find.byKey(const Key('profile_system_prompt_expanded_field')),
    );
    expect(
      expanded.controller,
      same(
        tester
            .widget<TextField>(
              find.byKey(const Key('profile_system_prompt_field')),
            )
            .controller,
      ),
    );
  });
}

Future<void> _waitForAsyncScreen(WidgetTester tester) async {
  final finder = find.byKey(const Key('profile_system_prompt_field'));
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}
