import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'api_adapter.dart';
import 'cache_debug_log.dart';
import 'grok_context_ledger.dart';
import 'model_info.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';
import 'system_context_debug.dart';
import 'token_estimator.dart';

/// Native xAI Grok Chat Completions adapter.
///
/// Prompt caching is implicit on xAI. No Anthropic `cache_control` is sent;
/// instead a stable `x-grok-conv-id` and append-only hidden context events are
/// used to keep the exact prefix intact across turns.
class XaiService implements ApiAdapter {
  static const String defaultModel = 'grok-4.5';
  static const String _chatUrl = 'https://api.x.ai/v1/chat/completions';
  static const String _modelsUrl = 'https://api.x.ai/v1/language-models';

  static Map<String, int> lastCacheStats = <String, int>{};
  static Map<String, Object?> lastDiagnostics = <String, Object?>{};

  final String apiKey;
  http.Client? _activeClient;

  XaiService({required this.apiKey});

  static void resetDiagnostics() {
    lastCacheStats = <String, int>{};
    lastDiagnostics = <String, Object?>{};
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
            headers: <String, String>{'Authorization': 'Bearer $apiKey'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('無法獲取 xAI 模型列表：${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map ? decoded['models'] : null;
      if (rawModels is! List) return const <ModelInfo>[];
      final models = rawModels
          .whereType<Map>()
          .map((raw) {
            final id = '${raw['id'] ?? ''}'.trim();
            final aliases = raw['aliases'];
            return ModelInfo(
              id: id,
              name: id,
              inputModalities: _stringList(raw['input_modalities']),
              outputModalities: _stringList(raw['output_modalities']),
              supportedParameters: aliases is List
                  ? aliases.map((value) => '$value').toList()
                  : const <String>[],
            );
          })
          .where((model) => model.id.isNotEmpty)
          .toList();
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } finally {
      ownedClient?.close();
    }
  }

  Future<Map<String, dynamic>> debugBuildBodyForTesting({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    bool stream = false,
  }) async {
    final plan = await _buildPlan(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: stream,
    );
    return plan.body;
  }

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    resetDiagnostics();
    final plan = await _buildPlan(
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
            Uri.parse(_chatUrl),
            headers: _headers(plan.affinityId),
            body: jsonEncode(plan.body),
          )
          .timeout(const Duration(seconds: 180));
      if (response.statusCode != 200) {
        throw Exception('xAI 錯誤 ${response.statusCode}: ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final usage = _usage(data, plan.diagnostics);
      onUsage?.call(usage);
      final message = data['choices']?[0]?['message'];
      if (message is Map) {
        await _rememberReasoning(plan, message);
        return '${message['content'] ?? ''}';
      }
      return '';
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
    resetDiagnostics();
    final plan = await _buildPlan(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: true,
    );
    final client = http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final request = http.Request('POST', Uri.parse(_chatUrl));
      request.headers.addAll(_headers(plan.affinityId));
      request.body = jsonEncode(plan.body);
      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'xAI Grok',
      );
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        throw Exception('xAI 錯誤 ${response.statusCode}: $errorBody');
      }

      Map<String, dynamic>? usageData;
      final reasoning = StringBuffer();
      final diagnostics = SseStreamDiagnostics();
      await for (final raw in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (raw == '[DONE]') break;
        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          if (data['usage'] != null) usageData = data;
          final delta = data['choices']?[0]?['delta'];
          if (delta is Map) {
            final hiddenReasoning = delta['reasoning_content'];
            if (hiddenReasoning is String && hiddenReasoning.isNotEmpty) {
              reasoning.write(hiddenReasoning);
            }
            final content = delta['content'];
            if (content is String && content.isNotEmpty) yield content;
          }
        } catch (_) {}
      }

      plan.diagnostics['malformed_utf8_replacements'] =
          diagnostics.malformedUtf8Replacements;
      if (reasoning.isNotEmpty) {
        await GrokContextLedger.rememberReasoning(
          providerRoute: plan.providerRoute,
          model: plan.model,
          cacheChannel: plan.cacheChannel,
          turnAnchor: plan.turnAnchor,
          payload: <String, dynamic>{'reasoning_content': reasoning.toString()},
        );
      }
      if (usageData != null) {
        onUsage?.call(_usage(usageData, plan.diagnostics));
      } else {
        lastDiagnostics = Map<String, Object?>.from(plan.diagnostics);
        onUsage?.call(ApiUsage(diagnostics: plan.diagnostics));
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

  Future<_XaiRequestPlan> _buildPlan(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    required StructuredPrompt? structuredPrompt,
    required bool stream,
  }) async {
    final normalizedModel = _normalizeModel(model);
    final stableParts =
        structuredPrompt?.cacheableParts ?? <String>[systemPrompt ?? ''];
    final stableContext = stableParts
        .where((part) => part.trim().isNotEmpty)
        .join('\n\n');
    final cacheChannel = structuredPrompt?.cacheChannel ?? 'tool';
    const providerRoute = 'xai_native';
    final liveState = structuredPrompt?.requestOnlyPart ?? '';
    final hasEphemeralEvidence =
        structuredPrompt?.ephemeralEvidencePart.isNotEmpty ?? false;

    final allMessages = <Map<String, dynamic>>[
      for (final part in stableParts.where((part) => part.trim().isNotEmpty))
        <String, dynamic>{'role': 'system', 'content': part},
    ];

    GrokPreparedHistory? prepared;
    var runtimeTransport = '';
    if (structuredPrompt != null && !hasEphemeralEvidence) {
      prepared = await GrokContextLedger.prepareHistory(
        sourceMessages: messages,
        providerRoute: providerRoute,
        model: normalizedModel,
        cacheChannel: cacheChannel,
        stableContext: stableContext,
        liveState: liveState,
      );
      allMessages.addAll(prepared.messages);
      runtimeTransport = 'grok_append_only_system_event';
    } else {
      allMessages.addAll(messages.map(_plainApiMessage));
      if (structuredPrompt != null &&
          RuntimeContextSidecar.insertSystemBeforeLatestUser(
            allMessages,
            liveState,
          )) {
        runtimeTransport = 'system_before_latest_user_no_ledger';
      }
    }

    final affinity = prepared?.affinityId ?? '';
    final diagnostics = <String, Object?>{
      'provider': 'xai',
      'model': normalizedModel,
      'cache_mode': prepared == null ? 'none' : 'xai_implicit_prefix',
      'enable_cache': prepared != null,
      'x_grok_conv_id': affinity.isEmpty ? null : affinity,
      'session_id': affinity.isEmpty ? null : affinity,
      'cache_channel': cacheChannel,
      'runtime_event_count': prepared?.runtimeEventCount ?? 0,
      'runtime_event_reused': prepared?.reusedCurrentRuntime ?? false,
      'reasoning_payload_preserved': (prepared?.reasoningPayloadCount ?? 0) > 0,
      'reasoning_payload_count': prepared?.reasoningPayloadCount ?? 0,
      'grok_turn_anchor': prepared?.currentTurnAnchor ?? '',
      'grok_provider_route': providerRoute,
      'static_tokens': TokenEstimator.estimate(stableContext),
      'dynamic_tokens': TokenEstimator.estimate(liveState),
      'static_hash': _shortHash(stableContext),
      'is_structured': structuredPrompt != null,
    };
    lastDiagnostics = Map<String, Object?>.from(diagnostics);

    if (structuredPrompt != null) {
      SystemContextDebug.recordChatRequest(
        provider: 'xai',
        model: normalizedModel,
        cacheChannel: cacheChannel,
        sessionId: affinity,
        transport: runtimeTransport,
        sourceMessages: messages,
        requestMessages: allMessages,
        stableContext: stableContext,
        liveState: structuredPrompt.liveStatePart,
        cacheEnabled: prepared != null,
        cachePrefixPreserved: prepared != null || liveState.trim().isEmpty,
        expectTime: structuredPrompt.liveStatePart.trim().isNotEmpty,
      );
    }

    return _XaiRequestPlan(
      body: <String, dynamic>{
        'model': normalizedModel,
        'messages': allMessages,
        'stream': stream,
        'max_tokens': 4096,
        if (stream) 'stream_options': <String, dynamic>{'include_usage': true},
      },
      affinityId: affinity,
      providerRoute: providerRoute,
      model: normalizedModel,
      cacheChannel: cacheChannel,
      turnAnchor: prepared?.currentTurnAnchor ?? '',
      diagnostics: diagnostics,
    );
  }

  Future<void> _rememberReasoning(_XaiRequestPlan plan, Map message) async {
    final content = message['reasoning_content'];
    if (content == null || '$content'.isEmpty) return;
    await GrokContextLedger.rememberReasoning(
      providerRoute: plan.providerRoute,
      model: plan.model,
      cacheChannel: plan.cacheChannel,
      turnAnchor: plan.turnAnchor,
      payload: <String, dynamic>{'reasoning_content': content},
    );
  }

  ApiUsage _usage(Map<String, dynamic> data, Map<String, Object?> diagnostics) {
    final rawUsage = data['usage'];
    final usage = rawUsage is Map ? rawUsage : const <String, dynamic>{};
    final promptDetails = usage['prompt_tokens_details'];
    final outputDetails =
        usage['completion_tokens_details'] ?? usage['output_tokens_details'];
    final cached = promptDetails is Map
        ? _intValue(promptDetails['cached_tokens'])
        : 0;
    final reasoning = outputDetails is Map
        ? _intValue(outputDetails['reasoning_tokens'])
        : 0;
    final ticks = _intValue(
      usage['cost_in_usd_ticks'] ?? data['cost_in_usd_ticks'],
    );
    if (ticks > 0) {
      diagnostics['native_cost_ticks'] = ticks;
      diagnostics['actual_cost_usd'] = ticks / 10000000000;
      diagnostics['actual_cost_source'] = 'xai_cost_in_usd_ticks';
    }
    diagnostics['reasoning_tokens'] = reasoning;
    diagnostics['cached_tokens'] = cached;
    final stats = <String, int>{
      'prompt_tokens': _intValue(
        usage['prompt_tokens'] ?? usage['input_tokens'],
      ),
      'completion_tokens': _intValue(
        usage['completion_tokens'] ?? usage['output_tokens'],
      ),
      'cache_read': cached,
      'cache_creation': 0,
      'reasoning_tokens': reasoning,
      'native_cost_ticks': ticks,
    };
    lastCacheStats = Map<String, int>.from(stats);
    lastDiagnostics = Map<String, Object?>.from(diagnostics);
    CacheDebugLog.add(<String, dynamic>{
      'at': DateTime.now().toIso8601String().substring(11, 19),
      'model': diagnostics['model'],
      'hash': diagnostics['static_hash'],
      'static_t': diagnostics['static_tokens'],
      'dynamic_t': diagnostics['dynamic_tokens'],
      'internal': diagnostics['is_structured'] != true,
      'session_id': diagnostics['session_id'],
      'cache_channel': diagnostics['cache_channel'],
      'cache_mode': diagnostics['cache_mode'],
      'prompt_t': stats['prompt_tokens'],
      'read': cached,
      'write': 0,
      'reasoning_t': reasoning,
      'runtime_event_count': diagnostics['runtime_event_count'],
      'reasoning_payload_preserved': diagnostics['reasoning_payload_preserved'],
      'actual_cost': diagnostics['actual_cost_usd'],
    });
    return ApiUsage.fromStats(stats, diagnostics: diagnostics);
  }

  Map<String, String> _headers(String affinityId) => <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $apiKey',
    if (affinityId.isNotEmpty) 'x-grok-conv-id': affinityId,
  };

  static Map<String, dynamic> _plainApiMessage(Map<String, String> source) {
    final role = source['role'] ?? 'user';
    final content = source['content'] ?? '';
    final image = source['image_data_url'];
    if (role == 'user' && image != null && image.isNotEmpty) {
      return <String, dynamic>{
        'role': role,
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'image_url',
            'image_url': <String, dynamic>{'url': image},
          },
          <String, dynamic>{'type': 'text', 'text': content},
        ],
      };
    }
    return <String, dynamic>{'role': role, 'content': content};
  }

  static String _normalizeModel(String model) {
    final trimmed = model.trim();
    return trimmed.toLowerCase().startsWith('x-ai/')
        ? trimmed.substring(5)
        : trimmed;
  }

  static List<String> _stringList(dynamic raw) => raw is List
      ? raw.map((value) => '$value').where((value) => value.isNotEmpty).toList()
      : const <String>[];

  static int _intValue(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static String _shortHash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 12);
}

class _XaiRequestPlan {
  final Map<String, dynamic> body;
  final String affinityId;
  final String providerRoute;
  final String model;
  final String cacheChannel;
  final String turnAnchor;
  final Map<String, Object?> diagnostics;

  const _XaiRequestPlan({
    required this.body,
    required this.affinityId,
    required this.providerRoute,
    required this.model,
    required this.cacheChannel,
    required this.turnAnchor,
    required this.diagnostics,
  });
}
