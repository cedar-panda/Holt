import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'fresh v33 schema contains runtime tables, columns, and hot indexes',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);

      expect(DatabaseHelper.schemaVersionForTesting, 33);
      expect(await _columnNames(db, 'characters'), contains('bio_clock'));
      expect(await _columnNames(db, 'sticky_notes'), contains('character_id'));
      expect(await _columnNames(db, 'archive'), contains('character_id'));

      final tables = await _objectNames(db, 'table');
      expect(
        tables,
        containsAll(<String>[
          'emotion_points',
          'grudge_seals',
          'character_timeline',
        ]),
      );

      final indexes = await _objectNames(db, 'index');
      expect(
        indexes,
        containsAll(<String>[
          'idx_messages_conv_time',
          'idx_mem_char_mode_time',
          'idx_spider_web_memory_1',
          'idx_spider_web_memory_2',
          'idx_archive_original_unique',
          'idx_archive_char_time',
          'idx_notes_char_time',
          'idx_voice_char_time',
          'idx_voice_conversation',
          'idx_context_summary_char_time',
          'idx_context_keyword_char_time',
          'idx_emo_memory',
          'idx_timeline_memory',
        ]),
      );

      await db.insert('archive', {
        'character_id': 'char-a',
        'original_id': 7,
        'original_table': 'memories',
        'content_snapshot': '{}',
        'archived_at': '2026-07-10T00:00:00.000',
        'reason': 'first',
      });
      expect(
        () => db.insert('archive', {
          'character_id': 'char-a',
          'original_id': 7,
          'original_table': 'memories',
          'content_snapshot': '{}',
          'archived_at': '2026-07-10T00:00:01.000',
          'reason': 'duplicate',
        }),
        throwsA(isA<DatabaseException>()),
      );
    },
  );

  test(
    'failed database initialization can be retried in one process',
    () async {
      var attempts = 0;
      DatabaseHelper.useDatabaseInitializerForTesting(() async {
        attempts++;
        if (attempts == 1) throw StateError('temporary open failure');
        return db;
      });

      await expectLater(DatabaseHelper.database, throwsStateError);
      expect(await DatabaseHelper.database, same(db));
      expect(attempts, 2);

      DatabaseHelper.useDatabaseInitializerForTesting(null);
      DatabaseHelper.useDatabaseForTesting(db);
    },
  );

  test(
    'v32 migration backfills archive ownership and removes duplicates',
    () async {
      await _createRepresentativeV32Schema(db);
      await db.insert('memories', {
        'id': 41,
        'character_id': 'char-a',
        'mode': 'story',
        'status': 'deleted',
        'created_at': '2026-01-01T00:00:00.000',
      });
      final snapshot = jsonEncode({
        'id': 41,
        'character_id': 'char-a',
        'mode': 'story',
        'category': 'event',
        'content': 'snapshot',
        'status': 'deleted',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-01T00:00:00.000',
      });
      await db.insert('archive', {
        'original_id': 41,
        'original_table': 'memories',
        'content_snapshot': snapshot,
        'archived_at': '2026-01-01T00:00:00.000',
        'reason': 'older',
      });
      await db.insert('archive', {
        'original_id': 41,
        'original_table': 'memories',
        'content_snapshot': snapshot,
        'archived_at': '2026-01-02T00:00:00.000',
        'reason': 'newer',
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 32);

      expect(await _columnNames(db, 'characters'), contains('bio_clock'));
      expect(await _columnNames(db, 'sticky_notes'), contains('character_id'));
      expect(await _columnNames(db, 'archive'), contains('character_id'));
      expect(
        await _objectNames(db, 'table'),
        containsAll(['emotion_points', 'grudge_seals', 'character_timeline']),
      );

      final archives = await db.query('archive');
      expect(archives, hasLength(1));
      expect(archives.single['character_id'], 'char-a');
      expect(archives.single['reason'], 'newer');

      expect(
        () => db.insert('archive', {
          'character_id': 'char-a',
          'original_id': 41,
          'original_table': 'memories',
          'content_snapshot': snapshot,
          'archived_at': '2026-01-03T00:00:00.000',
          'reason': 'duplicate',
        }),
        throwsA(isA<DatabaseException>()),
      );
    },
  );

  test(
    'archive APIs isolate characters and hard delete all memory references',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      final a1 = await _insertMemory(db, 'char-a', 'A1');
      final a2 = await _insertMemory(db, 'char-a', 'A2');
      final b1 = await _insertMemory(db, 'char-b', 'B1');
      final b2 = await _insertMemory(db, 'char-b', 'B2');

      expect(
        await DatabaseHelper.archiveMemory(
          a1,
          'wrong scope',
          characterId: 'char-b',
        ),
        isFalse,
      );
      expect(
        await DatabaseHelper.archiveMemory(a1, 'manual', characterId: 'char-a'),
        isTrue,
      );
      expect(await DatabaseHelper.getArchivedCount(characterId: 'char-a'), 1);
      expect(await DatabaseHelper.getArchivedCount(characterId: 'char-b'), 0);

      final archiveId =
          (await DatabaseHelper.getArchivedMemories(
                characterId: 'char-a',
              )).single['id']
              as int;
      expect(
        await DatabaseHelper.restoreFromArchive(
          archiveId,
          characterId: 'char-b',
        ),
        isFalse,
      );
      expect(
        await DatabaseHelper.restoreFromArchive(
          archiveId,
          characterId: 'char-a',
        ),
        isTrue,
      );

      await _insertRelations(db, 'char-a', a1, a2);
      await _insertRelations(db, 'char-b', b1, b2);
      await DatabaseHelper.archiveMemory(
        a1,
        'delete permanently',
        characterId: 'char-a',
      );
      final secondArchiveId =
          (await DatabaseHelper.getArchivedMemories(
                characterId: 'char-a',
              )).single['id']
              as int;

      expect(
        await DatabaseHelper.permanentlyDelete(
          secondArchiveId,
          characterId: 'char-b',
        ),
        isFalse,
      );
      expect(
        await db.query('memories', where: 'id = ?', whereArgs: [a1]),
        isNotEmpty,
      );

      expect(
        await DatabaseHelper.permanentlyDelete(
          secondArchiveId,
          characterId: 'char-a',
        ),
        isTrue,
      );
      expect(
        await db.query('memories', where: 'id = ?', whereArgs: [a1]),
        isEmpty,
      );
      expect(await _relationCount(db, 'spider_web_links', 'char-a'), 0);
      expect(await _relationCount(db, 'emotion_points', 'char-a'), 0);
      expect(await _relationCount(db, 'grudge_seals', 'char-a'), 0);
      expect(await _relationCount(db, 'character_timeline', 'char-a'), 0);
      expect(await _relationCount(db, 'spider_web_links', 'char-b'), 1);
      expect(await _relationCount(db, 'emotion_points', 'char-b'), 1);
      expect(await _relationCount(db, 'grudge_seals', 'char-b'), 1);
      expect(await _relationCount(db, 'character_timeline', 'char-b'), 1);
    },
  );

  test('character deletion clears all database-owned character data', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', {
      'id': 'char-a',
      'name': 'A',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('characters', {
      'id': 'char-b',
      'name': 'B',
      'created_at': now,
      'updated_at': now,
    });
    final a1 = await _insertMemory(db, 'char-a', 'A1');
    final a2 = await _insertMemory(db, 'char-a', 'A2');
    final b1 = await _insertMemory(db, 'char-b', 'B1');
    await _insertRelations(db, 'char-a', a1, a2);
    await DatabaseHelper.archiveMemory(
      a1,
      'character deletion test',
      characterId: 'char-a',
    );
    await db.insert('backpack_items', {
      'owner_id': 'char-a',
      'item_id': 'item-a',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('sticky_notes', {
      'character_id': 'char-a',
      'content': 'note',
      'created_at': now,
    });
    await db.insert('usage_logs', {
      'character_id': 'char-a',
      'timestamp': now,
      'provider': 'test',
      'model': 'test',
    });

    await DatabaseHelper.deleteCharacter('char-a');

    for (final table in <String>[
      'memories',
      'spider_web_links',
      'emotion_points',
      'grudge_seals',
      'character_timeline',
      'archive',
      'sticky_notes',
      'usage_logs',
    ]) {
      expect(
        await _relationCount(db, table, 'char-a'),
        0,
        reason: '$table must not retain char-a rows',
      );
    }
    expect(
      await db.query('characters', where: 'id = ?', whereArgs: ['char-a']),
      isEmpty,
    );
    expect(
      await db.query(
        'backpack_items',
        where: 'owner_id = ?',
        whereArgs: ['char-a'],
      ),
      isEmpty,
    );
    expect(
      await db.query('memories', where: 'id = ?', whereArgs: [b1]),
      isNotEmpty,
      reason: 'deleting char-a must not touch char-b',
    );
  });
}

Future<Set<String>> _columnNames(Database db, String table) async {
  final rows = await db.rawQuery("PRAGMA table_info('$table')");
  return rows.map((row) => row['name'] as String).toSet();
}

Future<Set<String>> _objectNames(Database db, String type) async {
  final rows = await db.query(
    'sqlite_master',
    columns: ['name'],
    where: 'type = ?',
    whereArgs: [type],
  );
  return rows.map((row) => row['name'] as String).toSet();
}

Future<void> _createRepresentativeV32Schema(Database db) async {
  await db.execute('''
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      character_id TEXT DEFAULT 'default',
      title TEXT,
      is_starred INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT NOT NULL,
      character_id TEXT DEFAULT 'default',
      text TEXT DEFAULT '',
      is_user INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE characters (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sticky_notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      character_id TEXT DEFAULT 'default',
      mode TEXT NOT NULL,
      status TEXT DEFAULT 'active',
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE archive (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      original_id INTEGER NOT NULL,
      original_table TEXT NOT NULL,
      content_snapshot TEXT NOT NULL,
      archived_at TEXT NOT NULL,
      reason TEXT NOT NULL
    )
  ''');
}

Future<int> _insertMemory(Database db, String characterId, String content) {
  final now = DateTime.now().toIso8601String();
  return db.insert('memories', {
    'character_id': characterId,
    'mode': 'story',
    'category': 'event',
    'content': content,
    'status': 'active',
    'created_at': now,
    'updated_at': now,
  });
}

Future<void> _insertRelations(
  Database db,
  String characterId,
  int memoryId,
  int otherMemoryId,
) async {
  final now = DateTime.now().toIso8601String();
  await db.insert('spider_web_links', {
    'character_id': characterId,
    'memory_id_1': memoryId,
    'memory_id_2': otherMemoryId,
    'created_at': now,
  });
  await db.insert('emotion_points', {
    'character_id': characterId,
    'type': 'comfort',
    'x': 1.0,
    'y': 2.0,
    'concentration': 10.0,
    'memory_id': memoryId,
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('grudge_seals', {
    'character_id': characterId,
    'memory_id': memoryId,
    'negative_concentration': 10.0,
    'sealed_at': now,
  });
  await db.insert('character_timeline', {
    'character_id': characterId,
    'type': 'event',
    'value': 'event',
    'source_memory_id': memoryId,
    'created_at': now,
    'updated_at': now,
  });
}

Future<int> _relationCount(
  Database db,
  String table,
  String characterId,
) async {
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS count FROM $table WHERE character_id = ?',
    [characterId],
  );
  return rows.single['count'] as int;
}
