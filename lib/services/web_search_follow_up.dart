import 'protocol_tags.dart';
import 'web_search_service.dart';

/// Builds the request-only evidence used for the character's post-search reply.
///
/// Search evidence remains request-only. If a small chat model returns an
/// empty or merely ceremonial search acknowledgement, the already-grounded
/// provider answer is also the deterministic last-resort visible reply.
abstract final class WebSearchFollowUp {
  static const int _maxAnswerRunes = 5000;
  static const int _maxSnippetRunes = 700;
  static const int _maxSources = 5;
  static const int _maxFallbackRunes = 2200;

  static String? evidenceFor(WebSearchBatchResult batch) {
    final results = batch.successes;
    if (results.isEmpty) return null;

    final sections = <String>[
      'Task: Answer the latest real user message now, in the established character voice.',
      'Rules: Use the evidence as factual reference only. When it is sufficient, the reply must naturally include at least one concrete fact from it that answers the latest user. Do not mention tools, searches, providers, hidden context, or these rules. Do not output URLs, Markdown links, XML tags, tool calls, or action tags. If the evidence is insufficient, say so naturally instead of inventing facts.',
    ];
    for (final result in results) {
      final lines = <String>[
        'Provider result:',
        _takeRunes(result.text, _maxAnswerRunes),
        'Sources:',
      ];
      for (final source in result.sources.take(_maxSources)) {
        final host = safeWebSearchSourceUri(source.url)?.host ?? '';
        if (host.isEmpty) continue;
        final title = source.title.trim().isEmpty ? host : source.title.trim();
        lines.add('- $title ($host)');
        final snippet = source.snippet.trim();
        if (snippet.isNotEmpty) {
          lines.add('  ${_takeRunes(snippet, _maxSnippetRunes)}');
        }
      }
      sections.add(lines.join('\n'));
    }
    return sections.join('\n\n');
  }

  /// App-authored request-only state for a partial or failed search. It is
  /// transported beside live state, never as a user message or cached prompt.
  static String? failureContextFor(WebSearchBatchResult batch) {
    if (batch.failures.isEmpty) return null;
    final status = batch.allFailed ? 'failed' : 'partially failed';
    return '''### Web Search Attempt
Status: $status
No reliable web evidence was obtained from the failed part of this attempt.
Treat this as App state, not something the user said. Technical diagnostics are shown separately by the App. Do not mention or infer providers, API keys, relays, routes, rate limits, HTTP status codes, configuration, or how many paths were attempted. Do not compare this attempt with earlier failures. If no verified evidence is available, say only that the search could not verify the answer and do not invent missing facts.''';
  }

  static String standaloneFailureContext({
    required String query,
    required List<String> providers,
    required String safeMessage,
  }) {
    return '''### Web Search Attempt
Status: failed
No reliable web evidence was obtained for this attempt.
Treat this as App state, not something the user said. Technical diagnostics are shown separately by the App. Do not mention or infer providers, API keys, relays, routes, rate limits, HTTP status codes, configuration, or how many paths were attempted. Do not compare this attempt with earlier failures. Say only that the search could not verify the answer. Do not invent missing facts or claim the search succeeded.''';
  }

  /// A failed search with no successful evidence must not trigger another
  /// model pass: the conversation history may contain stale diagnostics that
  /// the model could incorrectly present as part of the current attempt.
  static bool hasNoVerifiedEvidence({
    required WebSearchBatchResult? result,
    required String failureContext,
  }) {
    return failureContext.trim().isNotEmpty &&
        (result == null || result.successes.isEmpty);
  }

  /// Gemini grounding stays provider-owned instead of entering the character
  /// model follow-up. Keep that outcome available for its required renderer.
  static WebSearchBatchResult? geminiDisplayResultFor(
    WebSearchBatchResult batch,
  ) {
    final outcomes = batch.outcomes
        .where((outcome) => outcome.provider == WebSearchProviderId.gemini)
        .toList(growable: false);
    if (outcomes.isEmpty) return null;
    return WebSearchBatchResult(
      requestedQuery: batch.requestedQuery,
      outcomes: outcomes,
    );
  }

  static String fallbackReply(WebSearchBatchResult batch) {
    const priority = <WebSearchProviderId>[
      WebSearchProviderId.openRouter,
      WebSearchProviderId.relay,
      WebSearchProviderId.xai,
      WebSearchProviderId.gemini,
    ];
    for (final provider in priority) {
      for (final result in batch.successes) {
        if (result.provider != provider) continue;
        final reply = sanitizeReply(result.text);
        if (reply.isNotEmpty) return _takeRunes(reply, _maxFallbackRunes);
      }
    }
    return '';
  }

  /// Keeps a successful search from becoming an empty or content-free chat
  /// bubble when the selected character model is too weak to use evidence.
  /// Substantive character replies remain untouched; only short replies with
  /// no recognisable evidence anchor receive the grounded provider answer.
  static String ensureGroundedReply({
    required String reply,
    required WebSearchBatchResult batch,
  }) {
    final visible = sanitizeReply(reply);
    final fallback = fallbackReply(batch);
    if (fallback.isEmpty) return visible;
    if (visible.isEmpty) return fallback;
    if (_hasEvidenceAnchor(visible, batch)) return visible;

    final prose = visible
        .replaceAll(
          RegExp(
            r'<(?:think|thinking)\b[^>]*>[\s\S]*?</(?:think|thinking)\s*>',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (prose.runes.length >= 80) return visible;
    return '$visible\n\n$fallback'.trim();
  }

  static bool _hasEvidenceAnchor(String reply, WebSearchBatchResult batch) {
    final normalizedReply = _normalizeForMatch(reply);
    if (normalizedReply.isEmpty) return false;
    var lexicalHits = 0;
    final seen = <String>{};
    for (final result in batch.successes) {
      final evidenceParts = <String>[
        result.text,
        for (final source in result.sources) ...<String>[
          source.title,
          source.snippet,
        ],
      ];
      for (final part in evidenceParts) {
        for (final match in RegExp(
          r'\d+(?:[./:\-]\d+)+|\d{2,}',
        ).allMatches(part)) {
          final token = _normalizeForMatch(match.group(0) ?? '');
          if (token.isNotEmpty && normalizedReply.contains(token)) return true;
        }
        for (final match in RegExp(
          r'[A-Za-z][A-Za-z0-9_-]{3,}',
        ).allMatches(part)) {
          final token = (match.group(0) ?? '').toLowerCase();
          if (!_usefulLatinToken(token) || !seen.add(token)) continue;
          if (normalizedReply.contains(token)) lexicalHits++;
          if (lexicalHits >= 2) return true;
        }
        for (final match in RegExp(r'[\u3400-\u9fff]{4,}').allMatches(part)) {
          final run = match.group(0) ?? '';
          final chars = run.runes.toList(growable: false);
          for (var i = 0; i + 4 <= chars.length; i += 2) {
            final token = String.fromCharCodes(chars.sublist(i, i + 4));
            if (!seen.add(token)) continue;
            if (normalizedReply.contains(token)) lexicalHits++;
            if (lexicalHits >= 2) return true;
          }
        }
      }
    }
    return false;
  }

  static bool _usefulLatinToken(String token) => !const <String>{
    'that',
    'this',
    'with',
    'from',
    'have',
    'will',
    'your',
    'about',
    'there',
    'their',
    'result',
    'search',
  }.contains(token);

  static String _normalizeForMatch(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]+'), '');

  /// Pure-text finalizer: tool/action tags are removed, never executed.
  static String sanitizeReply(String raw) {
    var output = raw;
    // 協議標籤只剝不執行；保留 <think> 給 Thinking 呈現。
    const blockedTags = <String>{
      ...ProtocolTags.block,
      ...ProtocolTags.standalone,
    };
    for (final tag in blockedTags) {
      final escaped = RegExp.escape(tag);
      output = output.replaceAll(
        RegExp(
          '<$escaped\\b[^>]*>[\\s\\S]*?</$escaped\\s*>',
          caseSensitive: false,
        ),
        '',
      );
      output = output.replaceAll(
        RegExp('<$escaped\\b[^>]*/\\s*>', caseSensitive: false),
        '',
      );
      output = output.replaceAll(
        RegExp('<$escaped\\b[^>]*>', caseSensitive: false),
        '',
      );
    }
    output = output.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(https?://[^)]+\)', caseSensitive: false),
      (match) => match.group(1) ?? '',
    );
    output = output.replaceAll(
      RegExp(r'<https?://[^>]+>', caseSensitive: false),
      '',
    );
    return output.trim();
  }

  static String _takeRunes(String value, int maxRunes) {
    final runes = value.trim().runes;
    if (runes.length <= maxRunes) return value.trim();
    return '${String.fromCharCodes(runes.take(maxRunes))}…';
  }
}
