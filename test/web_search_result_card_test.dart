import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/web_search_service.dart';
import 'package:project_yanci/widgets/web_search_result_card.dart';

void main() {
  testWidgets('renders two provider outcomes without merging their answers', (
    tester,
  ) async {
    final result = WebSearchBatchResult(
      requestedQuery: 'current facts',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.gemini,
            model: 'gemini-2.5-flash',
            requestedQuery: 'current facts',
            text: 'Gemini grounded answer.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://gemini.example/source',
                title: 'Gemini source',
              ),
            ],
            attribution: const WebSearchAttribution(
              provider: WebSearchProviderId.gemini,
              renderedContent:
                  '<a href="https://www.google.com/search?q=facts">Google Search</a>',
            ),
          ),
        ),
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.openRouter,
            model: 'openai/gpt-5-mini',
            requestedQuery: 'current facts',
            text: 'OpenRouter grounded answer.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://openrouter.example/source',
                title: 'OpenRouter source',
              ),
            ],
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(WebSearchResultCard(result: result)));
    await tester.pumpAndSettle();

    final geminiCard = find.byKey(
      const ValueKey<String>('web_search_provider_card_gemini'),
    );
    final openRouterCard = find.byKey(
      const ValueKey<String>('web_search_provider_card_openRouter'),
    );
    final geminiToggle = find.byKey(
      const ValueKey<String>('web_search_result_toggle_gemini'),
    );
    final openRouterToggle = find.byKey(
      const ValueKey<String>('web_search_result_toggle_openRouter'),
    );

    expect(geminiCard, findsOneWidget);
    expect(openRouterCard, findsOneWidget);
    expect(geminiToggle, findsOneWidget);
    expect(openRouterToggle, findsOneWidget);
    expect(find.text('Gemini grounded answer.'), findsOneWidget);
    expect(find.text('OpenRouter grounded answer.'), findsOneWidget);
    expect(find.text('Gemini source'), findsOneWidget);
    expect(find.text('OpenRouter source'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('gemini_search_attribution')),
      findsOneWidget,
    );

    await tester.tap(geminiToggle);
    await tester.pumpAndSettle();
    expect(find.text('Gemini grounded answer.'), findsNothing);
    expect(find.text('Gemini source'), findsNothing);
    expect(find.text('OpenRouter grounded answer.'), findsOneWidget);
    expect(find.text('OpenRouter source'), findsOneWidget);

    await tester.tap(geminiToggle);
    await tester.pumpAndSettle();
    await tester.tap(openRouterToggle);
    await tester.pumpAndSettle();
    expect(find.text('OpenRouter grounded answer.'), findsNothing);
    expect(find.text('OpenRouter source'), findsNothing);
    expect(find.text('Gemini grounded answer.'), findsOneWidget);
    expect(find.text('Gemini source'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('gemini_search_attribution')),
      findsOneWidget,
    );
  });

  testWidgets('shows a partial provider failure beside the safe result', (
    tester,
  ) async {
    final result = WebSearchBatchResult(
      requestedQuery: 'partial',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.failure(
          const WebSearchProviderFailure(
            provider: WebSearchProviderId.gemini,
            code: WebSearchFailureCode.rateLimited,
            safeMessage: 'Gemini is temporarily rate limited.',
            retryable: true,
            costCertainty: WebSearchCostCertainty.unknown,
          ),
        ),
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.openRouter,
            model: 'openai/gpt-5-mini',
            requestedQuery: 'partial',
            text: 'A safe OpenRouter result.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://safe.example/source',
                title: 'Safe source',
              ),
            ],
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(WebSearchResultCard(result: result)));
    await tester.pumpAndSettle();

    expect(find.text('Gemini is temporarily rate limited.'), findsOneWidget);
    expect(find.text('A safe OpenRouter result.'), findsOneWidget);
  });

  testWidgets('collapse hides result details and keeps a 48px target', (
    tester,
  ) async {
    final result = WebSearchBatchResult(
      requestedQuery: 'collapse',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.openRouter,
            model: 'openai/gpt-5-mini',
            requestedQuery: 'collapse',
            text: 'Collapsible answer.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://safe.example/source',
                title: 'Safe source',
              ),
            ],
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(WebSearchResultCard(result: result)));
    await tester.pumpAndSettle();
    final toggle = find.byKey(
      const ValueKey<String>('web_search_result_toggle_openRouter'),
    );
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Collapsible answer.'), findsNothing);
  });

  testWidgets('forged unsafe source URLs are never rendered as links', (
    tester,
  ) async {
    final result = WebSearchBatchResult(
      requestedQuery: 'unsafe',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.openRouter,
            model: 'openai/gpt-5-mini',
            requestedQuery: 'unsafe',
            text: 'Answer.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'javascript:alert(1)',
                title: 'Unsafe source',
              ),
            ],
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(WebSearchResultCard(result: result)));
    await tester.pumpAndSettle();

    expect(find.text('Unsafe source'), findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('web_search_source_javascript:alert(1)'),
      ),
      findsNothing,
    );
  });

  testWidgets('Gemini attribution cannot trigger remote image requests', (
    tester,
  ) async {
    final result = WebSearchBatchResult(
      requestedQuery: 'attribution',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.gemini,
            model: 'gemini-2.5-flash',
            requestedQuery: 'attribution',
            text: 'Grounded answer.',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://safe.example/source',
                title: 'Safe source',
              ),
            ],
            attribution: const WebSearchAttribution(
              provider: WebSearchProviderId.gemini,
              renderedContent:
                  '<div style="background-image:url(https://tracker.invalid/bg.png)">Suggestions</div>'
                  '<img src="https://tracker.invalid/pixel.png" alt="tracker">',
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(_host(WebSearchResultCard(result: result)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('gemini_search_attribution')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
  });
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 420, child: SingleChildScrollView(child: child)),
    ),
  );
}
