import 'thinking_blocks.dart';

/// Splits one assistant reply into visual chat bubbles without letting a
/// leading thinking block become a standalone bubble.
///
/// Blank lines are canonical. A single-line fallback is used only for a small
/// set of short, plain chat lines; prose, lists, quotes, tables, and code stay
/// intact.
List<String> splitReplyParagraphs(String rawText) {
  final raw = collapseRepeatedThinking(rawText.trim()).trim();
  if (raw.isEmpty) return const <String>[];

  var thinkingPrefix = '';
  var body = raw;
  final openThinking = RegExp(
    r'^\s*<(?:think|thinking)>',
    caseSensitive: false,
  ).firstMatch(raw);
  if (openThinking != null) {
    final closedThinking = RegExp(
      r'^\s*<(?:think|thinking)>[\s\S]*?</(?:think|thinking)>',
      caseSensitive: false,
    ).firstMatch(raw);
    if (closedThinking == null) {
      return <String>[raw];
    }
    thinkingPrefix = closedThinking.group(0)!.trim();
    body = raw.substring(closedThinking.end).trim();
  }

  if (body.isEmpty) {
    return thinkingPrefix.isEmpty ? const <String>[] : <String>[thinkingPrefix];
  }

  var parts = body
      .split(RegExp(r'\n[ \t]*\n+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  if (parts.length == 1 && body.contains('\n')) {
    final lines = body
        .split(RegExp(r'\n+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final looksLikeShortChat =
        lines.length >= 2 &&
        lines.length <= 6 &&
        lines.every((line) => line.length <= 120) &&
        lines.every(
          (line) => !RegExp(r'^(?:[-*+>]\s|#{1,6}\s|```|\|)').hasMatch(line),
        );
    if (looksLikeShortChat) parts = lines;
  }

  if (thinkingPrefix.isNotEmpty && parts.isNotEmpty) {
    parts = <String>['$thinkingPrefix\n${parts.first}', ...parts.skip(1)];
  }
  return parts;
}
