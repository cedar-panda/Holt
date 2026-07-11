import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_adapter.dart';

/// 通義千問 API（阿里雲 DashScope，OpenAI 兼容格式）
/// endpoint: compatible-mode/v1
class QwenService implements ApiAdapter {
  final String apiKey;
  static const String _baseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';

  static Map<String, int> lastCacheStats = {};

  QwenService({required this.apiKey});

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async {
    final body = _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: false,
    );

    final response = await http
        .post(Uri.parse(_baseUrl), headers: _headers(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 180));

    if (response.statusCode != 200) {
      throw Exception('Qwen 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    _extractUsage(data);
    return data['choices']?[0]?['message']?['content'] ?? '';
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  }) async* {
    final body = _buildBody(
      messages,
      model,
      systemPrompt,
      structuredPrompt: structuredPrompt,
      stream: true,
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
        final err = await response.stream.bytesToString();
        throw Exception('Qwen 錯誤 ${response.statusCode}: $err');
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
              if (json['usage'] != null) _extractUsage(json);
              final delta = json['choices']?[0]?['delta']?['content'];
              if (delta != null && delta.isNotEmpty) yield delta;
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
  };

  Map<String, dynamic> _buildBody(
    List<Map<String, String>> messages,
    String model,
    String? systemPrompt, {
    StructuredPrompt? structuredPrompt,
    required bool stream,
  }) {
    final allMessages = <Map<String, dynamic>>[];

    // Qwen 隱式前綴緩存（1024 token 起自動）：system 只放靜態，
    // dynamic 注入最新 user——舊版 combined 全拼 system，每輪變
    // 導致整條前綴（含全部歷史）永遠命不中。
    final staticPrompt = structuredPrompt?.staticPart ?? systemPrompt ?? '';
    final profilePrompt = structuredPrompt?.profilePart ?? '';
    final dynamicPrompt = structuredPrompt?.dynamicPart ?? '';
    if (staticPrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': staticPrompt});
    }
    if (profilePrompt.isNotEmpty) {
      allMessages.add({'role': 'system', 'content': profilePrompt});
    }

    for (final m in messages) {
      allMessages.add({
        'role': m['role'] ?? 'user',
        'content': m['content'] ?? '',
      });
    }

    if (dynamicPrompt.isNotEmpty) {
      var injected = false;
      for (int i = allMessages.length - 1; i >= 0; i--) {
        if (allMessages[i]['role'] == 'user') {
          final existing = allMessages[i]['content']?.toString() ?? '';
          allMessages[i] = {
            'role': 'user',
            'content': '$dynamicPrompt\n\n$existing',
          };
          injected = true;
          break;
        }
      }
      if (!injected) {
        allMessages.add({'role': 'user', 'content': dynamicPrompt});
      }
    }

    // model 如果帶前綴就去掉
    final modelId = model.contains('/') ? model.split('/').last : model;

    return {
      'model': modelId.isEmpty ? 'qwen-plus' : modelId,
      'messages': allMessages,
      'stream': stream,
    };
  }

  void _extractUsage(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage == null) return;
    lastCacheStats = {
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
    };
  }
}
