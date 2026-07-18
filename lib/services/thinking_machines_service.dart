import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_adapter.dart';
import 'locale_strings.dart';
import 'sse_stream.dart';
import 'stream_transport.dart';

/// Thinking Machines 第一方 Inkling API。
///
/// 使用 Tinker 的 Anthropic-compatible Messages endpoint，而不是共用通用
/// OpenAI-compatible 中轉邏輯，避免丟失 Inkling 的 thinking blocks、圖片格式
/// 與 Anthropic usage 資訊。
class ThinkingMachinesService implements ApiAdapter {
  static const String baseUrl =
      'https://tinker.thinkingmachines.dev/services/tinker-prod/anthropic/api';
  static const String defaultModel = 'thinkingmachines/Inkling';
  static const String _anthropicVersion = '2023-06-01';
  static const int _maxOutputTokens = 4096;

  static Map<String, int> lastUsage = <String, int>{};

  final String apiKey;
  final bool thinkingEnabled;
  final String thinkingEffort;
  final http.Client? _injectedClient;
  http.Client? _activeClient;

  ThinkingMachinesService({
    required this.apiKey,
    this.thinkingEnabled = false,
    this.thinkingEffort = 'high',
    http.Client? client,
  }) : _injectedClient = client;

  static Uri get _messagesUri => Uri.parse('$baseUrl/v1/messages');

  static Uri get _countTokensUri =>
      Uri.parse('$baseUrl/v1/messages/count_tokens');

  static Map<String, String> _headers(String apiKey) => <String, String>{
    'Content-Type': 'application/json',
    'x-api-key': apiKey.trim(),
    'anthropic-version': _anthropicVersion,
  };

  /// 以官方 count_tokens endpoint 驗證 Key、模型與 endpoint 權限。
  /// 不生成內容，因此比發送一條測試聊天更適合設定頁連線測試。
  static Future<int> testConnection({
    required String apiKey,
    String model = defaultModel,
    http.Client? client,
  }) async {
    final ownedClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      final response = await activeClient
          .post(
            _countTokensUri,
            headers: _headers(apiKey),
            body: jsonEncode(<String, dynamic>{
              'model': model.trim().isEmpty ? defaultModel : model.trim(),
              'messages': const <Map<String, String>>[
                <String, String>{'role': 'user', 'content': 'ping'},
              ],
            }),
          )
          .timeout(const Duration(seconds: 20));
      _throwForError(response.statusCode, response.body);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw FormatException(
          L.pick(
            en: 'Invalid Inkling token-count response',
            zhTW: 'Inkling token count 回覆格式無效',
          ),
        );
      }
      final inputTokens = decoded['input_tokens'];
      if (inputTokens is! num) {
        throw FormatException(
          L.pick(
            en: 'Inkling token-count response is missing input_tokens',
            zhTW: 'Inkling token count 缺少 input_tokens',
          ),
        );
      }
      return inputTokens.toInt();
    } finally {
      if (ownedClient) activeClient.close();
    }
  }

  Future<Map<String, dynamic>> debugBuildBodyForTesting({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    bool stream = true,
  }) async {
    return _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: stream,
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
    lastUsage = <String, int>{};
    final ownedClient = _injectedClient == null;
    final client = _injectedClient ?? http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: false,
      );
      final response = await client
          .post(_messagesUri, headers: _headers(apiKey), body: jsonEncode(body))
          .timeout(const Duration(seconds: 180));
      _throwForError(response.statusCode, response.body);

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException(
          L.pick(en: 'Invalid Inkling response', zhTW: 'Inkling 回覆格式無效'),
        );
      }
      final requestUsage = _captureUsage(
        decoded['usage'],
        base: const <String, int>{},
      );
      onUsage?.call(ApiUsage.fromStats(requestUsage));
      return _contentToText(decoded['content']);
    } on SocketException catch (error) {
      throw ThinkingMachinesException(
        L.pick(
          en: 'Could not connect to Thinking Machines: $error',
          zhTW: '無法連接 Thinking Machines：$error',
        ),
      );
    } on HttpException catch (error) {
      throw ThinkingMachinesException(
        L.pick(
          en: 'Thinking Machines network error: $error',
          zhTW: 'Thinking Machines 網路錯誤：$error',
        ),
      );
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      if (ownedClient) client.close();
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
    lastUsage = <String, int>{};
    final ownedClient = _injectedClient == null;
    final client = _injectedClient ?? http.Client();
    _activeClient?.close();
    _activeClient = client;
    try {
      final body = await _buildBody(
        messages,
        model,
        systemPrompt,
        structuredPrompt: structuredPrompt,
        stream: true,
      );
      final request = http.Request('POST', _messagesUri)
        ..headers.addAll(_headers(apiKey))
        ..body = jsonEncode(body);

      final response = await StreamTransport.waitForResponseStart(
        client.send(request),
        provider: 'Thinking Machines',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = await response.stream.bytesToString().timeout(
          SseStream.defaultIdleTimeout,
        );
        _throwForError(response.statusCode, errorBody);
      }

      var activeBlockType = '';
      var thinkingTagOpen = false;
      var requestUsage = <String, int>{};
      final diagnostics = SseStreamDiagnostics();

      await for (final payload in SseStream.data(
        response.stream,
        diagnostics: diagnostics,
      )) {
        if (payload.isEmpty || payload == '[DONE]') continue;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) continue;
          final type = decoded['type']?.toString() ?? '';

          if (type == 'message_start') {
            final message = decoded['message'];
            if (message is Map) {
              requestUsage = _captureUsage(
                message['usage'],
                base: requestUsage,
              );
            }
            continue;
          }
          if (type == 'message_delta') {
            requestUsage = _captureUsage(decoded['usage'], base: requestUsage);
            continue;
          }
          if (type == 'content_block_start') {
            final block = decoded['content_block'];
            activeBlockType = block is Map
                ? block['type']?.toString() ?? ''
                : '';
            if (activeBlockType == 'thinking' && thinkingEnabled) {
              thinkingTagOpen = true;
              yield '<think>';
              final initial = block is Map ? block['thinking'] : null;
              if (initial is String && initial.isNotEmpty) yield initial;
            } else if (activeBlockType == 'text') {
              final initial = block is Map ? block['text'] : null;
              if (initial is String && initial.isNotEmpty) yield initial;
            }
            continue;
          }
          if (type == 'content_block_delta') {
            final delta = decoded['delta'];
            if (delta is! Map) continue;
            final deltaType = delta['type']?.toString() ?? '';
            if (deltaType == 'thinking_delta' && thinkingEnabled) {
              if (!thinkingTagOpen) {
                thinkingTagOpen = true;
                yield '<think>';
              }
              final thinking = delta['thinking'];
              if (thinking is String && thinking.isNotEmpty) yield thinking;
            } else if (deltaType == 'text_delta') {
              if (thinkingTagOpen) {
                thinkingTagOpen = false;
                yield '</think>';
              }
              final text = delta['text'];
              if (text is String && text.isNotEmpty) yield text;
            }
            continue;
          }
          if (type == 'content_block_stop') {
            if (activeBlockType == 'thinking' && thinkingTagOpen) {
              thinkingTagOpen = false;
              yield '</think>';
            }
            activeBlockType = '';
            continue;
          }
          if (type == 'error') {
            final detail = _extractErrorMessage(decoded);
            throw ThinkingMachinesException(
              detail.isEmpty
                  ? L.pick(
                      en: 'Thinking Machines stream returned an error',
                      zhTW: 'Thinking Machines 串流返回錯誤',
                    )
                  : detail,
            );
          }
        } on FormatException {
          // 單一損壞事件不應丟掉整段已完成回覆；UTF-8 損壞另記診斷。
        }
      }

      if (thinkingTagOpen) yield '</think>';
      onUsage?.call(
        ApiUsage.fromStats(
          requestUsage,
          diagnostics: <String, Object?>{
            'malformed_utf8_replacements':
                diagnostics.malformedUtf8Replacements,
          },
        ),
      );
    } on SocketException catch (error) {
      throw ThinkingMachinesException(
        L.pick(
          en: 'Could not connect to Thinking Machines: $error',
          zhTW: '無法連接 Thinking Machines：$error',
        ),
      );
    } on HttpException catch (error) {
      throw ThinkingMachinesException(
        L.pick(
          en: 'Thinking Machines network error: $error',
          zhTW: 'Thinking Machines 網路錯誤：$error',
        ),
      );
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      if (ownedClient) client.close();
    }
  }

  @override
  void cancelActive() {
    final client = _activeClient;
    _activeClient = null;
    client?.close();
  }

  Future<Map<String, dynamic>> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) async {
    final systemParts = <String>[];
    final staticPrompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
    final profilePrompt = structuredPrompt?.profilePart ?? '';
    final dynamicPrompt = structuredPrompt?.dynamicPart ?? '';
    if (staticPrompt.trim().isNotEmpty) systemParts.add(staticPrompt.trim());
    if (profilePrompt.trim().isNotEmpty) systemParts.add(profilePrompt.trim());

    final apiMessages = <Map<String, dynamic>>[];
    for (final message in messages) {
      final role = message['role'] ?? 'user';
      final content = message['content'] ?? '';
      if (role == 'system') {
        if (content.trim().isNotEmpty) systemParts.add(content.trim());
        continue;
      }

      final normalizedRole = role == 'assistant' ? 'assistant' : 'user';
      final imageDataUrl = message['image_data_url'];
      if (normalizedRole == 'user' && imageDataUrl?.isNotEmpty == true) {
        apiMessages.add(<String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            _imageBlock(imageDataUrl!),
            <String, dynamic>{
              'type': 'text',
              'text': content.isEmpty ? '（用戶發送了一張圖片）' : content,
            },
          ],
        });
      } else {
        apiMessages.add(<String, dynamic>{
          'role': normalizedRole,
          'content': content,
        });
      }
    }

    if (dynamicPrompt.trim().isNotEmpty) {
      var latestUser = -1;
      for (var i = apiMessages.length - 1; i >= 0; i--) {
        if (apiMessages[i]['role'] == 'user') {
          latestUser = i;
          break;
        }
      }
      if (latestUser < 0) {
        apiMessages.add(<String, dynamic>{
          'role': 'user',
          'content': dynamicPrompt.trim(),
        });
      } else {
        final existing = apiMessages[latestUser]['content'];
        if (existing is List) {
          existing.insert(0, <String, dynamic>{
            'type': 'text',
            'text': dynamicPrompt.trim(),
          });
        } else {
          apiMessages[latestUser]['content'] =
              '${dynamicPrompt.trim()}\n\n${existing ?? ''}';
        }
      }
    }

    if (apiMessages.isEmpty) {
      apiMessages.add(const <String, dynamic>{
        'role': 'user',
        'content': '（開始對話）',
      });
    }

    return <String, dynamic>{
      'model': model.trim().isEmpty ? defaultModel : model.trim(),
      'max_tokens': _maxOutputTokens,
      'messages': apiMessages,
      'stream': stream,
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      if (thinkingEnabled)
        'output_config': <String, dynamic>{'effort': _normalizedEffort}
      else
        'thinking': const <String, dynamic>{'type': 'disabled'},
    };
  }

  String get _normalizedEffort {
    const supported = <String>{'low', 'medium', 'high', 'xhigh', 'max'};
    final normalized = thinkingEffort.trim().toLowerCase();
    return supported.contains(normalized) ? normalized : 'high';
  }

  static Map<String, dynamic> _imageBlock(String source) {
    final match = RegExp(
      r'^data:([^;]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(source);
    if (match != null) {
      return <String, dynamic>{
        'type': 'image',
        'source': <String, dynamic>{
          'type': 'base64',
          'media_type': match.group(1),
          'data': match.group(2),
        },
      };
    }
    return <String, dynamic>{
      'type': 'image',
      'source': <String, dynamic>{'type': 'url', 'url': source},
    };
  }

  String _contentToText(dynamic rawContent) {
    if (rawContent is! List) return '';
    final thinking = StringBuffer();
    final text = StringBuffer();
    for (final rawBlock in rawContent) {
      if (rawBlock is! Map) continue;
      final type = rawBlock['type']?.toString();
      if (type == 'thinking' && thinkingEnabled) {
        thinking.write(rawBlock['thinking']?.toString() ?? '');
      } else if (type == 'text') {
        text.write(rawBlock['text']?.toString() ?? '');
      }
    }
    if (thinking.isEmpty) return text.toString();
    return '<think>${thinking.toString()}</think>${text.toString()}';
  }

  static Map<String, int> _captureUsage(
    dynamic rawUsage, {
    Map<String, int> base = const <String, int>{},
  }) {
    final next = Map<String, int>.from(base);
    if (rawUsage is! Map) return next;
    final input = rawUsage['input_tokens'];
    final output = rawUsage['output_tokens'];
    if (input is num) next['prompt_tokens'] = input.toInt();
    if (output is num) next['completion_tokens'] = output.toInt();
    lastUsage = Map<String, int>.from(next);
    return next;
  }

  static void _throwForError(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    final detail = _extractErrorMessage(body);
    final prefix = switch (statusCode) {
      400 => L.pick(
        en: 'The Inkling request or model is not supported',
        zhTW: 'Inkling 請求格式或模型不受支援',
      ),
      401 => L.pick(
        en: 'The Thinking Machines API Key is invalid',
        zhTW: 'Thinking Machines API Key 無效',
      ),
      402 => L.pick(
        en: 'This Tinker account has insufficient credits or requires billing setup',
        zhTW: '此 Tinker 帳號額度不足或尚未完成計費設定',
      ),
      403 => L.pick(
        en: 'This Tinker account does not have Inkling compatible-inference access',
        zhTW: '此 Tinker 帳號尚未取得 Inkling 相容推理權限',
      ),
      404 => L.pick(
        en: 'The Inkling API endpoint or model was not found',
        zhTW: 'Inkling API 或模型不存在',
      ),
      429 => L.pick(
        en: 'Thinking Machines is rate-limiting this request or has limited capacity',
        zhTW: 'Thinking Machines 請求過於頻繁或容量受限',
      ),
      >= 500 => L.pick(
        en: 'The Thinking Machines beta service is temporarily unavailable',
        zhTW: 'Thinking Machines beta 服務暫時不可用',
      ),
      _ => L.pick(
        en: 'Thinking Machines API error $statusCode',
        zhTW: 'Thinking Machines API 錯誤 $statusCode',
      ),
    };
    throw ThinkingMachinesException(
      detail.isEmpty
          ? prefix
          : '$prefix${L.locale == 'en' ? ': ' : '：'}$detail',
      statusCode: statusCode,
    );
  }

  static String _extractErrorMessage(dynamic raw) {
    dynamic decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return raw.trim();
      }
    }
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        return error['message']?.toString().trim() ?? error.toString();
      }
      if (error != null) return error.toString().trim();
      final message = decoded['message'];
      if (message != null) return message.toString().trim();
    }
    return '';
  }
}

class ThinkingMachinesException implements Exception {
  final String message;
  final int? statusCode;

  const ThinkingMachinesException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
