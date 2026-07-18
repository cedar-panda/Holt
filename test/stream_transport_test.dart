import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/stream_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
  });

  test('long response startup is not limited by the old 30-second value', () {
    expect(
      StreamTransport.responseStartTimeout,
      greaterThan(const Duration(seconds: 30)),
    );
  });

  test(
    'response startup timeout becomes a localized retryable error',
    () async {
      await expectLater(
        StreamTransport.waitForResponseStart(
          Completer<int>().future,
          provider: 'Claude',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<ResponseStartTimeoutException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('Claude'), contains('等待開始回覆')),
          ),
        ),
      );
    },
  );
}
