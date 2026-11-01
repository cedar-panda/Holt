import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/sse_stream.dart';

void main() {
  test('in-stream provider error is raised instead of ending silently', () {
    expect(
      () => StreamPayloadException.throwIfPresent(<String, Object?>{
        'error': <String, Object?>{'code': 502, 'message': 'upstream error'},
        'choices': <Object?>[
          <String, Object?>{'finish_reason': 'error'},
        ],
      }, provider: 'OpenRouter'),
      throwsA(
        isA<StreamPayloadException>().having(
          (e) => e.message,
          'message',
          allOf(contains('API 錯誤 502'), contains('upstream error')),
        ),
      ),
    );
  });

  test('normal chunks pass through', () {
    StreamPayloadException.throwIfPresent(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'delta': <String, Object?>{'content': 'hi'},
        },
      ],
    }, provider: 'OpenRouter');
  });
}
