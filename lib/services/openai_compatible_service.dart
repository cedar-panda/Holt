import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'model_info.dart';
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'system_context_debug.dart';
import 'token_estimator.dart';

/// OpenAI 兼容 API（支持任何中轉站 / 自建端點）
/// 只要遵循 /v1/chat/completions 格式就能用
class OpenAICompatibleService implements ApiAdapter {
  final String apiKey;
  final String baseUrl; // 例：https://api.openai.com/v1
  final String modelPrefixToStrip;
  final bool thinkingEnabled;
  http.Client? _activeClient;
  static Map<String, int> lastUsageStats = <String, int>{};

  OpenAICompatibleService({
    required this.apiKey,
    required this.baseUrl,
    this.modelPrefixToStrip = '',
    this.thinkingEnabled = false,
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

  /// 優先讀取 New API / One API 公開的模型定價清單；不支援時再退回
  /// OpenAI 標準的 /models。公開定價清單不需要 API Key。
  static Future<List<ModelInfo>> fetchModels({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
  }) async {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const FormatException('Base URL 無效');
    }

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
        throw Exception('無法獲取模型列表：${response.statusCode}');
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
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const FormatException('Base URL 無效');
    }
    return _modelsUri(base);
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

  String get _completionsUrl {
    final url = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    // 如果已經包含完整路徑就直接用，否則補上
    if (url.endsWith('/chat/completions')) return url;
    if (url.endsWith('/v1')) return '$url/chat/completions';
    return '$url/v1/chat/completions';
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
      final response = await client
          .post(
            Uri.parse(_completionsUrl),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));
      if (response.statusCode != 200) {
        throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      final stats = _extractUsage(data);
      if (stats != null) onUsage?.call(ApiUsage.fromStats(stats));
      final message = data['choices'][0]['message'];
      final content = message is Map ? '${message['content'] ?? ''}' : '';
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

      final request = http.Request('POST', Uri.parse(_completionsUrl));
      request.headers.addAll(_headers());
      request.body = jsonEncode(body);

      final http.StreamedResponse response;
      try {
        response = await StreamTransport.waitForResponseStart(
          client.send(request),
          provider: 'OpenAI-compatible API',
        );
      } on SocketException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      } on HttpException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      }

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('API 錯誤 ${response.statusCode}: $errorBody');
      }

      Map<String, int>? requestStats;
      var reasoningOpen = false;
      final diagnostics = SseStreamDiagnostics();
      await for (final data in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data);
          if (json['usage'] != null) requestStats = _extractUsage(json);
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
          final delta = deltaMap is Map ? deltaMap['content'] : null;
          if (delta != null && delta.isNotEmpty) {
            if (reasoningOpen) {
              reasoningOpen = false;
              yield '</think>';
            }
            yield delta;
          }
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
    return '網路錯誤：$e';
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
      provider: 'openai_compatible',
      model: model,
    );
    final shouldCache = cacheControl != null && enableCache;

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
      final imageUrl = m['image_data_url'];

      if (imageUrl != null && role == 'user') {
        // 多模態
        final contentBlocks = <Map<String, dynamic>>[
          {
            'type': 'image_url',
            'image_url': {'url': imageUrl},
          },
          {
            'type': 'text',
            'text': content.isNotEmpty ? content : '（用戶發送了一張圖片）',
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
    if (lowerModel.contains('claude')) {
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
      final runtimeRole =
          lowerModel.contains('gpt') || lowerModel.contains('openai')
          ? 'developer'
          : 'system';
      final attached = RuntimeContextSidecar.insertSystemBeforeLatestUser(
        allMessages,
        liveState,
        role: runtimeRole,
      );
      if (attached) runtimeTransport = '${runtimeRole}_before_latest_user';
    }

    final body = <String, dynamic>{
      'model': _modelForRequest(model),
      'messages': allMessages,
      'stream': stream,
    };
    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: 'openai_compatible',
        model: model,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: CacheSession.conversationId,
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
}
