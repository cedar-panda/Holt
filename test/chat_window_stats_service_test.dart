import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/chat_window_stats_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-10T10:00:00.000Z';
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'main',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('loads only activity attributed to the current window', () async {
    const now = '2026-10-10T10:00:00.000Z';
    await DatabaseHelper.logUsage(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      characterId: 'char-a',
      conversationId: 'conv-a',
      promptTokens: 120,
      completionTokens: 30,
      requestKind: 'chat',
    );
    await DatabaseHelper.logUsage(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      characterId: 'char-a',
      conversationId: 'conv-a',
      promptTokens: 40,
      completionTokens: 10,
      cacheHitTokens: 16,
      requestKind: 'worldbook',
    );
    await DatabaseHelper.logUsage(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      characterId: 'char-a',
      conversationId: 'conv-a',
      promptTokens: 0,
      completionTokens: 0,
      cacheHitTokens: 8,
      requestKind: 'summary',
    );
    await DatabaseHelper.logUsage(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      characterId: 'char-a',
      conversationId: 'conv-b',
      promptTokens: 999,
      completionTokens: 999,
      requestKind: 'worldbook',
    );
    await db.insert('context_summaries', <String, Object?>{
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'main',
      'source_conversation_id': 'conv-a',
      'content': '摘要',
      'token_count': 20,
      'created_at': now,
    });
    await db.insert(
      'messages',
      Message(
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '命中',
        isUser: false,
        cacheHit: true,
        createdAt: DateTime.parse(now),
      ).toMap(),
    );
    await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        mode: 'rp',
        category: '關係',
        content: '兩人立下約定',
        sourceConversationId: 'conv-a',
        triggers: '立下約定',
      ),
    );

    final snapshot = await ChatWindowStatsService.load(
      conversationId: 'conv-a',
      provider: 'gemini',
      model: 'gemini-2.5-flash',
    );

    expect(snapshot.recordedTokens, 200);
    expect(snapshot.summaryCount, 1);
    expect(snapshot.worldbookCount, 1);
    expect(snapshot.cacheHitCount, 2);
    expect(snapshot.cacheReportingAvailable, isTrue);
    expect(snapshot.memories, hasLength(1));
    expect(snapshot.memories.single.content, '兩人立下約定');
  });

  test('edits and archives only active memory from this window', () async {
    final id = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        mode: 'rp',
        category: '承諾',
        content: '舊內容',
        sourceConversationId: 'conv-a',
      ),
    );
    final initial = await ChatWindowStatsService.load(
      conversationId: 'conv-a',
      provider: 'local',
      model: 'local',
    );
    expect(initial.cacheReportingAvailable, isFalse);

    await ChatWindowStatsService.updateMemory(
      memoryId: id,
      conversationId: 'conv-a',
      content: '新內容',
      triggers: '承諾兌現',
    );
    final edited = await ChatWindowStatsService.load(
      conversationId: 'conv-a',
      provider: 'local',
      model: 'local',
    );
    expect(edited.memories.single.content, '新內容');
    expect(edited.memories.single.triggers, '承諾兌現');

    final archived = await ChatWindowStatsService.archiveMemory(
      memory: edited.memories.single,
      characterId: 'char-a',
    );
    expect(archived, isTrue);
    final afterArchive = await ChatWindowStatsService.load(
      conversationId: 'conv-a',
      provider: 'local',
      model: 'local',
    );
    expect(afterArchive.memories, isEmpty);
  });

  test(
    'does not invent a zero when a custom route may omit cache usage',
    () async {
      final snapshot = await ChatWindowStatsService.load(
        conversationId: 'conv-a',
        provider: 'openai_compatible',
        model: 'custom-model',
      );

      expect(snapshot.cacheHitCount, 0);
      expect(snapshot.cacheReportingAvailable, isFalse);
    },
  );
}
