import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/sidebar/sidebar_accordion.dart';

void main() {
  testWidgets('external expansion changes notify after the build frame', (
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
    expect(coordinator.value, 'group');

    await tester.pumpWidget(buildSection(false));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
