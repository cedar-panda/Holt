import 'dart:math';

import '../memory/database.dart';
import '../models/memory.dart';
import '../models/memory_action_proposal.dart';
import '../models/context_mode.dart';
import 'memory_duplicate_detector.dart';
import 'memory_guard_service.dart';

class ExistingMemoryScanResult {
  final int comparedPairs;
  final int suggestedRelations;
  final int duplicateProposals;
  final int conflictRelations;
  final int mergedGroups;
  final int updatedLinks;
  final int unchangedLinks;
  final int protectedLinks;
  final List<ExistingMemoryRelationReport> relations;

  const ExistingMemoryScanResult({
    required this.comparedPairs,
    required this.suggestedRelations,
    required this.duplicateProposals,
    required this.conflictRelations,
    this.mergedGroups = 0,
    this.updatedLinks = 0,
    this.unchangedLinks = 0,
    this.protectedLinks = 0,
    this.relations = const <ExistingMemoryRelationReport>[],
  });
}

class ExistingMemoryRelationReport {
  final int firstId;
  final int secondId;
  final String type;
  final double strength;
  final String reason;

  const ExistingMemoryRelationReport({
    required this.firstId,
    required this.secondId,
    required this.type,
    required this.strength,
    this.reason = '',
  });
}

class _RelationCandidate {
  final Memory first;
  final Memory second;
  final MemoryDuplicateMatch match;
  final String type;
  final double strength;

  const _RelationCandidate({
    required this.first,
    required this.second,
    required this.match,
    required this.type,
    required this.strength,
  });

  bool get isDuplicate => type == 'duplicate_candidate';
  bool get isConflict => type == 'conflict_update';
}

/// Zero-token scanner for memories already stored on the device.
///
/// Background/default use only creates review suggestions. A user-triggered
/// selected-memory pass may opt into immediate links and duplicate merges;
/// permanent memories still remain protected behind review.
class ExistingMemoryScanner {
  static const int maxSuggestionsPerRun = 10000;

  static Future<ExistingMemoryScanResult> scan({
    required String characterId,
    required List<Memory> memories,
    bool applyImmediately = false,
  }) async {
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null &&
            memory.status == 'active' &&
            memory.characterId == characterId)
          memory.id!: memory,
    };
    final rows = unique.values.toList(growable: false);
    if (rows.length < 2) {
      return const ExistingMemoryScanResult(
        comparedPairs: 0,
        suggestedRelations: 0,
        duplicateProposals: 0,
        conflictRelations: 0,
      );
    }

    final priorLinks = await DatabaseHelper.getSpiderWebLinks(
      characterId,
      includeRejected: true,
    );
    final decidedRelations = <String>{
      for (final link in priorLinks)
        if (link['status'] == 'confirmed' || link['status'] == 'rejected')
          _relationKey(
            (link['memory_id_1'] as num?)?.toInt(),
            (link['memory_id_2'] as num?)?.toInt(),
            link['relation_type']?.toString() ?? 'related',
          ),
    }..remove('');

    final candidates = <_RelationCandidate>[];
    var compared = 0;
    for (var leftIndex = 0; leftIndex < rows.length - 1; leftIndex++) {
      final first = rows[leftIndex];
      for (
        var rightIndex = leftIndex + 1;
        rightIndex < rows.length;
        rightIndex++
      ) {
        final second = rows[rightIndex];
        if (first.contextMode != second.contextMode ||
            first.continuityId != second.continuityId ||
            first.mode != second.mode) {
          continue;
        }
        compared++;
        final match = MemoryDuplicateDetector.compare(first, second);
        final type = _relationType(match);
        if (type == null) continue;
        if (first.contextMode == ContextMode.rp &&
            type != 'duplicate_candidate') {
          continue;
        }
        if (decidedRelations.contains(
          _relationKey(first.id, second.id, type),
        )) {
          continue;
        }
        candidates.add(
          _RelationCandidate(
            first: first,
            second: second,
            match: match,
            type: type,
            strength: _strengthFor(type, match),
          ),
        );
        if (compared % 400 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }

    candidates.sort((left, right) {
      final byRisk = _priority(right.type).compareTo(_priority(left.type));
      if (byRisk != 0) return byRisk;
      return right.strength.compareTo(left.strength);
    });
    final selected = candidates
        .take(maxSuggestionsPerRun)
        .toList(growable: false);

    var inserted = 0;
    var proposals = 0;
    var mergedGroups = 0;
    var conflicts = 0;
    var updated = 0;
    var unchanged = 0;
    var protected = 0;
    for (final candidate in selected.where(
      (candidate) => !candidate.isDuplicate,
    )) {
      final writeResult = await DatabaseHelper.upsertSpiderWebRelationDetailed(
        characterId,
        candidate.first.id!,
        candidate.second.id!,
        relationType: candidate.type,
        strength: candidate.strength,
        status: applyImmediately ? 'confirmed' : 'suggested',
        source: applyImmediately ? 'user_curation' : 'local_scan',
        reason: candidate.match.reasons.join(','),
      );
      switch (writeResult) {
        case SpiderWebRelationWriteResult.inserted:
          inserted++;
          if (candidate.isConflict) conflicts++;
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

    final duplicateCandidates = selected
        .where((candidate) => candidate.isDuplicate)
        .toList(growable: false);
    final duplicateGroups = <Set<int>>[];
    for (final candidate in duplicateCandidates) {
      final pair = {candidate.first.id!, candidate.second.id!};
      final overlapping = duplicateGroups
          .where((group) => group.any(pair.contains))
          .toList(growable: false);
      if (overlapping.isEmpty) {
        duplicateGroups.add(pair);
        continue;
      }
      final merged = <int>{...pair};
      for (final group in overlapping) {
        merged.addAll(group);
        duplicateGroups.remove(group);
      }
      duplicateGroups.add(merged);
    }
    for (final group in duplicateGroups) {
      final groupCandidates = duplicateCandidates
          .where(
            (candidate) =>
                group.contains(candidate.first.id) &&
                group.contains(candidate.second.id),
          )
          .toList(growable: false);
      final groupMemories = group
          .map((id) => unique[id]!)
          .toList(growable: false);
      final score = groupCandidates
          .map((candidate) => candidate.match.contentScore)
          .fold<double>(0, max);
      final reasons = groupCandidates
          .expand((candidate) => candidate.match.reasons)
          .toSet()
          .toList(growable: false);
      final proposalId = await MemoryGuardService.proposeExistingDuplicateGroup(
        characterId: characterId,
        mode: groupMemories.first.mode,
        memories: groupMemories,
        score: score,
        reasons: reasons,
      );
      if (proposalId == null) continue;
      var merged = false;
      if (applyImmediately &&
          !groupMemories.any((memory) => memory.isPermanent)) {
        merged =
            await MemoryGuardService.execute(proposalId, characterId) ==
            MemoryActionProposal.statusCompleted;
      }
      if (merged) {
        mergedGroups++;
      } else {
        proposals++;
      }
      if (merged) continue;
      for (final candidate in groupCandidates) {
        if (candidate.first.contextMode == ContextMode.rp) continue;
        final writeResult =
            await DatabaseHelper.upsertSpiderWebRelationDetailed(
              characterId,
              candidate.first.id!,
              candidate.second.id!,
              relationType: candidate.type,
              strength: candidate.strength,
              status: 'suggested',
              source: 'local_scan',
              reason: candidate.match.reasons.join(','),
            );
        switch (writeResult) {
          case SpiderWebRelationWriteResult.inserted:
            inserted++;
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
    }

    return ExistingMemoryScanResult(
      comparedPairs: compared,
      suggestedRelations: inserted,
      duplicateProposals: proposals,
      conflictRelations: conflicts,
      mergedGroups: mergedGroups,
      updatedLinks: updated,
      unchangedLinks: unchanged,
      protectedLinks: protected,
      relations: <ExistingMemoryRelationReport>[
        for (final candidate in selected)
          ExistingMemoryRelationReport(
            firstId: candidate.first.id!,
            secondId: candidate.second.id!,
            type: candidate.type,
            strength: candidate.strength,
            reason: candidate.match.reasons.join(','),
          ),
      ],
    );
  }

  static String? _relationType(MemoryDuplicateMatch match) {
    if (match.hasConflict &&
        match.contentScore >= 0.70 &&
        (match.categoryScore >= 0.4 || match.triggerScore >= 0.5)) {
      return 'conflict_update';
    }
    if (!match.hasConflict && match.contentScore >= 0.83) {
      return 'duplicate_candidate';
    }
    if (!match.hasConflict &&
        match.categoryScore == 1 &&
        match.contentScore >= 0.78) {
      return 'same_event';
    }
    if (match.triggerScore >= 0.5 &&
        (match.contentScore >= 0.30 || match.categoryScore >= 0.4)) {
      return 'related';
    }
    return null;
  }

  static double _strengthFor(String type, MemoryDuplicateMatch match) {
    final base = switch (type) {
      'duplicate_candidate' => match.contentScore,
      'conflict_update' => match.contentScore,
      'same_event' => match.score,
      _ => match.triggerScore * 0.55 + match.contentScore * 0.45,
    };
    return base.clamp(0.0, 1.0);
  }

  static int _priority(String type) => switch (type) {
    'conflict_update' => 4,
    'duplicate_candidate' => 3,
    'same_event' => 2,
    _ => 1,
  };

  static String _relationKey(int? first, int? second, String type) {
    if (first == null || second == null || first == second) return '';
    final pair = first < second ? '$first:$second' : '$second:$first';
    return '$pair:$type';
  }
}
