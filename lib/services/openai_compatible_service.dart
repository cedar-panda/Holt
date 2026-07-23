import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'openrouter_service.dart' show ModelInfo;
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'token_estimator.dart';

/// OpenAI 兼容 API（支持任何中轉站 / 自建端點）
/// 只要遵循 /v1/chat/completions 格式就能用
class OpenAICompatibleService implements ApiAdapter {
  final String apiKey;
  final String baseUrl; // 例：https://api.openai.com/v1
  final String modelPrefixToStrip;
  http.Client? _activeClient;
  static Map<String, int> lastUsageStats = <String, int>{};

  OpenAICompatibleService({
    required this.apiKey,
    required this.baseUrl,
    this.modelPrefixToStrip = '',
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
  }) async {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const FormatException('Base URL 無效');
    }

    final pricingUri = base.replace(path: '/api/pricing', query: null);
    try {
      final response = await http
          .get(pricingUri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final models = _parsePricingModels(response.body);
        if (models.isNotEmpty) return models;
      }
    } catch (_) {
      // 並非所有 OpenAI 相容站都提供公開定價接口，繼續嘗試 /models。
    }

    final modelsUri = _modelsUri(base);
    final response = await http
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
    final rawModels = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (rawModels is! List) throw const FormatException('模型列表格式無效');
    return _sortedUniqueModels(
      rawModels.whereType<Map>().map((raw) {
        final id = '${raw['id'] ?? ''}'.trim();
        final name = '${raw['name'] ?? id}'.trim();
        return ModelInfo(id: id, name: name.isEmpty ? id : name);
      }),
    );
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
      return data['choices'][0]['message']['content'] ?? '';
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
      final diagnostics = SseStreamDiagnostics();
      await for (final data in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data);
          if (json['usage'] != null) requestStats = _extractUsage(json);
          final delta = json['choices']?[0]?['delta']?['content'];
          if (delta != null && delta.isNotEmpty) {
            yield delta;
          }
        } catch (_) {}
      }
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

    // ═══ system 只放靜態部分，動態移到最新 user ═══
    final staticPrompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
    final profilePrompt = structuredPrompt?.profilePart ?? '';
    final dynamicPrompt = structuredPrompt?.dynamicPart ?? '';
    if (staticPrompt.isNotEmpty) {
      if (shouldCache) {
        allMessages.add({
          'role': 'system',
          'content': <Map<String, dynamic>>[
            {
              'type': 'text',
              'text': staticPrompt,
              'cache_control': Map<String, String>.from(cacheControl),
            },
          ],
        });
      } else {
        allMessages.add({'role': 'system', 'content': staticPrompt});
      }
    }
    if (profilePrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': profilePrompt});
    }
    if (dynamicPrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': dynamicPrompt});
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
        minIndex: staticPrompt.isNotEmpty ? 1 : 0,
        maxIndexExclusive: latestUserIndex >= 0
            ? latestUserIndex
            : allMessages.length,
        cacheControl: cacheControl,
      );
    }

    return {
      'model': _modelForRequest(model),
      'messages': allMessages,
      'stream': stream,
    };
  }
}
