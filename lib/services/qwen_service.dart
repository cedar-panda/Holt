import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';

/// 通義千問 API（阿里雲 DashScope，OpenAI 兼容格式）
/// endpoint: compatible-mode/v1
class QwenService implements ApiAdapter {
  final String apiKey;
  http.Client? _activeClient;
  static const String _baseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';

  static Map<String, int> lastCacheStats = {};

  QwenService({required this.apiKey});

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
        throw Exception('Qwen 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      final stats = _extractUsage(data);
      if (stats != null) onUsage?.call(ApiUsage.fromStats(stats));
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
        provider: 'Qwen',
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('Qwen 錯誤 ${response.statusCode}: $err');
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
          if (delta != null && delta.isNotEmpty) yield delta;
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

    // User turn 僅保留用戶原文；runtime context 使用獨立 system message。
    final staticPrompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
    final profilePrompt = structuredPrompt?.profilePart ?? '';
    final dynamicPrompt = structuredPrompt?.dynamicPart ?? '';
    if (staticPrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': staticPrompt});
    }
    if (profilePrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': profilePrompt});
    }
    if (dynamicPrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': dynamicPrompt});
    }

    for (final m in messages) {
      allMessages.add({
        'role': m['role'] ?? 'user',
        'content': m['content'] ?? '',
      });
    }

    // model 如果帶前綴就去掉
    final modelId = model.contains('/') ? model.split('/').last : model;

    return {
      'model': modelId.isEmpty ? 'qwen-plus' : modelId,
      'messages': allMessages,
      'stream': stream,
    };
  }

  Map<String, int>? _extractUsage(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage == null) return null;
    final stats = <String, int>{
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
    };
    lastCacheStats = Map<String, int>.from(stats);
    return stats;
  }
}
