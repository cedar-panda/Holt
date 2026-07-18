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
            sourceMessageIds: [41],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            value: '兩人吵架',
            evidence: '現在不要跟我吵架',
          ),
          TimelineEventCandidate(
            sourceMessageIds: [41],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            value: '兩人吵架',
            evidence: '我們剛剛做愛了',
          ),
          TimelineEventCandidate(
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
              sourceMessageIds: [52],
              occurredOn: '2026-07-18',
              dateBasis: 'relative',
              value: '兩人旅行歸來',
              evidence: '今天我們旅行回來了',
            ),
            TimelineEventCandidate(
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
            sourceMessageIds: [61],
            occurredOn: '2026-07-17',
            dateBasis: 'relative',
            value: '兩人一起看電影',
            evidence: '昨天我們一起看了電影',
          ),
          TimelineEventCandidate(
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

  test('ISO week group uses the week-year at New Year boundaries', () {
    expect(isoWeekGroup(DateTime(2025, 12, 29)), '2026-W01');
    expect(isoWeekGroup(DateTime(2021, 1, 1)), '2020-W53');
    expect(isoWeekGroup(DateTime(2026, 7, 18)), '2026-W29');
  });
}
