import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/guide_entry.dart';

void main() {
  testWidgets('guide entry remains a 48px accessible target', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: GuideEntry(
              showIntro: false,
              reduceMotion: true,
              color: Colors.black,
              onTap: () => tapped = true,
              onIntroCompleted: () {},
            ),
          ),
        ),
      ),
    );

    final guideButton = find.byKey(const Key('guide_entry_button'));
    expect(guideButton, findsOneWidget);
    expect(tester.getSize(guideButton), const Size(48, 48));
    await tester.tap(guideButton);
    expect(tapped, isTrue);
  });

  testWidgets('reduced motion intro uses no repeating animation', (
    tester,
  ) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GuideEntry(
          showIntro: true,
          reduceMotion: true,
          color: Colors.black,
          onTap: () {},
          onIntroCompleted: () => completed = true,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 9));
    expect(completed, isTrue);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
