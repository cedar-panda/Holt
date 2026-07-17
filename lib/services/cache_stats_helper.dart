import 'api_adapter.dart';

/// 各 provider 緩存統計的統一讀取（chat_screen / call_screen 共用）
class CacheStatsHelper {
  /// 命中讀取的 token 數（>0 = 命中）
  static int readTokens(ApiUsage usage) => usage.cacheReadTokens;

  /// 新建寫入的 token 數（>0 = 本次建立了緩存）
  static int createdTokens(ApiUsage usage) {
    if (usage.cacheCreationTokens > 0) return usage.cacheCreationTokens;
    if ((usage.raw['cache_miss'] ?? 0) > 0) return usage.raw['cache_miss']!;
    return (usage.raw['cache_status'] ?? -2) == 1 ? 1 : 0;
  }

  /// 簡短顯示文本（null = 無資料）
  static String? shortLabel(ApiUsage usage) {
    final read = readTokens(usage);
    if (read > 0) return '⚡ cache ${_fmt(read)}';
    final created = createdTokens(usage);
    if (created > 0) {
      return created == 1 ? '📦 cache created' : '📦 cache ${_fmt(created)}';
    }
    return null;
  }

  static String _fmt(int t) =>
      t >= 1000 ? '${(t / 1000).toStringAsFixed(1)}k' : '${t}t';
}
