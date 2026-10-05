import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/context_summary_repair_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'rp_worldbook_auto_write_v1': false,
    });
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });
  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('invalidated RP chain is rebuilt in original summary order', () async {
    const now = '2026-10-02T10:00:00.000';
    for (final conversationId in <String>['conv-a', 'conv-b']) {
      await db.insert('conversations', <String, Object?>{
        'id': conversationId,
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'created_at': now,
        'updated_at': now,
      });
    }
    for (final row in const <Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'conversation_id': 'conv-a',
        'text': '第一段舊內容',
        'is_user': 1,
      },
      <String, Object?>{
        'id': 2,
        'conversation_id': 'conv-a',
        'text': '第一段回應',
        'is_user': 0,
      },
      <String, Object?>{
        'id': 3,
        'conversation_id': 'conv-b',
        'text': '第二段內容',
        'is_user': 1,
      },
      <String, Object?>{
        'id': 4,
        'conversation_id': 'conv-b',
        'text': '第二段回應',
        'is_user': 0,
      },
    ]) {
      await db.insert('messages', <String, Object?>{
        ...row,
        'character_id': 'char-a',
        'created_at': now,
      });
    }
    final first = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: '舊摘要一',
      tokenCount: 10,
      conversationId: 'conv-a',
      cursorMessageId: 2,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    final second = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: '舊摘要二',
      tokenCount: 10,
      conversationId: 'conv-b',
      cursorMessageId: 4,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );

    await DatabaseHelper.updateMessageText(1, '第一段修正內容');

    final queued = await db.query(
      'context_summary_repairs',
      orderBy: 'original_summary_id ASC',
    );
    expect(queued.map((row) => row['original_summary_id']), <int>[
      first,
      second,
    ]);
    expect(queued.map((row) => row['status']), everyElement('pending'));

    final processedOrder = <int>[];
    final rebuilt = await ContextSummaryRepairService.processScope(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
      runner: (job, sourceMessages) async {
        processedOrder.add(job['original_summary_id']! as int);
        final conversationId = job['source_conversation_id']!.toString();
        await DatabaseHelper.insertContextSummary(
          characterId: 'char-a',
          content: '重建 ${job['original_summary_id']}',
          tokenCount: 12,
          sourceConversationId: conversationId,
          displayAnchorMessageId: sourceMessages.last.id!,
          sourceMessageStartId: sourceMessages.first.id!,
          sourceMessageEndId: sourceMessages.last.id!,
          replaceSummaryId: job['original_summary_id']! as int,
          replaceInvalidatedSummary: true,
          contextMode: ContextMode.rp,
          continuityId: 'story-a',
          allowPendingRepairs: true,
          expectedSourceMessages: sourceMessages,
        );
        return 12;
      },
    );

    expect(rebuilt, 2);
    expect(processedOrder, <int>[first, second]);
    expect(
      (await db.query('context_summary_repairs')).map((row) => row['status']),
      everyElement('completed'),
    );
    final valid = await db.query(
      'context_summaries',
      where: 'revision_status = ?',
      whereArgs: <Object?>['valid'],
      orderBy: 'id ASC',
    );
    expect(valid, hasLength(2));
    expect(valid.first['parent_summary_id'], isNull);
    expect(valid.last['parent_summary_id'], valid.first['id']);
    expect(
      (await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: <Object?>[1],
      )).single['text'],
      '第一段修正內容',
    );
  });

  test('source revision guard rejects a model result after an edit', () async {
    const now = '2026-10-02T10:00:00.000';
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('messages', <String, Object?>{
      'id': 1,
      'conversation_id': 'conv-a',
      'character_id': 'char-a',
      'text': '原文',
      'is_user': 1,
      'created_at': now,
    });
    final snapshot = Message.fromMap(
      (await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: <Object?>[1],
      )).single,
    );
    expect(
      await DatabaseHelper.messageSnapshotsStillCurrent(<Message>[snapshot]),
      isTrue,
    );

    await DatabaseHelper.updateMessageText(1, '修改後');

    expect(
      await DatabaseHelper.messageSnapshotsStillCurrent(<Message>[snapshot]),
      isFalse,
    );
    final skipped = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: '不應保存的舊摘要',
      tokenCount: 12,
      conversationId: 'conv-a',
      cursorMessageId: 1,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
      expectedSourceMessages: <Message>[snapshot],
    );
    expect(skipped, 0);
    expect(await db.query('context_summaries'), isEmpty);
    expect(
      (await db.query('conversations')).single['summary_cursor_message_id'],
      0,
    );
  });

  test('repair replaces an invalidated summary in its original slot', () async {
    const now = '2026-10-02T10:00:00.000';
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('messages', <String, Object?>{
      'id': 1,
      'conversation_id': 'conv-a',
      'character_id': 'char-a',
      'text': '舊內容',
      'is_user': 1,
      'created_at': now,
    });
    final oldId = await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: '舊摘要',
      tokenCount: 8,
      sourceConversationId: 'conv-a',
      sourceMessageStartId: 1,
      sourceMessageEndId: 1,
      displayAnchorMessageId: 1,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    final oldCreatedAt = (await db.query(
      'context_summaries',
      where: 'id = ?',
      whereArgs: <Object?>[oldId],
    )).single['created_at'];
    await DatabaseHelper.updateMessageText(1, '修正內容');
    final snapshot = Message.fromMap((await db.query('messages')).single);

    final replacementId = await DatabaseHelper.insertContextSummary(
      characterId: 'char-a',
      content: '修正摘要',
      tokenCount: 9,
      sourceConversationId: 'conv-a',
      sourceMessageStartId: 1,
      sourceMessageEndId: 1,
      displayAnchorMessageId: 1,
      replaceSummaryId: oldId,
      replaceInvalidatedSummary: true,
      expectedSourceMessages: <Message>[snapshot],
      allowPendingRepairs: true,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    expect(replacementId, greaterThan(0));
    final valid = (await db.query(
      'context_summaries',
      where: "revision_status = 'valid'",
    )).single;
    expect(valid['content'], '修正摘要');
    expect(valid['created_at'], oldCreatedAt);
    expect(valid['revision'], 2);
    expect((await db.query('context_summary_repairs')).single['status'], 'completed');
  });

  test(
    'pending repair blocks ordinary summaries but permits its replacement',
    () async {
      const now = '2026-10-02T10:00:00.000';
      await db.insert('conversations', <String, Object?>{
        'id': 'conv-a',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('messages', <String, Object?>{
        'id': 1,
        'conversation_id': 'conv-a',
        'character_id': 'char-a',
        'text': '新劇情',
        'is_user': 1,
        'created_at': now,
      });
      final oldSummary =
          await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
            characterId: 'char-a',
            content: '舊劇情',
            tokenCount: 8,
            conversationId: 'conv-a',
            cursorMessageId: 1,
            contextMode: ContextMode.rp,
            continuityId: 'story-a',
          );
      await DatabaseHelper.updateMessageText(1, '修正的新劇情');
      expect(
        (await db.query(
          'context_summary_repairs',
        )).single['original_summary_id'],
        oldSummary,
      );
      final snapshot = Message.fromMap((await db.query('messages')).single);
      Future<int> write({required bool repair}) =>
          DatabaseHelper.insertContextSummaryAndAdvanceCursor(
            characterId: 'char-a',
            content: '修正後摘要',
            tokenCount: 10,
            conversationId: 'conv-a',
            cursorMessageId: 1,
            contextMode: ContextMode.rp,
            continuityId: 'story-a',
            expectedSourceMessages: <Message>[snapshot],
            allowPendingRepairs: repair,
          );
      expect(await write(repair: false), 0);
      expect(await write(repair: true), greaterThan(0));
    },
  );

  test(
    'deleting a source window closes its unreplayable repair jobs',
    () async {
      const now = '2026-10-02T10:00:00.000';
      await db.insert('conversations', <String, Object?>{
        'id': 'conv-a',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('context_summary_repairs', <String, Object?>{
        'original_summary_id': 77,
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'source_conversation_id': 'conv-a',
        'source_message_start_id': 1,
        'source_message_end_id': 2,
        'status': 'pending',
        'created_at': now,
        'updated_at': now,
      });
      await DatabaseHelper.deleteConversation('conv-a');
      expect(
        (await db.query('context_summary_repairs')).single['status'],
        'completed',
      );
    },
  );

  test('re-roll repair waits for the replacement reply', () async {
    const now = '2026-10-02T10:00:00.000';
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': now,
      'updated_at': now,
    });
    for (final row in const <Map<String, Object?>>[
      {'id': 1, 'text': '請繼續', 'is_user': 1},
      {'id': 2, 'text': '舊回覆', 'is_user': 0},
    ]) {
      await db.insert('messages', <String, Object?>{
        ...row,
        'conversation_id': 'conv-a',
        'character_id': 'char-a',
        'created_at': now,
      });
    }
    await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
      characterId: 'char-a',
      content: '舊摘要',
      tokenCount: 8,
      conversationId: 'conv-a',
      cursorMessageId: 2,
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
    );
    await DatabaseHelper.deleteMessageById(2, reason: 'reroll');

    var calls = 0;
    await ContextSummaryRepairService.processScope(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
      runner: (job, messages) async {
        calls++;
        return 1;
      },
    );
    expect(calls, 0);
    expect(
      (await db.query('context_summary_repairs')).single['status'],
      'pending',
    );

    await db.insert('messages', <String, Object?>{
      'id': 3,
      'conversation_id': 'conv-a',
      'character_id': 'char-a',
      'text': '新回覆',
      'is_user': 0,
      'created_at': now,
    });
    await ContextSummaryRepairService.processScope(
      characterId: 'char-a',
      contextMode: ContextMode.rp,
      continuityId: 'story-a',
      runner: (job, messages) async {
        calls++;
        expect(messages.map((message) => message.id), <int?>[1, 3]);
        return 1;
      },
    );
    expect(calls, 1);
    expect(
      (await db.query('context_summary_repairs')).single['status'],
      'completed',
    );
  });
}
