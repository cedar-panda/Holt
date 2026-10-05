import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/character_diary_service.dart';
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
        userName: '昭昭',
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
        userName: '昭昭',
        currentUserContent: '今天發生了一件事',
        contextMode: ContextMode.daily,
        enabled: true,
        now: now,
        chanceRoll: 0,
      );
      expect(dailyPrompt.text, contains('昭昭'));
      expect(dailyPrompt.text, contains('<holt_diary'));
    },
  );

  test('one diary per local day is stored and XML stays out of chat', () async {
    final now = DateTime(2026, 10, 4, 22);
    const xml =
        '晚安。\n<holt_diary version="1">'
        '<title>今天</title><body>和昭昭聊了很久 &amp; 很安心。</body>'
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
    expect(entries.single.body, '和昭昭聊了很久 & 很安心。');
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
      userName: '昭昭',
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
}
