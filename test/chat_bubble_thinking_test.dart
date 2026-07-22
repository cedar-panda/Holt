import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('thinking label stays English in every interface locale', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    for (final locale in const ['zh_TW', 'zh_CN', 'en']) {
      await L.setLocale(locale);
      expect(L.get('chat_thinking'), 'Thinking');
    }
  });

  testWidgets('thinking block stays transparent and remains expandable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(text: '<think>正在整理想法</think>正常回覆', isUser: false),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.bubble_chart_outlined), findsOneWidget);
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
    expect(find.text('Thinking'), findsOneWidget);

    final thinkingContainer = tester.widget<Container>(
      find.byKey(const ValueKey('thinking-chain-container')),
    );
    expect(thinkingContainer.color, isNull);
    expect(thinkingContainer.decoration, isNull);

    expect(find.text('正在整理想法'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pump();
    expect(find.text('正在整理想法'), findsOneWidget);
    expect(find.text('正常回覆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
