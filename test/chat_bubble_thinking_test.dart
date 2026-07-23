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

  testWidgets('capture mode paints bubble content without waiting for ticker', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: false,
          child: Scaffold(
            body: ChatBubble(text: '長截圖內容', isUser: false, captureMode: true),
          ),
        ),
      ),
    );

    expect(find.text('長截圖內容'), findsOneWidget);
    final opacity = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(opacity.any((widget) => widget.opacity == 0), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capture mode can force thinking open without toggling it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>截圖中的完整思考</think>正常回覆',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
          ),
        ),
      ),
    );

    expect(find.text('截圖中的完整思考'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pump();
    expect(find.text('截圖中的完整思考'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bubble actions use bookmark and sound-wave idle icons', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '回覆內容',
            isUser: false,
            timestamp: DateTime(2026, 7, 22, 12),
            captureMode: true,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsNothing);

    final copySlot = find.byKey(const ValueKey('bubble-action-copy'));
    final bookmarkSlot = find.byKey(const ValueKey('bubble-action-bookmark'));
    final ttsSlot = find.byKey(const ValueKey('bubble-action-tts'));
    expect(tester.getSize(copySlot), const Size.square(22));
    expect(tester.getSize(bookmarkSlot), const Size.square(22));
    expect(tester.getSize(ttsSlot), const Size.square(22));
    expect(
      tester.getCenter(copySlot).dy,
      closeTo(tester.getCenter(bookmarkSlot).dy, 0.01),
    );
    expect(
      tester.getCenter(bookmarkSlot).dy,
      closeTo(tester.getCenter(ttsSlot).dy, 0.01),
    );
    expect(tester.takeException(), isNull);
  });
}
