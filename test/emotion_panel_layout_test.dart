import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/emotion_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('en');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
    await L.setLocale('zh_TW');
  });

  testWidgets('Mood Map stays collapsed until the user opens it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 300,
                child: EmotionPanel(characterId: 'character'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Mood Map'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('emotion-panel-collapsed')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('emotion-panel-expanded')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('emotion-panel-collapsed')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('emotion-panel-expanded')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('emotion-panel-collapse')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
