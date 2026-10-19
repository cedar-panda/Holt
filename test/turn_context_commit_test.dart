import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/retriever.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/bio_clock_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object>{
      'id': 'char-a',
      'name': 'A',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    Retriever.releaseWindowIds('window-a');
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('bio-clock cooldown is committed only after prompt delivery', () async {
    final now = DateTime.now();
    await BioClockService.addHabit(
      'char-a',
      hour: now.hour,
      minute: now.minute,
      content: '吃飯',
      keywords: const <String>['吃飯'],
    );

    final draft = await BioClockService.triggerPrompt('char-a');
    expect(draft.isNotEmpty, isTrue);
    expect((await _bioMeta(db, 'char-a'))['last_inject_at'], isNull);

    final retryBeforeDelivery = await BioClockService.triggerPrompt('char-a');
    expect(retryBeforeDelivery.isNotEmpty, isTrue);

    await draft.commit();
    expect((await _bioMeta(db, 'char-a'))['last_inject_at'], isNotNull);
    expect((await BioClockService.triggerPrompt('char-a')).isNotEmpty, isFalse);
  });

  test(
    'current habit reminder outranks unresolved duplicate cleanup',
    () async {
      final now = DateTime.now();
      await BioClockService.addHabit(
        'char-a',
        hour: now.hour,
        minute: now.minute,
        content: '吃晚餐',
        keywords: const <String>['吃飯'],
      );
      await BioClockService.addHabit(
        'char-a',
        hour: now.hour,
        minute: now.minute,
        content: '晚餐時間',
        keywords: const <String>['吃飯'],
      );

      final draft = await BioClockService.turnPrompt('char-a');
      expect(draft.text, contains('生物鐘提醒'));
      expect(draft.text, isNot(contains('生物鐘整理')));
    },
  );

  test(
    'duplicate cleanup cooldown starts only after successful delivery',
    () async {
      await BioClockService.addHabit(
        'char-a',
        hour: 3,
        minute: 10,
        content: '早睡',
        keywords: const <String>['睡眠'],
      );
      await BioClockService.addHabit(
        'char-a',
        hour: 3,
        minute: 20,
        content: '準備睡覺',
        keywords: const <String>['睡眠'],
      );

      final draft = await BioClockService.dedupPrompt('char-a');
      expect(draft.text, contains('生物鐘整理'));
      expect((await _bioMeta(db, 'char-a'))['last_dedup_prompt_at'], isNull);

      final retryBeforeDelivery = await BioClockService.dedupPrompt('char-a');
      expect(retryBeforeDelivery.isNotEmpty, isTrue);

      await draft.commit();
      expect((await _bioMeta(db, 'char-a'))['last_dedup_prompt_at'], isNotNull);
      expect((await BioClockService.dedupPrompt('char-a')).isNotEmpty, isFalse);
    },
  );

  test('clock update and delete use durable habit ids after gaps', () async {
    for (final entry in const <(int, String, String)>[
      (7, '早餐', '早餐'),
      (12, '午餐', '午餐'),
      (18, '晚餐', '晚餐'),
    ]) {
      await BioClockService.addHabit(
        'char-a',
        hour: entry.$1,
        minute: 0,
        content: entry.$2,
        keywords: <String>[entry.$3],
      );
    }

    await BioClockService.processReply(
      '<clock_del>①</clock_del>',
      characterId: 'char-a',
    );
    await BioClockService.processReply(
      '<clock_update>③|19:30 晚點吃晚餐 @晚餐</clock_update>',
      characterId: 'char-a',
    );

    final habits = await _bioHabits(db, 'char-a');
    expect(habits.map((habit) => habit['id']), <Object?>[2, 3]);
    expect(habits[0]['content'], '午餐');
    expect(habits[1]['content'], '晚點吃晚餐');
    expect(habits[1]['hour'], 19);
    expect(habits[1]['minute'], 30);
  });

  test(
    'bio-clock setup retries until delivery and then rests for that slot',
    () async {
      final lunch = DateTime(2026, 8, 1, 12);
      final draft = await BioClockService.setupPrompt('char-a', at: lunch);
      expect(draft.isNotEmpty, isTrue);
      expect(draft.text, contains('飯點'));
      expect(await _bioSetupKeys(db, 'char-a'), isEmpty);

      final retry = await BioClockService.setupPrompt('char-a', at: lunch);
      expect(retry.isNotEmpty, isTrue);

      await draft.commit();
      expect(await _bioSetupKeys(db, 'char-a'), contains('2026-08-01:lunch'));
      expect(
        (await BioClockService.setupPrompt('char-a', at: lunch)).isNotEmpty,
        isFalse,
      );

      final dinner = await BioClockService.setupPrompt(
        'char-a',
        at: DateTime(2026, 8, 1, 18),
      );
      expect(dinner.isNotEmpty, isTrue);
      expect(dinner.text, contains('晚餐'));
    },
  );

  test('a new habit is not calibrated immediately', () async {
    final now = DateTime.now();
    await BioClockService.addHabit(
      'char-a',
      hour: (now.hour + 8) % 24,
      minute: now.minute,
      content: '晚點再吃飯',
      keywords: const <String>['吃飯'],
    );

    expect(
      (await BioClockService.calibratePrompt('char-a')).isNotEmpty,
      isFalse,
    );
  });

  test('memory hit count changes only after prompt delivery', () async {
    final id = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '測試內容',
        confidence: 'high',
        triggers: '測試關鍵詞',
      ),
    );

    final draft = await Retriever.buildMemoryPrompt(
      currentMessage: '提到測試關鍵詞',
      characterId: 'char-a',
      windowId: 'window-a',
    );
    expect(draft.isNotEmpty, isTrue);
    expect(await _mentionCount(db, id), 0);

    await draft.commit();
    expect(await _mentionCount(db, id), 1);
    await draft.commit();
    expect(await _mentionCount(db, id), 1);
  });

  test('memory prompt is empty when no memory is recalled', () async {
    final draft = await Retriever.buildMemoryPrompt(
      currentMessage: '全新的話題',
      characterId: 'char-without-memory',
      windowId: 'window-without-memory',
    );

    expect(draft.isNotEmpty, isFalse);
  });

  test('self notes discard exact and 90-percent duplicate variants', () async {
    expect(
      await DatabaseHelper.appendSelfNote('char-a', '我會在小禾難過的時候先安靜地陪著他。'),
      isTrue,
    );
    expect(
      await DatabaseHelper.appendSelfNote('char-a', '我會在小禾難過的時候先安靜地陪著他'),
      isFalse,
    );
    expect(
      await DatabaseHelper.appendSelfNote('char-a', '我會在小禾難過的時候先安靜地陪着他'),
      isFalse,
    );
    expect(
      await DatabaseHelper.appendSelfNote('char-a', '我發現自己其實很依賴小禾給我的安全感'),
      isTrue,
    );

    final notes = await DatabaseHelper.getSelfNotes('char-a');
    expect(notes.split('\n'), hasLength(2));
  });

  test(
    'deleting a self note leaves the conversation static snapshot intact',
    () async {
      await DatabaseHelper.appendSelfNote('char-a', '小禾喜歡下雨天');
      await DatabaseHelper.appendSelfNote('char-a', '小禾嘴硬時其實想被抱住');
      await DatabaseHelper.createConversation(
        Conversation(id: 'conv-a', characterId: 'char-a'),
      );
      await db.update(
        'conversations',
        {'pinned_static_self_notes': '· 小禾喜歡下雨天\n· 小禾嘴硬時其實想被抱住'},
        where: 'id = ?',
        whereArgs: ['conv-a'],
      );

      expect(await DatabaseHelper.deleteSelfNote('char-a', '小禾喜歡下雨天'), isTrue);
      expect(await DatabaseHelper.getSelfNotes('char-a'), '· 小禾嘴硬時其實想被抱住');
      expect(
        await DatabaseHelper.getConversationPinnedSelfNotes('conv-a'),
        '· 小禾喜歡下雨天\n· 小禾嘴硬時其實想被抱住',
      );
    },
  );

  test(
    'reading self notes cleans existing duplicates but keeps conflicts',
    () async {
      await db.update(
        'characters',
        {
          'self_notes': '''
· 我會在小禾難過的時候先安靜地陪著他
· 我會在小禾難過的時候先安靜地陪著他。
· 我會在小禾難過的時候先安靜地陪着他
· 我不會在小禾難過的時候先安靜地陪著他
· 我會記得小禾每天要吃2顆藥
· 我會記得小禾每天要吃3顆藥
''',
        },
        where: 'id = ?',
        whereArgs: ['char-a'],
      );

      final notes = await DatabaseHelper.getSelfNotes('char-a');
      expect(notes.split('\n'), hasLength(4));
      expect(notes, contains('我會在小禾難過的時候先安靜地陪著他'));
      expect(notes, contains('我不會在小禾難過的時候先安靜地陪著他'));
      expect(notes, contains('每天要吃2顆藥'));
      expect(notes, contains('每天要吃3顆藥'));
      final stored = (await db.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: ['char-a'],
      )).single['self_notes'];
      expect(stored, notes);
    },
  );
}

Future<Map<String, dynamic>> _bioMeta(Database db, String characterId) async {
  final row = (await db.query(
    'characters',
    columns: const <String>['bio_clock'],
    where: 'id = ?',
    whereArgs: <Object>[characterId],
  )).single;
  final decoded =
      jsonDecode(row['bio_clock'] as String) as Map<String, dynamic>;
  return Map<String, dynamic>.from(decoded['meta'] as Map);
}

Future<List<Map<String, dynamic>>> _bioHabits(
  Database db,
  String characterId,
) async {
  final row = (await db.query(
    'characters',
    columns: const <String>['bio_clock'],
    where: 'id = ?',
    whereArgs: <Object>[characterId],
  )).single;
  final decoded =
      jsonDecode(row['bio_clock'] as String) as Map<String, dynamic>;
  return (decoded['habits'] as List<dynamic>)
      .map((habit) => Map<String, dynamic>.from(habit as Map))
      .toList();
}

Future<int> _mentionCount(Database db, int id) async {
  final row = (await db.query(
    'memories',
    columns: const <String>['mention_count'],
    where: 'id = ?',
    whereArgs: <Object>[id],
  )).single;
  return row['mention_count'] as int;
}

Future<List<String>> _bioSetupKeys(Database db, String characterId) async {
  final row = (await db.query(
    'characters',
    columns: const <String>['bio_clock'],
    where: 'id = ?',
    whereArgs: <Object>[characterId],
  )).single;
  final raw = row['bio_clock'] as String? ?? '';
  if (raw.isEmpty) return const <String>[];
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final meta = Map<String, dynamic>.from(decoded['meta'] as Map);
  return (meta['delivered_setup_keys'] as List<dynamic>? ?? const <dynamic>[])
      .map((value) => value.toString())
      .toList();
}
