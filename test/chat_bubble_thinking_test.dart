import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';
import 'package:project_yanci/widgets/bubble_action_glyph.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'thinking tree label stays Thinking in every interface locale',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await L.setLocale('zh_TW');
      expect(L.get('chat_thinking_tree'), 'Thinking');
      await L.setLocale('zh_CN');
      expect(L.get('chat_thinking_tree'), 'Thinking');
      await L.setLocale('en');
      expect(L.get('chat_thinking_tree'), 'Thinking');
    },
  );

  testWidgets('thinking tree stays transparent and remains expandable', (
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

    expect(find.byIcon(Icons.bubble_chart_outlined), findsNothing);
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
    expect(find.text('Thinking'), findsOneWidget);

    final thinkingContainer = tester.widget<Container>(
      find.byKey(const ValueKey('thinking-chain-container')),
    );
    expect(thinkingContainer.color, isNull);
    expect(thinkingContainer.decoration, isNull);

    expect(find.text('正在整理想法'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pumpAndSettle();
    expect(find.text('正在整理想法'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-tree-body')), findsOneWidget);
    expect(
      tester
          .widget<AnimatedRotation>(
            find.byKey(const ValueKey('thinking-tree-chevron')),
          )
          .turns,
      0.25,
    );
    expect(find.text('正常回覆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking and memory branches render markdown', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>**判斷**\n\n- 線索一</think>正常回覆',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
            memoryLog: '**命中記憶**\n\n- 條目一\nDone',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('thinking-chain-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('memory-markdown-content')),
      findsOneWidget,
    );
    expect(find.text('判斷'), findsOneWidget);
    expect(find.text('線索一'), findsOneWidget);
    expect(find.text('命中記憶'), findsOneWidget);
    expect(find.text('條目一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('emotion nests inside Memory when both appear under Thinking', (
    tester,
  ) async {
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

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-log-container')), findsNothing);
    expect(find.byKey(const ValueKey('emotion-log-container')), findsNothing);
    expect(find.text('讀取相關記憶'), findsNothing);
    expect(find.text('📍 情緒打點：安心'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pumpAndSettle();

    final treeBody = tester.widget<Container>(
      find.byKey(const ValueKey('thinking-tree-body')),
    );
    expect(treeBody.decoration, isNull);

    const transparentKeys = <ValueKey<String>>[
      ValueKey('thinking-chain-container'),
      ValueKey('memory-log-container'),
    ];
    for (final key in transparentKeys) {
      final container = tester.widget<Container>(find.byKey(key));
      expect(container.color, isNull, reason: '$key should stay transparent');
      expect(
        container.decoration,
        isNull,
        reason: '$key should not draw a border or surface',
      );
    }

    Color? branchIconColor(ValueKey<String> key, IconData icon) {
      return tester
          .widget<Icon>(
            find.descendant(of: find.byKey(key), matching: find.byIcon(icon)),
          )
          .color;
    }

    final thinkingColor = tester
        .widget<Text>(find.text('Thinking'))
        .style!
        .color;
    expect(
      branchIconColor(
        const ValueKey('memory-log-container'),
        Icons.auto_awesome_outlined,
      ),
      thinkingColor,
    );
    expect(find.text('讀取相關記憶'), findsNothing);
    expect(find.text('📍 情緒打點：安心'), findsNothing);
    expect(find.text('(0.3, -0.2)'), findsNothing);
    final thinkingX = tester
        .getTopLeft(find.byKey(const ValueKey('thinking-chain-content')))
        .dx;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('memory-log-container'))).dx,
      greaterThanOrEqualTo(thinkingX + 12),
    );
    await tester.tap(find.byKey(const ValueKey('memory-log-container')));
    await tester.pumpAndSettle();
    expect(find.text('讀取相關記憶'), findsOneWidget);
    expect(find.text('📍 情緒打點：安心'), findsOneWidget);
    expect(find.text('(0.3, -0.2)'), findsOneWidget);
    for (final key in const <ValueKey<String>>[
      ValueKey('emotion-log-container'),
      ValueKey('emotion-coordinate-container'),
    ]) {
      final container = tester.widget<Container>(find.byKey(key));
      expect(container.color, isNull, reason: '$key should stay transparent');
      expect(container.decoration, isNull);
    }
    expect(
      branchIconColor(
        const ValueKey('emotion-log-container'),
        Icons.favorite_border_rounded,
      ),
      thinkingColor,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('emotion-log-container')),
        matching: find.byIcon(Icons.keyboard_arrow_right_rounded),
      ),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('emotion-log-container'))).dx,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('memory-log-container')))
            .dx,
      ),
    );
    expect(find.text('Done ✓'), findsNWidgets(2));
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

  testWidgets('memory-only metadata uses Memory as its root', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '正常回覆',
            isUser: false,
            captureMode: true,
            memoryLog: '讀取相關記憶\nDone',
          ),
        ),
      ),
    );

    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-root-container')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-log-container')), findsNothing);
    expect(find.text('讀取相關記憶'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('memory-root-container')));
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-root-body')), findsOneWidget);
    expect(find.text('讀取相關記憶'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('thinking-chain-container')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('memory root contains emotion when Thinking is absent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '正常回覆',
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

    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Mood'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('memory-root-container')));
    await tester.pump();
    expect(find.text('讀取相關記憶'), findsOneWidget);
    expect(find.text('Mood'), findsOneWidget);
    expect(find.text('📍 情緒打點：安心'), findsOneWidget);
    expect(find.text('(0.3, -0.2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('emotion-only metadata uses an independent emotion root', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '正常回覆',
            isUser: false,
            captureMode: true,
            memoryLog:
                '📍 情緒打點：安心\n'
                '情緒座標: (0.3, -0.2)\n'
                'Done',
          ),
        ),
      ),
    );

    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Memory'), findsNothing);
    expect(find.text('Mood'), findsOneWidget);
    expect(find.text('(0.3, -0.2)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('emotion-root-container')),
      findsOneWidget,
    );
    expect(find.text('📍 情緒打點：安心'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('emotion-root-container')));
    await tester.pump();
    expect(find.text('📍 情緒打點：安心'), findsOneWidget);
    expect(find.byKey(const ValueKey('emotion-root-body')), findsOneWidget);
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
            memoryLog:
                '讀取相關記憶\n'
                '📍 情緒打點：安心\n'
                '情緒座標: (0.3, -0.2)\n'
                'Done',
          ),
        ),
      ),
    );

    expect(find.text('截圖中的完整思考'), findsOneWidget);
    expect(find.text('讀取相關記憶'), findsOneWidget);
    expect(find.text('📍 情緒打點：安心'), findsOneWidget);
    expect(find.text('(0.3, -0.2)'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedRotation>(
            find.byKey(const ValueKey('thinking-tree-chevron')),
          )
          .turns,
      0.25,
    );
    await tester.tap(
      find.byKey(const ValueKey('thinking-chain-container')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.text('截圖中的完整思考'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capture details can include emotion without exposing memory', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>不公開的思考</think>正常回覆',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
            includeThinkingDetails: false,
            includeMemoryDetails: false,
            includeEmotionDetails: true,
            memoryLog:
                '不公開的記憶\n'
                '📍 情緒打點：安心\n'
                '情緒座標: (0.3, -0.2)\n'
                'Done',
          ),
        ),
      ),
    );

    expect(find.text('不公開的思考'), findsNothing);
    expect(find.text('不公開的記憶'), findsNothing);
    expect(find.byKey(const ValueKey('memory-log-container')), findsNothing);
    expect(find.text('📍 情緒打點：安心'), findsOneWidget);
    expect(find.text('(0.3, -0.2)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>不公開的思考</think>正常回覆',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
            includeThinkingDetails: false,
            includeMemoryDetails: true,
            includeEmotionDetails: false,
            memoryLog:
                '公開的記憶\n'
                '📍 不公開的情緒\n'
                '情緒座標: (0.3, -0.2)\n'
                'Done',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('不公開的思考'), findsNothing);
    expect(find.text('公開的記憶'), findsOneWidget);
    expect(find.text('📍 不公開的情緒'), findsNothing);
    expect(find.text('(0.3, -0.2)'), findsNothing);
    expect(find.byKey(const ValueKey('emotion-log-container')), findsNothing);
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
    final copyGlyph = glyphs.singleWhere(
      (glyph) => glyph.type == BubbleActionGlyphType.copy,
    );
    expect(copyGlyph.size, 13.5);
    expect(copyGlyph.size, lessThan(BubbleActionGlyph.defaultSize));
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

  testWidgets('pending memory badge opens review from the source reply', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>正在整理</think>正常回覆',
            isUser: false,
            captureMode: true,
            memoryLog: '◌ 提出刪除記憶建議\nDone',
            pendingMemoryActionCount: 2,
            onMemoryReviewTap: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2 待確認'), findsWidgets);
    await tester.tap(find.text('2 待確認').first);
    await tester.pump();
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });
}
