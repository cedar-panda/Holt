import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/web_search_service.dart';
import 'package:project_yanci/widgets/chat_avatar.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';
import 'package:project_yanci/widgets/web_search_activity_card.dart';
import 'package:project_yanci/widgets/web_search_thinking_node.dart';

void main() {
  final result = WebSearchBatchResult(
    requestedQuery: 'Taipei weather',
    outcomes: <WebSearchProviderOutcome>[
      WebSearchProviderOutcome.success(
        WebSearchResult(
          provider: WebSearchProviderId.openRouter,
          model: 'openai/gpt-5-mini',
          requestedQuery: 'Taipei weather',
          text: 'Grounded answer',
          sources: const <WebSearchSource>[
            WebSearchSource(
              url: 'https://weather.example/taipei',
              title: 'Taipei forecast',
            ),
          ],
        ),
      ),
    ],
  );
  final trace = result.toDisplayTrace();

  test('minimal search trace survives a message database round trip', () {
    final original = Message(
      conversationId: 'conversation',
      characterId: 'character',
      text: 'Weather reply',
      isUser: false,
      webSearchTrace: trace,
    );
    final row = original.toMap();
    final encoded = row['web_search_trace_json']! as String;

    expect(encoded, isNot(contains('Taipei weather')));
    expect(encoded, isNot(contains('Grounded answer')));
    expect(encoded, isNot(contains('https://')));
    expect(original.toPromptHistoryEntry(), <String, String>{
      'role': 'assistant',
      'content': 'Weather reply',
    });

    final restored = Message.fromMap(row);
    expect(restored.webSearchTrace, isNotNull);
    expect(restored.webSearchTrace!.providers, <String>['OpenRouter']);
    expect(restored.webSearchTrace!.sources.single.host, 'weather.example');
  });

  testWidgets('completed search is a non-interactive Thinking child', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '今天偏暖，出門記得帶傘。',
            isUser: false,
            webSearchTrace: trace,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Web Search'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.text('Web Search'), findsOneWidget);
    expect(find.text('Taipei forecast · weather.example'), findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
    final node = find.byKey(const ValueKey<String>('web-search-thinking-node'));
    expect(
      find.descendant(of: node, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: node, matching: find.byType(InkWell)),
      findsNothing,
    );
  });

  testWidgets('partial provider failure stays inside the Thinking trace', (
    tester,
  ) async {
    final partial = WebSearchBatchResult(
      requestedQuery: 'Taipei weather',
      outcomes: <WebSearchProviderOutcome>[
        WebSearchProviderOutcome.success(
          WebSearchResult(
            provider: WebSearchProviderId.gemini,
            model: 'gemini-2.5-flash',
            requestedQuery: 'Taipei weather',
            text: 'Gemini grounded answer',
            sources: const <WebSearchSource>[
              WebSearchSource(
                url: 'https://weather.example/taipei',
                title: 'Taipei forecast',
              ),
            ],
          ),
        ),
        WebSearchProviderOutcome.failure(
          const WebSearchProviderFailure(
            provider: WebSearchProviderId.openRouter,
            code: WebSearchFailureCode.billing,
            safeMessage: 'OpenRouter does not have enough search credit.',
            retryable: false,
            costCertainty: WebSearchCostCertainty.known,
            statusCode: 402,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: 'Weather reply',
            isUser: false,
            webSearchTrace: partial.toDisplayTrace(),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'OpenRouter · OpenRouter does not have enough search credit. (HTTP 402)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('search activity uses Thinking hierarchy and reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: WebSearchThinkingActivity(
              status: WebSearchActivityStatus.searching,
              query: 'Taipei weather',
              providers: <String>['OpenRouter · Exa'],
              showAvatar: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Web Search'), findsOneWidget);
    expect(find.byType(ChatAvatar), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('completed search keeps avatar and Thinking during handoff', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WebSearchThinkingActivity(
            status: WebSearchActivityStatus.completed,
            query: 'Taipei weather',
            providers: <String>['Gemini'],
            showAvatar: true,
          ),
        ),
      ),
    );

    expect(find.byType(ChatAvatar), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.textContaining('Search completed'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
