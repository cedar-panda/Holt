import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:project_yanci/services/tool_runner.dart';
import 'package:project_yanci/services/web_search_service.dart';

void main() {
  group('OpenRouter web search provider', () {
    test('sends bounded server-tool request and parses citations', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url, OpenRouterWebSearchProvider.endpoint);
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer or-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'anthropic/claude-sonnet-4');
        expect(body['max_tool_calls'], 1);
        final messages = body['messages'] as List;
        expect(messages, hasLength(2));
        expect(messages.last['content'], 'Taipei weather today');
        expect(request.body, isNot(contains('character profile')));
        final tools = body['tools'] as List;
        final tool = tools.single as Map<String, dynamic>;
        expect(tool['type'], 'openrouter:web_search');
        final parameters = tool['parameters'] as Map<String, dynamic>;
        expect(parameters['max_uses'], 1);
        expect(parameters['max_results'], 5);
        expect(parameters['max_total_results'], 5);
        expect(parameters['max_characters'], 2000);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'Taipei is sunny.',
                  'annotations': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'type': 'url_citation',
                      'url_citation': <String, dynamic>{
                        'url': 'https://weather.example/taipei',
                        'title': 'Weather source',
                        'content': 'Forecast excerpt',
                        'start_index': 0,
                        'end_index': 6,
                      },
                    },
                  ],
                },
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 20,
              'completion_tokens': 8,
              'cost': 0.012,
              'server_tool_use': <String, int>{'web_search_requests': 1},
            },
          }),
          200,
        );
      });
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'or-key',
        model: 'anthropic/claude-sonnet-4',
        clientFactory: () => client,
      );

      final result = await provider.search(
        WebSearchRequest(query: 'Taipei weather today'),
        ToolCancellationController().token,
      );

      expect(result.provider, WebSearchProviderId.openRouter);
      expect(result.text, 'Taipei is sunny.');
      expect(result.sources.single.url, 'https://weather.example/taipei');
      expect(result.sources.single.snippet, 'Forecast excerpt');
      expect(result.citations.single.sourceIndex, 0);
      expect(result.usage.searchRequests, 1);
      expect(result.usage.actualCostUsd, 0.012);
      expect(result.usage.costCertainty, WebSearchCostCertainty.known);
    });

    test('rejects redirects without forwarding authorization', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          307,
          headers: <String, String>{'location': 'https://evil.example/steal'},
        );
      });
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'or-secret-key',
        model: 'openrouter/auto',
        clientFactory: () => client,
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>()
              .having(
                (error) => error.code,
                'code',
                WebSearchFailureCode.redirectRejected,
              )
              .having(
                (error) => error.toString(),
                'safe message',
                isNot(contains('or-secret-key')),
              ),
        ),
      );
      expect(calls, 1);
    });

    test('drops unsafe and duplicate citation URLs', () async {
      final annotations = <Map<String, dynamic>>[
        _openRouterAnnotation('javascript:alert(1)', 'bad'),
        _openRouterAnnotation('https://127.0.0.1/private', 'loopback'),
        _openRouterAnnotation('https://localhost./private', 'localhost'),
        _openRouterAnnotation('https://10.0.0.5/private', 'private'),
        _openRouterAnnotation('https://2130706433/private', 'numeric host'),
        _openRouterAnnotation('https://0177.0.0.1/private', 'octal host'),
        _openRouterAnnotation('https://0x7f.0.0.1/private', 'hex host'),
        _openRouterAnnotation('https://[::1]/private', 'ipv6 loopback'),
        _openRouterAnnotation(
          'https://[0:0:0:0:0:0:0:1]/private',
          'expanded ipv6 loopback',
        ),
        _openRouterAnnotation(
          'https://[0:0:0:0:0:ffff:7f00:1]/private',
          'mapped ipv6 loopback',
        ),
        _openRouterAnnotation('https://[ff02::1]/private', 'ipv6 multicast'),
        _openRouterAnnotation('https://safe.example./story', 'trailing dot'),
        _openRouterAnnotation('https://safe.example:8443/story', 'custom port'),
        _openRouterAnnotation(
          'https://user:password@safe.example/private',
          'userinfo',
        ),
        _openRouterAnnotation('https://safe.example/story', 'safe'),
        _openRouterAnnotation('https://safe.example/story', 'duplicate'),
      ];
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'key',
        model: 'openrouter/auto',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'content': 'Grounded answer',
                    'annotations': annotations,
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );

      final result = await provider.search(
        WebSearchRequest(query: 'safe query'),
        ToolCancellationController().token,
      );

      expect(result.sources, hasLength(1));
      expect(result.sources.single.url, 'https://safe.example/story');
    });

    test('rejects an answer with no safe structured source', () async {
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'key',
        model: 'openrouter/auto',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'content': 'Unsupported citation only',
                    'annotations': <Map<String, dynamic>>[
                      _openRouterAnnotation('file:///private', 'bad'),
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.ungrounded,
          ),
        ),
      );
    });

    test('caps the provider response before JSON decoding', () async {
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'key',
        model: 'openrouter/auto',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            List<String>.filled(1024 * 1024 + 1, 'x').join(),
            200,
          ),
        ),
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.responseTooLarge,
          ),
        ),
      );
    });

    test('raw provider errors never enter the public message', () async {
      const secret = 'sk-super-secret-provider-body';
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'key',
        model: 'openrouter/auto',
        clientFactory: () =>
            MockClient((_) async => http.Response('{"error":"$secret"}', 401)),
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>()
              .having(
                (error) => error.code,
                'code',
                WebSearchFailureCode.authentication,
              )
              .having(
                (error) => error.toString(),
                'safe message',
                isNot(contains(secret)),
              ),
        ),
      );
    });
  });

  group('Gemini web search provider', () {
    test(
      'keeps the key out of the URI and parses grounding metadata',
      () async {
        final client = MockClient((request) async {
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'generativelanguage.googleapis.com');
          expect(request.url.query, isEmpty);
          expect(request.headers['x-goog-api-key'], 'gem-key');
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final tools = body['tools'] as List;
          expect(tools.single, <String, dynamic>{
            'google_search': <String, dynamic>{},
          });
          final contents = body['contents'] as List;
          expect(contents.single['parts'].single['text'], 'Euro 2024 winner');
          expect(request.body, isNot(contains('persona')));
          return http.Response(
            jsonEncode(<String, dynamic>{
              'candidates': <Map<String, dynamic>>[
                <String, dynamic>{
                  'content': <String, dynamic>{
                    'parts': <Map<String, String>>[
                      <String, String>{'text': 'Spain won Euro 2024.'},
                    ],
                  },
                  'groundingMetadata': <String, dynamic>{
                    'webSearchQueries': <String>[
                      'UEFA Euro 2024 winner',
                      'Euro 2024 final result',
                    ],
                    'searchEntryPoint': <String, String>{
                      'renderedContent': '<script>must not escape</script>',
                    },
                    'groundingChunks': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'web': <String, String>{
                          'uri': 'https://uefa.example/euro-2024',
                          'title': 'UEFA',
                        },
                      },
                      <String, dynamic>{
                        'web': <String, String>{
                          'uri': 'https://localhost/private',
                          'title': 'bad',
                        },
                      },
                    ],
                    'groundingSupports': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'segment': <String, int>{
                          'startIndex': 0,
                          'endIndex': 5,
                        },
                        'groundingChunkIndices': <int>[0, 1, 99],
                      },
                    ],
                  },
                },
              ],
              'usageMetadata': <String, int>{
                'promptTokenCount': 15,
                'candidatesTokenCount': 6,
              },
            }),
            200,
          );
        });
        final provider = GeminiWebSearchProvider(
          apiKey: 'gem-key',
          model: 'google/gemini-2.5-flash',
          clientFactory: () => client,
        );

        final result = await provider.search(
          WebSearchRequest(query: 'Euro 2024 winner'),
          ToolCancellationController().token,
        );

        expect(result.model, 'gemini-2.5-flash');
        expect(result.text, 'Spain won Euro 2024.');
        expect(result.sources, hasLength(1));
        expect(result.citations, hasLength(1));
        expect(result.executedQueries, hasLength(2));
        expect(result.usage.searchRequests, 1);
        expect(result.usage.actualCostUsd, isNull);
        expect(result.usage.costCertainty, WebSearchCostCertainty.unknown);
        expect(result.attribution?.provider, WebSearchProviderId.gemini);
        expect(
          result.attribution?.renderedContent,
          '<script>must not escape</script>',
        );
        expect(result.text, isNot(contains('script')));
      },
    );

    test('Gemini 3 counts unique non-empty search queries', () async {
      final provider = GeminiWebSearchProvider(
        apiKey: 'gem-key',
        model: 'gemini-3.1-flash',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(
              _geminiResponse(
                queries: const <String>[
                  'first query',
                  '',
                  'first query',
                  'second query',
                ],
              ),
            ),
            200,
          ),
        ),
      );

      final result = await provider.search(
        WebSearchRequest(query: 'safe query'),
        ToolCancellationController().token,
      );

      expect(result.executedQueries, <String>['first query', 'second query']);
      expect(result.usage.searchRequests, 2);
    });

    test(
      'Gemini 3 billing count is independent from display sanitizing',
      () async {
        final sharedPrefix = List<String>.filled(241, 'x').join();
        final provider = GeminiWebSearchProvider(
          apiKey: 'gem-key',
          model: 'gemini-3-flash',
          clientFactory: () => MockClient(
            (_) async => http.Response(
              jsonEncode(
                _geminiResponse(
                  queries: <String>['${sharedPrefix}a', '${sharedPrefix}b'],
                ),
              ),
              200,
            ),
          ),
        );

        final result = await provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        );

        expect(result.executedQueries, hasLength(1));
        expect(result.usage.searchRequests, 2);
      },
    );

    test('Gemini 3 fails closed without billable query metadata', () async {
      final provider = GeminiWebSearchProvider(
        apiKey: 'gem-key',
        model: 'gemini-3-flash',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(_geminiResponse(queries: const <String>['', '   '])),
            200,
          ),
        ),
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.invalidResponse,
          ),
        ),
      );
    });

    test('caps grounded sources to the requested result limit', () async {
      final response = _geminiResponse(queries: const <String>['safe query']);
      final candidate =
          (response['candidates'] as List).single as Map<String, dynamic>;
      final metadata = candidate['groundingMetadata'] as Map<String, dynamic>;
      final chunks = metadata['groundingChunks'] as List<Map<String, dynamic>>;
      chunks.add(<String, dynamic>{
        'web': <String, String>{
          'uri': 'https://second.example/source',
          'title': 'Second source',
        },
      });
      final provider = GeminiWebSearchProvider(
        apiKey: 'gem-key',
        model: 'gemini-2.5-flash',
        clientFactory: () =>
            MockClient((_) async => http.Response(jsonEncode(response), 200)),
      );

      final result = await provider.search(
        WebSearchRequest(query: 'safe query', maxResults: 1),
        ToolCancellationController().token,
      );

      expect(result.sources, hasLength(1));
    });

    test('fails closed when required Search attribution is missing', () async {
      final response = _geminiResponse(queries: const <String>['safe query']);
      final candidate =
          (response['candidates'] as List).single as Map<String, dynamic>;
      final metadata = candidate['groundingMetadata'] as Map<String, dynamic>;
      metadata.remove('searchEntryPoint');
      final provider = GeminiWebSearchProvider(
        apiKey: 'gem-key',
        model: 'gemini-2.5-flash',
        clientFactory: () =>
            MockClient((_) async => http.Response(jsonEncode(response), 200)),
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.invalidResponse,
          ),
        ),
      );
    });

    test('unsupported model fails before an HTTP client is created', () async {
      var clientsCreated = 0;
      final provider = GeminiWebSearchProvider(
        apiKey: 'gem-key',
        model: 'gemini-1.5-flash',
        clientFactory: () {
          clientsCreated++;
          return MockClient((_) async => http.Response('{}', 200));
        },
      );

      await expectLater(
        provider.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.unsupportedModel,
          ),
        ),
      );
      expect(clientsCreated, 0);
    });
  });

  group('query privacy', () {
    test('normalizes the App underscore locale before provider use', () {
      expect(
        WebSearchRequest(query: 'safe query', locale: 'zh_TW').locale,
        'zh-TW',
      );
      expect(
        WebSearchRequest(query: 'safe query', locale: 'zh_CN').locale,
        'zh-CN',
      );
    });

    test('credentials are blocked before configuration or HTTP', () {
      expect(
        () => WebSearchRequest(
          query: 'find Bearer abcdefghijklmnopqrstuvwxyz012345',
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.secretDetected,
          ),
        ),
      );
      expect(
        () => WebSearchRequest(
          query: 'find ghp_abcdefghijklmnopqrstuvwxyz123456',
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.secretDetected,
          ),
        ),
      );
      expect(
        () =>
            WebSearchRequest(query: 'api_key=abcdefghijklmnopqrstuvwxyz123456'),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.secretDetected,
          ),
        ),
      );
      expect(
        () => WebSearchRequest(query: 'ASIAABCDEFGHIJKLMNOP'),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.secretDetected,
          ),
        ),
      );
      expect(
        () => WebSearchRequest(
          query: 'AWS_SECRET_ACCESS_KEY=abcdefghijklmnopqrstuvwxyz123456',
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.secretDetected,
          ),
        ),
      );
    });

    test('personal data needs an app-side confirmation', () {
      expect(
        () => WebSearchRequest(query: 'look up person@example.com'),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.sensitiveQueryConfirmationRequired,
          ),
        ),
      );
      expect(
        WebSearchRequest(
          query: 'look up person@example.com',
          sensitiveQueryConfirmed: true,
        ).query,
        contains('person@example.com'),
      );
    });
  });

  group('hybrid provider selection', () {
    test('requires provider consent before loading keys or settings', () async {
      final configurationSource = _CountingConfigurationSource();
      final service = HybridWebSearchService(
        configurationSource: configurationSource,
        providerFactory: _FailingFactory(),
      );

      await expectLater(
        service.search(
          WebSearchRequest(query: 'safe query'),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.providerConsentRequired,
          ),
        ),
      );
      expect(configurationSource.loads, 0);
    });

    test('prefers the current chat provider and stops after success', () async {
      final gemini = _RecordingProvider(WebSearchProviderId.gemini);
      final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(
          _configuration(current: 'openrouter'),
        ),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            }),
      );

      final result = await service.search(
        WebSearchRequest(
          query: 'safe query',
          allowedProviders: const <WebSearchProviderId>{
            WebSearchProviderId.openRouter,
          },
        ),
        ToolCancellationController().token,
      );

      expect(result.provider, WebSearchProviderId.openRouter);
      expect(result.attemptedProviders, <WebSearchProviderId>[
        WebSearchProviderId.openRouter,
      ]);
      expect(openRouter.calls, 1);
      expect(gemini.calls, 0);
    });

    test('does not cross providers without explicit consent', () async {
      final gemini = _RecordingProvider(
        WebSearchProviderId.gemini,
        failures: <WebSearchProviderException>[
          const WebSearchProviderException(
            code: WebSearchFailureCode.rateLimited,
            safeMessage: 'Gemini rate limited.',
            retryable: true,
            crossProviderFallbackAllowed: true,
            statusCode: 429,
          ),
        ],
      );
      final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(
          _configuration(current: 'gemini'),
        ),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            }),
      );

      await expectLater(
        service.search(
          WebSearchRequest(
            query: 'safe query',
            allowedProviders: const <WebSearchProviderId>{
              WebSearchProviderId.gemini,
              WebSearchProviderId.openRouter,
            },
          ),
          ToolCancellationController().token,
        ),
        throwsA(isA<WebSearchProviderException>()),
      );
      expect(gemini.calls, 1);
      expect(openRouter.calls, 0);
    });

    test(
      'falls back at most once after a cost-certain preflight failure',
      () async {
        final gemini = _RecordingProvider(
          WebSearchProviderId.gemini,
          failures: <WebSearchProviderException>[
            const WebSearchProviderException(
              code: WebSearchFailureCode.unsupportedModel,
              safeMessage: 'Gemini model is unsupported.',
              retryable: true,
              crossProviderFallbackAllowed: true,
              costCertainty: WebSearchCostCertainty.known,
            ),
          ],
        );
        final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
        final service = HybridWebSearchService(
          configurationSource: _StaticConfigurationSource(
            _configuration(current: 'gemini'),
          ),
          providerFactory: _RecordingProviderFactory(
            <WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            },
          ),
        );

        final result = await service.search(
          WebSearchRequest(
            query: 'safe query',
            allowCrossProviderFallback: true,
            allowedProviders: const <WebSearchProviderId>{
              WebSearchProviderId.gemini,
              WebSearchProviderId.openRouter,
            },
          ),
          ToolCancellationController().token,
        );

        expect(result.provider, WebSearchProviderId.openRouter);
        expect(result.attemptedProviders, <WebSearchProviderId>[
          WebSearchProviderId.gemini,
          WebSearchProviderId.openRouter,
        ]);
        expect(gemini.calls, 1);
        expect(openRouter.calls, 1);
      },
    );

    test(
      'does not double-send after a cost-uncertain provider failure',
      () async {
        final gemini = _RecordingProvider(
          WebSearchProviderId.gemini,
          failures: <WebSearchProviderException>[
            const WebSearchProviderException(
              code: WebSearchFailureCode.unavailable,
              safeMessage: 'Gemini unavailable.',
              retryable: true,
              crossProviderFallbackAllowed: true,
              costCertainty: WebSearchCostCertainty.unknown,
              statusCode: 503,
            ),
          ],
        );
        final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
        final service = HybridWebSearchService(
          configurationSource: _StaticConfigurationSource(
            _configuration(current: 'gemini'),
          ),
          providerFactory: _RecordingProviderFactory(
            <WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            },
          ),
        );

        await expectLater(
          service.search(
            WebSearchRequest(
              query: 'safe query',
              allowCrossProviderFallback: true,
              allowedProviders: const <WebSearchProviderId>{
                WebSearchProviderId.gemini,
                WebSearchProviderId.openRouter,
              },
            ),
            ToolCancellationController().token,
          ),
          throwsA(isA<WebSearchProviderException>()),
        );
        expect(gemini.calls, 1);
        expect(openRouter.calls, 0);
      },
    );

    test('a cancelled first provider never falls back', () async {
      final controller = ToolCancellationController();
      final gemini = _RecordingProvider(
        WebSearchProviderId.gemini,
        onSearch: () => controller.cancel('stop'),
      );
      final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(
          _configuration(current: 'gemini'),
        ),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            }),
      );

      await expectLater(
        service.search(
          WebSearchRequest(
            query: 'safe query',
            allowCrossProviderFallback: true,
            allowedProviders: const <WebSearchProviderId>{
              WebSearchProviderId.gemini,
              WebSearchProviderId.openRouter,
            },
          ),
          controller.token,
        ),
        throwsA(isA<ToolCancelledException>()),
      );
      expect(openRouter.calls, 0);
    });

    test('never leaves the explicitly allowed provider set', () async {
      final gemini = _RecordingProvider(
        WebSearchProviderId.gemini,
        failures: <WebSearchProviderException>[
          const WebSearchProviderException(
            code: WebSearchFailureCode.unavailable,
            safeMessage: 'Gemini unavailable.',
            crossProviderFallbackAllowed: true,
            statusCode: 503,
          ),
        ],
      );
      final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(
          _configuration(current: 'openrouter'),
        ),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            }),
      );

      await expectLater(
        service.search(
          WebSearchRequest(
            query: 'safe query',
            allowCrossProviderFallback: true,
            allowedProviders: const <WebSearchProviderId>{
              WebSearchProviderId.gemini,
            },
          ),
          ToolCancellationController().token,
        ),
        throwsA(isA<WebSearchProviderException>()),
      );
      expect(gemini.calls, 1);
      expect(openRouter.calls, 0);
    });

    test('does not silently replace an unsupported current provider', () async {
      final gemini = _RecordingProvider(WebSearchProviderId.gemini);
      final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
      final configuration = WebSearchConfiguration(
        currentChatProvider: 'gemini',
        providers: const <WebSearchProviderConfig>[
          WebSearchProviderConfig(
            id: WebSearchProviderId.gemini,
            apiKey: 'gem-key',
            model: 'gemini-1.5-flash',
          ),
          WebSearchProviderConfig(
            id: WebSearchProviderId.openRouter,
            apiKey: 'or-key',
            model: 'openrouter/auto',
          ),
        ],
      );
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(configuration),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            }),
      );

      await expectLater(
        service.search(
          WebSearchRequest(
            query: 'safe query',
            allowedProviders: const <WebSearchProviderId>{
              WebSearchProviderId.gemini,
              WebSearchProviderId.openRouter,
            },
          ),
          ToolCancellationController().token,
        ),
        throwsA(
          isA<WebSearchProviderException>().having(
            (error) => error.code,
            'code',
            WebSearchFailureCode.notConfigured,
          ),
        ),
      );
      expect(gemini.calls, 0);
      expect(openRouter.calls, 0);

      final result = await service.search(
        WebSearchRequest(
          query: 'safe query',
          allowedProviders: const <WebSearchProviderId>{
            WebSearchProviderId.openRouter,
          },
        ),
        ToolCancellationController().token,
      );
      expect(result.provider, WebSearchProviderId.openRouter);
      expect(openRouter.calls, 1);

      final fallback = await service.search(
        WebSearchRequest(
          query: 'safe query',
          allowCrossProviderFallback: true,
          allowedProviders: const <WebSearchProviderId>{
            WebSearchProviderId.gemini,
            WebSearchProviderId.openRouter,
          },
        ),
        ToolCancellationController().token,
      );
      expect(fallback.provider, WebSearchProviderId.openRouter);
      expect(fallback.attemptedProviders, <WebSearchProviderId>[
        WebSearchProviderId.openRouter,
      ]);
      expect(openRouter.calls, 2);
    });
  });

  group('ToolRunner integration', () {
    test(
      'replay reads only the fixture and bypasses network permission',
      () async {
        final configurationSource = _CountingConfigurationSource();
        final fixture = _result(WebSearchProviderId.gemini, fromReplay: false);
        final fixtureRequest = WebSearchRequest(
          query: 'fixture query',
          locale: 'en-US',
        );
        final definition = createWebSearchToolDefinition(
          service: HybridWebSearchService(
            configurationSource: configurationSource,
            providerFactory: _FailingFactory(),
          ),
          replayStore: InMemoryWebSearchReplayStore(<WebSearchReplayFixture>[
            WebSearchReplayFixture(request: fixtureRequest, result: fixture),
          ]),
        );
        final runner = ToolRunner(
          registry: ToolRegistry()..register(definition),
        );

        final result = await runner.run(
          call: ToolCall(
            id: 'replay-search',
            name: 'web.search',
            arguments: const <String, Object?>{'query': '  FIXTURE   query  '},
          ),
          context: ToolContext(
            mode: ToolRunMode.replay,
            metadata: const <String, Object?>{'locale': 'en_US'},
          ),
        );

        final data = result.requireData<WebSearchResult>();
        expect(data.fromReplay, isTrue);
        expect(data.text, fixture.text);
        expect(data.usage.searchRequests, 0);
        expect(data.usage.promptTokens, 0);
        expect(data.usage.completionTokens, 0);
        expect(data.usage.actualCostUsd, isNull);
        expect(data.attribution, isNull);
        expect(data.attemptedProviders, isEmpty);
        expect(data.requestedQuery, 'FIXTURE   query');
        expect(configurationSource.loads, 0);
      },
    );

    test('replay identity includes locale and result limit', () async {
      final zhRequest = WebSearchRequest(query: 'same query');
      final enRequest = WebSearchRequest(
        query: 'same query',
        locale: 'en-US',
        maxResults: 3,
      );
      final store = InMemoryWebSearchReplayStore(<WebSearchReplayFixture>[
        WebSearchReplayFixture(
          request: zhRequest,
          result: _result(WebSearchProviderId.gemini),
        ),
        WebSearchReplayFixture(
          request: enRequest,
          result: _result(WebSearchProviderId.openRouter),
        ),
      ]);

      expect(
        (await store.lookup(zhRequest))?.provider,
        WebSearchProviderId.gemini,
      );
      expect(
        (await store.lookup(enRequest))?.provider,
        WebSearchProviderId.openRouter,
      );
      expect(
        await store.lookup(
          WebSearchRequest(query: 'same query', locale: 'en-US'),
        ),
        isNull,
      );
      expect(
        () => InMemoryWebSearchReplayStore(<WebSearchReplayFixture>[
          WebSearchReplayFixture(
            request: zhRequest,
            result: _result(WebSearchProviderId.gemini),
          ),
          WebSearchReplayFixture(
            request: WebSearchRequest(query: ' SAME   QUERY '),
            result: _result(WebSearchProviderId.openRouter),
          ),
        ]),
        throwsStateError,
      );
    });

    test('replay revalidates sources, citations, text, and usage', () async {
      final fixtureRequest = WebSearchRequest(query: 'unsafe fixture');
      final fixture = WebSearchResult(
        provider: WebSearchProviderId.gemini,
        model: 'gemini-2.5-flash',
        requestedQuery: 'wrong audit query',
        text: 'safe\u202E answer',
        sources: const <WebSearchSource>[
          WebSearchSource(url: 'javascript:alert(1)', title: 'bad'),
          WebSearchSource(url: 'https://safe.example/source', title: 'safe'),
        ],
        citations: const <WebSearchCitation>[
          WebSearchCitation(sourceIndex: 0, startIndex: 0, endIndex: 4),
          WebSearchCitation(sourceIndex: 1, startIndex: 0, endIndex: 4),
          WebSearchCitation(sourceIndex: 1, startIndex: 0, endIndex: 999),
        ],
        usage: const WebSearchUsage(
          promptTokens: 99,
          completionTokens: 99,
          searchRequests: 99,
          actualCostUsd: 42,
          costCertainty: WebSearchCostCertainty.known,
        ),
        attribution: const WebSearchAttribution(
          provider: WebSearchProviderId.gemini,
          renderedContent: '<div>must not replay</div>',
        ),
      );
      final definition = createWebSearchToolDefinition(
        service: HybridWebSearchService(
          configurationSource: _CountingConfigurationSource(),
          providerFactory: _FailingFactory(),
        ),
        replayStore: InMemoryWebSearchReplayStore(<WebSearchReplayFixture>[
          WebSearchReplayFixture(request: fixtureRequest, result: fixture),
        ]),
      );
      final result =
          await ToolRunner(registry: ToolRegistry()..register(definition)).run(
            call: ToolCall(
              id: 'replay-sanitize',
              name: 'web.search',
              arguments: const <String, Object?>{'query': 'unsafe fixture'},
            ),
            context: ToolContext(mode: ToolRunMode.replay),
          );

      final data = result.requireData<WebSearchResult>();
      expect(data.requestedQuery, 'unsafe fixture');
      expect(data.text, isNot(contains('\u202E')));
      expect(data.sources, hasLength(1));
      expect(data.sources.single.url, 'https://safe.example/source');
      expect(data.citations, hasLength(1));
      expect(data.citations.single.sourceIndex, 0);
      expect(data.usage.searchRequests, 0);
      expect(data.usage.actualCostUsd, isNull);
      expect(data.attribution, isNull);
      expect(data.attemptedProviders, isEmpty);
    });

    test('replay rejects a fixture with no safe source', () async {
      final fixtureRequest = WebSearchRequest(query: 'bad fixture');
      final fixture = WebSearchResult(
        provider: WebSearchProviderId.openRouter,
        model: 'openrouter/auto',
        requestedQuery: 'bad fixture',
        text: 'Ungrounded fixture',
        sources: const <WebSearchSource>[
          WebSearchSource(url: 'file:///private', title: 'unsafe'),
        ],
      );
      final definition = createWebSearchToolDefinition(
        service: HybridWebSearchService(
          configurationSource: _CountingConfigurationSource(),
          providerFactory: _FailingFactory(),
        ),
        replayStore: InMemoryWebSearchReplayStore(<WebSearchReplayFixture>[
          WebSearchReplayFixture(request: fixtureRequest, result: fixture),
        ]),
      );
      final result =
          await ToolRunner(registry: ToolRegistry()..register(definition)).run(
            call: ToolCall(
              id: 'bad-replay',
              name: 'web.search',
              arguments: const <String, Object?>{'query': 'bad fixture'},
            ),
            context: ToolContext(mode: ToolRunMode.replay),
          );

      expect(result.status, ToolResultStatus.failed);
      expect(result.failure?.domainCode, 'web.search.ungrounded');
    });

    test('replay miss is a safe structured failure', () async {
      final configurationSource = _CountingConfigurationSource();
      final definition = createWebSearchToolDefinition(
        service: HybridWebSearchService(
          configurationSource: configurationSource,
          providerFactory: _FailingFactory(),
        ),
        replayStore: InMemoryWebSearchReplayStore(
          const <WebSearchReplayFixture>[],
        ),
      );
      final result =
          await ToolRunner(registry: ToolRegistry()..register(definition)).run(
            call: ToolCall(
              id: 'replay-miss',
              name: 'web.search',
              arguments: const <String, Object?>{'query': 'missing fixture'},
            ),
            context: ToolContext(mode: ToolRunMode.replay),
          );

      expect(result.status, ToolResultStatus.failed);
      expect(result.failure?.domainCode, 'web.search.replay_miss');
      expect(result.failure?.retryable, isFalse);
      expect(configurationSource.loads, 0);
    });

    test('validator measures the trimmed query', () {
      final definition = createWebSearchToolDefinition(
        service: HybridWebSearchService(
          configurationSource: _CountingConfigurationSource(),
          providerFactory: _FailingFactory(),
        ),
      );

      expect(
        definition.validateArguments!(<String, Object?>{
          'query': '  ${List<String>.filled(240, '字').join()}  ',
        }),
        isNull,
      );
      expect(
        definition.validateArguments!(<String, Object?>{
          'query': '  ${List<String>.filled(241, '字').join()}  ',
        }),
        isNotNull,
      );
    });

    test(
      'live authorization is bound to exact query and provider set',
      () async {
        final gemini = _RecordingProvider(WebSearchProviderId.gemini);
        final openRouter = _RecordingProvider(WebSearchProviderId.openRouter);
        final service = HybridWebSearchService(
          configurationSource: _StaticConfigurationSource(
            _configuration(current: 'openrouter'),
          ),
          providerFactory: _RecordingProviderFactory(
            <WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: openRouter,
            },
          ),
        );
        final runner = ToolRunner(
          registry: ToolRegistry()
            ..register(
              createWebSearchToolDefinition(service: service, enableLive: true),
            ),
          permissionPolicy: const _AllowAllToolPermissionPolicy(),
        );
        final authorization = WebSearchAuthorization(
          query: 'authorized query',
          allowedProviders: const <WebSearchProviderId>{
            WebSearchProviderId.gemini,
          },
          sensitiveQueryConfirmed: true,
        );

        final success = await runner.run(
          call: ToolCall(
            id: 'authorized-search',
            name: 'web.search',
            arguments: const <String, Object?>{'query': 'authorized query'},
          ),
          context: ToolContext(
            mode: ToolRunMode.live,
            metadata: <String, Object?>{
              ...authorization.toContextMetadata(),
              'locale': 'zh_TW',
            },
          ),
        );
        expect(
          success.requireData<WebSearchResult>().provider,
          WebSearchProviderId.gemini,
        );
        expect(gemini.calls, 1);
        expect(openRouter.calls, 0);
        expect(gemini.lastRequest?.query, 'authorized query');
        expect(gemini.lastRequest?.locale, 'zh-TW');
        expect(gemini.lastRequest?.sensitiveQueryConfirmed, isTrue);
        expect(gemini.lastRequest?.allowCrossProviderFallback, isFalse);
        expect(gemini.lastRequest?.allowedProviders, <WebSearchProviderId>{
          WebSearchProviderId.gemini,
        });

        final rejected = await runner.run(
          call: ToolCall(
            id: 'mismatched-search',
            name: 'web.search',
            arguments: const <String, Object?>{'query': 'different query'},
          ),
          context: ToolContext(
            mode: ToolRunMode.live,
            metadata: authorization.toContextMetadata(),
          ),
        );
        expect(
          rejected.failure?.domainCode,
          'web.search.provider_consent_required',
        );
        expect(gemini.calls, 1);
        expect(openRouter.calls, 0);
      },
    );

    test('live provider errors become safe domain failures', () async {
      final gemini = _RecordingProvider(
        WebSearchProviderId.gemini,
        failures: <WebSearchProviderException>[
          const WebSearchProviderException(
            code: WebSearchFailureCode.rateLimited,
            safeMessage: 'Gemini is rate limited.',
            retryable: true,
            statusCode: 429,
          ),
        ],
      );
      final service = HybridWebSearchService(
        configurationSource: _StaticConfigurationSource(
          _configuration(current: 'gemini'),
        ),
        providerFactory:
            _RecordingProviderFactory(<WebSearchProviderId, _RecordingProvider>{
              WebSearchProviderId.gemini: gemini,
              WebSearchProviderId.openRouter: _RecordingProvider(
                WebSearchProviderId.openRouter,
              ),
            }),
      );
      final runner = ToolRunner(
        registry: ToolRegistry()
          ..register(
            createWebSearchToolDefinition(service: service, enableLive: true),
          ),
        permissionPolicy: const _AllowAllToolPermissionPolicy(),
      );
      final authorization = WebSearchAuthorization(
        query: 'rate limited query',
        allowedProviders: const <WebSearchProviderId>{
          WebSearchProviderId.gemini,
        },
      );

      final result = await runner.run(
        call: ToolCall(
          id: 'rate-limited-search',
          name: 'web.search',
          arguments: const <String, Object?>{'query': 'rate limited query'},
        ),
        context: ToolContext(
          mode: ToolRunMode.live,
          metadata: authorization.toContextMetadata(),
        ),
      );

      expect(result.status, ToolResultStatus.failed);
      expect(result.failure?.domainCode, 'web.search.rate_limited');
      expect(result.failure?.retryable, isTrue);
      expect(result.failure?.safeDetails, const <String, Object?>{
        'httpStatus': 429,
        'costCertainty': 'unknown',
      });
    });

    test(
      'live web search is denied until a network policy allows it',
      () async {
        final configurationSource = _CountingConfigurationSource();
        final definition = createWebSearchToolDefinition(
          service: HybridWebSearchService(
            configurationSource: configurationSource,
            providerFactory: _FailingFactory(),
          ),
        );
        final runner = ToolRunner(
          registry: ToolRegistry()..register(definition),
        );

        final result = await runner.run(
          call: ToolCall.create(
            name: 'web.search',
            arguments: const <String, Object?>{'query': 'safe query'},
          ),
          context: ToolContext(mode: ToolRunMode.live),
        );

        expect(result.status, ToolResultStatus.permissionDenied);
        expect(configurationSource.loads, 0);
      },
    );

    test(
      'live capability remains disabled even under an allow policy',
      () async {
        final configurationSource = _CountingConfigurationSource();
        final definition = createWebSearchToolDefinition(
          service: HybridWebSearchService(
            configurationSource: configurationSource,
            providerFactory: _FailingFactory(),
          ),
        );
        final authorization = WebSearchAuthorization(
          query: 'safe query',
          allowedProviders: const <WebSearchProviderId>{
            WebSearchProviderId.gemini,
          },
        );
        final result =
            await ToolRunner(
              registry: ToolRegistry()..register(definition),
              permissionPolicy: const _AllowAllToolPermissionPolicy(),
            ).run(
              call: ToolCall(
                id: 'disabled-live-search',
                name: 'web.search',
                arguments: const <String, Object?>{'query': 'safe query'},
              ),
              context: ToolContext(
                mode: ToolRunMode.live,
                metadata: authorization.toContextMetadata(),
              ),
            );

        expect(result.failure?.domainCode, 'web.search.live_disabled');
        expect(configurationSource.loads, 0);
      },
    );

    test(
      'malformed live authorization fails before settings are loaded',
      () async {
        final configurationSource = _CountingConfigurationSource();
        final definition = createWebSearchToolDefinition(
          service: HybridWebSearchService(
            configurationSource: configurationSource,
            providerFactory: _FailingFactory(),
          ),
          enableLive: true,
        );
        final result =
            await ToolRunner(
              registry: ToolRegistry()..register(definition),
              permissionPolicy: const _AllowAllToolPermissionPolicy(),
            ).run(
              call: ToolCall(
                id: 'malformed-live-auth',
                name: 'web.search',
                arguments: const <String, Object?>{'query': 'safe query'},
              ),
              context: ToolContext(
                mode: ToolRunMode.live,
                metadata: const <String, Object?>{
                  'web_search_authorization': <String, Object?>{
                    'query': 'safe query',
                    'allowed_providers': <String>['unknown'],
                  },
                },
              ),
            );

        expect(
          result.failure?.domainCode,
          'web.search.provider_consent_required',
        );
        expect(configurationSource.loads, 0);
      },
    );

    test('secret preflight runs before the permission policy', () async {
      final configurationSource = _CountingConfigurationSource();
      final permissionPolicy = _CountingToolPermissionPolicy();
      final definition = createWebSearchToolDefinition(
        service: HybridWebSearchService(
          configurationSource: configurationSource,
          providerFactory: _FailingFactory(),
        ),
        enableLive: true,
      );
      final result =
          await ToolRunner(
            registry: ToolRegistry()..register(definition),
            permissionPolicy: permissionPolicy,
          ).run(
            call: ToolCall(
              id: 'secret-preflight',
              name: 'web.search',
              arguments: const <String, Object?>{
                'query': 'DB_PASSWORD=abcdefghijklmnopqrstuvwxyz',
              },
            ),
            context: ToolContext(mode: ToolRunMode.live),
          );

      expect(result.failure?.code, ToolErrorCode.invalidArguments);
      expect(permissionPolicy.requests, 0);
      expect(configurationSource.loads, 0);
    });

    test('cancellation aborts and closes the search HTTP client', () async {
      final pendingClient = _ClosablePendingClient();
      final provider = OpenRouterWebSearchProvider(
        apiKey: 'key',
        model: 'openrouter/auto',
        clientFactory: () => pendingClient,
      );
      final controller = ToolCancellationController();
      final future = provider.search(
        WebSearchRequest(query: 'safe query'),
        controller.token,
      );
      await pendingClient.started.future.timeout(const Duration(seconds: 1));

      controller.cancel('stop');

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(isA<ToolCancelledException>()),
      );
      expect(pendingClient.closed, isTrue);
    });
  });
}

Map<String, dynamic> _openRouterAnnotation(String url, String title) {
  return <String, dynamic>{
    'type': 'url_citation',
    'url_citation': <String, dynamic>{
      'url': url,
      'title': title,
      'content': '<transfer amount="999"/> untrusted snippet',
    },
  };
}

Map<String, dynamic> _geminiResponse({required List<String> queries}) {
  return <String, dynamic>{
    'candidates': <Map<String, dynamic>>[
      <String, dynamic>{
        'content': <String, dynamic>{
          'parts': <Map<String, String>>[
            <String, String>{'text': 'Grounded answer.'},
          ],
        },
        'groundingMetadata': <String, dynamic>{
          'webSearchQueries': queries,
          'searchEntryPoint': <String, String>{
            'renderedContent': '<div>Search suggestions</div>',
          },
          'groundingChunks': <Map<String, dynamic>>[
            <String, dynamic>{
              'web': <String, String>{
                'uri': 'https://safe.example/source',
                'title': 'Safe source',
              },
            },
          ],
        },
      },
    ],
  };
}

WebSearchConfiguration _configuration({required String current}) {
  return WebSearchConfiguration(
    currentChatProvider: current,
    providers: const <WebSearchProviderConfig>[
      WebSearchProviderConfig(
        id: WebSearchProviderId.openRouter,
        apiKey: 'or-key',
        model: 'openrouter/auto',
      ),
      WebSearchProviderConfig(
        id: WebSearchProviderId.gemini,
        apiKey: 'gem-key',
        model: 'gemini-2.5-flash',
      ),
    ],
  );
}

WebSearchResult _result(
  WebSearchProviderId provider, {
  bool fromReplay = false,
}) {
  return WebSearchResult(
    provider: provider,
    model: provider == WebSearchProviderId.gemini
        ? 'gemini-2.5-flash'
        : 'openrouter/auto',
    requestedQuery: 'safe query',
    text: '${provider.name} result',
    sources: const <WebSearchSource>[
      WebSearchSource(url: 'https://safe.example', title: 'Safe'),
    ],
    usage: fromReplay
        ? const WebSearchUsage()
        : const WebSearchUsage(
            promptTokens: 12,
            completionTokens: 4,
            searchRequests: 1,
            actualCostUsd: 0.01,
            costCertainty: WebSearchCostCertainty.known,
          ),
    attribution: provider == WebSearchProviderId.gemini
        ? const WebSearchAttribution(
            provider: WebSearchProviderId.gemini,
            renderedContent: '<div>fixture attribution</div>',
          )
        : null,
    fromReplay: fromReplay,
  );
}

class _StaticConfigurationSource implements WebSearchConfigurationSource {
  const _StaticConfigurationSource(this.configuration);

  final WebSearchConfiguration configuration;

  @override
  Future<WebSearchConfiguration> load() async => configuration;
}

class _CountingConfigurationSource implements WebSearchConfigurationSource {
  int loads = 0;

  @override
  Future<WebSearchConfiguration> load() async {
    loads++;
    return _configuration(current: 'gemini');
  }
}

class _RecordingProviderFactory implements WebSearchProviderFactory {
  const _RecordingProviderFactory(this.providers);

  final Map<WebSearchProviderId, _RecordingProvider> providers;

  @override
  WebSearchProvider create(WebSearchProviderConfig config) {
    return providers[config.id]!;
  }
}

class _RecordingProvider implements WebSearchProvider {
  _RecordingProvider(
    this.id, {
    List<WebSearchProviderException> failures =
        const <WebSearchProviderException>[],
    this.onSearch,
  }) : _failures = List<WebSearchProviderException>.of(failures);

  @override
  final WebSearchProviderId id;
  final List<WebSearchProviderException> _failures;
  final void Function()? onSearch;
  int calls = 0;
  WebSearchRequest? lastRequest;

  @override
  Future<WebSearchResult> search(
    WebSearchRequest request,
    ToolCancellationToken cancellationToken,
  ) async {
    calls++;
    lastRequest = request;
    onSearch?.call();
    cancellationToken.throwIfCancelled();
    if (_failures.isNotEmpty) throw _failures.removeAt(0);
    return _result(id);
  }
}

class _FailingFactory implements WebSearchProviderFactory {
  @override
  WebSearchProvider create(WebSearchProviderConfig config) {
    throw StateError('Live provider must not be created in this test.');
  }
}

class _AllowAllToolPermissionPolicy implements ToolPermissionPolicy {
  const _AllowAllToolPermissionPolicy();

  @override
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    return ToolPermissionDecision.allow;
  }
}

class _CountingToolPermissionPolicy implements ToolPermissionPolicy {
  int requests = 0;

  @override
  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    requests++;
    return ToolPermissionDecision.allow;
  }
}

class _ClosablePendingClient extends http.BaseClient {
  final Completer<void> started = Completer<void>();
  final Completer<http.StreamedResponse> _response =
      Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!started.isCompleted) started.complete();
    final abortable = request as http.AbortableRequest;
    unawaited(
      abortable.abortTrigger!.then((_) {
        if (!_response.isCompleted) {
          _response.completeError(http.RequestAbortedException(request.url));
        }
      }),
    );
    return _response.future;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
