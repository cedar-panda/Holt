import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'api_adapter.dart';
import 'locale_strings.dart';
import 'settings/memory_settings.dart';
import 'sse_stream.dart';
import 'token_estimator.dart';

/// Google Gemini API 直連
/// Context caching 依模型有不同最低 token 門檻
/// 達不到門檻時降級為普通請求
class GeminiService implements ApiAdapter {
  final String apiKey;
  final String modelId;
  http.Client? _activeClient;
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  static String get _dynamicContextHeader =>
      L.pick(en: '[System Dynamic Context]', zhTW: '[系統動態上下文]');

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

  GeminiService({required this.apiKey, this.modelId = 'gemini-2.0-flash'});

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
      return data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
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

      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('Gemini 錯誤 ${response.statusCode}: $err');
      }

      final diagnostics = SseStreamDiagnostics();
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
          final text =
              json['candidates']?[0]?['content']?['parts']?[0]?['text'];
          if (text != null && text.isNotEmpty) yield text;
        } catch (_) {}
      }
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
    // 如果是 OpenRouter 格式 "google/gemini-2.0-flash"
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

    final hashStr = '${prompt.staticPart}\n\n${prompt.profilePart ?? ''}';
    final staticHash = sha256.convert(utf8.encode(hashStr)).toString();
    final estimatedTokens = _estimateTokens(hashStr);
    final minCacheTokens = TokenEstimator.cacheThresholdForModel(
      provider: 'gemini',
      model: model,
    );

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
          'parts': [
            {'text': prompt.staticPart},
            if (prompt.profilePart != null && prompt.profilePart!.isNotEmpty)
              {'text': prompt.profilePart!},
          ],
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

    if (_activeCacheName != null) {
      // 使用緩存，system prompt 在緩存裡
      body['cachedContent'] = _activeCacheName;

      // dynamic 注入「最新」user 消息——插第一條會污染 contents 前綴，
      // 隱式緩存整段歷史每輪 miss；插最新條前綴保持穩定
      if (structuredPrompt != null && structuredPrompt.dynamicPart.isNotEmpty) {
        bool injected = false;
        for (int i = contents.length - 1; i >= 0; i--) {
          if (contents[i]['role'] == 'user') {
            final parts = contents[i]['parts'] as List;
            parts.insert(0, {
              'text':
                  '$_dynamicContextHeader\n${structuredPrompt.dynamicPart}\n---\n',
            });
            injected = true;
            break;
          }
        }
        // fallback：沒有 user 消息時才插入獨立條目
        if (!injected) {
          contents.insert(0, {
            'role': 'user',
            'parts': [
              {
                'text':
                    '$_dynamicContextHeader\n${structuredPrompt.dynamicPart}',
              },
            ],
          });
        }
      }
    } else {
      // 無緩存，正常注入 system instruction
      final parts = <Map<String, String>>[];
      if (structuredPrompt != null) {
        parts.add({'text': structuredPrompt.staticPart});
        if (structuredPrompt.profilePart != null &&
            structuredPrompt.profilePart!.isNotEmpty) {
          parts.add({'text': structuredPrompt.profilePart!});
        }
      } else if (systemPrompt != null && systemPrompt.isNotEmpty) {
        parts.add({'text': systemPrompt});
      }

      if (parts.isNotEmpty) {
        body['systemInstruction'] = {'parts': parts};
      }

      // 同上：注入最新 user，保護 contents 前綴（隱式緩存 2.5+ 自動生效）
      if (structuredPrompt != null && structuredPrompt.dynamicPart.isNotEmpty) {
        bool injected = false;
        for (int i = contents.length - 1; i >= 0; i--) {
          if (contents[i]['role'] == 'user') {
            final userParts = contents[i]['parts'] as List;
            userParts.insert(0, {
              'text':
                  '$_dynamicContextHeader\n${structuredPrompt.dynamicPart}\n---\n',
            });
            injected = true;
            break;
          }
        }
        if (!injected) {
          contents.insert(0, {
            'role': 'user',
            'parts': [
              {
                'text':
                    '$_dynamicContextHeader\n${structuredPrompt.dynamicPart}',
              },
            ],
          });
        }
      }
    }

    body['generationConfig'] = {'maxOutputTokens': 4096};

    return body;
  }

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
