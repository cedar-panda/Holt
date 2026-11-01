import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/character_diary_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/model_action_protocol.dart';
import 'package:project_yanci/widgets/character_diary_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-04T12:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '角色 A',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'daily-window',
      'character_id': 'char-a',
      'context_mode': 'daily',
      'continuity_id': 'main',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'rp-window',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'night prompt is daily-only and follows an eligible user turn',
    () async {
      final now = DateTime(2026, 10, 4, 21, 30);
      final rpPrompt = await CharacterDiaryService.buildNightPrompt(
        characterId: 'char-a',
        conversationId: 'rp-window',
        sourceMessageId: 1,
        userName: '小禾',
        currentUserContent: '今天發生了一件事',
        contextMode: ContextMode.rp,
        enabled: true,
        now: now,
        chanceRoll: 0,
      );
      expect(rpPrompt.isNotEmpty, isFalse);

      final dailyPrompt = await CharacterDiaryService.buildNightPrompt(
        characterId: 'char-a',
        conversationId: 'daily-window',
        sourceMessageId: 2,
        userName: '小禾',
        currentUserContent: '今天發生了一件事',
        contextMode: ContextMode.daily,
        enabled: true,
        now: now,
        chanceRoll: 0,
      );
      expect(dailyPrompt.text, contains('小禾'));
      expect(dailyPrompt.text, contains('"type":"diary.write"'));
      expect(dailyPrompt.text, isNot(contains('<holt_diary')));
    },
  );

  test(
    'JSON diary action normalizes and stores through the same path',
    () async {
      const raw = '''晚安。
[[HOLT_ACTIONS]]
{"actions":[{"type":"diary.write","arguments":{"title":"秋夜","body":"今天很安心。"}}]}
[[/HOLT_ACTIONS]]''';
      final normalized = ModelActionProtocol.normalizeForLegacyProcessors(raw);
      final result = await CharacterDiaryService.processReply(
        text: normalized,
        characterId: 'char-a',
        conversationId: 'daily-window',
        sourceMessageId: 9,
        contextMode: ContextMode.daily,
        enabled: true,
        now: DateTime(2026, 10, 4, 21),
      );

      expect(result.visibleText, '晚安。');
      expect(result.saved, isTrue);
      final entries = await CharacterDiaryService.listEntries('char-a');
      expect(entries.single.title, '秋夜');
      expect(entries.single.body, '今天很安心。');
    },
  );

  test('one diary per local day is stored and XML stays out of chat', () async {
    final now = DateTime(2026, 10, 4, 22);
    const xml =
        '晚安。\n<holt_diary version="1">'
        '<title>今天</title><body>和小禾聊了很久 &amp; 很安心。</body>'
        '</holt_diary>';
    final first = await CharacterDiaryService.processReply(
      text: xml,
      characterId: 'char-a',
      conversationId: 'daily-window',
      sourceMessageId: 10,
      contextMode: ContextMode.daily,
      enabled: true,
      now: now,
    );
    expect(first.visibleText, '晚安。');
    expect(first.saved, isTrue);

    final second = await CharacterDiaryService.processReply(
      text:
          '<holt_diary version="1"><title>第二份</title>'
          '<body>不應覆蓋第一份。</body></holt_diary>',
      characterId: 'char-a',
      conversationId: 'daily-window',
      sourceMessageId: 11,
      contextMode: ContextMode.daily,
      enabled: true,
      now: now,
    );
    expect(second.visibleText, isEmpty);
    expect(second.saved, isFalse);

    final entries = await CharacterDiaryService.listEntries('char-a');
    expect(entries, hasLength(1));
    expect(entries.single.title, '今天');
    expect(entries.single.body, '和小禾聊了很久 & 很安心。');
  });

  test('an existing diary suppresses the nightly prompt', () async {
    final now = DateTime(2026, 10, 4, 23);
    await CharacterDiaryService.processReply(
      text:
          '<holt_diary version="1"><title></title>'
          '<body>今天已經寫過了。</body></holt_diary>',
      characterId: 'char-a',
      conversationId: 'daily-window',
      sourceMessageId: 12,
      contextMode: ContextMode.daily,
      enabled: true,
      now: now,
    );
    final prompt = await CharacterDiaryService.buildNightPrompt(
      characterId: 'char-a',
      conversationId: 'daily-window',
      sourceMessageId: 13,
      userName: '小禾',
      currentUserContent: '還想再聊一會兒',
      contextMode: ContextMode.daily,
      enabled: true,
      now: now,
      chanceRoll: 0,
    );
    expect(prompt.isNotEmpty, isFalse);
  });

  test('RP and disabled diary tags are stripped without storage', () async {
    const text =
        '正文<holt_diary version="1"><title>秘密</title>'
        '<body>不應落庫。</body></holt_diary>';
    final rp = await CharacterDiaryService.processReply(
      text: text,
      characterId: 'char-a',
      conversationId: 'rp-window',
      sourceMessageId: 14,
      contextMode: ContextMode.rp,
      enabled: true,
    );
    expect(rp.visibleText, '正文');
    expect(await CharacterDiaryService.countEntries('char-a'), 0);

    final disabled = await CharacterDiaryService.processReply(
      text: text,
      characterId: 'char-a',
      conversationId: 'daily-window',
      sourceMessageId: 15,
      contextMode: ContextMode.daily,
      enabled: false,
    );
    expect(disabled.visibleText, '正文');
    expect(await CharacterDiaryService.countEntries('char-a'), 0);
  });

  testWidgets('empty daily diary keeps its archive heading visible', (
    tester,
  ) async {
    await L.setLocale('zh_TW');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CharacterDiaryReader(characterId: 'char-a')),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('日記'), findsOneWidget);
    expect(find.text('還沒有日記'), findsOneWidget);
  });

  testWidgets('daily diary preview shows title without exposing the body', (
    tester,
  ) async {
    await L.setLocale('zh_TW');
    await tester.runAsync(
      () => CharacterDiaryService.processReply(
        text:
            '<holt_diary version="1"><title>秋夜小記</title>'
            '<body>這段正文預設不應直接顯示。</body></holt_diary>',
        characterId: 'char-a',
        conversationId: 'daily-window',
        sourceMessageId: 16,
        contextMode: ContextMode.daily,
        enabled: true,
        now: DateTime(2026, 10, 5, 22),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CharacterDiaryReader(characterId: 'char-a')),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.text('秋夜小記'), findsOneWidget);
    expect(find.text('這段正文預設不應直接顯示。'), findsNothing);

    await tester.tap(find.text('秋夜小記'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('這段正文預設不應直接顯示。'), findsOneWidget);

    // The visually blank area above the sheet is the modal barrier, so a tap
    // there returns to the diary list without requiring a swipe gesture.
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();
    expect(find.text('這段正文預設不應直接顯示。'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
