import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/character_timeline_service.dart';
import 'package:project_yanci/utils/iso_week.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.createSchemaForTesting(db);
    DatabaseHelper.useDatabaseForTesting(db);
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'event month query does not depend on a global latest-row limit',
    () async {
      await CharacterTimelineService.addEvent(
        'char-a',
        '旅行',
        occurredAt: DateTime(2026, 5, 3, 12),
      );
      await CharacterTimelineService.addEvent(
        'char-a',
        '約會',
        occurredAt: DateTime(2026, 7, 3, 12),
      );

      final may = await CharacterTimelineService.getEvents(
        'char-a',
        from: DateTime(2026, 5),
        until: DateTime(2026, 6),
        limit: 200,
      );
      expect(may.map((event) => event['value']), <Object?>['旅行']);
    },
  );

  test(
    'summary candidates require source evidence and completed semantics',
    () async {
      final messages = <Message>[
        Message(
          id: 41,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '現在不要跟我吵架。我們剛剛做愛了。昨天我們一起看了電影。',
          isUser: false,
          createdAt: DateTime(2026, 7, 18, 20, 30),
        ),
      ];

      final inserted = await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: messages,
        candidates: const [
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [41],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            value: '兩人吵架',
            evidence: '現在不要跟我吵架',
          ),
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [41],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            value: '兩人吵架',
            evidence: '我們剛剛做愛了',
          ),
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [41],
            occurredOn: '2026-07-17',
            dateBasis: 'relative',
            value: '兩人一起看電影',
            evidence: '昨天我們一起看了電影',
          ),
        ],
      );

      expect(inserted, 1);
      final events = await CharacterTimelineService.getEvents('char-a');
      expect(events, hasLength(1));
      expect(events.single['value'], '兩人一起看電影');
      expect(events.single['created_at'].toString(), startsWith('2026-07-17'));
      expect(jsonDecode(events.single['source_message_ids'] as String), [41]);
      expect(events.single['source_evidence'], '昨天我們一起看了電影');
    },
  );

  test(
    'older discovered events are returned left-to-right chronologically',
    () async {
      final messages = <Message>[
        Message(
          id: 51,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '7月12日我們正式和好了。',
          isUser: true,
          createdAt: DateTime(2026, 7, 18, 9),
        ),
        Message(
          id: 52,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '今天我們旅行回來了。',
          isUser: false,
          createdAt: DateTime(2026, 7, 18, 20),
        ),
      ];

      expect(
        await CharacterTimelineService.storeSummaryCandidates(
          characterId: 'char-a',
          sourceMessages: messages,
          candidates: const [
            TimelineEventCandidate(
              type: 'event',
              subject: 'relationship',
              sourceMessageIds: [52],
              occurredOn: '2026-07-18',
              dateBasis: 'relative',
              value: '兩人旅行歸來',
              evidence: '今天我們旅行回來了',
            ),
            TimelineEventCandidate(
              type: 'event',
              subject: 'relationship',
              sourceMessageIds: [51],
              occurredOn: '2026-07-12',
              dateBasis: 'explicit',
              value: '兩人正式和好',
              evidence: '7月12日我們正式和好了',
            ),
          ],
        ),
        2,
      );

      final events = await CharacterTimelineService.getEvents(
        'char-a',
        ascending: true,
        limit: 20,
      );
      expect(events.map((event) => event['value']), ['兩人正式和好', '兩人旅行歸來']);
    },
  );

  test(
    'same-day summary candidates merge provenance instead of duplicating',
    () async {
      final messages = <Message>[
        Message(
          id: 61,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '昨天我們一起看了電影。',
          isUser: true,
          createdAt: DateTime(2026, 7, 18, 10),
        ),
        Message(
          id: 62,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '昨天一起看電影真的很開心。',
          isUser: false,
          createdAt: DateTime(2026, 7, 18, 10, 1),
        ),
      ];

      final inserted = await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: messages,
        candidates: const [
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [61],
            occurredOn: '2026-07-17',
            dateBasis: 'relative',
            value: '兩人一起看電影',
            evidence: '昨天我們一起看了電影',
          ),
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [62],
            occurredOn: '2026-07-17',
            dateBasis: 'relative',
            value: '一起看電影',
            evidence: '昨天一起看電影真的很開心',
          ),
        ],
      );

      expect(inserted, 1);
      final events = await CharacterTimelineService.getEvents('char-a');
      expect(events, hasLength(1));
      expect(jsonDecode(events.single['source_message_ids'] as String), [
        61,
        62,
      ]);
    },
  );

  test(
    'period day derives character state and start while nickname is rejected',
    () async {
      final messages = <Message>[
        Message(
          id: 71,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '晏辭，你昨天是生理期第二天。我稱呼晏辭為大小姐。',
          isUser: true,
          createdAt: DateTime(2026, 7, 18, 20, 30),
        ),
      ];

      final changed = await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: messages,
        candidates: const [
          TimelineEventCandidate(
            type: 'state',
            subject: 'character',
            sourceMessageIds: [71],
            // Intentionally wrong model date/basis: local evidence parsing must
            // still resolve 「昨天」 before deriving the cycle start.
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            key: '生理週期',
            value: '晏辭處於生理期第二天',
            evidence: '你昨天是生理期第二天',
          ),
          TimelineEventCandidate(
            type: 'event',
            subject: 'relationship',
            sourceMessageIds: [71],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            value: '昭昭稱呼晏辭為大小姐',
            evidence: '我稱呼晏辭為大小姐',
          ),
        ],
      );

      expect(changed, 2);
      final states = await CharacterTimelineService.getStates('char-a');
      expect(states, hasLength(1));
      expect(states.single['key'], '生理週期');
      expect(states.single['value'], '生理期第3天（推算；開始於2026-07-16）');
      expect(states.single['created_at'].toString(), startsWith('2026-07-16'));
      expect(states.single['updated_at'].toString(), startsWith('2026-07-18'));
      final snapshot = await CharacterTimelineService.stateSnapshotPrompt(
        'char-a',
        now: DateTime(2026, 7, 18, 23),
      );
      expect(snapshot, contains('生理期第3天（推算；開始於2026-07-16）'));

      final events = await CharacterTimelineService.getEvents('char-a');
      expect(events, hasLength(1));
      expect(events.single['value'], '生理期開始（推算）');
      expect(events.single['created_at'].toString(), startsWith('2026-07-16'));
      expect(jsonDecode(events.single['source_message_ids'] as String), [71]);
    },
  );

  test(
    'current period evidence survives a wrong relationship subject',
    () async {
      final messages = <Message>[
        Message(
          id: 72,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '你今天還是生理期，先好好休息。',
          isUser: true,
          createdAt: DateTime(2026, 7, 18, 21, 15),
        ),
      ];

      final changed = await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: messages,
        candidates: const [
          TimelineEventCandidate(
            type: 'state',
            subject: 'relationship',
            sourceMessageIds: [72],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            key: '生理週期',
            value: '晏辭仍在生理期',
            evidence: '你今天還是生理期',
          ),
        ],
      );

      expect(changed, 1);
      final states = await CharacterTimelineService.getStates('char-a');
      expect(states, hasLength(1));
      expect(states.single['key'], '生理週期');
      expect(states.single['value'], '生理期中（紀錄於2026-07-18）');
      expect(await CharacterTimelineService.getEvents('char-a'), isEmpty);
    },
  );

  test('a period question is never stored as a current state', () async {
    final changed = await CharacterTimelineService.storeSummaryCandidates(
      characterId: 'char-a',
      sourceMessages: [
        Message(
          id: 73,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '你今天還是生理期嗎？',
          isUser: true,
          createdAt: DateTime(2026, 7, 18, 21, 20),
        ),
      ],
      candidates: const [
        TimelineEventCandidate(
          type: 'state',
          subject: 'character',
          sourceMessageIds: [73],
          occurredOn: '2026-07-18',
          dateBasis: 'message_time',
          key: '生理週期',
          value: '晏辭仍在生理期',
          // 模型即使漏引問號，本地仍會檢查完整來源消息。
          evidence: '你今天還是生理期',
        ),
      ],
    );

    expect(changed, 0);
    expect(await CharacterTimelineService.getStates('char-a'), isEmpty);
  });

  test(
    'an older window cannot roll a newer character state backwards',
    () async {
      final newer = Message(
        id: 81,
        conversationId: 'conv-new',
        characterId: 'char-a',
        text: '你今天感冒了。',
        isUser: true,
        createdAt: DateTime(2026, 7, 18, 20),
      );
      final older = Message(
        id: 82,
        conversationId: 'conv-old',
        characterId: 'char-a',
        text: '你昨天還很健康。',
        isUser: true,
        createdAt: DateTime(2026, 7, 18, 10),
      );

      expect(
        await CharacterTimelineService.storeSummaryCandidates(
          characterId: 'char-a',
          sourceMessages: [newer],
          candidates: const [
            TimelineEventCandidate(
              type: 'state',
              subject: 'character',
              sourceMessageIds: [81],
              occurredOn: '2026-07-18',
              dateBasis: 'relative',
              key: '健康',
              value: '晏辭感冒',
              evidence: '你今天感冒了',
            ),
          ],
        ),
        1,
      );
      expect(
        await CharacterTimelineService.storeSummaryCandidates(
          characterId: 'char-a',
          sourceMessages: [older],
          candidates: const [
            TimelineEventCandidate(
              type: 'state',
              subject: 'character',
              sourceMessageIds: [82],
              occurredOn: '2026-07-17',
              dateBasis: 'relative',
              key: '健康',
              value: '晏辭健康正常',
              evidence: '你昨天還很健康',
            ),
          ],
        ),
        0,
      );

      final states = await CharacterTimelineService.getStates('char-a');
      expect(states.single['value'], '晏辭感冒');
      expect(states.single['source_message_id'], 81);
    },
  );

  test('period end clears the live state and creates a dated event', () async {
    final activeMessage = Message(
      id: 91,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '你今天是生理期第三天。',
      isUser: true,
      createdAt: DateTime(2026, 7, 20, 20),
    );
    expect(
      await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: [activeMessage],
        candidates: const [
          TimelineEventCandidate(
            type: 'state',
            subject: 'character',
            sourceMessageIds: [91],
            occurredOn: '2026-07-20',
            dateBasis: 'relative',
            key: '生理週期',
            value: '晏辭處於生理期第三天',
            evidence: '你今天是生理期第三天',
          ),
        ],
      ),
      2,
    );
    expect(await CharacterTimelineService.getStates('char-a'), hasLength(1));

    final endedMessage = Message(
      id: 92,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '晏辭說，生理期已於昨天（2026-07-22）結束。',
      isUser: false,
      createdAt: DateTime(2026, 7, 23, 18, 50),
    );
    expect(
      await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: [endedMessage],
        candidates: const [
          TimelineEventCandidate(
            type: 'event',
            subject: 'character',
            sourceMessageIds: [92],
            occurredOn: '2026-07-22',
            dateBasis: 'explicit',
            value: '生理期結束',
            evidence: '生理期已於昨天（2026-07-22）結束',
          ),
        ],
      ),
      2,
    );

    expect(await CharacterTimelineService.getStates('char-a'), isEmpty);
    final events = await CharacterTimelineService.getEvents(
      'char-a',
      ascending: true,
    );
    expect(events.map((event) => event['value']), ['生理期開始（推算）', '生理期結束']);
    expect(events.last['created_at'].toString(), startsWith('2026-07-22'));
    expect(jsonDecode(events.last['source_message_ids'] as String), [92]);
  });

  test('period end questions and ongoing statements are not stored', () async {
    final messages = [
      Message(
        id: 93,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '生理期還沒結束。',
        isUser: false,
        createdAt: DateTime(2026, 7, 23, 19),
      ),
      Message(
        id: 94,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '生理期結束了嗎？',
        isUser: true,
        createdAt: DateTime(2026, 7, 23, 19, 1),
      ),
    ];

    expect(
      await CharacterTimelineService.storeSummaryCandidates(
        characterId: 'char-a',
        sourceMessages: messages,
        candidates: const [
          TimelineEventCandidate(
            type: 'event',
            subject: 'character',
            sourceMessageIds: [93],
            occurredOn: '2026-07-23',
            dateBasis: 'message_time',
            value: '生理期結束',
            evidence: '生理期還沒結束',
          ),
          TimelineEventCandidate(
            type: 'event',
            subject: 'character',
            sourceMessageIds: [94],
            occurredOn: '2026-07-23',
            dateBasis: 'message_time',
            value: '生理期結束',
            evidence: '生理期結束了嗎？',
          ),
        ],
      ),
      0,
    );
    expect(await CharacterTimelineService.getEvents('char-a'), isEmpty);
  });

  test('ISO week group uses the week-year at New Year boundaries', () {
    expect(isoWeekGroup(DateTime(2025, 12, 29)), '2026-W01');
    expect(isoWeekGroup(DateTime(2021, 1, 1)), '2020-W53');
    expect(isoWeekGroup(DateTime(2026, 7, 18)), '2026-W29');
  });
}
