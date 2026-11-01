import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/background_preset.dart';
import 'package:project_yanci/widgets/gradient_background.dart';

void main() {
  testWidgets('bound home backgrounds use a feathered directional handoff', (
    tester,
  ) async {
    const first = BackgroundPreset(
      slot: 1,
      homePath: 'assets/images/holt_logo.png',
    );
    const second = BackgroundPreset(
      slot: 2,
      homePath: 'assets/images/holt_logo.png',
      homeOffsetX: .1,
    );
    var preset = first;
    var revision = 0;
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return GradientBackground(
              scope: YanciBackgroundScope.home,
              presetOverride: preset,
              transitionDirection: BackgroundTransitionDirection.rightToLeft,
              transitionRevision: revision,
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );

    update(() {
      preset = second;
      revision++;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('carousel progress directly drives the two-sided feather', (
    tester,
  ) async {
    const first = BackgroundPreset(
      slot: 1,
      homePath: 'assets/images/holt_logo.png',
    );
    const second = BackgroundPreset(
      slot: 2,
      homePath: 'assets/images/holt_logo.png',
      homeOffsetX: .1,
    );
    final transition = ValueNotifier<BackgroundSwipeTransition>(
      const BackgroundSwipeTransition(
        leftPreset: first,
        rightPreset: second,
        onlineReady: true,
      ),
    );
    addTearDown(transition.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: GradientBackground(
          scope: YanciBackgroundScope.home,
          presetOverride: first,
          swipeTransition: transition,
          child: const SizedBox.expand(),
        ),
      ),
    );

    expect(find.byType(ImageFiltered), findsNothing);
    transition.value = const BackgroundSwipeTransition(
      leftPreset: first,
      rightPreset: second,
      progress: .42,
      onlineReady: false,
    );
    await tester.pump();

    final crossfadeOpacityFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Opacity &&
          widget.key != const ValueKey('custom-background-visibility'),
    );
    expect(crossfadeOpacityFinder, findsNWidgets(2));
    expect(find.byType(ImageFiltered), findsOneWidget);
    final crossfadeLayers = tester
        .widgetList<Opacity>(crossfadeOpacityFinder)
        .toList();
    expect(crossfadeLayers.first.opacity, 1);
    expect(crossfadeLayers.last.opacity, greaterThan(0));
    expect(crossfadeLayers.last.opacity, lessThan(1));
    expect(tester.takeException(), isNull);

    // A character without a bound photo should still fade to the theme.
    transition.value = const BackgroundSwipeTransition(
      leftPreset: first,
      progress: .42,
      onlineReady: false,
    );
    await tester.pump();
    final themeHandoffLayers = tester
        .widgetList<Opacity>(crossfadeOpacityFinder)
        .toList();
    expect(themeHandoffLayers.first.opacity, lessThan(1));

    transition.value = const BackgroundSwipeTransition(
      leftPreset: second,
      rightPreset: second,
      onlineReady: true,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('tab background visibility can use an independent duration', (
    tester,
  ) async {
    var opacity = 0.0;
    late StateSetter setHostState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return GradientBackground(
              customBackgroundOpacity: opacity,
              transitionDuration: const Duration(seconds: 1),
              customBackgroundTransitionDuration: const Duration(
                milliseconds: 500,
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('custom-background-visibility')),
      findsNothing,
    );
    setHostState(() => opacity = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(const ValueKey('custom-background-visibility')),
      findsOneWidget,
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('card region blur uses a baked image without live blur filters', (
    tester,
  ) async {
    final file = File('assets/images/holt_logo.png');
    expect(file.existsSync(), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              height: 108,
              child: BakedCardRegionBlur(
                file: file,
                scale: 1,
                offsetX: 0,
                offsetY: 0,
                blur: 12,
                viewportSize: const Size(390, 844),
                regionOffset: const Offset(24, 120),
                devicePixelRatio: 1,
                overlayColor: Colors.black.withValues(alpha: .12),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
