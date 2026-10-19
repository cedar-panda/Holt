import 'dart:convert';

import '../memory/database.dart';
import '../models/memory.dart';
import '../models/memory_action_proposal.dart';
import 'api_adapter.dart';
import 'settings/api_settings.dart';
import 'settings/memory_settings.dart';
import 'locale_strings.dart';
import 'token_tracker.dart';
import 'memory_guard_service.dart';
import 'memory_debug_log.dart';
import 'memory_vector_recall_service.dart';
import 'token_estimator.dart';

typedef MemoryCurationBatchProgress =
    void Function(int completedBatches, int totalBatches);

class MemoryCurationResult {
  final int proposedRelations;
  final int createdLinks;
  final int updatedLinks;
  final int unchangedLinks;
  final int protectedLinks;
  final int duplicateProposals;
  final int mergedGroups;
  final List<MemoryRelationProposal> relations;

  /// Optional one-sentence dream summary extracted from the model response.
  /// Only populated when a dream-specific systemPromptOverride is used.
  final String? dreamSummary;

  const MemoryCurationResult({
    required this.proposedRelations,
    required this.createdLinks,
    this.updatedLinks = 0,
    this.unchangedLinks = 0,
    this.protectedLinks = 0,
    this.duplicateProposals = 0,
    this.mergedGroups = 0,
    this.relations = const <MemoryRelationProposal>[],
    this.dreamSummary,
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
- The merged memory must contain only the memory itself. Never append process notes such as "duplicate memories merged".
- Never invent a fact or an id. Return only merge data; never claim that a memory was changed or deleted.
- Relevant summaries are evidence for checking continuity and source truth. Never create a relation from a summary alone.
- Vector candidates are similarity hints only. Independently decide whether they are actually related, duplicated, updated, or unrelated.
- existing_links contains already stored relations touching this batch. existing_link_memories contains each endpoint once. Use both to avoid redundant or transitive edges and to preserve established context.
- Never return an unchanged confirmed relation from existing_links. Suggested relations may be independently reassessed; return one only when the supplied evidence supports it.
- user_rejected_pairs are explicit user decisions. Never propose those pairs again.
- Do not create a generic related edge merely because two memories share a broad category. The new edge must add information that is not already represented by the supplied existing links.
- When scope.context_mode is rp, return only duplicate_candidate items for memory consolidation. RP memories do not use graph relations.
- If there is no strong relation, return {"relations":[]}.
''';

  static Future<MemoryCurationResult> analyzeAndLink({
    required String characterId,
    required List<Memory> memories,
    MemoryCurationBatchProgress? onBatchProgress,
    ApiAdapter? adapterOverride,
    String? modelOverride,
    String? providerOverride,
    String? systemPromptOverride,
    List<MemoryVectorPairCandidate> vectorCandidates =
        const <MemoryVectorPairCandidate>[],
    bool applyImmediately = false,
    bool persistSuggestions = true,
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
    final scopedGroups = <String, List<Memory>>{};
    for (final memory in unique.values) {
      final key = <String>[
        memory.characterId,
        memory.contextMode.storageValue,
        memory.continuityId,
        memory.mode,
      ].join('\u0000');
      scopedGroups.putIfAbsent(key, () => <Memory>[]).add(memory);
    }
    final batches = <List<Memory>>[
      for (final group in scopedGroups.values)
        ...buildAnalysisBatches(
          _orderByVectorClusters(group, vectorCandidates),
        ),
    ];
    if (batches.isEmpty) {
      return const MemoryCurationResult(proposedRelations: 0, createdLinks: 0);
    }

    var proposed = 0;
    var created = 0;
    var updated = 0;
    var unchanged = 0;
    var protected = 0;
    var duplicateProposals = 0;
    var mergedGroups = 0;
    final relationReports = <MemoryRelationProposal>[];
    String? dreamSummary;
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      final batch = batches[batchIndex];
      final scope = batch.first;
      final summaries = await _summaryEvidence(scope, batch);
      final existingLinkEvidence = await _existingLinkEvidence(scope, batch);
      final allowedIds = batch.map((memory) => memory.id!).toSet();
      final batchVectorCandidates = vectorCandidates
          .where(
            (candidate) =>
                allowedIds.contains(candidate.firstId) &&
                allowedIds.contains(candidate.secondId),
          )
          .toList(growable: false);
      ApiUsage? usage;
      late String response;
      try {
        response = await adapter.sendMessage(
          messages: [
            {
              'role': 'user',
              'content': jsonEncode({
                'output_language': _outputLanguage,
                'batch': {'index': batchIndex + 1, 'total': batches.length},
                'scope': <String, Object?>{
                  'context_mode': scope.contextMode.storageValue,
                  'continuity_id': scope.continuityId,
                  'memory_mode': scope.mode,
                },
                'relevant_summaries': summaries,
                'existing_links': existingLinkEvidence['existing_links'],
                'existing_link_memories':
                    existingLinkEvidence['existing_link_memories'],
                'user_rejected_pairs':
                    existingLinkEvidence['user_rejected_pairs'],
                'vector_candidates': [
                  for (final candidate in batchVectorCandidates)
                    candidate.toPayload(),
                ],
                'memories': [
                  for (final memory in batch) _memoryPayload(memory),
                ],
              }),
            },
          ],
          model: model,
          systemPrompt: systemPromptOverride ?? _systemPrompt,
          onUsage: (value) => usage = value,
        );
      } catch (error) {
        MemoryDebugLog.record(
          stage: 'curation_summary_error',
          contextMode: scope.contextMode.storageValue,
          continuityId: scope.continuityId,
          provider: provider,
          model: model,
          inputCount: batch.length,
          resultIds: allowedIds,
          details: <String, Object?>{
            'summary_count': summaries.length,
            'existing_link_count':
                (existingLinkEvidence['existing_links'] as List).length,
            'rejected_pair_count':
                (existingLinkEvidence['user_rejected_pairs'] as List).length,
            'vector_pairs': batchVectorCandidates.length,
          },
          error: error,
        );
        rethrow;
      }
      await TokenTracker().recordRealUsage(
        provider: provider,
        model: model,
        usage: usage ?? const ApiUsage(),
        characterId: characterId,
        requestKind: ApiRequestKind.memory,
      );

      final decodedRelations = decodeRelations(
        response,
        allowedIds: allowedIds,
      );
      final relations = scope.contextMode.storageValue == 'rp'
          ? decodedRelations
                .where((relation) => relation.type == 'duplicate_candidate')
                .toList(growable: false)
          : decodedRelations;
      relationReports.addAll(relations);
      dreamSummary ??= extractDreamSummary(response);
      proposed += relations.length;
      if (applyImmediately) {
        final applied = await _applyReviewedRelations(
          characterId: characterId,
          memories: batch,
          relations: relations,
        );
        created += applied.confirmedLinks;
        updated += applied.updatedLinks;
        unchanged += applied.unchangedLinks;
        protected += applied.protectedLinks;
        duplicateProposals += applied.protectedProposals;
        mergedGroups += applied.mergedGroups;
      } else if (persistSuggestions) {
        for (final relation in relations) {
          if (scope.contextMode.storageValue != 'rp') {
            final writeResult =
                await DatabaseHelper.upsertSpiderWebRelationDetailed(
                  characterId,
                  relation.mainId,
                  relation.relatedId,
                  relationType: relation.type,
                  strength: relation.score,
                  status: 'suggested',
                  source: 'model',
                  reason: relation.reason,
                );
            switch (writeResult) {
              case SpiderWebRelationWriteResult.inserted:
                created++;
              case SpiderWebRelationWriteResult.updated:
                updated++;
              case SpiderWebRelationWriteResult.unchanged:
                unchanged++;
              case SpiderWebRelationWriteResult.protected:
                protected++;
              case SpiderWebRelationWriteResult.invalid:
                break;
            }
          }
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
      }
      MemoryDebugLog.record(
        stage: scope.contextMode.storageValue == 'rp'
            ? 'rp_merge_review'
            : 'daily_link_review',
        contextMode: scope.contextMode.storageValue,
        continuityId: scope.continuityId,
        provider: provider,
        model: model,
        inputCount: batch.length,
        resultIds: relations
            .expand((relation) => <int>[relation.mainId, relation.relatedId])
            .toSet(),
        details: <String, Object?>{
          'summary_count': summaries.length,
          'existing_link_count':
              (existingLinkEvidence['existing_links'] as List).length,
          'rejected_pair_count':
              (existingLinkEvidence['user_rejected_pairs'] as List).length,
          'vector_pairs': batchVectorCandidates.length,
          'relations': relations.length,
          'created_links': created,
          'updated_links': updated,
          'unchanged_links': unchanged,
          'protected_links': protected,
          'duplicates': relations
              .where((relation) => relation.type == 'duplicate_candidate')
              .length,
        },
      );
      onBatchProgress?.call(batchIndex + 1, batches.length);
    }
    return MemoryCurationResult(
      proposedRelations: proposed,
      createdLinks: created,
      updatedLinks: updated,
      unchangedLinks: unchanged,
      protectedLinks: protected,
      duplicateProposals: duplicateProposals,
      mergedGroups: mergedGroups,
      relations: List<MemoryRelationProposal>.unmodifiable(relationReports),
      dreamSummary: dreamSummary,
    );
  }

  /// Applies exactly the relations that were already shown to the user.
  /// Analysis itself stays read-only; this is the sole mutation boundary for
  /// the manual curation preview flow.
  static Future<MemoryCurationResult> applyReviewedRelations({
    required String characterId,
    required List<Memory> memories,
    required List<MemoryRelationProposal> relations,
  }) async {
    final applied = await _applyReviewedRelations(
      characterId: characterId,
      memories: memories,
      relations: relations,
    );
    return MemoryCurationResult(
      proposedRelations: relations.length,
      createdLinks: applied.confirmedLinks,
      updatedLinks: applied.updatedLinks,
      unchangedLinks: applied.unchangedLinks,
      protectedLinks: applied.protectedLinks,
      duplicateProposals: applied.protectedProposals,
      mergedGroups: applied.mergedGroups,
      relations: List<MemoryRelationProposal>.unmodifiable(relations),
    );
  }

  static Future<
    ({
      int confirmedLinks,
      int updatedLinks,
      int unchangedLinks,
      int protectedLinks,
      int mergedGroups,
      int protectedProposals,
    })
  >
  _applyReviewedRelations({
    required String characterId,
    required List<Memory> memories,
    required List<MemoryRelationProposal> relations,
  }) async {
    final byId = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    var confirmedLinks = 0;
    var updatedLinks = 0;
    var unchangedLinks = 0;
    var protectedLinks = 0;
    for (final relation in relations.where(
      (relation) => relation.type != 'duplicate_candidate',
    )) {
      final writeResult = await DatabaseHelper.upsertSpiderWebRelationDetailed(
        characterId,
        relation.mainId,
        relation.relatedId,
        relationType: relation.type,
        strength: relation.score,
        status: 'confirmed',
        source: 'user_curation',
        reason: relation.reason,
      );
      switch (writeResult) {
        case SpiderWebRelationWriteResult.inserted:
          confirmedLinks++;
        case SpiderWebRelationWriteResult.updated:
          updatedLinks++;
        case SpiderWebRelationWriteResult.unchanged:
          unchangedLinks++;
        case SpiderWebRelationWriteResult.protected:
          protectedLinks++;
        case SpiderWebRelationWriteResult.invalid:
          break;
      }
    }

    final duplicateRelations = relations
        .where((relation) => relation.type == 'duplicate_candidate')
        .toList(growable: false);
    final components = <Set<int>>[];
    for (final relation in duplicateRelations) {
      final pair = <int>{relation.mainId, relation.relatedId};
      final overlapping = components
          .where((component) => component.any(pair.contains))
          .toList(growable: false);
      if (overlapping.isEmpty) {
        components.add(pair);
        continue;
      }
      final merged = <int>{...pair};
      for (final component in overlapping) {
        merged.addAll(component);
        components.remove(component);
      }
      components.add(merged);
    }

    var mergedGroups = 0;
    var protectedProposals = 0;
    for (final component in components) {
      final group = component
          .map((id) => byId[id])
          .whereType<Memory>()
          .toList(growable: false);
      if (group.length < 2) continue;
      final groupRelations =
          duplicateRelations
              .where(
                (relation) =>
                    component.contains(relation.mainId) &&
                    component.contains(relation.relatedId),
              )
              .toList(growable: false)
            ..sort((left, right) => right.score.compareTo(left.score));
      final best = groupRelations.first;
      final proposalId = await MemoryGuardService.proposeExistingDuplicateGroup(
        characterId: characterId,
        mode: group.first.mode,
        memories: group,
        score: best.score,
        reasons: <String>[
          for (final relation in groupRelations) ...[
            'model_relation:${(relation.score * 100).round()}',
            if (relation.reason.isNotEmpty) relation.reason,
          ],
        ],
        mergeResult: best.mergeResult,
      );
      if (proposalId == null) continue;
      if (group.any((memory) => memory.isPermanent)) {
        protectedProposals++;
        continue;
      }
      final status = await MemoryGuardService.execute(
        proposalId,
        characterId,
        mergeResultOverride: best.mergeResult,
      );
      if (status == MemoryActionProposal.statusCompleted) {
        mergedGroups++;
      } else {
        protectedProposals++;
      }
    }
    return (
      confirmedLinks: confirmedLinks,
      updatedLinks: updatedLinks,
      unchangedLinks: unchangedLinks,
      protectedLinks: protectedLinks,
      mergedGroups: mergedGroups,
      protectedProposals: protectedProposals,
    );
  }

  static List<Memory> _orderByVectorClusters(
    List<Memory> memories,
    List<MemoryVectorPairCandidate> candidates,
  ) {
    final byId = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    final adjacency = <int, Set<int>>{};
    for (final candidate in candidates) {
      if (!byId.containsKey(candidate.firstId) ||
          !byId.containsKey(candidate.secondId)) {
        continue;
      }
      adjacency
          .putIfAbsent(candidate.firstId, () => <int>{})
          .add(candidate.secondId);
      adjacency
          .putIfAbsent(candidate.secondId, () => <int>{})
          .add(candidate.firstId);
    }
    final ordered = <Memory>[];
    final visited = <int>{};
    for (final start in adjacency.keys) {
      if (!visited.add(start)) continue;
      final queue = <int>[start];
      while (queue.isNotEmpty) {
        final id = queue.removeAt(0);
        final memory = byId[id];
        if (memory != null) ordered.add(memory);
        for (final next in adjacency[id] ?? const <int>{}) {
          if (visited.add(next)) queue.add(next);
        }
      }
    }
    for (final memory in memories) {
      if (memory.id == null || visited.add(memory.id!)) ordered.add(memory);
    }
    return ordered;
  }

  static Future<List<Map<String, Object?>>> _summaryEvidence(
    Memory scope,
    List<Memory> batch,
  ) async {
    late List<Map<String, dynamic>> rows;
    try {
      rows = await DatabaseHelper.getRelevantContextSummaries(
        scope.characterId,
        contextMode: scope.contextMode,
        continuityId: scope.continuityId,
        sourceConversationIds: batch
            .map((memory) => memory.sourceConversationId ?? '')
            .where((id) => id.isNotEmpty),
        limit: 3,
      );
    } catch (error) {
      MemoryDebugLog.record(
        stage: 'curation_summary_lookup_fallback',
        contextMode: scope.contextMode.storageValue,
        continuityId: scope.continuityId,
        inputCount: batch.length,
        error: error,
      );
      return const <Map<String, Object?>>[];
    }
    const budget = 2200;
    var used = 0;
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      final content = row['content']?.toString().trim() ?? '';
      if (content.isEmpty) continue;
      final tokens = TokenEstimator.estimate(content);
      if (result.isNotEmpty && used + tokens > budget) break;
      result.add(<String, Object?>{
        'id': row['id'],
        'source_conversation_id': row['source_conversation_id'] ?? '',
        'content': content,
      });
      used += tokens;
    }
    return result;
  }

  /// Sends the model the already stored graph around the current batch rather
  /// than the character's entire graph. Both endpoint texts are included so
  /// the model can see whether a proposed edge is duplicate, transitive, or a
  /// genuine update. Endpoint content is de-duplicated to keep dense clusters
  /// from repeating the same prose for every edge. Rejected pairs are sent
  /// separately as user decisions.
  static Future<Map<String, List<Map<String, Object?>>>> _existingLinkEvidence(
    Memory scope,
    List<Memory> batch,
  ) async {
    final ids = batch.map((memory) => memory.id).whereType<int>().toList();
    if (ids.isEmpty) {
      return const <String, List<Map<String, Object?>>>{
        'existing_links': <Map<String, Object?>>[],
        'existing_link_memories': <Map<String, Object?>>[],
        'user_rejected_pairs': <Map<String, Object?>>[],
      };
    }
    try {
      final db = await DatabaseHelper.database;
      final placeholders = List<String>.filled(ids.length, '?').join(',');
      final rows = await db.rawQuery(
        '''
        SELECT link.id, link.memory_id_1, link.memory_id_2,
               link.relation_type, link.strength, link.status,
               link.source, link.reason,
               first_memory.mode AS first_mode,
               first_memory.category AS first_category,
               first_memory.content AS first_content,
               first_memory.triggers AS first_triggers,
               second_memory.mode AS second_mode,
               second_memory.category AS second_category,
               second_memory.content AS second_content,
               second_memory.triggers AS second_triggers
        FROM spider_web_links AS link
        INNER JOIN memories AS first_memory
          ON first_memory.id = link.memory_id_1
         AND first_memory.character_id = link.character_id
        INNER JOIN memories AS second_memory
          ON second_memory.id = link.memory_id_2
         AND second_memory.character_id = link.character_id
        WHERE link.character_id = ?
          AND (link.memory_id_1 IN ($placeholders)
               OR link.memory_id_2 IN ($placeholders))
          AND first_memory.context_mode = ?
          AND second_memory.context_mode = ?
          AND first_memory.continuity_id = ?
          AND second_memory.continuity_id = ?
          AND first_memory.mode = ?
          AND second_memory.mode = ?
        ORDER BY CASE link.status
                   WHEN 'confirmed' THEN 0
                   WHEN 'suggested' THEN 1
                   ELSE 2
                 END,
                 link.strength DESC,
                 link.id ASC
        ''',
        <Object?>[
          scope.characterId,
          ...ids,
          ...ids,
          scope.contextMode.storageValue,
          scope.contextMode.storageValue,
          scope.continuityId,
          scope.continuityId,
          scope.mode,
          scope.mode,
        ],
      );
      final existing = <Map<String, Object?>>[];
      final linkedMemories = <int, Map<String, Object?>>{};
      final rejected = <Map<String, Object?>>[];
      for (final row in rows) {
        final firstId = row['memory_id_1'];
        final secondId = row['memory_id_2'];
        if (firstId is! int || secondId is! int) continue;
        if (row['status'] == 'rejected') {
          rejected.add(<String, Object?>{
            'memory_id_1': firstId,
            'memory_id_2': secondId,
            'relation_type': row['relation_type'] ?? 'related',
          });
          continue;
        }
        existing.add(<String, Object?>{
          'memory_id_1': firstId,
          'memory_id_2': secondId,
          'relation_type': row['relation_type'] ?? 'related',
          'strength': row['strength'] ?? 0,
          'status': row['status'] ?? 'confirmed',
          'source': row['source'] ?? 'legacy',
          'reason': row['reason'] ?? '',
        });
        linkedMemories[firstId] = <String, Object?>{
          'id': firstId,
          'mode': row['first_mode'] ?? '',
          'category': row['first_category'] ?? '',
          'content': row['first_content'] ?? '',
          'triggers': row['first_triggers'] ?? '',
        };
        linkedMemories[secondId] = <String, Object?>{
          'id': secondId,
          'mode': row['second_mode'] ?? '',
          'category': row['second_category'] ?? '',
          'content': row['second_content'] ?? '',
          'triggers': row['second_triggers'] ?? '',
        };
      }
      return <String, List<Map<String, Object?>>>{
        'existing_links': existing,
        'existing_link_memories': linkedMemories.values.toList(growable: false),
        'user_rejected_pairs': rejected,
      };
    } catch (error) {
      MemoryDebugLog.record(
        stage: 'curation_existing_links_fallback',
        contextMode: scope.contextMode.storageValue,
        continuityId: scope.continuityId,
        inputCount: batch.length,
        error: error,
      );
      return const <String, List<Map<String, Object?>>>{
        'existing_links': <Map<String, Object?>>[],
        'existing_link_memories': <Map<String, Object?>>[],
        'user_rejected_pairs': <Map<String, Object?>>[],
      };
    }
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

  /// Extract the optional `dream_summary` string from a model response.
  /// Returns null if not present or empty.
  static String? extractDreamSummary(String response) {
    final match = RegExp(r'\{[\s\S]*\}').firstMatch(response);
    if (match == null) return null;
    try {
      final decoded = jsonDecode(match.group(0)!);
      if (decoded is! Map) return null;
      final summary = decoded['dream_summary']?.toString().trim();
      return (summary != null && summary.isNotEmpty) ? summary : null;
    } catch (_) {
      return null;
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
