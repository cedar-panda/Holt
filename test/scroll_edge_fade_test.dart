import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/scroll_edge_fade.dart';

void main() {
  testWidgets('supports a pure alpha-only edge fade', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 320,
          child: ScrollEdgeFade(
            controller: controller,
            topExtent: 100,
            bottomExtent: 76,
            blurSigma: 0,
            alwaysFadeTop: true,
            alwaysFadeBottom: true,
            child: ListView.builder(
              controller: controller,
              itemCount: 30,
              itemBuilder: (_, index) =>
                  SizedBox(height: 44, child: Text('Message $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final mask = tester.widget<ShaderMask>(find.byType(ShaderMask));
    expect(mask.blendMode, BlendMode.dstIn);
    expect(find.byType(BackdropFilter), findsNothing);

    final fade = tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade));
    expect(fade.alwaysFadeTop, isTrue);
    expect(fade.alwaysFadeBottom, isTrue);
  });

  testWidgets('retains optional edge blur for other surfaces', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 320,
          child: ScrollEdgeFade(
            controller: controller,
            child: ListView.builder(
              controller: controller,
              itemCount: 30,
              itemBuilder: (_, index) =>
                  SizedBox(height: 44, child: Text('Message $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });
}
