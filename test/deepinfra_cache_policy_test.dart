import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/cache/deepinfra_cache_policy.dart';

void main() {
  setUp(DeepInfraCachePolicy.resetForTesting);

  test('supported DeepInfra model opens one-hour explicit retention', () {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': 'stable system'},
      <String, dynamic>{'role': 'assistant', 'content': 'stable history'},
      <String, dynamic>{'role': 'system', 'content': 'live state'},
      <String, dynamic>{'role': 'user', 'content': 'latest input'},
    ];
    final body = <String, dynamic>{'messages': messages};
    final now = DateTime(2026, 10, 11, 9);

    DeepInfraCachePolicy.decorateRequest(
      body: body,
      messages: messages,
      model: 'moonshotai/Kimi-K2.7-Code',
      sessionId: 'story-a',
      breakpointIndex: 1,
      enabled: true,
      now: now,
    );

    expect(body['prompt_cache_key'], contains('story-a'));
    expect(body['prompt_cache_options'], <String, String>{
      'mode': 'explicit',
      'ttl': '1h',
    });
    final boundary = messages[1]['content'] as List<dynamic>;
    expect((boundary.last as Map)['prompt_cache_breakpoint'], <String, String>{
      'mode': 'explicit',
    });

    final second = <String, dynamic>{'messages': messages};
    DeepInfraCachePolicy.decorateRequest(
      body: second,
      messages: messages,
      model: 'moonshotai/Kimi-K2.7-Code',
      sessionId: 'story-a',
      breakpointIndex: 1,
      enabled: true,
      now: now.add(const Duration(minutes: 30)),
    );
    expect(second['prompt_cache_key'], body['prompt_cache_key']);
    expect(second, isNot(contains('prompt_cache_options')));
  });

  test('DeepInfra DeepSeek receives a stable key without unsupported TTL', () {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': 'hello'},
    ];
    final body = <String, dynamic>{'messages': messages};

    DeepInfraCachePolicy.decorateRequest(
      body: body,
      messages: messages,
      model: 'deepseek-ai/DeepSeek-V3.2',
      sessionId: 'story-a',
      breakpointIndex: 0,
      enabled: true,
    );

    expect(body['prompt_cache_key'], 'holt:story-a:deepseek-ai/deepseek-v3.2');
    expect(body, isNot(contains('prompt_cache_options')));
    expect(messages.single['content'], 'hello');
  });
}
