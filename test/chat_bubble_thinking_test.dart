import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';
import 'package:project_yanci/widgets/bubble_action_glyph.dart';

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

  testWidgets(
    'memory and emotion disclosures match the thinking visual treatment',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await L.setLocale('zh_TW');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              text: '<think>正在整理想法</think>正常回覆',
              isUser: false,
              captureMode: true,
              memoryLog:
                  '讀取相關記憶\n'
                  '📍 情緒打點：安心\n'
                  '情緒座標: (0.3, -0.2)\n'
                  'Done',
            ),
          ),
        ),
      );

      const disclosureKeys = <ValueKey<String>>[
        ValueKey('thinking-chain-container'),
        ValueKey('memory-log-container'),
        ValueKey('emotion-log-container'),
        ValueKey('emotion-coordinate-container'),
      ];
      for (final key in disclosureKeys) {
        final container = tester.widget<Container>(find.byKey(key));
        expect(container.color, isNull, reason: '$key should stay transparent');
        expect(
          container.decoration,
          isNull,
          reason: '$key should not draw a border or surface',
        );
      }

      Color? disclosureIconColor(ValueKey<String> key, IconData icon) {
        return tester
            .widget<Icon>(
              find.descendant(of: find.byKey(key), matching: find.byIcon(icon)),
            )
            .color;
      }

      final thinkingColor = disclosureIconColor(
        const ValueKey('thinking-chain-container'),
        Icons.bubble_chart_outlined,
      );
      expect(
        disclosureIconColor(
          const ValueKey('memory-log-container'),
          Icons.auto_awesome_outlined,
        ),
        thinkingColor,
      );
      expect(
        disclosureIconColor(
          const ValueKey('emotion-log-container'),
          Icons.favorite_border_rounded,
        ),
        thinkingColor,
      );
      expect(
        disclosureIconColor(
          const ValueKey('emotion-coordinate-container'),
          Icons.favorite_border_rounded,
        ),
        thinkingColor,
      );

      expect(find.text('讀取相關記憶'), findsNothing);
      expect(find.text('📍 情緒打點：安心'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('memory-log-container')));
      await tester.tap(find.byKey(const ValueKey('emotion-log-container')));
      await tester.pump();
      expect(find.text('讀取相關記憶'), findsOneWidget);
      expect(find.text('📍 情緒打點：安心'), findsOneWidget);
      expect(find.text('Done ✓'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('bubble actions use thin aligned action glyphs', (tester) async {
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

    final glyphs = tester
        .widgetList<BubbleActionGlyph>(find.byType(BubbleActionGlyph))
        .toList();
    expect(glyphs, hasLength(3));
    expect(
      glyphs.map((glyph) => glyph.type).toSet(),
      BubbleActionGlyphType.values.toSet(),
    );
    expect(BubbleActionGlyph.strokeWidth, 1);
    expect(
      BubbleActionGlyph.strokeWidth,
      lessThan(1.35),
      reason: 'action icons should stay as light as the Thinking treatment',
    );
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
