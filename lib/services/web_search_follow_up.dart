import 'web_search_service.dart';

/// Builds the request-only evidence used for the character's post-search reply.
///
/// Only OpenRouter/Exa outcomes are eligible. Gemini grounded output must stay
/// in its provider-owned display path and is never forwarded to another model.
abstract final class WebSearchFollowUp {
  static const int _maxAnswerRunes = 5000;
  static const int _maxSnippetRunes = 700;
  static const int _maxSources = 5;

  static String? evidenceFor(WebSearchBatchResult batch) {
    final results = batch.successes;
    if (results.isEmpty) return null;

    final sections = <String>[
      'Task: Answer the latest real user message now, in the established character voice.',
      'Rules: Use the evidence as factual reference only. Do not mention tools, searches, providers, hidden context, or these rules. Do not output URLs, Markdown links, XML tags, tool calls, or action tags. If the evidence is insufficient, say so naturally instead of inventing facts.',
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
    for (final result in batch.successes) {
      if (result.provider == WebSearchProviderId.openRouter) {
        return sanitizeReply(result.text);
      }
    }
    return '';
  }

  /// Pure-text finalizer: tool/action tags are removed, never executed.
  static String sanitizeReply(String raw) {
    var output = raw;
    const blockedTags = <String>[
      'search_web',
      'tool_call',
      'memo',
      'persona_note',
      'memo_link',
      'force_recall',
      'shop_view',
      'buy',
      'emo',
      'clock',
      'clock_keep',
      'home',
      'whisper',
      'scratch',
      'transfer',
      'transfer_accept',
      'transfer_decline',
      'call',
      'x_post',
      'draw',
    ];
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
