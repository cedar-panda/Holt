import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:project_yanci/services/image_generation/image_generation_client.dart';
import 'package:project_yanci/services/image_generation/image_generation_provider.dart';

void main() {
  final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  final pngBase64 = base64Encode(png);

  test(
    'OpenRouter uses the dedicated Images API and parses b64_json',
    () async {
      late Map<String, dynamic> body;
      final client = ImageGenerationClient(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://openrouter.ai/api/v1/images');
          expect(request.headers['Authorization'], 'Bearer or-key');
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <Object>[
                <String, String>{'b64_json': pngBase64},
              ],
            }),
            200,
          );
        }),
      );

      final image = await client.generate(
        config: const ImageGenerationConfig(
          provider: ImageGenerationProvider.openRouter,
          model: 'vendor/image-model',
          apiKey: 'or-key',
        ),
        prompt: 'portrait',
      );

      expect(body, containsPair('model', 'vendor/image-model'));
      expect(body, containsPair('prompt', 'portrait'));
      expect(image.bytes, png);
      expect(image.mimeType, 'image/png');
    },
  );

  test('Gemini requests IMAGE modality and parses inlineData', () async {
    late Map<String, dynamic> body;
    final client = ImageGenerationClient(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://generativelanguage.googleapis.com/v1/models/'
          'gemini-3.1-flash-image:generateContent',
        );
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object>{
            'candidates': <Object>[
              <String, Object>{
                'content': <String, Object>{
                  'parts': <Object>[
                    <String, Object>{
                      'inlineData': <String, String>{
                        'mimeType': 'image/png',
                        'data': pngBase64,
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final image = await client.generate(
      config: const ImageGenerationConfig(
        provider: ImageGenerationProvider.gemini,
        model: 'gemini-3.1-flash-image',
        apiKey: 'gemini-key',
      ),
      prompt: 'landscape',
    );

    expect((body['generationConfig'] as Map)['responseModalities'], <String>[
      'IMAGE',
    ]);
    expect(image.bytes, png);
  });

  test('xAI parses a signed HTTPS URL and downloads the image', () async {
    var calls = 0;
    final client = ImageGenerationClient(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          expect(request.url.path, '/v1/images/generations');
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <Object>[
                <String, String>{
                  'url': 'https://imgen.x.ai/generated/result.jpeg',
                  'mime_type': 'image/jpeg',
                },
              ],
            }),
            200,
          );
        }
        expect(request.url.host, 'imgen.x.ai');
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );

    final image = await client.generate(
      config: const ImageGenerationConfig(
        provider: ImageGenerationProvider.xai,
        model: 'grok-imagine-image-2.0',
        apiKey: 'xai-key',
      ),
      prompt: 'street art',
    );

    expect(calls, 2);
    expect(image.mimeType, 'image/png');
  });

  test('Qwen parses the multimodal generation response URL', () async {
    var calls = 0;
    final client = ImageGenerationClient(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          expect(
            request.url.path,
            '/api/v1/services/aigc/multimodal-generation/generation',
          );
          return http.Response(
            jsonEncode(<String, Object>{
              'output': <String, Object>{
                'choices': <Object>[
                  <String, Object>{
                    'message': <String, Object>{
                      'content': <Object>[
                        <String, String>{
                          'image':
                              'https://dashscope-result.oss-cn.example/a.png',
                        },
                      ],
                    },
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );

    final image = await client.generate(
      config: const ImageGenerationConfig(
        provider: ImageGenerationProvider.qwen,
        model: 'qwen-image-3.0-pro',
        apiKey: 'qwen-key',
      ),
      prompt: 'poster',
    );

    expect(calls, 2);
    expect(image.bytes, png);
  });

  test(
    'compatible relay normalizes endpoint and surfaces 403 reason',
    () async {
      final client = ImageGenerationClient(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://relay.example/v1/images/generations',
          );
          return http.Response(
            jsonEncode(<String, Object>{
              'error': <String, String>{'message': 'image channel is disabled'},
            }),
            403,
          );
        }),
      );

      await expectLater(
        client.generate(
          config: const ImageGenerationConfig(
            provider: ImageGenerationProvider.openAICompatible,
            model: 'gpt-image-1',
            apiKey: 'relay-key',
            baseUrl: 'https://relay.example/v1/chat/completions',
          ),
          prompt: 'portrait',
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                '$error'.contains('403') &&
                '$error'.contains('image channel is disabled'),
          ),
        ),
      );
    },
  );

  test('compatible endpoint resolver accepts base and full endpoint forms', () {
    expect(
      ImageGenerationClient.imagesUriForBase('https://relay.example'),
      Uri.parse('https://relay.example/v1/images/generations'),
    );
    expect(
      ImageGenerationClient.imagesUriForBase(
        'https://relay.example/v1/images/generations',
      ),
      Uri.parse('https://relay.example/v1/images/generations'),
    );
  });
}
