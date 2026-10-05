import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:project_yanci/services/deepseek_service.dart';
import 'package:project_yanci/services/gemini_service.dart';
import 'package:project_yanci/services/openai_compatible_service.dart';
import 'package:project_yanci/services/openrouter_service.dart';
import 'package:project_yanci/services/xai_service.dart';

void main() {
  test(
    'Gemini model discovery uses its own header and filters methods',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url,
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
        );
        expect(request.url.query, isEmpty);
        expect(request.headers['x-goog-api-key'], 'gemini-test-key');
        return http.Response(
          jsonEncode(<String, Object?>{
            'models': <Object?>[
              <String, Object?>{
                'name': 'models/gemini-3.6-flash',
                'displayName': 'Gemini 3.6 Flash',
                'supportedGenerationMethods': <String>['generateContent'],
              },
              <String, Object?>{
                'name': 'models/gemini-embedding-2',
                'supportedGenerationMethods': <String>['embedContent'],
              },
            ],
          }),
          200,
        );
      });

      final models = await GeminiService.fetchModels(
        'gemini-test-key',
        client: client,
      );

      expect(models.map((model) => model.id), <String>['gemini-3.6-flash']);
    },
  );

  test('Gemini embedding discovery exposes only embedding models', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'models': <Object?>[
            <String, Object?>{
              'name': 'models/gemini-3.6-flash',
              'supportedGenerationMethods': <String>['generateContent'],
            },
            <String, Object?>{
              'name': 'models/gemini-embedding-2',
              'displayName': 'Gemini Embedding 2',
              'supportedGenerationMethods': <String>['embedContent'],
            },
          ],
        }),
        200,
      );
    });

    final models = await GeminiService.fetchEmbeddingModels(
      'gemini-test-key',
      client: client,
    );

    expect(models.map((model) => model.id), <String>['gemini-embedding-2']);
  });

  test('xAI model discovery follows the language-models schema', () async {
    final client = MockClient((request) async {
      expect(request.url, Uri.parse('https://api.x.ai/v1/language-models'));
      expect(request.headers['authorization'], 'Bearer xai-test-key');
      return http.Response(
        jsonEncode(<String, Object?>{
          'models': <Object?>[
            <String, Object?>{
              'id': 'grok-4.5',
              'input_modalities': <String>['text', 'image'],
              'output_modalities': <String>['text'],
              'aliases': <String>['grok-latest'],
            },
          ],
        }),
        200,
      );
    });

    final models = await XaiService.fetchModels('xai-test-key', client: client);

    expect(models.single.id, 'grok-4.5');
    expect(models.single.inputModalities, <String>['text', 'image']);
  });

  test('DeepSeek model discovery parses the official list response', () async {
    final client = MockClient((request) async {
      expect(request.url, Uri.parse('https://api.deepseek.com/models'));
      expect(request.headers['authorization'], 'Bearer deepseek-test-key');
      return http.Response(
        jsonEncode(<String, Object?>{
          'object': 'list',
          'data': <Object?>[
            <String, Object?>{'id': 'deepseek-v4-pro'},
            <String, Object?>{'id': 'deepseek-v4-flash'},
          ],
        }),
        200,
      );
    });

    final models = await DeepSeekService.fetchModels(
      'deepseek-test-key',
      client: client,
    );

    expect(models.map((model) => model.id), <String>[
      'deepseek-v4-flash',
      'deepseek-v4-pro',
    ]);
  });

  test(
    'OpenRouter discovery keeps its credential and metadata isolated',
    () async {
      final client = MockClient((request) async {
        expect(request.url, Uri.parse('https://openrouter.ai/api/v1/models'));
        expect(request.headers['authorization'], 'Bearer openrouter-test-key');
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 'openai/gpt-5-mini',
                'name': 'OpenAI: GPT-5 Mini',
                'architecture': <String, Object?>{
                  'input_modalities': <String>['text'],
                  'output_modalities': <String>['text'],
                },
              },
            ],
          }),
          200,
        );
      });

      final models = await OpenRouterService.fetchModels(
        'openrouter-test-key',
        client: client,
      );

      expect(models.single.id, 'openai/gpt-5-mini');
    },
  );

  test('OpenRouter embedding discovery uses its dedicated catalogue', () async {
    final client = MockClient((request) async {
      expect(
        request.url,
        Uri.parse('https://openrouter.ai/api/v1/embeddings/models'),
      );
      return http.Response(
        jsonEncode(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 'openai/text-embedding-3-small',
              'name': 'Text Embedding 3 Small',
            },
            <String, Object?>{'id': 'openai/gpt-5-mini', 'name': 'GPT 5 Mini'},
          ],
        }),
        200,
      );
    });

    final models = await OpenRouterService.fetchEmbeddingModels(
      'openrouter-test-key',
      client: client,
    );

    expect(models.map((model) => model.id), <String>[
      'openai/text-embedding-3-small',
    ]);
  });

  test(
    'official OpenAI base URL falls back to the standard models API',
    () async {
      final client = MockClient((request) async {
        expect(request.url, Uri.parse('https://api.openai.com/v1/models'));
        expect(request.headers['authorization'], 'Bearer openai-test-key');
        return http.Response(
          jsonEncode(<String, Object?>{
            'object': 'list',
            'data': <Object?>[
              <String, Object?>{'id': 'gpt-5-mini'},
            ],
          }),
          200,
        );
      });

      final models = await OpenAICompatibleService.fetchModels(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'openai-test-key',
        client: client,
      );

      expect(models.single.id, 'gpt-5-mini');
    },
  );

  test('OpenAI-compatible 403 error exposes the relay reason safely', () {
    final message = OpenAICompatibleService.httpErrorMessage(
      403,
      jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'message': 'The selected model is not enabled for this API key.',
        },
      }),
    );

    expect(message, contains('403'));
    expect(message, contains('selected model is not enabled'));
  });

  test('OpenAI-compatible model discovery includes a 403 reason', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/pricing') {
        return http.Response('', 404);
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'error': <String, String>{
            'message': 'Model listing is disabled for this token.',
          },
        }),
        403,
      );
    });

    await expectLater(
      OpenAICompatibleService.fetchModels(
        baseUrl: 'https://relay.example/v1',
        apiKey: 'relay-test-key',
        client: client,
      ),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains(
            'Model listing is disabled for this token.',
          ),
        ),
      ),
    );
  });

  test('OpenAI-compatible HTML errors are not echoed into the UI', () {
    final message = OpenAICompatibleService.httpErrorMessage(
      403,
      '<!doctype html><html><body>gateway diagnostics</body></html>',
    );

    expect(message, contains('403'));
    expect(message, isNot(contains('gateway diagnostics')));
  });
}
