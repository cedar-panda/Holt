import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'api_adapter.dart';
import 'aws_event_stream.dart';
import 'settings/memory_settings.dart';
import 'token_estimator.dart';

/// AWS Bedrock 直連 Claude — 帶 Signature V4 簽名
class BedrockService implements ApiAdapter {
  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String modelId;
  final Duration streamIdleTimeout;

  static const String _service = 'bedrock-runtime';
  static Map<String, int> lastCacheStats = {};

  static void resetCacheStats() {
    lastCacheStats = {};
  }

  BedrockService({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.region = 'us-east-1',
    this.modelId = 'anthropic.claude-sonnet-4-20250514-v1:0',
    this.streamIdleTimeout = BedrockEventStream.defaultIdleTimeout,
  });

  String get _endpoint =>
      'https://$_service.$region.amazonaws.com/model/$modelId/invoke';

  String get _streamEndpoint =>
      'https://$_service.$region.amazonaws.com/model/$modelId/invoke-with-response-stream';

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async {
    resetCacheStats();
    final body = await _buildBody(
      messages,
      systemPrompt,
      structuredPrompt: structuredPrompt,
    );
    final bodyStr = jsonEncode(body);

    final headers = _signRequest(
      method: 'POST',
      uri: '/model/$modelId/invoke',
      body: bodyStr,
    );

    final response = await http
        .post(Uri.parse(_endpoint), headers: headers, body: bodyStr)
        .timeout(const Duration(seconds: 180));

    if (response.statusCode != 200) {
      throw Exception('Bedrock 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    _extractUsage(data);
    return data['content']?[0]?['text'] ?? '';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async* {
    resetCacheStats();
    final body = await _buildBody(
      messages,
      systemPrompt,
      structuredPrompt: structuredPrompt,
    );
    final bodyStr = jsonEncode(body);

    final headers = _signRequest(
      method: 'POST',
      uri: '/model/$modelId/invoke-with-response-stream',
      body: bodyStr,
    );

    final request = http.Request('POST', Uri.parse(_streamEndpoint));
    request.headers.addAll(headers);
    request.body = bodyStr;

    // client 自己開的自己關（finally），連接超時 30s 防永久轉圈
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString().timeout(
          streamIdleTimeout,
        );
        throw Exception('Bedrock 錯誤 ${response.statusCode}: $errorBody');
      }

      // HTTP body 是 binary application/vnd.amazon.eventstream。decoder 會增量
      // 組 frame、驗 prelude/message CRC、解 headers，再取出 chunk.bytes。
      // 任一壞 frame、服務端 exception 或 idle timeout 都會明確終止，不再吞錯。
      await for (final event in BedrockEventStream.decode(
        response.stream,
        idleTimeout: streamIdleTimeout,
      )) {
        _extractUsage(event);
        final message = event['message'];
        if (message is Map) {
          _extractUsage(<String, dynamic>{
            for (final entry in message.entries)
              entry.key.toString(): entry.value,
          });
        }

        if (event['type'] == 'content_block_delta') {
          final delta = event['delta'];
          final text = delta is Map ? delta['text'] : null;
          if (text is String && text.isNotEmpty) yield text;
        }
      }
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _buildBody(
    List<Map<String, String>> messages,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
  }) async {
    final cacheControl = TokenEstimator.promptCacheControl(
      provider: 'bedrock',
      model: modelId,
    );
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final enableCache = cacheEnabled && cacheControl != null;

    // ═══ 歷史統一 blocks 格式（滾動斷點需要）═══
    final allMessages = messages
        .map(
          (m) => <String, dynamic>{
            'role': m['role'],
            'content': <Map<String, dynamic>>[
              {'type': 'text', 'text': m['content'] ?? ''},
            ],
          },
        )
        .toList();

    // ═══ 滾動 breakpoint（按模型能力決定 TTL）— 僅啟用 caching 時 ═══
    final latestUserIndex = CacheBreakpoint.latestUserIndex(allMessages);
    if (enableCache) {
      // Bedrock 的 messages 開頭沒有 system，minIndex = 0
      CacheBreakpoint.applyRolling(
        allMessages,
        minIndex: 0,
        maxIndexExclusive: latestUserIndex >= 0
            ? latestUserIndex
            : allMessages.length,
        cacheControl: cacheControl,
      );
    }

    // ═══ dynamic 注入最新 user ═══
    // 舊版把 dynamic 放在 system 尾部 → system 每輪都變，
    // 後面所有消息的前綴跟著變，歷史永遠緩存不到。
    // 移到最新 user 消息，system 保持純靜態。
    if (structuredPrompt != null && structuredPrompt.dynamicPart.isNotEmpty) {
      if (latestUserIndex >= 0) {
        (allMessages[latestUserIndex]['content'] as List).insert(0, {
          'type': 'text',
          'text': structuredPrompt.dynamicPart,
        });
      }
    }

    final body = <String, dynamic>{
      'anthropic_version': 'bedrock-2023-05-31',
      'max_tokens': 4096,
      'messages': allMessages,
    };

    if (structuredPrompt != null) {
      final systemBlock = <String, dynamic>{
        'type': 'text',
        'text': structuredPrompt.staticPart,
      };
      if (enableCache) {
        systemBlock['cache_control'] = Map<String, String>.from(cacheControl);
      }
      body['system'] = <Map<String, dynamic>>[systemBlock];
    } else if (systemPrompt != null && systemPrompt.isNotEmpty) {
      body['system'] = systemPrompt;
    }

    return body;
  }

  void _extractUsage(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage is! Map) return;

    final next = Map<String, int>.from(lastCacheStats);
    void update(String target, List<String> candidates) {
      for (final key in candidates) {
        final value = usage[key];
        if (value is int) {
          next[target] = value;
          return;
        }
        if (value is num) {
          next[target] = value.toInt();
          return;
        }
      }
    }

    update('prompt_tokens', const ['input_tokens', 'prompt_tokens']);
    update('completion_tokens', const ['output_tokens', 'completion_tokens']);
    update('cache_creation', const ['cache_creation_input_tokens']);
    update('cache_read', const ['cache_read_input_tokens']);
    lastCacheStats = next;
  }

  /// AWS Signature V4 簽名
  Map<String, String> _signRequest({
    required String method,
    required String uri,
    required String body,
  }) {
    final now = DateTime.now().toUtc();
    final dateStamp = _formatDate(now);
    final amzDate = _formatAmzDate(now);
    final host = '$_service.$region.amazonaws.com';

    final canonicalHeaders =
        'content-type:application/json\n'
        'host:$host\n'
        'x-amz-date:$amzDate\n';
    final signedHeaders = 'content-type;host;x-amz-date';

    final payloadHash = _sha256Hash(body);

    final canonicalRequest =
        '$method\n'
        '$uri\n'
        '\n'
        '$canonicalHeaders\n'
        '$signedHeaders\n'
        '$payloadHash';

    final credentialScope = '$dateStamp/$region/$_service/aws4_request';
    final stringToSign =
        'AWS4-HMAC-SHA256\n'
        '$amzDate\n'
        '$credentialScope\n'
        '${_sha256Hash(canonicalRequest)}';

    final signingKey = _getSignatureKey(
      secretAccessKey,
      dateStamp,
      region,
      _service,
    );
    final signature = _hmacSha256Hex(signingKey, stringToSign);

    final authorization =
        'AWS4-HMAC-SHA256 '
        'Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    return {
      'Content-Type': 'application/json',
      'X-Amz-Date': amzDate,
      'Authorization': authorization,
    };
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';

  String _formatAmzDate(DateTime dt) =>
      '${_formatDate(dt)}T${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}${dt.second.toString().padLeft(2, '0')}Z';

  String _sha256Hash(String data) =>
      sha256.convert(utf8.encode(data)).toString();

  Uint8List _hmacSha256(List<int> key, String data) {
    final hmac = Hmac(sha256, key);
    return Uint8List.fromList(hmac.convert(utf8.encode(data)).bytes);
  }

  String _hmacSha256Hex(List<int> key, String data) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode(data)).toString();
  }

  Uint8List _getSignatureKey(
    String key,
    String dateStamp,
    String region,
    String service,
  ) {
    final kDate = _hmacSha256(utf8.encode('AWS4$key'), dateStamp);
    final kRegion = _hmacSha256(kDate, region);
    final kService = _hmacSha256(kRegion, service);
    return _hmacSha256(kService, 'aws4_request');
  }
}
