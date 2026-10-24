import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/services/openai_compatible_service.dart';

void main() {
  final service = OpenAICompatibleService(
    apiKey: 'test',
    baseUrl: 'https://example.com/v1',
  );

  test('ordinary HTTP 400 does not trigger capability downgrade', () {
    final result = service.debugDowngradeBodyForTesting(<String, dynamic>{
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'developer', 'content': 'state'},
      ],
    }, '{"error":{"message":"quota exceeded"}}');

    expect(result, isNull);
  });

  test('explicit unsupported developer role downgrades once-ready body', () {
    final result = service.debugDowngradeBodyForTesting(<String, dynamic>{
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'developer', 'content': 'state'},
        <String, dynamic>{'role': 'user', 'content': 'hello'},
      ],
    }, '{"error":{"message":"developer role is not supported"}}');

    expect(result, isNotNull);
    expect((result!['messages'] as List).first['role'], 'system');
  });

  test('explicit unsupported cache_control removes only that field', () {
    final result = service.debugDowngradeBodyForTesting(<String, dynamic>{
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'system',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'stable',
              'cache_control': <String, String>{'type': 'ephemeral'},
            },
          ],
        },
      ],
    }, '{"error":{"message":"unknown field cache_control"}}');

    expect(result, isNotNull);
    expect(result.toString(), isNot(contains('cache_control')));
    expect(result.toString(), contains('stable'));
  });
}
