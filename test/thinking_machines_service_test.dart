import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/settings/api_settings.dart';
import 'package:project_yanci/services/thinking_machines_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('en');
    ThinkingMachinesService.lastUsage = <String, int>{};
  });

  test('builds an independent Anthropic Inkling request', () async {
    final service = ThinkingMachinesService(apiKey: 'tml-key');

    final body = await service.debugBuildBodyForTesting(
      messages: const <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Hello'},
      ],
      model: '',
      structuredPrompt: StructuredPrompt(
        staticPart: 'Character',
        profilePart: 'Profile',
        dynamicPart: 'Memory',
      ),
    );

    expect(body['model'], ThinkingMachinesService.defaultModel);
    expect(body['system'], 'Character\n\nProfile\n\nMemory');
    expect(body['thinking'], <String, dynamic>{'type': 'disabled'});
    expect(body.containsKey('output_config'), isFalse);
    final messages = body['messages'] as List;
    expect(messages.single['content'], 'Hello');
  });

  test('uses Inkling native effort when thinking is enabled', () async {
    final service = ThinkingMachinesService(
      apiKey: 'tml-key',
      thinkingEnabled: true,
      thinkingEffort: 'xhigh',
    );

    final body = await service.debugBuildBodyForTesting(
      messages: const <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Hello'},
      ],
      model: ThinkingMachinesService.defaultModel,
    );

    expect(body['output_config'], <String, dynamic>{'effort': 'xhigh'});
    expect(body.containsKey('thinking'), isFalse);
  });

  test('converts data URL images to Anthropic image blocks', () async {
    final service = ThinkingMachinesService(apiKey: 'tml-key');

    final body = await service.debugBuildBodyForTesting(
      messages: const <Map<String, String>>[
        <String, String>{
          'role': 'user',
          'content': 'Describe this',
          'image_data_url': 'data:image/png;base64,YWJj',
        },
      ],
      model: ThinkingMachinesService.defaultModel,
    );

    final messages = body['messages'] as List;
    final content = messages.single['content'] as List;
    expect(content.first['type'], 'image');
    expect(content.first['source']['type'], 'base64');
    expect(content.first['source']['media_type'], 'image/png');
    expect(content.first['source']['data'], 'YWJj');
  });

  test('parses non-streaming thinking, text, and usage', () async {
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/v1/messages'));
      expect(request.headers['x-api-key'], 'tml-key');
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'content': <Map<String, String>>[
            <String, String>{'type': 'thinking', 'thinking': 'reason'},
            <String, String>{'type': 'text', 'text': 'answer'},
          ],
          'usage': <String, int>{'input_tokens': 12, 'output_tokens': 7},
        }),
        200,
      );
    });
    final service = ThinkingMachinesService(
      apiKey: 'tml-key',
      thinkingEnabled: true,
      client: client,
    );

    final response = await service.sendMessage(
      messages: const <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Hello'},
      ],
      model: ThinkingMachinesService.defaultModel,
    );

    expect(response, '<think>reason</think>answer');
    expect(ThinkingMachinesService.lastUsage['prompt_tokens'], 12);
    expect(ThinkingMachinesService.lastUsage['completion_tokens'], 7);
  });

  test('parses Anthropic SSE without OpenRouter delta format', () async {
    final events = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'message_start',
        'message': <String, dynamic>{
          'usage': <String, int>{'input_tokens': 5, 'output_tokens': 0},
        },
      },
      <String, dynamic>{
        'type': 'content_block_start',
        'content_block': <String, String>{'type': 'thinking', 'thinking': ''},
      },
      <String, dynamic>{
        'type': 'content_block_delta',
        'delta': <String, String>{
          'type': 'thinking_delta',
          'thinking': 'reason',
        },
      },
      <String, dynamic>{'type': 'content_block_stop'},
      <String, dynamic>{
        'type': 'content_block_start',
        'content_block': <String, String>{'type': 'text', 'text': ''},
      },
      <String, dynamic>{
        'type': 'content_block_delta',
        'delta': <String, String>{'type': 'text_delta', 'text': 'answer'},
      },
      <String, dynamic>{'type': 'content_block_stop'},
      <String, dynamic>{
        'type': 'message_delta',
        'usage': <String, int>{'output_tokens': 9},
      },
      <String, dynamic>{'type': 'message_stop'},
    ];
    final sse = events.map((event) => 'data: ${jsonEncode(event)}\n\n').join();
    final client = MockClient((_) async {
      return http.Response(
        sse,
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
      );
    });
    final service = ThinkingMachinesService(
      apiKey: 'tml-key',
      thinkingEnabled: true,
      client: client,
    );

    final chunks = await service
        .sendMessageStream(
          messages: const <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'Hello'},
          ],
          model: ThinkingMachinesService.defaultModel,
        )
        .toList();

    expect(chunks.join(), '<think>reason</think>answer');
    expect(ThinkingMachinesService.lastUsage['prompt_tokens'], 5);
    expect(ThinkingMachinesService.lastUsage['completion_tokens'], 9);
  });

  test(
    'connection test uses Tinker count_tokens and its own key header',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/v1/messages/count_tokens'));
        expect(request.headers['x-api-key'], 'tml-key');
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], ThinkingMachinesService.defaultModel);
        return http.Response('{"input_tokens":3}', 200);
      });

      final count = await ThinkingMachinesService.testConnection(
        apiKey: 'tml-key',
        client: client,
      );

      expect(count, 3);
    },
  );

  test('Thinking Machines model never resolves to OpenRouter', () async {
    const model = ThinkingMachinesService.defaultModel;
    await ApiSettings.saveStarredModels(<String>[model]);
    await ApiSettings.rememberStarredModelProviders(const <String>[
      model,
    ], 'openrouter');

    final provider = await ApiSettings.resolveStarredModelProvider(model);

    expect(provider, 'thinking_machines');
    expect(
      await ApiSettings.getStarredModelProvider(model),
      'thinking_machines',
    );
  });

  test('Thinking Machines HTTP errors are localized independently', () async {
    final client = MockClient((_) async {
      return http.Response('{"error":{"message":"denied"}}', 403);
    });
    final service = ThinkingMachinesService(apiKey: 'bad', client: client);

    await expectLater(
      service.sendMessage(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'Hello'},
        ],
        model: ThinkingMachinesService.defaultModel,
      ),
      throwsA(
        isA<ThinkingMachinesException>().having(
          (error) => error.message,
          'message',
          contains('Tinker account'),
        ),
      ),
    );

    await L.setLocale('zh_TW');
    await expectLater(
      service.sendMessage(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'Hello'},
        ],
        model: ThinkingMachinesService.defaultModel,
      ),
      throwsA(
        isA<ThinkingMachinesException>().having(
          (error) => error.message,
          'message',
          contains('尚未取得'),
        ),
      ),
    );
  });

  test('Tinker 402 uses its own localized billing error', () async {
    final client = MockClient((_) async {
      return http.Response(
        '{"error":{"message":"insufficient account balance"}}',
        402,
      );
    });

    await expectLater(
      ThinkingMachinesService.testConnection(apiKey: 'tml-key', client: client),
      throwsA(
        isA<ThinkingMachinesException>()
            .having((error) => error.statusCode, 'statusCode', 402)
            .having(
              (error) => error.message,
              'message',
              allOf(contains('insufficient credits'), contains('balance')),
            ),
      ),
    );

    await L.setLocale('zh_TW');
    await expectLater(
      ThinkingMachinesService.testConnection(apiKey: 'tml-key', client: client),
      throwsA(
        isA<ThinkingMachinesException>().having(
          (error) => error.message,
          'message',
          contains('額度不足'),
        ),
      ),
    );

    await L.setLocale('zh_CN');
    await expectLater(
      ThinkingMachinesService.testConnection(apiKey: 'tml-key', client: client),
      throwsA(
        isA<ThinkingMachinesException>().having(
          (error) => error.message,
          'message',
          contains('额度不足'),
        ),
      ),
    );
  });
}
