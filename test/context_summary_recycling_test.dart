import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/context_compressor.dart';
import 'package:project_yanci/services/rp_story_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });
  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('below the cap, both lanes keep all recent summaries active', () async {
    for (final mode in [ContextMode.daily, ContextMode.rp]) {
      for (final name in ['a', 'b']) {
        await DatabaseHelper.insertContextSummary(
          characterId: 'char-a',
          content: '${mode.storageValue} $name',
          tokenCount: 900,
          contextMode: mode,
        );
      }
      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: mode,
        continuityId: 'main',
        extractKeywords: (_) async => 'unused',
      );
      expect(
        await DatabaseHelper.getContextSummaries('char-a', contextMode: mode),
        hasLength(2),
      );
      expect(
        await DatabaseHelper.getContextKeywords('char-a', contextMode: mode),
        isEmpty,
      );
    }
  });

  test('RP prompt pack injects the newest four active summaries', () async {
    for (var i = 1; i <= 5; i++) {
      await DatabaseHelper.insertContextSummary(
        characterId: 'char-a',
        content: '### ——主線——\n**[事件] 摘要 $i**',
        tokenCount: 10,
        contextMode: ContextMode.rp,
        continuityId: 'story-a',
      );
    }
    final pack = await ContextCompressor.loadSummaryPack(
      'char-a',
      includeKeywordRecall: false,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    expect(pack['summary'], isNot(contains('摘要 1')));
    for (var i = 2; i <= 5; i++) {
      expect(pack['summary'], contains('摘要 $i'));
    }
  });

  test(
    'daily keeps a rolling four blocks at this size; RP keeps four',
    () async {
      final dailyIds = <int>[];
      final rpIds = <int>[];
      Future<String> labels(String source) async => '$source tag';

      for (final name in ['a', 'b', 'c', 'd', 'e', 'f']) {
        dailyIds.add(
          await DatabaseHelper.insertContextSummary(
            characterId: 'char-a',
            content: 'daily $name',
            tokenCount: 900,
          ),
        );
        rpIds.add(
          await DatabaseHelper.insertContextSummary(
            characterId: 'char-a',
            content: 'rp $name',
            tokenCount: 12,
            contextMode: ContextMode.rp,
            continuityId: 'story-one',
          ),
        );
      }
      final otherStory = await DatabaseHelper.insertContextSummary(
        characterId: 'char-a',
        content: 'other story',
        tokenCount: 12,
        contextMode: ContextMode.rp,
        continuityId: 'story-two',
      );

      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
        extractKeywords: labels,
      );
      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-one',
        extractKeywords: labels,
      );
      // A retry cannot create the same labels twice.
      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-one',
        extractKeywords: labels,
      );

      expect(
        (await DatabaseHelper.getContextSummaries(
          'char-a',
        )).map((r) => r['id']),
        dailyIds.skip(2),
      );
      expect(
        (await DatabaseHelper.getContextSummaries(
          'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'story-one',
        )).map((r) => r['id']),
        rpIds.skip(2),
      );
      expect(
        (await DatabaseHelper.getContextSummaries(
          'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'story-two',
        )).single['id'],
        otherStory,
      );
      final dailyTags = await DatabaseHelper.getContextKeywords('char-a');
      final rpTags = await DatabaseHelper.getContextKeywords(
        'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-one',
      );
      expect(dailyTags.map((r) => r['source_summary_id']), dailyIds.take(2));
      expect(dailyTags.first['source_summary_content'], 'daily a');
      expect(rpTags.map((r) => r['source_summary_id']), rpIds.take(2));
      expect(rpTags.first['source_summary_content'], 'rp a');

      for (final name in ['g', 'h']) {
        dailyIds.add(
          await DatabaseHelper.insertContextSummary(
            characterId: 'char-a',
            content: 'daily $name',
            tokenCount: 900,
          ),
        );
      }
      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
        extractKeywords: labels,
      );
      expect(
        (await DatabaseHelper.getContextSummaries(
          'char-a',
        )).map((r) => r['id']),
        dailyIds.skip(4),
      );
      expect(
        (await DatabaseHelper.getContextKeywords(
          'char-a',
        )).map((r) => r['source_summary_id']),
        dailyIds.take(4),
      );
    },
  );

  test(
    'archived summaries keep their chat anchor and editable source',
    () async {
      await db.insert('conversations', {
        'id': 'conv-a',
        'character_id': 'char-a',
        'created_at': '2026-09-26T09:00:00.000',
        'updated_at': '2026-09-26T09:00:00.000',
      });
      for (final id in [101, 102]) {
        await db.insert('messages', {
          'id': id,
          'conversation_id': 'conv-a',
          'character_id': 'char-a',
          'text': 'message $id',
          'is_user': id.isOdd ? 1 : 0,
          'created_at': '2026-09-26T09:0${id - 100}:00.000',
        });
      }
      final first = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char-a',
        content: 'first version',
        tokenCount: 2000,
        conversationId: 'conv-a',
        cursorMessageId: 101,
      );
      final second = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char-a',
        content: 'second version',
        tokenCount: 2000,
        conversationId: 'conv-a',
        cursorMessageId: 102,
      );
      await ContextCompressor.recycleSupersededSummaries(
        'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
        extractKeywords: (_) async => 'first, version',
      );

      expect(await DatabaseHelper.getSummaryRecordedAnchors('conv-a'), {
        101: first,
        102: second,
      });
      expect(
        (await DatabaseHelper.getLatestContextSummaries(
          'char-a',
        )).map((row) => row['id']),
        [second],
      );
      expect(
        (await DatabaseHelper.getRelevantContextSummaries(
          'char-a',
          contextMode: ContextMode.daily,
          continuityId: 'main',
          sourceConversationIds: ['conv-a'],
        )).map((row) => row['id']),
        [second, first],
      );
      expect(
        (await DatabaseHelper.getConversationContextSummaryById(
          summaryId: first,
          conversationId: 'conv-a',
          contextMode: ContextMode.daily,
          continuityId: 'main',
        ))?['content'],
        'first version',
      );
      await DatabaseHelper.updateContextSummary(
        id: first,
        content: 'corrected first version',
        tokenCount: 12,
      );
      expect(
        (await DatabaseHelper.getContextKeywords(
          'char-a',
        )).single['source_summary_content'],
        'corrected first version',
      );
      await DatabaseHelper.deleteContextSummary(first);
      expect(await DatabaseHelper.getContextKeywords('char-a'), isEmpty);
      expect(await DatabaseHelper.getSummaryRecordedAnchors('conv-a'), {
        102: second,
      });
    },
  );

  test(
    'editing summarized text invalidates its derived summary chain',
    () async {
      await db.insert('conversations', {
        'id': 'conv-edit',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'created_at': '2026-10-02T09:00:00.000',
        'updated_at': '2026-10-02T09:00:00.000',
      });
      for (var id = 1; id <= 4; id++) {
        await db.insert('messages', {
          'id': id,
          'conversation_id': 'conv-edit',
          'character_id': 'char-a',
          'text': 'old message $id',
          'is_user': id.isOdd ? 1 : 0,
          'created_at': '2026-10-02T09:0$id:00.000',
        });
      }
      final first = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char-a',
        content: 'first summary',
        tokenCount: 100,
        conversationId: 'conv-edit',
        cursorMessageId: 2,
        contextMode: ContextMode.rp,
        continuityId: 'story-a',
      );
      final second = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char-a',
        content: 'second summary',
        tokenCount: 100,
        conversationId: 'conv-edit',
        cursorMessageId: 4,
        contextMode: ContextMode.rp,
        continuityId: 'story-a',
      );
      await DatabaseHelper.insertContextKeywords(
        characterId: 'char-a',
        keywords: 'old plot',
        tokenCount: 2,
        sourceSummaryId: first,
        sourceSummaryContent: 'first summary',
        sourceConversationId: 'conv-edit',
        contextMode: ContextMode.rp,
        continuityId: 'story-a',
      );
      const stateBase = <String, Object?>{
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'state_type': 'plot',
        'subject_entity_key': '',
        'object_entity_key': '',
        'narrative_layer': 'main',
        'status': 'active',
        'story_time': '',
        'source_conversation_id': 'conv-edit',
        'source_message_ids': '[1]',
        'evidence': 'old message 1',
        'created_at': '2026-10-02T09:05:00.000',
        'updated_at': '2026-10-02T09:05:00.000',
      };
      await db.insert('rp_story_states', <String, Object?>{
        ...stateBase,
        'id': 'state-model',
        'state_key': 'plot.model_state',
        'value': 'model-derived state',
        'source_summary_id': first,
        'user_edited': 0,
      });
      await db.insert('rp_story_states', <String, Object?>{
        ...stateBase,
        'id': 'state-user',
        'state_key': 'plot.user_state',
        'value': 'user-corrected state',
        'source_summary_id': first,
        'user_edited': 1,
      });
      for (final messageId in <int>[1, 3]) {
        await db.insert('rp_character_timeline', <String, Object?>{
          'character_id': 'char-a',
          'continuity_id': 'story-a',
          'source_conversation_id': 'conv-edit',
          'type': 'event',
          'value': 'event from message $messageId',
          'source_message_id': messageId,
          'source_message_ids': '[$messageId]',
          'source_evidence': 'old message $messageId',
          'sequence_order': messageId,
        });
      }

      await DatabaseHelper.updateMessageText(1, 'edited message 1');

      final revisions = await db.query('message_revisions');
      expect(revisions, hasLength(1));
      expect(revisions.single['message_id'], 1);
      expect(revisions.single['archive_reason'], 'edit');
      expect((await DatabaseHelper.getMessageById(1))?.revision, 2);
      final summaries = await db.query('context_summaries', orderBy: 'id ASC');
      expect(summaries.map((row) => row['id']), <int>[first, second]);
      expect(
        summaries.map((row) => row['revision_status']),
        everyElement('invalidated'),
      );
      expect(await db.query('context_keywords'), isEmpty);
      final remainingStates = await db.query('rp_story_states');
      expect(remainingStates, hasLength(1));
      expect(remainingStates.single['id'], 'state-user');
      expect(await db.query('rp_character_timeline'), isEmpty);
      expect(
        await DatabaseHelper.getSummaryRecordedAnchors('conv-edit'),
        isEmpty,
      );
      expect(
        (await db.query(
          'conversations',
          where: 'id = ?',
          whereArgs: ['conv-edit'],
        )).single['summary_cursor_message_id'],
        0,
      );
    },
  );

  test(
    'editing RP source rolls character and relationship projections back',
    () async {
      const conversationId = 'conv-projection';
      const characterId = 'char-a';
      const continuityId = 'story-a';
      const sourceText = '沈昭嶼與晏辭從陌生變成盟友，柳青首次登場。';
      const createdAt = '2026-10-02T09:00:00.000';
      await db.insert('conversations', <String, Object?>{
        'id': conversationId,
        'character_id': characterId,
        'context_mode': 'rp',
        'continuity_id': continuityId,
        'created_at': createdAt,
        'updated_at': createdAt,
      });
      await db.insert('messages', <String, Object?>{
        'id': 101,
        'conversation_id': conversationId,
        'character_id': characterId,
        'text': sourceText,
        'is_user': 1,
        'created_at': createdAt,
      });

      Future<void> insertCharacter({
        required String id,
        required String entityKey,
        required String name,
        required String identity,
      }) async {
        await db.insert('rp_story_characters', <String, Object?>{
          'id': id,
          'entity_key': entityKey,
          'character_id': characterId,
          'continuity_id': continuityId,
          'normalized_name': name,
          'name': name,
          'identity': identity,
          'tier': 'common',
          'mention_count': 2,
          'last_seen_at': createdAt,
          'created_at': createdAt,
          'updated_at': createdAt,
        });
        await db.insert('rp_story_entity_aliases', <String, Object?>{
          'character_id': characterId,
          'continuity_id': continuityId,
          'entity_key': entityKey,
          'normalized_alias': name,
          'display_alias': name,
          'alias_type': 'name',
          'created_at': createdAt,
          'updated_at': createdAt,
        });
      }

      await insertCharacter(
        id: 'person-a',
        entityKey: 'P-0001',
        name: '沈昭嶼',
        identity: '學徒',
      );
      await insertCharacter(
        id: 'person-b',
        entityKey: 'P-0002',
        name: '晏辭',
        identity: '書生',
      );
      await db.insert('rp_story_relationships', <String, Object?>{
        'id': 'relation-a-b',
        'character_id': characterId,
        'continuity_id': continuityId,
        'from_name': '沈昭嶼',
        'to_name': '晏辭',
        'from_entity_key': 'P-0001',
        'to_entity_key': 'P-0002',
        'normalized_edge': 'P-0001|P-0002|mutual',
        'direction': 'mutual',
        'current_relation': '陌生',
        'origin': '渡口初見',
        'created_at': createdAt,
        'updated_at': createdAt,
      });

      final summaryId =
          await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
            characterId: characterId,
            content: '本輪摘要',
            tokenCount: 100,
            conversationId: conversationId,
            cursorMessageId: 101,
            contextMode: ContextMode.rp,
            continuityId: continuityId,
          );
      final sourceMessage = Message(
        id: 101,
        conversationId: conversationId,
        characterId: characterId,
        text: sourceText,
        isUser: true,
        createdAt: DateTime.parse(createdAt),
      );
      await RpStoryService.storeExtraction(
        characterId: characterId,
        continuityId: continuityId,
        sourceConversationId: conversationId,
        sourceMessages: <Message>[sourceMessage],
        sourceSummaryId: summaryId,
        characters: const <Map<String, Object?>>[
          <String, Object?>{
            'entity_id': 'P-0001',
            'name': '沈昭嶼',
            'aliases': <String>['昭昭'],
            'identity': '藥師',
            'source_message_ids': <int>[101],
            'evidence': '沈昭嶼',
          },
          <String, Object?>{
            'entity_id': 'new',
            'name': '柳青',
            'identity': '新登場人物',
            'source_message_ids': <int>[101],
            'evidence': '柳青首次登場',
          },
        ],
        relationships: const <Map<String, Object?>>[
          <String, Object?>{
            'from_entity_id': 'P-0001',
            'to_entity_id': 'P-0002',
            'from': '沈昭嶼',
            'to': '晏辭',
            'direction': 'mutual',
            'current_relation': '盟友',
            'change': '兩人結盟',
            'source_message_ids': <int>[101],
            'evidence': '沈昭嶼與晏辭從陌生變成盟友',
          },
        ],
      );

      expect(
        (await db.query(
          'rp_story_characters',
          where: 'entity_key = ?',
          whereArgs: <Object?>['P-0001'],
        )).single['identity'],
        '藥師',
      );
      expect(await db.query('rp_story_characters'), hasLength(3));
      expect(
        (await db.query('rp_story_relationships')).single['current_relation'],
        '盟友',
      );
      expect(await db.query('rp_story_relationship_events'), hasLength(1));
      expect(await db.query('rp_story_projection_revisions'), hasLength(3));

      await DatabaseHelper.updateMessageText(101, '沈昭嶼沒有遇見任何人。');

      final characters = await db.query(
        'rp_story_characters',
        orderBy: 'entity_key ASC',
      );
      expect(characters, hasLength(2));
      expect(characters.first['entity_key'], 'P-0001');
      expect(characters.first['identity'], '學徒');
      expect(characters.first['aliases_json'], '[]');
      expect(
        (await db.query(
          'rp_story_entity_aliases',
          where: 'entity_key = ?',
          whereArgs: <Object?>['P-0001'],
        )).map((row) => row['display_alias']),
        <Object?>['沈昭嶼'],
      );
      expect(
        (await db.query('rp_story_relationships')).single['current_relation'],
        '陌生',
      );
      expect(await db.query('rp_story_relationship_events'), isEmpty);
      expect(await db.query('rp_story_projection_revisions'), isEmpty);
    },
  );

  test('failed labels and locked summaries remain active', () async {
    await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: 'failed label',
      tokenCount: 1300,
    );
    final locked = await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: 'locked summary',
      tokenCount: 1300,
    );
    await DatabaseHelper.updateSummaryLockState(id: locked, locked: true);
    await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: 'latest summary',
      tokenCount: 1300,
    );

    await ContextCompressor.recycleSupersededSummaries(
      'char-a',
      contextMode: ContextMode.daily,
      continuityId: 'main',
      extractKeywords: (_) async => '',
    );
    expect(await DatabaseHelper.getContextSummaries('char-a'), hasLength(3));
    expect(await DatabaseHelper.getContextKeywords('char-a'), isEmpty);
  });

  test('RP archived labels recall only inside the same storyline', () async {
    final summaryId = await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: '### ——主線——\n**[物品] 白鶴印信**\n印信證明來客受書院院長委託。',
      tokenCount: 40,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    await DatabaseHelper.insertContextKeywords(
      characterId: 'char-a',
      keywords: '白鶴印信, 書院委託',
      tokenCount: 8,
      sourceSummaryId: summaryId,
      sourceSummaryContent: '### ——主線——\n**[物品] 白鶴印信**\n印信證明來客受書院院長委託。',
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );

    final matched = await ContextCompressor.loadSummaryPack(
      'char-a',
      currentMessage: '重新查看白鶴印信的來歷',
      includeLatestSummaries: false,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    final other = await ContextCompressor.loadSummaryPack(
      'char-a',
      currentMessage: '重新查看白鶴印信的來歷',
      includeLatestSummaries: false,
      contextMode: ContextMode.rp,
      continuityId: 'story-b',
    );

    expect(matched['keywordSummaries'], contains('白鶴印信'));
    expect(other['keywordSummaries'], isEmpty);
  });

  test(
    'RP label recall can return up to three distinct event summaries',
    () async {
      for (var i = 1; i <= 4; i++) {
        final summary = '### ——主線——\n**[衝突] 白鶴印信交付事件 $i**\n第 $i 次推進書院委託。';
        final summaryId = await DatabaseHelper.insertContextSummary(
          characterId: 'char-a',
          content: summary,
          tokenCount: 30,
          contextMode: ContextMode.rp,
          continuityId: 'story-a',
        );
        await DatabaseHelper.insertContextKeywords(
          characterId: 'char-a',
          keywords: '白鶴印信交付',
          tokenCount: 5,
          sourceSummaryId: summaryId,
          sourceSummaryContent: summary,
          contextMode: ContextMode.rp,
          continuityId: 'story-a',
        );
      }

      final pack = await ContextCompressor.loadSummaryPack(
        'char-a',
        currentMessage: '重新追查白鶴印信交付',
        includeLatestSummaries: false,
        contextMode: ContextMode.rp,
        continuityId: 'story-a',
      );
      final recalled = pack['keywordSummaries'] ?? '';
      expect(
        RegExp(r'Keyword-matched old summary').allMatches(recalled),
        hasLength(3),
      );
    },
  );

  test(
    'v67 upgrade adds the archive state without changing old rows',
    () async {
      // Replace only this in-memory test table with its v67 shape.
      await db.execute('DROP TABLE context_summaries');
      await db.execute('''
        CREATE TABLE context_summaries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_id TEXT NOT NULL,
          context_mode TEXT NOT NULL DEFAULT 'daily',
          continuity_id TEXT NOT NULL DEFAULT 'main',
          content TEXT NOT NULL,
          token_count INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          display_anchor_message_id INTEGER
        )
      ''');
      await db.insert('context_summaries', {
        'character_id': 'char-a',
        'content': 'existing',
        'token_count': 5,
        'created_at': '2026-09-26T09:00:00.000',
      });
      await DatabaseHelper.upgradeSchemaForTesting(db, 67);
      expect((await db.query('context_summaries')).single['archived'], 0);
    },
  );
}
