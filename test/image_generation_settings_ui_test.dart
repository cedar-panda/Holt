import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/screens/tool_model_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/secure_storage_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureStorageTestMock secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'image_gen_provider': 'qwen',
    });
    secureStorage = SecureStorageTestMock()..install();
  });

  tearDown(() => secureStorage.uninstall());

  testWidgets('image settings expose independent multi-provider selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: ToolModelScreen()));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Qwen / DashScope'), findsOneWidget);
    expect(find.text('qwen-image-3.0-pro'), findsWidgets);

    await tester.tap(find.text('Qwen / DashScope').first);
    await tester.pumpAndSettle();

    expect(find.text('OpenRouter'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('xAI'), findsOneWidget);
    expect(find.text('API 中轉站'), findsOneWidget);
    expect(find.text('本地 API'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
