import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/image_card_stack.dart';

void main() {
  testWidgets('multiple images swipe as separate rounded cards', (
    tester,
  ) async {
    String? heldPath;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ImageCardStack(
              paths: const <String>['/missing/a.png', '/missing/b.png'],
              onLongPress: (path) => heldPath = path,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-image-page-view')),
      findsOneWidget,
    );
    expect(find.text('1/2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('conversation-image-card-0')),
      findsOneWidget,
    );

    await tester.longPressAt(const Offset(400, 300));
    expect(heldPath, '/missing/a.png');

    await tester.drag(
      find.byKey(const ValueKey<String>('conversation-image-page-view')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('2/2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('conversation-image-card-1')),
      findsOneWidget,
    );
  });
}
