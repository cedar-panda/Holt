import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/anniversary_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    for (final row in const <Map<String, Object?>>[
      <String, Object?>{
        'id': 'char-a',
        'name': 'A',
        'created_at': '2026-09-01T23:30:00.000',
        'updated_at': '2026-09-01T23:30:00.000',
      },
      <String, Object?>{
        'id': 'char-b',
        'name': 'B',
        'created_at': '2026-09-02T00:00:00.000',
        'updated_at': '2026-09-02T00:00:00.000',
      },
    ]) {
      await db.insert('characters', row);
    }
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('natural days are inclusive and do not use an activity clock', () {
    expect(
      AnniversaryService.naturalDayNumber(
        DateTime(2026, 9, 1),
        now: DateTime(2026, 9, 15, 23, 59),
      ),
      15,
    );
  });

  test(
    'entries and display settings are isolated by persona and character',
    () async {
      final target = await AnniversaryService.create(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
        title: '初遇',
        startDate: DateTime(2026, 9, 1),
      );
      await AnniversaryService.create(
        userPersonaId: 'persona-b',
        characterId: 'char-a',
        title: '另一個我',
        startDate: DateTime(2026, 9, 2),
      );
      await AnniversaryService.create(
        userPersonaId: 'persona-a',
        characterId: 'char-b',
        title: '另一位角色',
        startDate: DateTime(2026, 9, 3),
      );

      await AnniversaryService.update(
        target.copyWith(placement: AnniversaryPlacement.avatarLine),
      );
      await AnniversaryService.setHideUserName(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
        value: true,
      );

      final entries = await AnniversaryService.list(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
      );
      expect(entries, hasLength(1));
      expect(entries.single.title, '初遇');
      expect(entries.single.placement, AnniversaryPlacement.avatarLine);
      expect(
        (await AnniversaryService.settings(
          userPersonaId: 'persona-a',
          characterId: 'char-a',
        )).hideUserName,
        isTrue,
      );
      expect(
        (await AnniversaryService.settings(
          userPersonaId: 'persona-b',
          characterId: 'char-a',
        )).hideUserName,
        isFalse,
      );
    },
  );

  test(
    'default date prefers first window then falls back to character creation',
    () async {
      await db.insert('conversations', <String, Object?>{
        'id': 'char-a-first-window',
        'character_id': 'char-a',
        'created_at': '2026-08-28T10:00:00.000',
        'updated_at': '2026-08-28T10:00:00.000',
      });
      expect(
        AnniversaryService.storageDate(
          await AnniversaryService.defaultStartDate('char-a'),
        ),
        '2026-08-28',
      );

      expect(
        AnniversaryService.storageDate(
          await AnniversaryService.defaultStartDate('char-b'),
        ),
        '2026-09-02',
      );
    },
  );

  test(
    'deleting a persona removes its anniversaries and pair settings',
    () async {
      await AnniversaryService.create(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
        title: '應清理',
        startDate: DateTime(2026, 9, 1),
      );
      await AnniversaryService.setHideUserName(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
        value: true,
      );

      await AnniversaryService.deleteForPersona('persona-a');

      expect(
        await AnniversaryService.list(
          userPersonaId: 'persona-a',
          characterId: 'char-a',
        ),
        isEmpty,
      );
      expect(
        (await AnniversaryService.settings(
          userPersonaId: 'persona-a',
          characterId: 'char-a',
        )).hideUserName,
        isFalse,
      );
    },
  );

  test('malformed stored data fails closed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'anniversary_entries_v1': '{broken',
      'anniversary_display_settings_v1': '[]',
    });

    expect(
      await AnniversaryService.list(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
      ),
      isEmpty,
    );
    expect(
      (await AnniversaryService.settings(
        userPersonaId: 'persona-a',
        characterId: 'char-a',
      )).hideUserName,
      isFalse,
    );
  });
}
