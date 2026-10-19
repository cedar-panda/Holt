import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/memory_curation_service.dart';
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

  test('curation decoder rejects hallucinated, weak and duplicate links', () {
    const response = '''```json
{"relations":[
  {"main_id":1,"related_id":2,"score":0.97,"type":"same_event"},
  {"main_id":2,"related_id":1,"score":0.96,"type":"duplicate"},
  {"main_id":1,"related_id":3,"score":0.70,"type":"weak"},
  {"main_id":1,"related_id":999,"score":0.99,"type":"invented"},
  {"main_id":2,"related_id":2,"score":1.0,"type":"self"}
]}
```''';

    final result = MemoryCurationService.decodeRelations(
      response,
      allowedIds: {1, 2, 3},
    );

    expect(result, hasLength(1));
    expect(result.single.mainId, 1);
    expect(result.single.relatedId, 2);
  });

  test('curation decoder accepts a localized coherent merge preview', () {
    const response = '''
{"relations":[{
  "main_id":1,
  "related_id":2,
  "score":0.97,
  "type":"duplicate_candidate",
  "reason":"描述的是同一件事",
  "merge":{
    "category":"重要事件",
    "content":"[7/24] 小禾接受了這個孩子，兩人決定一起留下他。",
    "triggers":["孩子","決定"]
  }
}]}
''';

    final result = MemoryCurationService.decodeRelations(
      response,
      allowedIds: {1, 2},
    );

    expect(result, hasLength(1));
    expect(result.single.type, 'duplicate_candidate');
    expect(result.single.reason, '描述的是同一件事');
    expect(result.single.mergeResult, <String, Object?>{
      'category': '重要事件',
      'content': '[7/24] 小禾接受了這個孩子，兩人決定一起留下他。',
      'triggers': '孩子,決定',
    });
  });

  test(
    'manual curation processes every selected memory across batches',
    () async {
      final adapter = _RecordingAdapter();
      final memories = List<Memory>.generate(
        67,
        (index) => Memory(
          id: index + 1,
          characterId: 'char-a',
          mode: 'romance',
          category: '事件',
          content: '第 ${index + 1} 條記憶內容',
        ),
      );
      final progress = <(int, int)>[];

      final result = await MemoryCurationService.analyzeAndLink(
        characterId: 'char-a',
        memories: memories,
        adapterOverride: adapter,
        modelOverride: 'test-summary-model',
        providerOverride: 'test',
        onBatchProgress: (completed, total) {
          progress.add((completed, total));
        },
      );

      final processedIds = adapter.batches.expand((batch) => batch).toList();
      expect(adapter.batches, hasLength(greaterThan(1)));
      expect(processedIds, List<int>.generate(67, (index) => index + 1));
      expect(processedIds.toSet(), hasLength(67));
      expect(adapter.batches.every((batch) => batch.length >= 2), isTrue);
      expect(progress.last, (adapter.batches.length, adapter.batches.length));
      expect(result.proposedRelations, 0);
    },
  );

  test('manual curation splits daily and RP story scopes', () async {
    final adapter = _RecordingAdapter();
    final memories = <Memory>[
      Memory(
        id: 1,
        characterId: 'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
        mode: 'romance',
        category: '事件',
        content: '日常一',
      ),
      Memory(
        id: 2,
        characterId: 'char-a',
        contextMode: ContextMode.daily,
        continuityId: 'main',
        mode: 'romance',
        category: '事件',
        content: '日常二',
      ),
      Memory(
        id: 3,
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        mode: 'story',
        category: '事件',
        content: '劇情一',
      ),
      Memory(
        id: 4,
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'route-a',
        mode: 'story',
        category: '事件',
        content: '劇情二',
      ),
    ];

    await MemoryCurationService.analyzeAndLink(
      characterId: 'char-a',
      memories: memories,
      adapterOverride: adapter,
      modelOverride: 'test-summary-model',
      providerOverride: 'test',
    );

    expect(adapter.scopes, hasLength(2));
    expect(
      adapter.scopes,
      containsAll(<String>{'daily/main/romance', 'rp/route-a/story'}),
    );
  });
}

class _RecordingAdapter implements ApiAdapter {
  final List<List<int>> batches = <List<int>>[];
  final List<String> scopes = <String>[];

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
    final memories = payload['memories'] as List;
    final scope = payload['scope'];
    if (scope is Map) {
      scopes.add(
        '${scope['context_mode']}/${scope['continuity_id']}/${scope['memory_mode']}',
      );
    }
    batches.add(
      memories
          .map((memory) => ((memory as Map)['id'] as num).toInt())
          .toList(growable: false),
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
