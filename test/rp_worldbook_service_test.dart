import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/rp_worldbook_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'rp_worldbook_auto_write_v1': true,
      'rp_worldbook_summary_interval_v1': 4,
    });
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '測試角色',
      'created_at': now,
      'updated_at': now,
    });
    for (final id in const <String>['story-a', 'story-b']) {
      await db.insert('rp_storylines', <String, Object?>{
        'character_id': 'char-a',
        'id': id,
        'name': id,
        'status': 'active',
        'is_default': id == 'story-a' ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      });
    }
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'fourth RP summary triggers exactly one independent worldbook pass',
    () async {
      var calls = 0;
      Future<String> modelCall({
        required String systemPrompt,
        required String userMessage,
      }) async {
        calls += 1;
        final payload = jsonDecode(userMessage) as Map<String, dynamic>;
        final batch = payload['summary_batch'] as List<dynamic>;
        final sourceId = (batch.last as Map<String, dynamic>)['summary_id'];
        return jsonEncode(<String, Object?>{
          'storyline_id': 'story-a',
          'worldbook_updates': <Object?>[
            <String, Object?>{
              'operation': 'create',
              'entry_key': '',
              'merge_entry_keys': <Object?>[],
              'name': '渡陽律例',
              'category': 'law',
              'content': '渡陽城夜間實施宵禁。',
              'scope': '渡陽城',
              'visibility': '城中居民皆知',
              'triggers': <String>['渡陽城', '宵禁'],
              'ended_reason': '',
              'source_summary_ids': <Object?>[sourceId],
              'evidence': '渡陽城夜間實施宵禁',
            },
          ],
          'possible_duplicates': <Object?>[],
          'conflicts': <Object?>[],
        });
      }

      for (var index = 1; index <= 3; index++) {
        await _insertSummary(index, 'story-a');
        await RpWorldbookService.maybeProcessAfterSummary(
          characterId: 'char-a',
          continuityId: 'story-a',
          callModel: modelCall,
        );
      }
      expect(calls, 0);
      await _insertSummary(4, 'story-a');
      await RpWorldbookService.maybeProcessAfterSummary(
        characterId: 'char-a',
        continuityId: 'story-a',
        callModel: modelCall,
      );

      expect(calls, 1);
      final entries = await db.query('rp_worldbook_entries');
      expect(entries, hasLength(1));
      expect(entries.single['entry_key'], 'WB-0001');
      expect(entries.single['continuity_id'], 'story-a');
    },
  );

  test('recall remains isolated to one storyline', () async {
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('rp_worldbook_entries', <String, Object?>{
      'id': 'entry-a',
      'entry_key': 'WB-0001',
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'name': '雪嶺青',
      'category': 'species',
      'content': '只生長於嵩臨山背面崖壁。',
      'scope': '嵩臨山',
      'visibility': '採藥人知情',
      'status': 'active',
      'ended_reason': '',
      'triggers_json': '["雪嶺青"]',
      'source_summary_ids': '[1]',
      'user_edited': 0,
      'created_at': now,
      'updated_at': now,
    });

    expect(
      await RpWorldbookService.recallPrompt(
        characterId: 'char-a',
        continuityId: 'story-a',
        query: '雪嶺青',
      ),
      contains('雪嶺青'),
    );
    expect(
      await RpWorldbookService.recallPrompt(
        characterId: 'char-a',
        continuityId: 'story-b',
        query: '雪嶺青',
      ),
      isEmpty,
    );
  });

  test('recall keeps global lore but omits unrelated scoped entries', () async {
    const now = '2026-10-02T00:00:00.000Z';
    for (final row in <Map<String, Object?>>[
      <String, Object?>{
        'id': 'entry-global',
        'entry_key': 'WB-0001',
        'name': '共同曆法',
        'category': 'custom',
        'content': '全年分為十二月。',
        'scope': 'global',
        'visibility': 'public',
        'triggers_json': '["曆法"]',
      },
      <String, Object?>{
        'id': 'entry-local',
        'entry_key': 'WB-0002',
        'name': '北境禁令',
        'category': 'law',
        'content': '北境城門夜間封閉。',
        'scope': '北境',
        'visibility': 'public',
        'triggers_json': '["北境","城門"]',
      },
    ]) {
      await db.insert('rp_worldbook_entries', <String, Object?>{
        ...row,
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'status': 'active',
        'ended_reason': '',
        'source_summary_ids': '[1]',
        'user_edited': 0,
        'created_at': now,
        'updated_at': now,
      });
    }

    final unrelated = await RpWorldbookService.recallPrompt(
      characterId: 'char-a',
      continuityId: 'story-a',
      query: '她在南方茶樓坐下',
    );
    expect(unrelated, contains('共同曆法'));
    expect(unrelated, isNot(contains('北境禁令')));

    final related = await RpWorldbookService.recallPrompt(
      characterId: 'char-a',
      continuityId: 'story-a',
      query: '一行人抵達北境城門',
    );
    expect(related, contains('共同曆法'));
    expect(related, contains('北境禁令'));
  });

  test('storyline mismatch keeps the batch cursor for retry', () async {
    for (var index = 1; index <= 4; index++) {
      await _insertSummary(index, 'story-a');
    }
    await RpWorldbookService.maybeProcessAfterSummary(
      characterId: 'char-a',
      continuityId: 'story-a',
      callModel: ({required systemPrompt, required userMessage}) async =>
          '{"storyline_id":"story-b","worldbook_updates":[],'
          '"possible_duplicates":[],"conflicts":[]}',
    );

    expect(await db.query('rp_worldbook_sync_state'), isEmpty);
    expect(await db.query('rp_worldbook_entries'), isEmpty);
  });

  test(
    'summary invalidated during the model call cannot create ghost lore',
    () async {
      for (var index = 1; index <= 4; index++) {
        await _insertSummary(index, 'story-a');
      }
      await RpWorldbookService.maybeProcessAfterSummary(
        characterId: 'char-a',
        continuityId: 'story-a',
        callModel: ({required systemPrompt, required userMessage}) async {
          final summaries = await db.query(
            'context_summaries',
            orderBy: 'id ASC',
            limit: 1,
          );
          await db.update(
            'context_summaries',
            <String, Object?>{'revision_status': 'invalidated'},
            where: 'id = ?',
            whereArgs: <Object?>[summaries.single['id']],
          );
          final sourceId = summaries.single['id'];
          return jsonEncode(<String, Object?>{
            'storyline_id': 'story-a',
            'worldbook_updates': <Object?>[
              <String, Object?>{
                'operation': 'create',
                'entry_key': '',
                'merge_entry_keys': <Object?>[],
                'name': '幽靈設定',
                'category': 'other',
                'content': '不應寫入。',
                'scope': 'global',
                'visibility': 'public',
                'triggers': <Object?>[],
                'ended_reason': '',
                'source_summary_ids': <Object?>[sourceId],
                'evidence': '渡陽城夜間實施宵禁',
              },
            ],
            'possible_duplicates': <Object?>[],
            'conflicts': <Object?>[],
          });
        },
      );

      expect(await db.query('rp_worldbook_sync_state'), isEmpty);
      expect(await db.query('rp_worldbook_entries'), isEmpty);
    },
  );

  test(
    'manual worldbook edits are protected from automatic replacement',
    () async {
      final entryKey = await RpWorldbookService.createManualEntry(
        characterId: 'char-a',
        continuityId: 'story-a',
        name: '渡陽律例',
        content: '城門在戌時關閉。',
        category: 'law',
        scope: '渡陽城',
        visibility: '城中居民皆知',
        triggers: const <String>['渡陽城', '城門'],
      );
      expect(entryKey, 'WB-0001');

      for (var index = 1; index <= 4; index++) {
        await _insertSummary(index, 'story-a');
      }
      await RpWorldbookService.maybeProcessAfterSummary(
        characterId: 'char-a',
        continuityId: 'story-a',
        callModel: ({required systemPrompt, required userMessage}) async {
          final payload = jsonDecode(userMessage) as Map<String, dynamic>;
          final batch = payload['summary_batch'] as List<dynamic>;
          final sourceId = (batch.last as Map<String, dynamic>)['summary_id'];
          return jsonEncode(<String, Object?>{
            'storyline_id': 'story-a',
            'worldbook_updates': <Object?>[
              <String, Object?>{
                'operation': 'update',
                'entry_key': entryKey,
                'merge_entry_keys': <Object?>[],
                'name': '渡陽律例',
                'category': 'law',
                'content': '模型嘗試改寫的內容。',
                'scope': '渡陽城',
                'visibility': 'public',
                'triggers': <String>['宵禁'],
                'ended_reason': '',
                'source_summary_ids': <Object?>[sourceId],
                'evidence': '渡陽城夜間實施宵禁',
              },
            ],
            'possible_duplicates': <Object?>[],
            'conflicts': <Object?>[],
          });
        },
      );

      final rows = await db.query(
        'rp_worldbook_entries',
        where: 'entry_key = ?',
        whereArgs: <Object?>[entryKey],
      );
      expect(rows, hasLength(1));
      expect(rows.single['content'], '城門在戌時關閉。');
      expect(rows.single['user_edited'], 1);
    },
  );
}

Future<void> _insertSummary(int index, String continuityId) async {
  await DatabaseHelper.insertContextSummary(
    characterId: 'char-a',
    content: '第 $index 份摘要：渡陽城夜間實施宵禁。',
    tokenCount: 20,
    contextMode: ContextMode.rp,
    continuityId: continuityId,
  );
}
