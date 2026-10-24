import 'dart:collection';

import 'package:flutter/foundation.dart' show immutable;

@immutable
class RecallKeywordMatch {
  final String keyword;
  final int score;

  const RecallKeywordMatch(this.keyword, this.score);
}

/// Provider-independent text matching used by both long-term memories and
/// compressed-summary keyword recall.
class RecallTextMatcher {
  static const int _keywordCacheLimit = 12000;
  static const Set<String> _commonCjkRecallTerms = <String>{
    '我們',
    '我们',
    '你們',
    '你们',
    '他們',
    '他们',
    '她們',
    '她们',
    '自己',
    '大家',
    '人家',
    '這個',
    '这个',
    '那個',
    '那个',
    '一個',
    '一个',
    '現在',
    '现在',
    '剛才',
    '刚才',
    '已經',
    '已经',
    '還是',
    '还是',
    '沒有',
    '没有',
    '不是',
    '就是',
    '只是',
    '但是',
    '可是',
    '因為',
    '因为',
    '所以',
    '如果',
    '然後',
    '然后',
    '而且',
    '或者',
    '可能',
    '應該',
    '应该',
    '可以',
    '需要',
    '覺得',
    '觉得',
    '知道',
    '明白',
    '看看',
    '想想',
    '什麼',
    '什么',
    '怎麼',
    '怎么',
    '為什麼',
    '为什么',
    '哪個',
    '哪个',
    '這樣',
    '这样',
    '那樣',
    '那样',
    '這裡',
    '这里',
    '那裡',
    '那里',
    '有點',
    '有点',
    '一下',
    '一些',
    '一直',
    '真的',
    '其實',
    '其实',
    '好像',
    '比如',
    '例如',
    '關於',
    '关于',
    '目前',
  };
  static final LinkedHashMap<String, List<String>> _keywordCache =
      LinkedHashMap<String, List<String>>();

  /// Bounded terms for relevance ranking. CJK does not have whitespace word
  /// boundaries, so include short 2-4 character windows; longer windows score
  /// higher at the caller and reduce dependence on model-authored triggers.
  static List<String> relevanceTerms(
    String query, {
    int maxTerms = 48,
    bool dropCommonCjkTerms = false,
  }) {
    if (maxTerms <= 0) return const <String>[];
    final normalized = _normalize(query);
    final seen = <String>{};
    final terms = <String>[];

    void add(String value) {
      final term = value.trim();
      if (term.length < 2 ||
          (dropCommonCjkTerms && _commonCjkRecallTerms.contains(term)) ||
          !seen.add(term) ||
          terms.length >= maxTerms) {
        return;
      }
      terms.add(term);
    }

    for (final match in RegExp(r'[a-z0-9]{2,}').allMatches(normalized)) {
      add(match.group(0)!);
    }
    for (final match in RegExp(
      r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]{2,}',
    ).allMatches(normalized)) {
      final chunk = match.group(0)!;
      if (chunk.length <= 8) add(chunk);
      for (final size in const <int>[4, 3, 2]) {
        if (chunk.length < size) continue;
        for (var start = 0; start + size <= chunk.length; start++) {
          add(chunk.substring(start, start + size));
          if (terms.length >= maxTerms) return terms;
        }
      }
    }
    return terms;
  }

  static RecallKeywordMatch? bestKeywordMatch(
    String query,
    String keywordText,
  ) {
    final normalizedQuery = _normalize(query);
    final compactQuery = _compact(normalizedQuery);
    if (compactQuery.isEmpty) return null;

    return _bestKeywordMatchNormalized(
      normalizedQuery: normalizedQuery,
      compactQuery: compactQuery,
      keywords: splitKeywords(keywordText),
    );
  }

  /// Matches several keyword rows while normalizing the query only once.
  /// The returned list keeps the same order and length as [keywordTexts].
  static List<RecallKeywordMatch?> bestKeywordMatches(
    String query,
    Iterable<String> keywordTexts,
  ) {
    final texts = keywordTexts.toList(growable: false);
    final normalizedQuery = _normalize(query);
    final compactQuery = _compact(normalizedQuery);
    if (compactQuery.isEmpty) {
      return List<RecallKeywordMatch?>.filled(texts.length, null);
    }
    return <RecallKeywordMatch?>[
      for (final text in texts)
        _bestKeywordMatchNormalized(
          normalizedQuery: normalizedQuery,
          compactQuery: compactQuery,
          keywords: splitKeywords(text),
        ),
    ];
  }

  static RecallKeywordMatch? _bestKeywordMatchNormalized({
    required String normalizedQuery,
    required String compactQuery,
    required Iterable<String> keywords,
  }) {
    RecallKeywordMatch? best;
    for (final keyword in keywords) {
      final score = _score(
        normalizedQuery: normalizedQuery,
        compactQuery: compactQuery,
        keyword: keyword,
      );
      if (score <= 0 || (best != null && best.score >= score)) continue;
      best = RecallKeywordMatch(keyword, score);
    }
    return best;
  }

  static bool containsPhrase(String text, String phrase) =>
      bestKeywordMatch(text, phrase) != null;

  static List<String> splitKeywords(String raw) {
    final cached = _keywordCache.remove(raw);
    if (cached != null) {
      _keywordCache[raw] = cached;
      return cached;
    }
    final seen = <String>{};
    final result = <String>[];
    for (final group in raw.split(RegExp(r'[,，、;；\n|｜]+'))) {
      final alternatives = group.split(RegExp(r'[=＝/／]+'));
      for (final alternative in alternatives) {
        final candidates = <String>[
          alternative,
          ...RegExp(
            r'[（(]([^）)]+)[）)]',
          ).allMatches(alternative).map((match) => match.group(1) ?? ''),
        ];
        for (var candidate in candidates) {
          candidate = candidate
              .replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ')
              .trim();
          final key = _compact(_normalize(candidate));
          if (!_isUsableKeyword(key) || !seen.add(key)) continue;
          result.add(candidate);
        }
      }
    }
    final stored = List<String>.unmodifiable(result);
    _keywordCache[raw] = stored;
    if (_keywordCache.length > _keywordCacheLimit) {
      _keywordCache.remove(_keywordCache.keys.first);
    }
    return stored;
  }

  static int _score({
    required String normalizedQuery,
    required String compactQuery,
    required String keyword,
  }) {
    final normalizedKeyword = _normalize(keyword);
    final compactKeyword = _compact(normalizedKeyword);
    if (!_isUsableKeyword(compactKeyword)) return 0;

    if (normalizedQuery.contains(normalizedKeyword)) {
      return 1000 + compactKeyword.length.clamp(0, 100);
    }
    if (compactQuery.contains(compactKeyword)) {
      return 900 + compactKeyword.length.clamp(0, 100);
    }

    final keywordWords = normalizedKeyword
        .split(RegExp(r'\s+'))
        .where((word) => word.length >= 2)
        .toList();
    if (keywordWords.length > 1 &&
        keywordWords.every(normalizedQuery.contains)) {
      return 800 + compactKeyword.length.clamp(0, 100);
    }

    // Conservative typo tolerance for Latin product/model names. CJK fuzzy
    // matching is deliberately excluded because one-character differences
    // produce too many unrelated recalls.
    if (RegExp(r'^[a-z0-9]+$').hasMatch(compactKeyword) &&
        compactKeyword.length >= 4) {
      for (final word in normalizedQuery.split(RegExp(r'[^a-z0-9]+'))) {
        if ((word.length - compactKeyword.length).abs() > 1) continue;
        if (_editDistanceAtMostOne(word, compactKeyword)) {
          return 600 + compactKeyword.length.clamp(0, 100);
        }
      }
    }
    return 0;
  }

  static bool _isUsableKeyword(String keyword) {
    if (keyword.isEmpty) return false;
    if (RegExp(
      r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]',
    ).hasMatch(keyword)) {
      return keyword.length >= 2;
    }
    return keyword.length >= 3;
  }

  static String _normalize(String input) {
    final buffer = StringBuffer();
    for (final rune in input.trim().toLowerCase().runes) {
      if (rune == 0x3000) {
        buffer.write(' ');
      } else if (rune >= 0xff01 && rune <= 0xff5e) {
        buffer.writeCharCode(rune - 0xfee0);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _compact(String input) => input.replaceAll(
    RegExp(r'[^a-z0-9\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]+'),
    '',
  );

  static bool _editDistanceAtMostOne(String left, String right) {
    if (left == right) return true;
    if ((left.length - right.length).abs() > 1) return false;
    var i = 0;
    var j = 0;
    var edits = 0;
    while (i < left.length && j < right.length) {
      if (left.codeUnitAt(i) == right.codeUnitAt(j)) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (left.length > right.length) {
        i++;
      } else if (right.length > left.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    if (i < left.length || j < right.length) edits++;
    return edits <= 1;
  }
}
