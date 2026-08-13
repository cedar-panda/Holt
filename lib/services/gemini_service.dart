import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'api_adapter.dart';
import 'model_info.dart';
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'token_estimator.dart';
import 'system_context_debug.dart';

/// Google Gemini API 直連
/// Context caching 依模型有不同最低 token 門檻
/// 達不到門檻時降級為普通請求
class GeminiService implements ApiAdapter {
  final String apiKey;
  final String modelId;
  bool thinkingEnabled;
  http.Client? _activeClient;
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// 緩存名稱（跨請求復用，有效期內不重建）
  String? _activeCacheName;
  DateTime? _cacheExpiry;
  String? _cachedStaticHash;

  /// 最近一次統計
  static Map<String, int> lastCacheStats = {};
  static final Map<String, _GeminiCacheEntry> _cacheEntries = {};

  static void resetCacheStats() {
    lastCacheStats = {};
  }

  static const Duration _cacheTtl = Duration(hours: 1);

  GeminiService({
    required this.apiKey,
    this.modelId = 'gemini-2.5-flash',
    this.thinkingEnabled = false,
  });

  /// Loads concrete Gemini models that accept `generateContent` requests.
  ///
  /// The API key stays in the request header so it cannot leak through URLs,
  /// redirect logs, or exception messages.
  static Future<List<ModelInfo>> fetchModels(
    String apiKey, {
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final response = await activeClient
          .get(
            Uri.parse('$_baseUrl/models'),
            headers: {'x-goog-api-key': apiKey},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('無法獲取 Gemini 模型列表：${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map ? decoded['models'] : null;
      if (rawModels is! List) {
        throw const FormatException('Gemini 模型列表格式不正確');
      }
      final models = <ModelInfo>[];
      for (final raw in rawModels) {
        if (raw is! Map) continue;
        final methods = _modelStringList(raw['supportedGenerationMethods']);
        if (!methods.contains('generateContent')) continue;
        final rawName = raw['name']?.toString().trim() ?? '';
        final id = rawName.startsWith('models/')
            ? rawName.substring('models/'.length)
            : rawName;
        if (id.isEmpty || id.toLowerCase().contains('embedding')) continue;
        final displayName = raw['displayName']?.toString().trim() ?? '';
        models.add(
          ModelInfo(
            id: id,
            name: displayName.isEmpty ? id : displayName,
            supportedParameters: methods,
          ),
        );
      }
      models.sort((a, b) => a.name.compareTo(b.name));
      return models;
    } finally {
      ownedClient?.close();
    }
  }

  static List<String> _modelStringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> debugBuildBodyForTesting({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    String? activeCacheName,
  }) {
    final previousCacheName = _activeCacheName;
    _activeCacheName = activeCacheName;
    try {
      return _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
      );
    } finally {
      _activeCacheName = previousCacheName;
    }
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
    final m = model.isNotEmpty ? _extractModel(model) : modelId;
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      // 嘗試 context caching；建立 cachedContents 也共用同一個可取消 client。
      var requestStats = await _ensureCache(
        structuredPrompt,
        m,
        client: client,
      );

      final body = _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
      );

      final url = '$_baseUrl/models/$m:generateContent?key=$apiKey';
      final response = await client
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode != 200) {
        throw Exception('Gemini 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      requestStats = _extractUsage(data, base: requestStats);
      onUsage?.call(
        ApiUsage.fromStats(requestStats, cacheReadKey: 'cached_tokens'),
      );
      return _replyText(data['candidates']?[0]?['content']);
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
    final m = model.isNotEmpty ? _extractModel(model) : modelId;
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      var requestStats = await _ensureCache(
        structuredPrompt,
        m,
        client: client,
      );

      final body = _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
      );

      final url =
          '$_baseUrl/models/$m:streamGenerateContent?alt=sse&key=$apiKey';

      final request = http.Request('POST', Uri.parse(url));
      request.headers.addAll({'Content-Type': 'application/json'});
      request.body = jsonEncode(body);

      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'Gemini',
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('Gemini 錯誤 ${response.statusCode}: $err');
      }

      final diagnostics = SseStreamDiagnostics();
      var reasoningOpen = false;
      await for (final data in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final json = jsonDecode(data);
          if (json['usageMetadata'] != null) {
            requestStats = _extractUsage(json, base: requestStats);
          }
          final parts = json['candidates']?[0]?['content']?['parts'];
          if (parts is List) {
            for (final part in parts) {
              if (part is! Map) continue;
              final text = part['text'];
              if (text is! String || text.isEmpty) continue;
              final isThought = part['thought'] == true;
              if (isThought && thinkingEnabled) {
                if (!reasoningOpen) {
                  reasoningOpen = true;
                  yield '<think>';
                }
                yield text;
              } else if (!isThought) {
                if (reasoningOpen) {
                  reasoningOpen = false;
                  yield '</think>';
                }
                yield text;
              }
            }
          }
        } catch (_) {}
      }
      if (reasoningOpen) yield '</think>';
      onUsage?.call(
        ApiUsage.fromStats(
          requestStats,
          cacheReadKey: 'cached_tokens',
          diagnostics: <String, Object?>{
            'malformed_utf8_replacements':
                diagnostics.malformedUtf8Replacements,
          },
        ),
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

  String _extractModel(String model) {
    // 如果是 OpenRouter 格式（例如 "google/gemini-2.5-flash"）
    if (model.contains('/')) return model.split('/').last;
    return model;
  }

  // ═══════════════════════════════════
  // Context Caching
  // ═══════════════════════════════════

  Future<Map<String, int>> _ensureCache(
    StructuredPrompt? prompt,
    String model, {
    required http.Client client,
  }) async {
    Map<String, int> publish(Map<String, int> stats) {
      lastCacheStats = Map<String, int>.from(stats);
      return stats;
    }

    if (prompt == null) return publish(<String, int>{});
    if (!await MemorySettings.getEnablePromptCaching()) {
      _activeCacheName = null;
      _cachedStaticHash = null;
      _cacheExpiry = null;
      return publish(<String, int>{});
    }

    final minCacheTokens = TokenEstimator.cacheThresholdForModel(
      provider: 'gemini',
      model: model,
    );

    final hashStr = prompt.cacheableParts.join('\n\n');
    final staticHash = sha256.convert(utf8.encode(hashStr)).toString();
    final estimatedTokens = _estimateTokens(hashStr);

    // 門檻不到，不緩存
    if (estimatedTokens < minCacheTokens) {
      _activeCacheName = null;
      _cachedStaticHash = null;
      _cacheExpiry = null;
      return publish(<String, int>{
        'cache_status': 0,
        'cache_threshold': minCacheTokens,
      });
    }

    final now = DateTime.now();
    if (_activeCacheName != null &&
        _cachedStaticHash == staticHash &&
        _cacheExpiry != null &&
        now.isBefore(_cacheExpiry!)) {
      return publish(<String, int>{
        'cache_status': 2,
        'cache_threshold': minCacheTokens,
      });
    }

    final cacheKey = '${apiKey.hashCode}:$model:$staticHash';
    _cacheEntries.removeWhere((_, entry) => !now.isBefore(entry.expiry));

    final cached = _cacheEntries[cacheKey];
    if (cached != null) {
      _activeCacheName = cached.name;
      _cachedStaticHash = staticHash;
      _cacheExpiry = cached.expiry;
      return publish(<String, int>{
        'cache_status': 2,
        'cache_threshold': minCacheTokens,
      });
    }

    // 建立新緩存
    try {
      final cacheBody = {
        'model': 'models/$model',
        'systemInstruction': {
          'parts': prompt.cacheableParts
              .where((part) => part.isNotEmpty)
              .map((part) => <String, String>{'text': part})
              .toList(),
        },
        'ttl': '${_cacheTtl.inSeconds}s',
      };

      final response = await client.post(
        Uri.parse('$_baseUrl/cachedContents?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(cacheBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _activeCacheName = data['name'];
        _cachedStaticHash = staticHash;
        _cacheExpiry = DateTime.now().add(_cacheTtl);
        if (_activeCacheName != null && _cacheExpiry != null) {
          _cacheEntries[cacheKey] = _GeminiCacheEntry(
            name: _activeCacheName!,
            expiry: _cacheExpiry!,
          );
        }
        return publish(<String, int>{
          'cache_status': 1,
          'cache_threshold': minCacheTokens,
        });
      } else {
        // 緩存建立失敗，降級為普通請求
        _activeCacheName = null;
        return publish(<String, int>{
          'cache_status': -1,
          'cache_threshold': minCacheTokens,
        });
      }
    } catch (_) {
      _activeCacheName = null;
      _cachedStaticHash = null;
      _cacheExpiry = null;
      return publish(<String, int>{
        'cache_status': -1,
        'cache_threshold': minCacheTokens,
      });
    }
  }

  Map<String, dynamic> _buildBody(
    List<Map<String, String>> messages,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
  }) {
    final contents = <Map<String, dynamic>>[];

    for (final m in messages) {
      contents.add({
        'role': m['role'] == 'assistant' ? 'model' : 'user',
        'parts': [
          {'text': m['content'] ?? ''},
        ],
      });
    }

    final body = <String, dynamic>{'contents': contents};

    final liveState = structuredPrompt?.requestOnlyPart ?? '';
    final attachedToModel = RuntimeContextSidecar.appendToGeminiPreviousModel(
      contents,
      liveState,
    );
    final useCachedContent =
        _activeCacheName != null &&
        (liveState.trim().isEmpty || attachedToModel);
    var runtimeTransport = attachedToModel ? 'gemini_model_state' : '';
    var runtimeFallback = '';

    if (useCachedContent) {
      // 使用緩存，system prompt 在緩存裡
      body['cachedContent'] = _activeCacheName;
    } else {
      // 首輪沒有上一個 model turn 可承載 request-only Live State，只能回退
      // systemInstruction。這時不用 cachedContent，避免 Gemini 禁止兩者並存。
      final parts = <Map<String, String>>[];
      if (structuredPrompt != null) {
        for (final part in structuredPrompt.cacheableParts) {
          if (part.isNotEmpty) parts.add({'text': part});
        }
      } else if (systemPrompt != null && systemPrompt.isNotEmpty) {
        parts.add({'text': systemPrompt});
      }

      if (!attachedToModel &&
          RuntimeContextSidecar.appendToGeminiSystemParts(parts, liveState)) {
        runtimeTransport = 'gemini_system_instruction_fallback';
        runtimeFallback = 'No previous model turn was available.';
      }

      if (parts.isNotEmpty) {
        body['systemInstruction'] = {'parts': parts};
      }
    }

    body['generationConfig'] = <String, dynamic>{
      'maxOutputTokens': 4096,
      // Gemini 2.5 exposes hidden thoughts by default. Explicitly disable
      // that budget when Thinking is off; leaving it absent preserves the
      // provider's normal dynamic budget when Thinking is on.
      if (!thinkingEnabled && _supportsThinkingBudget(modelId))
        'thinkingConfig': <String, int>{'thinkingBudget': 0},
    };

    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: 'gemini',
        model: modelId,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: CacheSession.conversationId,
        transport: runtimeTransport,
        sourceMessages: messages,
        requestMessages: contents,
        stableContext: structuredPrompt.cacheableParts.join('\n\n'),
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: useCachedContent,
        cachePrefixPreserved: useCachedContent || liveState.trim().isEmpty,
        fallbackReason: runtimeFallback,
        topLevelRoles: body.containsKey('cachedContent')
            ? const <String>['cachedContent']
            : (body.containsKey('systemInstruction')
                  ? const <String>['systemInstruction']
                  : const <String>[]),
        roleKey: 'role',
        contentKey: 'parts',
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }

    return body;
  }

  String _replyText(dynamic content) {
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) return '';
    final reasoning = StringBuffer();
    final answer = StringBuffer();
    for (final part in parts) {
      if (part is! Map || part['text'] is! String) continue;
      if (part['thought'] == true) {
        reasoning.write(part['text']);
      } else {
        answer.write(part['text']);
      }
    }
    if (thinkingEnabled && reasoning.isNotEmpty) {
      return '<think>$reasoning</think>$answer';
    }
    return answer.toString();
  }

  static bool _supportsThinkingBudget(String model) =>
      model.toLowerCase().contains('gemini-2.5');

  Map<String, int> _extractUsage(
    Map<String, dynamic> data, {
    Map<String, int> base = const <String, int>{},
  }) {
    final usage = data['usageMetadata'];
    if (usage == null) return Map<String, int>.from(base);
    final stats = <String, int>{
      ...base,
      'prompt_tokens': usage['promptTokenCount'] ?? 0,
      'completion_tokens': usage['candidatesTokenCount'] ?? 0,
      'cached_tokens': usage['cachedContentTokenCount'] ?? 0,
    };
    lastCacheStats = Map<String, int>.from(stats);
    return stats;
  }

  int _estimateTokens(String text) {
    final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    final other = text.length - chinese;
    return (chinese / 1.5 + other / 4).round();
  }
}

class _GeminiCacheEntry {
  final String name;
  final DateTime expiry;

  const _GeminiCacheEntry({required this.name, required this.expiry});
}
