import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'cache_debug_log.dart';
import 'settings_manager.dart';
import 'token_estimator.dart';

/// OpenRouter API 實現（含 Anthropic prompt caching）
class OpenRouterService implements ApiAdapter {
  final String apiKey;
  static const String _baseUrl =
      'https://openrouter.ai/api/v1/chat/completions';
  static const String _modelsUrl = 'https://openrouter.ai/api/v1/models';

  /// 最近一次 API 回覆的 caching 統計（用於測試/debug）
  static Map<String, int> lastCacheStats = {};
  static Map<String, Object?> lastCacheDiagnostics = {};

  static void resetCacheStats() {
    lastCacheStats = {};
    lastCacheDiagnostics = {};
  }

  static String get _sessionId {
    final raw = CacheSession.conversationId.isEmpty
        ? 'default'
        : CacheSession.conversationId;
    final normalized = raw.replaceAll(RegExp(r'[^a-zA-Z0-9._:-]'), '_');
    final id = 'yanci_$normalized';
    return id.length <= 256 ? id : id.substring(0, 256);
  }

  OpenRouterService({required this.apiKey});

  Future<Map<String, dynamic>> debugBuildBodyForTesting({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    bool stream = true,
  }) {
    return _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: stream,
    );
  }

  static Future<List<ModelInfo>> fetchModels(String apiKey) async {
    final response = await http
        .get(
          Uri.parse(_modelsUrl),
          headers: {'Authorization': 'Bearer $apiKey'},
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('無法獲取模型列表：${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final models = (data['data'] as List)
        .map((m) {
          final architecture = m['architecture'] as Map<String, dynamic>?;
          return ModelInfo(
            id: m['id'] ?? '',
            name: m['name'] ?? m['id'] ?? '',
            inputModalities: _stringList(architecture?['input_modalities']),
            outputModalities: _stringList(architecture?['output_modalities']),
            supportedParameters: _stringList(m['supported_parameters']),
          );
        })
        .where((m) => m.id.isNotEmpty)
        .toList();

    models.sort((a, b) => a.name.compareTo(b.name));
    return models;
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => '$e').where((e) => e.isNotEmpty).toList();
  }

  /// 判斷是否 Anthropic 模型（支持 prompt caching）
  static bool _isAnthropicModel(String model) {
    final m = model.toLowerCase();
    return m.contains('anthropic') ||
        m.contains('claude') ||
        m.contains('opus') ||
        m.contains('sonnet') ||
        m.contains('haiku') ||
        m.contains('fable') ||
        m.contains('mythos');
  }

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async {
    resetCacheStats();
    final body = _sanitizeRequestBody(
      await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: false,
      ),
    );

    final response = await http
        .post(Uri.parse(_baseUrl), headers: _headers(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 180));

    if (response.statusCode != 200) {
      throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    _extractCacheStats(data);
    return data['choices'][0]['message']['content'] ?? '';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async* {
    resetCacheStats();
    final body = _sanitizeRequestBody(
      await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: true,
      ),
    );

    final request = http.Request('POST', Uri.parse(_baseUrl));
    request.headers.addAll(_headers());
    request.body = jsonEncode(body);

    // client 自己開的自己關（finally），連接超時 30s 防永久轉圈
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        throw Exception('API 錯誤 ${response.statusCode}: $errorBody');
      }

      String buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') return;

            try {
              final json = jsonDecode(data);
              // 提取 cache stats（streaming 時在 usage 裡）
              if (json['usage'] != null) {
                _extractCacheStats(json);
              }
              final delta = json['choices']?[0]?['delta']?['content'];
              if (delta != null && delta.isNotEmpty) {
                yield delta;
              }
            } catch (_) {}
          }
        }
      }
    } finally {
      client.close();
    }
  }

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $apiKey',
    'HTTP-Referer': 'https://project-yanci.app',
    'X-Title': 'Project Yanci',
  };

  Map<String, dynamic> _sanitizeRequestBody(Map<String, dynamic> body) {
    final cleaned = Map<String, dynamic>.from(body)
      ..remove('ignore_unsupported_parameters');

    final provider = cleaned['provider'];
    if (provider is Map) {
      const allowedProviderKeys = {
        'order',
        'allow_fallbacks',
        'require_parameters',
        'data_collection',
        'zdr',
        'enforce_distillable_text',
        'only',
        'ignore',
        'quantizations',
        'sort',
        'preferred_min_throughput',
        'preferred_max_latency',
        'max_price',
      };
      final sanitizedProvider = <String, dynamic>{};
      for (final entry in provider.entries) {
        final key = entry.key.toString();
        if (allowedProviderKeys.contains(key)) {
          sanitizedProvider[key] = entry.value;
        }
      }
      if (sanitizedProvider.isEmpty) {
        cleaned.remove('provider');
      } else {
        cleaned['provider'] = sanitizedProvider;
      }
    }

    return cleaned;
  }

  Future<Map<String, dynamic>> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) async {
    final allMessages = <Map<String, dynamic>>[];

    // ═══ 核心：system prompt 構建 ═══
    final useStructured = structuredPrompt != null && _isAnthropicModel(model);
    final cacheControl = TokenEstimator.promptCacheControl(
      provider: 'openrouter',
      model: model,
    );
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final enableCache = useStructured && cacheEnabled && cacheControl != null;

    if (useStructured) {
      final staticText = structuredPrompt.staticPart;
      final profileText = structuredPrompt.profilePart ?? '';
      if (enableCache) {
        // Anthropic 模型 + cache on：system 只放靜態內容，最後一個
        // static/profile block 掛 cache_control，讓整段 static prefix 可緩存。
        final contentBlocks = <Map<String, dynamic>>[
          if (staticText.isNotEmpty) {'type': 'text', 'text': staticText},
          if (profileText.isNotEmpty) {'type': 'text', 'text': profileText},
        ];
        if (contentBlocks.isNotEmpty) {
          contentBlocks.last['cache_control'] = Map<String, String>.from(
            cacheControl,
          );
          allMessages.add({'role': 'system', 'content': contentBlocks});
        }
      } else {
        // Cache off 時依指南保持 plain string，不送 blocks/cache_control/session_id。
        if (staticText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': staticText});
        }
        if (profileText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': profileText});
        }
      }
    } else {
      // 非 Anthropic 模型 → 普通字串拆分成多個 system message
      final prompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
      if (prompt.isNotEmpty) {
        allMessages.add({'role': 'system', 'content': prompt});
      }
      if (structuredPrompt?.profilePart != null &&
          structuredPrompt!.profilePart!.isNotEmpty) {
        allMessages.add({
          'role': 'system',
          'content': structuredPrompt.profilePart!,
        });
      }
      // dynamic 不放 system——非 Anthropic 模型（DeepSeek/GLM/Gemini/Qwen…）
      // 的上游隱式前綴緩存同樣吃前綴一致性：dynamic 若作為 system 擋在
      // 歷史前面，每輪一變全部歷史 miss。統一走「注入最新 user」（見下）。
    }

    // 加入對話歷史
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      final role = m['role'] ?? 'user';
      final content = m['content'] ?? '';
      final imageUrl = m['image_data_url'];

      // 多模態消息（圖+文）
      if (imageUrl != null && role == 'user') {
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
      } else if (enableCache) {
        // 緩存模式：統一 content blocks 格式
        // 顯式標注 <String, dynamic>：滾動 breakpoint 要往 block 掛
        // cache_control（Map 值），讓 Dart 推斷成 Map<String, String>
        // 會在運行時拋 type error
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

    // ═══ 滾動 breakpoint（共用助手，1h TTL）═══
    final latestUserIndex = CacheBreakpoint.latestUserIndex(allMessages);
    if (enableCache) {
      CacheBreakpoint.applyRolling(
        allMessages,
        minIndex: _firstHistoryIndex(allMessages),
        maxIndexExclusive: latestUserIndex >= 0
            ? latestUserIndex
            : allMessages.length,
        cacheControl: cacheControl,
      );
    }

    // ═══ dynamic 注入最新 user 消息（保持前綴不變；所有模型統一）═══
    if (structuredPrompt != null && structuredPrompt.dynamicPart.isNotEmpty) {
      // 找最後一條 user 消息，把 dynamic 前綴加進去
      if (latestUserIndex >= 0) {
        final existing = allMessages[latestUserIndex]['content'];
        final dynamicPrefix = structuredPrompt.dynamicPart;

        if (existing is List) {
          // content blocks 格式 → 在最前面插入 dynamic block
          existing.insert(0, {'type': 'text', 'text': dynamicPrefix});
        } else if (existing is String) {
          // 純字串格式 → 前綴拼接
          allMessages[latestUserIndex] = {
            'role': 'user',
            'content': '$dynamicPrefix\n\n$existing',
          };
        }
      }
    }

    final rollingBreakpointIndex = _latestNonSystemCacheControlIndex(
      allMessages,
    );
    lastCacheDiagnostics = {
      'provider': 'openrouter',
      'model': model,
      'cache_setting_enabled': cacheEnabled,
      'use_structured': useStructured,
      'enable_cache': enableCache,
      'session_id': enableCache ? _sessionId : null,
      'cache_control': cacheControl,
      'static_tokens': structuredPrompt == null
          ? TokenEstimator.estimate(systemPrompt ?? '')
          : TokenEstimator.estimate(
              [
                structuredPrompt.staticPart,
                if ((structuredPrompt.profilePart ?? '').isNotEmpty)
                  structuredPrompt.profilePart!,
              ].join('\n\n'),
            ),
      'dynamic_tokens': structuredPrompt == null
          ? 0
          : TokenEstimator.estimate(structuredPrompt.dynamicPart),
      'static_hash': structuredPrompt == null
          ? _shortHash(systemPrompt ?? '')
          : _shortHash(
              [
                structuredPrompt.staticPart,
                if ((structuredPrompt.profilePart ?? '').isNotEmpty)
                  structuredPrompt.profilePart!,
              ].join('\n\n'),
            ),
      // 無 structuredPrompt = 命名/摘要等內部工具請求，
      // 不參與 debug 面板的指紋漂移比較（防插隊誤報）
      'is_structured': structuredPrompt != null,
      // 靜態前綴分段指紋：指紋漂移時 diff 出「具體哪段變了」
      'static_segs': structuredPrompt == null
          ? const <String>[]
          : [
              structuredPrompt.staticPart,
              if ((structuredPrompt.profilePart ?? '').isNotEmpty)
                structuredPrompt.profilePart!,
            ]
                .join('\n\n')
                .split('\n\n')
                .where((s) => s.trim().isNotEmpty)
                .map((s) {
                  final head = s.trim().replaceAll('\n', ' ');
                  final label = head.length > 14 ? head.substring(0, 14) : head;
                  return '${_shortHash(s)}|$label';
                })
                .toList(),
      'latest_user_index': latestUserIndex,
      'rolling_breakpoint_index': rollingBreakpointIndex,
      'latest_user_has_cache_control': latestUserIndex >= 0
          ? _contentHasCacheControl(allMessages[latestUserIndex]['content'])
          : false,
    };

    return {
      'model': model,
      'messages': allMessages,
      'stream': stream,
      'max_tokens': 4096,
      // streaming 的 cache stats 需要 final usage chunk；沒有它會看起來
      // 像完全沒命中，實際只是客戶端沒有收到 usage。
      if (stream) 'stream_options': {'include_usage': true},
      // ═══ 緩存優化 ═══
      // session_id 啟用 sticky routing：首次成功請求後固定 provider + 節點，
      // 後續同 session 請求走同一條路，cache namespace 不漂移。
      // ⚠️ 不可同時設 provider.order——OpenRouter 文件明確寫
      //    「Sticky routing is not used when you specify a manual provider order」，
      //    provider.order 會把 sticky routing 整個蓋掉，導致 cache 永遠命不中。
      if (enableCache) 'session_id': _sessionId,
    };
  }

  int _firstHistoryIndex(List<Map<String, dynamic>> messages) {
    var i = 0;
    while (i < messages.length && messages[i]['role'] == 'system') {
      i++;
    }
    return i;
  }

  int _latestNonSystemCacheControlIndex(List<Map<String, dynamic>> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'system') continue;
      if (_contentHasCacheControl(messages[i]['content'])) return i;
    }
    return -1;
  }

  bool _contentHasCacheControl(dynamic content) {
    if (content is! List) return false;
    for (final block in content) {
      if (block is Map && block.containsKey('cache_control')) return true;
    }
    return false;
  }

  String _shortHash(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 12);

  /// 提取 cache 統計
  void _extractCacheStats(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage == null) return;

    // Anthropic 格式
    int read = usage['cache_read_input_tokens'] ?? 0;
    int created = usage['cache_creation_input_tokens'] ?? 0;

    // OpenRouter / Vertex prompt_tokens_details
    // 寫入統計 OpenRouter 常放在 cache_write_tokens（舊代碼只讀
    // cache_creation_input_tokens，「cache created」一直顯示不出來）
    final details = usage['prompt_tokens_details'];
    if (details != null) {
      if (read == 0) read = details['cached_tokens'] ?? 0;
      if (created == 0) created = details['cache_write_tokens'] ?? 0;
    }

    lastCacheStats = {
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
      'cache_creation': created,
      'cache_read': read,
    };

    // 緩存診斷指紋（開發者診斷頁 Cache Debug 讀取）
    CacheDebugLog.add({
      'at': DateTime.now().toIso8601String().substring(11, 19),
      'hash': lastCacheDiagnostics['static_hash'],
      'static_t': lastCacheDiagnostics['static_tokens'],
      'dynamic_t': lastCacheDiagnostics['dynamic_tokens'],
      'prompt_t': lastCacheStats['prompt_tokens'],
      'read': read,
      'write': created,
      'internal': lastCacheDiagnostics['is_structured'] != true,
      'segs': lastCacheDiagnostics['static_segs'] ?? const <String>[],
    });
  }
}

class ModelInfo {
  final String id;
  final String name;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final List<String> supportedParameters;

  ModelInfo({
    required this.id,
    required this.name,
    this.inputModalities = const [],
    this.outputModalities = const [],
    this.supportedParameters = const [],
  });

  bool get supportsImageOutput {
    final outputs = outputModalities.map((m) => m.toLowerCase()).toSet();
    if (outputs.contains('image')) return true;

    final haystack = '$id $name ${supportedParameters.join(' ')}'.toLowerCase();
    return haystack.contains('image') ||
        haystack.contains('img') ||
        haystack.contains('gpt-image') ||
        haystack.contains('flux') ||
        haystack.contains('dall-e') ||
        haystack.contains('stable-diffusion') ||
        haystack.contains('imagen');
  }
}
