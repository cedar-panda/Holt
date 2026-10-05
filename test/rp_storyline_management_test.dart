import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
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
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '測試角色',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('one character keeps at most three active RP storylines', () async {
    await DatabaseHelper.ensureDefaultRpStoryline('char-a');
    await DatabaseHelper.createRpStoryline(characterId: 'char-a', name: '第二條線');
    await DatabaseHelper.createRpStoryline(characterId: 'char-a', name: '第三條線');

    expect(await DatabaseHelper.getRpStorylines('char-a'), hasLength(3));
    expect(
      () =>
          DatabaseHelper.createRpStoryline(characterId: 'char-a', name: '第四條線'),
      throwsA(isA<StateError>()),
    );
  });

  test('archiving the recent storyline transfers the recent marker', () async {
    await DatabaseHelper.ensureDefaultRpStoryline('char-a');
    final second = await DatabaseHelper.createRpStoryline(
      characterId: 'char-a',
      name: '第二條線',
    );
    await DatabaseHelper.setDefaultRpStoryline(
      characterId: 'char-a',
      storylineId: second,
    );
    await DatabaseHelper.setRpStorylineArchived(
      characterId: 'char-a',
      storylineId: second,
      archived: true,
    );

    final rows = await DatabaseHelper.getRpStorylines(
      'char-a',
      includeArchived: true,
    );
    final main = rows.singleWhere((row) => row['id'] == 'main');
    final archived = rows.singleWhere((row) => row['id'] == second);
    expect(main['is_default'], 1);
    expect(archived['status'], 'archived');
    expect(archived['is_default'], 0);
  });

  test('the final active storyline cannot be archived', () async {
    await DatabaseHelper.ensureDefaultRpStoryline('char-a');
    expect(
      () => DatabaseHelper.setRpStorylineArchived(
        characterId: 'char-a',
        storylineId: 'main',
        archived: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('new RP window keeps the selected storyline identity', () async {
    await DatabaseHelper.ensureDefaultRpStoryline('char-a');
    final storyline = await DatabaseHelper.createRpStoryline(
      characterId: 'char-a',
      name: '北境線',
    );
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'conversation-a',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: storyline,
      ),
    );

    final conversation = await DatabaseHelper.getConversation('conversation-a');
    expect(conversation?.continuityId, storyline);
    expect(conversation?.contextMode, ContextMode.rp);
  });

  test(
    'an empty RP window can move to another storyline exactly once',
    () async {
      await DatabaseHelper.ensureDefaultRpStoryline('char-a');
      final storyline = await DatabaseHelper.createRpStoryline(
        characterId: 'char-a',
        name: '北境線',
      );
      await DatabaseHelper.createConversation(
        Conversation(
          id: 'empty-window',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'main',
        ),
      );

      expect(
        await DatabaseHelper.rebindEmptyRpConversation(
          conversationId: 'empty-window',
          characterId: 'char-a',
          storylineId: storyline,
          userPersonaId: 'persona-a',
          userPersonaSnapshot: '{"name":"昭昭"}',
        ),
        isTrue,
      );
      final rebound = await DatabaseHelper.getConversation('empty-window');
      expect(rebound?.continuityId, storyline);
      expect(rebound?.userPersonaId, 'persona-a');

      await DatabaseHelper.insertMessage(
        Message(conversationId: 'empty-window', text: '這條線已經開始', isUser: true),
      );
      expect(
        await DatabaseHelper.rebindEmptyRpConversation(
          conversationId: 'empty-window',
          characterId: 'char-a',
          storylineId: 'main',
          userPersonaId: 'persona-b',
          userPersonaSnapshot: '{"name":"另一身分"}',
        ),
        isFalse,
      );
      expect(
        (await DatabaseHelper.getConversation('empty-window'))?.continuityId,
        storyline,
      );
    },
  );

  test('RP history detection sees windows across storylines', () async {
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'story-window',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-two',
      ),
    );
    expect(
      await DatabaseHelper.hasConversationHistoryForCharacter(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      ),
      isFalse,
    );

    await DatabaseHelper.insertMessage(
      Message(conversationId: 'story-window', text: '第二條故事線的正文', isUser: true),
    );
    expect(
      await DatabaseHelper.hasConversationHistoryForCharacter(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
      ),
      isTrue,
    );
    expect(
      await DatabaseHelper.hasConversationHistoryForCharacter(
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      ),
      isFalse,
    );
  });

  test('RP memory search and archive stay inside one storyline', () async {
    final firstId = await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-one',
        mode: 'story',
        category: '伏筆',
        content: '城門留下了一封密信',
      ),
    );
    await DatabaseHelper.insertMemory(
      Memory(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-two',
        mode: 'story',
        category: '伏筆',
        content: '城門埋著另一條線索',
      ),
    );

    final firstStory = await DatabaseHelper.searchMemoriesForCharacter(
      '城門',
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'story-one',
    );
    expect(firstStory, hasLength(1));
    expect(firstStory.single.continuityId, 'story-one');

    await DatabaseHelper.archiveMemory(firstId, 'test', characterId: 'char-a');
    expect(
      await DatabaseHelper.getArchivedCount(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-one',
      ),
      1,
    );
    expect(
      await DatabaseHelper.getArchivedCount(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'story-two',
      ),
      0,
    );
  });
}
