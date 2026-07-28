import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/call_tts_failure_policy.dart';

void main() {
  test('permanent client failures are treated as TTS configuration errors', () {
    expect(CallTtsFailurePolicy.isConfigurationStatus(400), isTrue);
    expect(CallTtsFailurePolicy.isConfigurationStatus(401), isTrue);
    expect(CallTtsFailurePolicy.isConfigurationStatus(403), isTrue);
    expect(CallTtsFailurePolicy.isConfigurationStatus(422), isTrue);
  });

  test('retryable failures remain eligible for poor-signal handling', () {
    expect(CallTtsFailurePolicy.isConfigurationStatus(408), isFalse);
    expect(CallTtsFailurePolicy.isConfigurationStatus(429), isFalse);
    expect(CallTtsFailurePolicy.isConfigurationStatus(500), isFalse);
    expect(CallTtsFailurePolicy.isConfigurationStatus(503), isFalse);
  });

  test('configuration exception exposes a user-safe reason', () {
    const error = CallTtsConfigurationException('OpenAI TTS API Key 未設定');
    expect(error.toString(), 'OpenAI TTS API Key 未設定');
  });
}
