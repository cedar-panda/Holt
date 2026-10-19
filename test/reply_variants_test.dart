import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/memory_guard_service.dart';
import 'package:project_yanci/widgets/reply_variant_controls.dart';
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
    await db.insert('conversations', {
      'id': 'window',
      'character_id': 'char',
      'created_at': now,
      'updated_at': now,
    });
  });
  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });
  Future<int> message(String text, {bool user = false}) =>
      DatabaseHelper.insertMessage(
        Message(
          conversationId: 'window',
          characterId: 'char',
          isUser: user,
          text: text,
        ),
      );
  Future<void> pending(String id, int source, {String status = 'pending'}) => db
      .insert('pending_memory_actions', {
        'id': id,
        'character_id': 'char',
        'mode': 'romance',
        'action': 'create',
        'source': 'model',
        'source_conversation_id': 'window',
        'source_message_id': source,
        'fingerprint': id,
        'status': status,
        'created_at': DateTime.now().toIso8601String(),
      })
      .then((_) {});

  test(
    'reroll keeps disk versions and deletes only old pending proposals',
    () async {
      final user = await message('hello', user: true);
      final first = await message('first reply');
      await pending('old-pending', first);
      await pending('old-rejected', first, status: 'rejected');
      await pending('old-confirmed', first, status: 'completed');
      await DatabaseHelper.deleteMessageById(first, reason: 'reroll');
      final second = await message('second reply');
      await pending('new-pending', second);
      expect(
        (await db.query(
          'messages',
          where: 'id = ?',
          whereArgs: [second],
        )).single['reply_to_message_id'],
        user,
      );
      var variants = await ReplyVariants.index(second);
      expect(variants.archiveIds.length, 2);
      expect(variants.selected, 1);
      expect(
        await db.query('pending_memory_actions', where: "id = 'old-pending'"),
        isEmpty,
      );
      expect(await db.query('pending_memory_actions'), hasLength(3));

      final restored = await ReplyVariants.select(
        second,
        variants.archiveIds.first!,
      );
      expect(restored!.text, 'first reply');
      expect(restored.id, second);
      expect(restored.revision, 2);
      expect(restored.memoryLog, isEmpty);
      expect(await db.query('pending_memory_actions'), hasLength(2));
      variants = await ReplyVariants.index(second);
      expect(variants.selected, 0);
      expect(variants.archiveIds.length, 2);
      await ReplyVariants.select(second, variants.archiveIds.last!);
      variants = await ReplyVariants.index(second);
      expect(variants.selected, 1);
      expect(
        variants.archiveIds.length,
        2,
        reason: 'switching must not duplicate versions',
      );
      expect(
        (await DatabaseHelper.getMessages('window')).map((m) => m.text),
        ['hello', 'second reply'],
        reason: 'only selected content enters prompt history',
      );
    },
  );

  test(
    'edited resend restores the original prompt and answer as a pair',
    () async {
      final user = await message('first wording', user: true);
      final first = await message('first answer');
      await pending('old', first);
      await pending('rejected', first, status: 'rejected');
      final summary = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char',
        content: 'old wording summary',
        tokenCount: 10,
        conversationId: 'window',
        cursorMessageId: first,
        sourceMessageStartId: user,
      );
      final edited = await ReplyVariants.prepareUserResend(user, 'new wording');
      expect(edited!.id, user);
      expect(edited.text, 'new wording');
      expect(edited.revision, 2);
      expect(await db.query('pending_memory_actions'), hasLength(1));
      expect(
        (await db.query(
          'context_summaries',
          where: 'id = ?',
          whereArgs: [summary],
        )).single['revision_status'],
        'invalidated',
      );
      final second = await message('second answer');
      var choices = await ReplyVariants.index(second);
      expect(choices.archiveIds.length, 2);
      expect(choices.selected, 1);
      await ReplyVariants.select(second, choices.archiveIds.first!);
      expect((await DatabaseHelper.getMessages('window')).map((m) => m.text), [
        'first wording',
        'first answer',
      ]);
      choices = await ReplyVariants.index(second);
      expect(choices.archiveIds.length, 2);
      expect(choices.selected, 0);
      await ReplyVariants.select(second, choices.archiveIds.last!);
      expect((await DatabaseHelper.getMessages('window')).map((m) => m.text), [
        'new wording',
        'second answer',
      ]);
      expect((await ReplyVariants.index(second)).archiveIds.length, 2);
    },
  );

  test(
    'identical AI text for different edited prompts still has two versions',
    () async {
      final user = await message('first wording', user: true);
      await message('same answer');
      await ReplyVariants.prepareUserResend(user, 'second wording');
      final second = await message('same answer');
      final choices = await ReplyVariants.index(second);
      expect(choices.archiveIds.length, 2);
      await ReplyVariants.select(second, choices.archiveIds.first!);
      expect(
        (await DatabaseHelper.getMessageById(user))!.text,
        'first wording',
      );
      expect((await ReplyVariants.index(second)).selected, 0);
    },
  );

  test(
    'editing an earlier turn excludes discarded later replies and pending actions',
    () async {
      final user = await message('first question', user: true);
      final first = await message('first answer');
      final laterUser = await message('follow up', user: true);
      final laterReply = await message('later answer');
      await pending('first', first);
      await pending('later-user', laterUser);
      await pending('later-reply', laterReply);
      await ReplyVariants.prepareUserResend(user, 'changed question');
      final replacement = await message('replacement answer');
      expect(await db.query('pending_memory_actions'), isEmpty);
      expect((await DatabaseHelper.getMessages('window')).map((m) => m.text), [
        'changed question',
        'replacement answer',
      ]);
      final choices = await ReplyVariants.index(replacement);
      expect(choices.archiveIds.length, 2);
      final restored = await ReplyVariants.select(
        replacement,
        choices.archiveIds.first!,
      );
      expect(restored!.text, 'first answer');
    },
  );

  testWidgets(
    'no refresh button; choices appear only after editing/resending',
    (tester) async {
      final user = (await tester.runAsync(() => message('question', user: true)))!;
      final first = (await tester.runAsync(() => message('answer')))!;
      Widget controls(int id) => MaterialApp(
        home: Scaffold(
          body: ReplyVariantControls(
            messageId: id,
            revision: 1,
            color: Colors.black,
            onSelect: (_) {},
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(controls(first));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
      await tester.runAsync(
        () => ReplyVariants.prepareUserResend(user, 'edited question'),
      );
      final second = (await tester.runAsync(() => message('new answer')))!;
      await tester.runAsync(() async {
        await tester.pumpWidget(controls(second));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.byType(IconButton), findsNWidgets(2));
    },
  );

  test(
    'later turns block switching and history edits are not alternate replies',
    () async {
      await message('question', user: true);
      final first = await message('answer');
      await DatabaseHelper.deleteMessageById(first, reason: 'reroll');
      final next = await message('replacement');
      final old = (await ReplyVariants.index(next)).archiveIds.first!;
      await message('continue', user: true);
      expect(await ReplyVariants.select(next, old), isNull);
      expect((await ReplyVariants.index(next)).archiveIds, isEmpty);
      await DatabaseHelper.deleteMessageById(next, reason: 'history_edit');
      final newReply = await message('new answer');
      expect((await ReplyVariants.index(newReply)).archiveIds, [null]);
    },
  );

  test(
    'editing text clears pending even without a summary, tombstones survive',
    () async {
      await message('question', user: true);
      final answer = await message('answer');
      await pending('candidate', answer);
      await pending('rejected', answer, status: 'rejected');
      await DatabaseHelper.updateMessageText(answer, 'changed');
      expect(
        (await db.query('pending_memory_actions')).single['id'],
        'rejected',
      );
      expect((await ReplyVariants.index(answer)).archiveIds, [null]);
    },
  );

  test(
    'selecting a version invalidates summaries and deleting window clears archives',
    () async {
      final user = await message('question', user: true);
      final first = await message('old reply');
      await DatabaseHelper.deleteMessageById(first, reason: 'reroll');
      final latest = await message('new reply');
      final summary = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: 'char',
        content: 'new reply summary',
        tokenCount: 10,
        conversationId: 'window',
        cursorMessageId: latest,
        sourceMessageStartId: user,
      );
      await ReplyVariants.select(
        latest,
        (await ReplyVariants.index(latest)).archiveIds.first!,
      );
      expect(
        (await db.query(
          'context_summaries',
          where: 'id = ?',
          whereArgs: [summary],
        )).single['revision_status'],
        'invalidated',
      );
      await DatabaseHelper.deleteConversation('window');
      expect(await db.query('message_revisions'), isEmpty);
    },
  );

  test(
    'deleted reply cannot acquire pending proposals in a late binding',
    () async {
      await message('question', user: true);
      final answer = await message('answer');
      await pending('unbound', answer);
      await db.update('pending_memory_actions', {'source_message_id': null});
      await DatabaseHelper.deleteMessageById(answer);
      await MemoryGuardService.bindToMessage(
        proposalIds: ['unbound'],
        conversationId: 'window',
        messageId: answer,
      );
      expect(await db.query('pending_memory_actions'), isEmpty);
    },
  );
}
