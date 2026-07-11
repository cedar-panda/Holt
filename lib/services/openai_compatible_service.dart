import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';
import 'settings/memory_settings.dart';
import 'token_estimator.dart';

/// OpenAI 兼容 API（支持任何中轉站 / 自建端點）
/// 只要遵循 /v1/chat/completions 格式就能用
class OpenAICompatibleService implements ApiAdapter {
  final String apiKey;
  final String baseUrl; // 例：https://api.openai.com/v1
  final String modelPrefixToStrip;

  OpenAICompatibleService({
    required this.apiKey,
    required this.baseUrl,
    this.modelPrefixToStrip = '',
  });

  String get _completionsUrl {
    final url = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    // 如果已經包含完整路徑就直接用，否則補上
    if (url.endsWith('/chat/completions')) return url;
    if (url.endsWith('/v1')) return '$url/chat/completions';
    return '$url/v1/chat/completions';
  }

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async {
    final body = await _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: false,
    );

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(_completionsUrl),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));
    } on SocketException catch (e) {
      throw Exception(_friendlyNetworkError(e));
    } on HttpException catch (e) {
      throw Exception(_friendlyNetworkError(e));
    }

    if (response.statusCode != 200) {
      throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async* {
    final body = await _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: true,
    );

    final request = http.Request('POST', Uri.parse(_completionsUrl));
    request.headers.addAll(_headers());
    request.body = jsonEncode(body);

    final client = http.Client();
    try {
      final http.StreamedResponse response;
      try {
        response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
      } on SocketException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      } on HttpException catch (e) {
        throw Exception(_friendlyNetworkError(e));
      }

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

  Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    if (apiKey.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }
    return headers;
  }

  static String _friendlyNetworkError(dynamic e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('connection refused') || msg.contains('no route')) {
      return '無法連接到 API 服務。請確認：\n'
          '1. 電腦上的 LM Studio / 服務已啟動\n'
          '2. 手機和電腦在同一個 WiFi\n'
          '3. Base URL 用的是電腦局域網 IP（不是 127.0.0.1）';
    }
    if (msg.contains('timed out') || msg.contains('timeout')) {
      return '連接超時。請檢查網路或 API 服務是否正常運行。';
    }
    if (msg.contains('network is unreachable')) {
      return '網路不可用。請確認手機已連接 WiFi。';
    }
    return '網路錯誤：$e';
  }

  String _modelForRequest(String model) {
    if (modelPrefixToStrip.isNotEmpty && model.startsWith(modelPrefixToStrip)) {
      return model.substring(modelPrefixToStrip.length);
    }
    return model;
  }

  Future<Map<String, dynamic>> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) async {
    final enableCache = await MemorySettings.getEnablePromptCaching();
    final allMessages = <Map<String, dynamic>>[];
    // Claude 系模型（經中轉）支持 Anthropic 風格 cache_control 透傳
    final cacheControl = TokenEstimator.promptCacheControl(
      provider: 'openai_compatible',
      model: model,
    );
    final shouldCache = cacheControl != null && enableCache;

    // ═══ system 只放靜態部分，動態移到最新 user ═══
    final staticPrompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
    final profilePrompt = structuredPrompt?.profilePart ?? '';
    final dynamicPrompt = structuredPrompt?.dynamicPart ?? '';
    if (staticPrompt.isNotEmpty) {
      if (shouldCache) {
        allMessages.add({
          'role': 'system',
          'content': <Map<String, dynamic>>[
            {
              'type': 'text',
              'text': staticPrompt,
              'cache_control': Map<String, String>.from(cacheControl),
            },
          ],
        });
      } else {
        allMessages.add({'role': 'system', 'content': staticPrompt});
      }
    }
    if (profilePrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': profilePrompt});
    }

    // 對話歷史
    for (final m in messages) {
      final role = m['role'] ?? 'user';
      final content = m['content'] ?? '';
      final imageUrl = m['image_data_url'];

      if (imageUrl != null && role == 'user') {
        // 多模態
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
      } else if (shouldCache) {
        // Claude 路線 + 開啟 caching：統一 blocks 格式，供滾動斷點使用
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

    // ═══ 滾動 breakpoint（僅 Claude 路線 + 啟用 caching）═══
    final latestUserIndex = CacheBreakpoint.latestUserIndex(allMessages);
    if (shouldCache) {
      CacheBreakpoint.applyRolling(
        allMessages,
        minIndex: staticPrompt.isNotEmpty ? 1 : 0,
        maxIndexExclusive: latestUserIndex >= 0
            ? latestUserIndex
            : allMessages.length,
        cacheControl: cacheControl,
      );
    }

    // ═══ dynamic 注入最新 user（保持前綴穩定）═══
    if (dynamicPrompt.isNotEmpty) {
      if (latestUserIndex >= 0) {
        final existing = allMessages[latestUserIndex]['content'];
        if (existing is List) {
          existing.insert(0, {'type': 'text', 'text': dynamicPrompt});
        } else if (existing is String) {
          allMessages[latestUserIndex] = {
            'role': 'user',
            'content': '$dynamicPrompt\n\n$existing',
          };
        }
      }
    }

    return {
      'model': _modelForRequest(model),
      'messages': allMessages,
      'stream': stream,
    };
  }
}
