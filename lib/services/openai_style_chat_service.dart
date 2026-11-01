import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'system_context_debug.dart';

/// DeepSeek / Qwen 共用的 OpenAI 兼容 Chat Completions 骨架。
///
/// 兩家原本各寫一份、約八成相同；差異只留成下面幾個覆寫點：
/// endpoint、錯誤顯示名、usage 解析、是否要求流式結束標記、預設模型。
/// 行為與合併前一致：只送文字（不帶圖片）、system 只放穩定前綴、
/// live state 以 request-only system 插在最新 user 前。
abstract class OpenAiStyleChatService implements ApiAdapter {
  final String apiKey;
  final bool thinkingEnabled;
  http.Client? _activeClient;

  OpenAiStyleChatService({required this.apiKey, this.thinkingEnabled = false});

  /// 錯誤訊息與 StreamTransport 用的顯示名，例如 `DeepSeek`。
  String get providerLabel;

  /// SystemContextDebug 記錄用的 provider id，例如 `deepseek`。
  String get debugProviderId;

  /// 完整的 chat/completions URL。
  String get chatCompletionsUrl;

  /// 從回應 JSON 解析 usage；沒有 usage 時回傳 null。
  Map<String, int>? extractUsage(Map<String, dynamic> data);

  /// [ApiUsage.fromStats] 讀取快取命中的 key。
  String get usageCacheReadKey => 'cache_read';

  /// 流式是否必須看到 `[DONE]` 或 finish_reason，否則視為中斷。
  bool get requireStreamTerminal => false;

  /// SystemContextDebug 面板上的 cache 狀態。
  bool get debugCacheEnabled => false;

  /// 去掉前綴後模型 id 為空時的後備值；空字串代表不補。
  String get fallbackModelId => '';

  /// 每次請求開始前呼叫（例如重置靜態快取統計）。
  void onRequestStart() {}

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
    onRequestStart();
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
            Uri.parse(chatCompletionsUrl),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode != 200) {
        throw Exception(
          '$providerLabel 錯誤 ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body);
      final stats = extractUsage(data);
      if (stats != null) {
        onUsage?.call(
          ApiUsage.fromStats(stats, cacheReadKey: usageCacheReadKey),
        );
      }
      final message = data['choices']?[0]?['message'];
      final content = message is Map ? '${message['content'] ?? ''}' : '';
      final reasoning = message is Map
          ? ProviderReasoning.fromMap(message)
          : '';
      if (thinkingEnabled && reasoning.isNotEmpty) {
        return '<think>$reasoning</think>$content';
      }
      return content;
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
    onRequestStart();
    final body = _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: true,
    );

    final request = http.Request('POST', Uri.parse(chatCompletionsUrl));
    request.headers.addAll(_headers());
    request.body = jsonEncode(body);

    // client 自己開的自己關（finally），連接超時 30s 防永久轉圈
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: providerLabel,
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('$providerLabel 錯誤 ${response.statusCode}: $err');
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
          if (json['usage'] != null) requestStats = extractUsage(json);
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
          final delta = deltaMap is Map ? deltaMap['content'] : null;
          if (delta is String && delta.isNotEmpty) {
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
          ApiUsage.fromStats(
            requestStats,
            cacheReadKey: usageCacheReadKey,
            diagnostics: streamDiagnostics,
          ),
        );
      } else {
        onUsage?.call(ApiUsage(diagnostics: streamDiagnostics));
      }
      if (requireStreamTerminal) {
        StreamTerminalGuard.requireOpenAiCompatible(
          provider: providerLabel,
          sawDone: sawDone,
          finishReason: terminalFinishReason,
        );
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

    // model 如果帶前綴就去掉
    final modelId = model.contains('/') ? model.split('/').last : model;

    final body = <String, dynamic>{
      'model': modelId.isEmpty ? fallbackModelId : modelId,
      'messages': allMessages,
      'stream': stream,
    };
    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: debugProviderId,
        model: model,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: structuredPrompt.cacheSessionId,
        transport: attached ? 'system_before_latest_user' : '',
        sourceMessages: messages,
        requestMessages: allMessages,
        stableContext: systemParts.join('\n\n'),
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: debugCacheEnabled,
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }
    return body;
  }
}
