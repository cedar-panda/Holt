import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_error_localizer.dart';
import 'package:project_yanci/services/app_error_log_service.dart';
import 'package:project_yanci/services/locale_strings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('localizes Gemini high-demand 503 without exposing raw JSON', () async {
    const error =
        'Exception: Gemini 錯誤 503: {"error":{"code":503,'
        '"message":"This model is currently experiencing high demand.",'
        '"status":"UNAVAILABLE"}}';

    await L.setLocale('zh_TW');
    final zhTw = ApiErrorLocalizer.userMessage(error);
    expect(zhTw, 'Gemini：服務商伺服器暫時異常，請稍後重試（HTTP 503）');
    expect(zhTw, isNot(contains('high demand')));
    expect(zhTw, isNot(contains('{')));

    await L.setLocale('zh_CN');
    expect(
      ApiErrorLocalizer.userMessage(error),
      'Gemini：服务商服务器暂时异常，请稍后重试（HTTP 503）',
    );

    await L.setLocale('en');
    expect(
      ApiErrorLocalizer.userMessage(error),
      'Gemini: The provider server is temporarily unavailable. Please try '
      'again later. (HTTP 503)',
    );
  });

  test(
    'localizes authentication, rate limit, and long-context errors',
    () async {
      await L.setLocale('zh_TW');

      expect(
        ApiErrorLocalizer.userMessage(
          Exception('OpenRouter API error 401: invalid api key'),
        ),
        'OpenRouter：API 金鑰無效或已失效，請到設定中檢查（HTTP 401）',
      );
      expect(
        ApiErrorLocalizer.userMessage(
          Exception('DeepSeek API error 429: too many requests'),
        ),
        'DeepSeek：目前請求過於頻繁，請稍等片刻後重試（HTTP 429）',
      );
      expect(
        ApiErrorLocalizer.userMessage(
          Exception('API error 400: maximum context length exceeded'),
        ),
        '對話內容超過此模型可接受的長度，請開啟新窗口或縮短內容後重試（HTTP 400）',
      );
    },
  );

  test(
    'unknown Chinese-locale errors become a safe localized fallback',
    () async {
      await L.setLocale('zh_CN');
      final message = ApiErrorLocalizer.userMessage(
        Exception('Opaque provider failure: internal shard abc-123'),
      );

      expect(message, '请求失败，请重试；若持续发生，可查看 Debug 日志');
      expect(message, isNot(contains('Opaque')));
    },
  );

  test('distinguishes 403 key limits and redacts copied logs', () async {
    await L.setLocale('zh_TW');
    final diagnosis = ApiErrorLocalizer.diagnose(
      Exception(
        'OpenRouter error 403: API key spending limit reached '
        'Authorization: Bearer sk-secret-value-12345',
      ),
    );

    expect(diagnosis.category, 'key_limit');
    expect(diagnosis.summary, 'OpenRouter：此 API 金鑰已達設定的用量或消費上限（HTTP 403）');
    expect(diagnosis.rawLog, contains('[REDACTED]'));
    expect(diagnosis.rawLog, isNot(contains('sk-secret-value-12345')));
    expect(
      ApiErrorLocalizer.sanitizeRawLog(
        'https://example.test?q=1&key=AIza123456789012345678901234567890',
      ),
      isNot(contains('AIza123456789012345678901234567890')),
    );
  });

  test(
    '429 credit errors are quota while other 429 errors are rate limits',
    () {
      expect(
        ApiErrorLocalizer.diagnose(
          Exception('API error 429: quota exhausted'),
        ).category,
        'quota',
      );
      expect(
        ApiErrorLocalizer.diagnose(
          Exception('API error 429: too many requests'),
        ).category,
        'rate_limit',
      );
    },
  );

  test(
    'missing API setup becomes a localized configuration diagnosis',
    () async {
      await L.setLocale('zh_TW');
      final diagnosis = ApiErrorLocalizer.diagnose(
        Exception('Gemini API Key 未設定'),
      );

      expect(diagnosis.category, 'configuration');
      expect(diagnosis.summary, 'Gemini：這個 API 來源尚未完成設定，請先補齊金鑰或節點資訊');
    },
  );

  test(
    'local diagnostic history never persists request conversation text',
    () async {
      const privateText = '這是不能寫進診斷紀錄的私人劇情';
      await AppErrorLogService.record(
        error: Exception(
          'API error 400: {"messages":[{"role":"user",'
          '"content":"$privateText"}],"error":{"code":"bad_request",'
          '"type":"invalid_request_error"}}',
        ),
        trigger: 'send_message',
        provider: 'test',
      );

      final rows = await AppErrorLogService.latest();
      expect(rows, hasLength(1));
      final raw = '${rows.single['raw_log']}';
      expect(raw, contains('code=bad_request'));
      expect(raw, contains('type=invalid_request_error'));
      expect(raw, isNot(contains(privateText)));
      expect(raw, isNot(contains('messages')));
    },
  );

  test('MetricKit disk-write payload is not mislabeled as a native crash', () {
    final descriptor = AppErrorLogService.classifyMetricKitPayloadText(
      '{"diskWriteExceptionDiagnostics":[{"diagnosticMetaData":{"writesCaused":"4295 MB"}}]}',
    );

    expect(descriptor.category, 'excessive_disk_writes');
    expect(descriptor.summary, contains('disk-write'));
    expect(descriptor.rawPrefix, contains('disk_write'));
  });

  test('MetricKit crash payload keeps the native crash category', () {
    final descriptor = AppErrorLogService.classifyMetricKitPayloadText(
      '{"crashDiagnostics":[{}]}',
    );

    expect(descriptor.category, 'native_crash');
    expect(descriptor.rawPrefix, contains('crash'));
  });
}
