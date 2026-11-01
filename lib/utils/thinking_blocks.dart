/// Display-only normalization for replies that contain more than one
/// thinking round.
///
/// Some relays retry upstream mid-stream and append the second attempt to the
/// same response, and some models interleave reasoning with content. Both end
/// up as `<think>A</think>v1<think>B</think>v2` (sometimes with an orphan
/// `</think>`). Without this, only the first block is folded and the rest leaks
/// into bubbles as raw text, so the reply looks duplicated.
///
/// Rule: every thinking round is merged into one leading block, and the
/// visible body is the last non-empty segment outside thinking. The stored raw
/// text is never rewritten; callers apply this only when presenting it.
library;

final RegExp _thinkTag = RegExp(
  r'<(/?)(?:think|thinking)\b[^>]*>',
  caseSensitive: false,
);

/// Returns [raw] unchanged unless it holds repeated or malformed thinking
/// tags (two or more opening tags, or a closing tag with no opener).
String collapseRepeatedThinking(String raw) {
  final tags = _thinkTag.allMatches(raw).toList(growable: false);
  if (tags.isEmpty) return raw;

  var opens = 0;
  var depth = 0;
  var orphanClose = false;
  for (final tag in tags) {
    if (tag.group(1)!.isEmpty) {
      opens++;
      depth++;
    } else if (depth == 0) {
      orphanClose = true;
    } else {
      depth--;
    }
  }
  if (opens <= 1 && !orphanClose) return raw;

  final thinking = <String>[];
  final visible = <String>[];
  var inThink = false;
  var cursor = 0;
  for (final tag in tags) {
    final segment = raw.substring(cursor, tag.start).trim();
    final isClose = tag.group(1)!.isNotEmpty;
    if (inThink || (isClose && !inThink)) {
      // Text before an orphan close tag was thinking whose opener got lost.
      if (segment.isNotEmpty) thinking.add(segment);
    } else if (segment.isNotEmpty) {
      visible.add(segment);
    }
    inThink = !isClose;
    cursor = tag.end;
  }
  final tail = raw.substring(cursor).trim();

  if (inThink) {
    // Still streaming (or truncated) inside the latest round: keep it open so
    // callers treat it as unfinished thinking.
    if (tail.isNotEmpty) thinking.add(tail);
    return '<think>${thinking.join('\n\n')}';
  }
  if (tail.isNotEmpty) visible.add(tail);

  final thought = thinking.join('\n\n');
  final body = visible.isEmpty ? '' : visible.last;
  if (thought.isEmpty) return body;
  return body.isEmpty
      ? '<think>$thought</think>'
      : '<think>$thought</think>\n\n$body';
}
