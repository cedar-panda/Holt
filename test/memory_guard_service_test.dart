import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/memory.dart';
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
      expect(
        await db.query(
          'spider_web_links',
          where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
          whereArgs: [
            'char-a',
            mergedId < neighbor ? mergedId : neighbor,
            mergedId < neighbor ? neighbor : mergedId,
          ],
        ),
        hasLength(1),
      );
    },
  );

  test(
    'existing duplicate preview and execution keep one record date',
    () async {
      final firstId = await _insertMemory(
        db,
        'char-a',
        '[7/24] 昭昭說「是你的我都想要」，兩人決定留下這個孩子。',
      );
      final secondId = await _insertMemory(
        db,
        'char-a',
        '[7/24] 虛擬驗孕呈陽性，昭昭接受了這個孩子。',
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
          'content': '[7/24] 昭昭接受了虛擬驗孕結果；[7/24] 兩人決定留下這個孩子。',
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
        'content': '[7/24] 昭昭接受了虛擬驗孕結果；[7/24] 兩人決定留下這個孩子。',
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
      content: '[8/6] 昭昭喜歡熱牛奶。',
      confidence: 'high',
      triggers: '熱牛奶',
    );

    final results = await Future.wait([
      MemoryGuardService.guardNewMemory(
        candidate: candidate(),
        source: 'model',
        sourceConversationId: 'conv-a',
      ),
      MemoryGuardService.guardNewMemory(
        candidate: candidate(),
        source: 'summary',
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
      final oldId = await _insertMemory(db, 'char-a', '昭昭喜歡下雨天窩在家裡慢慢看電影');
      final candidate = Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '昭昭喜歡下雨天在家裡看電影',
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
      final oldId = await _insertMemory(db, 'char-a', '昭昭每天要吃2顆藥');
      final neighbor = await _insertMemory(db, 'char-a', '提醒昭昭照顧身體');
      await DatabaseHelper.insertSpiderWebLink('char-a', oldId, neighbor);
      final guarded = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: 'char-a',
          mode: 'romance',
          category: '重要事件',
          content: '昭昭每天要吃3顆藥',
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
        whereArgs: ['昭昭每天要吃3顆藥', 'active'],
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
    final oldId = await _insertMemory(db, 'char-a', '昭昭答應8月10日一起看電影');
    final guarded = await MemoryGuardService.guardNewMemory(
      candidate: Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '約定',
        content: '昭昭改成8月11日一起看電影',
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
          'content': '昭昭把看電影的約定改到8月11日',
          'triggers': '看電影,8月11日',
        },
      ),
      MemoryActionProposal.statusCompleted,
    );
    expect(await _memoryStatus(db, oldId), 'deleted');
    final merged = await db.query(
      'memories',
      where: 'content = ? AND status = ?',
      whereArgs: ['昭昭把看電影的約定改到8月11日', 'active'],
    );
    expect(merged, hasLength(1));
    expect(merged.single['triggers'], '看電影,8月11日');
    expect(await db.query('archive'), hasLength(1));
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
