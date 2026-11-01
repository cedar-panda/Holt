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

  test('weak empty reply falls back to grounded provider answer', () {
    final relayOnly = WebSearchBatchResult(
      requestedQuery: '台北天氣',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.relay,
            model: 'search-model',
            requestedQuery: '台北天氣',
            text: '台北今天最高溫 28 度，午後降雨機率較高。',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://weather.example/taipei',
                title: '台北天氣預報',
              ),
            ],
          ),
        ),
      ],
    );

    expect(
      WebSearchFollowUp.ensureGroundedReply(reply: '', batch: relayOnly),
      contains('最高溫 28 度'),
    );
  });

  test('short acknowledgement is supplemented with grounded facts', () {
    final supplemented = WebSearchFollowUp.ensureGroundedReply(
      reply: '我查到了，稍等我整理一下。',
      batch: batch,
    );

    expect(supplemented, startsWith('我查到了'));
    expect(supplemented, contains('Taipei is warm today.'));
  });

  test('reply already using grounded facts is not duplicated', () {
    const grounded =
        'Taipei is warm today, and the rain forecast is worth checking.';

    expect(
      WebSearchFollowUp.ensureGroundedReply(reply: grounded, batch: batch),
      grounded,
    );
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

  test('failed search exposes only semantic App state to the model', () async {
    final failedBatch = WebSearchBatchResult(
      requestedQuery: 'latest private launch date',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.failure(
          const WebSearchProviderFailure(
            provider: WebSearchProviderId.openRouter,
            code: WebSearchFailureCode.invalidResponse,
            safeMessage: 'No grounded search result was returned.',
            retryable: false,
            costCertainty: WebSearchCostCertainty.known,
          ),
        ),
      ],
    );
    final failureContext = WebSearchFollowUp.failureContextFor(failedBatch)!;
    final prompt = StructuredPrompt(
      staticPart: 'STATIC',
      liveStatePart: failureContext,
    );

    expect(prompt.cacheableParts.join('\n'), isNot(contains(failureContext)));
    final body = await ThinkingMachinesService(apiKey: 'test')
        .debugBuildBodyForTesting(
          messages: const <Map<String, String>>[
            <String, String>{'role': 'assistant', 'content': 'previous'},
            <String, String>{'role': 'user', 'content': '幫我查最新日期'},
          ],
          model: ThinkingMachinesService.defaultModel,
          structuredPrompt: prompt,
        );
    final messages = (body['messages'] as List).cast<Map>();
    final user = messages.lastWhere((message) => message['role'] == 'user');

    expect(user['content'], '幫我查最新日期');
    expect(body.toString(), contains('No reliable web evidence'));
    expect(body.toString(), isNot(contains('openRouter')));
    expect(body.toString(), isNot(contains('latest private launch date')));
    expect(
      body.toString(),
      isNot(contains('No grounded search result was returned.')),
    );
    expect(body.toString(), contains('App Live State'));
  });

  test('standalone failure hides route and HTTP diagnostics from model', () {
    final context = WebSearchFollowUp.standaloneFailureContext(
      query: 'search this',
      providers: const <String>['Gemini direct', 'API relay'],
      safeMessage: 'API relay is temporarily unavailable. (HTTP 503)',
    );

    expect(context, contains('No reliable web evidence'));
    expect(context, isNot(contains('search this')));
    expect(context, isNot(contains('Gemini direct')));
    expect(context, isNot(contains('API relay')));
    expect(context, isNot(contains('503')));
  });

  test('all-failed search bypasses a second model narration pass', () {
    final failedBatch = WebSearchBatchResult(
      requestedQuery: 'latest result',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.failure(
          const WebSearchProviderFailure(
            provider: WebSearchProviderId.relay,
            code: WebSearchFailureCode.unavailable,
            safeMessage: 'API relay is temporarily unavailable. (HTTP 503)',
            retryable: true,
            costCertainty: WebSearchCostCertainty.known,
          ),
        ),
      ],
    );
    final failureContext = WebSearchFollowUp.failureContextFor(failedBatch)!;

    expect(
      WebSearchFollowUp.hasNoVerifiedEvidence(
        result: failedBatch,
        failureContext: failureContext,
      ),
      isTrue,
    );
    expect(
      WebSearchFollowUp.hasNoVerifiedEvidence(
        result: batch,
        failureContext: failureContext,
      ),
      isFalse,
    );
  });
}
