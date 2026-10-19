import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/widgets/sidebar/holt_sidebar_shell.dart';

void main() {
  testWidgets('left-edge drag opens and both dismiss paths close sidebar', (
    tester,
  ) async {
    final sidebarKey = GlobalKey<HoltSidebarShellState>();
    await tester.pumpWidget(
      MaterialApp(
        home: HoltSidebarShell(
          key: sidebarKey,
          background: const ColoredBox(color: Colors.black),
          sidebar: const Text('Sidebar content'),
          child: const Scaffold(body: Center(child: Text('Home content'))),
        ),
      ),
    );

    expect(find.text('Sidebar content'), findsNothing);

    await tester.dragFrom(const Offset(1, 300), const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(find.text('Sidebar content'), findsOneWidget);
    final inheritedStyle = DefaultTextStyle.of(
      tester.element(find.text('Sidebar content')),
    ).style;
    expect(inheritedStyle.decoration, isNot(TextDecoration.underline));

    expect(sidebarKey.currentState!.isOpen, isTrue);
    await tester.drag(
      find.byKey(const ValueKey('sidebar-dismiss-surface')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();

    expect(sidebarKey.currentState!.isClosed, isTrue);
    expect(find.text('Sidebar content'), findsNothing);

    await tester.dragFrom(const Offset(1, 300), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(sidebarKey.currentState!.isOpen, isTrue);

    await tester.tap(find.byKey(const ValueKey('sidebar-dismiss-surface')));
    await tester.pumpAndSettle();
    expect(sidebarKey.currentState!.isClosed, isTrue);
  });

  testWidgets('closing sidebar releases a focused numeric field', (
    tester,
  ) async {
    final sidebarKey = GlobalKey<HoltSidebarShellState>();
    await tester.pumpWidget(
      MaterialApp(
        home: HoltSidebarShell(
          key: sidebarKey,
          background: const ColoredBox(color: Colors.black),
          sidebar: const Material(
            child: TextField(
              key: ValueKey<String>('sidebar-count-field'),
              keyboardType: TextInputType.number,
            ),
          ),
          child: const Scaffold(body: Text('Home content')),
        ),
      ),
    );

    sidebarKey.currentState!.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-count-field')));
    await tester.pump();
    final fieldFocus = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(fieldFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    sidebarKey.currentState!.close();
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isFalse);
    expect(fieldFocus.hasFocus, isFalse);
  });
}
