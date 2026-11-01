import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'api_adapter.dart';
import 'cache/gemini_cache_policy.dart';
import 'model_info.dart';
import 'locale_strings.dart';
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'token_estimator.dart';
import 'system_context_debug.dart';
import 'reasoning_effort.dart';

class GeminiResponseTruncatedException implements Exception {
  const GeminiResponseTruncatedException();

  @override
  String toString() => L.pick(
    en: 'Gemini stopped at its output limit. The received text was kept; retry to continue.',
    zhTW: 'Gemini 已達輸出長度上限，現有內容已保留，可重試繼續。',
    zhCN: 'Gemini 已达到输出长度上限，现有内容已保留，可重试继续。',
  );
}

class GeminiThoughtOnlyException implements Exception {
  const GeminiThoughtOnlyException();

  @override
  String toString() => L.pick(
    en: 'Gemini returned thinking without a final reply. Please retry.',
    zhTW: 'Gemini 只返回了思考內容，沒有正文，請重新落筆。',
    zhCN: 'Gemini 只返回了思考内容，没有正文，请重新落笔。',
  );
}

/// Google Gemini API 直連
/// Context caching 依模型有不同最低 token 門檻
/// 達不到門檻時降級為普通請求
class GeminiService implements ApiAdapter {
  final String apiKey;
  final String modelId;
  bool thinkingEnabled;
  String reasoningEffort;
  http.Client? _activeClient;
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// 緩存名稱（跨請求復用，有效期內不重建）
  String? _activeCacheName;
  DateTime? _cacheExpiry;
  String? _cachedStaticHash;
  String? _activeCacheNamespace;
  String? _activeCachedMessageHash;
  int _activeCachedMessageCount = 0;

  /// 最近一次統計
  static Map<String, int> lastCacheStats = {};
  static final Map<String, _GeminiCacheEntry> _cacheEntries = {};

  final http.Client Function()? _clientFactory;

  static void resetCacheStats() {
    lastCacheStats = {};
  }

  static const Duration _cacheTtl = GeminiCachePolicy.ttl;

  GeminiService({
    required this.apiKey,
    this.modelId = 'gemini-2.5-flash',
    this.thinkingEnabled = false,
    this.reasoningEffort = ReasoningEffort.medium,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory;

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

  /// Dedicated discovery for vector models. Chat discovery deliberately hides
  /// these models, so the embedding picker must query the raw Gemini catalogue.
  static Future<List<ModelInfo>> fetchEmbeddingModels(
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
        throw Exception('無法獲取 Gemini Embedding 模型列表：${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map ? decoded['models'] : null;
      if (rawModels is! List) return const <ModelInfo>[];
      final models = <ModelInfo>[];
      for (final raw in rawModels) {
        if (raw is! Map) continue;
        final methods = _modelStringList(raw['supportedGenerationMethods']);
        final rawName = raw['name']?.toString().trim() ?? '';
        final id = rawName.startsWith('models/')
            ? rawName.substring('models/'.length)
            : rawName;
        final displayName = raw['displayName']?.toString().trim() ?? '';
        final searchable = '$id $displayName'.toLowerCase();
        if (!methods.contains('embedContent') ||
            !searchable.contains('embedding')) {
          continue;
        }
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
    int cachedMessagePrefixCount = 0,
  }) {
    final previousCacheName = _activeCacheName;
    final previousStaticHash = _cachedStaticHash;
    final previousCacheNamespace = _activeCacheNamespace;
    final previousMessageHash = _activeCachedMessageHash;
    final previousMessageCount = _activeCachedMessageCount;
    _activeCacheName = activeCacheName;
    _cachedStaticHash = 'debug-static';
    _activeCacheNamespace = 'debug-session';
    _activeCachedMessageCount = cachedMessagePrefixCount;
    _activeCachedMessageHash = _messagePrefixHash(
      messages,
      cachedMessagePrefixCount,
    );
    try {
      return _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        requestModel: modelId,
      );
    } finally {
      _activeCacheName = previousCacheName;
      _cachedStaticHash = previousStaticHash;
      _activeCacheNamespace = previousCacheNamespace;
      _activeCachedMessageHash = previousMessageHash;
      _activeCachedMessageCount = previousMessageCount;
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
    final client = _clientFactory?.call() ?? http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      // 嘗試 context caching；建立 cachedContents 也共用同一個可取消 client。
      var requestStats = await _ensureCache(
        structuredPrompt,
        m,
        messages: messages,
        client: client,
      );

      final body = _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        requestModel: m,
      );

      final url = '$_baseUrl/models/$m:generateContent?key=$apiKey';
      final response = await client
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_requestTimeoutForModel(m));

      if (response.statusCode != 200) {
        throw Exception('Gemini 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      requestStats = _extractUsage(data, base: requestStats);
      final primaryUsage = ApiUsage.fromStats(
        requestStats,
        cacheReadKey: 'cached_tokens',
      );
      if (data['candidates']?[0]?['finishReason']?.toString() == 'MAX_TOKENS') {
        onUsage?.call(primaryUsage);
        throw const GeminiResponseTruncatedException();
      }
      final content = data['candidates']?[0]?['content'];
      final reply = _replyText(content);
      if (thinkingEnabled &&
          _hasThoughtText(content) &&
          !_hasFinalAnswer(reply)) {
        final originalThinking = thinkingEnabled;
        ApiUsage? retryUsage;
        thinkingEnabled = false;
        try {
          late String fallback;
          try {
            fallback = await sendMessage(
              messages: messages,
              model: model,
              systemPrompt: systemPrompt,
              structuredPrompt: structuredPrompt,
              onUsage: (usage) => retryUsage = usage,
            );
          } catch (_) {
            onUsage?.call(_combineUsage(primaryUsage, retryUsage));
            rethrow;
          }
          if (fallback.trim().isEmpty) {
            throw const GeminiThoughtOnlyException();
          }
          onUsage?.call(_combineUsage(primaryUsage, retryUsage));
          return '$reply$fallback';
        } finally {
          thinkingEnabled = originalThinking;
        }
      }
      if (!thinkingEnabled &&
          _hasThoughtText(content) &&
          reply.trim().isEmpty) {
        onUsage?.call(primaryUsage);
        throw const GeminiThoughtOnlyException();
      }
      onUsage?.call(primaryUsage);
      return reply;
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
    final client = _clientFactory?.call() ?? http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      var requestStats = await _ensureCache(
        structuredPrompt,
        m,
        messages: messages,
        client: client,
      );

      final body = _buildBody(
        messages,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        requestModel: m,
      );

      final url =
          '$_baseUrl/models/$m:streamGenerateContent?alt=sse&key=$apiKey';

      final request = http.Request('POST', Uri.parse(url));
      request.headers.addAll({'Content-Type': 'application/json'});
      request.body = jsonEncode(body);

      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'Gemini',
        timeout: _requestTimeoutForModel(m),
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('Gemini 錯誤 ${response.statusCode}: $err');
      }

      final diagnostics = SseStreamDiagnostics();
      var reasoningOpen = false;
      final thoughtBuffer = StringBuffer();
      var answerCharacters = 0;
      String? terminalFinishReason;
      // 思考模式下模型可能長時間只輸出思考 chunk，加長超時
      final sseTimeout = GeminiCachePolicy.usesImplicitCaching(m)
          ? _requestTimeoutForModel(m)
          : (thinkingEnabled
                ? const Duration(seconds: 120)
                : SseStream.defaultIdleTimeout);
      await for (final data in SseStream.data(
        response.stream,
        idleTimeout: sseTimeout,
        diagnostics: diagnostics,
      )) {
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final json = jsonDecode(data);
          if (json['usageMetadata'] != null) {
            requestStats = _extractUsage(json, base: requestStats);
          }
          // 檢查是否因安全過濾或 token 上限被截斷
          final finishReason = json['candidates']?[0]?['finishReason']
              ?.toString();
          if (finishReason != null && finishReason.isNotEmpty) {
            terminalFinishReason = finishReason;
          }
          final parts = json['candidates']?[0]?['content']?['parts'];
          if (parts is List) {
            for (final part in parts) {
              if (part is! Map) continue;
              final text = part['text'];
              if (text is! String || text.isEmpty) continue;
              final isThought = part['thought'] == true;
              if (isThought) {
                thoughtBuffer.write(text);
                if (thinkingEnabled) {
                  if (!reasoningOpen) {
                    reasoningOpen = true;
                    yield '<think>';
                  }
                  yield text;
                }
              } else if (!isThought) {
                answerCharacters += text.runes.length;
                if (reasoningOpen) {
                  reasoningOpen = false;
                  yield '</think>';
                }
                yield text;
              }
            }
          }
          // 安全攔截：candidates 為空或被過濾
          if (finishReason == 'SAFETY' || finishReason == 'RECITATION') {
            // 靜默：上層會看到空回覆並提示 user
          }
        } catch (e, st) {
          // 記錄而非靜默，方便追蹤截斷原因
          developer.log(
            'Gemini SSE chunk parse failed',
            error: e,
            stackTrace: st,
            name: 'GeminiService',
          );
        }
      }
      if (reasoningOpen) yield '</think>';
      final primaryUsage = ApiUsage.fromStats(
        requestStats,
        cacheReadKey: 'cached_tokens',
        diagnostics: <String, Object?>{
          'malformed_utf8_replacements': diagnostics.malformedUtf8Replacements,
        },
      );
      if (terminalFinishReason == 'MAX_TOKENS') {
        onUsage?.call(primaryUsage);
        throw const GeminiResponseTruncatedException();
      }
      if (terminalFinishReason == null || terminalFinishReason.isEmpty) {
        onUsage?.call(primaryUsage);
        throw const StreamEndedWithoutTerminalException('Gemini');
      }
      if (terminalFinishReason != 'STOP') {
        onUsage?.call(primaryUsage);
        throw StreamEndedWithReasonException('Gemini', terminalFinishReason);
      }
      if (thoughtBuffer.isNotEmpty && answerCharacters == 0) {
        if (!thinkingEnabled) {
          onUsage?.call(primaryUsage);
          throw const GeminiThoughtOnlyException();
        }
        final originalThinking = thinkingEnabled;
        ApiUsage? retryUsage;
        var retryEmitted = false;
        thinkingEnabled = false;
        try {
          try {
            await for (final chunk in sendMessageStream(
              messages: messages,
              model: model,
              systemPrompt: systemPrompt,
              structuredPrompt: structuredPrompt,
              onUsage: (usage) => retryUsage = usage,
            )) {
              if (chunk.isNotEmpty) retryEmitted = true;
              yield chunk;
            }
          } catch (_) {
            onUsage?.call(_combineUsage(primaryUsage, retryUsage));
            rethrow;
          }
        } finally {
          thinkingEnabled = originalThinking;
        }
        onUsage?.call(_combineUsage(primaryUsage, retryUsage));
        if (!retryEmitted) throw const GeminiThoughtOnlyException();
        return;
      }
      onUsage?.call(primaryUsage);
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
    required List<Map<String, String>> messages,
    required http.Client client,
  }) async {
    Map<String, int> publish(Map<String, int> stats) {
      lastCacheStats = Map<String, int>.from(stats);
      return stats;
    }

    if (prompt == null) return publish(<String, int>{});

    final thresholdInfo = TokenEstimator.cacheThresholdInfoForModel(
      provider: 'gemini',
      model: model,
    );
    final minCacheTokens = thresholdInfo.minimumTokens;

    // 未列入 Google 官方門檻表的模型不可把「未知」當成 0 tokens 達標。
    // 保持普通請求可用，但不建立可能被 provider 拒絕的 explicit cache。
    if (minCacheTokens == null) {
      _clearActiveCache();
      return publish(<String, int>{'cache_status': 0, 'cache_threshold': 0});
    }

    final staticText = prompt.cacheableParts.join('\n\n');
    final staticTokens = _estimateTokens(staticText);

    // Gemini 4 Argon only supports provider-managed implicit caching. Never
    // call cachedContents for it: keep systemInstruction and the complete
    // selected history in the ordinary request so Google can match the common
    // prefix. A cache hit is confirmed only by cachedContentTokenCount later.
    if (GeminiCachePolicy.usesImplicitCaching(model)) {
      _clearActiveCache();
      final historyTokens = _estimateMessagePrefixTokens(
        messages,
        messages.length,
      );
      final dynamicTokens = _estimateTokens(prompt.requestOnlyPart);
      // Implicit cache eligibility is based on the reusable common prefix.
      // The request-only live state changes every turn and must not make the
      // UI claim that a stable prefix reached Google's minimum by itself.
      final reusablePrefixTokens = staticTokens + historyTokens;
      return publish(<String, int>{
        'cache_status': reusablePrefixTokens >= minCacheTokens ? 3 : 0,
        'cache_implicit': 1,
        'cache_threshold': minCacheTokens,
        'cache_prefix_tokens': reusablePrefixTokens,
        'cache_static_tokens': staticTokens,
        'cache_history_tokens': historyTokens,
        'cache_history_messages': messages.length,
        'cache_dynamic_tokens': dynamicTokens,
      });
    }

    if (!await MemorySettings.getEnablePromptCaching()) {
      _clearActiveCache();
      return publish(<String, int>{});
    }

    final staticHash = sha256.convert(utf8.encode(staticText)).toString();
    final cacheNamespace = _cacheNamespace(prompt);
    final candidateMessageCount = _historySnapshotMessageCount(messages);
    final candidateMessageHash = _messagePrefixHash(
      messages,
      candidateMessageCount,
    );
    final historyTokens = _estimateMessagePrefixTokens(
      messages,
      candidateMessageCount,
    );
    final estimatedTokens = staticTokens + historyTokens;
    final now = DateTime.now();

    _cacheEntries.removeWhere((_, entry) => !now.isBefore(entry.expiry));

    final activeMatches =
        _activeCacheName != null &&
        _cachedStaticHash == staticHash &&
        _activeCacheNamespace == cacheNamespace &&
        _cacheExpiry != null &&
        now.isBefore(_cacheExpiry!) &&
        _messagePrefixMatches(
          messages,
          count: _activeCachedMessageCount,
          expectedHash: _activeCachedMessageHash,
        );
    if (activeMatches) {
      final pendingHistoryTokens = _estimateMessageRangeTokens(
        messages,
        _activeCachedMessageCount,
        candidateMessageCount,
      );
      if (candidateMessageCount <= _activeCachedMessageCount ||
          pendingHistoryTokens < minCacheTokens) {
        return publish(<String, int>{
          'cache_status': 2,
          'cache_threshold': minCacheTokens,
          'cache_static_tokens': staticTokens,
          'cache_history_tokens': _estimateMessagePrefixTokens(
            messages,
            _activeCachedMessageCount,
          ),
          'cache_history_messages': _activeCachedMessageCount,
          'cache_pending_history_tokens': pendingHistoryTokens,
        });
      }
    }

    _clearActiveCache();

    final reusable = _bestReusableEntry(
      model: model,
      cacheNamespace: cacheNamespace,
      staticHash: staticHash,
      messages: messages,
      now: now,
    );
    if (reusable != null) {
      final pendingHistoryTokens = _estimateMessageRangeTokens(
        messages,
        reusable.messagePrefixCount,
        candidateMessageCount,
      );
      if (candidateMessageCount <= reusable.messagePrefixCount ||
          pendingHistoryTokens < minCacheTokens) {
        _activateCache(reusable);
        return publish(<String, int>{
          'cache_status': 2,
          'cache_threshold': minCacheTokens,
          'cache_static_tokens': staticTokens,
          'cache_history_tokens': _estimateMessagePrefixTokens(
            messages,
            reusable.messagePrefixCount,
          ),
          'cache_history_messages': reusable.messagePrefixCount,
          'cache_pending_history_tokens': pendingHistoryTokens,
        });
      }
    }

    // Gemini 的 explicit cache 門檻以「穩定 system 前綴＋舊對話快照」
    // 合計。最新 assistant 與本輪 user 留在普通 contents，讓 request-only
    // Live State 仍能安全附著，也避免每句話都重建 cache。
    if (estimatedTokens < minCacheTokens) {
      return publish(<String, int>{
        'cache_status': 0,
        'cache_threshold': minCacheTokens,
        'cache_static_tokens': staticTokens,
        'cache_history_tokens': historyTokens,
        'cache_history_messages': candidateMessageCount,
      });
    }

    // 建立新緩存
    try {
      final cacheBody = <String, dynamic>{
        'model': 'models/$model',
        'systemInstruction': {
          'parts': prompt.cacheableParts
              .where((part) => part.isNotEmpty)
              .map((part) => <String, String>{'text': part})
              .toList(),
        },
        if (candidateMessageCount > 0)
          'contents': _geminiContents(
            messages,
            endIndexExclusive: candidateMessageCount,
          ),
        'ttl': '${_cacheTtl.inSeconds}s',
      };

      final response = await client
          .post(
            Uri.parse('$_baseUrl/cachedContents?key=$apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(cacheBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final cacheName = data['name']?.toString().trim() ?? '';
        if (cacheName.isEmpty) {
          throw const FormatException('Missing cache name');
        }
        final entry = _GeminiCacheEntry(
          name: cacheName,
          expiry: DateTime.now().add(_cacheTtl),
          apiKeyFingerprint: apiKey.hashCode,
          model: model,
          cacheNamespace: cacheNamespace,
          staticHash: staticHash,
          messagePrefixHash: candidateMessageHash,
          messagePrefixCount: candidateMessageCount,
        );
        _cacheEntries[_cacheEntryKey(entry)] = entry;
        _activateCache(entry);
        return publish(<String, int>{
          'cache_status': 1,
          'cache_threshold': minCacheTokens,
          'cache_static_tokens': staticTokens,
          'cache_history_tokens': historyTokens,
          'cache_history_messages': candidateMessageCount,
        });
      } else {
        // 緩存建立失敗，降級為普通請求
        _clearActiveCache();
        return publish(<String, int>{
          'cache_status': -1,
          'cache_threshold': minCacheTokens,
          'cache_static_tokens': staticTokens,
          'cache_history_tokens': historyTokens,
          'cache_history_messages': candidateMessageCount,
        });
      }
    } catch (_) {
      _clearActiveCache();
      return publish(<String, int>{
        'cache_status': -1,
        'cache_threshold': minCacheTokens,
        'cache_static_tokens': staticTokens,
        'cache_history_tokens': historyTokens,
        'cache_history_messages': candidateMessageCount,
      });
    }
  }

  String _cacheNamespace(StructuredPrompt prompt) => <String>[
    prompt.sessionIdentity?.cacheNamespace ?? prompt.cacheSessionId,
    prompt.cacheContextMode,
    prompt.cacheChannel,
  ].join('\u0000');

  static int _historySnapshotMessageCount(List<Map<String, String>> messages) {
    // 保留最新 assistant/model turn 與本輪 user 在普通 request 中。
    // 這樣 request-only Live State 仍可附在真實的 model turn 上；正常交替
    // 對話的 cache 快照會停在前一個 user turn，符合 Gemini prefix 順序。
    for (var i = messages.length - 1; i >= 0; i--) {
      final role = messages[i]['role'];
      if (role == 'assistant' || role == 'model') return i;
    }
    return 0;
  }

  static String _messagePrefixHash(
    List<Map<String, String>> messages,
    int count,
  ) {
    if (count <= 0) return '';
    final safeCount = count.clamp(0, messages.length);
    final canonical = <Map<String, String>>[
      for (var i = 0; i < safeCount; i++)
        <String, String>{
          'role': messages[i]['role'] ?? '',
          'content': messages[i]['content'] ?? '',
          'image_data_urls':
              messages[i]['image_data_urls'] ??
              messages[i]['image_data_url'] ??
              '',
        },
    ];
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static bool _messagePrefixMatches(
    List<Map<String, String>> messages, {
    required int count,
    required String? expectedHash,
  }) {
    if (count == 0) return expectedHash == null || expectedHash.isEmpty;
    if (count < 0 || count > messages.length || expectedHash == null) {
      return false;
    }
    return _messagePrefixHash(messages, count) == expectedHash;
  }

  static int _estimateMessagePrefixTokens(
    List<Map<String, String>> messages,
    int count,
  ) {
    if (count <= 0) return 0;
    final safeCount = count.clamp(0, messages.length);
    final text = <String>[
      for (var i = 0; i < safeCount; i++)
        '${messages[i]['role'] ?? ''}: ${messages[i]['content'] ?? ''}',
    ].join('\n');
    return _estimateTokens(text);
  }

  static int _estimateMessageRangeTokens(
    List<Map<String, String>> messages,
    int start,
    int end,
  ) {
    final safeStart = start.clamp(0, messages.length);
    final safeEnd = end.clamp(safeStart, messages.length);
    if (safeStart >= safeEnd) return 0;
    final text = <String>[
      for (var i = safeStart; i < safeEnd; i++)
        '${messages[i]['role'] ?? ''}: ${messages[i]['content'] ?? ''}',
    ].join('\n');
    return _estimateTokens(text);
  }

  /// Keep-alive 與設定 UI 共用的 Gemini explicit-cache 資格判斷。
  /// 門檻包含穩定 system 前綴與可安全凍結的舊對話快照。
  static bool hasCacheableExplicitPrefix({
    required StructuredPrompt prompt,
    required List<Map<String, String>> messages,
    required String model,
  }) {
    if (!GeminiCachePolicy.supportsExplicitCaching(model)) return false;
    final threshold = TokenEstimator.cacheThresholdInfoForModel(
      provider: 'gemini',
      model: model,
    ).minimumTokens;
    if (threshold == null) return false;
    final staticTokens = _estimateTokens(prompt.cacheableParts.join('\n\n'));
    final historyCount = _historySnapshotMessageCount(messages);
    final historyTokens = _estimateMessagePrefixTokens(messages, historyCount);
    return staticTokens + historyTokens >= threshold;
  }

  static List<Map<String, dynamic>> _geminiContents(
    List<Map<String, String>> messages, {
    int startIndex = 0,
    int? endIndexExclusive,
  }) {
    final start = startIndex.clamp(0, messages.length);
    final end = (endIndexExclusive ?? messages.length).clamp(
      start,
      messages.length,
    );
    final contents = <Map<String, dynamic>>[];
    for (var i = start; i < end; i++) {
      final parts = <Map<String, dynamic>>[];
      for (final url in ApiMessageMedia.imageDataUrls(messages[i])) {
        final media = ApiMessageMedia.splitDataUrl(url);
        if (media == null) continue;
        parts.add(<String, dynamic>{
          'inlineData': <String, String>{
            'mimeType': media.mimeType,
            'data': media.base64,
          },
        });
      }
      final content = messages[i]['content'] ?? '';
      if (content.isNotEmpty || parts.isEmpty) {
        parts.add(<String, String>{'text': content});
      }
      contents.add(<String, dynamic>{
        'role':
            messages[i]['role'] == 'assistant' || messages[i]['role'] == 'model'
            ? 'model'
            : 'user',
        'parts': parts,
      });
    }
    return contents;
  }

  _GeminiCacheEntry? _bestReusableEntry({
    required String model,
    required String cacheNamespace,
    required String staticHash,
    required List<Map<String, String>> messages,
    required DateTime now,
  }) {
    _GeminiCacheEntry? best;
    for (final entry in _cacheEntries.values) {
      if (entry.apiKeyFingerprint != apiKey.hashCode ||
          entry.model != model ||
          entry.cacheNamespace != cacheNamespace ||
          entry.staticHash != staticHash ||
          !now.isBefore(entry.expiry) ||
          !_messagePrefixMatches(
            messages,
            count: entry.messagePrefixCount,
            expectedHash: entry.messagePrefixHash,
          )) {
        continue;
      }
      if (best == null || entry.messagePrefixCount > best.messagePrefixCount) {
        best = entry;
      }
    }
    return best;
  }

  static String _cacheEntryKey(_GeminiCacheEntry entry) => sha256
      .convert(
        utf8.encode(
          <Object>[
            entry.apiKeyFingerprint,
            entry.model,
            entry.cacheNamespace,
            entry.staticHash,
            entry.messagePrefixHash,
          ].join('\u0000'),
        ),
      )
      .toString();

  void _activateCache(_GeminiCacheEntry entry) {
    _activeCacheName = entry.name;
    _cacheExpiry = entry.expiry;
    _cachedStaticHash = entry.staticHash;
    _activeCacheNamespace = entry.cacheNamespace;
    _activeCachedMessageHash = entry.messagePrefixHash;
    _activeCachedMessageCount = entry.messagePrefixCount;
  }

  void _clearActiveCache() {
    _activeCacheName = null;
    _cacheExpiry = null;
    _cachedStaticHash = null;
    _activeCacheNamespace = null;
    _activeCachedMessageHash = null;
    _activeCachedMessageCount = 0;
  }

  Map<String, dynamic> _buildBody(
    List<Map<String, String>> messages,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    String? requestModel,
  }) {
    final liveState = structuredPrompt?.requestOnlyPart ?? '';
    final cachePrefixMatches =
        _activeCacheName != null &&
        _messagePrefixMatches(
          messages,
          count: _activeCachedMessageCount,
          expectedHash: _activeCachedMessageHash,
        );
    var contents = _geminiContents(
      messages,
      startIndex: cachePrefixMatches ? _activeCachedMessageCount : 0,
    );
    var attachedToModel = RuntimeContextSidecar.appendToGeminiPreviousModel(
      contents,
      liveState,
    );
    final useCachedContent =
        cachePrefixMatches && (liveState.trim().isEmpty || attachedToModel);

    if (!useCachedContent && cachePrefixMatches) {
      // Cache 因首輪沒有可承載 Live State 的 model turn 而不能使用時，完整
      // 還原原始 history；不可保留已裁掉的快照前綴。
      contents = _geminiContents(messages);
      attachedToModel = RuntimeContextSidecar.appendToGeminiPreviousModel(
        contents,
        liveState,
      );
    }

    final body = <String, dynamic>{'contents': contents};
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

    final activeModel = (requestModel ?? modelId).trim();
    final thinkingConfig = _thinkingConfig(activeModel);
    body['generationConfig'] = <String, dynamic>{
      'maxOutputTokens': GeminiCachePolicy.usesImplicitCaching(activeModel)
          ? 32768
          : 8192,
      if (thinkingConfig.isNotEmpty) 'thinkingConfig': thinkingConfig,
    };

    if (structuredPrompt != null) {
      final implicitCache = GeminiCachePolicy.usesImplicitCaching(activeModel);
      SystemContextDebug.recordChatRequest(
        provider: 'gemini',
        model: modelId,
        cacheChannel: structuredPrompt.cacheChannel,
        sessionId: structuredPrompt.cacheSessionId,
        transport: runtimeTransport,
        sourceMessages: messages,
        requestMessages: contents,
        stableContext: structuredPrompt.cacheableParts.join('\n\n'),
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: useCachedContent || implicitCache,
        cachePrefixPreserved:
            useCachedContent || implicitCache || liveState.trim().isEmpty,
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

  Map<String, Object?> _thinkingConfig(String model) {
    final normalized = model.toLowerCase();
    final effort = ReasoningEffort.normalize(reasoningEffort);
    if (effort == ReasoningEffort.auto) {
      // Absence is intentional: Gemini chooses the model-native default.
      return const <String, Object?>{};
    }
    final level = ReasoningEffort.normalize(
      thinkingEnabled ? reasoningEffort : ReasoningEffort.off,
    ).toUpperCase();
    if (GeminiCachePolicy.usesImplicitCaching(normalized)) {
      return <String, Object?>{
        // Argon-style models require reasoning; off means LOW with thoughts
        // hidden, matching the provider's mandatory-reasoning contract.
        'thinkingLevel': thinkingEnabled ? level : 'LOW',
        'includeThoughts': thinkingEnabled,
      };
    }
    if (thinkingEnabled && _supportsThinkingBudget(normalized)) {
      final budget = switch (ReasoningEffort.normalize(reasoningEffort)) {
        ReasoningEffort.low => 1024,
        ReasoningEffort.high => 8192,
        _ => 4096,
      };
      return <String, Object?>{
        'thinkingBudget': budget,
        'includeThoughts': true,
      };
    }
    if (thinkingEnabled) {
      return <String, Object?>{'thinkingLevel': level, 'includeThoughts': true};
    }
    if (_supportsThinkingBudget(normalized)) {
      return const <String, Object?>{
        'thinkingBudget': 0,
        'includeThoughts': false,
      };
    }
    if (normalized.contains('gemini-3')) {
      final level =
          normalized.contains('3.8') ||
              normalized.contains('3.7') ||
              normalized.contains('pro')
          ? 'low'
          : 'minimal';
      return <String, Object?>{
        'thinkingLevel': level,
        'includeThoughts': false,
      };
    }
    return const <String, Object?>{};
  }

  static bool _hasThoughtText(dynamic content) {
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) return false;
    return parts.any(
      (part) =>
          part is Map &&
          part['thought'] == true &&
          part['text'] is String &&
          (part['text'] as String).trim().isNotEmpty,
    );
  }

  static bool _hasFinalAnswer(String text) {
    final withoutThinking = text.replaceAll(
      RegExp(
        r'<(?:think|thinking)\b[^>]*>[\s\S]*?</(?:think|thinking)\s*>',
        caseSensitive: false,
      ),
      '',
    );
    return withoutThinking.trim().isNotEmpty;
  }

  static ApiUsage _combineUsage(ApiUsage first, ApiUsage? second) {
    if (second == null) return first;
    final firstCost = first.diagnostics['actual_cost_usd'];
    final secondCost = second.diagnostics['actual_cost_usd'];
    final totalCost =
        (firstCost is num ? firstCost.toDouble() : 0) +
        (secondCost is num ? secondCost.toDouble() : 0);
    return ApiUsage(
      promptTokens: first.promptTokens + second.promptTokens,
      completionTokens: first.completionTokens + second.completionTokens,
      cacheReadTokens: first.cacheReadTokens + second.cacheReadTokens,
      cacheCreationTokens:
          first.cacheCreationTokens + second.cacheCreationTokens,
      diagnostics: <String, Object?>{
        ...first.diagnostics,
        ...second.diagnostics,
        'thought_only_retry': true,
        if (totalCost > 0) 'actual_cost_usd': totalCost,
      },
    );
  }

  static bool _supportsThinkingBudget(String model) =>
      model.toLowerCase().contains('gemini-2.5');

  static Duration _requestTimeoutForModel(String model) =>
      GeminiCachePolicy.usesImplicitCaching(model)
      ? const Duration(minutes: 20)
      : const Duration(seconds: 180);

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

  static int _estimateTokens(String text) {
    final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    final other = text.length - chinese;
    return (chinese / 1.5 + other / 4).round();
  }
}

class _GeminiCacheEntry {
  final String name;
  final DateTime expiry;
  final int apiKeyFingerprint;
  final String model;
  final String cacheNamespace;
  final String staticHash;
  final String messagePrefixHash;
  final int messagePrefixCount;

  const _GeminiCacheEntry({
    required this.name,
    required this.expiry,
    required this.apiKeyFingerprint,
    required this.model,
    required this.cacheNamespace,
    required this.staticHash,
    required this.messagePrefixHash,
    required this.messagePrefixCount,
  });
}
