import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/memory_guard_service.dart';
import 'package:project_yanci/services/background_foreground_service.dart';
import 'package:project_yanci/models/background_preset.dart';
import 'package:project_yanci/models/memory_action_proposal.dart';
import 'package:project_yanci/theme/app_theme.dart';
import 'package:project_yanci/theme/theme_presets.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';
import 'package:project_yanci/widgets/chat_avatar.dart';
import 'package:project_yanci/widgets/gradient_background.dart';
import 'package:project_yanci/widgets/bubble_action_glyph.dart';
import 'package:project_yanci/widgets/thinking_context_widgets.dart';

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

  testWidgets('grouped bubbles keep one avatar and softly join inner corners', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    YanciTheme.aiBubbleFlat = false;
    addTearDown(() => YanciTheme.aiBubbleFlat = originalFlatMode);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatBubble(
                text: '第一段',
                isUser: false,
                showAvatar: true,
                groupedWithNext: true,
                captureMode: true,
              ),
              ChatBubble(
                text: '第二段',
                isUser: false,
                showAvatar: true,
                showAvatarImage: false,
                groupedWithPrevious: true,
                captureMode: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(ChatAvatar), findsOneWidget);
    final surfaces = tester
        .widgetList<Container>(
          find.byKey(const ValueKey('chat-bubble-surface')),
        )
        .toList();
    expect(surfaces, hasLength(2));
    final first =
        (surfaces.first.decoration! as BoxDecoration).borderRadius!
            as BorderRadius;
    final second =
        (surfaces.last.decoration! as BoxDecoration).borderRadius!
            as BorderRadius;
    expect(first.topLeft, first.topRight);
    expect(first.bottomLeft.x, 14);
    expect(first.bottomLeft.x, lessThan(first.topLeft.x));
    expect(second.bottomLeft, second.bottomRight);
    expect(second.topLeft.x, 14);
    expect(second.topLeft.x, lessThan(second.topRight.x));
  });

  testWidgets('one rendered line is a pill and multiline keeps theme radius', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    final originalRadius = YanciTheme.bubbleRadius;
    YanciTheme.aiBubbleFlat = false;
    YanciTheme.bubbleRadius = 23;
    addTearDown(() {
      YanciTheme.aiBubbleFlat = originalFlatMode;
      YanciTheme.bubbleRadius = originalRadius;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatBubble(text: '短句', isUser: true, captureMode: true),
              ChatBubble(text: '第一行\n第二行', isUser: true, captureMode: true),
            ],
          ),
        ),
      ),
    );

    final surfaces = tester
        .widgetList<Container>(
          find.byKey(const ValueKey('chat-bubble-surface')),
        )
        .toList();
    final pill = (surfaces[0].decoration! as BoxDecoration).borderRadius;
    final multiline = (surfaces[1].decoration! as BoxDecoration).borderRadius;
    expect(pill, BorderRadius.circular(YanciTheme.radiusPill));
    expect(multiline, BorderRadius.circular(23));
  });

  testWidgets('flat AI text keeps a readable asymmetric page margin', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    YanciTheme.aiBubbleFlat = true;
    addTearDown(() async {
      YanciTheme.aiBubbleFlat = originalFlatMode;
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(400, 800));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(text: '平鋪正文', isUser: false, captureMode: true),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('chat-bubble-surface'));
    expect(tester.getTopLeft(bubble).dx, greaterThanOrEqualTo(24));
    expect(400 - tester.getTopRight(bubble).dx, greaterThanOrEqualTo(40));
  });

  testWidgets('persisted assistant content does not replay entry opacity', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '已經顯示完成的正文',
            isUser: false,
            animateEntry: false,
          ),
        ),
      ),
    );

    final opacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('chat-bubble-entry-opacity')),
    );
    expect(opacity.opacity, 1);
  });

  testWidgets('normal bubble reveals late Memory without a hard layout jump', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    YanciTheme.aiBubbleFlat = false;
    addTearDown(() => YanciTheme.aiBubbleFlat = originalFlatMode);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '正文',
            isUser: false,
            memoryLog: '記憶已整理\nDone',
            animateEntry: false,
            animateContextReveal: true,
          ),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('chat-bubble-surface'));
    final initialTop = tester.getTopLeft(bubble).dy;
    expect(
      tester
          .getSize(find.byKey(const ValueKey('context-reveal-anchor')))
          .height,
      0,
    );

    // Let the post-frame reveal request start the implicit animation before
    // measuring its midpoint.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final halfwayTop = tester.getTopLeft(bubble).dy;
    expect(halfwayTop, greaterThan(initialTop));

    await tester.pump(const Duration(milliseconds: 150));
    final finalTop = tester.getTopLeft(bubble).dy;
    expect(finalTop, greaterThan(halfwayTop));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('memory-root-container')))
          .height,
      lessThanOrEqualTo(40),
    );
  });

  testWidgets('flat metadata reveal stays inside the avatar row height', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    YanciTheme.aiBubbleFlat = true;
    addTearDown(() => YanciTheme.aiBubbleFlat = originalFlatMode);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '平鋪正文',
            isUser: false,
            showAvatar: true,
            memoryLog: '記憶已整理\nDone',
            animateEntry: false,
            animateContextReveal: true,
          ),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('chat-bubble-surface'));
    final initialTop = tester.getTopLeft(bubble).dy;
    await tester.pump(const Duration(milliseconds: 260));
    final finalTop = tester.getTopLeft(bubble).dy;
    expect(finalTop, closeTo(initialTop, 0.5));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('memory-root-container')))
          .height,
      lessThanOrEqualTo(40),
    );
  });

  testWidgets('context metadata floats independently beside the avatar', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalFlatMode = YanciTheme.aiBubbleFlat;
    YanciTheme.aiBubbleFlat = false;
    addTearDown(() => YanciTheme.aiBubbleFlat = originalFlatMode);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>整理中</think>正文',
            isUser: false,
            showAvatar: true,
            captureMode: true,
          ),
        ),
      ),
    );

    final contextTop = tester.getTopLeft(
      find.byKey(const ValueKey('thinking-chain-container')),
    );
    final avatarTop = tester.getTopLeft(find.byType(ChatAvatar));
    final avatarRect = tester.getRect(find.byType(ChatAvatar));
    final anchorRect = tester.getRect(
      find.byKey(const ValueKey('avatar-side-context-anchor')),
    );
    final bubbleTop = tester
        .getTopLeft(find.byKey(const ValueKey('chat-bubble-surface')))
        .dy;

    expect(contextTop.dy, closeTo(avatarTop.dy, 1));
    expect(anchorRect.left, greaterThan(avatarRect.right));
    expect(bubbleTop, greaterThan(anchorRect.top));
  });

  testWidgets('thinking opens a two-stage draggable sheet', (tester) async {
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
    expect(
      find.byKey(const ValueKey('context-tree-image-surface')),
      findsNothing,
    );

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
    expect(find.byKey(const ValueKey('thinking-detail-sheet')), findsOneWidget);
    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byKey(const ValueKey('thinking-detail-sheet')),
    );
    expect(sheet.initialChildSize, 0.58);
    expect(sheet.maxChildSize, 1.0);
    expect(sheet.snap, isTrue);
    expect(sheet.snapSizes, const [0.58, 1.0]);
    final sheetSurface = tester.widget<Container>(
      find.byKey(const ValueKey('thinking-sheet-surface')),
    );
    final sheetDecoration = sheetSurface.decoration! as BoxDecoration;
    expect(sheetDecoration.border, isNull);
    expect(find.text('正常回覆'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('thinking-sheet-scroll-view')),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-sheet-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinking-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-detail-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking sheet syncs saved thinking color across history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalPath = YanciTheme.chatBackgroundImagePath;
    final originalThinkingColor = YanciTheme.chatBackgroundThinkingTextOverride;
    addTearDown(() {
      YanciTheme.chatBackgroundImagePath = originalPath;
      YanciTheme.chatBackgroundThinkingTextOverride = originalThinkingColor;
    });

    YanciTheme.chatBackgroundImagePath = '';
    YanciTheme.chatBackgroundThinkingTextOverride = const Color(0xFF2B5876);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>圖片背景思考內容</think>正常回覆',
            isUser: false,
            memoryLog:
                '讀取相關記憶\n'
                '📍 情緒打點：安心\n'
                '情緒座標: (0.3, -0.2)\n'
                'Done',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('thinking-chain-container')));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(
      find.byKey(const ValueKey('thinking-sheet-title')),
    );
    expect(title.style?.color, const Color(0xFF2B5876));
    expect(title.style?.fontSize, 14);
    expect(title.style?.fontWeight, FontWeight.w700);
    final body = tester.widget<ThinkingMarkdown>(
      find.byKey(const ValueKey('thinking-chain-content')),
    );
    expect(body.bodyColor, const Color(0xFF2B5876));
    expect(body.fontSize, 13);
    expect(
      tester.widget<Text>(find.text('Memory')).style?.color,
      const Color(0xFF2B5876),
    );
    await tester.tap(find.byKey(const ValueKey('memory-log-container')));
    await tester.pumpAndSettle();
    final memory = tester.widget<ThinkingMarkdown>(
      find.byKey(const ValueKey('memory-markdown-content')),
    );
    expect(memory.bodyColor, const Color(0xFF2B5876));
    expect(
      tester.widget<Text>(find.text('Mood')).style?.color,
      const Color(0xFF2B5876),
    );
    expect(
      tester.widget<Text>(find.text('📍 情緒打點：安心')).style?.color,
      const Color(0xFF2B5876),
    );
    expect(find.text('圖片背景思考內容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unclosed think tag stays in the thinking tree', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>連線中斷前的思考片段',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
          ),
        ),
      ),
    );

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('連線中斷前的思考片段'), findsOneWidget);
    expect(find.textContaining('<think>'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all preset themes keep context metadata transparent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalPreset = YanciTheme.presetId;
    final originalPath = YanciTheme.chatBackgroundImagePath;
    addTearDown(() {
      YanciTheme.setPreset(originalPreset);
      YanciTheme.chatBackgroundImagePath = originalPath;
    });

    YanciTheme.chatBackgroundImagePath = '';
    for (final preset in presets) {
      YanciTheme.setPreset(preset.id);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              text: '<think>正在整理想法</think>正常回覆',
              isUser: false,
              captureMode: true,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('context-tree-image-surface')),
        findsNothing,
        reason: '${preset.id} should preserve the transparent treatment',
      );
    }
  });

  testWidgets('spring swallow uses the PNG as a scalable bubble frame', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalPreset = YanciTheme.presetId;
    addTearDown(() => YanciTheme.setPreset(originalPreset));
    YanciTheme.setPreset('swallow');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(text: '燕子歸來的雨後', isUser: false, captureMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final frameFinder = find.byKey(const ValueKey('themed-bubble-frame'));
    expect(frameFinder, findsOneWidget);
    final frame = tester.widget<Image>(frameFinder);
    expect(frame.fit, BoxFit.fill);
    expect(frame.centerSlice, const Rect.fromLTRB(20, 20, 60, 60));
    expect(tester.takeException(), isNull);
  });

  test('spring swallow is hidden but legacy selections still resolve', () {
    expect(presets.any((preset) => preset.id == 'swallow'), isFalse);
    expect(findPreset('swallow').id, 'swallow');
  });

  testWidgets(
    'valid custom image keeps context transparent and uses custom text color',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await L.setLocale('zh_TW');
      final originalPath = YanciTheme.chatBackgroundImagePath;
      final originalThinkingColor =
          YanciTheme.chatBackgroundThinkingTextOverride;
      final tempDir = Directory.systemTemp.createTempSync(
        'holt_chat_background_test_',
      );
      final background = File('${tempDir.path}/background.jpg')
        ..writeAsBytesSync(const <int>[1, 2, 3]);
      addTearDown(() {
        YanciTheme.chatBackgroundImagePath = originalPath;
        YanciTheme.chatBackgroundThinkingTextOverride = originalThinkingColor;
        tempDir.deleteSync(recursive: true);
      });

      YanciTheme.chatBackgroundImagePath = background.path;
      YanciTheme.chatBackgroundThinkingTextOverride = const Color(0xFF2B5876);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              text: '<think>正在整理想法</think>正常回覆',
              isUser: false,
              captureMode: true,
              thinkingExpandedOverride: true,
              memoryLog: '讀取相關記憶\nDone',
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('context-tree-image-surface')),
        findsNothing,
      );
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('Memory'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Thinking')).style?.color,
        const Color(0xFF2B5876),
      );
      expect(
        tester.widget<Text>(find.text('Memory')).style?.color,
        const Color(0xFF2B5876),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('valid custom image uses image-specific bubble colors', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final originalPath = YanciTheme.chatBackgroundImagePath;
    final originalAiColor = YanciTheme.chatBackgroundAiBubbleOverride;
    final originalUserColor = YanciTheme.chatBackgroundUserBubbleOverride;
    final originalOpacity = YanciTheme.chatBackgroundBubbleOpacityOverride;
    final tempDir = Directory.systemTemp.createTempSync(
      'holt_chat_bubble_color_test_',
    );
    final background = File('${tempDir.path}/background.jpg')
      ..writeAsBytesSync(const <int>[1, 2, 3]);
    addTearDown(() {
      YanciTheme.chatBackgroundImagePath = originalPath;
      YanciTheme.chatBackgroundAiBubbleOverride = originalAiColor;
      YanciTheme.chatBackgroundUserBubbleOverride = originalUserColor;
      YanciTheme.chatBackgroundBubbleOpacityOverride = originalOpacity;
      tempDir.deleteSync(recursive: true);
    });

    YanciTheme.chatBackgroundImagePath = background.path;
    YanciTheme.chatBackgroundAiBubbleOverride = const Color(0xFF456789);
    YanciTheme.chatBackgroundUserBubbleOverride = const Color(0xFF987654);
    YanciTheme.chatBackgroundBubbleOpacityOverride = 0.5;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatBubble(text: '角色訊息', isUser: false, captureMode: true),
              ChatBubble(text: '用戶訊息', isUser: true, captureMode: true),
            ],
          ),
        ),
      ),
    );

    final bubbles = tester
        .widgetList<Container>(
          find.byKey(const ValueKey('chat-bubble-surface')),
        )
        .toList();
    expect(bubbles, hasLength(2));
    final aiBubbleColor = (bubbles[0].decoration! as BoxDecoration).color!;
    final userBubbleColor = (bubbles[1].decoration! as BoxDecoration).color!;
    expect(aiBubbleColor.withValues(alpha: 1), const Color(0xFF456789));
    expect(userBubbleColor.withValues(alpha: 1), const Color(0xFF987654));
    expect(aiBubbleColor.a, closeTo(0.5, 0.0001));
    expect(userBubbleColor.a, closeTo(0.5, 0.0001));

    YanciTheme.chatBackgroundBubbleOpacityOverride = 0.0;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatBubble(text: '角色訊息', isUser: false, captureMode: true),
              ChatBubble(text: '用戶訊息', isUser: true, captureMode: true),
            ],
          ),
        ),
      ),
    );
    final hiddenSurface = tester
        .widgetList<Container>(
          find.byKey(const ValueKey('chat-bubble-surface')),
        )
        .first;
    final hiddenDecoration = hiddenSurface.decoration! as BoxDecoration;
    expect(hiddenDecoration.color!.a, 0.0);
    expect(hiddenDecoration.border!.top.color.a, 0.0);
    expect(hiddenDecoration.boxShadow!.first.color.a, 0.0);
    expect(find.text('角色訊息'), findsOneWidget);
    expect(find.text('用戶訊息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long screenshot without image keeps selected theme bubble colors',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final originalPath = YanciTheme.chatBackgroundImagePath;
      final originalUserColor = YanciTheme.chatBackgroundUserBubbleOverride;
      final tempDir = Directory.systemTemp.createTempSync(
        'holt_longshot_theme_color_test_',
      );
      final background = File('${tempDir.path}/background.jpg')
        ..writeAsBytesSync(const <int>[1, 2, 3]);
      addTearDown(() {
        YanciTheme.chatBackgroundImagePath = originalPath;
        YanciTheme.chatBackgroundUserBubbleOverride = originalUserColor;
        tempDir.deleteSync(recursive: true);
      });

      YanciTheme.chatBackgroundImagePath = background.path;
      YanciTheme.chatBackgroundUserBubbleOverride = const Color(0xFF123456);
      final expectedThemeColor = YanciTheme.userBubble;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              text: '長截圖內容',
              isUser: true,
              captureMode: true,
              forceThemeBubbleColors: true,
            ),
          ),
        ),
      );

      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('chat-bubble-surface')),
      );
      final color = (surface.decoration! as BoxDecoration).color;
      expect(color, expectedThemeColor);
      expect(color, isNot(const Color(0xFF123456)));
    },
  );

  testWidgets('bound character palette does not inherit active slot colors', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tempDir = Directory.systemTemp.createTempSync('holt-bubble-bg-');
    final background = File('${tempDir.path}/bound.png')..writeAsBytesSync([0]);
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final originalAi = YanciTheme.chatBackgroundAiBubbleOverride;
    final originalUser = YanciTheme.chatBackgroundUserBubbleOverride;
    addTearDown(() {
      YanciTheme.chatBackgroundAiBubbleOverride = originalAi;
      YanciTheme.chatBackgroundUserBubbleOverride = originalUser;
    });
    YanciTheme.chatBackgroundAiBubbleOverride = const Color(0xFF112233);
    YanciTheme.chatBackgroundUserBubbleOverride = const Color(0xFF334455);

    const palette = ChatBubblePalette(
      aiBubble: Color(0xFFABCDEF),
      userBubble: Color(0xFFFEDCBA),
      bubbleText: Color(0xFF010203),
      thinkingText: Color(0xFF040506),
      bubbleOpacity: 0.75,
      inputBarBg: Color(0xFF070809),
      inputBarBorder: Color(0xFF0A0B0C),
      inputBarText: Color(0xFF0D0E0F),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBackgroundPresetScope(
            preset: BackgroundPreset(slot: 2, chatPath: background.path),
            palette: palette,
            child: const Column(
              children: [
                ChatBubble(text: '角色訊息', isUser: false, captureMode: true),
                ChatBubble(text: '用戶訊息', isUser: true, captureMode: true),
              ],
            ),
          ),
        ),
      ),
    );

    final bubbles = tester
        .widgetList<Container>(
          find.byKey(const ValueKey('chat-bubble-surface')),
        )
        .toList();
    expect(
      (bubbles[0].decoration! as BoxDecoration).color,
      const Color(0xFFABCDEF).withValues(alpha: 0.75),
    );
    expect(
      (bubbles[1].decoration! as BoxDecoration).color,
      const Color(0xFFFEDCBA).withValues(alpha: 0.75),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing custom image keeps context metadata transparent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    final originalPath = YanciTheme.chatBackgroundImagePath;
    addTearDown(() => YanciTheme.chatBackgroundImagePath = originalPath);

    YanciTheme.chatBackgroundImagePath =
        '${Directory.systemTemp.path}/holt_missing_chat_background.jpg';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>正在整理想法</think>正常回覆',
            isUser: false,
            captureMode: true,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('context-tree-image-surface')),
      findsNothing,
    );
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
    final bookmarkGlyph = glyphs.singleWhere(
      (glyph) => glyph.type == BubbleActionGlyphType.bookmark,
    );
    final soundWaveGlyph = glyphs.singleWhere(
      (glyph) => glyph.type == BubbleActionGlyphType.soundWave,
    );
    expect(copyGlyph.size, 12);
    expect(copyGlyph.size, BubbleActionGlyph.defaultSize * 0.8);
    expect(bookmarkGlyph.size, closeTo(16.8, 0.001));
    expect(soundWaveGlyph.size, closeTo(16.8, 0.001));
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
      tester.getCenter(bookmarkSlot).dx - tester.getCenter(copySlot).dx,
      closeTo(38, 0.01),
    );
    expect(
      tester.getCenter(ttsSlot).dx - tester.getCenter(bookmarkSlot).dx,
      closeTo(38, 0.01),
    );
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

  testWidgets('cache bolt explains itself without widening into a label', (
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
            cacheHit: true,
            timestamp: DateTime(2026, 10, 15, 12),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.bolt_rounded)).size,
      closeTo(12.8, 0.001),
    );
    expect(find.text('命中上下文緩存'), findsNothing);

    await tester.tap(find.byIcon(Icons.bolt_rounded));
    await tester.pump();

    expect(find.byKey(const ValueKey('cache-hit-popover')), findsOneWidget);
    expect(find.text('已命中緩存'), findsOneWidget);

    // 點空白處收起
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('已命中緩存'), findsNothing);
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

  testWidgets('model memory proposal is confirmed inside the Memory branch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    MemoryActionProposal? actedProposal;
    String? decision;
    final proposal = MemoryActionProposal(
      id: 'proposal-inline-1',
      characterId: 'char-a',
      mode: 'romance',
      action: MemoryActionProposal.actionCreate,
      source: 'model',
      sourceConversationId: 'conv-a',
      sourceMessageId: 7,
      targetIds: const [],
      payload: const <String, dynamic>{
        'candidate': <String, dynamic>{
          'category': '偏好',
          'content': '小禾喜歡喝熱牛奶',
          'triggers': '熱牛奶',
        },
      },
      baseVersions: const <String, dynamic>{},
      fingerprint: 'inline-fingerprint',
      status: MemoryActionProposal.statusPending,
      createdAt: DateTime(2026, 8, 16),
      seenAt: null,
      resolvedAt: null,
      error: '',
      result: const <String, dynamic>{},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '<think>正在整理</think>正常回覆',
            isUser: false,
            captureMode: true,
            thinkingExpandedOverride: true,
            memoryLog: '◌ 模型記憶已送往待確認區\nDone',
            pendingMemoryActionCount: 1,
            pendingMemoryProposals: [proposal],
            onInlineMemoryProposal: (proposal, selectedDecision) async {
              actedProposal = proposal;
              decision = selectedDecision;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('模型想記住這件事'), findsOneWidget);
    expect(find.text('保存記憶'), findsOneWidget);
    await tester.tap(find.text('保存記憶'));
    await tester.pump();

    expect(actedProposal?.id, 'proposal-inline-1');
    expect(decision, MemoryGuardService.createDecisionUseNew);
    expect(tester.takeException(), isNull);
  });
}
