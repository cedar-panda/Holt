import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/memory/spider_web_core.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/memory_action_proposal.dart';
import 'package:project_yanci/services/existing_memory_scanner.dart';
import 'package:project_yanci/services/memory_guard_service.dart';
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
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'existing duplicates become suggestions and never auto-archive',
    () async {
      final memories = <Memory>[
        await _insert(db, '昭昭喜歡在雨天窩在家裡看電影', triggers: '雨天,電影'),
        await _insert(db, '昭昭喜歡雨天在家裡看電影', triggers: '雨天,電影'),
      ];
      final result = await ExistingMemoryScanner.scan(
        characterId: 'char-a',
        memories: memories,
      );
      expect(result.suggestedRelations, 1);
      expect(result.duplicateProposals, 1);
      final relation = (await DatabaseHelper.getSpiderWebLinks(
        'char-a',
      )).single;
      expect(relation['status'], 'suggested');
      expect(relation['relation_type'], 'duplicate_candidate');
      final proposal = (await MemoryGuardService.listForReview(
        'char-a',
      )).single;
      expect(proposal.action, MemoryActionProposal.actionMerge);
      expect(proposal.isExistingDuplicateScan, isTrue);
      expect(proposal.duplicateScore, greaterThan(0.75));
      expect(
        await db.query('memories', where: 'status = ?', whereArgs: ['active']),
        hasLength(2),
      );
      expect(await db.query('archive'), isEmpty);
    },
  );

  test('state reversal is a conflict relation, not a merge proposal', () async {
    final memories = <Memory>[
      await _insert(db, '昭昭現在喜歡喝咖啡', triggers: '咖啡'),
      await _insert(db, '昭昭現在不再喜歡喝咖啡', triggers: '咖啡'),
    ];

    final result = await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: memories,
    );

    expect(result.conflictRelations, 1);
    expect(result.duplicateProposals, 0);
    final relation = (await DatabaseHelper.getSpiderWebLinks('char-a')).single;
    expect(relation['relation_type'], 'conflict_update');
    expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
  });

  test('overlapping duplicate pairs become one grouped proposal', () async {
    final memories = <Memory>[
      await _insert(db, '昭昭喜歡在雨天窩在家裡看電影', triggers: '雨天,電影'),
      await _insert(db, '昭昭喜歡雨天在家裡看電影', triggers: '雨天,電影'),
      await _insert(db, '昭昭很喜歡雨天窩在家裡看電影', triggers: '雨天,電影'),
    ];

    final result = await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: memories,
    );

    expect(result.duplicateProposals, 1);
    final proposals = await MemoryGuardService.listForReview('char-a');
    expect(proposals, hasLength(1));
    expect(proposals.single.targetIds, hasLength(3));
  });

  test('one memory can connect to every qualifying neighbor', () async {
    final memories = <Memory>[
      for (var index = 0; index < 6; index++)
        await _insert(db, '昭昭喜歡雨天看電影', triggers: '雨天,電影'),
    ];

    final result = await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: memories,
    );

    expect(result.suggestedRelations, 15);
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), hasLength(15));
    final firstId = memories.first.id!;
    final firstLinks = (await DatabaseHelper.getSpiderWebLinks('char-a')).where(
      (link) =>
          link['memory_id_1'] == firstId || link['memory_id_2'] == firstId,
    );
    expect(firstLinks, hasLength(5));
  });

  test('older overlapping pair proposals are consolidated safely', () async {
    final memories = <Memory>[
      await _insert(db, '昭昭喜歡在雨天窩在家裡看電影', triggers: '雨天,電影'),
      await _insert(db, '昭昭喜歡雨天在家裡看電影', triggers: '雨天,電影'),
      await _insert(db, '昭昭很喜歡雨天窩在家裡看電影', triggers: '雨天,電影'),
    ];
    await MemoryGuardService.proposeExistingDuplicate(
      characterId: 'char-a',
      mode: 'romance',
      first: memories[0],
      second: memories[1],
      score: 0.95,
      reasons: const ['content_overlap'],
    );
    await MemoryGuardService.proposeExistingDuplicate(
      characterId: 'char-a',
      mode: 'romance',
      first: memories[0],
      second: memories[2],
      score: 0.96,
      reasons: const ['content_overlap'],
    );

    final collapsed =
        await MemoryGuardService.consolidateExistingDuplicateProposals(
          'char-a',
        );

    expect(collapsed, 2);
    final proposals = await MemoryGuardService.listForReview('char-a');
    expect(proposals, hasLength(1));
    expect(proposals.single.targetIds, hasLength(3));
  });

  test('rejected relation is not suggested again on a later scan', () async {
    final memories = <Memory>[
      await _insert(db, '一起照顧家裡的橘貓', triggers: '橘貓'),
      await _insert(db, '記得替橘貓準備晚餐', triggers: '橘貓'),
    ];
    await ExistingMemoryScanner.scan(characterId: 'char-a', memories: memories);
    final relation = (await DatabaseHelper.getSpiderWebLinks('char-a')).single;
    await DatabaseHelper.resolveSpiderWebRelation(
      'char-a',
      relation['id'] as int,
      confirmed: false,
    );

    final repeated = await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: memories,
    );

    expect(repeated.suggestedRelations, 0);
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
    final all = await DatabaseHelper.getSpiderWebLinks(
      'char-a',
      includeRejected: true,
    );
    expect(all.single['status'], 'rejected');
  });

  test('suggested relation can be upgraded to a duplicate proposal', () async {
    final memories = <Memory>[
      await _insert(db, '昭昭喜歡在雨天窩在家裡看電影', triggers: '雨天,電影'),
      await _insert(db, '昭昭喜歡雨天在家裡看電影', triggers: '雨天,電影'),
    ];
    await DatabaseHelper.upsertSpiderWebRelation(
      'char-a',
      memories.first.id!,
      memories.last.id!,
      relationType: 'same_event',
      strength: 0.91,
      status: 'suggested',
      source: 'model',
      reason: 'content_overlap',
    );

    final result = await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: memories,
    );

    expect(result.duplicateProposals, 1);
    final relation = (await DatabaseHelper.getSpiderWebLinks('char-a')).single;
    expect(relation['relation_type'], 'duplicate_candidate');
    expect(relation['source'], 'local_scan');
    expect(await MemoryGuardService.listForReview('char-a'), hasLength(1));
  });

  test(
    '83 percent content similarity enters review across categories',
    () async {
      final memories = <Memory>[
        await _insert(db, '昭昭喜歡電影', triggers: '電影', category: '偏好'),
        await _insert(db, '昭昭喜歡影', triggers: '電影', category: '重要事件'),
      ];

      final result = await ExistingMemoryScanner.scan(
        characterId: 'char-a',
        memories: memories,
      );

      expect(result.duplicateProposals, 1);
      final relation = (await DatabaseHelper.getSpiderWebLinks(
        'char-a',
      )).single;
      expect(relation['relation_type'], 'duplicate_candidate');
      expect(((relation['strength'] as num).toDouble() * 100).round(), 83);
      expect(await MemoryGuardService.listForReview('char-a'), hasLength(1));
    },
  );

  test(
    'new dedupe policy revives a proposal hidden by an older scan',
    () async {
      final memories = <Memory>[
        await _insert(db, '昭昭喜歡電影', triggers: '電影'),
        await _insert(db, '昭昭喜歡影', triggers: '電影'),
      ];
      await ExistingMemoryScanner.scan(
        characterId: 'char-a',
        memories: memories,
      );
      final proposal = (await MemoryGuardService.listForReview(
        'char-a',
      )).single;
      await MemoryGuardService.reject(proposal.id, 'char-a');
      await db.update(
        'pending_memory_actions',
        <String, Object?>{'payload_json': '{"existing_duplicate_scan":true}'},
        where: 'id = ?',
        whereArgs: [proposal.id],
      );

      final repeated = await ExistingMemoryScanner.scan(
        characterId: 'char-a',
        memories: memories,
      );

      expect(repeated.duplicateProposals, 1);
      final revived = (await MemoryGuardService.listForReview('char-a')).single;
      expect(revived.id, proposal.id);
      expect(revived.status, MemoryActionProposal.statusPending);
      expect(revived.duplicateScore, greaterThanOrEqualTo(0.83));
    },
  );

  test('suggested relation never participates in neural propagation', () async {
    final first = await _insert(db, '一起照顧家裡的橘貓', triggers: '橘貓');
    final second = await _insert(db, '記得替橘貓準備晚餐', triggers: '橘貓');
    await ExistingMemoryScanner.scan(
      characterId: 'char-a',
      memories: [first, second],
    );
    final before = (await db.query(
      'memories',
      columns: ['last_accessed'],
      where: 'id = ?',
      whereArgs: [second.id],
    )).single['last_accessed'];

    await SpiderWebCore.triggerMemory(first.id!, characterId: 'char-a');
    final whileSuggested = (await db.query(
      'memories',
      columns: ['last_accessed'],
      where: 'id = ?',
      whereArgs: [second.id],
    )).single['last_accessed'];
    expect(whileSuggested, before);

    final relation = (await DatabaseHelper.getSpiderWebLinks('char-a')).single;
    await DatabaseHelper.resolveSpiderWebRelation(
      'char-a',
      relation['id'] as int,
      confirmed: true,
    );
    await SpiderWebCore.triggerMemory(first.id!, characterId: 'char-a');
    final afterConfirm = (await db.query(
      'memories',
      columns: ['last_accessed'],
      where: 'id = ?',
      whereArgs: [second.id],
    )).single['last_accessed'];
    expect(afterConfirm, isNot(before));
  });
}

Future<Memory> _insert(
  Database db,
  String content, {
  required String triggers,
  String category = '偏好',
}) async {
  final now = DateTime.utc(2026, 8, 6);
  final memory = Memory(
    characterId: 'char-a',
    mode: 'romance',
    category: category,
    content: content,
    confidence: 'high',
    triggers: triggers,
    createdAt: now,
    updatedAt: now,
  );
  final id = await db.insert('memories', memory.toMap());
  return Memory.fromMap(<String, Object?>{...memory.toMap(), 'id': id});
}
