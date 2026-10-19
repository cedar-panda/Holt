import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/retriever.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/character_timeline_service.dart';
import 'package:project_yanci/services/context_compressor.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/recall_text_matcher.dart';
import 'package:project_yanci/services/rp_character_timeline_service.dart';
import 'package:project_yanci/services/rp_story_service.dart';
import 'package:project_yanci/services/rp_story_state_service.dart';
import 'package:project_yanci/services/settings/context_mode_settings.dart';
import 'package:project_yanci/widgets/context_mode_pill.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RP summary prompt is a standalone story dossier contract', () {
    final daily = ContextCompressor.compressionPromptForMode(ContextMode.daily);
    final rp = ContextCompressor.compressionPromptForMode(ContextMode.rp);

    expect(daily, contains('menstrual cycle'));
    expect(rp, contains('story dossier'));
    expect(rp, contains('story_characters'));
    expect(rp, contains('relationships'));
    expect(rp, contains('complete replacement narrative map'));
    expect(rp, contains('one stable card per person'));
    expect(rp, contains('first meeting'));
    expect(rp, contains('cannot overwrite origin or catalyst'));
    expect(rp, contains('source_message_ids'));
    expect(rp, contains('Preserve actor, order, causality'));
    expect(rp, contains('stable entity_id'));
    expect(rp, contains('scene.current'));
    expect(rp, contains('concrete profiles'));
    expect(rp, contains('keyword-recalled worldbook facts'));
    expect(rp, contains('per-person knowledge'));
    expect(rp, contains('relationship pair separate'));
    expect(rp, contains('objective fact, public claim'));
    expect(rp, contains('Transient fatigue'));
    expect(rp, contains('Keep one copy of each event'));
    expect(rp, contains('worldbook extraction'));
    expect(rp, contains('1600 characters'));
    expect(rp, contains('storyline_id'));
    expect(rp, contains('24 changed characters'));
    expect(rp, contains('matched-existing list is not exhaustive'));
    expect(rp, isNot(contains('Prior Context')));
    expect(rp, isNot(contains('menstrual')));
    expect(rp, isNot(contains('character health')));
  });

  test('RP summary ceiling scales with storyline source volume', () {
    expect(ContextCompressor.suggestedRpSummaryMaxCharsForSource(99999), 1200);
    expect(ContextCompressor.suggestedRpSummaryMaxCharsForSource(100000), 2200);
    expect(ContextCompressor.suggestedRpSummaryMaxCharsForSource(300000), 2800);
    expect(ContextCompressor.suggestedRpSummaryMaxCharsForSource(700000), 3400);
    expect(
      ContextCompressor.suggestedRpSummaryMaxCharsForSource(1200000),
      4000,
    );
  });

  test('rolling summary anchors keep the two newest bases in order', () {
    final formatted = ContextCompressor.formatRollingSummaryAnchorsForTesting(
      <String>['摘要 A', '摘要 B'],
    );

    expect(formatted, contains('anchor 1'));
    expect(formatted, contains('anchor 2'));
    expect(formatted.indexOf('摘要 A'), lessThan(formatted.indexOf('摘要 B')));
  });

  test(
    'RP rolling summary restores omitted event locally without another model call',
    () {
      const old = '''### ——主線——
**[不可逆] 城門決裂**
兩人在城門公開決裂，盟約因此終止並留下長期敵意。

**[伏筆] 密函去向**
密函被第三人帶走，去向仍未查明。''';
      const next = '''### ——主線——
**[伏筆] 密函去向**
密函仍未尋回，但已確認最後出現在驛站。''';

      final restored =
          ContextCompressor.restoreMissingRpCarryoverEventsForTesting(
            anchors: const <String>[old],
            nextSummary: next,
          );

      expect(restored, contains('**[不可逆] 城門決裂**'));
      expect(restored, contains('盟約因此終止'));
      expect(
        ContextCompressor.missingRpCarryoverTitlesForTesting(
          anchors: const <String>[old],
          nextSummary: restored,
        ),
        isEmpty,
      );
    },
  );

  test('RP rolling guard rejects summaries that erase prior events', () {
    const prior = '''
### ——主線——
**[衝突] 青鸞印信交付**
顧遠在渡口交付青鸞印信，清川因此允許他暫住。

**[關係] 冬至之約**
兩人在藥鋪約定冬至再會。
''';
    const incomplete = '''
### ——主線——
**[關係] 冬至之約**
兩人在藥鋪約定冬至再會。
''';
    const complete = '''
### ——主線——
**[衝突] 青鸞印信交付**
顧遠交付印信後獲准暫住。

**[關係] 冬至之約**
兩人仍約定冬至再會。
''';

    expect(
      ContextCompressor.missingRpCarryoverTitlesForTesting(
        anchors: const <String>[prior],
        nextSummary: incomplete,
      ),
      <String>['青鸞印信交付'],
    );
    expect(
      ContextCompressor.missingRpCarryoverTitlesForTesting(
        anchors: const <String>[prior],
        nextSummary: complete,
      ),
      isEmpty,
    );
  });

  test('RP injection budgets retain complete event paragraphs', () {
    final first = '事件一：${List.filled(180, '甲').join()}。';
    final second = '事件二：${List.filled(180, '乙').join()}。';
    final third = '事件三：${List.filled(180, '丙').join()}。';
    final source = '$first\n\n$second\n\n$third';

    final fitted = ContextCompressor.fitRpSummaryToCharacterBudget(
      source,
      first.length + second.length + 2,
    );
    expect(fitted, '$first\n\n$second');
    expect(fitted, isNot(contains('事件三')));
  });

  test('chapter handoff prefers newer summaries inside one total budget', () {
    final oldSummary = '舊事件：${List.filled(700, '舊').join()}。';
    final newSummary = '新事件：${List.filled(700, '新').join()}。';
    final fitted = ContextCompressor.fitRpSummariesToCharacterBudget(<String>[
      oldSummary,
      newSummary,
    ], 900);

    expect(fitted, contains('新事件'));
    expect(fitted, isNot(contains('舊事件')));
  });

  test(
    'custom summary rules are optional and cannot replace hard rules',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'rp_summary_auto_max_chars_v1': false,
        'rp_summary_max_chars_v1': 3000,
      });
      final clean = await ContextCompressor.summaryPromptForRequest(
        contextMode: ContextMode.rp,
        characterId: 'char-a',
        continuityId: 'story-a',
      );
      expect(clean, isNot(contains('使用者自定義摘要偏好')));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('rp_summary_custom_rules_v1', '著重法律案件的因果鏈');
      final customized = await ContextCompressor.summaryPromptForRequest(
        contextMode: ContextMode.rp,
        characterId: 'char-a',
        continuityId: 'story-a',
      );
      expect(customized, contains('著重法律案件的因果鏈'));
      expect(customized, contains('required JSON schema'));
      expect(customized, contains('source-range rules'));
    },
  );

  test('CJK relevance terms keep short story entities searchable', () {
    final terms = RecallTextMatcher.relevanceTerms('她回到王城，摸了摸信物');
    expect(terms, containsAll(<String>['王城', '信物']));
  });

  test('RP envelope keeps storyline and accepts the new timeline schema', () {
    final decoded = ContextCompressor.decodeSummaryEnvelope('''
{"storyline_id":"story-a","summary":"### ——主線——\\n內容","timeline":[{"narrative_layer":"mainline","subject_entity_ids":["P-0001","P-0002"],"source_message_ids":[7],"occurred_on":"第三日","date_basis":"relative","value":"兩人結盟","evidence":"我們結盟"}],"story_states":[],"story_characters":[],"relationships":[]}
''');
    expect(decoded.storylineId, 'story-a');
    expect(decoded.timeline, hasLength(1));
    expect(decoded.timeline.single.type, 'event');
    expect(decoded.timeline.single.subject, 'relationship');
    expect(decoded.timeline.single.narrativeLayer, 'mainline');
    expect(decoded.timeline.single.subjectEntityIds, <String>[
      'P-0001',
      'P-0002',
    ]);
  });

  test('RP envelope binds recall labels to exact summary segments', () {
    final decoded = ContextCompressor.decodeSummaryEnvelope(r'''
{"storyline_id":"story-a","summary":"第一段：渡口交付青鸞印信。\n\n第二段：兩人在藥鋪立下冬至之約。","timeline":[],"story_states":[],"story_characters":[],"relationships":[],"recall_segments":[{"segment_order":1,"title":"印信交付","content":"第一段：渡口交付青鸞印信。","keywords":["渡口交付青鸞印信","書院信物"]},{"segment_order":2,"title":"冬至之約","content":"第二段：兩人在藥鋪立下冬至之約。","keywords":["藥鋪冬至之約","立約等待"]},{"segment_order":3,"title":"不存在","content":"模型捏造的第三段。","keywords":["捏造事件"]}]}
''');

    expect(decoded.recallSegments, hasLength(2));
    expect(decoded.recallSegments.first.content, '第一段：渡口交付青鸞印信。');
    expect(decoded.recallSegments.first.keywords, <String>['渡口交付青鸞印信']);
    expect(decoded.recallSegments.last.keywords, contains('藥鋪冬至之約'));
    expect(decoded.recallSegments.last.keywords, hasLength(1));
  });

  test('RP recall fallback indexes each paragraph with one label', () {
    final segments = ContextCompressor.buildRpRecallSegmentDrafts(
      summary: '### ——主線——\n渡口交付青鸞印信。\n\n藥鋪立下冬至之約。',
    );
    expect(segments, hasLength(2));
    expect(segments.every((segment) => segment.keywords.length == 1), isTrue);
    expect(segments.first.content, '渡口交付青鸞印信。');
    expect(segments.last.content, '藥鋪立下冬至之約。');
  });

  test(
    'RP summary envelope keeps hidden character and relationship payloads',
    () {
      final decoded = ContextCompressor.decodeSummaryEnvelope('''
{"summary":"### ——核心——\\n**[角色] 顧遠登場**","timeline":[],"story_characters":[{"name":"顧遠","source_message_ids":[1],"evidence":"顧遠登場"}],"relationships":[{"from":"清川","to":"顧遠","source_message_ids":[1],"evidence":"讓他暫住"}]}
''');
      expect(decoded.storyCharacters.single['name'], '顧遠');
      expect(decoded.relationships.single['from'], '清川');
    },
  );

  test('RP compact character index fills missing detailed cards', () {
    final decoded = ContextCompressor.decodeSummaryEnvelope('''
{"storyline_id":"story-a","character_index":[{"entity_id":"new","name":"陸箏","source_message_ids":[19],"evidence":"大姐兒陸箏"},{"entity_id":"new","name":"裴昭","source_message_ids":[21],"evidence":"左相裴昭"}],"summary":"### ——主線——\\n家宴","timeline":[],"story_states":[],"story_characters":[{"entity_id":"new","name":"陸箏","identity":"鎮西大將軍","source_message_ids":[19],"evidence":"大姐兒陸箏"}],"relationships":[]}
''');

    expect(decoded.storyCharacters, hasLength(2));
    expect(decoded.storyCharacters.map((item) => item['name']), <String>[
      '陸箏',
      '裴昭',
    ]);
    expect(decoded.storyCharacters.first['identity'], '鎮西大將軍');
  });

  test('RP truncated envelope still preserves summary and character index', () {
    final decoded = ContextCompressor.decodeSummaryEnvelope('''
{"storyline_id":"story-a","character_index":[{"entity_id":"new","name":"裴華","source_message_ids":[99],"evidence":"老三裴華"}],"summary":"### ——主線——\\n江南查案","timeline":[{"broken":
''');

    expect(decoded.storylineId, 'story-a');
    expect(decoded.summary, contains('江南查案'));
    expect(decoded.storyCharacters.single['name'], '裴華');
  });

  testWidgets('mode pill switches and respects reduced motion', (tester) async {
    var mode = ContextMode.daily;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: ContextModePill(
                mode: mode,
                onChanged: (next) => setState(() => mode = next),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('RP'));
    await tester.pump();
    expect(mode, ContextMode.rp);
  });

  testWidgets('history pill keeps all, daily, and RP reachable', (
    tester,
  ) async {
    var filter = 'all';
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: HistoryModePill(
                value: filter,
                backgroundColor: Colors.white,
                onChanged: (next) => setState(() => filter = next),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('RP'));
    await tester.pump();
    expect(filter, 'rp');
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(filter, 'all');
  });

  test('history empty state points to the heartbeat in all locales', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await L.setLocale('zh_TW');
    expect(L.get('history_empty'), '還沒有故事開始\n點擊TA的心跳開始你們的故事');
    await L.setLocale('zh_CN');
    expect(L.get('history_empty'), '还没有故事开始\n点击TA的心跳开始你们的故事');
    await L.setLocale('en');
    expect(
      L.get('history_empty'),
      'No story has begun yet\nTap their heartbeat to begin your story',
    );
  });

  test(
    'global and per-character history choices use independent keys',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ContextModeSettings.setGlobalRpEnabled(true);
      await ContextModeSettings.setHistoryFilter(
        'char-a',
        ConversationHistoryFilter.rp,
      );

      expect(await ContextModeSettings.getGlobalRpEnabled(), isTrue);
      expect(
        await ContextModeSettings.historyFilter('char-a'),
        ConversationHistoryFilter.rp,
      );
      expect(
        await ContextModeSettings.historyFilter('char-b'),
        ConversationHistoryFilter.all,
      );
    },
  );

  group('scoped persistence', () {
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

    test('chat search filters and labels daily/RP windows', () async {
      await db.insert('conversations', _conversation('daily-c', 'daily'));
      await db.insert('conversations', _conversation('rp-c', 'rp'));
      await db.insert('messages', _message('daily-c', 'daily line'));
      await db.insert('messages', _message('rp-c', 'rp line'));

      final daily = await DatabaseHelper.searchMessages(
        keyword: 'line',
        characterId: 'char-a',
        scope: 'daily',
        currentMode: ContextMode.rp,
      );
      final all = await DatabaseHelper.searchMessages(
        keyword: 'line',
        characterId: 'char-a',
        scope: 'all',
        currentMode: ContextMode.rp,
      );

      expect(daily.map((row) => row['context_mode']), ['daily']);
      expect(
        all.map((row) => row['context_mode']),
        containsAll(['rp', 'daily']),
      );
    });

    test('latest-window warning ignores history star ordering', () async {
      await db.insert('conversations', <String, Object?>{
        ..._conversation('old-starred-rp', 'rp'),
        'is_starred': 1,
        'updated_at': '2026-09-12T00:00:00.000Z',
      });
      await db.insert('conversations', <String, Object?>{
        ..._conversation('latest-daily', 'daily'),
        'updated_at': '2026-09-13T00:00:00.000Z',
      });

      expect(
        await ContextModeSettings.latestWindowDiffers(
          'char-a',
          ContextMode.daily,
        ),
        isFalse,
      );
      expect(
        await ContextModeSettings.latestWindowDiffers('char-a', ContextMode.rp),
        isTrue,
      );
    });

    test('RP timeline validates evidence and dedupes independently', () async {
      final source = Message(
        id: 11,
        conversationId: 'rp-c',
        characterId: 'char-a',
        text: '在王城鐘聲響起時，她答應明日赴約。',
        isUser: false,
      );
      final candidate = TimelineEventCandidate(
        type: 'event',
        subject: 'character',
        sourceMessageIds: const <int>[11],
        occurredOn: '王城曆 312 年',
        dateBasis: 'explicit',
        value: '她答應明日赴約',
        evidence: '她答應明日赴約',
      );

      final first = await RpCharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        continuityId: 'main',
        sourceConversationId: 'rp-c',
        candidates: <TimelineEventCandidate>[candidate],
        sourceMessages: <Message>[source],
      );
      final second = await RpCharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        continuityId: 'main',
        sourceConversationId: 'rp-c',
        candidates: <TimelineEventCandidate>[candidate],
        sourceMessages: <Message>[source],
      );
      final otherStory =
          await RpCharacterTimelineService.storeSummaryCandidates(
            characterId: 'char-a',
            continuityId: 'route-b',
            sourceConversationId: 'rp-c',
            candidates: <TimelineEventCandidate>[candidate],
            sourceMessages: <Message>[source],
          );

      expect(first, 1);
      expect(second, 0);
      expect(otherStory, 1);
      expect(
        await RpCharacterTimelineService.getEntries('char-a'),
        hasLength(1),
      );
      final routeB = await RpCharacterTimelineService.getEntries(
        'char-a',
        continuityId: 'route-b',
      );
      expect(routeB, hasLength(1));
      expect(
        await RpCharacterTimelineService.deleteEntry(
          characterId: 'char-a',
          id: routeB.single['id'] as int,
          continuityId: 'route-b',
        ),
        isTrue,
      );
      expect(
        await RpCharacterTimelineService.getEntries('char-a'),
        hasLength(1),
      );
      expect(await db.query('character_timeline'), isEmpty);
    });

    test(
      'RP timeline preserves narrative layers without recalling dreams',
      () async {
        final source = Message(
          id: 12,
          conversationId: 'rp-c',
          characterId: 'char-a',
          text: '她夢見王城失火；醒後想起幼時曾住在王城。',
          isUser: false,
        );
        await RpCharacterTimelineService.storeSummaryCandidates(
          characterId: 'char-a',
          continuityId: 'main',
          sourceConversationId: 'rp-c',
          candidates: const <TimelineEventCandidate>[
            TimelineEventCandidate(
              type: 'event',
              subject: 'character',
              sourceMessageIds: <int>[12],
              occurredOn: '',
              dateBasis: 'unknown',
              value: '王城失火',
              evidence: '夢見王城失火',
              eventKey: 'dream.city_fire',
              narrativeLayer: 'dream',
              subjectEntityIds: <String>['P-0001'],
            ),
            TimelineEventCandidate(
              type: 'event',
              subject: 'character',
              sourceMessageIds: <int>[12],
              occurredOn: '幼時',
              dateBasis: 'relative',
              value: '幼時曾住在王城',
              evidence: '幼時曾住在王城',
              eventKey: 'history.lived_in_city',
              narrativeLayer: 'flashback',
              subjectEntityIds: <String>['P-0001'],
            ),
          ],
          sourceMessages: <Message>[source],
        );

        final visible = await RpCharacterTimelineService.getEntries('char-a');
        expect(visible, hasLength(1));
        expect(visible.single['narrative_layer'], 'memory');
        expect(visible.single['event_key'], 'history.lived_in_city');
        expect(
          jsonDecode(visible.single['subject_entity_ids'] as String),
          <String>['P-0001'],
        );
        expect(
          await RpCharacterTimelineService.getEntries(
            'char-a',
            includeNonCanonical: true,
          ),
          hasLength(2),
        );
        final prompt = await RpCharacterTimelineService.recallPrompt(
          'char-a',
          '王城',
        );
        expect(prompt, contains('幼時曾住在王城'));
        expect(prompt, isNot(contains('王城失火')));
      },
    );

    test(
      'RP story characters and relationship history stay continuity scoped',
      () async {
        final source = Message(
          id: 31,
          conversationId: 'rp-c',
          characterId: 'char-a',
          text: '顧遠帶著青鸞印來到藥鋪，清川因此讓他暫住。',
          isUser: false,
        );
        await RpStoryService.storeExtraction(
          characterId: 'char-a',
          continuityId: 'route-a',
          sourceConversationId: 'rp-c',
          sourceMessages: <Message>[source],
          characters: <Map<String, Object?>>[
            <String, Object?>{
              'name': '顧遠',
              'gender': '男',
              'identity': '嵩臨書院書生',
              'relation_to_leads': '藥鋪暫住客',
              'recurrence': 'recurring',
              'tier': 'active',
              'source_message_ids': <int>[31],
              'evidence': '顧遠帶著青鸞印來到藥鋪',
            },
          ],
          relationships: <Map<String, Object?>>[
            <String, Object?>{
              'from': '清川',
              'to': '顧遠',
              'direction': 'from_to',
              'current_relation': '允許暫住',
              'origin': '顧遠帶來青鸞印',
              'visibility': 'public',
              'change': '清川讓顧遠暫住藥鋪',
              'story_time': '到達首日',
              'source_message_ids': <int>[31],
              'evidence': '清川因此讓他暫住',
            },
          ],
        );

        expect(
          await RpStoryService.listCharacters(
            'char-a',
            continuityId: 'route-a',
          ),
          // A source-validated relationship may mention a participant that the
          // model forgot to repeat in story_characters. The store creates a
          // minimal anchor so the edge remains visible instead of becoming an
          // orphaned relationship.
          hasLength(2),
        );
        expect(
          await RpStoryService.listCharacters(
            'char-a',
            continuityId: 'route-b',
          ),
          isEmpty,
        );
        final relations = await RpStoryService.listRelationships(
          'char-a',
          continuityId: 'route-a',
        );
        expect(relations.single['origin'], '顧遠帶來青鸞印');
        expect(
          await RpStoryService.relationshipEvents(
            relations.single['id'] as String,
          ),
          hasLength(1),
        );

        final later = Message(
          id: 32,
          conversationId: 'rp-c',
          characterId: 'char-a',
          text: '清川與顧遠共同赴約，兩人開始互相信任。',
          isUser: false,
        );
        await RpStoryService.storeExtraction(
          characterId: 'char-a',
          continuityId: 'route-a',
          sourceConversationId: 'rp-c',
          sourceMessages: <Message>[later],
          characters: const <Map<String, Object?>>[],
          relationships: <Map<String, Object?>>[
            <String, Object?>{
              'from': '清川',
              'to': '顧遠',
              'direction': 'from_to',
              'current_relation': '開始互相信任',
              'origin': '後來共同赴約',
              'visibility': 'public',
              'change': '兩人開始互相信任',
              'story_time': '赴約當日',
              'source_message_ids': <int>[32],
              'evidence': '兩人開始互相信任',
            },
          ],
        );
        final updatedRelations = await RpStoryService.listRelationships(
          'char-a',
          continuityId: 'route-a',
        );
        expect(updatedRelations.single['origin'], '顧遠帶來青鸞印');
        expect(updatedRelations.single['current_relation'], '開始互相信任');
        expect(
          await RpStoryService.relationshipEvents(
            updatedRelations.single['id'] as String,
          ),
          hasLength(2),
        );

        await RpStoryService.updateRelationship(
          updatedRelations.single['id'] as String,
          currentRelation: '開始互相信任',
          origin: '顧遠帶來青鸞印',
          visibility: 'public',
        );
        expect(
          (await RpStoryService.listRelationships(
            'char-a',
            continuityId: 'route-a',
          )).single['user_edited'],
          0,
        );

        await RpStoryService.updateRelationship(
          updatedRelations.single['id'] as String,
          currentRelation: '使用者確認的互信同伴',
          origin: '顧遠帶來青鸞印',
          visibility: 'public',
        );
        final newest = Message(
          id: 33,
          conversationId: 'rp-c',
          characterId: 'char-a',
          text: '清川與顧遠交換信物，約定共同守住藥鋪。',
          isUser: false,
        );
        await RpStoryService.storeExtraction(
          characterId: 'char-a',
          continuityId: 'route-a',
          sourceConversationId: 'rp-c',
          sourceMessages: <Message>[newest],
          characters: const <Map<String, Object?>>[],
          relationships: <Map<String, Object?>>[
            <String, Object?>{
              'from': '清川',
              'to': '顧遠',
              'direction': 'from_to',
              'current_relation': '交換信物的守護同盟',
              'origin': '後來交換信物',
              'visibility': 'public',
              'change': '兩人交換信物並約定共同守住藥鋪',
              'story_time': '交換信物當日',
              'source_message_ids': <int>[33],
              'evidence': '清川與顧遠交換信物',
            },
          ],
        );
        final protectedRelations = await RpStoryService.listRelationships(
          'char-a',
          continuityId: 'route-a',
        );
        expect(protectedRelations.single['current_relation'], '使用者確認的互信同伴');
        expect(protectedRelations.single['latest_change'], '兩人交換信物並約定共同守住藥鋪');
        expect(protectedRelations.single['source_message_ids'], '[33]');
      },
    );

    test('RP story recall can rank sqflite query results', () async {
      final source = Message(
        id: 41,
        conversationId: 'rp-c',
        characterId: 'char-a',
        text: '顧遠與韓衡同時來到藥鋪。',
        isUser: false,
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'main',
        sourceConversationId: 'rp-c',
        sourceMessages: <Message>[source],
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'name': '顧遠',
            'identity': '書生',
            'tier': 'active',
            'source_message_ids': <int>[41],
            'evidence': '顧遠',
          },
          <String, Object?>{
            'name': '韓衡',
            'identity': '少卿',
            'tier': 'active',
            'source_message_ids': <int>[41],
            'evidence': '韓衡',
          },
        ],
        relationships: const <Map<String, Object?>>[],
      );

      final prompt = await RpStoryService.recallPrompt('char-a', '韓衡走進藥鋪');
      expect(prompt, contains('韓衡'));
      expect(prompt, contains('顧遠'));
    });

    test(
      'RP summary archive context includes participating profiles and recalled lore',
      () async {
        const now = '2026-10-04T00:00:00.000Z';
        await db.insert('characters', <String, Object?>{
          'id': 'char-a',
          'name': '顧遠',
          'gender': '男',
          'relationship': '同門',
          'description': '沉穩寡言，隨身帶著青鸞印。',
          'created_at': now,
          'updated_at': now,
        });
        await db.insert('conversations', <String, Object?>{
          ..._conversation('rp-profile-c', 'rp'),
          'user_persona_id': 'persona-a',
          'user_persona_snapshot': jsonEncode(<String, Object?>{
            'version': 2,
            'id': 'persona-a',
            'display_name': '清川',
            'pronouns': '他',
            'bio': '許家藥鋪主人',
            'prompt_content': '熟悉藥理。',
          }),
        });
        await db.insert('rp_worldbook_entries', <String, Object?>{
          'id': 'world-a',
          'entry_key': 'WB-0001',
          'character_id': 'char-a',
          'continuity_id': 'main',
          'name': '雪嶺青',
          'category': 'species',
          'content': '只生長於嵩臨山背面崖壁。',
          'scope': '嵩臨山',
          'visibility': '採藥人知情',
          'status': 'active',
          'ended_reason': '',
          'triggers_json': '["雪嶺青"]',
          'source_summary_ids': '[]',
          'user_edited': 1,
          'created_at': now,
          'updated_at': now,
        });
        for (final person in const <Map<String, Object?>>[
          <String, Object?>{
            'id': 'person-involved',
            'entity_key': 'P-0001',
            'normalized_name': '顧遠',
            'name': '顧遠',
            'tier': 'active',
          },
          <String, Object?>{
            'id': 'person-unrelated',
            'entity_key': 'P-0002',
            'normalized_name': '韓衡',
            'name': '韓衡',
            'tier': 'backstage',
          },
        ]) {
          await db.insert('rp_story_characters', <String, Object?>{
            ...person,
            'character_id': 'char-a',
            'continuity_id': 'main',
            'last_seen_at': now,
            'created_at': now,
            'updated_at': now,
          });
        }
        for (final state in const <Map<String, Object?>>[
          <String, Object?>{
            'id': 'state-related',
            'state_key': 'body.P-0001.shoulder',
            'state_type': 'body',
            'subject_entity_key': 'P-0001',
            'value': '左肩箭傷恢復中',
            'status': 'recovering',
            'evidence': '不應注入的逐字證據',
          },
          <String, Object?>{
            'id': 'state-unrelated',
            'state_key': 'body.P-0002.fever',
            'state_type': 'body',
            'subject_entity_key': 'P-0002',
            'value': '無關人物的高熱',
            'status': 'recovering',
          },
          <String, Object?>{
            'id': 'state-dream',
            'state_key': 'body.P-0001.dream_wound',
            'state_type': 'body',
            'subject_entity_key': 'P-0001',
            'narrative_layer': 'dream',
            'value': '夢中傷勢',
            'status': 'recovering',
          },
        ]) {
          await db.insert('rp_story_states', <String, Object?>{
            ...state,
            'character_id': 'char-a',
            'continuity_id': 'main',
            'narrative_layer': state['narrative_layer'] ?? 'main',
            'created_at': now,
            'updated_at': now,
          });
        }

        final context = await ContextCompressor.buildRpArchiveContext(
          characterId: 'char-a',
          continuityId: 'main',
          conversationId: 'rp-profile-c',
          sourceText: '清川問顧遠是否找到雪嶺青。',
        );

        expect(context, contains('【本輪參與劇情的具體人設】'));
        expect(context, contains('沉穩寡言'));
        expect(context, contains('熟悉藥理'));
        expect(context, contains('【本輪關鍵詞召回的世界書】'));
        expect(context, contains('只生長於嵩臨山背面崖壁'));
        expect(context, contains('左肩箭傷恢復中'));
        expect(context, isNot(contains('無關人物的高熱')));
        expect(context, isNot(contains('夢中傷勢')));
        expect(context, isNot(contains('不應注入的逐字證據')));
      },
    );

    test(
      'RP story recall keeps relationships during pronoun-only turns',
      () async {
        final source = Message(
          id: 42,
          conversationId: 'rp-c',
          characterId: 'char-a',
          text: '顧遠與韓衡因青鸞印結盟，開始彼此信任。',
          isUser: false,
        );
        await RpStoryService.storeExtraction(
          characterId: 'char-a',
          continuityId: 'main',
          sourceConversationId: 'rp-c',
          sourceMessages: <Message>[source],
          characters: <Map<String, Object?>>[
            <String, Object?>{
              'name': '顧遠',
              'identity': '書生',
              'tier': 'active',
              'source_message_ids': <int>[42],
              'evidence': '顧遠',
            },
            <String, Object?>{
              'name': '韓衡',
              'identity': '少卿',
              'tier': 'active',
              'source_message_ids': <int>[42],
              'evidence': '韓衡',
            },
          ],
          relationships: <Map<String, Object?>>[
            <String, Object?>{
              'from': '顧遠',
              'to': '韓衡',
              'direction': 'mutual',
              'current_relation': '盟友',
              'origin': '因青鸞印結盟',
              'closeness_catalyst': '共同守住青鸞印',
              'source_message_ids': <int>[42],
              'evidence': '因青鸞印結盟',
            },
          ],
        );

        final prompt = await RpStoryService.recallPrompt(
          'char-a',
          '他沒有鬆開對方的手。',
        );
        expect(prompt, contains('顧遠 → 韓衡'));
        expect(prompt, contains('因青鸞印結盟'));
      },
    );

    test(
      'RP timeline keeps discrete events and rejects legacy state candidates',
      () async {
        final source = <Message>[
          Message(
            id: 21,
            conversationId: 'rp-c',
            characterId: 'char-a',
            text: '她仍然保管著王城的信物。',
            isUser: false,
          ),
          Message(
            id: 22,
            conversationId: 'rp-c',
            characterId: 'char-a',
            text: '兩人約定在鐘樓見面。',
            isUser: false,
          ),
        ];
        await RpCharacterTimelineService.storeSummaryCandidates(
          characterId: 'char-a',
          continuityId: 'main',
          sourceConversationId: 'rp-c',
          candidates: const <TimelineEventCandidate>[
            TimelineEventCandidate(
              type: 'state',
              subject: 'character',
              sourceMessageIds: [21],
              occurredOn: '王城曆 312 年',
              dateBasis: 'explicit',
              key: 'important item',
              value: '她仍然保管著王城的信物',
              evidence: '她仍然保管著王城的信物',
            ),
            TimelineEventCandidate(
              type: 'event',
              subject: 'relationship',
              sourceMessageIds: [22],
              occurredOn: '王城曆 312 年',
              dateBasis: 'explicit',
              value: '兩人約定在鐘樓見面',
              evidence: '兩人約定在鐘樓見面',
            ),
          ],
          sourceMessages: source,
        );

        final prompt = await RpCharacterTimelineService.recallPrompt(
          'char-a',
          '她走進了王城',
        );
        expect(prompt, isNot(contains('她仍然保管著王城的信物')));
        expect(prompt, contains('兩人約定在鐘樓見面'));
        final rows = await RpCharacterTimelineService.getEntries('char-a');
        expect(rows, hasLength(1));
        expect(rows.single['type'], 'event');
      },
    );

    test(
      'RP memory ranks story-relevant entries before unrelated core entries',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'memory_send_limit_v1': 5,
          'mem_budget_total': 2000,
          'mem_budget_v2_migrated': true,
        });
        final relevantMemoryId = await DatabaseHelper.insertMemory(
          Memory(
            characterId: 'char-a',
            contextMode: ContextMode.rp,
            continuityId: 'main',
            mode: 'romance',
            category: '伏筆',
            narrativeWeight: 'branch',
            content: '王城的信物會在鐘樓約定中再次出現。',
            triggers: '王城,信物',
          ),
        );
        await DatabaseHelper.insertMemory(
          Memory(
            characterId: 'char-a',
            contextMode: ContextMode.rp,
            continuityId: 'main',
            mode: 'romance',
            category: '世界觀',
            narrativeWeight: 'core',
            content: '北境的古老王朝有七座城門。',
          ),
        );

        Retriever.resetWindowIds('rp-memory-window');
        final prompt = await Retriever.buildMemoryPrompt(
          mode: 'romance',
          currentMessage: '她回到王城，摸了摸信物',
          characterId: 'char-a',
          windowId: 'rp-memory-window',
          contextMode: ContextMode.rp,
          continuityId: 'main',
        );
        expect(
          prompt.text.indexOf('王城的信物會在鐘樓約定中再次出現'),
          lessThan(prompt.text.indexOf('北境的古老王朝有七座城門')),
        );
        expect(
          (await db.query(
            'memories',
            columns: const <String>['mention_count'],
            where: 'id = ?',
            whereArgs: <Object?>[relevantMemoryId],
          )).single['mention_count'],
          0,
        );
        await prompt.commit();
        expect(
          (await db.query(
            'memories',
            columns: const <String>['mention_count'],
            where: 'id = ?',
            whereArgs: <Object?>[relevantMemoryId],
          )).single['mention_count'],
          1,
        );
      },
    );

    test(
      'RP timeline reads the newest 200 entries in a long continuity',
      () async {
        final batch = db.batch();
        for (var index = 1; index <= 205; index++) {
          batch.insert('rp_character_timeline', <String, Object?>{
            'character_id': 'char-a',
            'continuity_id': 'main',
            'type': 'event',
            'value': '劇情事件 $index',
            'sequence_order': index,
          });
        }
        await batch.commit(noResult: true);

        final prompt = await RpCharacterTimelineService.recallPrompt(
          'char-a',
          '回想劇情事件 205',
        );
        expect(prompt, contains('劇情事件 205'));
        expect(prompt, isNot(contains('劇情事件 1\n')));
      },
    );

    test(
      'RP strips daily life-fix tags without changing daily state',
      () async {
        await CharacterTimelineService.upsertState('char-a', '住所', '日常住處');
        final visible = CharacterTimelineService.stripLifeFix(
          '繼續劇情<life_fix>住所|RP 城堡</life_fix>',
        );
        expect(visible, '繼續劇情');
        final states = await CharacterTimelineService.getStates('char-a');
        expect(states.single['value'], '日常住處');
      },
    );

    test(
      'older RP summaries cannot roll a newer story state backwards',
      () async {
        final newer = Message(
          id: 32,
          conversationId: 'newer-rp',
          characterId: 'char-a',
          text: '一行人目前已抵達王城。',
          isUser: false,
        );
        final older = Message(
          id: 31,
          conversationId: 'older-rp',
          characterId: 'char-a',
          text: '一行人仍停留在北境。',
          isUser: false,
        );
        expect(
          await RpStoryStateService.storeExtraction(
            characterId: 'char-a',
            continuityId: 'main',
            sourceConversationId: 'newer-rp',
            states: const <Map<String, Object?>>[
              <String, Object?>{
                'state_key': 'scene.current',
                'state_type': 'scene',
                'narrative_layer': 'mainline',
                'value': '一行人目前已抵達王城',
                'status': '',
                'source_message_ids': <int>[32],
                'evidence': '一行人目前已抵達王城',
              },
            ],
            sourceMessages: <Message>[newer],
          ),
          1,
        );
        expect(
          await RpStoryStateService.storeExtraction(
            characterId: 'char-a',
            continuityId: 'main',
            sourceConversationId: 'older-rp',
            states: const <Map<String, Object?>>[
              <String, Object?>{
                'state_key': 'scene.current',
                'state_type': 'scene',
                'narrative_layer': 'mainline',
                'value': '一行人仍停留在北境',
                'status': '',
                'source_message_ids': <int>[31],
                'evidence': '一行人仍停留在北境',
              },
            ],
            sourceMessages: <Message>[older],
          ),
          0,
        );
        final entries = await RpStoryStateService.listStates(
          'char-a',
          continuityId: 'main',
        );
        expect(entries.single['value'], '一行人目前已抵達王城');
      },
    );
  });
}

Map<String, Object?> _conversation(String id, String mode) => <String, Object?>{
  'id': id,
  'character_id': 'char-a',
  'context_mode': mode,
  'continuity_id': 'main',
  'created_at': '2026-09-13T00:00:00.000Z',
  'updated_at': '2026-09-13T00:00:00.000Z',
};

Map<String, Object?> _message(String conversationId, String text) =>
    <String, Object?>{
      'conversation_id': conversationId,
      'character_id': 'char-a',
      'text': text,
      'is_user': 1,
      'created_at': '2026-09-13T00:00:00.000Z',
    };
