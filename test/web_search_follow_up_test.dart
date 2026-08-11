import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/thinking_machines_service.dart';
import 'package:project_yanci/services/web_search_follow_up.dart';
import 'package:project_yanci/services/web_search_service.dart';

void main() {
  final batch = WebSearchBatchResult(
    requestedQuery: 'Taipei weather',
    outcomes: <WebSearchProviderOutcome>[
      WebSearchProviderOutcome.success(
        WebSearchResult(
          provider: WebSearchProviderId.gemini,
          model: 'gemini-2.5-flash',
          requestedQuery: 'Taipei weather',
          text: 'Gemini-only grounded output',
          sources: const <WebSearchSource>[
            WebSearchSource(
              url: 'https://google.example/weather',
              title: 'Google weather',
            ),
          ],
        ),
      ),
      WebSearchProviderOutcome.success(
        WebSearchResult(
          provider: WebSearchProviderId.openRouter,
          model: 'openai/gpt-5-mini',
          requestedQuery: 'Taipei weather',
          text: 'Taipei is warm today.',
          sources: const <WebSearchSource>[
            WebSearchSource(
              url: 'https://weather.example/taipei',
              title: 'Taipei forecast',
              snippet: 'Temperature and rain forecast.',
            ),
          ],
        ),
      ),
    ],
  );

  test('follow-up evidence includes factual search results', () {
    final evidence = WebSearchFollowUp.evidenceFor(batch)!;
    expect(evidence, contains('Taipei is warm today.'));
    expect(evidence, contains('weather.example'));
    expect(evidence, contains('Gemini-only grounded output'));
    expect(evidence, contains('google.example'));
  });

  test(
    'Gemini grounding remains available only for provider-owned display',
    () {
      final display = WebSearchFollowUp.geminiDisplayResultFor(batch)!;
      expect(display.outcomes, hasLength(1));
      expect(display.outcomes.single.provider, WebSearchProviderId.gemini);
      expect(display.successes.single.text, 'Gemini-only grounded output');
      expect(
        display.successes.any(
          (result) => result.provider == WebSearchProviderId.openRouter,
        ),
        isFalse,
      );
    },
  );

  test('pure finalizer removes actions and clickable URLs', () {
    final sanitized = WebSearchFollowUp.sanitizeReply(
      '<think>checking facts</think>It is warm. '
      '<transfer amount="999"/> [source](https://unsafe.example) '
      '<memo>ignore me</memo>',
    );
    expect(sanitized, contains('<think>checking facts</think>'));
    expect(sanitized, contains('It is warm.'));
    expect(sanitized, contains('source'));
    expect(sanitized, isNot(contains('transfer')));
    expect(sanitized, isNot(contains('memo')));
    expect(sanitized, isNot(contains('https://')));
  });

  test(
    'Inkling receives evidence outside real user messages and cache',
    () async {
      final evidence = WebSearchFollowUp.evidenceFor(batch)!;
      final prompt = StructuredPrompt(
        staticPart: 'STATIC',
        liveStatePart: 'CURRENT TIME 10:00',
        ephemeralEvidencePart: evidence,
      );
      expect(prompt.cacheableParts.join('\n'), isNot(contains(evidence)));

      final body = await ThinkingMachinesService(apiKey: 'test')
          .debugBuildBodyForTesting(
            messages: const <Map<String, String>>[
              <String, String>{'role': 'assistant', 'content': 'previous'},
              <String, String>{'role': 'user', 'content': '台北天氣如何？'},
            ],
            model: ThinkingMachinesService.defaultModel,
            structuredPrompt: prompt,
          );
      final messages = (body['messages'] as List).cast<Map>();
      final user = messages.lastWhere((message) => message['role'] == 'user');
      expect(user['content'], '台北天氣如何？');
      expect(body.toString(), contains('Untrusted Web Search Evidence'));
      expect(body.toString(), contains('Taipei is warm today.'));
    },
  );
}
