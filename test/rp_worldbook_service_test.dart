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
      final revisionBefore = RpWorldbookService.revision.value;
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
      expect(RpWorldbookService.revision.value, greaterThan(revisionBefore));
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

  test(
    'recall keeps only triggerless global lore always-on and matches triggered lore',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      for (final row in <Map<String, Object?>>[
        <String, Object?>{
          'id': 'entry-global',
          'entry_key': 'WB-0001',
          'name': '共同曆法',
          'category': 'custom',
          'content': '全年分為十二月。',
          'scope': 'global',
          'activation_mode': 'always',
          'visibility': 'public',
          'triggers_json': '[]',
        },
        <String, Object?>{
          'id': 'entry-global-triggered',
          'entry_key': 'WB-0003',
          'name': '王室曆法',
          'category': 'custom',
          'content': '王室典禮使用銀月曆。',
          'scope': 'global',
          'activation_mode': 'triggered',
          'visibility': 'public',
          'triggers_json': '["銀月曆"]',
        },
        <String, Object?>{
          'id': 'entry-local',
          'entry_key': 'WB-0002',
          'name': '北境禁令',
          'category': 'law',
          'content': '北境城門夜間封閉。',
          'scope': '北境',
          'activation_mode': 'triggered',
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
      expect(unrelated, isNot(contains('王室曆法')));
      expect(unrelated, isNot(contains('北境禁令')));

      final related = await RpWorldbookService.recallPrompt(
        characterId: 'char-a',
        continuityId: 'story-a',
        query: '一行人抵達北境城門',
      );
      expect(related, contains('共同曆法'));
      expect(related, contains('北境禁令'));

      final triggeredGlobal = await RpWorldbookService.recallPrompt(
        characterId: 'char-a',
        continuityId: 'story-a',
        query: '王室正在核對銀月曆',
      );
      expect(triggeredGlobal, contains('王室曆法'));
      expect(triggeredGlobal, contains('共同曆法'));
    },
  );

  test(
    'recall caps triggerless global lore without starving a triggered entry',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      for (var index = 1; index <= 20; index++) {
        await db.insert('rp_worldbook_entries', <String, Object?>{
          'id': 'always-on-$index',
          'entry_key': 'WB-100$index',
          'character_id': 'char-a',
          'continuity_id': 'story-a',
          'name': '常駐設定 $index',
          'category': 'custom',
          'content': '這是第 $index 條常駐背景設定。',
          'scope': 'global',
          'activation_mode': 'always',
          'visibility': 'public',
          'status': 'active',
          'ended_reason': '',
          'triggers_json': '[]',
          'source_summary_ids': '[1]',
          'user_edited': 0,
          'created_at': now,
          'updated_at': now,
        });
      }
      await db.insert('rp_worldbook_entries', <String, Object?>{
        'id': 'triggered-entry',
        'entry_key': 'WB-2001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'name': '銀月橋規則',
        'category': 'law',
        'content': '銀月橋只在月圓時開放。',
        'scope': 'global',
        'activation_mode': 'triggered',
        'visibility': 'public',
        'status': 'active',
        'ended_reason': '',
        'triggers_json': '["銀月橋"]',
        'source_summary_ids': '[1]',
        'user_edited': 0,
        'created_at': now,
        'updated_at': now,
      });

      final prompt = await RpWorldbookService.recallPrompt(
        characterId: 'char-a',
        continuityId: 'story-a',
        query: '眾人抵達銀月橋',
      );
      expect(RegExp(r'常駐設定 \d+').allMatches(prompt), hasLength(3));
      expect(prompt, contains('銀月橋規則'));
    },
  );

  test('lead name alone cannot recall unrelated scoped lore', () async {
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('rp_worldbook_entries', <String, Object?>{
      'id': 'entry-name-only',
      'entry_key': 'WB-0003',
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'name': '北境軍籍制度',
      'category': 'law',
      'content': '江離曾在北境看過軍籍；制度本身按營分冊。',
      'scope': '北境軍營',
      'visibility': '軍中公開',
      'status': 'active',
      'ended_reason': '',
      'triggers_json': '["軍籍","分營造冊"]',
      'source_summary_ids': '[1]',
      'user_edited': 0,
      'created_at': now,
      'updated_at': now,
    });

    final nameOnly = await RpWorldbookService.recallPrompt(
      characterId: 'char-a',
      continuityId: 'story-a',
      query: '江離今天回到府中',
    );
    expect(nameOnly, isNot(contains('北境軍籍制度')));

    final settingTerm = await RpWorldbookService.recallPrompt(
      characterId: 'char-a',
      continuityId: 'story-a',
      query: '他查閱軍籍確認編制',
    );
    expect(settingTerm, contains('北境軍籍制度'));
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

  test(
    'pending review draft can be edited and merged into a saved entry',
    () async {
      final entryKey = await RpWorldbookService.createManualEntry(
        characterId: 'char-a',
        continuityId: 'story-a',
        name: '渡陽律例',
        content: '城門在戌時關閉。',
        category: 'law',
        scope: '渡陽城',
        visibility: 'public',
        triggers: const <String>['城門'],
      );
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_worldbook_review_items', <String, Object?>{
        'id': 'review-a',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'kind': 'conflict',
        'payload_json': jsonEncode(<String, Object?>{
          'entry_key': entryKey,
          'candidate_name': '渡陽宵禁',
          'candidate_content': '城門改為亥時關閉。',
          'source_summary_ids': <int>[7],
        }),
        'status': 'pending',
        'created_at': now,
        'updated_at': now,
      });

      await RpWorldbookService.updatePendingReviewDraft(
        id: 'review-a',
        characterId: 'char-a',
        continuityId: 'story-a',
        name: '渡陽城門令',
        content: '城門自秋日起改為亥時關閉。',
        category: 'law',
        scope: '渡陽城',
        visibility: 'public',
        triggers: const <String>['城門令'],
      );
      final pending = await db.query(
        'rp_worldbook_review_items',
        where: 'id = ?',
        whereArgs: const <Object?>['review-a'],
      );
      final draft =
          jsonDecode(pending.single['payload_json']! as String)
              as Map<String, dynamic>;
      expect(draft['candidate_name'], '渡陽城門令');
      expect(pending.single['status'], 'pending');

      await RpWorldbookService.resolvePendingReview(
        id: 'review-a',
        characterId: 'char-a',
        continuityId: 'story-a',
        name: draft['candidate_name']! as String,
        content: draft['candidate_content']! as String,
        category: draft['category']! as String,
        scope: draft['scope']! as String,
        visibility: draft['visibility']! as String,
        triggers: (draft['triggers']! as List<dynamic>).cast<String>(),
        targetEntryKey: entryKey,
      );

      final entries = await db.query(
        'rp_worldbook_entries',
        where: 'entry_key = ?',
        whereArgs: <Object?>[entryKey],
      );
      expect(entries.single['name'], '渡陽城門令');
      expect(entries.single['content'], '城門自秋日起改為亥時關閉。');
      expect(entries.single['user_edited'], 1);
      final resolved = await db.query(
        'rp_worldbook_review_items',
        where: 'id = ?',
        whereArgs: const <Object?>['review-a'],
      );
      expect(resolved.single['status'], 'resolved');
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
