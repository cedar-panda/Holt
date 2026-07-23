import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/aws_bedrock_service.dart';
import 'package:project_yanci/services/deepseek_service.dart';
import 'package:project_yanci/services/gemini_service.dart';
import 'package:project_yanci/services/openai_compatible_service.dart';
import 'package:project_yanci/services/qwen_service.dart';

const _sourceMessages = <Map<String, String>>[
  <String, String>{'role': 'assistant', 'content': 'previous reply'},
  <String, String>{'role': 'user', 'content': 'actual human message'},
];

final _structuredPrompt = StructuredPrompt(
  staticPart: 'STATIC EXACT',
  profilePart: 'PROFILE EXACT',
  dynamicPart: 'MEMORY + TIME + THINKING',
);

String _textContent(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .map((block) => block['text']?.toString() ?? '')
        .where((text) => text.isNotEmpty)
        .join();
  }
  return '';
}

Map _latestUser(List messages) {
  return messages.cast<Map>().lastWhere((message) => message['role'] == 'user');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'OpenAI-compatible keeps user text pure with cache off and on',
    () async {
      for (final cacheEnabled in <bool>[false, true]) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'enable_prompt_caching': cacheEnabled,
        });
        final service = OpenAICompatibleService(
          apiKey: 'test',
          baseUrl: 'https://example.com/v1',
        );
        final body = await service.debugBuildBodyForTesting(
          messages: _sourceMessages,
          model: '[A2-量]claude-sonnet-4-6-thinking',
          structuredPrompt: _structuredPrompt,
        );
        final messages = body['messages'] as List;
        final systemMessages = messages
            .cast<Map>()
            .where((message) => message['role'] == 'system')
            .toList();

        expect(_textContent(systemMessages.first['content']), 'STATIC EXACT');
        expect(
          _textContent(systemMessages.last['content']),
          'MEMORY + TIME + THINKING',
        );
        expect(
          _textContent(_latestUser(messages)['content']),
          'actual human message',
        );
      }
    },
  );

  test('Bedrock keeps static cache block and user text separate', () async {
    for (final cacheEnabled in <bool>[false, true]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'enable_prompt_caching': cacheEnabled,
      });
      final service = BedrockService(
        accessKeyId: 'test',
        secretAccessKey: 'test',
      );
      final body = await service.debugBuildBodyForTesting(
        messages: _sourceMessages,
        structuredPrompt: _structuredPrompt,
      );
      final system = body['system'] as List;
      final staticBlock = system.first as Map;

      expect(staticBlock['text'], 'STATIC EXACT');
      expect((system.last as Map)['text'], 'MEMORY + TIME + THINKING');
      expect(staticBlock.containsKey('cache_control'), cacheEnabled);
      expect(
        _textContent(_latestUser(body['messages'] as List)['content']),
        'actual human message',
      );
    }
  });

  test('DeepSeek and Qwen use system messages for runtime context', () {
    final deepSeekBody = DeepSeekService(apiKey: 'test')
        .debugBuildBodyForTesting(
          messages: _sourceMessages,
          model: 'deepseek-chat',
          structuredPrompt: _structuredPrompt,
        );
    final qwenBody = QwenService(apiKey: 'test').debugBuildBodyForTesting(
      messages: _sourceMessages,
      model: 'qwen-plus',
      structuredPrompt: _structuredPrompt,
    );

    for (final body in <Map<String, dynamic>>[deepSeekBody, qwenBody]) {
      final messages = body['messages'] as List;
      final systemMessages = messages
          .cast<Map>()
          .where((message) => message['role'] == 'system')
          .toList();
      expect(_textContent(systemMessages.first['content']), 'STATIC EXACT');
      expect(
        _textContent(systemMessages.last['content']),
        'MEMORY + TIME + THINKING',
      );
      expect(
        _textContent(_latestUser(messages)['content']),
        'actual human message',
      );
    }
  });

  test('Gemini does not mix runtime context into user cached contents', () {
    final body = GeminiService(apiKey: 'test').debugBuildBodyForTesting(
      messages: _sourceMessages,
      structuredPrompt: _structuredPrompt,
      activeCacheName: 'cachedContents/static-test',
    );

    expect(body.containsKey('cachedContent'), isFalse);
    final systemParts = (body['systemInstruction'] as Map)['parts'] as List;
    expect((systemParts[0] as Map)['text'], 'STATIC EXACT');
    expect((systemParts[1] as Map)['text'], 'PROFILE EXACT');
    expect((systemParts[2] as Map)['text'], 'MEMORY + TIME + THINKING');

    final contents = body['contents'] as List;
    final latestUser = contents.cast<Map>().lastWhere(
      (message) => message['role'] == 'user',
    );
    expect(_textContent(latestUser['parts']), 'actual human message');
  });
}
