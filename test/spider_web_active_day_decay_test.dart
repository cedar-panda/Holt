import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/spider_web_core.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': 'A',
      'is_spider_web_enabled': 1,
      'created_at': now,
      'updated_at': now,
    });
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'daily-window',
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      ),
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'rp-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      ),
    );
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'one or many messages on a date count as one daily active day',
    () async {
      final day = DateTime.now().subtract(const Duration(days: 2));
      await _insertUserMessage(db, 'daily-window', day);
      await _insertUserMessage(
        db,
        'daily-window',
        day.add(const Duration(hours: 2)),
      );
      await _insertUserMessage(
        db,
        'rp-window',
        day.add(const Duration(hours: 3)),
      );

      final keys = await DatabaseHelper.getCharacterActiveDateKeys('char-a');

      expect(keys, hasLength(1));
      expect(
        SpiderWebCore.countActiveDaysSince(
          day.subtract(const Duration(days: 1)).toIso8601String(),
          activeDateKeys: keys,
        ),
        1,
      );
    },
  );

  test('offline calendar time does not decay or archive an island', () async {
    final old = DateTime.now().subtract(const Duration(days: 365));
    final memoryId = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '偏好',
        content: 'still here after a year offline',
        createdAt: old,
        updatedAt: old,
        lastAccessed: old,
      ),
    );

    expect(await SpiderWebCore.runArchiveEngine(characterId: 'char-a'), 0);
    expect(
      (await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: [memoryId],
      )).single['status'],
      'active',
    );
  });

  test(
    'an unmentioned island archives after thirty daily active days',
    () async {
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 60));
      final memoryId = await DatabaseHelper.insertMemory(
        Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '偏好',
          content: 'fades only while daily chat is active',
          createdAt: old,
          updatedAt: old,
          lastAccessed: old,
        ),
      );

      for (var i = 0; i < 29; i++) {
        await _insertUserMessage(
          db,
          'daily-window',
          now.subtract(Duration(days: i)),
        );
        await _insertUserMessage(
          db,
          'rp-window',
          now.subtract(Duration(days: i + 30)),
        );
      }
      expect(await SpiderWebCore.runArchiveEngine(characterId: 'char-a'), 0);

      await _insertUserMessage(
        db,
        'daily-window',
        now.subtract(const Duration(days: 29)),
      );
      expect(await SpiderWebCore.runArchiveEngine(characterId: 'char-a'), 1);
      expect(
        (await db.query(
          'memories',
          where: 'id = ?',
          whereArgs: [memoryId],
        )).single['status'],
        'deleted',
      );
      final archived = await db.query(
        'archive',
        where: 'original_table = ? AND original_id = ?',
        whereArgs: <Object?>['memories', memoryId],
      );
      expect(archived, hasLength(1));
      expect(archived.single['reason'], 'spider_web_decay');
    },
  );
}

Future<void> _insertUserMessage(
  Database db,
  String conversationId,
  DateTime createdAt,
) async {
  await db.insert('messages', <String, Object?>{
    'conversation_id': conversationId,
    'character_id': 'char-a',
    'text': 'hello',
    'is_user': 1,
    'created_at': createdAt.toIso8601String(),
  });
}
