import 'dart:math';

import '../memory/database.dart';
import '../models/memory.dart';
import 'memory_duplicate_detector.dart';
import 'memory_guard_service.dart';

class ExistingMemoryScanResult {
  final int comparedPairs;
  final int suggestedRelations;
  final int duplicateProposals;
  final int conflictRelations;

  const ExistingMemoryScanResult({
    required this.comparedPairs,
    required this.suggestedRelations,
    required this.duplicateProposals,
    required this.conflictRelations,
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
/// It only creates suggested graph relations and review proposals. It never
/// archives, merges, or rewrites a memory automatically.
class ExistingMemoryScanner {
  static const int maxSuggestionsPerRun = 10000;

  static Future<ExistingMemoryScanResult> scan({
    required String characterId,
    required List<Memory> memories,
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
    final decidedPairs = <String>{
      for (final link in priorLinks)
        if (link['status'] == 'confirmed' || link['status'] == 'rejected')
          _pairKey(
            (link['memory_id_1'] as num?)?.toInt(),
            (link['memory_id_2'] as num?)?.toInt(),
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
        if (first.mode != second.mode ||
            decidedPairs.contains(_pairKey(first.id, second.id))) {
          continue;
        }
        compared++;
        final match = MemoryDuplicateDetector.compare(first, second);
        final type = _relationType(match);
        if (type == null) continue;
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
    var conflicts = 0;
    for (final candidate in selected.where(
      (candidate) => !candidate.isDuplicate,
    )) {
      final saved = await DatabaseHelper.upsertSpiderWebRelation(
        characterId,
        candidate.first.id!,
        candidate.second.id!,
        relationType: candidate.type,
        strength: candidate.strength,
        status: 'suggested',
        source: 'local_scan',
        reason: candidate.match.reasons.join(','),
      );
      if (!saved) continue;
      inserted++;
      if (candidate.isConflict) conflicts++;
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
      proposals++;
      for (final candidate in groupCandidates) {
        final saved = await DatabaseHelper.upsertSpiderWebRelation(
          characterId,
          candidate.first.id!,
          candidate.second.id!,
          relationType: candidate.type,
          strength: candidate.strength,
          status: 'suggested',
          source: 'local_scan',
          reason: candidate.match.reasons.join(','),
        );
        if (saved) inserted++;
      }
    }

    return ExistingMemoryScanResult(
      comparedPairs: compared,
      suggestedRelations: inserted,
      duplicateProposals: proposals,
      conflictRelations: conflicts,
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

  static String _pairKey(int? first, int? second) {
    if (first == null || second == null || first == second) return '';
    return first < second ? '$first:$second' : '$second:$first';
  }
}
