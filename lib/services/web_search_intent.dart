/// A parsed web-search request and the reply text that is safe to display.
final class WebSearchIntent {
  const WebSearchIntent({required this.query, required this.visibleText});

  /// The first valid query, or `null` when the reply does not request a search.
  final String? query;

  /// The original reply with web-search control blocks removed.
  final String visibleText;
}

/// Parses the two supported web-search control syntaxes without executing them.
abstract final class WebSearchIntentParser {
  static const int maxQueryRunes = 240;

  static final RegExp _queryWhitespace = RegExp(r'\s+', unicode: true);
  static final RegExp _unsafeControls = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u202A-\u202E\u2066-\u2069]',
    unicode: true,
  );

  /// Returns a passive intent. Calling this method never starts a tool.
  static WebSearchIntent parse(String reply) {
    final searchBlocks = _findBlocks(reply, 'search_web');
    final toolBlocks = _findBlocks(reply, 'tool_call');
    final candidates = <_QueryCandidate>[];
    final removalSpans = <_TextSpan>[
      for (final block in searchBlocks) _TextSpan(block.start, block.end),
    ];

    final recognizedBlocks = <_TaggedBlock>[...searchBlocks, ...toolBlocks];
    for (final block in searchBlocks) {
      if (block.isClosed && !_isStructurallyNested(block, recognizedBlocks)) {
        candidates.add(
          _QueryCandidate(offset: block.start, rawQuery: block.body(reply)),
        );
      }
    }

    for (final block in toolBlocks) {
      if (_attributeValue(block.openingTag, 'name')?.trim().toLowerCase() !=
          'web.search') {
        continue;
      }

      removalSpans.add(_TextSpan(block.start, block.end));
      if (!block.isClosed || _isStructurallyNested(block, recognizedBlocks)) {
        continue;
      }

      final body = block.body(reply);
      for (final parameter in _findBlocks(body, 'parameter')) {
        if (!parameter.isClosed ||
            _attributeValue(
                  parameter.openingTag,
                  'name',
                )?.trim().toLowerCase() !=
                'query') {
          continue;
        }
        candidates.add(
          _QueryCandidate(
            offset: block.bodyStart + parameter.start,
            rawQuery: parameter.body(body),
          ),
        );
      }
    }

    candidates.sort((left, right) => left.offset.compareTo(right.offset));
    String? query;
    for (final candidate in candidates) {
      final normalized = _normalizeQuery(candidate.rawQuery);
      if (normalized != null) {
        query = normalized;
        break;
      }
    }

    return WebSearchIntent(
      query: query,
      visibleText: _removeSpans(reply, removalSpans).trim(),
    );
  }

  static String? _normalizeQuery(String rawQuery) {
    final query = rawQuery.trim().replaceAll(_queryWhitespace, ' ');
    if (query.isEmpty ||
        query.runes.length > maxQueryRunes ||
        _unsafeControls.hasMatch(query)) {
      return null;
    }
    return query;
  }

  static bool _isStructurallyNested(
    _TaggedBlock target,
    List<_TaggedBlock> blocks,
  ) {
    for (final block in blocks) {
      if (identical(block, target)) continue;
      if (block.start < target.start && block.end >= target.end) return true;
      if (target.start < block.start && target.end >= block.end) return true;
    }
    return false;
  }

  static String _removeSpans(String text, List<_TextSpan> spans) {
    if (spans.isEmpty) return text;

    spans.sort((left, right) => left.start.compareTo(right.start));
    final merged = <_TextSpan>[];
    for (final span in spans) {
      if (merged.isEmpty || span.start > merged.last.end) {
        merged.add(span);
        continue;
      }
      final previous = merged.removeLast();
      merged.add(
        _TextSpan(
          previous.start,
          span.end > previous.end ? span.end : previous.end,
        ),
      );
    }

    final visible = StringBuffer();
    var cursor = 0;
    for (final span in merged) {
      visible.write(text.substring(cursor, span.start));
      cursor = span.end;
    }
    visible.write(text.substring(cursor));
    return visible.toString();
  }

  static List<_TaggedBlock> _findBlocks(String text, String tagName) {
    final tokens = _findTags(text, tagName);
    final openTags = <_TagToken>[];
    final blocks = <_TaggedBlock>[];

    for (final token in tokens) {
      if (!token.isClosing) {
        if (token.isSelfClosing) {
          blocks.add(
            _TaggedBlock(
              start: token.start,
              bodyStart: token.end,
              bodyEnd: token.end,
              end: token.end,
              openingTag: token.source,
              isClosed: true,
            ),
          );
        } else {
          openTags.add(token);
        }
        continue;
      }

      if (openTags.isEmpty) continue;
      final opening = openTags.removeLast();
      blocks.add(
        _TaggedBlock(
          start: opening.start,
          bodyStart: opening.end,
          bodyEnd: token.start,
          end: token.end,
          openingTag: opening.source,
          isClosed: true,
        ),
      );
    }

    for (final opening in openTags) {
      blocks.add(
        _TaggedBlock(
          start: opening.start,
          bodyStart: opening.end,
          bodyEnd: text.length,
          end: text.length,
          openingTag: opening.source,
          isClosed: false,
        ),
      );
    }
    blocks.sort((left, right) => left.start.compareTo(right.start));
    return blocks;
  }

  static List<_TagToken> _findTags(String text, String tagName) {
    final tokens = <_TagToken>[];
    var cursor = 0;
    while (cursor < text.length) {
      final start = text.indexOf('<', cursor);
      if (start < 0) break;

      var index = start + 1;
      var isClosing = false;
      if (index < text.length && text.codeUnitAt(index) == 0x2F) {
        isClosing = true;
        index++;
      }

      if (!_startsWithTagName(text, index, tagName)) {
        cursor = start + 1;
        continue;
      }
      index += tagName.length;
      if (index < text.length && !_isTagNameBoundary(text.codeUnitAt(index))) {
        cursor = start + 1;
        continue;
      }

      String? quote;
      var end = index;
      for (; end < text.length; end++) {
        final character = text[end];
        if (quote != null) {
          if (character == quote) quote = null;
          continue;
        }
        if (character == '"' || character == "'") {
          quote = character;
        } else if (character == '>') {
          break;
        }
      }
      if (end >= text.length) break;

      final source = text.substring(start, end + 1);
      var slashCheck = source.length - 2;
      while (slashCheck >= 0 && _isWhitespace(source.codeUnitAt(slashCheck))) {
        slashCheck--;
      }
      tokens.add(
        _TagToken(
          start: start,
          end: end + 1,
          source: source,
          isClosing: isClosing,
          isSelfClosing:
              !isClosing &&
              slashCheck >= 0 &&
              source.codeUnitAt(slashCheck) == 0x2F,
        ),
      );
      cursor = end + 1;
    }
    return tokens;
  }

  static bool _startsWithTagName(String text, int start, String tagName) {
    if (start + tagName.length > text.length) return false;
    return text.substring(start, start + tagName.length).toLowerCase() ==
        tagName;
  }

  static bool _isTagNameBoundary(int codeUnit) =>
      _isWhitespace(codeUnit) || codeUnit == 0x2F || codeUnit == 0x3E;

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;

  static String? _attributeValue(String openingTag, String targetName) {
    var index = openingTag.indexOf(RegExp(r'\s'));
    if (index < 0) return null;

    while (index < openingTag.length) {
      while (index < openingTag.length &&
          _isWhitespace(openingTag.codeUnitAt(index))) {
        index++;
      }
      if (index >= openingTag.length ||
          openingTag.codeUnitAt(index) == 0x3E ||
          openingTag.codeUnitAt(index) == 0x2F) {
        return null;
      }

      final nameStart = index;
      while (index < openingTag.length &&
          !_isWhitespace(openingTag.codeUnitAt(index)) &&
          openingTag.codeUnitAt(index) != 0x3D &&
          openingTag.codeUnitAt(index) != 0x3E &&
          openingTag.codeUnitAt(index) != 0x2F) {
        index++;
      }
      final name = openingTag.substring(nameStart, index).toLowerCase();
      while (index < openingTag.length &&
          _isWhitespace(openingTag.codeUnitAt(index))) {
        index++;
      }
      if (index >= openingTag.length || openingTag.codeUnitAt(index) != 0x3D) {
        while (index < openingTag.length &&
            !_isWhitespace(openingTag.codeUnitAt(index)) &&
            openingTag.codeUnitAt(index) != 0x3E) {
          index++;
        }
        continue;
      }

      index++;
      while (index < openingTag.length &&
          _isWhitespace(openingTag.codeUnitAt(index))) {
        index++;
      }
      if (index >= openingTag.length ||
          (openingTag[index] != '"' && openingTag[index] != "'")) {
        return null;
      }

      final quote = openingTag[index++];
      final valueStart = index;
      while (index < openingTag.length && openingTag[index] != quote) {
        index++;
      }
      if (index >= openingTag.length) return null;
      final value = openingTag.substring(valueStart, index);
      index++;
      if (name == targetName.toLowerCase()) return value;
    }
    return null;
  }
}

final class _TaggedBlock {
  const _TaggedBlock({
    required this.start,
    required this.bodyStart,
    required this.bodyEnd,
    required this.end,
    required this.openingTag,
    required this.isClosed,
  });

  final int start;
  final int bodyStart;
  final int bodyEnd;
  final int end;
  final String openingTag;
  final bool isClosed;

  String body(String source) => source.substring(bodyStart, bodyEnd);
}

final class _TagToken {
  const _TagToken({
    required this.start,
    required this.end,
    required this.source,
    required this.isClosing,
    required this.isSelfClosing,
  });

  final int start;
  final int end;
  final String source;
  final bool isClosing;
  final bool isSelfClosing;
}

final class _QueryCandidate {
  const _QueryCandidate({required this.offset, required this.rawQuery});

  final int offset;
  final String rawQuery;
}

final class _TextSpan {
  const _TextSpan(this.start, this.end);

  final int start;
  final int end;
}
