import 'openai_style_chat_service.dart';

/// 通義千問 API（阿里雲 DashScope，OpenAI 兼容格式）
/// endpoint: compatible-mode/v1
/// 請求／流式流程在 [OpenAiStyleChatService]，這裡只放 Qwen 的差異。
class QwenService extends OpenAiStyleChatService {
  static const String _baseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';

  static Map<String, int> lastCacheStats = {};

  QwenService({required super.apiKey, super.thinkingEnabled});

  @override
  String get providerLabel => 'Qwen';

  @override
  String get debugProviderId => 'qwen';

  @override
  String get chatCompletionsUrl => _baseUrl;

  @override
  String get fallbackModelId => 'qwen-plus';

  @override
  Map<String, int>? extractUsage(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage is! Map) return null;
    final promptDetails = usage['prompt_tokens_details'];
    final stats = <String, int>{
      'prompt_tokens': _intValue(
        usage['prompt_tokens'] ?? usage['input_tokens'],
      ),
      'completion_tokens': _intValue(
        usage['completion_tokens'] ?? usage['output_tokens'],
      ),
      // Model Studio implicit cache reports Chat Completions hits here.
      // Keep Anthropic-compatible aliases as a fallback for relayed models.
      'cache_read': promptDetails is Map
          ? _intValue(promptDetails['cached_tokens'])
          : _intValue(
              usage['cache_read_input_tokens'] ??
                  usage['input_tokens_details']?['cached_tokens'],
            ),
      'cache_creation': _intValue(usage['cache_creation_input_tokens']),
    };
    lastCacheStats = Map<String, int>.from(stats);
    return stats;
  }

  static int _intValue(dynamic value) => value is num ? value.toInt() : 0;
}
