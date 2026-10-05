import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/emotion_coordinates.dart';
import 'package:project_yanci/models/context_mode.dart';
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

      expect(DatabaseHelper.schemaVersionForTesting, 77);
      expect(
        await _columnNames(db, 'character_diaries'),
        containsAll(<String>[
          'character_id',
          'diary_date',
          'title',
          'body',
          'source_conversation_id',
          'source_message_id',
        ]),
      );
      expect(await _columnNames(db, 'messages'), contains('status'));
      expect(
        await _columnNames(db, 'messages'),
        contains('web_search_trace_json'),
      );
      expect(await _columnNames(db, 'messages'), contains('email_draft_json'));
      expect(await _columnNames(db, 'messages'), contains('summary_recorded'));
      expect(
        await _columnNames(db, 'context_summaries'),
        contains('source_span_status'),
      );
      expect(await _columnNames(db, 'characters'), contains('bio_clock'));
      expect(await _columnNames(db, 'characters'), contains('signature'));
      expect(
        await _columnNames(db, 'character_signatures'),
        containsAll(<String>['phase', 'signature', 'is_selected']),
      );
      expect(
        await _columnNames(db, 'characters'),
        containsAll([
          'whisper_user_text',
          'whisper_model_text',
          'whisper_source',
          'whisper_model_override',
        ]),
      );
      expect(await _columnNames(db, 'sticky_notes'), contains('character_id'));
      expect(
        await _columnNames(db, 'conversations'),
        containsAll(<String>[
          'pinned_static_self_notes',
          'pinned_coin_snapshot_char',
          'pinned_coin_snapshot_user',
        ]),
      );
      expect(
        await _columnNames(db, 'conversations'),
        contains('summary_cursor_message_id'),
      );
      expect(
        await _columnNames(db, 'conversations'),
        containsAll(<String>[
          'context_mode',
          'continuity_id',
          'user_persona_id',
          'user_persona_snapshot',
          'worldbook_set_id',
        ]),
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
      expect(
        await _columnNames(db, 'rp_character_timeline'),
        containsAll(<String>[
          'event_key',
          'narrative_layer',
          'subject_entity_ids',
        ]),
      );
      expect(
        await _columnNames(db, 'usage_logs'),
        containsAll(<String>['request_kind', 'cost_known']),
      );

      final tables = await _objectNames(db, 'table');
      expect(
        tables,
        containsAll(<String>[
          'emotion_points',
          'grudge_seals',
          'character_timeline',
          'rp_character_timeline',
          'rp_story_characters',
          'rp_story_relationships',
          'rp_story_relationship_events',
          'rp_story_entity_aliases',
          'rp_story_states',
          'rp_story_projection_revisions',
          'context_summary_repairs',
          'pending_memory_actions',
          'web_search_usage_logs',
          'user_personas',
          'user_persona_mode_overrides',
          'character_persona_bindings',
          'character_signatures',
          'memory_embeddings',
        ]),
      );

      final indexes = await _objectNames(db, 'index');
      expect(
        indexes,
        containsAll(<String>[
          'idx_messages_conv_time',
          'idx_mem_char_mode_time',
          'idx_mem_char_context_time',
          'idx_spider_web_memory_1',
          'idx_spider_web_memory_2',
          'idx_archive_original_unique',
          'idx_archive_char_time',
          'idx_notes_char_time',
          'idx_voice_char_time',
          'idx_voice_conversation',
          'idx_context_summary_char_time',
          'idx_context_keyword_char_time',
          'idx_context_summary_scope_time',
          'idx_context_keyword_scope_time',
          'idx_emo_memory',
          'idx_emo_char_type_time',
          'idx_timeline_memory',
          'idx_timeline_event_daily_unique',
          'idx_timeline_source_message',
          'idx_rp_timeline_state',
          'idx_rp_timeline_event_lookup',
          'idx_rp_timeline_conversation',
          'idx_rp_projection_revision_summary',
          'idx_context_summary_repair_scope',
          'idx_saved_message_unique',
          'idx_pending_memory_character_status',
          'idx_pending_memory_source_message',
          'idx_spider_web_status',
          'idx_web_search_turn_once',
          'idx_web_search_call_once',
          'idx_web_search_budget_status',
          'idx_web_search_reservation',
          'idx_web_search_char_time',
          'idx_persona_binding_persona',
          'idx_character_signature_history',
          'idx_character_signature_selected',
          'idx_usage_kind_ts',
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

  test('v77 upgrade adds the one-entry-per-day diary table', () async {
    await DatabaseHelper.upgradeSchemaForTesting(db, 76);

    expect(
      await _columnNames(db, 'character_diaries'),
      containsAll(<String>['character_id', 'diary_date', 'title', 'body']),
    );
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'character_diaries'",
    );
    expect(
      indexes.map((row) => row['name']),
      contains('idx_character_diaries_character_date'),
    );
  });

  test('v73 upgrade creates RP projection history and repair queue', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.execute('DROP TABLE rp_story_projection_revisions');
    await db.execute('DROP TABLE context_summary_repairs');

    await DatabaseHelper.upgradeSchemaForTesting(db, 72);

    final tables = await _objectNames(db, 'table');
    expect(tables, contains('rp_story_projection_revisions'));
    expect(tables, contains('context_summary_repairs'));
    expect(
      await _columnNames(db, 'context_summary_repairs'),
      containsAll(<String>[
        'original_summary_id',
        'continuity_id',
        'source_message_start_id',
        'source_message_end_id',
        'status',
      ]),
    );
  });

  test('v74 upgrade adds request kind and trusted cost markers', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.execute('ALTER TABLE usage_logs RENAME TO usage_logs_v73');
    await db.execute('''
      CREATE TABLE usage_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        character_id TEXT DEFAULT 'default',
        prompt_tokens INTEGER DEFAULT 0,
        completion_tokens INTEGER DEFAULT 0,
        cache_hit_tokens INTEGER DEFAULT 0,
        cache_creation_tokens INTEGER DEFAULT 0,
        estimated_cost REAL DEFAULT 0.0
      )
    ''');
    await db.execute('DROP TABLE usage_logs_v73');

    await DatabaseHelper.upgradeSchemaForTesting(db, 73);

    expect(
      await _columnNames(db, 'usage_logs'),
      containsAll(<String>['request_kind', 'cost_known']),
    );
    expect(await _objectNames(db, 'index'), contains('idx_usage_kind_ts'));
  });

  test(
    'v52 repairs Daily-labelled memories with an RP source window',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      const now = '2026-09-19T00:00:00.000Z';
      await db.insert('conversations', <String, Object?>{
        'id': 'rp-source-window',
        'character_id': 'char-a',
        'title': 'RP',
        'context_mode': 'rp',
        'continuity_id': 'route-red',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('memories', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'mode': 'story',
        'category': '伏筆',
        'content': '錯標的 RP 記憶',
        'source_conversation_id': 'rp-source-window',
        'created_at': now,
        'updated_at': now,
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 51);

      final row = (await db.query(
        'memories',
        where: 'content = ?',
        whereArgs: ['錯標的 RP 記憶'],
      )).single;
      expect(row['context_mode'], 'rp');
      expect(row['continuity_id'], 'route-red');
    },
  );

  test('v46 upgrade adds the saved character signature column', () async {
    await db.execute('''
      CREATE TABLE characters (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await DatabaseHelper.upgradeSchemaForTesting(db, 46);

    expect(await _columnNames(db, 'characters'), contains('signature'));
  });

  test(
    'runtime schema repair recreates and backfills missing memory FTS',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.insert('memories', {
        'character_id': 'char-a',
        'mode': 'normal',
        'category': 'fact',
        'content': 'recoverable memory',
        'created_at': '2026-08-11T00:00:00.000Z',
        'updated_at': '2026-08-11T00:00:00.000Z',
        'status': 'active',
        'triggers': 'recoverable',
      });
      await db.execute('DROP TABLE memories_fts');

      await DatabaseHelper.ensureRuntimeSchemaForTesting(db);

      expect(await _objectNames(db, 'table'), contains('memories_fts'));
      final rows = await db.rawQuery(
        'SELECT rowid FROM memories_fts WHERE memories_fts MATCH ?',
        ['recoverable'],
      );
      expect(rows, hasLength(1));
    },
  );

  test(
    'v66 replaces legacy FTS5 with trigram and rebuilds only active rows',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      for (final trigger in const <String>[
        'memories_fts_ai',
        'memories_fts_au_deactivate',
        'memories_fts_au_activate',
        'memories_fts_au_content',
        'memories_fts_ad',
      ]) {
        await db.execute('DROP TRIGGER IF EXISTS $trigger');
      }
      await db.execute('DROP TABLE memories_fts');
      await db.execute('''
      CREATE VIRTUAL TABLE memories_fts
      USING fts5(content, triggers, content='', tokenize='unicode61')
    ''');
      final memoryId = await db.insert('memories', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-red',
        'mode': 'story',
        'category': '伏筆',
        'content': '沈昭嶼收起了琥珀吊墜',
        'created_at': '2026-09-24T00:00:00.000Z',
        'updated_at': '2026-09-24T00:00:00.000Z',
        'status': 'active',
        'triggers': '琥珀吊墜',
      });
      await db.insert('memories_fts', <String, Object?>{
        'rowid': memoryId,
        'content': '沈昭嶼收起了琥珀吊墜',
        'triggers': '琥珀吊墜',
      });
      await db.insert('memories', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-red',
        'mode': 'story',
        'category': '廢棄',
        'content': '不應重建的軟刪除記憶',
        'created_at': '2026-09-24T00:00:00.000Z',
        'updated_at': '2026-09-24T00:00:00.000Z',
        'status': 'rejected',
        'triggers': '軟刪除',
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 65);

      final sql = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = 'memories_fts'",
      )).single['sql']!.toString().toLowerCase();
      expect(sql, allOf(contains('fts5'), contains('trigram')));
      expect(
        (await db.rawQuery(
          'SELECT count(*) AS count FROM memories_fts',
        )).single['count'],
        1,
      );
      final results = await DatabaseHelper.searchMemoriesByText(
        '他是在什麼時候收起了琥珀吊墜的',
        mode: 'story',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-red',
      );
      expect(results.map((memory) => memory.id), contains(memoryId));
    },
  );

  test('FTS4 matchinfo fallback applies BM25 term and length scoring', () {
    Uint8List encode(List<int> values) =>
        Uint32List.fromList(values).buffer.asUint8List();

    // p=1, c=2, n=10, then average lengths, row lengths, and x triples.
    final strong = DatabaseHelper.bm25FromFts4MatchInfoForTesting(
      encode([1, 2, 10, 10, 1, 3, 0, 3, 12, 2, 0, 0, 0]),
    );
    final weak = DatabaseHelper.bm25FromFts4MatchInfoForTesting(
      encode([1, 2, 10, 10, 1, 10, 0, 1, 12, 2, 0, 0, 0]),
    );

    expect(strong, greaterThan(weak));
    expect(weak, greaterThan(0));
  });

  test('memory text search combines BM25 words with CJK fragments', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime(2026, 8, 11).toIso8601String();
    await db.insert('memories', {
      'character_id': 'char-a',
      'mode': 'normal',
      'category': 'fact',
      'content': 'We watched the lighthouse together.',
      'created_at': now,
      'updated_at': now,
      'status': 'active',
      'triggers': 'lighthouse',
    });
    await db.insert('memories', {
      'character_id': 'char-a',
      'mode': 'normal',
      'category': 'event',
      'content': '昭昭曾和 tata 一起去海邊散步',
      'created_at': now,
      'updated_at': now,
      'status': 'active',
      'triggers': '海邊',
    });

    final english = await DatabaseHelper.searchMemoriesByText(
      'lighthouse',
      mode: 'normal',
      characterId: 'char-a',
    );
    final chinese = await DatabaseHelper.searchMemoriesByText(
      '你還記得我們一起去海邊嗎',
      mode: 'normal',
      characterId: 'char-a',
    );

    expect(
      english.map((memory) => memory.content),
      contains('We watched the lighthouse together.'),
    );
    expect(
      chinese.map((memory) => memory.content),
      contains('昭昭曾和 tata 一起去海邊散步'),
    );
  });

  test('Chinese long sentence finds a keyword in the middle section', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime(2026, 9, 24).toIso8601String();
    await db.insert('memories', <String, Object?>{
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'route-blue',
      'mode': 'story',
      'category': '物品',
      'content': '晏辭把琥珀吊墜交給了昭昭保管',
      'created_at': now,
      'updated_at': now,
      'status': 'active',
      'triggers': '琥珀吊墜',
    });

    final results = await DatabaseHelper.searchMemoriesByText(
      '我想起他們先在雨夜談到書院的往事，中間曾經提到琥珀吊墜，後來才去渡口追查船夫的下落',
      mode: 'story',
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'route-blue',
    );

    expect(results.map((memory) => memory.content), contains('晏辭把琥珀吊墜交給了昭昭保管'));
  });

  test(
    'FTS4-compatible fallback keeps Chinese substrings searchable',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      for (final trigger in const <String>[
        'memories_fts_ai',
        'memories_fts_au_deactivate',
        'memories_fts_au_activate',
        'memories_fts_au_content',
        'memories_fts_ad',
      ]) {
        await db.execute('DROP TRIGGER IF EXISTS $trigger');
      }
      await db.execute('DROP TABLE memories_fts');
      // FTS4 unicode61 cannot segment a Chinese sentence into useful terms.
      // Removing the derived table forces the same bounded substring fallback
      // that runs after an empty FTS4 result, without requiring this desktop
      // SQLite build to compile the optional FTS4 module.
      final now = DateTime(2026, 9, 24).toIso8601String();
      await db.insert('memories', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'mode': 'normal',
        'category': '偏好',
        'content': '昭昭喜歡桂花烏龍茶',
        'created_at': now,
        'updated_at': now,
        'status': 'active',
        'triggers': '桂花烏龍',
      });

      final results = await DatabaseHelper.searchMemoriesByText(
        '記得他喜歡桂花烏龍茶',
        mode: 'normal',
        characterId: 'char-a',
      );

      expect(results.map((memory) => memory.content), contains('昭昭喜歡桂花烏龍茶'));
    },
  );

  test('BM25 search remains responsive with a few thousand memories', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final batch = db.batch();
    for (var i = 0; i < 3000; i++) {
      batch.insert('memories', {
        'character_id': 'char-a',
        'mode': 'normal',
        'category': 'fact',
        'content': i == 1777
            ? 'the unique lighthouse needle memory'
            : 'ordinary synthetic memory number $i',
        'created_at': '2026-08-11T00:00:00.000Z',
        'updated_at': '2026-08-11T00:00:00.000Z',
        'status': 'active',
        'triggers': '',
      });
    }
    await batch.commit(noResult: true);

    final stopwatch = Stopwatch()..start();
    final results = await DatabaseHelper.searchMemoriesByText(
      'lighthouse needle',
      mode: 'normal',
      characterId: 'char-a',
      limit: 10,
    );
    stopwatch.stop();

    expect(results, isNotEmpty);
    expect(results.first.content, contains('lighthouse'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('v41 adds per-character whisper fields with safe defaults', () async {
    await db.execute('''
      CREATE TABLE characters (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.insert('characters', {
      'id': 'legacy-char',
      'name': 'Legacy',
      'created_at': '2026-08-08T00:00:00.000',
      'updated_at': '2026-08-08T00:00:00.000',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 40);

    final row = (await db.query('characters')).single;
    expect(row['whisper_user_text'], '');
    expect(row['whisper_model_text'], '');
    expect(row['whisper_source'], 'default');
    expect(row['whisper_model_override'], 1);
  });

  test('v42 adds the privacy-minimized web-search provider ledger', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.execute('DROP TABLE web_search_usage_logs');

    await DatabaseHelper.upgradeSchemaForTesting(db, 41);

    expect(
      await _columnNames(db, 'web_search_usage_logs'),
      containsAll(<String>[
        'reservation_id',
        'conversation_id',
        'character_id',
        'turn_id',
        'generation_serial',
        'plan_strategy',
        'provider',
        'provider_model',
        'provider_route',
        'call_id',
        'status',
        'search_requests',
        'actual_cost_usd',
        'cost_certainty',
      ]),
    );
    final columns = await _columnNames(db, 'web_search_usage_logs');
    expect(columns.where((column) => column.contains('query')), isEmpty);
    expect(columns.where((column) => column.contains('source')), isEmpty);
    expect(columns.where((column) => column.contains('key')), isEmpty);
    expect(
      await _objectNames(db, 'index'),
      containsAll(<String>[
        'idx_web_search_turn_once',
        'idx_web_search_call_once',
        'idx_web_search_budget_status',
      ]),
    );
  });

  test(
    'v44 adds message search traces without rewriting existing rows',
    () async {
      await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL
      )
    ''');
      await db.insert('messages', <String, Object?>{'text': 'legacy reply'});

      await DatabaseHelper.upgradeSchemaForTesting(db, 43);

      expect(
        await _columnNames(db, 'messages'),
        contains('web_search_trace_json'),
      );
      final row = (await db.query('messages')).single;
      expect(row['text'], 'legacy reply');
      expect(row['web_search_trace_json'], '');
    },
  );

  test('v46 adds local email drafts without rewriting existing rows', () async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL
      )
    ''');
    await db.insert('messages', <String, Object?>{'text': 'legacy reply'});

    await DatabaseHelper.upgradeSchemaForTesting(db, 45);

    expect(await _columnNames(db, 'messages'), contains('email_draft_json'));
    final row = (await db.query('messages')).single;
    expect(row['text'], 'legacy reply');
    expect(row['email_draft_json'], '');
  });

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
    'v39 adds the memory proposal inbox without touching existing data',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.insert('memories', {
        'character_id': 'char-a',
        'mode': 'romance',
        'category': '重要事件',
        'content': '升級前記憶',
        'created_at': '2026-08-05T00:00:00.000',
        'updated_at': '2026-08-05T00:00:00.000',
        'last_accessed': '2026-08-05T00:00:00.000',
      });
      await db.execute('DROP TABLE pending_memory_actions');

      await DatabaseHelper.upgradeSchemaForTesting(db, 38);

      expect(
        await _objectNames(db, 'table'),
        contains('pending_memory_actions'),
      );
      expect(
        await _objectNames(db, 'index'),
        containsAll([
          'idx_pending_memory_character_status',
          'idx_pending_memory_source_message',
        ]),
      );
      expect(
        await db.query('memories', where: 'content = ?', whereArgs: ['升級前記憶']),
        hasLength(1),
      );
    },
  );

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
    await db.insert('messages', {
      'id': 72,
      'conversation_id': 'conv-a',
      'character_id': 'char-a',
      'text': 'covered message',
      'is_user': 0,
      'created_at': '2026-07-18T09:01:00.000',
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
    expect(rows.single['display_anchor_message_id'], 72);
    expect(await DatabaseHelper.getSummaryRecordedMessageIds('conv-a'), <int>{
      72,
    });
  });

  test(
    'summary cursor and visible shortcut may use different messages',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.insert('conversations', {
        'id': 'conv-late-summary',
        'character_id': 'char-a',
        'created_at': '2026-09-26T09:00:00.000',
        'updated_at': '2026-09-26T09:00:00.000',
      });
      for (final id in <int>[91, 92]) {
        await db.insert('messages', {
          'id': id,
          'conversation_id': 'conv-late-summary',
          'character_id': 'char-a',
          'text': 'message $id',
          'is_user': id.isOdd ? 1 : 0,
          'created_at': '2026-09-26T09:0${id - 90}:00.000',
        });
      }

      final summaryId =
          await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
            characterId: 'char-a',
            content: 'summary created after another reply arrived',
            tokenCount: 12,
            conversationId: 'conv-late-summary',
            cursorMessageId: 91,
            displayAnchorMessageId: 92,
            sourceWindowId: 'W-LATE',
          );

      expect(
        await DatabaseHelper.getConversationSummaryCursor('conv-late-summary'),
        91,
      );
      expect(
        await DatabaseHelper.getSummaryRecordedAnchors('conv-late-summary'),
        <int, int>{92: summaryId},
      );
    },
  );

  test('legacy summary marker follows summary completion time', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', {
      'id': 'conv-legacy-summary',
      'character_id': 'char-a',
      'created_at': '2026-09-26T09:00:00.000',
      'updated_at': '2026-09-26T09:00:00.000',
    });
    for (final entry in <(int, String)>[
      (101, '2026-09-26T09:01:00.000'),
      (102, '2026-09-26T09:02:00.000'),
    ]) {
      await db.insert('messages', {
        'id': entry.$1,
        'conversation_id': 'conv-legacy-summary',
        'character_id': 'char-a',
        'text': 'message ${entry.$1}',
        'is_user': entry.$1.isOdd ? 1 : 0,
        'summary_recorded': entry.$1 == 101 ? 1 : 0,
        'created_at': entry.$2,
      });
    }
    final summaryId = await db.insert('context_summaries', {
      'character_id': 'char-a',
      'source_window_id': 'LEGACY',
      'source_conversation_id': 'conv-legacy-summary',
      'context_mode': 'daily',
      'continuity_id': 'main',
      'content': 'legacy summary',
      'token_count': 10,
      'created_at': '2026-09-26T09:03:00.000',
    });

    expect(
      await DatabaseHelper.getSummaryRecordedAnchors('conv-legacy-summary'),
      <int, int>{102: summaryId},
    );
  });

  test('one conversation can persist more than one rolling summary', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', {
      'id': 'conv-repeat',
      'character_id': 'char-a',
      'created_at': '2026-09-26T09:00:00.000',
      'updated_at': '2026-09-26T09:00:00.000',
    });
    for (final id in <int>[81, 82]) {
      await db.insert('messages', {
        'id': id,
        'conversation_id': 'conv-repeat',
        'character_id': 'char-a',
        'text': 'batch $id',
        'is_user': id.isOdd ? 1 : 0,
        'created_at': '2026-09-26T09:0${id - 80}:00.000',
      });
    }

    await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: 'first summary',
      tokenCount: 10,
      conversationId: 'conv-repeat',
      cursorMessageId: 81,
      sourceWindowId: 'W1',
    );
    await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: 'second summary',
      tokenCount: 11,
      conversationId: 'conv-repeat',
      cursorMessageId: 82,
      sourceWindowId: 'W2',
    );

    expect(
      await DatabaseHelper.getConversationSummaryCursor('conv-repeat'),
      82,
    );
    expect(
      await db.query(
        'context_summaries',
        where: 'source_conversation_id = ?',
        whereArgs: <Object?>['conv-repeat'],
      ),
      hasLength(2),
    );
    expect(
      await DatabaseHelper.getSummaryRecordedMessageIds('conv-repeat'),
      <int>{81, 82},
    );
  });

  test('v58 adds summary marker column without marking old messages', () async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        text TEXT NOT NULL,
        is_user INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.insert('messages', <String, Object?>{
      'conversation_id': 'legacy-conv',
      'text': 'legacy message',
      'is_user': 1,
      'created_at': '2026-07-18T09:00:00.000',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 57);

    expect(await _columnNames(db, 'messages'), contains('summary_recorded'));
    expect((await db.query('messages')).single['summary_recorded'], 0);
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

  test('chat history search executes against SQLite', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', {
      'id': 'conv-search-a',
      'character_id': 'char-a',
      'title': '跨窗口線索',
      'created_at': '2026-08-20T00:00:00.000',
      'updated_at': '2026-08-20T00:00:00.000',
    });
    await db.insert('messages', {
      'conversation_id': 'conv-search-a',
      'character_id': 'char-a',
      'text': '睫毛根旁邊有一顆小痣。',
      'is_user': 0,
      'created_at': '2026-08-20T00:01:00.000',
    });

    final results = await DatabaseHelper.searchMessages(
      keyword: '小痣',
      characterId: 'char-a',
    );

    expect(results, hasLength(1));
    expect(results.single['text'], contains('小痣'));
    expect(results.single['title'], '跨窗口線索');
  });

  test(
    'conversation search finds an early window by message keyword',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      await db.insert('conversations', <String, Object?>{
        'id': 'conv-early',
        'character_id': 'char-a',
        'title': '最早的普通窗口',
        'created_at': '2024-01-01T00:00:00.000',
        'updated_at': '2024-01-01T00:00:00.000',
      });
      await db.insert('conversations', <String, Object?>{
        'id': 'conv-other-character',
        'character_id': 'char-b',
        'title': '另一個角色',
        'created_at': '2026-08-20T00:00:00.000',
        'updated_at': '2026-08-20T00:00:00.000',
      });
      for (final conversationId in <String>[
        'conv-early',
        'conv-other-character',
      ]) {
        await db.insert('messages', <String, Object?>{
          'conversation_id': conversationId,
          'character_id': conversationId == 'conv-early' ? 'char-a' : 'char-b',
          'text': '只有消息正文包含琥珀耳墜這個線索。',
          'is_user': 0,
          'created_at': '2024-01-01T00:01:00.000',
        });
      }
      // 同一窗口多次命中也只能返回一個窗口。
      await db.insert('messages', <String, Object?>{
        'conversation_id': 'conv-early',
        'character_id': 'char-a',
        'text': '後來又提到琥珀耳墜。',
        'is_user': 1,
        'created_at': '2024-01-01T00:02:00.000',
      });

      final results = await DatabaseHelper.searchConversations(
        '琥珀耳墜',
        characterId: 'char-a',
      );

      expect(results.map((conversation) => conversation.id), <String>[
        'conv-early',
      ]);
    },
  );

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

  test('conversation coin snapshot is pinned only once', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await DatabaseHelper.createConversation(
      Conversation(id: 'conv-coins', characterId: 'char-a'),
    );

    final first =
        await DatabaseHelper.setConversationPinnedCoinSnapshotIfAbsent(
          'conv-coins',
          characterCoins: 800,
          userCoins: 900,
        );
    final second =
        await DatabaseHelper.setConversationPinnedCoinSnapshotIfAbsent(
          'conv-coins',
          characterCoins: 830,
          userCoins: 930,
        );

    expect(first, (characterCoins: 800, userCoins: 900));
    expect(second, first);
    expect(
      await DatabaseHelper.getConversationPinnedCoinSnapshot('conv-coins'),
      first,
    );
  });

  test('v53 adds nullable conversation coin snapshots', () async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.insert('conversations', <String, Object?>{
      'id': 'existing-conv',
      'created_at': '2026-09-20T00:00:00.000Z',
      'updated_at': '2026-09-20T00:00:00.000Z',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 52);

    expect(
      await _columnNames(db, 'conversations'),
      containsAll(<String>[
        'pinned_coin_snapshot_char',
        'pinned_coin_snapshot_user',
      ]),
    );
    final row = (await db.query('conversations')).single;
    expect(row['pinned_coin_snapshot_char'], isNull);
    expect(row['pinned_coin_snapshot_user'], isNull);
  });

  test('v55 removes legacy thinking-only character signatures', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('characters', <String, Object?>{
      'id': 'char-thinking-signature',
      'name': '小澈',
      'signature': '<think>I should explain this signature.</think>',
      'created_at': '2026-09-22T00:00:00.000Z',
      'updated_at': '2026-09-22T00:00:00.000Z',
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-thinking-signature',
      'character_id': 'char-thinking-signature',
      'context_mode': 'daily',
      'continuity_id': 'main',
      'created_at': '2026-09-22T00:00:00.000Z',
      'updated_at': '2026-09-22T00:00:00.000Z',
    });
    await db.insert('character_signatures', <String, Object?>{
      'character_id': 'char-thinking-signature',
      'conversation_id': 'conv-thinking-signature',
      'context_mode': 'daily',
      'continuity_id': 'main',
      'phase': 'opening',
      'signature': '<think>I should explain this signature.</think>',
      'is_selected': 1,
      'created_at': '2026-09-22T00:00:01.000Z',
      'updated_at': '2026-09-22T00:00:01.000Z',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 54);

    expect(await db.query('character_signatures'), isEmpty);
    final character = await DatabaseHelper.getCharacter(
      'char-thinking-signature',
    );
    expect(character?['signature'], '');
  });

  test('v56 backfills the legacy card signature into window history', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('characters', <String, Object?>{
      'id': 'char-legacy-signature',
      'name': '小澈',
      'signature': '風從舊窗口吹回來。',
      'created_at': '2026-09-20T00:00:00.000Z',
      'updated_at': '2026-09-22T08:30:00.000Z',
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-older',
      'character_id': 'char-legacy-signature',
      'context_mode': 'daily',
      'continuity_id': 'main',
      'created_at': '2026-09-20T00:00:00.000Z',
      'updated_at': '2026-09-20T01:00:00.000Z',
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-latest',
      'character_id': 'char-legacy-signature',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': '2026-09-21T00:00:00.000Z',
      'updated_at': '2026-09-22T00:00:00.000Z',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 55);
    await DatabaseHelper.upgradeSchemaForTesting(db, 55);

    final history = await db.query('character_signatures');
    expect(history, hasLength(1));
    expect(history.single['character_id'], 'char-legacy-signature');
    expect(history.single['conversation_id'], 'conv-latest');
    expect(history.single['context_mode'], 'rp');
    expect(history.single['continuity_id'], 'story-a');
    expect(history.single['phase'], 'closing');
    expect(history.single['signature'], '風從舊窗口吹回來。');
    expect(history.single['created_at'], '2026-09-22T08:30:00.000Z');
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

  test('batch archive and unlink are character-scoped and atomic', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final a1 = await _insertMemory(db, 'char-a', 'A1');
    final a2 = await _insertMemory(db, 'char-a', 'A2');
    final b1 = await _insertMemory(db, 'char-b', 'B1');
    expect(await DatabaseHelper.insertSpiderWebLink('char-a', a1, a2), isTrue);

    expect(
      await DatabaseHelper.archiveMemories(
        [a1, a2, b1, a2],
        'batch',
        characterId: 'char-a',
      ),
      2,
    );
    expect(await DatabaseHelper.getArchivedCount(characterId: 'char-a'), 2);
    expect(await DatabaseHelper.getArchivedCount(characterId: 'char-b'), 0);
    expect(
      await db.query(
        'memories',
        where: 'id IN (?, ?) AND status = ?',
        whereArgs: [a1, a2, 'deleted'],
      ),
      hasLength(2),
    );
    expect(
      await db.query('memories', where: 'id = ?', whereArgs: [b1]),
      isNotEmpty,
    );
    expect(await DatabaseHelper.deleteSpiderWebLink('char-b', a1, a2), isFalse);
    expect(await DatabaseHelper.deleteSpiderWebLink('char-a', a1, a2), isTrue);
    final rejectedLinks = await db.query('spider_web_links');
    expect(rejectedLinks, hasLength(1));
    expect(rejectedLinks.single['status'], 'rejected');
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
  });

  test(
    'batch restore returns archived memories in one scoped operation',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      final first = await _insertMemory(db, 'char-a', 'first');
      final second = await _insertMemory(db, 'char-a', 'second');
      expect(
        await DatabaseHelper.archiveMemories(
          [first, second],
          'batch restore test',
          characterId: 'char-a',
        ),
        2,
      );
      final archiveIds = (await DatabaseHelper.getArchivedMemories(
        characterId: 'char-a',
      )).map((row) => row['id'] as int).toList();

      expect(
        await DatabaseHelper.restoreFromArchives(
          archiveIds,
          characterId: 'char-a',
        ),
        2,
      );
      expect(await DatabaseHelper.getArchivedCount(characterId: 'char-a'), 0);
      expect(
        await db.query(
          'memories',
          where: 'id IN (?, ?) AND status = ?',
          whereArgs: [first, second, 'active'],
        ),
        hasLength(2),
      );
    },
  );

  test('archived endpoints hide their web links until restored', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final first = await _insertMemory(db, 'char-a', 'first');
    final second = await _insertMemory(db, 'char-a', 'second');
    expect(
      await DatabaseHelper.insertSpiderWebLink('char-a', first, second),
      isTrue,
    );
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), hasLength(1));

    expect(
      await DatabaseHelper.archiveMemories(
        [first],
        'hide linked endpoint',
        characterId: 'char-a',
      ),
      1,
    );
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
    expect(
      await DatabaseHelper.getSpiderWebLinks('char-a', includeRejected: true),
      isEmpty,
    );

    final archiveId =
        (await DatabaseHelper.getArchivedMemories(
              characterId: 'char-a',
            )).single['id']
            as int;
    expect(
      await DatabaseHelper.restoreFromArchive(archiveId, characterId: 'char-a'),
      isTrue,
    );
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), hasLength(1));
  });

  test('v40 backfills explainable spider relation metadata', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.execute('DROP TABLE spider_web_links');
    await db.execute('''
      CREATE TABLE spider_web_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        memory_id_1 INTEGER NOT NULL,
        memory_id_2 INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        CHECK(memory_id_1 < memory_id_2),
        UNIQUE(character_id, memory_id_1, memory_id_2)
      )
    ''');
    await db.insert('spider_web_links', {
      'character_id': 'char-a',
      'memory_id_1': 1,
      'memory_id_2': 2,
      'created_at': '2026-08-01T00:00:00.000',
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 39);

    expect(
      await _columnNames(db, 'spider_web_links'),
      containsAll(<String>[
        'relation_type',
        'strength',
        'status',
        'source',
        'reason',
        'updated_at',
      ]),
    );
    final row = (await db.query('spider_web_links')).single;
    expect(row['relation_type'], 'related');
    expect(row['strength'], 1.0);
    expect(row['status'], 'confirmed');
    expect(row['source'], 'legacy');
    expect(row['updated_at'], '2026-08-01T00:00:00.000');
  });

  test(
    'v63 allows multiple relation kinds and protects user decisions',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      final first = await _insertMemory(db, 'char-a', 'first');
      final second = await _insertMemory(db, 'char-a', 'second');

      expect(
        await DatabaseHelper.upsertSpiderWebRelationDetailed(
          'char-a',
          first,
          second,
          relationType: 'related',
          strength: 0.8,
          status: 'suggested',
          source: 'local_scan',
          reason: 'shared trigger',
        ),
        SpiderWebRelationWriteResult.inserted,
      );
      expect(
        await DatabaseHelper.upsertSpiderWebRelationDetailed(
          'char-a',
          first,
          second,
          relationType: 'related',
          strength: 0.8,
          status: 'suggested',
          source: 'local_scan',
          reason: 'shared trigger',
        ),
        SpiderWebRelationWriteResult.unchanged,
      );
      expect(
        await DatabaseHelper.upsertSpiderWebRelationDetailed(
          'char-a',
          first,
          second,
          relationType: 'temporal',
          strength: 0.7,
          status: 'suggested',
          source: 'model',
          reason: 'same period',
        ),
        SpiderWebRelationWriteResult.inserted,
      );
      expect(
        await DatabaseHelper.resolveSpiderWebRelation(
          'char-a',
          (await db.query(
                'spider_web_links',
                where: 'relation_type = ?',
                whereArgs: ['related'],
              )).single['id']
              as int,
          confirmed: true,
        ),
        isTrue,
      );
      expect(
        await DatabaseHelper.upsertSpiderWebRelationDetailed(
          'char-a',
          first,
          second,
          relationType: 'related',
          strength: 0.2,
          status: 'suggested',
          source: 'model',
          reason: 'model overwrite',
        ),
        SpiderWebRelationWriteResult.protected,
      );
      expect(
        await db.query(
          'spider_web_links',
          where: 'character_id = ?',
          whereArgs: ['char-a'],
        ),
        hasLength(2),
      );
    },
  );

  test('v64 removes old RP graph links and preserves daily links', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final dailyA = await _insertMemory(db, 'char-a', 'daily a');
    final dailyB = await _insertMemory(db, 'char-a', 'daily b');
    final rpA = await _insertMemory(db, 'char-a', 'rp a');
    final rpB = await _insertMemory(db, 'char-a', 'rp b');
    await db.update(
      'memories',
      <String, Object?>{'context_mode': 'rp', 'continuity_id': 'route-a'},
      where: 'id IN (?, ?)',
      whereArgs: <Object?>[rpA, rpB],
    );
    final now = DateTime.now().toIso8601String();
    Future<void> link(int first, int second) =>
        db.insert('spider_web_links', <String, Object?>{
          'character_id': 'char-a',
          'memory_id_1': first < second ? first : second,
          'memory_id_2': first < second ? second : first,
          'created_at': now,
          'updated_at': now,
        });
    await link(dailyA, dailyB);
    await link(rpA, rpB);
    await link(dailyA, rpA);

    await DatabaseHelper.upgradeSchemaForTesting(db, 63);

    final remaining = await db.query('spider_web_links');
    expect(remaining, hasLength(1));
    expect(remaining.single['memory_id_1'], dailyA);
    expect(remaining.single['memory_id_2'], dailyB);
    expect(await db.query('memories'), hasLength(4));
  });

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
    await db.insert('web_search_usage_logs', {
      'reservation_id': 'reservation-a',
      'logical_slot': 1,
      'conversation_id': 'conversation-a',
      'character_id': 'char-a',
      'turn_id': 'turn-a',
      'generation_serial': 1,
      'budget_day': '2026-08-09',
      'plan_strategy': 'single',
      'provider': 'openRouter',
      'provider_model': 'openai/gpt-5-mini',
      'provider_route': 'openrouter:web_search:exa:zdr-no-fallback',
      'status': 'success',
      'reserved_at': now,
      'expires_at': now,
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
      'web_search_usage_logs',
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
