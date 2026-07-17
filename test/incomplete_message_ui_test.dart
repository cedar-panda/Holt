import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('incomplete bubble shows status and retry action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    var retries = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '半段回覆',
            isUser: false,
            timestamp: DateTime(2026, 7, 17, 12),
            incomplete: true,
            onRetryIncomplete: () => retries++,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('回覆中斷'), findsOneWidget);
    expect(find.text('重試'), findsOneWidget);
    await tester.tap(find.text('重試'));
    expect(retries, 1);
  });
}
