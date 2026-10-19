import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/memory_curation_service.dart';
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

  test('manual model curation applies links and duplicate merges', () async {
    final first = await _insert(db, '小禾答應下雨天一起看電影');
    final second = await _insert(db, '下雨天時小禾答應一起看電影');
    final third = await _insert(db, '小禾準備了電影票');

    final result = await MemoryCurationService.analyzeAndLink(
      characterId: 'char-a',
      memories: [first, second, third],
      adapterOverride: const _RelationAdapter(),
      modelOverride: 'test-summary-model',
      providerOverride: 'test',
      applyImmediately: true,
    );

    expect(result.mergedGroups, 1);
    expect(result.duplicateProposals, 0);
    expect(result.createdLinks, 1);
    expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
    final active = await db.query(
      'memories',
      where: 'character_id = ? AND status = ?',
      whereArgs: ['char-a', 'active'],
    );
    expect(active, hasLength(2));
    final links = await DatabaseHelper.getSpiderWebLinks('char-a');
    expect(links, hasLength(1));
    expect(links.single['status'], 'confirmed');
  });

  test('manual model curation preview is fully read-only', () async {
    final first = await _insert(db, '小禾答應下雨天一起看電影');
    final second = await _insert(db, '下雨天時小禾答應一起看電影');
    final third = await _insert(db, '小禾準備了電影票');

    final result = await MemoryCurationService.analyzeAndLink(
      characterId: 'char-a',
      memories: [first, second, third],
      adapterOverride: const _RelationAdapter(),
      modelOverride: 'test-summary-model',
      providerOverride: 'test',
      applyImmediately: false,
      persistSuggestions: false,
    );

    expect(result.relations, hasLength(2));
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
    expect(await MemoryGuardService.listForReview('char-a'), isEmpty);
    final active = await db.query(
      'memories',
      where: 'character_id = ? AND status = ?',
      whereArgs: ['char-a', 'active'],
    );
    expect(active, hasLength(3));
  });

  test('RP curation merges duplicates without creating graph links', () async {
    final first = await _insert(
      db,
      '許清川在渡口接過青鸞印信',
      contextMode: ContextMode.rp,
      continuityId: 'route-a',
    );
    final second = await _insert(
      db,
      '渡口相遇時，許清川收下青鸞印信',
      contextMode: ContextMode.rp,
      continuityId: 'route-a',
    );
    final third = await _insert(
      db,
      '顧遠在藥鋪等待回覆',
      contextMode: ContextMode.rp,
      continuityId: 'route-a',
    );

    final result = await MemoryCurationService.analyzeAndLink(
      characterId: 'char-a',
      memories: [first, second, third],
      adapterOverride: const _RelationAdapter(),
      modelOverride: 'test-summary-model',
      providerOverride: 'test',
      applyImmediately: true,
    );

    expect(result.mergedGroups, 1);
    expect(result.createdLinks, 0);
    expect(await DatabaseHelper.getSpiderWebLinks('char-a'), isEmpty);
  });

  test(
    'model review receives existing linked content and rejected pairs',
    () async {
      final first = await _insert(db, '小禾準備搬家');
      final second = await _insert(db, '小禾整理了紙箱');
      final linked = await _insert(db, '小禾隔天正式搬進來');
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        first.id!,
        linked.id!,
        relationType: 'temporal',
        strength: 0.95,
        status: 'confirmed',
        source: 'user',
        reason: '搬家前後延續',
      );
      await DatabaseHelper.upsertSpiderWebRelation(
        'char-a',
        first.id!,
        second.id!,
        relationType: 'related',
        strength: 0.93,
        status: 'suggested',
        source: 'model',
        reason: '候選',
      );
      final suggested = (await db.query(
        'spider_web_links',
        where: 'memory_id_1 = ? AND memory_id_2 = ? AND relation_type = ?',
        whereArgs: <Object?>[first.id, second.id, 'related'],
      )).single;
      await DatabaseHelper.resolveSpiderWebRelation(
        'char-a',
        suggested['id'] as int,
        confirmed: false,
      );

      final adapter = _PayloadAdapter();
      await MemoryCurationService.analyzeAndLink(
        characterId: 'char-a',
        memories: <Memory>[first, second],
        adapterOverride: adapter,
        modelOverride: 'test-summary-model',
        providerOverride: 'test',
      );

      final existing = adapter.payload['existing_links'] as List;
      final linkedMemories = adapter.payload['existing_link_memories'] as List;
      final rejected = adapter.payload['user_rejected_pairs'] as List;
      expect(existing, hasLength(1));
      expect((existing.single as Map)['relation_type'], 'temporal');
      expect(
        linkedMemories.where((item) => (item as Map)['content'] == '小禾隔天正式搬進來'),
        hasLength(1),
      );
      expect(rejected, hasLength(1));
      expect((rejected.single as Map)['memory_id_1'], first.id);
      expect((rejected.single as Map)['memory_id_2'], second.id);
    },
  );
}

Future<Memory> _insert(
  Database db,
  String content, {
  ContextMode contextMode = ContextMode.daily,
  String continuityId = 'main',
}) async {
  final memory = Memory(
    characterId: 'char-a',
    contextMode: contextMode,
    continuityId: continuityId,
    mode: 'romance',
    category: '約定',
    content: content,
    confidence: 'high',
    triggers: '下雨天,電影',
  );
  final id = await db.insert('memories', memory.toMap());
  return Memory.fromMap(<String, Object?>{...memory.toMap(), 'id': id});
}

class _RelationAdapter implements ApiAdapter {
  const _RelationAdapter();

  @override
  void cancelActive() {}

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    final payload = jsonDecode(messages.single['content']!) as Map;
    final ids = (payload['memories'] as List)
        .map((memory) => ((memory as Map)['id'] as num).toInt())
        .toList(growable: false);
    return jsonEncode(<String, Object?>{
      'relations': <Object?>[
        <String, Object?>{
          'main_id': ids[0],
          'related_id': ids[1],
          'score': 0.98,
          'type': 'duplicate_candidate',
          'reason': '同一項約定',
          'merge': <String, Object?>{
            'category': '約定',
            'content': '小禾答應下雨天一起看電影',
            'triggers': <String>['下雨天', '電影'],
          },
        },
        <String, Object?>{
          'main_id': ids[0],
          'related_id': ids[2],
          'score': 0.94,
          'type': 'related',
          'reason': '同一場電影約定',
        },
      ],
    });
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) => const Stream<String>.empty();
}

class _PayloadAdapter implements ApiAdapter {
  Map<String, Object?> payload = <String, Object?>{};

  @override
  void cancelActive() {}

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    payload = Map<String, Object?>.from(
      jsonDecode(messages.single['content']!) as Map,
    );
    return '{"relations":[]}';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) => const Stream<String>.empty();
}
