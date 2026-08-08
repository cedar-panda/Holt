import 'dart:math';

import '../models/memory.dart';

enum MemoryDuplicateDisposition { newMemory, clearDuplicate, possibleDuplicate }

class MemoryDuplicateMatch {
  final Memory memory;
  final double score;
  final double contentScore;
  final double triggerScore;
  final double categoryScore;
  final bool exactContent;
  final bool hasConflict;
  final bool candidatePermanent;
  final List<String> reasons;

  const MemoryDuplicateMatch({
    required this.memory,
    required this.score,
    required this.contentScore,
    required this.triggerScore,
    required this.categoryScore,
    required this.exactContent,
    required this.hasConflict,
    required this.candidatePermanent,
    required this.reasons,
  });
}

class MemoryDuplicateAssessment {
  final MemoryDuplicateDisposition disposition;
  final List<MemoryDuplicateMatch> matches;

  const MemoryDuplicateAssessment(this.disposition, this.matches);

  MemoryDuplicateMatch? get best => matches.isEmpty ? null : matches.first;
}

/// Local, explainable duplicate detection for memory writes.
///
/// It intentionally does not call an embedding or summary model: every write
/// remains available offline, costs zero tokens, and cannot silently pass just
/// because a provider is unavailable. Only same-character, same-mode active
/// memories should be supplied by the caller.
class MemoryDuplicateDetector {
  static const double possibleThreshold = 0.68;
  static const double clearThreshold = 0.90;

  static MemoryDuplicateAssessment assess(
    Memory candidate,
    Iterable<Memory> existing,
  ) {
    final matches =
        existing
            .where(
              (memory) =>
                  memory.id != null &&
                  memory.characterId == candidate.characterId &&
                  memory.mode == candidate.mode &&
                  memory.status == 'active',
            )
            .map((memory) => compare(candidate, memory))
            .where(
              (match) =>
                  match.score >= possibleThreshold ||
                  match.contentScore >= 0.76,
            )
            .toList()
          ..sort((left, right) {
            final byScore = right.score.compareTo(left.score);
            if (byScore != 0) return byScore;
            return (right.memory.id ?? 0).compareTo(left.memory.id ?? 0);
          });

    final clearIndex = matches.indexWhere(_isClearDuplicate);
    if (clearIndex >= 0) {
      final clear = matches.removeAt(clearIndex);
      matches.insert(0, clear);
      return MemoryDuplicateAssessment(
        MemoryDuplicateDisposition.clearDuplicate,
        List<MemoryDuplicateMatch>.unmodifiable(matches),
      );
    }
    if (matches.isNotEmpty) {
      return MemoryDuplicateAssessment(
        MemoryDuplicateDisposition.possibleDuplicate,
        List<MemoryDuplicateMatch>.unmodifiable(matches),
      );
    }
    return const MemoryDuplicateAssessment(
      MemoryDuplicateDisposition.newMemory,
      <MemoryDuplicateMatch>[],
    );
  }

  static bool _isClearDuplicate(MemoryDuplicateMatch match) {
    if (match.hasConflict ||
        match.memory.isPermanent != match.candidatePermanent) {
      return false;
    }
    if (match.exactContent && match.categoryScore == 1) return true;
    if (match.contentScore >= 0.97 && match.categoryScore == 1) return true;
    return match.score >= clearThreshold &&
        match.contentScore >= 0.94 &&
        match.categoryScore == 1;
  }

  /// Exposes the same explainable pair score to the existing-memory scanner.
  /// Callers still decide whether a relation is only suggested or actionable.
  static MemoryDuplicateMatch compare(Memory candidate, Memory existing) {
    final candidateText = normalizeContent(candidate.content);
    final existingText = normalizeContent(existing.content);
    final exactContent =
        candidateText.isNotEmpty && candidateText == existingText;
    final conflicts = _conflicts(candidateText, existingText);
    final contentScore = _contentSimilarity(candidateText, existingText);
    final triggerScore = _triggerSimilarity(
      candidate.triggers,
      existing.triggers,
    );
    final categoryScore = _categoryCompatibility(
      candidate.category,
      existing.category,
    );
    final score =
        contentScore * 0.70 + triggerScore * 0.20 + categoryScore * 0.10;
    final reasons = <String>[
      if (exactContent) 'exact_content',
      if (!exactContent && contentScore >= 0.76)
        'content_similarity:${(contentScore * 100).round()}',
      if (triggerScore >= 0.5)
        'trigger_overlap:${(triggerScore * 100).round()}',
      if (categoryScore == 1) 'same_category',
      ...conflicts,
      if (candidate.isPermanent != existing.isPermanent) 'permanent_conflict',
    ];
    final match = MemoryDuplicateMatch(
      memory: existing,
      score: score.clamp(0, 1),
      contentScore: contentScore,
      triggerScore: triggerScore,
      categoryScore: categoryScore,
      exactContent: exactContent,
      hasConflict:
          conflicts.isNotEmpty || candidate.isPermanent != existing.isPermanent,
      candidatePermanent: candidate.isPermanent,
      reasons: List<String>.unmodifiable(reasons),
    );
    return match;
  }

  static String normalizeContent(String raw) {
    var value = raw.trim().replaceFirst(
      RegExp(r'^\[(?:\d{1,2}/\d{1,2}|\d{4}-\d{1,2}-\d{1,2})\]\s*'),
      '',
    );
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final normalizedRune = rune >= 0xff01 && rune <= 0xff5e
          ? rune - 0xfee0
          : rune;
      final char = String.fromCharCode(normalizedRune);
      if (RegExp(r'[a-z0-9\u3400-\u9fff]').hasMatch(char)) {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }

  static List<String> _conflicts(String left, String right) {
    final reasons = <String>[];
    const polarityTerms = <String>[
      '不再',
      '不是',
      '不會',
      '不能',
      '不要',
      '沒有',
      '没',
      '不',
      '無',
      '无',
      '拒絕',
      '拒绝',
      '取消',
    ];
    const transitionTerms = <String>[
      '開始',
      '开始',
      '停止',
      '結束',
      '结束',
      '恢復',
      '恢复',
      '分開',
      '分开',
      '和好',
      '改成',
      '變成',
      '变成',
    ];
    Set<String> present(String value, List<String> terms) => {
      for (final term in terms)
        if (value.contains(term)) term,
    };
    if (!_sameSet(
      present(left, polarityTerms),
      present(right, polarityTerms),
    )) {
      reasons.add('negation_conflict');
    }
    if (!_sameSet(
      present(left, transitionTerms),
      present(right, transitionTerms),
    )) {
      reasons.add('state_conflict');
    }
    final leftNumbers = _numbers(left);
    final rightNumbers = _numbers(right);
    if (!_sameSet(leftNumbers, rightNumbers)) {
      reasons.add('number_conflict');
    }
    return reasons;
  }

  static Set<String> _numbers(String value) => RegExp(
    r'\d+(?:\.\d+)?',
  ).allMatches(value).map((match) => match.group(0)!).toSet();

  static bool _sameSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  static double _contentSimilarity(String left, String right) {
    if (left.isEmpty || right.isEmpty) return 0;
    if (left == right) return 1;
    final longest = max(left.length, right.length);
    final edit = 1 - _levenshtein(left, right) / longest;
    final shorter = left.length <= right.length ? left : right;
    final longer = left.length <= right.length ? right : left;
    final containment = longer.contains(shorter)
        ? shorter.length / longer.length
        : 0.0;
    final leftPairs = _bigrams(left);
    final rightPairs = _bigrams(right);
    final intersection = leftPairs.intersection(rightPairs).length;
    final dice = leftPairs.isEmpty || rightPairs.isEmpty
        ? 0.0
        : (2.0 * intersection) / (leftPairs.length + rightPairs.length);
    return max(edit, max(containment, dice)).clamp(0, 1);
  }

  static double _triggerSimilarity(String left, String right) {
    final leftSet = _splitTriggers(left);
    final rightSet = _splitTriggers(right);
    if (leftSet.isEmpty && rightSet.isEmpty) return 0.5;
    if (leftSet.isEmpty || rightSet.isEmpty) return 0;
    final intersection = leftSet.intersection(rightSet).length;
    final union = leftSet.union(rightSet).length;
    return union == 0 ? 0 : intersection / union;
  }

  static Set<String> _splitTriggers(String value) => value
      .split(RegExp(r'[,，、]'))
      .map(normalizeContent)
      .where((trigger) => trigger.isNotEmpty)
      .toSet();

  static double _categoryCompatibility(String left, String right) {
    final a = _canonicalCategory(left);
    final b = _canonicalCategory(right);
    if (a == b) return 1;
    const adjacent = <Set<String>>[
      {'important_event', 'promise'},
      {'emotion', 'preference'},
    ];
    return adjacent.any((pair) => pair.contains(a) && pair.contains(b))
        ? 0.4
        : 0;
  }

  static String _canonicalCategory(String raw) {
    final value = raw.trim().toLowerCase();
    return switch (value) {
      'important event' || '重要事件' => 'important_event',
      'promise' || '約定' || '约定' => 'promise',
      'emotion' || '情緒' || '情绪' => 'emotion',
      'preference' || '偏好' => 'preference',
      'self-disclosure' || 'self disclosure' || '自我揭露' => 'self_disclosure',
      _ => value,
    };
  }

  static Set<String> _bigrams(String value) {
    if (value.isEmpty) return const {};
    if (value.length == 1) return {value};
    return {
      for (var index = 0; index < value.length - 1; index++)
        value.substring(index, index + 2),
    };
  }

  static int _levenshtein(String left, String right) {
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitution =
            left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
            ? 0
            : 1;
        current[rightIndex] = min(
          min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
          previous[rightIndex - 1] + substitution,
        );
      }
      previous = current;
    }
    return previous[right.length];
  }
}
