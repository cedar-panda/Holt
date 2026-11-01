import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/sidebar/sidebar_accordion.dart';

void main() {
  testWidgets('external expansion restores without coordinating siblings', (
    tester,
  ) async {
    final coordinator = SidebarAccordionCoordinator();
    const sectionKey = ValueKey<String>('test-section');

    Widget buildSection(bool expanded) {
      return MaterialApp(
        home: SidebarAccordionScope(
          coordinator: coordinator,
          child: Scaffold(
            body: SidebarAccordionSection(
              key: sectionKey,
              id: 'test',
              relationGroup: 'group',
              initiallyExpanded: expanded,
              title: const Text('Section'),
              children: const <Widget>[Text('Body')],
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildSection(false));
    await tester.pumpWidget(buildSection(true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(coordinator.value, isNull);

    await tester.pumpWidget(buildSection(false));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual expansion activates the coordinator', (tester) async {
    final coordinator = SidebarAccordionCoordinator();
    await tester.pumpWidget(
      MaterialApp(
        home: SidebarAccordionScope(
          coordinator: coordinator,
          child: const Scaffold(
            body: SidebarAccordionSection(
              id: 'manual',
              relationGroup: 'group',
              title: Text('Section'),
              children: <Widget>[Text('Body')],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Section'));
    await tester.pump();

    expect(coordinator.value, 'group');
  });
}
