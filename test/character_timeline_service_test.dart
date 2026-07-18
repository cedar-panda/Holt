import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
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

  test('historical, future, and negated mentions are not new events', () async {
    final now = DateTime(2026, 7, 18, 20, 30);

    expect(
      await CharacterTimelineService.scanReply(
        'char-a',
        '我還記得上次跟你看電影。明天要不要去約會？今天其實沒去吃飯。',
        now: now,
      ),
      0,
    );
    expect(await CharacterTimelineService.getEvents('char-a'), isEmpty);

    expect(
      await CharacterTimelineService.scanReply(
        'char-a',
        '我記得上次看電影，今天真的去約會了。',
        now: now,
      ),
      1,
    );
    expect(
      (await CharacterTimelineService.getEvents('char-a')).single['value'],
      '約會',
    );
  });

  test(
    'relative event date is preserved and same-day repeats are idempotent',
    () async {
      final now = DateTime(2026, 7, 18, 20, 30);
      const reply = '昨天跟你看電影，回家後還一直想著。';

      expect(
        await CharacterTimelineService.scanReply('char-a', reply, now: now),
        1,
      );
      expect(
        await CharacterTimelineService.scanReply('char-a', reply, now: now),
        0,
      );

      final events = await CharacterTimelineService.getEvents('char-a');
      expect(events, hasLength(1));
      expect(events.single['created_at'].toString(), startsWith('2026-07-17'));
      expect(events.single['value'], '看電影');
    },
  );

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

  test('ISO week group uses the week-year at New Year boundaries', () {
    expect(isoWeekGroup(DateTime(2025, 12, 29)), '2026-W01');
    expect(isoWeekGroup(DateTime(2021, 1, 1)), '2020-W53');
    expect(isoWeekGroup(DateTime(2026, 7, 18)), '2026-W29');
  });
}
