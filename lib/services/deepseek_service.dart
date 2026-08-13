import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'model_info.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'system_context_debug.dart';

/// DeepSeek API（OpenAI 兼容格式，自動 prompt caching）
/// 不需要手動標記 cache_control，DeepSeek 自動緩存重複前綴
/// 最小緩存長度 128 tokens，命中時費用降為 0.1 元/百萬 token
class DeepSeekService implements ApiAdapter {
  final String apiKey;
  http.Client? _activeClient;
  static const String _baseUrl = 'https://api.deepseek.com/chat/completions';

  /// 最近一次緩存統計
  static Map<String, int> lastCacheStats = {};

  static void resetCacheStats() {
    lastCacheStats = {};
  }

  DeepSeekService({required this.apiKey});

  static Future<List<ModelInfo>> fetchModels(
    String apiKey, {
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final response = await activeClient
          .get(
            Uri.parse('https://api.deepseek.com/models'),
            headers: <String, String>{
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('無法獲取 DeepSeek 模型列表：${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map ? decoded['data'] : null;
      if (rawModels is! List) {
        throw const FormatException('DeepSeek 模型列表格式不正確');
      }
      final models = rawModels
          .whereType<Map>()
          .map((raw) {
            final id = raw['id']?.toString().trim() ?? '';
            return ModelInfo(id: id, name: id);
          })
          .where((model) => model.id.isNotEmpty)
          .toList();
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } finally {
      ownedClient?.close();
    }
  }

  Map<String, dynamic> debugBuildBodyForTesting({
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

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    resetCacheStats();
    final body = _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: false,
    );

    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final response = await client
          .post(
            Uri.parse(_baseUrl),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode != 200) {
        throw Exception('DeepSeek 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      final stats = _extractCacheStats(data);
      if (stats != null) {
        onUsage?.call(ApiUsage.fromStats(stats, cacheReadKey: 'cache_hit'));
      }
      return data['choices']?[0]?['message']?['content'] ?? '';
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
    resetCacheStats();
    final body = _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: true,
    );

    final request = http.Request('POST', Uri.parse(_baseUrl));
    request.headers.addAll(_headers());
    request.body = jsonEncode(body);

    // client 自己開的自己關（finally），連接超時 30s 防永久轉圈
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'DeepSeek',
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('DeepSeek 錯誤 ${response.statusCode}: $err');
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
          if (json['usage'] != null) requestStats = _extractCacheStats(json);
          final delta = json['choices']?[0]?['delta']?['content'];
          if (delta != null && delta.isNotEmpty) yield delta;
        } catch (_) {}
      }
      final streamDiagnostics = <String, Object?>{
        'malformed_utf8_replacements': diagnostics.malformedUtf8Replacements,
      };
      if (requestStats != null) {
        onUsage?.call(
          ApiUsage.fromStats(
            requestStats,
            cacheReadKey: 'cache_hit',
            diagnostics: streamDiagnostics,
          ),
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

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $apiKey',
  };

  Map<String, dynamic> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) {
    final allMessages = <Map<String, dynamic>>[];

    // system 僅保留穩定前綴；動態 runtime 在歷史後作 request-only system。
    final systemParts =
        structuredPrompt?.cacheableParts ?? <String>[systemPrompt ?? ''];
    for (final part in systemParts.where((part) => part.isNotEmpty)) {
      allMessages.add({'role': 'system', 'content': part});
    }

    for (final m in messages) {
      allMessages.add({
        'role': m['role'] ?? 'user',
        'content': m['content'] ?? '',
      });
    }

    final liveState = structuredPrompt?.requestOnlyPart ?? '';
    final attached = RuntimeContextSidecar.insertSystemBeforeLatestUser(
      allMessages,
      liveState,
    );

    final body = <String, dynamic>{
      'model': model.contains('/') ? model.split('/').last : model,
      'messages': allMessages,
      'stream': stream,
    };
    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: 'deepseek',
        model: model,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: CacheSession.conversationId,
        transport: attached ? 'system_before_latest_user' : '',
        sourceMessages: messages,
        requestMessages: allMessages,
        stableContext: systemParts.join('\n\n'),
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: true,
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }
    return body;
  }

  Map<String, int>? _extractCacheStats(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage == null) return null;
    final stats = <String, int>{
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
      'cache_hit': usage['prompt_cache_hit_tokens'] ?? 0,
      'cache_miss': usage['prompt_cache_miss_tokens'] ?? 0,
    };
    lastCacheStats = Map<String, int>.from(stats);
    return stats;
  }
}
