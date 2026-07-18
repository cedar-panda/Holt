import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/emotion_coordinates.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/sticker_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    'fresh schema contains runtime tables, columns, and hot indexes',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);

      expect(DatabaseHelper.schemaVersionForTesting, 38);
      expect(await _columnNames(db, 'messages'), contains('status'));
      expect(await _columnNames(db, 'characters'), contains('bio_clock'));
      expect(await _columnNames(db, 'sticky_notes'), contains('character_id'));
      expect(
        await _columnNames(db, 'conversations'),
        contains('pinned_static_self_notes'),
      );
      expect(
        await _columnNames(db, 'conversations'),
        contains('summary_cursor_message_id'),
      );
      expect(
        await _columnNames(db, 'character_timeline'),
        containsAll([
          'source_message_id',
          'source_message_ids',
          'source_evidence',
        ]),
      );
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
          'idx_emo_char_type_time',
          'idx_timeline_memory',
          'idx_timeline_event_daily_unique',
          'idx_timeline_source_message',
          'idx_saved_message_unique',
        ]),
      );
      expect(
        indexes,
        isNot(
          containsAll(<String>[
            'idx_messages_conv',
            'idx_mem_char_mode',
            'idx_saved_char',
            'idx_conv_char',
          ]),
        ),
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

  test('v38 backfills the automatic summary message cursor', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', {
      'id': 'conv-a',
      'character_id': 'char-a',
      'title': '',
      'created_at': '2026-07-18T09:00:00.000',
      'updated_at': '2026-07-18T12:00:00.000',
    });
    for (final entry in const [
      (1, '2026-07-18T10:00:00.000'),
      (2, '2026-07-18T11:00:00.000'),
      (3, '2026-07-18T13:00:00.000'),
    ]) {
      await db.insert('messages', {
        'id': entry.$1,
        'conversation_id': 'conv-a',
        'character_id': 'char-a',
        'text': 'message ${entry.$1}',
        'is_user': 1,
        'created_at': entry.$2,
      });
    }
    await db.insert('context_summaries', {
      'character_id': 'char-a',
      'source_conversation_id': 'conv-a',
      'content': 'automatic summary',
      'token_count': 20,
      'created_at': '2026-07-18T12:00:00.000',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 37);

    expect(await DatabaseHelper.getConversationSummaryCursor('conv-a'), 2);
  });

  test(
    'v35 database reaches v38 before indexes use new timeline columns',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);

      // Recreate the timeline table exactly as it existed before v38. The
      // previous test suite upgraded a fresh v38 schema and therefore missed
      // the ordering failure that only happened on a real device.
      await db.execute('DROP TABLE character_timeline');
      await db.execute('''
        CREATE TABLE character_timeline (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_id TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'state',
          key TEXT,
          value TEXT NOT NULL,
          source_memory_id INTEGER,
          week_group TEXT,
          confirmed INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');
      await db.insert('character_timeline', {
        'character_id': 'char-a',
        'type': 'event',
        'value': '保留的舊事件',
        'week_group': '2026-W29',
        'created_at': '2026-07-18T12:00:00.000',
        'updated_at': '2026-07-18T12:00:00.000',
      });
      await db.insert('conversations', {
        'id': 'legacy-conversation',
        'character_id': 'char-a',
        'created_at': '2026-07-18T12:00:00.000',
        'updated_at': '2026-07-18T12:00:00.000',
      });
      await db.insert('messages', {
        'conversation_id': 'legacy-conversation',
        'character_id': 'char-a',
        'text': '不能遺失的聊天紀錄',
        'is_user': 1,
        'created_at': '2026-07-18T12:01:00.000',
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 35);

      expect(
        await _columnNames(db, 'character_timeline'),
        containsAll([
          'source_message_id',
          'source_message_ids',
          'source_evidence',
        ]),
      );
      expect(
        await _objectNames(db, 'index'),
        contains('idx_timeline_source_message'),
      );
      expect((await db.query('messages')).single['text'], '不能遺失的聊天紀錄');
      expect((await db.query('character_timeline')).single['value'], '保留的舊事件');
    },
  );

  test('automatic summary and cursor persist together', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', {
      'id': 'conv-a',
      'character_id': 'char-a',
      'created_at': '2026-07-18T09:00:00.000',
      'updated_at': '2026-07-18T09:00:00.000',
    });

    final summaryId = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: 'summary',
      tokenCount: 10,
      conversationId: 'conv-a',
      cursorMessageId: 72,
      sourceWindowId: 'ABC',
    );

    expect(summaryId, greaterThan(0));
    expect(await DatabaseHelper.getConversationSummaryCursor('conv-a'), 72);
    final rows = await db.query(
      'context_summaries',
      where: 'id = ?',
      whereArgs: [summaryId],
    );
    expect(rows.single['source_conversation_id'], 'conv-a');
    expect(rows.single['source_window_id'], 'ABC');
  });

  test(
    'v37 removes same-day timeline duplicates and repairs ISO week',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.execute('DROP INDEX idx_timeline_event_daily_unique');
      for (final entry in <(String, int)>[
        ('2025-12-29T09:00:00.000', 0),
        ('2025-12-29T20:00:00.000', 1),
        ('2025-12-30T09:00:00.000', 1),
      ]) {
        await db.insert('character_timeline', {
          'character_id': 'char-a',
          'type': 'event',
          'value': '約會',
          'week_group': '2025-W52',
          'confirmed': entry.$2,
          'created_at': entry.$1,
          'updated_at': entry.$1,
        });
      }

      await DatabaseHelper.upgradeSchemaForTesting(db, 36);

      final rows = await db.query(
        'character_timeline',
        orderBy: 'created_at ASC',
      );
      expect(rows, hasLength(2));
      expect(rows.first['confirmed'], 1);
      expect(rows.every((row) => row['week_group'] == '2026-W01'), isTrue);
      expect(
        await _objectNames(db, 'index'),
        contains('idx_timeline_event_daily_unique'),
      );
    },
  );

  test(
    'v36 normalizes spider links, deduplicates saves, and uses compound indexes',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.execute('DROP TABLE spider_web_links');
      await db.execute('''
        CREATE TABLE spider_web_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_id TEXT NOT NULL,
          memory_id_1 INTEGER NOT NULL,
          memory_id_2 INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          UNIQUE(memory_id_1, memory_id_2)
        )
      ''');
      final now = DateTime.now().toIso8601String();
      await db.insert('spider_web_links', {
        'character_id': 'char-a',
        'memory_id_1': 9,
        'memory_id_2': 5,
        'created_at': now,
      });
      await db.insert('spider_web_links', {
        'character_id': 'char-a',
        'memory_id_1': 5,
        'memory_id_2': 9,
        'created_at': now,
      });
      await db.insert('spider_web_links', {
        'character_id': 'char-a',
        'memory_id_1': 7,
        'memory_id_2': 7,
        'created_at': now,
      });

      await db.execute('DROP INDEX idx_saved_message_unique');
      await db.insert('saved_messages', {
        'message_id': '42',
        'content': 'first',
        'character_id': 'char-a',
        'created_at': now,
      });
      await db.insert('saved_messages', {
        'message_id': '42',
        'content': 'duplicate',
        'character_id': 'char-a',
        'created_at': now,
      });
      await db.execute(
        'CREATE INDEX idx_messages_conv ON messages(conversation_id)',
      );
      await db.execute(
        'CREATE INDEX idx_mem_char_mode ON memories(character_id, mode, status)',
      );
      await db.execute(
        'CREATE INDEX idx_saved_char ON saved_messages(character_id)',
      );
      await db.execute(
        'CREATE INDEX idx_conv_char ON conversations(character_id)',
      );

      await DatabaseHelper.upgradeSchemaForTesting(db, 35);

      final links = await db.query('spider_web_links');
      expect(links, hasLength(1));
      expect(links.single['memory_id_1'], 5);
      expect(links.single['memory_id_2'], 9);
      expect(await db.query('saved_messages'), hasLength(1));
      expect(
        () => db.insert('saved_messages', {
          'message_id': '42',
          'content': 'blocked',
          'character_id': 'char-a',
          'created_at': now,
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        () => db.insert('spider_web_links', {
          'character_id': 'char-a',
          'memory_id_1': 9,
          'memory_id_2': 5,
          'created_at': now,
        }),
        throwsA(isA<DatabaseException>()),
      );

      final indexes = await _objectNames(db, 'index');
      expect(indexes, isNot(contains('idx_messages_conv')));
      expect(indexes, isNot(contains('idx_mem_char_mode')));
      expect(indexes, isNot(contains('idx_saved_char')));
      expect(indexes, isNot(contains('idx_conv_char')));
      expect(
        await _queryPlanUses(
          db,
          'SELECT * FROM messages WHERE conversation_id = ? '
              'ORDER BY created_at DESC, id DESC',
          ['conv'],
          'idx_messages_conv_time',
        ),
        isTrue,
      );
      expect(
        await _queryPlanUses(
          db,
          'SELECT * FROM memories '
              'WHERE character_id = ? AND mode = ? AND status = ? '
              'ORDER BY created_at DESC',
          ['char-a', 'story', 'active'],
          'idx_mem_char_mode_time',
        ),
        isTrue,
      );
      expect(
        await _queryPlanUses(
          db,
          'SELECT * FROM saved_messages WHERE character_id = ? '
              'ORDER BY created_at DESC',
          ['char-a'],
          'idx_saved_char_time',
        ),
        isTrue,
      );
      expect(
        await _queryPlanUses(
          db,
          'SELECT * FROM conversations WHERE character_id = ? '
              'ORDER BY is_starred DESC, updated_at DESC',
          ['char-a'],
          'idx_conv_char_updated',
        ),
        isTrue,
      );
    },
  );

  test('LIKE search escapes wildcard characters', () {
    expect(
      DatabaseHelper.likeContainsForTesting(r'100%_done\ok'),
      r'%100\%\_done\\ok%',
    );
  });

  test(
    'v34 migration adds message delivery status without changing text',
    () async {
      await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        character_id TEXT DEFAULT 'default',
        text TEXT NOT NULL,
        is_user INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
      await db.insert('messages', <String, Object?>{
        'conversation_id': 'conv-old',
        'character_id': 'char-old',
        'text': 'kept exactly',
        'is_user': 0,
        'created_at': '2026-07-17T00:00:00.000',
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 34);

      final row = (await db.query('messages')).single;
      expect(row['text'], 'kept exactly');
      expect(row['status'], Message.statusComplete);
    },
  );

  test(
    'incomplete assistant message remains in normal conversation history',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await DatabaseHelper.createConversation(
        Conversation(id: 'conv-incomplete', characterId: 'char-a'),
      );
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'conv-incomplete',
          characterId: 'char-a',
          text: 'half of the answer',
          isUser: false,
          status: Message.statusIncomplete,
        ),
      );

      final history = await DatabaseHelper.getMessages('conv-incomplete');

      expect(history, hasLength(1));
      expect(history.single.text, 'half of the answer');
      expect(history.single.isIncomplete, isTrue);
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
    'conversation summary pin is write-once under concurrent builders',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await DatabaseHelper.createConversation(
        Conversation(id: 'conv-pin', characterId: 'char-a'),
      );

      final results = await Future.wait([
        DatabaseHelper.setConversationPinnedSummaryIfAbsent(
          'conv-pin',
          'summary-a',
        ),
        DatabaseHelper.setConversationPinnedSummaryIfAbsent(
          'conv-pin',
          'summary-b',
        ),
      ]);

      final stored = await DatabaseHelper.getConversationPinnedSummary(
        'conv-pin',
      );
      expect(stored, anyOf('summary-a', 'summary-b'));
      expect(results, everyElement(stored));
    },
  );

  test('repairing a sticker file path does not change its prompt', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final id = await DatabaseHelper.insertSticker({
      'file_path': '/missing/old.webp',
      'character_id': StickerService.userBucket,
      'line': '嗚嗚',
      'mood': '委屈',
      'tags': '委屈',
      'created_at': DateTime.now().toIso8601String(),
    });
    final before = await StickerService.buildStickerPrompt(
      characterId: 'char-a',
    );

    await DatabaseHelper.updateStickerFilePath(id, '/local/new.webp');
    final after = await StickerService.buildStickerPrompt(
      characterId: 'char-a',
    );

    expect(after, before);
  });

  test('conversation self-note snapshot is pinned only once', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await DatabaseHelper.createConversation(
      Conversation(id: 'conv-notes', characterId: 'char-a'),
    );

    final first = await DatabaseHelper.setConversationPinnedSelfNotesIfAbsent(
      'conv-notes',
      'old note',
    );
    final second = await DatabaseHelper.setConversationPinnedSelfNotesIfAbsent(
      'conv-notes',
      'new note',
    );

    expect(first, 'old note');
    expect(second, 'old note');
    expect(
      await DatabaseHelper.getConversationPinnedSelfNotes('conv-notes'),
      'old note',
    );
  });

  test(
    'v32 migration backfills archive ownership and removes duplicates',
    () async {
      await _createRepresentativeV32Schema(db);
      await db.insert('conversations', {
        'id': 'existing-conv',
        'character_id': 'char-a',
        'title': 'existing',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-01T00:00:00.000',
      });
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
      await db.insert('saved_messages', {
        'message_id': 'legacy-duplicate',
        'content': 'first',
        'character_id': 'char-a',
        'created_at': '2026-01-01T00:00:00.000',
      });
      await db.insert('saved_messages', {
        'message_id': 'legacy-duplicate',
        'content': 'second',
        'character_id': 'char-a',
        'created_at': '2026-01-02T00:00:00.000',
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 32);

      expect(await _columnNames(db, 'characters'), contains('bio_clock'));
      expect(await _columnNames(db, 'sticky_notes'), contains('character_id'));
      expect(await _columnNames(db, 'archive'), contains('character_id'));
      final migratedConversation = await db.query(
        'conversations',
        where: 'id = ?',
        whereArgs: ['existing-conv'],
      );
      expect(migratedConversation.single['pinned_static_self_notes'], '');
      expect(
        await _objectNames(db, 'table'),
        containsAll(['emotion_points', 'grudge_seals', 'character_timeline']),
      );

      final archives = await db.query('archive');
      expect(archives, hasLength(1));
      expect(archives.single['character_id'], 'char-a');
      expect(archives.single['reason'], 'newer');
      expect(await db.query('saved_messages'), hasLength(1));

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

  test(
    'conversation deletion removes only app-owned media after DB rows',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      final root = await Directory.systemTemp.createTemp('holt-media-test-');
      final documents = Directory('${root.path}/documents')..createSync();
      final inside = File('${documents.path}/chat_images/inside.jpg');
      inside.parent.createSync(recursive: true);
      inside.writeAsStringSync('inside');
      final outside = File('${root.path}/outside.jpg')
        ..writeAsStringSync('outside');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return documents.path;
            }
            return null;
          });
      try {
        await DatabaseHelper.createConversation(
          Conversation(id: 'conv-media', characterId: 'char-a'),
        );
        await DatabaseHelper.insertMessage(
          Message(
            conversationId: 'conv-media',
            characterId: 'char-a',
            text: 'inside',
            isUser: true,
            imagePath: inside.path,
          ),
        );
        await DatabaseHelper.insertMessage(
          Message(
            conversationId: 'conv-media',
            characterId: 'char-a',
            text: 'outside',
            isUser: true,
            imagePath: outside.path,
          ),
        );

        await DatabaseHelper.deleteConversation('conv-media');

        expect(await inside.exists(), isFalse);
        expect(await outside.exists(), isTrue);
        expect(await db.query('messages'), isEmpty);
        expect(await db.query('conversations'), isEmpty);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
  );

  test('emotion maintenance removes only old settled points', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final old = DateTime.now()
        .subtract(const Duration(days: 91))
        .toIso8601String();
    final recent = DateTime.now().toIso8601String();
    Future<void> insert(String status, String createdAt) {
      return db
          .insert('emotion_points', {
            'character_id': 'char-a',
            'type': '愜意',
            'x': 0.0,
            'y': 0.0,
            'concentration': 1.0,
            'status': status,
            'created_at': createdAt,
            'updated_at': createdAt,
          })
          .then((_) {});
    }

    await insert('resolved', old);
    await insert('active', old);
    await insert('dissipated', recent);

    expect(await EmotionCoordinates.startupMaintenance('char-a'), 1);
    final remaining = await db.query('emotion_points', orderBy: 'id ASC');
    expect(remaining.map((row) => row['status']), ['active', 'dissipated']);
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

Future<bool> _queryPlanUses(
  Database db,
  String sql,
  List<Object?> args,
  String index,
) async {
  final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
  return rows.any((row) => row['detail']?.toString().contains(index) == true);
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
  await db.execute('''
    CREATE TABLE saved_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id TEXT NOT NULL,
      content TEXT NOT NULL,
      character_id TEXT DEFAULT 'default',
      conversation_id TEXT,
      created_at TEXT NOT NULL
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
