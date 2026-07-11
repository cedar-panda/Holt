import 'package:shared_preferences/shared_preferences.dart';

/// 記憶系統設定（窗口摘要、模型寫入記憶、Token 預算、Prompt Caching）
class MemorySettings {
  // ═══ 摘要 ═══
  static const String _keySummarySource = 'summary_source';
  static const String _keySummaryModel = 'summary_model';
  static const String _keyMemoryMode = 'memory_mode';
  static const String _keyCustomMemoryPrompt = 'custom_memory_prompt';

  static Future<void> saveSummarySource(String source) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySummarySource, source);
  }

  static Future<String> getSummarySource() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keySummarySource) ?? 'api';
  }

  static Future<void> saveSummaryModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySummaryModel, v);
  }

  static Future<String> getSummaryModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keySummaryModel) ?? '';
  }

  /// 記憶方案：daily / story / custom
  static Future<void> saveMemoryMode(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyMemoryMode, v);
  }

  static Future<String> getMemoryMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyMemoryMode) ?? 'custom';
  }

  /// 自定義記憶 prompt
  static Future<void> saveCustomMemoryPrompt(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyCustomMemoryPrompt, v);
  }

  static Future<String> getCustomMemoryPrompt() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyCustomMemoryPrompt) ?? '';
  }

  // ═══ Prompt Caching ═══
  static const String _keyEnablePromptCaching = 'enable_prompt_caching';

  static Future<void> saveEnablePromptCaching(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyEnablePromptCaching, v);
  }

  static Future<bool> getEnablePromptCaching() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyEnablePromptCaching) ?? false;
  }

  // ═══ 上下文 Token 限制 ═══
  static const String _keyContextTokenLimit = 'context_token_limit';
  static const String _keyContextLimitEnabled = 'context_limit_enabled';

  static Future<void> saveContextTokenLimit(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyContextTokenLimit, v.clamp(1000, 200000));
  }

  static Future<int> getContextTokenLimit() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_keyContextTokenLimit) ?? 5000;
    return v < 1000 ? 5000 : v;
  }

  static Future<void> saveContextLimitEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyContextLimitEnabled, v);
  }

  static Future<bool> getContextLimitEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyContextLimitEnabled) ?? false;
  }

  // ═══ Token 預算（V2：統一預算）═══
  static const String _keyMemBudgetTotal = 'mem_budget_total';
  static const String _keyMemBudgetMigrated = 'mem_budget_v2_migrated';

  // 舊 key（migration 用）
  static const String _keyMemBudgetPermanent = 'mem_budget_permanent';
  static const String _keyMemBudgetActive = 'mem_budget_active';
  static const String _keyMemBudgetUnfinished = 'mem_budget_unfinished';
  static const String _keyMemBudgetObserving = 'mem_budget_observing';

  /// V2 統一預算：首次讀取時自動 migrate（舊四欄加總，上限 4000）
  static Future<int> getMemBudgetTotal() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_keyMemBudgetMigrated) != true) {
      final old =
          (p.getInt(_keyMemBudgetPermanent) ?? 1000) +
          (p.getInt(_keyMemBudgetActive) ?? 900) +
          (p.getInt(_keyMemBudgetUnfinished) ?? 300) +
          (p.getInt(_keyMemBudgetObserving) ?? 300);
      final migrated = old.clamp(500, 4000);
      await p.setInt(_keyMemBudgetTotal, migrated);
      await p.setBool(_keyMemBudgetMigrated, true);
    }
    return p.getInt(_keyMemBudgetTotal) ?? 1500;
  }

  static Future<void> saveMemBudgetTotal(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyMemBudgetTotal, v);
  }

  // ═══ 蛛網記憶預算 ═══
  static const String _keySpiderWebBudget = 'spider_web_budget_total';

  static Future<int> getSpiderWebBudgetTotal() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keySpiderWebBudget) ?? 1000;
  }

  static Future<void> saveSpiderWebBudgetTotal(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keySpiderWebBudget, v);
  }

  // ═══ 舊方法保留（向後相容，新代碼不再調用）═══
  static Future<int> getMemBudgetPermanent() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyMemBudgetPermanent) ?? 1000;
  }

  static Future<void> saveMemBudgetPermanent(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyMemBudgetPermanent, v);
  }

  static Future<int> getMemBudgetActive() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyMemBudgetActive) ?? 900;
  }

  static Future<int> getMemBudgetUnfinished() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyMemBudgetUnfinished) ?? 300;
  }

  static Future<int> getMemBudgetObserving() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyMemBudgetObserving) ?? 300;
  }

  static Future<bool> getMemEnableActive() async => true;
  static Future<bool> getMemEnableUnfinished() async => true;
  static Future<bool> getMemEnableObserving() async => true;

  // ═══ AI 拆分回覆 ═══
  static const String _keySplitReply = 'split_reply_enabled';

  // ═══ 窗口摘要總開關（舊 key 保留，避免升級後設定丟失）═══
  static const String _keyMemorySummarize = 'memory_summarize_enabled';
  static const String _keyCacheWindowSummary = 'cache_window_summary_enabled';
  static const String _keyContextWindowSummary =
      'context_window_summary_enabled';
  static const String _keyContextWindowSummaryTrigger =
      'context_window_summary_trigger_tokens';
  static const String _keyMemoryWriteEnabled = 'memory_write_enabled';

  static Future<void> saveMemorySummarize(bool v) async {
    await saveWindowSummaryEnabled(v);
  }

  static Future<bool> getMemorySummarize() async {
    return getWindowSummaryEnabled();
  }

  static Future<void> saveWindowSummaryEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyMemorySummarize, v);
    await p.setBool(_keyCacheWindowSummary, v);
  }

  static Future<bool> getWindowSummaryEnabled() async {
    final p = await SharedPreferences.getInstance();
    return (p.getBool(_keyCacheWindowSummary) ??
            p.getBool(_keyMemorySummarize) ??
            false) ||
        (p.getBool(_keyContextWindowSummary) ??
            p.getBool(_keyMemorySummarize) ??
            false);
  }

  static Future<void> saveCacheWindowSummaryEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyCacheWindowSummary, v);
  }

  static Future<bool> getCacheWindowSummaryEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyCacheWindowSummary) ??
        p.getBool(_keyMemorySummarize) ??
        false;
  }

  static Future<void> saveContextWindowSummaryEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyContextWindowSummary, v);
  }

  static Future<bool> getContextWindowSummaryEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyContextWindowSummary) ??
        p.getBool(_keyMemorySummarize) ??
        false;
  }

  static Future<void> saveContextWindowSummaryTriggerTokens(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyContextWindowSummaryTrigger, v.clamp(1000, 30000));
  }

  static Future<int> getContextWindowSummaryTriggerTokens() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyContextWindowSummaryTrigger) ?? 6000;
  }

  /// 模型自主寫入長期記憶開關。默認關閉。
  static Future<void> saveMemoryWriteEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyMemoryWriteEnabled, v);
  }

  static Future<bool> getMemoryWriteEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyMemoryWriteEnabled) ?? false;
  }

  static Future<void> saveSplitReply(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keySplitReply, v);
  }

  static Future<bool> getSplitReply() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keySplitReply) ?? false;
  }

  // ═══ Ability 模組開關 ═══

  static Future<bool> isAbilityEnabled(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool('ability_${key}_enabled') ?? true;
  }

  static Future<void> setAbilityEnabled(String key, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('ability_${key}_enabled', v);
  }

  // ═══ 自動延續命中（保活）═══
  static const String _keyKeepAliveEnabled = 'keepalive_toggle_enabled';
  static const String _keyKeepAliveDurationH = 'keepalive_duration_hours';

  static Future<void> saveKeepAliveEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyKeepAliveEnabled, v);
  }

  static Future<bool> getKeepAliveEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyKeepAliveEnabled) ?? false;
  }

  static Future<void> saveKeepAliveDurationHours(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyKeepAliveDurationH, v.clamp(1, 24));
  }

  static Future<int> getKeepAliveDurationHours() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyKeepAliveDurationH) ?? 2;
  }

  // ═══ 安靜時間（不發 ping 的時段）═══
  static const String _keyQuietStart = 'keepalive_quiet_start';
  static const String _keyQuietEnd = 'keepalive_quiet_end';

  static Future<void> saveQuietStartHour(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyQuietStart, v.clamp(0, 23));
  }

  static Future<int> getQuietStartHour() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyQuietStart) ?? 23;
  }

  static Future<void> saveQuietEndHour(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyQuietEnd, v.clamp(0, 23));
  }

  static Future<int> getQuietEndHour() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyQuietEnd) ?? 7;
  }

  /// 所有可切換的 ability 模組
  static const abilities = <String, String>{
    'emotion': '情緒座標',
    'bioclock': '生物鐘',
    'imagegen': '畫畫',
  };
}
