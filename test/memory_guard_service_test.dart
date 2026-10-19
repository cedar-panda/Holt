import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory_action_proposal.dart';
import 'package:project_yanci/services/memory_guard_service.dart';
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
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'delete proposal cannot archive memory before explicit approval',
    () async {
      final memoryId = await _insertMemory(db, 'char-a', '不可先刪的記憶');

      final proposalId = await MemoryGuardService.proposeDelete(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [memoryId],
      );

      expect(proposalId, isNotNull);
      expect(await _memoryStatus(db, memoryId), 'active');
      expect(await db.query('archive'), isEmpty);

      await db.insert('messages', {
        'id': 42,
        'conversation_id': 'conv-a',
        'character_id': 'char-a',
        'text': 'reply requesting deletion',
        'is_user': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
      await MemoryGuardService.bindToMessage(
        proposalIds: [proposalId!],
        conversationId: 'conv-a',
        messageId: 42,
      );
      final messageCounts = await MemoryGuardService.pendingCountsByMessage(
        'conv-a',
      );
      expect(messageCounts[42]?.total, 1);
      expect(messageCounts[42]?.unread, 1);

      expect(
        await MemoryGuardService.execute(proposalId, 'char-a'),
        MemoryActionProposal.statusCompleted,
      );
      expect(await _memoryStatus(db, memoryId), 'deleted');
      expect(await db.query('archive'), hasLength(1));
      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
    },
  );

  test(
    'duplicate model suggestions reuse one inbox item and respect rejection',
    () async {
      final memoryId = await _insertMemory(db, 'char-a', '同一條記憶');
      Future<String?> propose() => MemoryGuardService.proposeDelete(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [memoryId],
      );

      final first = await propose();
      final duplicate = await propose();
      expect(duplicate, first);
      expect(await MemoryGuardService.listForReview('char-a'), hasLength(1));

      await MemoryGuardService.reject(first!, 'char-a');
      expect(await propose(), isNull);
      expect(await _memoryStatus(db, memoryId), 'active');
    },
  );

  test(
    'rejected paraphrased model suggestion does not return to review',
    () async {
      final first = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '偏好',
          content: '小禾喜歡在下雨天留在家裡看電影',
          confidence: 'high',
          triggers: '下雨天,電影',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      expect(first.disposition, GuardedMemoryWriteDisposition.proposalCreated);
      await MemoryGuardService.reject(first.proposalId!, 'char-a');
      expect(await db.query('memory_rejection_tombstones'), hasLength(1));
      await db.delete(
        'pending_memory_actions',
        where: 'id = ?',
        whereArgs: <Object?>[first.proposalId],
      );

      final paraphrase = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '偏好',
          content: '小禾喜歡下雨天留在家裡看電影',
          confidence: 'high',
          triggers: '下雨天,電影',
        ),
        source: 'model',
        sourceConversationId: 'conv-b',
      );

      expect(
        paraphrase.disposition,
        GuardedMemoryWriteDisposition.skippedDuplicate,
      );
      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
      expect(await _memoryCount(db), 0);
    },
  );

  test(
    'rejected Chinese fact stays rejected after aliases and expansion',
    () async {
      final first = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '自我揭露',
          content: '[9/25] 小禾四歲時爸爸離開，現在聯繫但不親近，爸爸抱他時會想推開',
          confidence: 'high',
          triggers: '爸爸,推開,四歲',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      await MemoryGuardService.reject(first.proposalId!, 'char-a');

      final returned = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '自我揭露',
          content: '[9/25] 小禾的爸在他四歲時離開，現在仍有聯繫但不親；他爸抱他時，他很不習慣並會想推開',
          confidence: 'high',
          triggers: '爸,四歲,推開',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );

      expect(
        returned.disposition,
        GuardedMemoryWriteDisposition.skippedDuplicate,
      );
      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
    },
  );

  test(
    'added clarification does not turn a rejected paraphrase into conflict',
    () async {
      final first = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '自我揭露',
          content: '顧遠的爸爸很早離開，媽媽獨自養大她，不擁抱也不問感受',
          confidence: 'high',
          triggers: '顧遠媽媽,原生家庭',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      await MemoryGuardService.reject(first.proposalId!, 'char-a');

      final returned = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '自我揭露',
          content: '顧遠的爸走得早（離開，不是去世），媽媽一個人帶大她，從不擁抱，也不詢問她是否開心',
          confidence: 'high',
          triggers: '媽,安靜,家',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );

      expect(
        returned.disposition,
        GuardedMemoryWriteDisposition.skippedDuplicate,
      );
    },
  );

  test('a genuinely opposite fact is not hidden by an old rejection', () async {
    final first = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '偏好',
        content: '顧遠不喜歡榴槤味的甜點',
        confidence: 'high',
        triggers: '榴槤,甜點',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );
    await MemoryGuardService.reject(first.proposalId!, 'char-a');

    final changed = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '偏好',
        content: '顧遠現在喜歡榴槤味的甜點',
        confidence: 'high',
        triggers: '榴槤,甜點',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );

    expect(changed.disposition, GuardedMemoryWriteDisposition.proposalCreated);
    expect(await MemoryGuardService.listForReview('char-a'), hasLength(1));
  });

  test('open model suggestions are deduplicated before review', () async {
    final first = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '中秋節小禾帶月餅和花來，兩人談起各自的原生家庭',
        confidence: 'high',
        triggers: '中秋,月餅,原生家庭',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );
    final rewritten = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '中秋那天，小禾帶著冰皮月餅與花來找顧遠，之後兩人聊了雙方的原生家庭',
        confidence: 'high',
        triggers: '中秋,月餅,原生家庭',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );

    expect(first.disposition, GuardedMemoryWriteDisposition.proposalCreated);
    expect(
      rewritten.disposition,
      GuardedMemoryWriteDisposition.skippedDuplicate,
    );
    expect(await MemoryGuardService.listForReview('char-a'), hasLength(1));
  });

  test(
    'rejection survives category drift and cleans an existing inbox item',
    () async {
      final first = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '偏好',
          content: '[9/20] 小禾喜歡下雨天留在家裡看電影',
          confidence: 'high',
          triggers: '下雨天,電影',
        ),
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      await MemoryGuardService.reject(first.proposalId!, 'char-a');

      final now = DateTime.now().toIso8601String();
      await db.insert('pending_memory_actions', <String, Object?>{
        'id': 'returned-suggestion',
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'mode': 'romance',
        'action': MemoryActionProposal.actionCreate,
        'source': 'model',
        'source_conversation_id': 'conv-b',
        'source_message_id': null,
        'target_ids_json': '[]',
        'payload_json': jsonEncode(<String, Object?>{
          'targets': const <Object?>[],
          'candidate': <String, Object?>{
            'mode': 'romance',
            'category': '重要事件',
            'content': '[9/21] 小禾喜歡下雨天留在家裡看電影',
            'triggers': '下雨天,電影',
            'permanent': false,
          },
          'result': const <String, Object?>{},
        }),
        'base_versions_json': '{}',
        'fingerprint': 'returned-suggestion-fingerprint',
        'status': MemoryActionProposal.statusPending,
        'created_at': now,
        'seen_at': null,
        'resolved_at': null,
        'error': '',
        'result_json': '{}',
      });

      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
      final row = (await db.query(
        'pending_memory_actions',
        where: 'id = ?',
        whereArgs: ['returned-suggestion'],
      )).single;
      expect(row['status'], MemoryActionProposal.statusRejected);
    },
  );

  test('rejected paraphrase survives model category drift', () async {
    final first = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '自我揭露',
        content: '[9/25] 小禾的媽媽今天中秋節塞了他九顆大生蠔，媽媽不知道他來找顧遠',
        confidence: 'high',
        triggers: '生蠔,小禾媽媽',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );
    await MemoryGuardService.reject(first.proposalId!, 'char-a');

    final returned = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '偏好',
        content: '[9/25] 小禾今天來找顧遠之前被他媽塞了九顆大生蠔，顧遠拿來調侃並計算工作量',
        confidence: 'high',
        triggers: '生蠔,媽',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );

    expect(
      returned.disposition,
      GuardedMemoryWriteDisposition.skippedDuplicate,
    );
  });

  test('merge preview strips duplicate-processing narration', () async {
    final firstId = await _insertMemory(db, 'char-a', '小禾答應下次再來');
    final secondId = await _insertMemory(db, 'char-a', '小禾說下次還會再來');
    final rows = await db.query(
      'memories',
      where: 'id IN (?, ?)',
      whereArgs: [firstId, secondId],
      orderBy: 'id ASC',
    );
    await MemoryGuardService.proposeExistingDuplicate(
      characterId: 'char-a',
      mode: 'romance',
      first: Memory.fromMap(rows.first),
      second: Memory.fromMap(rows.last),
      score: 0.97,
      reasons: const ['same promise'],
      mergeResult: const <String, Object?>{
        'category': '約定',
        'content': '小禾答應下次還會再來（重複記憶已合併）',
        'triggers': '下次',
      },
    );

    final proposal = (await MemoryGuardService.listForReview('char-a')).single;
    expect(proposal.mergePreview['content'], '小禾答應下次還會再來');
  });

  test(
    'clear-all rejects only one character review items and suggested links',
    () async {
      final firstId = await _insertMemory(db, 'char-a', '小禾喜歡雨天');
      final secondId = await _insertMemory(db, 'char-a', '小禾喜歡下雨天');
      final thirdId = await _insertMemory(db, 'char-a', '小禾會帶傘');
      final otherId = await _insertMemory(db, 'char-b', '另一個角色的記憶');
      final rows = await db.query(
        'memories',
        where: 'id IN (?, ?)',
        whereArgs: [firstId, secondId],
        orderBy: 'id ASC',
      );
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        firstId,
        secondId,
        relationType: 'duplicate_candidate',
        strength: 0.91,
        status: 'suggested',
        source: 'local_scan',
        reason: 'test',
      );
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        firstId,
        thirdId,
        relationType: 'related',
        strength: 0.8,
        status: 'confirmed',
        source: 'user',
        reason: 'keep',
      );
      await MemoryGuardService.proposeExistingDuplicate(
        characterId: 'char-a',
        mode: 'romance',
        first: Memory.fromMap(rows.first),
        second: Memory.fromMap(rows.last),
        score: 0.91,
        reasons: const ['content_similarity:91'],
      );
      await MemoryGuardService.proposeDelete(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [thirdId],
      );
      await MemoryGuardService.proposeDelete(
        characterId: 'char-b',
        mode: 'romance',
        sourceConversationId: 'conv-b',
        targetIds: [otherId],
      );

      expect(await MemoryGuardService.rejectAllForReview('char-a'), 2);
      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
      expect(await MemoryGuardService.listForReview('char-b'), hasLength(1));
      expect(await _memoryStatus(db, firstId), 'active');
      expect(await _memoryStatus(db, secondId), 'active');
      expect(await _memoryStatus(db, thirdId), 'active');

      final links = await db.query(
        'spider_web_links',
        where: 'character_id = ?',
        whereArgs: ['char-a'],
        orderBy: 'memory_id_2 ASC',
      );
      final suggested = links.singleWhere(
        (row) =>
            row['memory_id_1'] == firstId && row['memory_id_2'] == secondId,
      );
      final confirmed = links.singleWhere(
        (row) => row['memory_id_1'] == firstId && row['memory_id_2'] == thirdId,
      );
      expect(suggested['status'], 'rejected');
      expect(confirmed['status'], 'confirmed');
    },
  );

  test(
    'clear relation suggestions preserves memories and confirmed links',
    () async {
      final firstId = await _insertMemory(db, 'char-a', '搬家前的約定');
      final secondId = await _insertMemory(db, 'char-a', '搬家後的結果');
      final thirdId = await _insertMemory(db, 'char-a', '共同挑選家具');
      final otherFirst = await _insertMemory(db, 'char-b', '另一角色記憶一');
      final otherSecond = await _insertMemory(db, 'char-b', '另一角色記憶二');
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        firstId,
        secondId,
        relationType: 'duplicate_candidate',
        strength: 0.96,
        status: 'suggested',
        source: 'model',
        reason: '待審核',
      );
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        firstId,
        thirdId,
        relationType: 'temporal',
        strength: 0.95,
        status: 'confirmed',
        source: 'user',
        reason: '保留',
      );
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-b',
        otherFirst,
        otherSecond,
        relationType: 'related',
        strength: 0.94,
        status: 'suggested',
        source: 'model',
        reason: '另一角色',
      );
      final rows = await db.query(
        'memories',
        where: 'id IN (?, ?)',
        whereArgs: <Object?>[firstId, secondId],
        orderBy: 'id ASC',
      );
      await MemoryGuardService.proposeExistingDuplicate(
        characterId: 'char-a',
        mode: 'romance',
        first: Memory.fromMap(rows.first),
        second: Memory.fromMap(rows.last),
        score: 0.96,
        reasons: const <String>['model_relation:96'],
      );

      expect(await MemoryGuardService.rejectAllSuggestedRelations('char-a'), 1);
      expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
      expect(await _memoryStatus(db, firstId), 'active');
      expect(await _memoryStatus(db, secondId), 'active');
      expect(await _memoryStatus(db, thirdId), 'active');

      final charALinks = await db.query(
        'spider_web_links',
        where: 'character_id = ?',
        whereArgs: const <Object?>['char-a'],
      );
      expect(
        charALinks.singleWhere(
          (row) => row['relation_type'] == 'duplicate_candidate',
        )['status'],
        'rejected',
      );
      expect(
        charALinks.singleWhere(
          (row) => row['relation_type'] == 'temporal',
        )['status'],
        'confirmed',
      );
      final charBLinks = await DatabaseHelper.getSpiderWebLinks('char-b');
      expect(charBLinks.single['status'], 'suggested');
    },
  );

  test('model curation cannot revive a user-rejected relation', () async {
    final firstId = await _insertMemory(db, 'char-a', '被拒絕的候選一');
    final secondId = await _insertMemory(db, 'char-a', '被拒絕的候選二');
    await DatabaseHelper.upsertSpiderWebRelation(
      'char-a',
      firstId,
      secondId,
      relationType: 'related',
      strength: 0.93,
      status: 'suggested',
      source: 'model',
      reason: '候選',
    );
    final link = (await db.query('spider_web_links')).single;
    await DatabaseHelper.resolveSpiderWebRelation(
      'char-a',
      link['id'] as int,
      confirmed: false,
    );

    expect(
      await DatabaseHelper.upsertSpiderWebRelationDetailed(
        'char-a',
        firstId,
        secondId,
        relationType: 'related',
        strength: 0.99,
        status: 'confirmed',
        source: 'user_curation',
        reason: '模型再次提出',
      ),
      SpiderWebRelationWriteResult.protected,
    );
    expect((await db.query('spider_web_links')).single['status'], 'rejected');
  });

  test(
    'reply review marks visible on-device duplicate proposals as seen',
    () async {
      final firstId = await _insertMemory(db, 'char-a', '相似記憶 A');
      final secondId = await _insertMemory(db, 'char-a', '相似記憶 B');
      final rows = await db.query(
        'memories',
        where: 'id IN (?, ?)',
        whereArgs: [firstId, secondId],
        orderBy: 'id ASC',
      );
      final proposalId = await MemoryGuardService.proposeExistingDuplicate(
        characterId: 'char-a',
        mode: 'romance',
        first: Memory.fromMap(rows.first),
        second: Memory.fromMap(rows.last),
        score: 0.91,
        reasons: const ['content_similarity:91'],
      );

      expect(proposalId, isNotNull);
      expect((await MemoryGuardService.counts('char-a')).unread, 1);
      await MemoryGuardService.markSeen(
        'char-a',
        sourceMessageId: 42,
        includeLocalScan: true,
      );
      expect((await MemoryGuardService.counts('char-a')).unread, 0);
    },
  );

  test(
    'model link proposal creates a confirmed multi-memory web on approval',
    () async {
      final first = await _insertMemory(db, 'char-a', '相關記憶 A');
      final second = await _insertMemory(db, 'char-a', '相關記憶 B');
      final third = await _insertMemory(db, 'char-a', '相關記憶 C');
      final proposalId = await MemoryGuardService.proposeLink(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [first, second, third],
      );

      expect(proposalId, isNotNull);
      expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
      expect(
        await MemoryGuardService.execute(
          proposalId!,
          'char-a',
          linkDecision: MemoryGuardService.linkDecisionConfirm,
        ),
        MemoryActionProposal.statusCompleted,
      );

      final links = await DatabaseHelper.getSpiderWebLinks('char-a');
      expect(links, hasLength(3));
      expect(links.every((link) => link['status'] == 'confirmed'), isTrue);
      expect(links.every((link) => link['source'] == 'user'), isTrue);
    },
  );

  test('deferred model links move into relation suggestions', () async {
    final first = await _insertMemory(db, 'char-a', '相關記憶 A');
    final second = await _insertMemory(db, 'char-a', '相關記憶 B');
    final proposalId = await MemoryGuardService.proposeLink(
      characterId: 'char-a',
      mode: 'romance',
      sourceConversationId: 'conv-a',
      targetIds: [first, second],
    );

    expect(
      await MemoryGuardService.execute(
        proposalId!,
        'char-a',
        linkDecision: MemoryGuardService.linkDecisionDefer,
      ),
      MemoryActionProposal.statusCompleted,
    );
    final link = (await DatabaseHelper.getSpiderWebLinks('char-a')).single;
    expect(link['status'], 'suggested');
    expect(link['source'], 'model');
    expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
  });

  test(
    'merge applies atomically and preserves external spider-web edges',
    () async {
      final first = await _insertMemory(db, 'char-a', '重複片段 A');
      final second = await _insertMemory(db, 'char-a', '重複片段 B');
      final neighbor = await _insertMemory(db, 'char-a', '關聯記憶');
      await DatabaseHelper.insertSpiderWebLink('char-a', first, neighbor);
      expect(
        await DatabaseHelper.upsertSpiderWebRelationDetailed(
          'char-a',
          first,
          neighbor,
          relationType: 'temporal',
          strength: 0.6,
          status: 'suggested',
          source: 'local_scan',
          reason: '同一時段',
        ),
        SpiderWebRelationWriteResult.inserted,
      );
      final temporalLink = (await db.query(
        'spider_web_links',
        where: 'relation_type = ?',
        whereArgs: ['temporal'],
      )).single;
      expect(
        await DatabaseHelper.resolveSpiderWebRelation(
          'char-a',
          temporalLink['id'] as int,
          confirmed: false,
        ),
        isTrue,
      );

      final beforeCount = await _memoryCount(db);
      final proposalId = await MemoryGuardService.proposeMerge(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [first, second],
        category: '重要事件',
        content: '合併後的完整記憶',
        triggers: '完整',
      );

      expect(await _memoryCount(db), beforeCount, reason: '確認前不得先寫入合併結果');
      expect(await _memoryStatus(db, first), 'active');
      expect(await _memoryStatus(db, second), 'active');

      expect(
        await MemoryGuardService.execute(proposalId!, 'char-a'),
        MemoryActionProposal.statusCompleted,
      );

      final mergedRows = await db.query(
        'memories',
        where: 'content = ?',
        whereArgs: ['合併後的完整記憶'],
      );
      expect(mergedRows, hasLength(1));
      final mergedId = mergedRows.single['id'] as int;
      expect(await _memoryStatus(db, first), 'deleted');
      expect(await _memoryStatus(db, second), 'deleted');
      final remappedLinks = await db.query(
        'spider_web_links',
        where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
        whereArgs: [
          'char-a',
          mergedId < neighbor ? mergedId : neighbor,
          mergedId < neighbor ? neighbor : mergedId,
        ],
      );
      expect(remappedLinks, hasLength(2));
      expect(
        remappedLinks.firstWhere(
          (row) => row['relation_type'] == 'related',
        )['status'],
        'confirmed',
      );
      expect(
        remappedLinks.firstWhere(
          (row) => row['relation_type'] == 'temporal',
        )['status'],
        'rejected',
      );
    },
  );

  test(
    'existing duplicate preview and execution keep one record date',
    () async {
      final firstId = await _insertMemory(
        db,
        'char-a',
        '[7/24] 小禾說「是你的我都想要」，兩人決定留下這個孩子。',
      );
      final secondId = await _insertMemory(
        db,
        'char-a',
        '[7/24] 虛擬驗孕呈陽性，小禾接受了這個孩子。',
      );
      final rows = await db.query(
        'memories',
        where: 'id IN (?, ?)',
        whereArgs: [firstId, secondId],
        orderBy: 'id ASC',
      );
      final proposalId = await MemoryGuardService.proposeExistingDuplicate(
        characterId: 'char-a',
        mode: 'romance',
        first: Memory.fromMap(rows.first),
        second: Memory.fromMap(rows.last),
        score: 0.97,
        reasons: const ['model_relation:97'],
        mergeResult: const <String, Object?>{
          'category': '重要事件',
          'content': '[7/24] 小禾接受了虛擬驗孕結果；[7/24] 兩人決定留下這個孩子。',
          'triggers': '孩子,驗孕',
        },
      );

      final preview = (await MemoryGuardService.listForReview(
        'char-a',
      )).single.mergePreview['content'].toString();
      expect(RegExp(r'\[7/24\]').allMatches(preview), hasLength(1));
      expect(preview, startsWith('[7/24] '));

      // Simulate a pending preview written by an older build. Merely opening
      // the review inbox must repair it without touching either source row.
      final actionRow = (await db.query(
        'pending_memory_actions',
        where: 'id = ?',
        whereArgs: [proposalId],
      )).single;
      final payload = Map<String, dynamic>.from(
        jsonDecode(actionRow['payload_json']!.toString()) as Map,
      );
      payload['result'] = <String, Object?>{
        ...Map<String, dynamic>.from(payload['result'] as Map),
        'content': '[7/24] 小禾接受了虛擬驗孕結果；[7/24] 兩人決定留下這個孩子。',
      };
      await db.update(
        'pending_memory_actions',
        {'payload_json': jsonEncode(payload)},
        where: 'id = ?',
        whereArgs: [proposalId],
      );

      final repaired = (await MemoryGuardService.listForReview(
        'char-a',
      )).single.mergePreview['content'].toString();
      expect(RegExp(r'\[7/24\]').allMatches(repaired), hasLength(1));
      expect(await _memoryStatus(db, firstId), 'active');
      expect(await _memoryStatus(db, secondId), 'active');

      expect(
        await MemoryGuardService.execute(proposalId!, 'char-a'),
        MemoryActionProposal.statusCompleted,
      );
      final activeRows = await db.query(
        'memories',
        where: 'character_id = ? AND status = ?',
        whereArgs: ['char-a', 'active'],
      );
      expect(activeRows, hasLength(1));
      expect(
        RegExp(r'\[7/24\]').allMatches(activeRows.single['content'].toString()),
        hasLength(1),
      );
    },
  );

  test(
    'changed target makes proposal stale instead of applying old decision',
    () async {
      final memoryId = await _insertMemory(db, 'char-a', '原內容');
      final proposalId = await MemoryGuardService.proposeDelete(
        characterId: 'char-a',
        mode: 'romance',
        sourceConversationId: 'conv-a',
        targetIds: [memoryId],
      );
      await db.update(
        'memories',
        {'content': '已被其他操作更新', 'updated_at': '2099-01-01T00:00:00.000'},
        where: 'id = ?',
        whereArgs: [memoryId],
      );

      expect(
        await MemoryGuardService.execute(proposalId!, 'char-a'),
        MemoryActionProposal.statusStale,
      );
      expect(await _memoryStatus(db, memoryId), 'active');
      expect(await db.query('archive'), isEmpty);
      final review = await MemoryGuardService.listForReview('char-a');
      expect(review.single.status, MemoryActionProposal.statusStale);
    },
  );

  test('new-memory guard inserts once and skips an exact duplicate', () async {
    Memory candidate() => Memory(
      characterId: 'char-a',
      mode: 'romance',
      category: '偏好',
      content: '[8/6] 小禾喜歡熱牛奶。',
      confidence: 'high',
      triggers: '熱牛奶',
    );

    final results = await Future.wait([
      MemoryGuardService.guardNewMemory(
        candidate: candidate(),
        source: 'memory_ui',
        sourceConversationId: 'conv-a',
      ),
      MemoryGuardService.guardNewMemory(
        candidate: candidate(),
        source: 'memory_ui',
        sourceConversationId: 'conv-a',
      ),
    ]);

    expect(
      results.where(
        (result) =>
            result.disposition == GuardedMemoryWriteDisposition.inserted,
      ),
      hasLength(1),
    );
    expect(
      results.where(
        (result) =>
            result.disposition ==
            GuardedMemoryWriteDisposition.skippedDuplicate,
      ),
      hasLength(1),
    );
    expect(await _memoryCount(db), 1);
  });

  test(
    'possible duplicate waits in inbox and rejection is respected',
    () async {
      final oldId = await _insertMemory(db, 'char-a', '小禾喜歡下雨天窩在家裡慢慢看電影');
      final candidate = Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '小禾喜歡下雨天在家裡看電影',
        confidence: 'high',
        triggers: '下雨天',
      );

      final first = await MemoryGuardService.guardNewMemory(
        candidate: candidate,
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      expect(first.disposition, GuardedMemoryWriteDisposition.proposalCreated);
      expect(first.existingMemoryId, oldId);
      expect(await _memoryCount(db), 1, reason: '確認前候選不得落庫');
      final proposal = (await MemoryGuardService.listForReview(
        'char-a',
      )).single;
      expect(proposal.action, MemoryActionProposal.actionCreate);
      expect(proposal.candidatePreview['content'], candidate.content);
      expect(proposal.duplicateScore, greaterThan(0.60));

      await MemoryGuardService.reject(proposal.id, 'char-a');
      final repeated = await MemoryGuardService.guardNewMemory(
        candidate: candidate,
        source: 'model',
        sourceConversationId: 'conv-a',
      );
      expect(
        repeated.disposition,
        GuardedMemoryWriteDisposition.skippedDuplicate,
      );
      expect(await _memoryCount(db), 1);
    },
  );

  test(
    'use-new decision archives old memory and preserves its web edge',
    () async {
      final oldId = await _insertMemory(db, 'char-a', '小禾每天要吃2顆藥');
      final neighbor = await _insertMemory(db, 'char-a', '提醒小禾照顧身體');
      await DatabaseHelper.insertSpiderWebLink('char-a', oldId, neighbor);
      final guarded = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '重要事件',
          content: '小禾每天要吃3顆藥',
          confidence: 'high',
          triggers: '吃藥',
        ),
        source: 'memory_ui',
      );
      expect(
        guarded.disposition,
        GuardedMemoryWriteDisposition.proposalCreated,
      );

      expect(
        await MemoryGuardService.execute(
          guarded.proposalId!,
          'char-a',
          createDecision: MemoryGuardService.createDecisionUseNew,
        ),
        MemoryActionProposal.statusCompleted,
      );
      expect(await _memoryStatus(db, oldId), 'deleted');
      final replacement = (await db.query(
        'memories',
        where: 'content = ? AND status = ?',
        whereArgs: ['小禾每天要吃3顆藥', 'active'],
      )).single;
      final replacementId = replacement['id'] as int;
      expect(
        await db.query(
          'spider_web_links',
          where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
          whereArgs: [
            'char-a',
            replacementId < neighbor ? replacementId : neighbor,
            replacementId < neighbor ? neighbor : replacementId,
          ],
        ),
        hasLength(1),
      );
    },
  );

  test('merge decision uses reviewed content in one transaction', () async {
    final oldId = await _insertMemory(db, 'char-a', '小禾答應8月10日一起看電影');
    final guarded = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '約定',
        content: '小禾改成8月11日一起看電影',
        confidence: 'high',
        triggers: '看電影',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );
    expect(guarded.disposition, GuardedMemoryWriteDisposition.proposalCreated);

    expect(
      await MemoryGuardService.execute(
        guarded.proposalId!,
        'char-a',
        createDecision: MemoryGuardService.createDecisionMerge,
        createResultOverride: const <String, Object?>{
          'category': '約定',
          'content': '小禾把看電影的約定改到8月11日',
          'triggers': '看電影,8月11日',
        },
      ),
      MemoryActionProposal.statusCompleted,
    );
    expect(await _memoryStatus(db, oldId), 'deleted');
    final merged = await db.query(
      'memories',
      where: 'content = ? AND status = ?',
      whereArgs: ['小禾把看電影的約定改到8月11日', 'active'],
    );
    expect(merged, hasLength(1));
    expect(merged.single['triggers'], '看電影,8月11日');
    expect(await db.query('archive'), hasLength(1));
  });

  test('new model memory stays out of the library until confirmed', () async {
    final guarded = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '偏好',
        content: '小禾喜歡喝熱牛奶',
        confidence: 'high',
        triggers: '熱牛奶',
      ),
      source: 'model',
      sourceConversationId: 'conv-a',
    );

    expect(guarded.disposition, GuardedMemoryWriteDisposition.proposalCreated);
    expect(await _memoryCount(db), 0);

    final proposal = (await MemoryGuardService.listForReview('char-a')).single;
    expect(proposal.targetIds, isEmpty);
    expect(
      await MemoryGuardService.execute(
        proposal.id,
        'char-a',
        createDecision: MemoryGuardService.createDecisionUseNew,
      ),
      MemoryActionProposal.statusCompleted,
    );
    expect(await _memoryCount(db), 1);
  });

  test('accepted RP proposal keeps its RP lane and continuity', () async {
    final guarded = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-red',
        mode: 'story',
        category: '伏筆',
        content: '門後傳來第三個人的腳步聲',
        confidence: 'high',
      ),
      source: 'model',
      sourceConversationId: 'rp-window',
    );
    expect(guarded.disposition, GuardedMemoryWriteDisposition.proposalCreated);

    expect(
      await MemoryGuardService.execute(
        guarded.proposalId!,
        'char-a',
        createDecision: MemoryGuardService.createDecisionUseNew,
      ),
      MemoryActionProposal.statusCompleted,
    );
    final row = (await db.query(
      'memories',
      where: 'content = ?',
      whereArgs: ['門後傳來第三個人的腳步聲'],
    )).single;
    expect(row['context_mode'], 'rp');
    expect(row['continuity_id'], 'route-red');
  });
}

Future<int> _insertMemory(Database db, String characterId, String content) {
  final now = DateTime.utc(2026, 8, 5).toIso8601String();
  return db.insert(
    'memories',
    Memory(
      characterId: characterId,
      mode: 'romance',
      category: '重要事件',
      content: content,
      confidence: 'high',
      createdAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
    ).toMap(),
  );
}

Future<String?> _memoryStatus(Database db, int id) async {
  final rows = await db.query(
    'memories',
    columns: ['status'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.single['status']?.toString();
}

Future<int> _memoryCount(Database db) async {
  final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM memories');
  return rows.single['count'] as int;
}
