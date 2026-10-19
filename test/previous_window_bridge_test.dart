import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
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
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'new window bridges exactly two turns from the same RP story line',
    () async {
      await DatabaseHelper.createConversation(
        Conversation(
          id: 'old-rp',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
          createdAt: DateTime.utc(2026, 9, 20),
          updatedAt: DateTime.utc(2026, 9, 20),
        ),
      );
      await DatabaseHelper.createConversation(
        Conversation(
          id: 'other-route',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-b',
          createdAt: DateTime.utc(2026, 9, 21),
          updatedAt: DateTime.utc(2026, 9, 21),
        ),
      );
      await DatabaseHelper.createConversation(
        Conversation(
          id: 'new-rp',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
          createdAt: DateTime.utc(2026, 9, 22),
          updatedAt: DateTime.utc(2026, 9, 22),
        ),
      );
      for (var index = 0; index < 6; index++) {
        await DatabaseHelper.insertMessage(
          Message(
            conversationId: 'old-rp',
            characterId: 'char-a',
            text: 'old-$index',
            isUser: index.isEven,
            createdAt: DateTime.utc(2026, 9, 20, 0, index),
          ),
        );
      }
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'other-route',
          characterId: 'char-a',
          text: 'must-not-cross',
          isUser: true,
          createdAt: DateTime.utc(2026, 9, 21, 0, 1),
        ),
      );

      final bridge = await DatabaseHelper.getPreviousConversationTurns(
        currentConversationId: 'new-rp',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
      );

      expect(bridge.map((message) => message.text), <String>[
        'old-2',
        'old-3',
        'old-4',
        'old-5',
      ]);
      expect(bridge.map((message) => message.isUser), <bool>[
        true,
        false,
        true,
        false,
      ]);
    },
  );

  test(
    'RP continuation candidates carry one complete rolling summary',
    () async {
      for (final conversation in <Conversation>[
        Conversation(
          id: 'created-later',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
          title: '較晚建立',
          createdAt: DateTime.utc(2026, 9, 22),
          updatedAt: DateTime.utc(2026, 9, 22),
        ),
        Conversation(
          id: 'active-later',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
          title: '最近活動',
          createdAt: DateTime.utc(2026, 9, 20),
          updatedAt: DateTime.utc(2026, 9, 20),
        ),
        Conversation(
          id: 'other-route',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-b',
          createdAt: DateTime.utc(2026, 9, 23),
          updatedAt: DateTime.utc(2026, 9, 23),
        ),
        Conversation(
          id: 'current',
          characterId: 'char-a',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
          createdAt: DateTime.utc(2026, 9, 25),
          updatedAt: DateTime.utc(2026, 9, 25),
        ),
      ]) {
        await DatabaseHelper.createConversation(conversation);
      }
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'created-later',
          characterId: 'char-a',
          text: 'older activity',
          isUser: true,
          createdAt: DateTime.utc(2026, 9, 22, 8),
        ),
      );
      for (var index = 0; index < 6; index++) {
        await DatabaseHelper.insertMessage(
          Message(
            conversationId: 'active-later',
            characterId: 'char-a',
            text: 'scene-$index',
            isUser: index.isEven,
            createdAt: DateTime.utc(2026, 9, 24, 9, index),
          ),
        );
      }
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'other-route',
          characterId: 'char-a',
          text: 'must-not-cross',
          isUser: true,
          createdAt: DateTime.utc(2026, 9, 25, 10),
        ),
      );
      for (var index = 0; index < 3; index++) {
        await DatabaseHelper.insertContextSummary(
          characterId: 'char-a',
          content: 'summary-$index',
          tokenCount: 10,
          sourceConversationId: 'active-later',
          contextMode: ContextMode.rp,
          continuityId: 'route-a',
        );
      }

      final sources = await DatabaseHelper.getRpChapterContinuationSources(
        currentConversationId: 'current',
        characterId: 'char-a',
        continuityId: 'route-a',
      );

      expect(sources.map((source) => source.conversation.id), <String>[
        'active-later',
        'created-later',
      ]);
      expect(sources.first.messages.map((message) => message.text), <String>[
        'scene-4',
        'scene-5',
      ]);
      expect(sources.first.summaries, <String>['summary-2']);
    },
  );

  test('RP continuation preview keeps the latest complete turn', () async {
    for (final conversation in <Conversation>[
      Conversation(
        id: 'source',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        createdAt: DateTime.utc(2026, 9, 20),
        updatedAt: DateTime.utc(2026, 9, 20),
      ),
      Conversation(
        id: 'current',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        createdAt: DateTime.utc(2026, 9, 25),
        updatedAt: DateTime.utc(2026, 9, 25),
      ),
    ]) {
      await DatabaseHelper.createConversation(conversation);
    }
    final messages = <(bool, String)>[
      (true, 'user-1'),
      (false, 'char-1'),
      (true, 'user-draft'),
      (true, 'user-2'),
      (false, 'char-2'),
      (true, 'user-3'),
      (false, 'char-3'),
    ];
    for (var index = 0; index < messages.length; index++) {
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'source',
          characterId: 'char-a',
          text: messages[index].$2,
          isUser: messages[index].$1,
          createdAt: DateTime.utc(2026, 9, 24, 9, index),
        ),
      );
    }

    final sources = await DatabaseHelper.getRpChapterContinuationSources(
      currentConversationId: 'current',
      characterId: 'char-a',
      continuityId: 'route-a',
    );

    expect(sources.single.messages.map((message) => message.text), <String>[
      'user-3',
      'char-3',
    ]);
  });

  test(
    'continuation source marker persists locally but never reaches prompt',
    () {
      final marker = Message.rpChapterContinuationSourceMarker('source/a');
      final anchor = Message.rpChapterContinuationAnchorMarker(42);
      final mode = Message.continuationStartModeMarker('user');
      final message = Message(
        conversationId: 'current',
        characterId: 'char-a',
        text:
            '${Message.rpChapterContinuationPrefix}\n$marker\n$anchor\n$mode\nContinue the scene.',
        isUser: true,
      );

      expect(message.rpChapterContinuationSourceId, 'source/a');
      expect(message.rpChapterContinuationAnchorMessageId, 42);
      expect(message.continuationStartMode, 'user');
      expect(message.isUserFirstContinuation, isTrue);
      expect(
        message.toPromptHistoryEntry()['content'],
        '${Message.rpChapterContinuationPrefix}\nContinue the scene.',
      );
    },
  );

  test('persisted continuation resolves the exact source and action', () async {
    for (final conversation in <Conversation>[
      Conversation(
        id: 'source-old',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        title: 'Old source',
      ),
      Conversation(
        id: 'source-new',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        title: 'New source',
      ),
      Conversation(
        id: 'current',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
      ),
    ]) {
      await DatabaseHelper.createConversation(conversation);
    }
    int? oldSourceAnchorId;
    for (final sourceId in <String>['source-old', 'source-new']) {
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: sourceId,
          characterId: 'char-a',
          text: '$sourceId-user',
          isUser: true,
        ),
      );
      final assistantId = await DatabaseHelper.insertMessage(
        Message(
          conversationId: sourceId,
          characterId: 'char-a',
          text: '$sourceId-char',
          isUser: false,
        ),
      );
      if (sourceId == 'source-old') oldSourceAnchorId = assistantId;
    }
    final marker = Message.rpChapterContinuationSourceMarker('source-old');
    final anchor = Message.rpChapterContinuationAnchorMarker(
      oldSourceAnchorId!,
    );
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: 'current',
        characterId: 'char-a',
        text:
            '${Message.rpChapterContinuationPrefix}\n$marker\n$anchor\nContinue the scene.',
        isUser: true,
      ),
    );
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: 'source-old',
        characterId: 'char-a',
        text: 'later-source-message',
        isUser: true,
      ),
    );

    final latestAction =
        await DatabaseHelper.getLatestRpChapterContinuationAction('current');
    final exact = await DatabaseHelper.getRpChapterContinuationSource(
      sourceConversationId: latestAction!.rpChapterContinuationSourceId!,
      currentConversationId: 'current',
      characterId: 'char-a',
      continuityId: 'route-a',
      throughMessageId: latestAction.rpChapterContinuationAnchorMessageId,
    );

    expect(exact?.conversation.id, 'source-old');
    expect(exact?.messages.map((message) => message.text), <String>[
      'source-old-user',
      'source-old-char',
    ]);
  });

  test('a long source window remains readable in 50-message pages', () async {
    await DatabaseHelper.createConversation(
      Conversation(
        id: 'long-source',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
      ),
    );
    final batch = db.batch();
    for (var index = 0; index < 120; index++) {
      batch.insert(
        'messages',
        Message(
          conversationId: 'long-source',
          characterId: 'char-a',
          text: 'message-$index',
          isUser: index.isEven,
          createdAt: DateTime.utc(2026, 9, 25, 0, index),
        ).toMap(),
      );
    }
    await batch.commit(noResult: true);

    final latest = await DatabaseHelper.getMessages('long-source', limit: 50);
    final previous = await DatabaseHelper.getMessagesBeforeId(
      'long-source',
      latest.first.id!,
      limit: 50,
    );
    final earliest = await DatabaseHelper.getMessagesBeforeId(
      'long-source',
      previous.first.id!,
      limit: 50,
    );

    expect(latest.length, 50);
    expect(previous.length, 50);
    expect(earliest.length, 20);
    expect(earliest.first.text, 'message-0');
    expect(latest.last.text, 'message-119');
  });

  test('daily continuation candidates never cross into RP', () async {
    for (final conversation in <Conversation>[
      Conversation(
        id: 'daily-source',
        characterId: 'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
      ),
      Conversation(
        id: 'rp-source',
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'main',
      ),
      Conversation(
        id: 'daily-current',
        characterId: 'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
      ),
    ]) {
      await DatabaseHelper.createConversation(conversation);
    }
    for (final source in <(String, String)>[
      ('daily-source', 'daily'),
      ('rp-source', 'rp'),
    ]) {
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: source.$1,
          characterId: 'char-a',
          text: '${source.$2}-user',
          isUser: true,
        ),
      );
      await DatabaseHelper.insertMessage(
        Message(
          conversationId: source.$1,
          characterId: 'char-a',
          text: '${source.$2}-char',
          isUser: false,
        ),
      );
    }

    final sources = await DatabaseHelper.getRpChapterContinuationSources(
      currentConversationId: 'daily-current',
      characterId: 'char-a',
      continuityId: 'main',
      contextMode: ContextMode.daily,
    );
    final crossMode = await DatabaseHelper.getRpChapterContinuationSource(
      sourceConversationId: 'rp-source',
      currentConversationId: 'daily-current',
      characterId: 'char-a',
      continuityId: 'main',
      contextMode: ContextMode.daily,
    );

    expect(sources.map((source) => source.conversation.id), <String>[
      'daily-source',
    ]);
    expect(crossMode, isNull);
  });
}
