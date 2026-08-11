import 'package:flutter/foundation.dart' show kDebugMode;

const bool _developerDiagnosticsEnabled = bool.fromEnvironment(
  'HOLT_ENABLE_DEVELOPER_DIAGNOSTICS',
  defaultValue: kDebugMode,
);

/// 緩存診斷日誌（內存 ring buffer，不落盤）
///
/// 每輪 OpenRouter 請求記一條指紋，開發者診斷頁「Cache Debug」讀取。
/// 判讀方法：
/// · 同 session + model + channel 的 static_hash 跟上一輪不同 → 靜態前綴漂移
/// · hash 沒變但 read=0、write 全量 → TTL 過期（隔太久）或路由漂移
/// · static_t 為 0 的行 → 摘要壓縮等內部工具請求，不是聊天主請求
class CacheDebugLog {
  static final List<Map<String, Object?>> entries = [];
  static final Map<String, int> _contextStallCounts = {};
  static const _cap = 30;

  static void add(Map<String, Object?> entry) {
    if (!_developerDiagnosticsEnabled) return;
    final enriched = Map<String, Object?>.from(entry);
    final isMainRequest = enriched['internal'] != true;
    final sessionId = (enriched['session_id'] ?? '').toString();
    final model = (enriched['model'] ?? '').toString();
    final channel = (enriched['cache_channel'] ?? 'text').toString();
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
      final key = '$sessionId|$model|$channel';
      final nextCount = looksStalled ? (_contextStallCounts[key] ?? 0) + 1 : 0;
      _contextStallCounts[key] = nextCount;
      enriched['context_stall_count'] = nextCount;
      enriched['context_cache_stalled'] = nextCount >= 3;
      enriched['stable_prefix_t'] = stablePrefixTokens;
    }

    entries.insert(0, enriched);
    if (entries.length > _cap) entries.removeLast();
  }

  /// 找出同一 cache namespace 的上一筆主請求。
  ///
  /// entries[0] 是最新；不同聊天窗口或不同模型的 hash 本來就應該不同，
  /// 不能互相比較。內部命名／摘要請求也不屬於主聊天 cache。
  static Map<String, Object?>? previousComparableMain(int currentIndex) {
    if (currentIndex < 0 || currentIndex >= entries.length) return null;
    final current = entries[currentIndex];
    if (current['internal'] == true) return null;

    final sessionId = (current['session_id'] ?? '').toString();
    final model = (current['model'] ?? '').toString();
    final channel = (current['cache_channel'] ?? 'text').toString();
    if (sessionId.isEmpty || model.isEmpty) return null;

    for (var i = currentIndex + 1; i < entries.length; i++) {
      final candidate = entries[i];
      if (candidate['internal'] == true) continue;
      if ((candidate['session_id'] ?? '').toString() != sessionId) continue;
      if ((candidate['model'] ?? '').toString() != model) continue;
      if ((candidate['cache_channel'] ?? 'text').toString() != channel) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  static void clear() {
    entries.clear();
    _contextStallCounts.clear();
  }
}
