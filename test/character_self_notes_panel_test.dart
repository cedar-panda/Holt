import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:project_yanci/widgets/character_self_notes_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.utc(2026, 8, 7).toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '顧遠',
      'description': '',
      'self_notes': '· 小禾喜歡下雨天\n· 小禾嘴硬時其實想被抱住',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  testWidgets('shows the latest self note and opens the complete list', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CharacterSelfNotesPanel(characterId: 'char-a')),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();

    expect(find.text('偷偷記住你'), findsOneWidget);
    expect(find.textContaining('小禾嘴硬時其實想被抱住'), findsOneWidget);
    expect(find.textContaining('小禾喜歡下雨天'), findsNothing);
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('character-self-notes-preview')),
    );
    expect(preview.data, startsWith('　　'));
    expect(preview.maxLines, 4);

    await tester.tap(find.byKey(const ValueKey('character-self-notes-panel')));
    await tester.pumpAndSettle();

    expect(find.textContaining('小禾喜歡下雨天'), findsOneWidget);
    expect(find.textContaining('小禾嘴硬時其實想被抱住'), findsNWidgets(2));
    expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);

    final longTermSwitch = find.byType(Switch);
    expect(longTermSwitch, findsOneWidget);
    await tester.tap(longTermSwitch);
    await tester.pump();
    expect(await MemorySettings.getSelfNotesLongTermEnabled(), isTrue);
    expect(tester.widget<Switch>(longTermSwitch).value, isTrue);

    await tester.tap(find.byIcon(Icons.lock_open_rounded).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('刪除這條自我註記？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
