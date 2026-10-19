import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
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
    await _insertCharacter(db, 'char-a');
    await _insertCharacter(db, 'char-b');
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('legacy self-note backfill preserves displayed chronology', () async {
    await db.update(
      'characters',
      <String, Object?>{'self_notes': '· 第一條舊註記\n· 第二條舊註記\n· 最新一條舊註記'},
      where: 'id = ?',
      whereArgs: <Object?>['char-a'],
    );

    final records = await DatabaseHelper.getSelfNoteRecords('char-a');

    expect(records.map((item) => item.content), <String>[
      '第一條舊註記',
      '第二條舊註記',
      '最新一條舊註記',
    ]);
  });

  test(
    'detailed self-note keeps model source and both turn messages',
    () async {
      final result = await DatabaseHelper.appendSelfNoteDetailed(
        'char-a',
        '小禾會在疲倦時安靜下來',
        retainLongTerm: true,
        provider: 'deepinfra',
        modelId: 'deepseek-v4-pro',
        modelVersion: '2026-10',
        sourceConversationId: 'window-a',
        sourceMessageIds: const <int>[7],
      );
      expect(result.accepted, isTrue);
      expect(result.recordId, isNotNull);

      await DatabaseHelper.bindSelfNotesToMessage(<int>[result.recordId!], 8);
      final note = (await DatabaseHelper.getSelfNoteRecords('char-a')).single;

      expect(note.provider, 'deepinfra');
      expect(note.modelId, 'deepseek-v4-pro');
      expect(note.modelVersion, '2026-10');
      expect(note.sourceConversationId, 'window-a');
      expect(note.sourceMessageIds, <int>[7, 8]);
      expect(note.longTerm, isTrue);
    },
  );

  test('locking limit is ten per character rather than app-wide', () async {
    final idsA = <int>[];
    for (var index = 0; index < 11; index++) {
      idsA.add(await _insertSelfNote(db, 'char-a', 'A-$index'));
    }
    final idB = await _insertSelfNote(db, 'char-b', 'B-0');

    for (final id in idsA.take(10)) {
      expect(await DatabaseHelper.setSelfNoteLocked(id, true), isTrue);
    }
    expect(await DatabaseHelper.setSelfNoteLocked(idsA.last, true), isFalse);
    expect(
      await DatabaseHelper.setSelfNoteLocked(idB, true),
      isTrue,
      reason: 'another character has an independent ten-note allowance',
    );
  });

  test('static injection count is configurable and clamped', () async {
    await MemorySettings.saveSelfNotesInjectionLimit(4);
    expect(await MemorySettings.getSelfNotesInjectionLimit(), 4);

    await MemorySettings.saveSelfNotesInjectionLimit(99);
    expect(await MemorySettings.getSelfNotesInjectionLimit(), 12);
  });
}

Future<void> _insertCharacter(Database db, String id) async {
  final now = DateTime.utc(2026, 10, 13).toIso8601String();
  await db.insert('characters', <String, Object?>{
    'id': id,
    'name': id,
    'description': '',
    'created_at': now,
    'updated_at': now,
  });
}

Future<int> _insertSelfNote(Database db, String characterId, String text) {
  final now = DateTime.now().toIso8601String();
  return db.insert('character_self_notes', <String, Object?>{
    'character_id': characterId,
    'content': text,
    'source_message_ids_json': '[]',
    'created_at': now,
    'updated_at': now,
  });
}
