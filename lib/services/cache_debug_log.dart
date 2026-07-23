/// 緩存診斷日誌（內存 ring buffer，不落盤）
///
/// 每輪 OpenRouter 請求記一條指紋，開發者診斷頁「Cache Debug」讀取。
/// 判讀方法：
/// · static_hash 跟上一輪不同 → 靜態前綴漂移（真 bug，找是哪塊變了）
/// · hash 沒變但 read=0、write 全量 → TTL 過期（隔太久）或路由漂移
/// · static_t 為 0 的行 → 摘要壓縮等內部工具請求，不是聊天主請求
class CacheDebugLog {
  static final List<Map<String, Object?>> entries = [];
  static final Map<String, int> _contextStallCounts = {};
  static const _cap = 30;

  static void add(Map<String, Object?> entry) {
    final enriched = Map<String, Object?>.from(entry);
    final isMainRequest = enriched['internal'] != true;
    final sessionId = (enriched['session_id'] ?? '').toString();
    final model = (enriched['model'] ?? '').toString();
    if (isMainRequest && sessionId.isNotEmpty && model.isNotEmpty) {
      final staticTokens = enriched['static_t'] as int? ?? 0;
      final dynamicTokens = enriched['dynamic_t'] as int? ?? 0;
      final promptTokens = enriched['prompt_t'] as int? ?? 0;
      final readTokens = enriched['read'] as int? ?? 0;
      final stablePrefixTokens = staticTokens + dynamicTokens;
      final historyBeyondPrefix = promptTokens - stablePrefixTokens;
      final tolerance = (stablePrefixTokens * 0.1).round().clamp(256, 768);
      final looksStalled =
          historyBeyondPrefix >= 1024 &&
          readTokens <= stablePrefixTokens + tolerance;
      final key = '$sessionId|$model';
      final nextCount = looksStalled ? (_contextStallCounts[key] ?? 0) + 1 : 0;
      _contextStallCounts[key] = nextCount;
      enriched['context_stall_count'] = nextCount;
      enriched['context_cache_stalled'] = nextCount >= 3;
      enriched['stable_prefix_t'] = stablePrefixTokens;
    }

    entries.insert(0, enriched);
    if (entries.length > _cap) entries.removeLast();
  }

  static void clear() {
    entries.clear();
    _contextStallCounts.clear();
  }
}
