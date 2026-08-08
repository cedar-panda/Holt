import 'dart:convert';

import '../memory/database.dart';
import '../models/memory.dart';
import 'api_adapter.dart';
import 'settings/api_settings.dart';
import 'settings/memory_settings.dart';
import 'locale_strings.dart';
import 'token_tracker.dart';
import 'memory_guard_service.dart';
import 'token_estimator.dart';

typedef MemoryCurationBatchProgress =
    void Function(int completedBatches, int totalBatches);

class MemoryCurationResult {
  final int proposedRelations;
  final int createdLinks;
  final int duplicateProposals;

  const MemoryCurationResult({
    required this.proposedRelations,
    required this.createdLinks,
    this.duplicateProposals = 0,
  });
}

/// Explicit, user-triggered memory relation analysis. It shares the summary
/// model selection but never enters chat history or chat StructuredPrompt, so
/// it cannot move or invalidate the conversation cache breakpoint.
class MemoryCurationService {
  static const double minimumRelationScore = 0.92;
  static const int defaultBatchMaxMemories = 32;
  static const int defaultBatchTokenBudget = 6000;

  static const String _systemPrompt = '''
You organize an existing long-term memory graph. Analyze only the supplied memories.
Return strict JSON and no prose:
{"relations":[{"main_id":1,"related_id":2,"score":0.97,"type":"duplicate_candidate","reason":"same promise and date","merge":{"category":"Important Event","content":"[7/24] One complete, coherent memory.","triggers":["promise"]}}]}

Rules:
- Link only memories that clearly describe the same event, entity, preference, promise, or continuing fact.
- type must be related, same_event, temporal, duplicate_candidate, or conflict_update.
- Use duplicate_candidate only when the core fact is effectively repeated.
- Use conflict_update when a number, date, negation, promise, or state has changed.
- Every human-readable string in reason and merge must use output_language.
- score must be 0..1. Omit anything below 0.92.
- main_id is the broader or more durable memory; related_id is the narrower memory.
- A memory may connect to multiple other memories. Return every qualifying pair; never limit a memory to one relation.
- For duplicate_candidate, merge is required. Its content must be one coherent long-term memory that preserves all compatible facts, not two source texts joined together.
- A merge content may contain at most one bracketed record date such as [7/24], placed at the beginning. If the sources share that date, write it only once.
- Never invent a fact or an id. Only return a reviewable merge preview; never claim that a memory was changed or deleted.
- If there is no strong relation, return {"relations":[]}.
''';

  static Future<MemoryCurationResult> analyzeAndLink({
    required String characterId,
    required List<Memory> memories,
    MemoryCurationBatchProgress? onBatchProgress,
    ApiAdapter? adapterOverride,
    String? modelOverride,
    String? providerOverride,
  }) async {
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    if (unique.length < 2) {
      return const MemoryCurationResult(proposedRelations: 0, createdLinks: 0);
    }

    var model = modelOverride?.trim() ?? '';
    if (model.isEmpty) model = await MemorySettings.getSummaryModel();
    if (model.trim().isEmpty) model = await ApiSettings.getModel();
    final provider = providerOverride?.trim().isNotEmpty == true
        ? providerOverride!.trim()
        : await ApiSettings.resolveSummaryModelProvider(model);
    final adapter =
        adapterOverride ?? await ApiSettings.buildAdapterForSummaryModel(model);
    final batches = buildAnalysisBatches(unique.values);
    if (batches.isEmpty) {
      return const MemoryCurationResult(proposedRelations: 0, createdLinks: 0);
    }

    var proposed = 0;
    var created = 0;
    var duplicateProposals = 0;
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      final batch = batches[batchIndex];
      ApiUsage? usage;
      final response = await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content': jsonEncode({
              'output_language': _outputLanguage,
              'batch': {'index': batchIndex + 1, 'total': batches.length},
              'memories': [for (final memory in batch) _memoryPayload(memory)],
            }),
          },
        ],
        model: model,
        systemPrompt: _systemPrompt,
        onUsage: (value) => usage = value,
      );
      if (usage != null) {
        await TokenTracker().recordRealUsage(
          provider: provider,
          model: model,
          usage: usage!,
          characterId: characterId,
        );
      }

      final relations = decodeRelations(
        response,
        allowedIds: batch.map((memory) => memory.id!).toSet(),
      );
      proposed += relations.length;
      for (final relation in relations) {
        final inserted = await DatabaseHelper.upsertSpiderWebRelation(
          characterId,
          relation.mainId,
          relation.relatedId,
          relationType: relation.type,
          strength: relation.score,
          status: 'suggested',
          source: 'model',
          reason: relation.reason,
        );
        if (inserted) created++;
        if (relation.type == 'duplicate_candidate') {
          final first = unique[relation.mainId];
          final second = unique[relation.relatedId];
          if (first != null && second != null) {
            final proposalId =
                await MemoryGuardService.proposeExistingDuplicate(
                  characterId: characterId,
                  mode: first.mode,
                  first: first,
                  second: second,
                  score: relation.score,
                  reasons: <String>[
                    'model_relation:${(relation.score * 100).round()}',
                    if (relation.reason.isNotEmpty) relation.reason,
                  ],
                  mergeResult: relation.mergeResult,
                );
            if (proposalId != null) duplicateProposals++;
          }
        }
      }
      onBatchProgress?.call(batchIndex + 1, batches.length);
    }
    return MemoryCurationResult(
      proposedRelations: proposed,
      createdLinks: created,
      duplicateProposals: duplicateProposals,
    );
  }

  /// Splits an unlimited manual selection into context-safe model requests.
  /// This budget is deliberately independent of the chat memory send limit:
  /// every selected memory appears in exactly one batch.
  static List<List<Memory>> buildAnalysisBatches(
    Iterable<Memory> memories, {
    int maxMemories = defaultBatchMaxMemories,
    int maxEstimatedTokens = defaultBatchTokenBudget,
  }) {
    if (maxMemories < 2) {
      throw ArgumentError.value(maxMemories, 'maxMemories', 'must be >= 2');
    }
    if (maxEstimatedTokens < 1) {
      throw ArgumentError.value(
        maxEstimatedTokens,
        'maxEstimatedTokens',
        'must be positive',
      );
    }
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    }.values.toList(growable: false);
    if (unique.length < 2) return const <List<Memory>>[];

    final batches = <List<Memory>>[];
    var current = <Memory>[];
    var currentTokens = 0;
    for (final memory in unique) {
      final memoryTokens = TokenEstimator.estimate(
        jsonEncode(_memoryPayload(memory)),
      );
      final wouldOverflow =
          current.isNotEmpty &&
          (current.length >= maxMemories ||
              currentTokens + memoryTokens > maxEstimatedTokens);
      // Keep at least two memories together so every request can compare.
      if (wouldOverflow && current.length >= 2) {
        batches.add(current);
        current = <Memory>[];
        currentTokens = 0;
      }
      current.add(memory);
      currentTokens += memoryTokens;
    }
    if (current.isNotEmpty) batches.add(current);

    // Avoid wasting a final one-item request. Move one item from the previous
    // batch when possible; otherwise merge the singleton into it.
    if (batches.length > 1 && batches.last.length == 1) {
      final singleton = batches.removeLast();
      final previous = batches.last;
      if (previous.length > 2) {
        singleton.insert(0, previous.removeLast());
        batches.add(singleton);
      } else {
        previous.addAll(singleton);
      }
    }
    return batches;
  }

  static Map<String, Object?> _memoryPayload(Memory memory) =>
      <String, Object?>{
        'id': memory.id,
        'mode': memory.mode,
        'category': memory.category,
        'content': memory.content,
        'triggers': memory.triggers,
        'mention_count': memory.mentionCount,
        'permanent': memory.isPermanent,
      };

  static String get _outputLanguage => switch (L.locale) {
    'en' => 'English',
    'zh_CN' => 'Simplified Chinese (简体中文)',
    _ => 'Traditional Chinese (繁體中文)',
  };

  static List<MemoryRelationProposal> decodeRelations(
    String response, {
    required Set<int> allowedIds,
  }) {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(response);
    if (match == null) return const [];
    try {
      final decoded = jsonDecode(match.group(0)!);
      if (decoded is! Map || decoded['relations'] is! List) return const [];
      final seen = <String>{};
      final result = <MemoryRelationProposal>[];
      for (final raw in decoded['relations'] as List) {
        if (raw is! Map) continue;
        final main = _asInt(raw['main_id']);
        final related = _asInt(raw['related_id']);
        final score = _asDouble(raw['score']);
        if (main == null || related == null || score == null) continue;
        if (main == related ||
            !allowedIds.contains(main) ||
            !allowedIds.contains(related)) {
          continue;
        }
        if (score < minimumRelationScore || score > 1) continue;
        final low = main < related ? main : related;
        final high = main < related ? related : main;
        if (!seen.add('$low:$high')) continue;
        result.add(
          MemoryRelationProposal(
            mainId: main,
            relatedId: related,
            score: score,
            type: _safeRelationType(raw['type']?.toString()),
            reason: raw['reason']?.toString().trim() ?? '',
            mergeResult: _decodeMergeResult(raw),
          ),
        );
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static Map<String, Object?>? _decodeMergeResult(Map raw) {
    final merge = raw['merge'];
    final source = merge is Map ? merge : raw;
    final content = (source['content'] ?? source['merged_content'])
        ?.toString()
        .trim();
    if (content == null || content.isEmpty) return null;
    final rawTriggers = source['triggers'] ?? source['merged_triggers'];
    final triggers = rawTriggers is List
        ? rawTriggers
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .take(3)
              .join(',')
        : rawTriggers?.toString().trim() ?? '';
    return <String, Object?>{
      'category':
          (source['category'] ?? source['merged_category'])
              ?.toString()
              .trim() ??
          '',
      'content': content,
      'triggers': triggers,
    };
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static String _safeRelationType(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'same_event' => 'same_event',
      'temporal' => 'temporal',
      'duplicate_candidate' => 'duplicate_candidate',
      'conflict_update' => 'conflict_update',
      _ => 'related',
    };
  }
}

class MemoryRelationProposal {
  final int mainId;
  final int relatedId;
  final double score;
  final String type;
  final String reason;
  final Map<String, Object?>? mergeResult;

  const MemoryRelationProposal({
    required this.mainId,
    required this.relatedId,
    required this.score,
    required this.type,
    this.reason = '',
    this.mergeResult,
  });
}
