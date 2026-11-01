import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/desktop/desktop_layout.dart';
import 'package:project_yanci/widgets/sidebar/holt_sidebar_shell.dart';

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    key: const ValueKey('counter'),
    onPressed: () => setState(() => taps++),
    child: Text('taps $taps'),
  );
}

Widget _app() => const MaterialApp(
  home: HoltSidebarShell(
    sidebar: Text('SIDEBAR'),
    background: ColoredBox(color: Colors.blue),
    child: Scaffold(body: Center(child: _Counter())),
  ),
);

void main() {
  tearDown(() => DesktopLayout.debugIsDesktopOverride = null);

  testWidgets('mobile keeps the sidebar hidden in a drawer', (tester) async {
    DesktopLayout.debugIsDesktopOverride = false;
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    expect(find.byType(DesktopDockedShell), findsNothing);
  });

  testWidgets('wide desktop docks the sidebar and keeps state on resize', (
    tester,
  ) async {
    DesktopLayout.debugIsDesktopOverride = true;
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());

    expect(find.byType(DesktopDockedShell), findsOneWidget);
    expect(find.text('SIDEBAR'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('counter'))).dx,
      greaterThan(DesktopLayout.sidebarWidth),
    );

    await tester.tap(find.byKey(const ValueKey('counter')));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);

    // 縮窄成抽屜，再拉寬：計數不歸零。
    await tester.binding.setSurfaceSize(const Size(600, 820));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopDockedShell), findsNothing);
    expect(find.text('taps 1'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopDockedShell), findsOneWidget);
    expect(find.text('taps 1'), findsOneWidget);
  });

  testWidgets('content column is capped on wide desktop windows', (
    tester,
  ) async {
    DesktopLayout.debugIsDesktopOverride = true;
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopContentWidth(child: SizedBox.expand(key: ValueKey('c'))),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('c'))).width,
      DesktopLayout.contentMaxWidth,
    );
  });
}
