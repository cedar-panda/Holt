import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/web_search_activity_card.dart';

void main() {
  testWidgets('reduced motion uses a static searching indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const WebSearchActivityCard(
          status: WebSearchActivityStatus.searching,
          query: 'A public query with enough text to wrap safely',
          providers: <String>['Gemini', 'OpenRouter · Exa'],
        ),
        disableAnimations: true,
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.travel_explore_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure presents both text and icon', (tester) async {
    await tester.pumpWidget(
      _host(
        const WebSearchActivityCard(
          status: WebSearchActivityStatus.failed,
          query: 'current weather',
          providers: <String>['Gemini'],
          safeMessage: 'The normal reply was kept.',
        ),
      ),
    );

    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.text('The normal reply was kept.'), findsOneWidget);
  });
}

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        textScaler: textScaler,
        size: const Size(360, 720),
      ),
      child: Scaffold(body: child),
    ),
  );
}
