import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/models/chat_session_identity.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/gemini_service.dart';
import 'package:project_yanci/services/locale_strings.dart';

String _text(int length, String value) =>
    List<String>.filled(length, value, growable: false).join();

ChatSessionIdentity _identity(String conversationId) =>
    ChatSessionIdentity.fromConversation(
      expectedConversationId: conversationId,
      conversation: Conversation(
        id: conversationId,
        characterId: 'char-a',
        contextMode: ContextMode.rp,
        continuityId: 'main',
        userPersonaId: 'persona-a',
      ),
    );

Map<String, dynamic> _successResponse() => <String, dynamic>{
  'candidates': <Map<String, dynamic>>[
    <String, dynamic>{
      'content': <String, dynamic>{
        'parts': <Map<String, String>>[
          <String, String>{'text': 'ok'},
        ],
      },
    },
  ],
  'usageMetadata': <String, int>{
    'promptTokenCount': 5100,
    'candidatesTokenCount': 1,
    'cachedContentTokenCount': 4700,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
    });
    await L.setLocale('zh_TW');
  });

  test(
    'Gemini caches stable history, removes it from request, and reuses it',
    () async {
      var createCount = 0;
      final createBodies = <Map<String, dynamic>>[];
      final generationBodies = <Map<String, dynamic>>[];

      final service = GeminiService(
        apiKey: 'history-cache-test-key',
        modelId: 'gemini-3.8-flash',
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/cachedContents')) {
            createCount++;
            createBodies.add(body);
            return http.Response(
              jsonEncode(<String, String>{
                'name': 'cachedContents/history-$createCount',
              }),
              200,
            );
          }
          generationBodies.add(body);
          return http.Response(jsonEncode(_successResponse()), 200);
        }),
      );

      final messages = <Map<String, String>>[
        <String, String>{'role': 'user', 'content': _text(5000, 'u')},
        <String, String>{'role': 'assistant', 'content': _text(5000, 'a')},
        <String, String>{'role': 'user', 'content': _text(5000, 'v')},
        <String, String>{'role': 'assistant', 'content': 'latest assistant'},
        <String, String>{'role': 'user', 'content': 'latest user'},
      ];
      final prompt = StructuredPrompt(
        sessionIdentity: _identity('gemini-history-window-a'),
        staticPart: _text(5000, 's'),
        liveStatePart: 'current memory',
      );

      ApiUsage? firstUsage;
      await service.sendMessage(
        messages: messages,
        model: 'gemini-3.8-flash',
        structuredPrompt: prompt,
        onUsage: (usage) => firstUsage = usage,
      );
      await service.sendMessage(
        messages: messages,
        model: 'gemini-3.8-flash',
        structuredPrompt: prompt,
      );

      expect(createCount, 1);
      expect(firstUsage?.cacheReadTokens, 4700);
      expect(firstUsage?.raw['cache_history_messages'], 3);

      final cachedHistory = createBodies.single['contents'] as List;
      expect(cachedHistory, hasLength(3));
      expect(cachedHistory.first['role'], 'user');
      expect(cachedHistory.last['role'], 'user');

      for (final body in generationBodies) {
        expect(body['cachedContent'], 'cachedContents/history-1');
        expect(body.containsKey('systemInstruction'), isFalse);
        final uncachedTail = body['contents'] as List;
        expect(uncachedTail, hasLength(2));
        expect(uncachedTail.first['role'], 'model');
        expect(uncachedTail.last['role'], 'user');
        expect(jsonEncode(uncachedTail.first), contains('current memory'));
      }

      final otherPrompt = prompt.copyWith(
        sessionIdentity: _identity('gemini-history-window-b'),
      );
      await service.sendMessage(
        messages: messages,
        model: 'gemini-3.8-flash',
        structuredPrompt: otherPrompt,
      );
      expect(createCount, 2);
      expect(
        generationBodies.last['cachedContent'],
        'cachedContents/history-2',
      );
    },
  );

  test('below-threshold static prompt can qualify with old chat history', () {
    final prompt = StructuredPrompt(
      sessionIdentity: _identity('gemini-history-threshold'),
      staticPart: _text(4000, 's'),
    );
    final shortMessages = <Map<String, String>>[
      <String, String>{'role': 'assistant', 'content': 'old reply'},
      <String, String>{'role': 'user', 'content': 'latest'},
    ];
    final longMessages = <Map<String, String>>[
      <String, String>{'role': 'user', 'content': _text(9000, 'u')},
      <String, String>{'role': 'assistant', 'content': _text(9000, 'a')},
      <String, String>{'role': 'user', 'content': _text(9000, 'v')},
      <String, String>{'role': 'assistant', 'content': 'latest reply'},
      <String, String>{'role': 'user', 'content': 'latest'},
    ];

    expect(
      GeminiService.hasCacheableExplicitPrefix(
        prompt: prompt,
        messages: shortMessages,
        model: 'gemini-3.8-flash',
      ),
      isFalse,
    );
    expect(
      GeminiService.hasCacheableExplicitPrefix(
        prompt: prompt,
        messages: longMessages,
        model: 'gemini-3.8-flash',
      ),
      isTrue,
    );
  });

  test('stream reports MAX_TOKENS instead of silently completing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': false,
    });
    final service = GeminiService(
      apiKey: 'stream-test-key',
      clientFactory: () => MockClient((_) async {
        return http.Response(
          'data: ${jsonEncode(<String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{
                'content': <String, Object?>{
                  'parts': <Object?>[
                    <String, Object?>{'text': 'partial reply'},
                  ],
                },
                'finishReason': 'MAX_TOKENS',
              },
            ],
          })}\n\n',
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
        );
      }),
    );

    await expectLater(
      service.sendMessageStream(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'hello'},
        ],
        model: 'gemini-3.8-flash',
      ),
      emitsInOrder(<Object>[
        'partial reply',
        emitsError(isA<GeminiResponseTruncatedException>()),
      ]),
    );
  });

  test('thought-only stream retries once and returns a final reply', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': false,
    });
    var requestCount = 0;
    final bodies = <Map<String, dynamic>>[];
    final service = GeminiService(
      apiKey: 'thought-retry-key',
      modelId: 'gemini-3.8-flash',
      thinkingEnabled: true,
      clientFactory: () => MockClient((request) async {
        requestCount++;
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final part = requestCount == 1
            ? <String, Object?>{'text': '思考內容', 'thought': true}
            : <String, Object?>{'text': '正式回覆'};
        return http.Response.bytes(
          utf8.encode(
            'data: ${jsonEncode(<String, Object?>{
              'candidates': <Object?>[
                <String, Object?>{
                  'content': <String, Object?>{
                    'parts': <Object?>[part],
                  },
                  'finishReason': 'STOP',
                },
              ],
            })}\n\n',
          ),
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
        );
      }),
    );

    final chunks = await service
        .sendMessageStream(
          messages: const <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'hello'},
          ],
          model: 'gemini-3.8-flash',
        )
        .toList();

    expect(chunks.join(), '<think>思考內容</think>正式回覆');
    expect(requestCount, 2);
    final firstConfig = bodies.first['generationConfig'] as Map;
    final retryConfig = bodies.last['generationConfig'] as Map;
    expect(firstConfig['thinkingConfig'], <String, Object?>{
      'includeThoughts': true,
    });
    expect(retryConfig['thinkingConfig'], <String, Object?>{
      'thinkingLevel': 'low',
      'includeThoughts': false,
    });
  });
}
