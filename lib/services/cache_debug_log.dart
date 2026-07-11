/// 緩存診斷日誌（內存 ring buffer，不落盤）
///
/// 每輪 OpenRouter 請求記一條指紋，開發者診斷頁「Cache Debug」讀取。
/// 判讀方法：
/// · static_hash 跟上一輪不同 → 靜態前綴漂移（真 bug，找是哪塊變了）
/// · hash 沒變但 read=0、write 全量 → TTL 過期（隔太久）或路由漂移
/// · static_t 為 0 的行 → 摘要壓縮等內部工具請求，不是聊天主請求
class CacheDebugLog {
  static final List<Map<String, Object?>> entries = [];
  static const _cap = 30;

  static void add(Map<String, Object?> entry) {
    entries.insert(0, entry);
    if (entries.length > _cap) entries.removeLast();
  }

  static void clear() => entries.clear();
}
