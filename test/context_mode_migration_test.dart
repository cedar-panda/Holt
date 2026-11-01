import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/chat_diagnostic_event.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/message.dart';
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
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('v48 migrates every pre-RP scope to daily exactly once', () async {
    await _createV47ScopeFixture(db);

    await DatabaseHelper.upgradeSchemaForTesting(db, 47);

    final conversation = (await db.query('conversations')).single;
    final character = (await db.query('characters')).single;
    final memory = (await db.query('memories')).single;
    final summary = (await db.query('context_summaries')).single;
    final keyword = (await db.query('context_keywords')).single;
    final proposal = (await db.query('pending_memory_actions')).single;

    expect(conversation['context_mode'], 'daily');
    expect(conversation['continuity_id'], 'main');
    expect(character['preferred_context_mode'], 'daily');
    expect(memory['context_mode'], 'daily');
    expect(memory['continuity_id'], 'main');
    expect(memory['mode'], 'romance', reason: 'legacy memory bucket is intact');
    expect(summary['context_mode'], 'daily');
    expect(summary['continuity_id'], 'main');
    expect(keyword['context_mode'], 'daily');
    expect(keyword['continuity_id'], 'main');
    expect(proposal['context_mode'], 'daily');
    expect(proposal['continuity_id'], 'main');
    expect(await _tableNames(db), contains('rp_character_timeline'));

    await db.update(
      'conversations',
      <String, Object?>{'context_mode': 'rp'},
      where: 'id = ?',
      whereArgs: <Object?>['conv-old'],
    );
    await DatabaseHelper.upgradeSchemaForTesting(db, 48);
    expect(
      (await db.query('conversations')).single['context_mode'],
      'rp',
      reason: 'later versions must not repeat the daily baseline update',
    );
  });

  test('fresh schema enforces context values and creates RP indexes', () async {
    await DatabaseHelper.createSchemaForTesting(db);

    expect(DatabaseHelper.schemaVersionForTesting, 86);
    expect(await _columnNames(db, 'characters'), contains('remark'));
    expect(
      await _columnNames(db, 'characters'),
      contains('tts_voice_ids_json'),
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
      await _columnNames(db, 'memories'),
      containsAll(<String>['context_mode', 'continuity_id', 'is_pinned']),
    );
    expect(await _columnNames(db, 'messages'), contains('summary_recorded'));
    expect(
      await _columnNames(db, 'context_summaries'),
      contains('display_anchor_message_id'),
    );
    expect(
      await _indexNames(db),
      containsAll(<String>[
        'idx_mem_char_context_time',
        'idx_context_summary_scope_time',
        'idx_context_keyword_scope_time',
        'idx_rp_timeline_state',
        'idx_rp_timeline_event_lookup',
        'idx_rp_timeline_conversation',
        'idx_persona_binding_persona',
      ]),
    );
    expect(
      await _tableNames(db),
      containsAll(<String>[
        'user_personas',
        'character_persona_bindings',
        'chat_diagnostics',
      ]),
    );

    await expectLater(
      db.insert('conversations', <String, Object?>{
        'id': 'invalid-mode',
        'character_id': 'char-a',
        'context_mode': 'story',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.insert('conversations', <String, Object?>{
        'id': 'empty-continuity',
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': '   ',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.insert('characters', <String, Object?>{
        'id': 'invalid-preference',
        'name': 'A',
        'preferred_context_mode': 'story',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test(
    'v82 collapses mode-scoped persona bindings into one shared pair',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      final older = DateTime.utc(2026, 9, 1).toIso8601String();
      final newer = DateTime.utc(2026, 9, 2).toIso8601String();
      for (final characterId in <String>['char-a', 'char-b']) {
        await db.insert('characters', <String, Object?>{
          'id': characterId,
          'name': characterId,
          'created_at': older,
          'updated_at': older,
        });
      }
      for (final personaId in <String>['persona-old', 'persona-new']) {
        await db.insert('user_personas', <String, Object?>{
          'id': personaId,
          'display_name': personaId,
          'created_at': older,
          'updated_at': older,
        });
      }
      await db.insert('character_persona_bindings', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'user_persona_id': 'persona-old',
        'created_at': older,
        'updated_at': older,
      });
      await db.insert('character_persona_bindings', <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-b',
        'user_persona_id': 'persona-new',
        'created_at': newer,
        'updated_at': newer,
      });
      await db.insert('character_persona_bindings', <String, Object?>{
        'character_id': 'char-b',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'user_persona_id': 'persona-new',
        'created_at': older,
        'updated_at': older,
      });

      await DatabaseHelper.upgradeSchemaForTesting(db, 81);

      final bindings = await db.query('character_persona_bindings');
      expect(bindings, hasLength(1));
      expect(bindings.single['character_id'], 'char-a');
      expect(bindings.single['user_persona_id'], 'persona-new');
      expect(bindings.single['context_mode'], 'daily');
      expect(bindings.single['continuity_id'], 'main');
    },
  );

  test('v69 registers existing RP continuity as a storyline', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-story',
      'name': 'Story character',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-story',
      'character_id': 'char-story',
      'context_mode': 'rp',
      'continuity_id': 'route-b',
      'created_at': now,
      'updated_at': now,
    });
    await db.execute('DROP TABLE rp_storylines');

    await DatabaseHelper.upgradeSchemaForTesting(db, 68);

    final storylines = await db.query('rp_storylines');
    expect(storylines, hasLength(1));
    expect(storylines.single['character_id'], 'char-story');
    expect(storylines.single['id'], 'route-b');
    expect(storylines.single['is_default'], 0);
  });

  test('new RP windows register at most three active storylines', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-three',
      'name': 'Three routes',
      'created_at': now,
      'updated_at': now,
    });
    for (final route in <String>['a', 'b', 'c']) {
      await DatabaseHelper.createConversation(
        Conversation(
          id: 'conv-$route',
          characterId: 'char-three',
          contextMode: ContextMode.rp,
          continuityId: route,
          createdAt: DateTime.parse(now),
          updatedAt: DateTime.parse(now),
        ),
      );
    }

    expect(await DatabaseHelper.getRpStorylines('char-three'), hasLength(3));
    await expectLater(
      DatabaseHelper.createConversation(
        Conversation(
          id: 'conv-d',
          characterId: 'char-three',
          contextMode: ContextMode.rp,
          continuityId: 'd',
          createdAt: DateTime.parse(now),
          updatedAt: DateTime.parse(now),
        ),
      ),
      throwsStateError,
    );
    expect(await DatabaseHelper.getConversation('conv-d'), isNull);
  });

  test('chat diagnostic is persistent and unique per source message', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('conversations', <String, Object?>{
      'id': 'diagnostic-conversation',
      'character_id': 'char-a',
      'created_at': '2026-09-23T00:00:00.000Z',
      'updated_at': '2026-09-23T00:00:00.000Z',
    });
    final sourceId = await db.insert('messages', <String, Object?>{
      'conversation_id': 'diagnostic-conversation',
      'character_id': 'char-a',
      'text': 'hello',
      'is_user': 1,
      'created_at': '2026-09-23T00:00:00.000Z',
    });

    final first = await DatabaseHelper.upsertChatDiagnostic(
      ChatDiagnosticEvent(
        conversationId: 'diagnostic-conversation',
        sourceMessageId: sourceId,
        anchorMessageId: sourceId,
        category: 'rate_limit',
        statusCode: 429,
        provider: 'OpenRouter',
        model: 'model-a',
        rawLog: 'HTTP 429: too many requests',
        createdAt: DateTime.utc(2026, 9, 23),
      ),
    );
    final updated = await DatabaseHelper.upsertChatDiagnostic(
      ChatDiagnosticEvent(
        conversationId: 'diagnostic-conversation',
        sourceMessageId: sourceId,
        anchorMessageId: sourceId,
        category: 'upstream',
        statusCode: 503,
        provider: 'OpenRouter',
        model: 'model-a',
        rawLog: 'HTTP 503: unavailable',
        createdAt: DateTime.utc(2026, 9, 23, 1),
      ),
    );

    final restored = await DatabaseHelper.getChatDiagnostics(
      'diagnostic-conversation',
    );
    expect(updated.id, first.id);
    expect(restored, hasLength(1));
    expect(restored.single.category, 'upstream');
    expect(restored.single.rawLog, contains('503'));

    await DatabaseHelper.deleteChatDiagnosticsForMessages(<int>[sourceId]);
    expect(
      await DatabaseHelper.getChatDiagnostics('diagnostic-conversation'),
      isEmpty,
    );
  });

  test('v49 revives pre-v1.5 archives and resets islands only once', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    final old = DateTime.now().subtract(const Duration(days: 120));
    await db.insert('characters', <String, Object?>{
      'id': 'char-v49',
      'name': 'V49',
      'created_at': old.toIso8601String(),
      'updated_at': old.toIso8601String(),
    });
    final islandId = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-v49',
        mode: 'romance',
        category: '偏好',
        content: 'island',
        mentionCount: 12,
        createdAt: old,
        updatedAt: old,
        lastAccessed: old,
      ),
    );
    final archivedId = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-v49',
        mode: 'romance',
        category: '關係',
        content: 'archived',
        mentionCount: 8,
        createdAt: old,
        updatedAt: old,
        lastAccessed: old,
      ),
    );
    await DatabaseHelper.archiveMemory(
      archivedId,
      '用戶手動刪除',
      characterId: 'char-v49',
    );

    await DatabaseHelper.upgradeSchemaForTesting(db, 48);

    final revived = await db.query(
      'memories',
      where: 'id IN (?, ?)',
      whereArgs: <Object?>[islandId, archivedId],
      orderBy: 'id ASC',
    );
    expect(revived, hasLength(2));
    for (final row in revived) {
      expect(row['status'], 'active');
      expect(row['mention_count'], 0);
      expect(row['clarity'], 1.0);
      expect(
        DateTime.parse(row['last_accessed'] as String).isAfter(old),
        isTrue,
      );
    }
    expect(await db.query('archive'), isEmpty);

    await db.update(
      'memories',
      <String, Object?>{'mention_count': 5},
      where: 'id = ?',
      whereArgs: <Object?>[islandId],
    );
    await DatabaseHelper.upgradeSchemaForTesting(db, 49);
    expect(
      (await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: [islandId],
      )).single['mention_count'],
      5,
      reason: 'later versions must not repeat the v1.5 activation reset',
    );
  });

  test('branch inherits immutable RP context identity', () async {
    await DatabaseHelper.createSchemaForTesting(db);
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'source-rp',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-b',
        userPersonaId: 'persona-a',
        userPersonaSnapshot: '{"version":1,"id":"persona-a"}',
        worldbookSetId: 'world-a',
      ),
    );

    final branchId = await DatabaseHelper.branchConversation(
      sourceConversationId: 'source-rp',
      beforeMessageId: 1,
    );
    final branch = await DatabaseHelper.getConversation(branchId);

    expect(branch, isNotNull);
    expect(branch!.contextMode, ContextMode.rp);
    expect(branch.continuityId, 'route-b');
    expect(branch.userPersonaId, 'persona-a');
    expect(branch.userPersonaSnapshot, '{"version":1,"id":"persona-a"}');
    expect(branch.worldbookSetId, 'world-a');
  });

  test('v50 creates persona storage and pins legacy windows once', () async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        character_id TEXT DEFAULT 'default',
        context_mode TEXT NOT NULL DEFAULT 'daily',
        continuity_id TEXT NOT NULL DEFAULT 'main',
        user_persona_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      INSERT INTO conversations (
        id, character_id, context_mode, continuity_id, user_persona_id,
        created_at, updated_at
      ) VALUES (
        'legacy-window', 'char-a', 'rp', 'main', NULL,
        '2026-09-13T00:00:00.000Z', '2026-09-13T00:00:00.000Z'
      )
    ''');
    await db.execute('''
      INSERT INTO conversations (
        id, character_id, context_mode, continuity_id, user_persona_id,
        created_at, updated_at
      ) VALUES (
        'reserved-window', 'char-a', 'rp', 'main', 'reserved-persona',
        '2026-09-13T00:00:00.000Z', '2026-09-13T00:00:00.000Z'
      )
    ''');

    await DatabaseHelper.upgradeSchemaForTesting(db, 49);

    expect(
      await _tableNames(db),
      containsAll(<String>['user_personas', 'character_persona_bindings']),
    );
    final row = (await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: const <Object?>['legacy-window'],
    )).single;
    expect(row['user_persona_id'], 'default');
    expect(row['user_persona_snapshot'], '');
    expect(
      (await db.query(
        'user_personas',
        where: 'id = ?',
        whereArgs: const <Object?>['default'],
      )).single['is_default'],
      1,
    );
    expect(
      (await db.query(
        'user_personas',
        where: 'id = ?',
        whereArgs: const <Object?>['reserved-persona'],
      )).single['is_default'],
      0,
      reason: 'a reserved cache identity must not become an orphan',
    );

    await db.update(
      'conversations',
      <String, Object?>{'user_persona_id': 'kept'},
      where: 'id = ?',
      whereArgs: const <Object?>['legacy-window'],
    );
    await DatabaseHelper.upgradeSchemaForTesting(db, 50);
    expect(
      (await db.query(
        'conversations',
        where: 'id = ?',
        whereArgs: const <Object?>['legacy-window'],
      )).single['user_persona_id'],
      'kept',
      reason: 'later versions must not repeat the v50 persona baseline',
    );
  });

  test(
    'v60 repairs legacy RP merge lanes and leaves mixed evidence untouched',
    () async {
      await DatabaseHelper.createSchemaForTesting(db);
      const now = '2026-09-24T00:00:00.000Z';
      for (final conversation in const <Map<String, Object?>>[
        <String, Object?>{
          'id': 'rp-window',
          'character_id': 'char-a',
          'context_mode': 'rp',
          'continuity_id': 'route-rp',
        },
        <String, Object?>{
          'id': 'daily-window',
          'character_id': 'char-a',
          'context_mode': 'daily',
          'continuity_id': 'main',
        },
      ]) {
        await db.insert('conversations', <String, Object?>{
          ...conversation,
          'created_at': now,
          'updated_at': now,
        });
      }

      Future<int> insertMemory({
        required String content,
        required String sourceConversationId,
        String contextMode = 'daily',
        String continuityId = 'main',
        String status = 'active',
      }) {
        return db.insert('memories', <String, Object?>{
          'character_id': 'char-a',
          'context_mode': contextMode,
          'continuity_id': continuityId,
          'mode': 'classic',
          'category': '重要事件',
          'content': content,
          'source_conversation_id': sourceConversationId,
          'created_at': now,
          'updated_at': now,
          'last_accessed': now,
          'status': status,
        });
      }

      final rpSourceA = await insertMemory(
        content: 'rp source a',
        sourceConversationId: 'rp-window',
        status: 'deleted',
      );
      final rpSourceB = await insertMemory(
        content: 'rp source b',
        sourceConversationId: 'rp-window',
        status: 'deleted',
      );
      final mergedRp = await insertMemory(
        content: 'merged rp',
        sourceConversationId: '',
      );
      final dailySource = await insertMemory(
        content: 'daily source',
        sourceConversationId: 'daily-window',
        contextMode: 'rp',
        continuityId: 'wrong-route',
        status: 'deleted',
      );
      final mixedReplacement = await insertMemory(
        content: 'mixed replacement',
        sourceConversationId: '',
      );

      Future<void> insertProposal({
        required String id,
        required List<int> archivedIds,
        required int newMemoryId,
      }) {
        return db.insert('pending_memory_actions', <String, Object?>{
          'id': id,
          'character_id': 'char-a',
          'context_mode': 'daily',
          'continuity_id': 'main',
          'mode': 'classic',
          'action': 'merge',
          'source': 'legacy',
          'source_conversation_id': '',
          'target_ids_json': jsonEncode(archivedIds),
          'payload_json': '{}',
          'base_versions_json': '{}',
          'fingerprint': 'fingerprint-$id',
          'status': 'completed',
          'created_at': now,
          'resolved_at': now,
          'error': '',
          'result_json': jsonEncode(<String, Object?>{
            'new_memory_id': newMemoryId,
            'archived_ids': archivedIds,
          }),
        });
      }

      await insertProposal(
        id: 'rp-merge',
        archivedIds: <int>[rpSourceA, rpSourceB],
        newMemoryId: mergedRp,
      );
      await insertProposal(
        id: 'mixed-merge',
        archivedIds: <int>[rpSourceA, dailySource],
        newMemoryId: mixedReplacement,
      );
      for (final sourceId in <int>[rpSourceA, rpSourceB, dailySource]) {
        final source = (await db.query(
          'memories',
          where: 'id = ?',
          whereArgs: <Object?>[sourceId],
        )).single;
        await db.insert('archive', <String, Object?>{
          'character_id': 'char-a',
          'original_id': sourceId,
          'original_table': 'memories',
          'content_snapshot': jsonEncode(source),
          'archived_at': now,
          'reason': 'legacy merge',
        });
      }

      await DatabaseHelper.upgradeSchemaForTesting(db, 59);

      final repaired = (await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: <Object?>[mergedRp],
      )).single;
      expect(repaired['context_mode'], 'rp');
      expect(repaired['continuity_id'], 'route-rp');
      final repairedProposal = (await db.query(
        'pending_memory_actions',
        where: 'id = ?',
        whereArgs: const <Object?>['rp-merge'],
      )).single;
      expect(repairedProposal['context_mode'], 'rp');
      expect(repairedProposal['continuity_id'], 'route-rp');

      final correctedDaily = (await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: <Object?>[dailySource],
      )).single;
      expect(correctedDaily['context_mode'], 'daily');
      expect(correctedDaily['continuity_id'], 'main');
      final mixed = (await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: <Object?>[mixedReplacement],
      )).single;
      expect(mixed['context_mode'], 'daily');
      expect(mixed['continuity_id'], 'main');

      final archived = await db.query('archive', orderBy: 'original_id ASC');
      final snapshots = <int, Map<String, Object?>>{
        for (final row in archived)
          row['original_id'] as int: Map<String, Object?>.from(
            jsonDecode(row['content_snapshot'] as String) as Map,
          ),
      };
      expect(snapshots[rpSourceA]?['context_mode'], 'rp');
      expect(snapshots[rpSourceA]?['continuity_id'], 'route-rp');
      expect(snapshots[dailySource]?['context_mode'], 'daily');
      expect(snapshots[dailySource]?['continuity_id'], 'main');
    },
  );
}

Future<void> _createV47ScopeFixture(Database db) async {
  await db.execute('''
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      character_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
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
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      character_id TEXT,
      mode TEXT NOT NULL,
      status TEXT,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE context_summaries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      character_id TEXT NOT NULL,
      source_conversation_id TEXT,
      content TEXT NOT NULL,
      token_count INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE context_keywords (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      character_id TEXT NOT NULL,
      source_conversation_id TEXT,
      keywords TEXT NOT NULL,
      token_count INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE pending_memory_actions (
      id TEXT PRIMARY KEY,
      character_id TEXT NOT NULL,
      mode TEXT NOT NULL
    )
  ''');

  const now = '2026-09-12T00:00:00.000Z';
  await db.insert('conversations', <String, Object?>{
    'id': 'conv-old',
    'character_id': 'char-a',
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('characters', <String, Object?>{
    'id': 'char-a',
    'name': 'A',
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('memories', <String, Object?>{
    'character_id': 'char-a',
    'mode': 'romance',
    'status': 'active',
    'created_at': now,
  });
  await db.insert('context_summaries', <String, Object?>{
    'character_id': 'char-a',
    'source_conversation_id': 'conv-old',
    'content': 'summary',
    'token_count': 1,
    'created_at': now,
  });
  await db.insert('context_keywords', <String, Object?>{
    'character_id': 'char-a',
    'source_conversation_id': 'conv-old',
    'keywords': 'keyword',
    'token_count': 1,
    'created_at': now,
  });
  await db.insert('pending_memory_actions', <String, Object?>{
    'id': 'proposal-old',
    'character_id': 'char-a',
    'mode': 'romance',
  });
}

Future<Set<String>> _columnNames(Database db, String table) async =>
    (await db.rawQuery(
      "PRAGMA table_info('$table')",
    )).map((row) => row['name'] as String).toSet();

Future<Set<String>> _tableNames(Database db) async => (await db.query(
  'sqlite_master',
  where: "type = 'table'",
)).map((row) => row['name'] as String).toSet();

Future<Set<String>> _indexNames(Database db) async => (await db.query(
  'sqlite_master',
  where: "type = 'index'",
)).map((row) => row['name'] as String).toSet();
