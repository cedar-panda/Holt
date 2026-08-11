import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'cache_debug_log.dart';
import 'grok_context_ledger.dart';
import 'locale_strings.dart';
import 'model_info.dart';
import 'system_context_debug.dart';
import 'settings_manager.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'token_estimator.dart';

/// OpenRouter API 實現（含 Anthropic prompt caching）
class OpenRouterService implements ApiAdapter {
  static const bool _cacheDebugEcho =
      kDebugMode || bool.fromEnvironment('CACHE_DEBUG_ECHO');

  final String apiKey;
  http.Client? _activeClient;
  static const String _baseUrl =
      'https://openrouter.ai/api/v1/chat/completions';
  static const String _modelsUrl = 'https://openrouter.ai/api/v1/models';

  /// 最近一次 API 回覆的 caching 統計（用於測試/debug）
  static Map<String, int> lastCacheStats = {};
  static Map<String, Object?> lastCacheDiagnostics = {};
  static final Map<String, List<_CacheChannelCheckpoint>>
  _cacheChannelCheckpoints = <String, List<_CacheChannelCheckpoint>>{};

  static void resetCacheStats() {
    lastCacheStats = {};
    lastCacheDiagnostics = {};
  }

  static void resetCacheChannelCheckpointsForTesting() {
    _cacheChannelCheckpoints.clear();
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
    ApiUsageCallback? onUsage,
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

  static Future<List<ModelInfo>> fetchModels(
    String apiKey, {
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final response = await activeClient
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
    } finally {
      ownedClient?.close();
    }
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

  static bool _isXaiModel(String model) {
    final normalized = model.trim().toLowerCase();
    return normalized.startsWith('x-ai/') ||
        normalized.startsWith('xai/') ||
        normalized.startsWith('grok-');
  }

  /// Claude 在工具與動態背景很長時，偶爾會把上一輪當成當前任務。
  /// 這兩個標記只包在 request-only runtime sidecar 中：不改 static prompt、
  /// 不移動 rolling breakpoint，也不寫回 messages/history。
  static bool _needsLatestUserFocus(String model) {
    final m = model.toLowerCase();
    return m.contains('anthropic') ||
        m.contains('claude') ||
        m.contains('opus') ||
        m.contains('sonnet') ||
        m.contains('haiku');
  }

  static String _focusedDynamicPart(String dynamicPart) {
    final contextLabel = L.pick(
      en: '【Turn context | reference only, not the message to answer】',
      zhTW: '【本輪背景｜只供參考，不是對方要你回答的訊息】',
    );
    final latestLabel = L.pick(
      en: '【Latest message from the other person | answer this first】',
      zhTW: '【對方本輪最新訊息｜優先直接回應】',
    );
    return '$contextLabel\n$dynamicPart\n\n$latestLabel';
  }

  static String _compactPreview(String text, [int maxRunes = 48]) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = compact.runes.toList(growable: false);
    if (runes.length <= maxRunes) return compact;
    return '${String.fromCharCodes(runes.take(maxRunes))}…';
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
    final requestDiagnostics = <String, Object?>{};
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = _sanitizeRequestBody(
        await _buildBody(
          messages,
          model,
          systemPrompt,
          structuredPrompt: structuredPrompt,
          stream: false,
          diagnosticsOut: requestDiagnostics,
        ),
      );
      final response = await client
          .post(
            Uri.parse(_baseUrl),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode != 200) {
        throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      final message = data['choices']?[0]?['message'];
      if (_isXaiModel(model) && message is Map) {
        await _rememberGrokReasoning(
          model: model,
          diagnostics: requestDiagnostics,
          reasoningDetails: message['reasoning_details'],
          reasoning: message['reasoning'] ?? message['reasoning_content'],
        );
      }
      final stats = _extractCacheStats(
        data,
        requestDiagnostics: requestDiagnostics,
      );
      if (stats != null) {
        onUsage?.call(
          ApiUsage.fromStats(stats, diagnostics: requestDiagnostics),
        );
      }
      return message is Map ? '${message['content'] ?? ''}' : '';
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
    final requestDiagnostics = <String, Object?>{};
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = _sanitizeRequestBody(
        await _buildBody(
          messages,
          model,
          systemPrompt,
          structuredPrompt: structuredPrompt,
          stream: true,
          diagnosticsOut: requestDiagnostics,
        ),
      );

      final request = http.Request('POST', Uri.parse(_baseUrl));
      request.headers.addAll(_headers());
      request.body = jsonEncode(body);

      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'OpenRouter',
      );

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('API 錯誤 ${response.statusCode}: $errorBody');
      }

      Map<String, dynamic>? finalUsageData;
      final reasoningDetails = <dynamic>[];
      final reasoning = StringBuffer();
      final streamDiagnostics = SseStreamDiagnostics();
      await for (final data in SseStream.data(
        response.stream,
        diagnostics: streamDiagnostics,
      )) {
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data);
          _captureUpstreamDiagnostics(json, requestDiagnostics);
          // usage 通常在最後幾個 chunk 之一。先保留，等 debug
          // echo / router metadata 都收齊後再寫診斷，避免上游 TTL 缺席。
          if (json['usage'] != null) {
            finalUsageData = json;
          }
          final delta = json['choices']?[0]?['delta'];
          if (delta is Map) {
            final details = delta['reasoning_details'];
            if (details is List) reasoningDetails.addAll(details);
            final hidden = delta['reasoning'] ?? delta['reasoning_content'];
            if (hidden is String && hidden.isNotEmpty) reasoning.write(hidden);
            final content = delta['content'];
            if (content is String && content.isNotEmpty) yield content;
          }
        } catch (_) {}
      }
      requestDiagnostics['malformed_utf8_replacements'] =
          streamDiagnostics.malformedUtf8Replacements;
      if (_isXaiModel(model)) {
        await _rememberGrokReasoning(
          model: model,
          diagnostics: requestDiagnostics,
          reasoningDetails: reasoningDetails,
          reasoning: reasoning.toString(),
        );
      }
      lastCacheDiagnostics = Map<String, Object?>.from(requestDiagnostics);
      if (finalUsageData != null) {
        final stats = _extractCacheStats(
          finalUsageData,
          requestDiagnostics: requestDiagnostics,
        );
        if (stats != null) {
          onUsage?.call(
            ApiUsage.fromStats(stats, diagnostics: requestDiagnostics),
          );
        }
      } else {
        onUsage?.call(ApiUsage(diagnostics: requestDiagnostics));
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
    'HTTP-Referer': 'https://project-yanci.app',
    'X-Title': 'Project Yanci',
    // 只回傳路由診斷資料，不改變路由與緩存語義。
    'X-OpenRouter-Metadata': 'enabled',
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
    Map<String, Object?>? diagnosticsOut,
  }) async {
    final allMessages = <Map<String, dynamic>>[];

    // ═══ 核心：system prompt 構建 ═══
    final useStructured = structuredPrompt != null && _isAnthropicModel(model);
    final isGrok = _isXaiModel(model);
    final cacheControl = TokenEstimator.promptCacheControl(
      provider: 'openrouter',
      model: model,
    );
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final enableCache = useStructured && cacheEnabled && cacheControl != null;
    // Grok caching is implicit and has no Anthropic-style write surcharge or
    // cache_control switch. A structured chat always gets its own append-only
    // ledger and sticky route; Claude's explicit-cache path stays untouched.
    final enableGrokCache = isGrok && structuredPrompt != null;
    final anyCacheEnabled = enableCache || enableGrokCache;
    final focusLatestUser =
        structuredPrompt != null &&
        structuredPrompt.liveStatePart.isNotEmpty &&
        _needsLatestUserFocus(model);
    final runtimeDynamicPart = structuredPrompt?.liveStatePart ?? '';
    final sentDynamicPart = structuredPrompt == null
        ? ''
        : (focusLatestUser
              ? _focusedDynamicPart(runtimeDynamicPart)
              : runtimeDynamicPart);
    final stableContext = structuredPrompt == null
        ? (systemPrompt ?? '')
        : structuredPrompt.cacheableParts.join('\n\n');

    if (useStructured) {
      final staticText = structuredPrompt.staticPart;
      final profileText = structuredPrompt.profilePart ?? '';
      final windowText = structuredPrompt.windowPart;
      final controlText = structuredPrompt.resolvedControlPart;
      if (enableCache) {
        // Anthropic 模型 + cache on：system 只放可快取的穩定前綴。
        // turn 會在 rolling breakpoint 設好後作獨立 system message。
        final contentBlocks = <Map<String, dynamic>>[
          if (staticText.isNotEmpty) {'type': 'text', 'text': staticText},
          if (profileText.isNotEmpty) {'type': 'text', 'text': profileText},
          if (windowText.isNotEmpty) {'type': 'text', 'text': windowText},
          if (controlText.isNotEmpty) {'type': 'text', 'text': controlText},
        ];
        if (contentBlocks.isNotEmpty) {
          contentBlocks.last['cache_control'] = Map<String, String>.from(
            cacheControl,
          );
        }
        if (contentBlocks.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': contentBlocks});
        }
      } else {
        // Cache off 仍保持相同 transport contract：穩定部分走 system，
        // runtime 走獨立 sidecar，避免 provider 行為因 cache 開關而改變。
        if (staticText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': staticText});
        }
        if (profileText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': profileText});
        }
        if (windowText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': windowText});
        }
        if (controlText.isNotEmpty) {
          allMessages.add({'role': 'system', 'content': controlText});
        }
      }
    } else {
      // 非 Anthropic 模型 → 普通字串拆分成多個 system message
      final systemParts =
          structuredPrompt?.cacheableParts ?? <String>[systemPrompt ?? ''];
      for (final part in systemParts.where((part) => part.isNotEmpty)) {
        allMessages.add({'role': 'system', 'content': part});
      }
    }

    GrokPreparedHistory? grokPrepared;
    if (enableGrokCache) {
      grokPrepared = await GrokContextLedger.prepareHistory(
        sourceMessages: messages,
        providerRoute: 'openrouter_xai',
        model: model,
        cacheChannel: structuredPrompt.cacheChannel,
        stableContext: stableContext,
        liveState: sentDynamicPart,
      );
      allMessages.addAll(grokPrepared.messages);
    } else {
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
    }

    // ═══ 滾動 breakpoint（共用助手，1h TTL）═══
    final cacheChannel = structuredPrompt?.cacheChannel ?? 'text';
    final historyStartIndex = _firstHistoryIndex(allMessages);
    final checkpointKey = _cacheChannelCheckpointKey(
      model: model,
      channel: cacheChannel,
    );
    final resumeSourceIndices = enableCache
        ? _resumeSourceIndices(checkpointKey, messages)
        : const <int>[];
    for (final sourceIndex in resumeSourceIndices) {
      CacheBreakpoint.applyAt(
        allMessages,
        historyStartIndex + sourceIndex,
        cacheControl: cacheControl,
      );
    }

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
      _rememberCurrentCheckpoint(checkpointKey, messages);
    }

    // 必須在所有 history breakpoint 都落定後才注入，且不得借用 user role。
    // 新 Claude 使用官方 mid-conversation system；舊 Claude 沒有這項能力，
    // 只能退回頂層 system（保穩定 system cache，但歷史段需重建）。
    var runtimeTransport = '';
    var runtimeFallback = '';
    var cachePrefixPreserved = true;
    if (enableGrokCache) {
      runtimeTransport = 'grok_append_only_system_event';
    } else if (_isAnthropicModel(model)) {
      if (RuntimeContextSidecar.supportsClaudeMidConversationSystem(model)) {
        final attached = RuntimeContextSidecar.appendSystemAfterLatestUser(
          allMessages,
          sentDynamicPart,
        );
        if (attached) runtimeTransport = 'claude_mid_system';
      } else {
        final attached =
            RuntimeContextSidecar.appendToPreviousAssistantBeforeLatestUser(
              allMessages,
              sentDynamicPart,
            );
        if (attached) {
          runtimeTransport = enableCache
              ? 'assistant_state_after_cache_breakpoint'
              : 'assistant_state';
        } else if (RuntimeContextSidecar.appendToLeadingSystemMessage(
          allMessages,
          sentDynamicPart,
        )) {
          runtimeTransport = 'top_level_system_fallback';
          runtimeFallback = 'No previous assistant turn was available.';
          cachePrefixPreserved =
              !enableCache || latestUserIndex <= historyStartIndex;
        }
      }
    } else {
      final runtimeRole = model.toLowerCase().contains('openai/')
          ? 'developer'
          : 'system';
      final attached = RuntimeContextSidecar.insertSystemBeforeLatestUser(
        allMessages,
        sentDynamicPart,
        role: runtimeRole,
      );
      if (attached) runtimeTransport = '${runtimeRole}_before_latest_user';
    }

    final rollingBreakpointIndex = _latestNonSystemCacheControlIndex(
      allMessages,
    );
    final sourceRolesTail = messages
        .skip(messages.length > 3 ? messages.length - 3 : 0)
        .map((m) => m['role'] ?? 'user')
        .join(' > ');
    String latestSourceUser = '';
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        latestSourceUser = messages[i]['content'] ?? '';
        break;
      }
    }
    final diagnostics = <String, Object?>{
      'provider': 'openrouter',
      'model': model,
      'cache_setting_enabled': cacheEnabled,
      'use_structured': useStructured,
      'enable_cache': anyCacheEnabled,
      'cache_mode': enableGrokCache
          ? 'xai_implicit_prefix'
          : (enableCache ? 'anthropic_explicit_breakpoint' : 'none'),
      'session_id': enableGrokCache
          ? grokPrepared?.affinityId
          : (enableCache ? _sessionId : null),
      'cache_channel': cacheChannel,
      'channel_resume_indices': resumeSourceIndices,
      'cache_control': cacheControl,
      'runtime_event_count': grokPrepared?.runtimeEventCount ?? 0,
      'runtime_event_reused': grokPrepared?.reusedCurrentRuntime ?? false,
      'reasoning_payload_preserved':
          (grokPrepared?.reasoningPayloadCount ?? 0) > 0,
      'reasoning_payload_count': grokPrepared?.reasoningPayloadCount ?? 0,
      'grok_turn_anchor': grokPrepared?.currentTurnAnchor ?? '',
      'grok_provider_route': enableGrokCache ? 'openrouter_xai' : '',
      'static_tokens': structuredPrompt == null
          ? TokenEstimator.estimate(systemPrompt ?? '')
          : TokenEstimator.estimate(
              structuredPrompt.cacheableParts.join('\n\n'),
            ),
      'dynamic_tokens': structuredPrompt == null
          ? 0
          : TokenEstimator.estimate(sentDynamicPart),
      'dynamic_snapshot_active': false,
      'dynamic_live_hash': structuredPrompt == null
          ? ''
          : _shortHash(structuredPrompt.liveStatePart),
      'dynamic_sent_hash': sentDynamicPart.isEmpty
          ? ''
          : _shortHash(sentDynamicPart),
      'static_hash': structuredPrompt == null
          ? _shortHash(systemPrompt ?? '')
          : _shortHash(structuredPrompt.cacheableParts.join('\n\n')),
      // 無 structuredPrompt = 命名/摘要等內部工具請求，
      // 不參與 debug 面板的指紋漂移比較（防插隊誤報）
      'is_structured': structuredPrompt != null,
      // 靜態前綴分段指紋：指紋漂移時 diff 出「具體哪段變了」
      'static_segs': structuredPrompt == null
          ? const <String>[]
          : structuredPrompt.cacheableParts
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
      'latest_user_focus': focusLatestUser,
      'roles_tail': sourceRolesTail,
      'latest_user_chars': latestSourceUser.runes.length,
      'latest_user_hash': latestSourceUser.isEmpty
          ? ''
          : _shortHash(latestSourceUser),
      'latest_user_preview': _compactPreview(latestSourceUser),
    };
    diagnosticsOut
      ?..clear()
      ..addAll(diagnostics);
    lastCacheDiagnostics = Map<String, Object?>.from(diagnostics);

    final body = <String, dynamic>{
      'model': model,
      'messages': allMessages,
      'stream': stream,
      'max_tokens': 4096,
      // streaming 的 cache stats 需要 final usage chunk；沒有它會看起來
      // 像完全沒命中，實際只是客戶端沒有收到 usage。
      if (stream) 'stream_options': {'include_usage': true},
      // OpenRouter 會在最後一個 debug chunk 回傳轉換後真正送往
      // Anthropic 的 body。僅 debug build 啟用，用來確認 ttl 是否被保留。
      if (stream && _cacheDebugEcho) 'debug': {'echo_upstream_body': true},
      // ═══ 緩存優化 ═══
      // session_id 啟用 sticky routing：首次成功請求後固定 provider + 節點，
      // 後續同 session 請求走同一條路，cache namespace 不漂移。
      // ⚠️ 不可同時設 provider.order——OpenRouter 文件明確寫
      //    「Sticky routing is not used when you specify a manual provider order」，
      //    provider.order 會把 sticky routing 整個蓋掉，導致 cache 永遠命不中。
      if (enableGrokCache) 'session_id': grokPrepared!.affinityId,
      if (!enableGrokCache && enableCache) 'session_id': _sessionId,
      // 不送 top-level automatic cache_control。它會把自動斷點推到最後一個
      // cacheable block，越過上面刻意設在「最新 user 前」的 rolling
      // breakpoint；1h 寫入又是高倍率，會造成每輪大額重寫。
      // static/profile 與 rolling history 已各有明確 block-level 斷點。
    };
    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: 'openrouter',
        model: model,
        cacheChannel: cacheChannel,
        sessionId: enableGrokCache
            ? grokPrepared!.affinityId
            : (enableCache ? _sessionId : CacheSession.conversationId),
        transport: runtimeTransport,
        sourceMessages: messages,
        requestMessages: allMessages,
        stableContext: structuredPrompt.cacheableParts.join('\n\n'),
        liveState: sentDynamicPart,
        cacheEnabled: anyCacheEnabled,
        cachePrefixPreserved: cachePrefixPreserved,
        fallbackReason: runtimeFallback,
        cacheBreakpointIndex: rollingBreakpointIndex,
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }
    return body;
  }

  int _firstHistoryIndex(List<Map<String, dynamic>> messages) {
    var i = 0;
    while (i < messages.length && messages[i]['role'] == 'system') {
      i++;
    }
    return i;
  }

  String _cacheChannelCheckpointKey({
    required String model,
    required String channel,
  }) {
    return '${apiKey.hashCode}|$_sessionId|'
        '${model.trim().toLowerCase()}|${channel.trim()}';
  }

  static List<int> _resumeSourceIndices(
    String key,
    List<Map<String, String>> messages,
  ) {
    final checkpoints = _cacheChannelCheckpoints[key];
    if (checkpoints == null || checkpoints.isEmpty || messages.isEmpty) {
      return const <int>[];
    }

    final resolved = <int>{};
    for (final checkpoint in checkpoints) {
      final direct = checkpoint.sourceIndex;
      if (direct >= 0 &&
          direct < messages.length &&
          checkpoint.matches(messages[direct])) {
        resolved.add(direct);
        continue;
      }
      for (var i = messages.length - 1; i >= 0; i--) {
        if (checkpoint.matches(messages[i])) {
          resolved.add(i);
          break;
        }
      }
    }
    final sorted = resolved.toList()..sort();
    return sorted;
  }

  static void _rememberCurrentCheckpoint(
    String key,
    List<Map<String, String>> messages,
  ) {
    var latestUser = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        latestUser = i;
        break;
      }
    }
    final checkpointIndex = latestUser > 0
        ? latestUser - 1
        : (messages.isNotEmpty ? messages.length - 1 : -1);
    if (checkpointIndex < 0) return;

    final next = _CacheChannelCheckpoint.fromMessage(
      checkpointIndex,
      messages[checkpointIndex],
    );
    final checkpoints = _cacheChannelCheckpoints.putIfAbsent(
      key,
      () => <_CacheChannelCheckpoint>[],
    );
    checkpoints.removeWhere((checkpoint) => checkpoint.sameIdentity(next));
    checkpoints.add(next);
    if (checkpoints.length > 2) {
      checkpoints.removeRange(0, checkpoints.length - 2);
    }
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

  Future<void> _rememberGrokReasoning({
    required String model,
    required Map<String, Object?> diagnostics,
    dynamic reasoningDetails,
    dynamic reasoning,
  }) async {
    final turnAnchor = '${diagnostics['grok_turn_anchor'] ?? ''}';
    if (turnAnchor.isEmpty) return;
    final payload = <String, dynamic>{};
    if (reasoningDetails is List && reasoningDetails.isNotEmpty) {
      payload['reasoning_details'] = reasoningDetails;
    }
    if (reasoning is String && reasoning.isNotEmpty) {
      payload['reasoning'] = reasoning;
    }
    if (payload.isEmpty) return;
    await GrokContextLedger.rememberReasoning(
      providerRoute: 'openrouter_xai',
      model: model,
      cacheChannel: '${diagnostics['cache_channel'] ?? 'text'}',
      turnAnchor: turnAnchor,
      payload: payload,
    );
  }

  /// 提取 cache 統計
  Map<String, int>? _extractCacheStats(
    Map<String, dynamic> data, {
    required Map<String, Object?> requestDiagnostics,
  }) {
    final usage = data['usage'];
    if (usage == null) return null;

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

    final creation = usage['cache_creation'];
    final write5m = creation is Map
        ? (creation['ephemeral_5m_input_tokens'] as num?)?.toInt() ?? 0
        : 0;
    final write1h = creation is Map
        ? (creation['ephemeral_1h_input_tokens'] as num?)?.toInt() ?? 0
        : 0;
    final completionDetails =
        usage['completion_tokens_details'] ?? usage['output_tokens_details'];
    final reasoningTokens = completionDetails is Map
        ? (completionDetails['reasoning_tokens'] as num?)?.toInt() ?? 0
        : 0;

    final stats = <String, int>{
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
      'cache_creation': created,
      'cache_read': read,
      'cache_write_5m': write5m,
      'cache_write_1h': write1h,
      'reasoning_tokens': reasoningTokens,
    };
    final actualCost = usage['cost'];
    if (actualCost is num) {
      requestDiagnostics['actual_cost_usd'] = actualCost.toDouble();
      requestDiagnostics['actual_cost_source'] = 'openrouter_usage';
    }
    requestDiagnostics['cached_tokens'] = read;
    requestDiagnostics['reasoning_tokens'] = stats['reasoning_tokens'];
    lastCacheStats = Map<String, int>.from(stats);

    // 緩存診斷指紋（開發者診斷頁 Cache Debug 讀取）
    CacheDebugLog.add({
      'at': DateTime.now().toIso8601String().substring(11, 19),
      'hash': requestDiagnostics['static_hash'],
      'static_t': requestDiagnostics['static_tokens'],
      'dynamic_t': requestDiagnostics['dynamic_tokens'],
      'prompt_t': stats['prompt_tokens'],
      'read': read,
      'write': created,
      'write_5m': write5m,
      'write_1h': write1h,
      'internal': requestDiagnostics['is_structured'] != true,
      'segs': requestDiagnostics['static_segs'] ?? const <String>[],
      'session_id': requestDiagnostics['session_id'],
      'cache_channel': requestDiagnostics['cache_channel'],
      'channel_resume_indices':
          requestDiagnostics['channel_resume_indices'] ?? const <int>[],
      'model': requestDiagnostics['model'],
      'sent_ttl': (requestDiagnostics['cache_control'] as Map?)?['ttl'],
      'upstream_ttl': requestDiagnostics['upstream_ttl'],
      'upstream_provider': requestDiagnostics['upstream_provider'],
      'upstream_model': requestDiagnostics['upstream_model'],
      'router_attempt': requestDiagnostics['router_attempt'],
      'router_strategy': requestDiagnostics['router_strategy'],
      'router_region': requestDiagnostics['router_region'],
      'router_fallback': requestDiagnostics['router_fallback'],
      'generation_id': data['id'],
      'latest_user_focus': requestDiagnostics['latest_user_focus'],
      'roles_tail': requestDiagnostics['roles_tail'],
      'latest_user_chars': requestDiagnostics['latest_user_chars'],
      'latest_user_hash': requestDiagnostics['latest_user_hash'],
      'latest_user_preview': requestDiagnostics['latest_user_preview'],
      'dynamic_snapshot_active': requestDiagnostics['dynamic_snapshot_active'],
      'dynamic_live_hash': requestDiagnostics['dynamic_live_hash'],
      'dynamic_sent_hash': requestDiagnostics['dynamic_sent_hash'],
      'cache_mode': requestDiagnostics['cache_mode'],
      'runtime_event_count': requestDiagnostics['runtime_event_count'],
      'reasoning_payload_preserved':
          requestDiagnostics['reasoning_payload_preserved'],
      'reasoning_t': requestDiagnostics['reasoning_tokens'],
      'actual_cost': requestDiagnostics['actual_cost_usd'],
    });
    lastCacheDiagnostics = Map<String, Object?>.from(requestDiagnostics);
    return stats;
  }

  void _captureUpstreamDiagnostics(
    Map<String, dynamic> data,
    Map<String, Object?> requestDiagnostics,
  ) {
    final provider = data['provider'];
    if (provider != null) requestDiagnostics['upstream_provider'] = '$provider';

    final metadata = data['openrouter_metadata'];
    if (metadata is Map) {
      requestDiagnostics['router_attempt'] = metadata['attempt'];
      requestDiagnostics['router_strategy'] = metadata['strategy'];
      requestDiagnostics['router_region'] = metadata['region'];
      final attempt = (metadata['attempt'] as num?)?.toInt() ?? 1;
      final attempts = metadata['attempts'];
      requestDiagnostics['router_fallback'] =
          attempt > 1 || (attempts is List && attempts.length > 1);
      final endpoints = metadata['endpoints'];
      if (endpoints is Map && endpoints['available'] is List) {
        for (final endpoint in endpoints['available'] as List) {
          if (endpoint is Map && endpoint['selected'] == true) {
            requestDiagnostics['upstream_provider'] = '${endpoint['provider']}';
            requestDiagnostics['upstream_model'] = '${endpoint['model']}';
            break;
          }
        }
      }
    }

    final debug = data['debug'];
    if (debug is Map) {
      final upstreamBody = debug['echo_upstream_body'];
      final ttl = _findCacheTtl(upstreamBody);
      requestDiagnostics['upstream_ttl'] = ttl ?? 'missing';
    }
  }

  String? _findCacheTtl(dynamic value) {
    if (value is Map) {
      final cacheControl = value['cache_control'];
      if (cacheControl is Map && cacheControl['ttl'] != null) {
        return '${cacheControl['ttl']}';
      }
      for (final child in value.values) {
        final ttl = _findCacheTtl(child);
        if (ttl != null) return ttl;
      }
    } else if (value is List) {
      for (final child in value) {
        final ttl = _findCacheTtl(child);
        if (ttl != null) return ttl;
      }
    }
    return null;
  }
}

class _CacheChannelCheckpoint {
  final int sourceIndex;
  final String role;
  final String content;
  final String imageDataUrl;

  const _CacheChannelCheckpoint({
    required this.sourceIndex,
    required this.role,
    required this.content,
    required this.imageDataUrl,
  });

  factory _CacheChannelCheckpoint.fromMessage(
    int sourceIndex,
    Map<String, String> message,
  ) {
    return _CacheChannelCheckpoint(
      sourceIndex: sourceIndex,
      role: message['role'] ?? 'user',
      content: message['content'] ?? '',
      imageDataUrl: message['image_data_url'] ?? '',
    );
  }

  bool matches(Map<String, String> message) {
    return role == (message['role'] ?? 'user') &&
        content == (message['content'] ?? '') &&
        imageDataUrl == (message['image_data_url'] ?? '');
  }

  bool sameIdentity(_CacheChannelCheckpoint other) {
    return sourceIndex == other.sourceIndex &&
        role == other.role &&
        content == other.content &&
        imageDataUrl == other.imageDataUrl;
  }
}
