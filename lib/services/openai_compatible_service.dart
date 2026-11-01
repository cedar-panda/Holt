import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;
import '../utils/endpoint_security.dart';
import 'api_adapter.dart';
import 'locale_strings.dart';
import 'model_info.dart';
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'system_context_debug.dart';
import 'token_estimator.dart';
import 'provider_content_parser.dart';
import 'reasoning_effort.dart';
import 'cache/deepinfra_cache_policy.dart';

/// OpenAI 兼容 API（支持任何中轉站 / 自建端點）
/// 只要遵循 /v1/chat/completions 格式就能用
class OpenAICompatibleService implements ApiAdapter {
  final String apiKey;
  final String baseUrl; // 例：https://api.openai.com/v1
  final String modelPrefixToStrip;
  final bool thinkingEnabled;
  final String reasoningEffort;
  final String providerId;
  final String providerLabel;
  final OpenAICompatibleCapabilities? capabilities;
  http.Client? _activeClient;
  static Map<String, int> lastUsageStats = <String, int>{};

  OpenAICompatibleService({
    required this.apiKey,
    required this.baseUrl,
    this.modelPrefixToStrip = '',
    this.thinkingEnabled = false,
    this.reasoningEffort = ReasoningEffort.auto,
    this.providerId = 'openai_compatible',
    this.providerLabel = 'OpenAI-compatible API',
    this.capabilities,
  });

  Future<Map<String, dynamic>> debugBuildBodyForTesting({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) {
    return _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: false,
    );
  }

  Map<String, dynamic>? debugDowngradeBodyForTesting(
    Map<String, dynamic> body,
    String errorBody,
  ) => _downgradeBodyForUnsupported400(body, errorBody);

  /// 優先讀取 New API / One API 公開的模型定價清單；不支援時再退回
  /// OpenAI 標準的 /models。公開定價清單不需要 API Key。
  static Future<List<ModelInfo>> fetchModels({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
  }) async {
    final base = EndpointSecurity.parseAndValidate(baseUrl);

    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      // New API / One API commonly expose a public pricing catalogue. The
      // official OpenAI host does not, so go straight to its authenticated
      // standard endpoint instead of issuing an unrelated probe first.
      if (base.host.toLowerCase() != 'api.openai.com') {
        final pricingUri = base.replace(path: '/api/pricing', query: null);
        try {
          final response = await activeClient
              .get(pricingUri)
              .timeout(const Duration(seconds: 20));
          if (response.statusCode == 200) {
            final models = _parsePricingModels(response.body);
            if (models.isNotEmpty) return models;
          }
        } catch (_) {
          // Not every compatible server exposes a pricing catalogue.
        }
      }

      final modelsUri = _modelsUri(base);
      final response = await activeClient
          .get(
            modelsUri,
            headers: {
              if (apiKey.trim().isNotEmpty)
                'Authorization': 'Bearer ${apiKey.trim()}',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception(
          _httpErrorMessage(
            response.statusCode,
            response.body,
            operation: L.pick(
              en: 'Could not load model list',
              zhTW: '無法獲取模型列表',
              zhCN: '无法获取模型列表',
            ),
          ),
        );
      }

      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map<String, dynamic>
          ? decoded['data']
          : null;
      if (rawModels is! List) throw const FormatException('模型列表格式無效');
      return _sortedUniqueModels(
        rawModels.whereType<Map>().map((raw) {
          final id = '${raw['id'] ?? ''}'.trim();
          final name = '${raw['name'] ?? id}'.trim();
          return ModelInfo(id: id, name: name.isEmpty ? id : name);
        }),
      );
    } finally {
      ownedClient?.close();
    }
  }

  static Uri _modelsUri(Uri base) {
    var path = base.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/chat/completions')) {
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    if (!path.endsWith('/v1')) path = '$path/v1';
    return base.replace(path: '$path/models', query: null);
  }

  static Uri modelsUriForBase(String baseUrl) {
    final base = EndpointSecurity.parseAndValidate(baseUrl);
    return _modelsUri(base);
  }

  static Uri embeddingsUriForBase(String baseUrl) {
    final base = EndpointSecurity.parseAndValidate(baseUrl);
    var path = base.path.replaceFirst(RegExp(r'/+$'), '');
    for (final suffix in const <String>[
      '/chat/completions',
      '/responses',
      '/embeddings',
    ]) {
      if (path.endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    if (!path.endsWith('/v1')) path = '$path/v1';
    return base.replace(path: '$path/embeddings', query: null);
  }

  static String httpErrorMessage(
    int statusCode,
    String body, {
    String operation = 'API 錯誤',
  }) => _httpErrorMessage(statusCode, body, operation: operation);

  /// 中轉站常把可操作原因放在 `error.message`、`message` 或 `detail`；純文字
  /// 錯誤也接受。所有原因都會壓成單行並限制長度，HTML 整頁不進聊天報錯。
  static String _httpErrorMessage(
    int statusCode,
    String body, {
    String? operation,
  }) {
    final reason = _extractHttpErrorReason(body);
    final prefix = operation ?? L.pick(en: 'API error', zhTW: 'API 錯誤');
    if (reason.isNotEmpty) return '$prefix $statusCode：$reason';
    return L.pick(
      en: '$prefix $statusCode: the relay did not provide a reason',
      zhTW: '$prefix $statusCode：中轉站未提供具體原因',
      zhCN: '$prefix $statusCode：中转站未提供具体原因',
    );
  }

  static String _extractHttpErrorReason(String body) {
    String? candidate;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          candidate = _firstNonEmpty(<Object?>[
            error['message'],
            error['detail'],
            error['reason'],
            error['type'],
          ]);
        } else if (error is String) {
          candidate = error;
        }
        candidate ??= _firstNonEmpty(<Object?>[
          decoded['message'],
          decoded['detail'],
          decoded['reason'],
          decoded['title'],
        ]);
      }
    } catch (_) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('<') &&
          !trimmed.toLowerCase().startsWith('<!doctype')) {
        candidate = trimmed;
      }
    }

    final compact = (candidate ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return '';
    final runes = compact.runes.toList(growable: false);
    if (runes.length <= 240) return compact;
    return '${String.fromCharCodes(runes.take(240))}…';
  }

  static String? _firstNonEmpty(Iterable<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != 'null') return text;
    }
    return null;
  }

  static List<ModelInfo> _parsePricingModels(String body) {
    final decoded = jsonDecode(body);
    final rawModels = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (rawModels is! List) return const [];

    return _sortedUniqueModels(
      rawModels
          .whereType<Map>()
          .where((raw) {
            final endpointTypes = raw['supported_endpoint_types'];
            if (endpointTypes is! List || endpointTypes.isEmpty) return true;
            return endpointTypes.any(
              (type) => type.toString().toLowerCase() == 'openai',
            );
          })
          .map((raw) {
            final name = '${raw['model_name'] ?? ''}'.trim();
            return ModelInfo(id: name, name: name);
          }),
    );
  }

  static List<ModelInfo> _sortedUniqueModels(Iterable<ModelInfo> models) {
    final unique = <String, ModelInfo>{};
    for (final model in models) {
      if (model.id.isNotEmpty) unique[model.id] = model;
    }
    final result = unique.values.toList();
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Uri get _completionsUri {
    return completionsUriForBase(baseUrl);
  }

  static Uri completionsUriForBase(String baseUrl) {
    final validated = EndpointSecurity.parseAndValidate(baseUrl);
    final rawUrl = validated.toString();
    final url = rawUrl.endsWith('/')
        ? rawUrl.substring(0, rawUrl.length - 1)
        : rawUrl;
    // 如果已經包含完整路徑就直接用，否則補上
    if (url.endsWith('/chat/completions')) return Uri.parse(url);
    if (url.endsWith('/v1')) return Uri.parse('$url/chat/completions');
    return Uri.parse('$url/v1/chat/completions');
  }

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: false,
      );
      var response = await client
          .post(_completionsUri, headers: _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 180));
      if (response.statusCode == 400) {
        final downgraded = _downgradeBodyForUnsupported400(body, response.body);
        if (downgraded != null) {
          response = await client
              .post(
                _completionsUri,
                headers: _headers(),
                body: jsonEncode(downgraded),
              )
              .timeout(const Duration(seconds: 180));
        }
      }
      if (response.statusCode != 200) {
        _debugHttpFailure(response.statusCode, response.bodyBytes.length);
        throw Exception(_httpErrorMessage(response.statusCode, response.body));
      }

      final data = jsonDecode(response.body);
      final stats = _extractUsage(data);
      if (stats != null) onUsage?.call(ApiUsage.fromStats(stats));
      final message = data['choices'][0]['message'];
      final content = message is Map
          ? ProviderContentParser.visibleText(message['content'])
          : '';
      final reasoning = message is Map
          ? ProviderReasoning.fromMap(message)
          : '';
      if (thinkingEnabled && reasoning.isNotEmpty) {
        return '<think>$reasoning</think>$content';
      }
      return content;
    } on SocketException catch (e) {
      throw Exception(_friendlyNetworkError(e));
    } on HttpException catch (e) {
      throw Exception(_friendlyNetworkError(e));
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close();
    }
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async* {
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: true,
      );

      Future<http.StreamedResponse> sendBody(Map<String, dynamic> requestBody) {
        final request = http.Request('POST', _completionsUri);
        request.headers.addAll(_headers());
        request.body = jsonEncode(requestBody);
        return StreamTransport.waitForResponseStart(
          client.send(request),
          provider: providerLabel,
        );
      }

      http.StreamedResponse response;
      try {
        response = await sendBody(body);
      } on SocketException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      } on HttpException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      }

      if (response.statusCode == 400) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        final downgraded = _downgradeBodyForUnsupported400(body, errorBody);
        if (downgraded != null) {
          response = await sendBody(downgraded);
        } else {
          _debugHttpFailure(response.statusCode, utf8.encode(errorBody).length);
          throw Exception(_httpErrorMessage(response.statusCode, errorBody));
        }
      }
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        _debugHttpFailure(response.statusCode, utf8.encode(errorBody).length);
        throw Exception(_httpErrorMessage(response.statusCode, errorBody));
      }

      Map<String, int>? requestStats;
      var reasoningOpen = false;
      var sawDone = false;
      String? terminalFinishReason;
      final diagnostics = SseStreamDiagnostics();
      await for (final data in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }

        try {
          final json = jsonDecode(data);
          StreamPayloadException.throwIfPresent(json, provider: providerLabel);
          if (json['usage'] != null) requestStats = _extractUsage(json);
          final finishReason = json['choices']?[0]?['finish_reason']
              ?.toString();
          if (finishReason != null && finishReason.isNotEmpty) {
            terminalFinishReason = finishReason;
          }
          final deltaMap = json['choices']?[0]?['delta'];
          final reasoning = deltaMap is Map
              ? ProviderReasoning.fromMap(deltaMap)
              : '';
          if (reasoning.isNotEmpty && thinkingEnabled) {
            if (!reasoningOpen) {
              reasoningOpen = true;
              yield '<think>';
            }
            yield reasoning;
          }
          final delta = deltaMap is Map
              ? ProviderContentParser.visibleText(deltaMap['content'])
              : '';
          if (delta.isNotEmpty) {
            if (reasoningOpen) {
              reasoningOpen = false;
              yield '</think>';
            }
            yield delta;
          }
        } on StreamPayloadException {
          rethrow;
        } catch (_) {}
      }
      if (reasoningOpen) yield '</think>';
      final streamDiagnostics = <String, Object?>{
        'malformed_utf8_replacements': diagnostics.malformedUtf8Replacements,
      };
      if (requestStats != null) {
        onUsage?.call(
          ApiUsage.fromStats(requestStats, diagnostics: streamDiagnostics),
        );
      } else {
        onUsage?.call(ApiUsage(diagnostics: streamDiagnostics));
      }
      StreamTerminalGuard.requireOpenAiCompatible(
        provider: 'OpenAI-compatible API',
        sawDone: sawDone,
        finishReason: terminalFinishReason,
      );
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close();
    }
  }

  @override
  void cancelActive() {
    final client = _activeClient;
    _activeClient = null;
    client?.close();
  }

  static Map<String, int>? _extractUsage(dynamic data) {
    if (data is! Map) return null;
    final usage = data['usage'];
    if (usage is! Map) return null;
    final details = usage['prompt_tokens_details'];
    final stats = <String, int>{
      'prompt_tokens': (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      'completion_tokens': (usage['completion_tokens'] as num?)?.toInt() ?? 0,
      'cache_read': details is Map
          ? (details['cached_tokens'] as num?)?.toInt() ?? 0
          : (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
      'cache_creation':
          (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
    };
    lastUsageStats = Map<String, int>.from(stats);
    return stats;
  }

  Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    if (apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }
    return headers;
  }

  static String _friendlyNetworkError(dynamic e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('connection refused') || msg.contains('no route')) {
      return '無法連接到 API 服務。請確認：\n'
          '1. 電腦上的 LM Studio / 服務已啟動\n'
          '2. 手機和電腦在同一個 WiFi\n'
          '3. Base URL 用的是電腦局域網 IP（不是 127.0.0.1）';
    }
    if (msg.contains('timed out') || msg.contains('timeout')) {
      return '連接超時。請檢查網路或 API 服務是否正常運行。';
    }
    if (msg.contains('network is unreachable')) {
      return '網路不可用。請確認手機已連接 WiFi。';
    }
    return '網路錯誤（${e.runtimeType}）';
  }

  static void _debugHttpFailure(int statusCode, int responseBytes) {
    if (!kDebugMode) return;
    debugPrint(
      '[OpenAICompatible] HTTP $statusCode (responseBytes=$responseBytes)',
    );
  }

  String _modelForRequest(String model) {
    if (modelPrefixToStrip.isNotEmpty && model.startsWith(modelPrefixToStrip)) {
      return model.substring(modelPrefixToStrip.length);
    }
    return model;
  }

  Future<Map<String, dynamic>> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) async {
    final enableCache = await MemorySettings.getEnablePromptCaching();
    final allMessages = <Map<String, dynamic>>[];
    // Claude 系模型（經中轉）支持 Anthropic 風格 cache_control 透傳
    final cacheControl = TokenEstimator.promptCacheControl(
      provider: providerId,
      model: model,
    );
    final isClaudeRoute = TokenEstimator.isClaudePromptCacheModel(
      provider: providerId,
      model: model,
    );
    final supportsCacheControl = capabilities?.supportsCacheControl ?? true;
    final shouldCache =
        supportsCacheControl &&
        isClaudeRoute &&
        cacheControl != null &&
        enableCache;

    // ═══ system 分層：只放可快取的穩定前綴 ═══
    final cacheableParts =
        structuredPrompt?.cacheableParts ?? <String>[systemPrompt ?? ''];
    final liveState = structuredPrompt?.requestOnlyPart ?? '';
    for (var i = 0; i < cacheableParts.length; i++) {
      final part = cacheableParts[i];
      if (part.isEmpty) continue;
      if (shouldCache) {
        allMessages.add({
          'role': 'system',
          'content': <Map<String, dynamic>>[
            {
              'type': 'text',
              'text': part,
              if (i == cacheableParts.length - 1)
                'cache_control': Map<String, String>.from(cacheControl),
            },
          ],
        });
      } else {
        allMessages.add({'role': 'system', 'content': part});
      }
    }
    // 對話歷史
    for (final m in messages) {
      final role = m['role'] ?? 'user';
      final content = m['content'] ?? '';
      final imageUrls = ApiMessageMedia.imageDataUrls(m);

      if (imageUrls.isNotEmpty && role == 'user') {
        // 多模態
        final contentBlocks = <Map<String, dynamic>>[
          for (final imageUrl in imageUrls)
            {
              'type': 'image_url',
              'image_url': {'url': imageUrl},
            },
          {
            'type': 'text',
            'text': content.isNotEmpty
                ? content
                : '（用戶發送了${imageUrls.length}張圖片）',
          },
        ];
        allMessages.add({'role': role, 'content': contentBlocks});
      } else if (shouldCache) {
        // Claude 路線 + 開啟 caching：統一 blocks 格式，供滾動斷點使用
        allMessages.add({
          'role': role,
          'content': <Map<String, dynamic>>[
            {'type': 'text', 'text': content},
          ],
        });
      } else {
        allMessages.add({'role': role, 'content': content});
      }
    }

    // ═══ 滾動 breakpoint（僅 Claude 路線 + 啟用 caching）═══
    final latestUserIndex = CacheBreakpoint.latestUserIndex(allMessages);
    // DeepInfra 的 explicit retention 也要錨定在「即時狀態」插入前的
    // 最後一則穩定訊息。保留 Map 參照，避免插入 live state 後舊索引偏移。
    final deepInfraStableBoundary = latestUserIndex > 0
        ? allMessages[latestUserIndex - 1]
        : null;
    if (shouldCache) {
      CacheBreakpoint.applyRolling(
        allMessages,
        minIndex: allMessages
            .takeWhile((message) => message['role'] == 'system')
            .length,
        maxIndexExclusive: latestUserIndex >= 0
            ? latestUserIndex
            : allMessages.length,
        cacheControl: cacheControl,
      );
    }

    // runtime 不得借用 user role。新版 Claude 可用官方 mid-system；舊版
    // Claude 只能放回頂層 system。其他 Chat Completions 路線放在最新 user 前。
    final lowerModel = model.toLowerCase();
    var runtimeTransport = '';
    var runtimeFallback = '';
    var cachePrefixPreserved = true;
    if (isClaudeRoute) {
      if (RuntimeContextSidecar.supportsClaudeMidConversationSystem(model)) {
        final attached = RuntimeContextSidecar.appendSystemAfterLatestUser(
          allMessages,
          liveState,
        );
        if (attached) runtimeTransport = 'claude_mid_system';
      } else {
        final attached =
            RuntimeContextSidecar.appendToPreviousAssistantBeforeLatestUser(
              allMessages,
              liveState,
            );
        if (attached) {
          runtimeTransport = shouldCache
              ? 'assistant_state_after_cache_breakpoint'
              : 'assistant_state';
        } else if (RuntimeContextSidecar.appendToLeadingSystemMessage(
          allMessages,
          liveState,
        )) {
          runtimeTransport = 'top_level_system_fallback';
          runtimeFallback = 'No previous assistant turn was available.';
          final historyStart = allMessages
              .takeWhile((message) => message['role'] == 'system')
              .length;
          cachePrefixPreserved =
              !shouldCache || latestUserIndex <= historyStart;
        }
      }
    } else {
      final supportsMidSystem =
          capabilities?.supportsMidConversationSystem ?? true;
      final useDeveloperRole =
          capabilities?.supportsDeveloperRole ??
          (lowerModel.contains('gpt') || lowerModel.contains('openai'));
      final runtimeRole = useDeveloperRole ? 'developer' : 'system';
      if (supportsMidSystem) {
        final attached = RuntimeContextSidecar.insertSystemBeforeLatestUser(
          allMessages,
          liveState,
          role: runtimeRole,
        );
        if (attached) runtimeTransport = '${runtimeRole}_before_latest_user';
      } else if (RuntimeContextSidecar.appendToLeadingSystemMessage(
        allMessages,
        liveState,
      )) {
        runtimeTransport = 'top_level_system_capability_fallback';
      }
    }

    final deepInfraReasoningEffort = providerId.toLowerCase() == 'deepinfra'
        ? _deepInfraReasoningEffort(model)
        : null;
    final body = <String, dynamic>{
      'model': _modelForRequest(model),
      'messages': allMessages,
      'stream': stream,
    };
    if (deepInfraReasoningEffort case final effort?) {
      body['reasoning_effort'] = effort;
    }
    if (providerId.toLowerCase() == 'deepinfra') {
      final deepInfraBreakpointIndex = deepInfraStableBoundary == null
          ? -1
          : allMessages.indexOf(deepInfraStableBoundary);
      DeepInfraCachePolicy.decorateRequest(
        body: body,
        messages: allMessages,
        model: model,
        sessionId: structuredPrompt?.cacheSessionId ?? '',
        breakpointIndex: deepInfraBreakpointIndex,
        enabled: enableCache,
      );
    }
    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: providerId,
        model: model,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: structuredPrompt.cacheSessionId,
        transport: runtimeTransport,
        sourceMessages: messages,
        requestMessages: allMessages,
        stableContext: cacheableParts.join('\n\n'),
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: shouldCache,
        cachePrefixPreserved: cachePrefixPreserved,
        fallbackReason: runtimeFallback,
        cacheBreakpointIndex: shouldCache && latestUserIndex > 0
            ? latestUserIndex - 1
            : -1,
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }
    return body;
  }

  Map<String, dynamic>? _downgradeBodyForUnsupported400(
    Map<String, dynamic> body,
    String errorBody,
  ) {
    final error = errorBody.toLowerCase();
    final explicitlyUnsupported =
        error.contains('unsupported') ||
        error.contains('not supported') ||
        error.contains('unrecognized') ||
        error.contains('unknown field') ||
        error.contains('not allowed') ||
        error.contains('extra field');
    final systemMustLead =
        error.contains('system') &&
        (error.contains('must be first') ||
            error.contains('only at the beginning') ||
            error.contains('not allowed after') ||
            error.contains('system message must'));
    if (!explicitlyUnsupported && !systemMustLead) return null;

    final downgraded = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    var changed = false;
    final messages = downgraded['messages'];

    if (messages is List &&
        explicitlyUnsupported &&
        error.contains('developer')) {
      for (final message in messages.whereType<Map>()) {
        if (message['role'] == 'developer') {
          message['role'] = 'system';
          changed = true;
        }
      }
    }
    if (explicitlyUnsupported && error.contains('cache_control')) {
      changed = _removeKeyRecursively(downgraded, 'cache_control') || changed;
    }
    if (explicitlyUnsupported && error.contains('reasoning_effort')) {
      changed = downgraded.remove('reasoning_effort') != null || changed;
    }
    if (explicitlyUnsupported &&
        (error.contains('tool_choice') || error.contains('tools'))) {
      changed = downgraded.remove('tools') != null || changed;
      changed = downgraded.remove('tool_choice') != null || changed;
    }
    if (messages is List && systemMustLead) {
      changed = _collapseMidConversationSystems(messages) || changed;
    }
    return changed ? downgraded : null;
  }

  Object? _deepInfraReasoningEffort(String model) {
    final effort = ReasoningEffort.normalize(reasoningEffort);
    if (effort == ReasoningEffort.auto) return null;
    final lower = model.toLowerCase();
    if (lower.contains('deepseek-v4.1')) {
      return switch (effort) {
        ReasoningEffort.low => 25,
        ReasoningEffort.medium => 60,
        ReasoningEffort.high => 90,
        _ => null,
      };
    }
    return effort;
  }

  static bool _removeKeyRecursively(dynamic value, String key) {
    var changed = false;
    if (value is Map) {
      changed = value.remove(key) != null;
      for (final child in value.values) {
        changed = _removeKeyRecursively(child, key) || changed;
      }
    } else if (value is List) {
      for (final child in value) {
        changed = _removeKeyRecursively(child, key) || changed;
      }
    }
    return changed;
  }

  static bool _collapseMidConversationSystems(List<dynamic> messages) {
    final lateSystems = <Map>[];
    var historyStarted = false;
    for (final item in messages) {
      if (item is! Map) continue;
      if (item['role'] != 'system') historyStarted = true;
      if (historyStarted && item['role'] == 'system') lateSystems.add(item);
    }
    if (lateSystems.isEmpty) return false;
    final text = lateSystems
        .map((message) => ProviderContentParser.visibleText(message['content']))
        .where((value) => value.trim().isNotEmpty)
        .join('\n\n');
    messages.removeWhere(lateSystems.contains);
    if (text.isEmpty) return true;
    final leading = messages.whereType<Map>().firstWhere(
      (message) => message['role'] == 'system',
      orElse: () => <String, dynamic>{},
    );
    if (leading.isNotEmpty) {
      final existing = ProviderContentParser.visibleText(leading['content']);
      leading['content'] = existing.isEmpty ? text : '$existing\n\n$text';
    } else {
      messages.insert(0, <String, dynamic>{'role': 'system', 'content': text});
    }
    return true;
  }
}

class OpenAICompatibleCapabilities {
  final bool supportsDeveloperRole;
  final bool supportsMidConversationSystem;
  final bool supportsCacheControl;
  final bool supportsTools;

  const OpenAICompatibleCapabilities({
    this.supportsDeveloperRole = false,
    this.supportsMidConversationSystem = true,
    this.supportsCacheControl = true,
    this.supportsTools = false,
  });
}
