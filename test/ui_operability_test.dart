import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/settings_manager.dart';
import 'package:project_yanci/widgets/character_signature_panel.dart';
import 'package:project_yanci/widgets/help_switch_tile.dart';
import 'package:project_yanci/widgets/orbit_loading_indicator.dart';
import 'package:project_yanci/widgets/sidebar/holt_sidebar_shell.dart';
import 'package:project_yanci/widgets/sidebar/sidebar_accordion.dart';
import 'package:project_yanci/widgets/sidebar/sidebar_behavior_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('sidebar numeric setting commits when its section loses focus', (
    tester,
  ) async {
    await MemorySettings.saveContextLimitEnabled(true);
    await MemorySettings.saveContextMessageLimit(20);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SidebarAccordionScope(
            coordinator: SidebarAccordionCoordinator(),
            child: const SingleChildScrollView(
              child: SidebarBehaviorSettings(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final countField = find.byType(TextFormField).first;
    await tester.enterText(countField, '37');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(await MemorySettings.getContextMessageLimit(), 37);
  });

  testWidgets('signature panel reflows instead of clipping large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(
            body: SizedBox(
              width: 260,
              child: CharacterSignaturePanel(
                signature: '今晚把窗留一條縫，我會帶著很長很長的故事回來。',
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final panelSize = tester.getSize(
      find.descendant(
        of: find.byType(CharacterSignaturePanel),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(panelSize.height, greaterThan(52));
  });

  testWidgets('help affordance keeps a usable transparent touch target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HelpSwitchTile(
            title: '測試設定',
            description: '測試說明',
            value: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final helpButton = tester.widget<IconButton>(find.byType(IconButton));
    expect(helpButton.constraints?.minWidth, 40);
    expect(helpButton.constraints?.minHeight, 40);
  });

  testWidgets('orbit loading indicator stays static with reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Center(
            child: OrbitLoadingIndicator(size: 20, color: Colors.blue),
          ),
        ),
      ),
    );
    final first = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<OrbitPainter>()
        .single
        .progress;
    await tester.pump(const Duration(seconds: 2));
    final second = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<OrbitPainter>()
        .single
        .progress;

    expect(second, first);
  });

  testWidgets('opening sidebar pauses background ticker mode', (tester) async {
    final shellKey = GlobalKey<HoltSidebarShellState>();
    await tester.pumpWidget(
      MaterialApp(
        home: HoltSidebarShell(
          key: shellKey,
          background: Builder(
            key: const ValueKey<String>('test-background'),
            builder: (context) => const SizedBox.expand(),
          ),
          sidebar: const SizedBox.expand(),
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    BuildContext backgroundContext = tester.element(
      find.byKey(const ValueKey<String>('test-background')),
    );
    expect(TickerMode.valuesOf(backgroundContext).enabled, isTrue);

    shellKey.currentState!.open();
    await tester.pump();
    backgroundContext = tester.element(
      find.byKey(const ValueKey<String>('test-background')),
    );
    expect(TickerMode.valuesOf(backgroundContext).enabled, isFalse);
  });
}
