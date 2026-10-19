import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/chat_window_stats_service.dart';
import 'package:project_yanci/widgets/chat_window_status.dart';

void main() {
  testWidgets('window status uses the requested three-slider control', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ChatWindowStatusButton(
              color: Colors.white,
              accentColor: Colors.green,
              onPressed: () => tapped = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(CupertinoIcons.slider_horizontal_3), findsOneWidget);
    expect(
      tester.getSize(find.byType(ChatWindowStatusButton)),
      const Size(44, 44),
    );
    await tester.tap(find.byType(ChatWindowStatusButton));
    expect(tapped, isTrue);
  });

  testWidgets('window status attention uses three slow pulses', (tester) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatWindowStatusButton(
            color: Colors.white,
            accentColor: Colors.green,
            playAttention: true,
            onAttentionComplete: () => completed = true,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2900));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 120));
    expect(completed, isTrue);
  });

  testWidgets('compact window metrics fit a phone-width sheet', (tester) async {
    const snapshot = ChatWindowStatsSnapshot(
      recordedTokens: 18750,
      summaryCount: 12,
      worldbookCount: 3,
      cacheHitCount: 7,
      cacheReportingAvailable: true,
      memories: <ChatWindowMemoryRecord>[],
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatWindowStatusSheet(
              modelName: 'provider/very-long-model-name-for-layout-check',
              liveTokenCount: 0,
              initialSnapshot: snapshot,
              loadSnapshot: () async => snapshot,
              onChooseModel: () {},
              onLongScreenshot: () {},
              longScreenshotBusy: false,
              onEditMemory: (_, _, _) async {},
              onArchiveMemory: (_) async => true,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('18.8k'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('long screenshot lives below model switch in window status', (
    tester,
  ) async {
    var captures = 0;
    const snapshot = ChatWindowStatsSnapshot(
      recordedTokens: 0,
      summaryCount: 0,
      worldbookCount: 0,
      cacheHitCount: 0,
      cacheReportingAvailable: false,
      memories: <ChatWindowMemoryRecord>[],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatWindowStatusSheet(
            modelName: 'gemini-flash',
            liveTokenCount: 0,
            initialSnapshot: snapshot,
            loadSnapshot: () async => snapshot,
            onChooseModel: () {},
            onLongScreenshot: () => captures++,
            longScreenshotBusy: false,
            onEditMemory: (_, _, _) async {},
            onArchiveMemory: (_) async => true,
            accentColor: Colors.green,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('chat-window-long-screenshot')),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('chat-window-long-screenshot')))
          .dy,
      greaterThan(tester.getTopLeft(find.text('gemini-flash')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('chat-window-long-screenshot')));
    expect(captures, 1);
  });
}
