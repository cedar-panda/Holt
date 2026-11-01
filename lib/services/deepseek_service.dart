import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model_info.dart';
import 'openai_style_chat_service.dart';

/// DeepSeek API（OpenAI 兼容格式，自動 prompt caching）
/// 不需要手動標記 cache_control，DeepSeek 自動緩存重複前綴
/// 官方快取命中按 64-token 區塊計算，且沒有可由客戶端指定的固定 TTL。
/// 請求／流式流程在 [OpenAiStyleChatService]，這裡只放 DeepSeek 的差異。
class DeepSeekService extends OpenAiStyleChatService {
  static const String _baseUrl = 'https://api.deepseek.com/chat/completions';

  /// 最近一次緩存統計
  static Map<String, int> lastCacheStats = {};

  static void resetCacheStats() {
    lastCacheStats = {};
  }

  DeepSeekService({required super.apiKey, super.thinkingEnabled});

  @override
  String get providerLabel => 'DeepSeek';

  @override
  String get debugProviderId => 'deepseek';

  @override
  String get chatCompletionsUrl => _baseUrl;

  @override
  String get usageCacheReadKey => 'cache_hit';

  @override
  bool get requireStreamTerminal => true;

  @override
  bool get debugCacheEnabled => true;

  @override
  void onRequestStart() => resetCacheStats();

  static Future<List<ModelInfo>> fetchModels(
    String apiKey, {
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final response = await activeClient
          .get(
            Uri.parse('https://api.deepseek.com/models'),
            headers: <String, String>{
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('無法獲取 DeepSeek 模型列表：${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final rawModels = decoded is Map ? decoded['data'] : null;
      if (rawModels is! List) {
        throw const FormatException('DeepSeek 模型列表格式不正確');
      }
      final models = rawModels
          .whereType<Map>()
          .map((raw) {
            final id = raw['id']?.toString().trim() ?? '';
            return ModelInfo(id: id, name: id);
          })
          .where((model) => model.id.isNotEmpty)
          .toList();
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } finally {
      ownedClient?.close();
    }
  }

  @override
  Map<String, int>? extractUsage(Map<String, dynamic> data) {
    final usage = data['usage'];
    if (usage == null) return null;
    final stats = <String, int>{
      'prompt_tokens': usage['prompt_tokens'] ?? 0,
      'completion_tokens': usage['completion_tokens'] ?? 0,
      'cache_hit': usage['prompt_cache_hit_tokens'] ?? 0,
      'cache_miss': usage['prompt_cache_miss_tokens'] ?? 0,
    };
    lastCacheStats = Map<String, int>.from(stats);
    return stats;
  }
}
