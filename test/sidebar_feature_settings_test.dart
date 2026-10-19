import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/screens/cost_context_screen.dart';
import 'package:project_yanci/services/settings/user_settings.dart';
import 'package:project_yanci/widgets/help_switch_tile.dart';
import 'package:project_yanci/widgets/sidebar/sidebar_feature_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('avatar toggles inline without opening a settings page', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SidebarFeatureSettings())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(await UserSettings.getShowChatAvatar(), isTrue);
    expect(find.byType(CostContextScreen), findsNothing);
  });
  testWidgets('module switches appear immediately with no second accordion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CostContextScreen(section: CostContextSection.modules),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(HelpSwitchTile), findsWidgets);
  });
}
