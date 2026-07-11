import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'api_adapter.dart';
import 'locale_strings.dart';
import 'settings/memory_settings.dart';
import 'token_estimator.dart';

/// Google Gemini API 直連
/// Context caching 依模型有不同最低 token 門檻
/// 達不到門檻時降級為普通請求
class GeminiService implements ApiAdapter {
  final String apiKey;
  final String modelId;
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
  }) async {
    resetCacheStats();
    final m = model.isNotEmpty ? _extractModel(model) : modelId;

    // 嘗試 context caching
    await _ensureCache(structuredPrompt, m);

    final body = _buildBody(
      messages,
      systemPrompt,
      structuredPrompt: structuredPrompt,
    );

    final url = '$_baseUrl/models/$m:generateContent?key=$apiKey';
    final response = await http
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
    _extractUsage(data);
    return data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async* {
    resetCacheStats();
    final m = model.isNotEmpty ? _extractModel(model) : modelId;

    await _ensureCache(structuredPrompt, m);

    final body = _buildBody(
      messages,
      systemPrompt,
      structuredPrompt: structuredPrompt,
    );

    final url = '$_baseUrl/models/$m:streamGenerateContent?alt=sse&key=$apiKey';

    final request = http.Request('POST', Uri.parse(url));
    request.headers.addAll({'Content-Type': 'application/json'});
    request.body = jsonEncode(body);

    // client 自己開的自己關（finally），連接超時 30s 防永久轉圈
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString();
        throw Exception('Gemini 錯誤 ${response.statusCode}: $err');
      }

      String buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data.isEmpty) continue;

            try {
              final json = jsonDecode(data);
              if (json['usageMetadata'] != null) _extractUsage(json);
              final text =
                  json['candidates']?[0]?['content']?['parts']?[0]?['text'];
              if (text != null && text.isNotEmpty) yield text;
            } catch (_) {}
          }
        }
      }
    } finally {
      client.close();
    }
  }

  String _extractModel(String model) {
    // 如果是 OpenRouter 格式 "google/gemini-2.0-flash"
    if (model.contains('/')) return model.split('/').last;
    return model;
  }

  // ═══════════════════════════════════
  // Context Caching
  // ═══════════════════════════════════

  Future<void> _ensureCache(StructuredPrompt? prompt, String model) async {
    if (prompt == null) return;
    if (!await MemorySettings.getEnablePromptCaching()) {
      _activeCacheName = null;
      _cachedStaticHash = null;
      _cacheExpiry = null;
      return;
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
      lastCacheStats['cache_status'] = 0; // 0 = 門檻不到
      lastCacheStats['cache_threshold'] = minCacheTokens;
      return;
    }

    final now = DateTime.now();
    if (_activeCacheName != null &&
        _cachedStaticHash == staticHash &&
        _cacheExpiry != null &&
        now.isBefore(_cacheExpiry!)) {
      lastCacheStats['cache_status'] = 2; // 2 = 命中
      lastCacheStats['cache_threshold'] = minCacheTokens;
      return;
    }

    final cacheKey = '${apiKey.hashCode}:$model:$staticHash';
    _cacheEntries.removeWhere((_, entry) => !now.isBefore(entry.expiry));

    final cached = _cacheEntries[cacheKey];
    if (cached != null) {
      _activeCacheName = cached.name;
      _cachedStaticHash = staticHash;
      _cacheExpiry = cached.expiry;
      lastCacheStats['cache_status'] = 2; // 2 = 命中
      lastCacheStats['cache_threshold'] = minCacheTokens;
      return;
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

      final response = await http.post(
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
        lastCacheStats['cache_status'] = 1; // 1 = 新建
        lastCacheStats['cache_threshold'] = minCacheTokens;
      } else {
        // 緩存建立失敗，降級為普通請求
        _activeCacheName = null;
        lastCacheStats['cache_status'] = -1; // -1 = 失敗
        lastCacheStats['cache_threshold'] = minCacheTokens;
      }
    } catch (_) {
      _activeCacheName = null;
      _cachedStaticHash = null;
      _cacheExpiry = null;
      lastCacheStats['cache_status'] = -1;
      lastCacheStats['cache_threshold'] = minCacheTokens;
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

  void _extractUsage(Map<String, dynamic> data) {
    final usage = data['usageMetadata'];
    if (usage == null) return;
    lastCacheStats = {
      ...lastCacheStats,
      'prompt_tokens': usage['promptTokenCount'] ?? 0,
      'completion_tokens': usage['candidatesTokenCount'] ?? 0,
      'cached_tokens': usage['cachedContentTokenCount'] ?? 0,
    };
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
