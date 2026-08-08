import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/memory_curation_service.dart';

void main() {
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
    "content":"[7/24] 昭昭接受了這個孩子，兩人決定一起留下他。",
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
      'content': '[7/24] 昭昭接受了這個孩子，兩人決定一起留下他。',
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
}

class _RecordingAdapter implements ApiAdapter {
  final List<List<int>> batches = <List<int>>[];

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
