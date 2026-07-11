import 'openrouter_service.dart';
import 'deepseek_service.dart';
import 'gemini_service.dart';
import 'aws_bedrock_service.dart';

/// 各 provider 緩存統計的統一讀取（chat_screen / call_screen 共用）
class CacheStatsHelper {
  /// 命中讀取的 token 數（>0 = 命中）
  static int readTokens(String provider) {
    switch (provider) {
      case 'openrouter':
        return OpenRouterService.lastCacheStats['cache_read'] ?? 0;
      case 'deepseek':
        return DeepSeekService.lastCacheStats['cache_hit'] ?? 0;
      case 'gemini':
        return GeminiService.lastCacheStats['cached_tokens'] ?? 0;
      case 'bedrock':
        return BedrockService.lastCacheStats['cache_read'] ?? 0;
      default:
        return 0;
    }
  }

  /// 新建寫入的 token 數（>0 = 本次建立了緩存）
  static int createdTokens(String provider) {
    switch (provider) {
      case 'openrouter':
        return OpenRouterService.lastCacheStats['cache_creation'] ?? 0;
      case 'deepseek':
        return DeepSeekService.lastCacheStats['cache_miss'] ?? 0;
      case 'bedrock':
        return BedrockService.lastCacheStats['cache_creation'] ?? 0;
      case 'gemini':
        return (GeminiService.lastCacheStats['cache_status'] ?? -2) == 1
            ? 1
            : 0;
      default:
        return 0;
    }
  }

  /// 簡短顯示文本（null = 無資料）
  static String? shortLabel(String provider) {
    final read = readTokens(provider);
    if (read > 0) return '⚡ cache ${_fmt(read)}';
    final created = createdTokens(provider);
    if (created > 0) {
      return created == 1 ? '📦 cache created' : '📦 cache ${_fmt(created)}';
    }
    return null;
  }

  static String _fmt(int t) =>
      t >= 1000 ? '${(t / 1000).toStringAsFixed(1)}k' : '${t}t';
}
