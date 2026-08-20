import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/screens/profile_screen.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Profile edits the existing global system prompt setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'system_prompt': 'legacy communication guide',
    });

    await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('profile_system_prompt_field'));
    expect(
      tester.widget<TextField>(field).controller?.text,
      'legacy communication guide',
    );

    await tester.enterText(field, 'be warm and direct');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(await ApiSettings.getSystemPrompt(), 'be warm and direct');
  });
}
