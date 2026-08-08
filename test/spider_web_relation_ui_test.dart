import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/spider_web_graph_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  setUp(() async {
    await L.setLocale('zh_TW');
  });

  testWidgets('zero-link web explains the state and exposes local scan', (
    tester,
  ) async {
    var requested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 720,
            child: SpiderWebGraphView(
              memories: _memories,
              links: const [],
              onNodeTapped: (_) {},
              onLinkTapped: (_, _, _) {},
              onNodePositionChanged: (_, _, _) {},
              onZeroLinksAction: () => requested = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2 節點'), findsOneWidget);
    expect(find.text('0 連線'), findsOneWidget);
    expect(find.text('本機記憶去重檢查'), findsOneWidget);
    await tester.tap(find.text('本機記憶去重檢查'));
    expect(requested, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relation badge remains an accessible list alternative', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: SizedBox(
              width: 390,
              height: 720,
              child: SpiderWebGraphView(
                memories: _memories,
                links: const [
                  {
                    'id': 1,
                    'memory_id_1': 1,
                    'memory_id_2': 2,
                    'status': 'suggested',
                    'relation_type': 'duplicate_candidate',
                    'strength': 0.91,
                  },
                ],
                onNodeTapped: (_) {},
                onLinkTapped: (_, _, _) {},
                onNodePositionChanged: (_, _, _) {},
                onLinksTapped: () => opened = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 連線'), findsOneWidget);
    expect(find.text('本機記憶去重檢查'), findsNothing);
    await tester.tap(find.text('1 連線'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('legacy free-drag positions are repaired onto visible web silk', () {
    const floating = Offset(0, 1900);
    final repaired = SpiderWebGraphView.snapSavedPositionForTesting(floating);

    expect(repaired, isNot(floating));
    expect(
      SpiderWebGraphView.visibleSlotCountForTesting(),
      greaterThanOrEqualTo(50),
    );
    expect(
      SpiderWebGraphView.maximumSlotRadiusForTesting(),
      lessThanOrEqualTo(1180),
    );
    final stable = SpiderWebGraphView.snapSavedPositionForTesting(repaired);
    expect((stable - repaired).distance, lessThan(0.001));
  });

  test('zoomed-out nodes keep a full-size drag target', () {
    for (final scale in [0.04, 0.08, 0.16, 0.34]) {
      expect(
        SpiderWebGraphView.screenDragTargetDiameterForTesting(scale: scale),
        greaterThanOrEqualTo(48),
      );
    }
  });

  test('a relation bends toward its own web instead of the canvas origin', () {
    final control = SpiderWebGraphView.edgeControlForTesting(
      start: const Offset(-920, -120),
      end: const Offset(-500, 100),
      webCenter: const Offset(-690, 0),
    );

    expect(control.dx, lessThan(-650));
    expect((control - const Offset(-690, 0)).distance, lessThan(30));
  });

  test('a single large web has its own higher inspection zoom limit', () {
    expect(SpiderWebGraphView.maximumScaleForTesting(webCount: 1), 3.6);
    expect(SpiderWebGraphView.maximumScaleForTesting(webCount: 2), 2.4);
    expect(SpiderWebGraphView.maximumScaleForTesting(webCount: 4), 2.4);
  });

  testWidgets(
    'pinch zoom wins when its first pointer starts on a draggable node',
    (tester) async {
      var tapped = false;
      var moved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SizedBox(
                width: 390,
                height: 720,
                child: SpiderWebGraphView(
                  memories: [_memories.first],
                  memoryGroups: [
                    [_memories.first],
                  ],
                  links: const [],
                  onNodeTapped: (_) => tapped = true,
                  onLinkTapped: (_, _, _) {},
                  onNodePositionChanged: (_, _, _) => moved = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      var viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final controller = viewer.transformationController!;
      final beforeScale = controller.value.getMaxScaleOnAxis();
      final slots = SpiderWebGraphView.visibleSlotCountForTesting();
      final localNode = SpiderWebGraphView.visibleSlotForTesting(slots ~/ 2);
      final screenNode = MatrixUtils.transformPoint(
        controller.value,
        const Offset(1600, 1600) + localNode,
      );
      final direction = screenNode.dx < 195 ? 1.0 : -1.0;

      final first = await tester.startGesture(screenNode, pointer: 1);
      await tester.pump();
      viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(viewer.scaleEnabled, isTrue);
      expect(viewer.maxScale, 3.6);

      final secondStart = screenNode + Offset(54 * direction, 0);
      final second = await tester.startGesture(secondStart, pointer: 2);
      await tester.pump();
      await first.moveTo(screenNode - Offset(44 * direction, 0));
      await second.moveTo(secondStart + Offset(44 * direction, 0));
      await tester.pump();

      expect(controller.value.getMaxScaleOnAxis(), greaterThan(beforeScale));
      await second.up();
      await first.up();
      await tester.pump();
      expect(tapped, isFalse);
      expect(moved, isFalse);
    },
  );

  test('single-web layers fit the viewport instead of opening over-zoomed', () {
    const viewport = Size(390, 650);
    const rightInset = 86.0;
    final scale = SpiderWebGraphView.fittedScaleForTesting(
      viewport: viewport,
      webCount: 1,
      rightInset: rightInset,
    );
    final content = SpiderWebGraphView.fittedContentSizeForTesting(webCount: 1);

    expect(scale, inInclusiveRange(0.08, 0.16));
    expect(scale, lessThan(0.72));
    expect(
      content.width * scale,
      lessThanOrEqualTo(viewport.width - rightInset - 28),
    );
    expect(content.height * scale, lessThanOrEqualTo(viewport.height - 36));
  });

  test('multi-web layers reserve room for the layer rail', () {
    final withoutRail = SpiderWebGraphView.fittedScaleForTesting(
      viewport: const Size(390, 650),
      webCount: 4,
    );
    final withRail = SpiderWebGraphView.fittedScaleForTesting(
      viewport: const Size(390, 650),
      webCount: 4,
      rightInset: 86,
    );

    expect(withRail, lessThan(withoutRail));
  });

  test('every layered web arrangement stays inside the usable viewport', () {
    const viewport = Size(390, 650);
    const rightInset = 86.0;
    for (var webCount = 1; webCount <= 4; webCount++) {
      final scale = SpiderWebGraphView.fittedScaleForTesting(
        viewport: viewport,
        webCount: webCount,
        rightInset: rightInset,
      );
      final content = SpiderWebGraphView.fittedContentSizeForTesting(
        webCount: webCount,
      );
      expect(
        content.width * scale,
        lessThanOrEqualTo(viewport.width - rightInset - 28),
        reason: 'webCount=$webCount should fit horizontally',
      );
      expect(
        content.height * scale,
        lessThanOrEqualTo(viewport.height - 36),
        reason: 'webCount=$webCount should fit vertically',
      );
    }
  });
}

const _memories = <Map<String, dynamic>>[
  {
    'id': 1,
    'category': '偏好',
    'content': '昭昭喜歡雨天',
    'mention_count': 1,
    'created_at': '2026-08-01T00:00:00.000',
  },
  {
    'id': 2,
    'category': '偏好',
    'content': '昭昭喜歡下雨',
    'mention_count': 1,
    'created_at': '2026-08-02T00:00:00.000',
  },
];
