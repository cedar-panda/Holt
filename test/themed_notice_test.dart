import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/themed_notice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('passive themed notice lets taps reach content behind it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Stack(
              children: [
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 18,
                  height: 64,
                  child: GestureDetector(
                    key: const ValueKey('content-behind-notice'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps += 1,
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: TextButton(
                    onPressed: () => showThemedPillNotice(
                      context,
                      'Saved',
                      duration: const Duration(milliseconds: 500),
                    ),
                    child: const Text('Show'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump(const Duration(milliseconds: 200));
    final notice = find.byKey(const ValueKey('themed-pill-notice'));
    expect(notice, findsOneWidget);
    expect(
      tester
          .getRect(notice)
          .overlaps(
            tester.getRect(find.byKey(const ValueKey('content-behind-notice'))),
          ),
      isTrue,
    );

    await tester.tapAt(tester.getCenter(notice));
    expect(taps, 1);
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('anchored notice stays above the composer edge', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final link = LayerLink();

    await tester.pumpWidget(
      MaterialApp(
        home: ThemedNoticeAnchorScope(
          link: link,
          child: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 24,
                    height: 72,
                    child: CompositedTransformTarget(
                      link: link,
                      child: const ColoredBox(
                        key: ValueKey('composer-edge'),
                        color: Colors.blue,
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: TextButton(
                      onPressed: () => showThemedPillNotice(
                        context,
                        'Identity ready',
                        duration: const Duration(milliseconds: 500),
                      ),
                      child: const Text('Show'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final noticeRect = tester.getRect(
      find.byKey(const ValueKey('themed-pill-notice')),
    );
    final composerRect = tester.getRect(
      find.byKey(const ValueKey('composer-edge')),
    );
    expect(noticeRect.bottom, closeTo(composerRect.top - 13, 0.01));
    expect(noticeRect.width, lessThan(400));
    expect(noticeRect.height, lessThan(64));
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('action notice keeps only its action interactive', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var actionCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showThemedPillNotice(
                  context,
                  'Request failed',
                  duration: const Duration(seconds: 2),
                  tone: ThemedNoticeTone.error,
                  action: ThemedNoticeAction(
                    label: 'Retry',
                    onPressed: () => actionCount += 1,
                  ),
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(actionCount, 1);
    expect(find.byKey(const ValueKey('themed-pill-notice')), findsNothing);
  });
}
