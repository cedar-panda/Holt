import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/aws_bedrock_service.dart';
import 'package:project_yanci/services/deepseek_service.dart';
import 'package:project_yanci/services/gemini_service.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/openai_compatible_service.dart';
import 'package:project_yanci/services/openrouter_service.dart';
import 'package:project_yanci/services/qwen_service.dart';

const _sourceMessages = <Map<String, String>>[
  <String, String>{'role': 'assistant', 'content': 'previous reply'},
  <String, String>{'role': 'user', 'content': 'actual human message'},
];

final _structuredPrompt = StructuredPrompt(
  staticPart: 'STATIC EXACT',
  profilePart: 'PROFILE EXACT',
  windowPart: 'WINDOW EXACT',
  controlPart: 'THINKING CONTROL',
  liveStatePart: 'MEMORY + CURRENT TIME=09:30',
);

String _textContent(dynamic content) {
  if (content is String) return content;
  if (content is Map) return content['text']?.toString() ?? '';
  if (content is List) {
    return content
        .whereType<Map>()
        .map((block) => block['text']?.toString() ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
  return '';
}

Map _latestUser(List messages) {
  return messages.cast<Map>().lastWhere((message) => message['role'] == 'user');
}

void _expectNoRuntimeInUserMessages(List messages) {
  final users = messages.cast<Map>().where(
    (message) => message['role'] == 'user',
  );
  for (final user in users) {
    final text = _textContent(user['content']);
    expect(text, isNot(contains('MEMORY + TIME + THINKING')));
    expect(text, isNot(contains('App Runtime Context')));
    expect(text, isNot(contains('App 即時背景')));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('en');
  });

  test('Claude mid-conversation system support is model-gated', () {
    expect(
      RuntimeContextSidecar.supportsClaudeMidConversationSystem(
        'anthropic/claude-opus-4.8',
      ),
      isTrue,
    );
    expect(
      RuntimeContextSidecar.supportsClaudeMidConversationSystem(
        'claude-opus-5',
      ),
      isTrue,
    );
    expect(
      RuntimeContextSidecar.supportsClaudeMidConversationSystem(
        'claude-mythos-5',
      ),
      isTrue,
    );
    expect(
      RuntimeContextSidecar.supportsClaudeMidConversationSystem(
        'claude-opus-4-6',
      ),
      isFalse,
    );
    expect(
      RuntimeContextSidecar.supportsClaudeMidConversationSystem(
        'claude-sonnet-5',
      ),
      isFalse,
    );
  });

  test('OpenAI-compatible Claude 4.6 uses cached assistant state', () async {
    for (final cacheEnabled in <bool>[false, true]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'enable_prompt_caching': cacheEnabled,
      });
      final body =
          await OpenAICompatibleService(
            apiKey: 'test',
            baseUrl: 'https://example.com/v1',
          ).debugBuildBodyForTesting(
            messages: _sourceMessages,
            model: '[A2-量]claude-opus-4-6-thinking',
            structuredPrompt: _structuredPrompt,
          );
      final messages = body['messages'] as List;
      final systems = messages
          .cast<Map>()
          .where((message) => message['role'] == 'system')
          .toList();

      expect(_textContent(systems.first['content']), contains('STATIC EXACT'));
      expect(
        systems.map((message) => _textContent(message['content'])).join('\n'),
        isNot(contains('MEMORY + CURRENT TIME=09:30')),
      );
      expect(
        systems.map((message) => _textContent(message['content'])).join('\n'),
        contains('THINKING CONTROL'),
      );
      final assistant = messages.cast<Map>().firstWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(
        _textContent(assistant['content']),
        contains('MEMORY + CURRENT TIME=09:30'),
      );
      expect(
        _textContent(_latestUser(messages)['content']),
        'actual human message',
      );
      _expectNoRuntimeInUserMessages(messages);
      expect(_sourceMessages.last['content'], 'actual human message');
    }
  });

  test(
    'OpenRouter keeps image and caption as unmodified user content',
    () async {
      for (final cacheEnabled in <bool>[false, true]) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'enable_prompt_caching': cacheEnabled,
        });
        final body = await OpenRouterService(apiKey: 'test')
            .debugBuildBodyForTesting(
              messages: const [
                {
                  'role': 'user',
                  'content': 'look at this image',
                  'image_data_url': 'data:image/png;base64,YWJj',
                },
              ],
              model: 'anthropic/claude-sonnet-4',
              structuredPrompt: _structuredPrompt,
            );

        final messages = body['messages'] as List;
        final blocks = _latestUser(messages)['content'] as List;
        expect(blocks, hasLength(2));
        expect((blocks.first as Map)['type'], 'image_url');
        expect(
          ((blocks.first as Map)['image_url'] as Map)['url'],
          'data:image/png;base64,YWJj',
        );
        expect((blocks.last as Map)['text'], 'look at this image');
        expect(
          blocks.cast<Map>().any((block) => block.containsKey('cache_control')),
          isFalse,
        );
        _expectNoRuntimeInUserMessages(messages);
        final runtimeSystem = messages.cast<Map>().lastWhere(
          (message) =>
              message['role'] == 'system' &&
              _textContent(
                message['content'],
              ).contains('MEMORY + CURRENT TIME=09:30'),
        );
        expect(
          _textContent(runtimeSystem['content']),
          contains('MEMORY + CURRENT TIME=09:30'),
        );
      }
    },
  );

  test('Bedrock Claude 4.6 keeps runtime after assistant breakpoint', () async {
    for (final cacheEnabled in <bool>[false, true]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'enable_prompt_caching': cacheEnabled,
      });
      final body =
          await BedrockService(
            accessKeyId: 'test',
            secretAccessKey: 'test',
            modelId: 'anthropic.claude-opus-4-6-v1:0',
          ).debugBuildBodyForTesting(
            messages: _sourceMessages,
            structuredPrompt: _structuredPrompt,
          );
      final system = body['system'] as List;

      expect((system[0] as Map)['text'], 'STATIC EXACT');
      expect((system[2] as Map)['text'], 'WINDOW EXACT');
      expect((system.last as Map).containsKey('cache_control'), cacheEnabled);
      expect(
        system.map((block) => _textContent(block)).join('\n'),
        isNot(contains('MEMORY + CURRENT TIME=09:30')),
      );
      final messages = body['messages'] as List;
      final assistant = messages.cast<Map>().firstWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(
        _textContent(assistant['content']),
        contains('MEMORY + CURRENT TIME=09:30'),
      );
      expect(
        _textContent(_latestUser(messages)['content']),
        'actual human message',
      );
      _expectNoRuntimeInUserMessages(messages);
    }
  });

  test('supported Claude appends runtime as a real system message', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
    });
    final body = await OpenRouterService(apiKey: 'test')
        .debugBuildBodyForTesting(
          messages: _sourceMessages,
          model: 'anthropic/claude-opus-4.8',
          structuredPrompt: _structuredPrompt,
        );
    final messages = body['messages'] as List;

    expect((messages.last as Map)['role'], 'system');
    expect(
      _textContent((messages.last as Map)['content']),
      contains('MEMORY + CURRENT TIME=09:30'),
    );
    expect(
      _textContent(_latestUser(messages)['content']),
      'actual human message',
    );
    _expectNoRuntimeInUserMessages(messages);
  });

  test('DeepSeek and Qwen use a separate system runtime message', () {
    final bodies = <Map<String, dynamic>>[
      DeepSeekService(apiKey: 'test').debugBuildBodyForTesting(
        messages: _sourceMessages,
        model: 'deepseek-chat',
        structuredPrompt: _structuredPrompt,
      ),
      QwenService(apiKey: 'test').debugBuildBodyForTesting(
        messages: _sourceMessages,
        model: 'qwen-plus',
        structuredPrompt: _structuredPrompt,
      ),
    ];

    for (final body in bodies) {
      final messages = body['messages'] as List;
      final systems = messages
          .cast<Map>()
          .where((message) => message['role'] == 'system')
          .toList();
      expect(_textContent(systems.first['content']), 'STATIC EXACT');
      expect(_textContent(systems[2]['content']), 'WINDOW EXACT');
      expect(
        _textContent(systems.last['content']),
        contains('MEMORY + CURRENT TIME=09:30'),
      );
      expect(
        _textContent(_latestUser(messages)['content']),
        'actual human message',
      );
      _expectNoRuntimeInUserMessages(messages);
    }
  });

  test('Gemini uses systemInstruction and never user content for runtime', () {
    final body = GeminiService(apiKey: 'test').debugBuildBodyForTesting(
      messages: _sourceMessages,
      structuredPrompt: _structuredPrompt,
      activeCacheName: 'cachedContents/static-test',
    );

    expect(body['cachedContent'], 'cachedContents/static-test');
    expect(body.containsKey('systemInstruction'), isFalse);

    final contents = body['contents'] as List;
    final modelState = contents.cast<Map>().firstWhere(
      (message) => message['role'] == 'model',
    );
    expect(
      _textContent(modelState['parts']),
      contains('MEMORY + CURRENT TIME=09:30'),
    );
    expect(
      _textContent(_latestUser(contents)['parts']),
      'actual human message',
    );
    _expectNoRuntimeInUserMessages(
      contents
          .cast<Map>()
          .map(
            (message) => <String, dynamic>{
              'role': message['role'],
              'content': message['parts'],
            },
          )
          .toList(),
    );
    expect(_sourceMessages.last['content'], 'actual human message');
  });

  test('stable control language follows the App UI locale', () async {
    await L.setLocale('zh_TW');
    final traditional = SystemContextControl.compose('');
    expect(traditional, contains('App UI 語言是繁體中文'));
    expect(traditional, contains('user'));

    await L.setLocale('zh_CN');
    final simplified = SystemContextControl.compose('');
    expect(simplified, contains('App UI 语言是简体中文'));
    expect(simplified, contains('user'));

    await L.setLocale('en');
    final english = SystemContextControl.compose('');
    expect(english, contains('App UI language is English'));
    expect(english, contains('user'));
  });

  test('changing time preserves the supported Claude cached prefix', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
      'app_locale': 'en',
    });
    await L.setLocale('en');
    CacheSession.conversationId = 'dynamic-time-cache-test';
    OpenRouterService.resetCacheChannelCheckpointsForTesting();
    final service = OpenRouterService(apiKey: 'test');

    Future<Map<String, dynamic>> build(String time) {
      return service.debugBuildBodyForTesting(
        messages: _sourceMessages,
        model: 'anthropic/claude-opus-4.8',
        structuredPrompt: StructuredPrompt(
          staticPart: 'STATIC EXACT',
          profilePart: 'PROFILE EXACT',
          windowPart: 'WINDOW EXACT',
          liveStatePart: 'CURRENT TIME=$time',
        ),
      );
    }

    final firstMessages = (await build('09:30'))['messages'] as List;
    final secondMessages = (await build('09:31'))['messages'] as List;

    expect(secondMessages.length, firstMessages.length);
    for (var i = 0; i < firstMessages.length - 1; i++) {
      expect(secondMessages[i], equals(firstMessages[i]));
    }
    expect(
      _textContent((firstMessages.last as Map)['content']),
      contains('09:30'),
    );
    expect(
      _textContent((secondMessages.last as Map)['content']),
      contains('09:31'),
    );
    expect((firstMessages.last as Map)['role'], 'system');
    expect((secondMessages.last as Map)['role'], 'system');
    _expectNoRuntimeInUserMessages(secondMessages);
  });

  test(
    'changing time preserves only stable system blocks on Claude 4.6',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'enable_prompt_caching': true,
      });
      final service = OpenRouterService(apiKey: 'test');

      Future<List> build(String time) async {
        final body = await service.debugBuildBodyForTesting(
          messages: _sourceMessages,
          model: 'anthropic/claude-opus-4.6',
          structuredPrompt: StructuredPrompt(
            staticPart: 'STATIC EXACT',
            profilePart: 'PROFILE EXACT',
            windowPart: 'WINDOW EXACT',
            liveStatePart: 'CURRENT TIME=$time',
          ),
        );
        return body['messages'] as List;
      }

      final first = await build('09:30');
      final second = await build('09:31');
      expect(second.first, equals(first.first));
      final firstAssistant = first.cast<Map>().firstWhere(
        (message) => message['role'] == 'assistant',
      );
      final secondAssistant = second.cast<Map>().firstWhere(
        (message) => message['role'] == 'assistant',
      );
      final firstBlocks = firstAssistant['content'] as List;
      final secondBlocks = secondAssistant['content'] as List;
      expect(firstBlocks.first, equals(secondBlocks.first));
      expect(_textContent(firstBlocks.last), contains('09:30'));
      expect(_textContent(secondBlocks.last), contains('09:31'));
      expect((secondBlocks.first as Map).containsKey('cache_control'), isTrue);
      _expectNoRuntimeInUserMessages(second);
    },
  );
}
