import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/screens/api_settings_screen.dart';
import 'package:project_yanci/screens/tool_model_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  testWidgets('API settings owns the default window summary model', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ApiSettingsScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final settingsList = find.byType(ListView).first;
    for (var i = 0; i < 5; i++) {
      await tester.drag(settingsList, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('gemini-3-flash'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool model screen no longer owns window summary selection', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ToolModelScreen()));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('gemini-3-flash'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
