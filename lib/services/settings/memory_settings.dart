import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 記憶系統設定（窗口摘要、模型寫入記憶、Token 預算、Prompt Caching）
class MemorySettings {
  // ═══ 摘要 ═══
  static const String _keySummarySource = 'summary_source';
  static const String _keySummaryModel = 'summary_model';
  static const String _keySummarySelection = 'summary_model_selection_v1';
  static const String _keyMemoryMode = 'memory_mode';
  static const String _keyCustomMemoryPrompt = 'custom_memory_prompt';

  static const String defaultSummaryProvider = 'gemini';
  static const String defaultSummaryModel = 'gemini-3-flash';

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
    await p.remove(_keySummarySelection);
  }

  /// 摘要 API 必須把來源和模型當作同一個設定保存，避免同名模型被送到
  /// 當前聊天來源。空值代表「跟隨聊天模型」。
  static Future<void> saveSummarySelection({
    required String provider,
    required String model,
  }) async {
    final normalizedModel = model.trim();
    final normalizedProvider = normalizedModel.isEmpty ? '' : provider.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _keySummarySelection,
      jsonEncode({'provider': normalizedProvider, 'model': normalizedModel}),
    );
    // 保留舊 key，讓降級版本仍能讀到使用者選過的模型。
    await p.setString(_keySummaryModel, normalizedModel);
  }

  static Future<String> getSummaryModel() async {
    final p = await SharedPreferences.getInstance();
    final selection = _decodeSummarySelection(
      p.getString(_keySummarySelection),
    );
    if (selection != null) return selection.model;
    if (p.containsKey(_keySummaryModel)) {
      final legacyModel = (p.getString(_keySummaryModel) ?? '').trim();
      return legacyModel.isEmpty ? defaultSummaryModel : legacyModel;
    }
    return defaultSummaryModel;
  }

  static Future<String> getSummaryProvider() async {
    final p = await SharedPreferences.getInstance();
    final selection = _decodeSummarySelection(
      p.getString(_keySummarySelection),
    );
    if (selection != null) return selection.provider;
    // 舊用戶若已選過模型，來源交給舊的星標映射推斷；只有從未選過的
    // 使用者才套用 Gemini 3 Flash 預設。
    if (p.containsKey(_keySummaryModel) &&
        (p.getString(_keySummaryModel) ?? '').trim().isNotEmpty) {
      return '';
    }
    return defaultSummaryProvider;
  }

  static ({String provider, String model})? _decodeSummarySelection(
    String? raw,
  ) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final provider = decoded['provider'];
      final model = decoded['model'];
      if (provider is! String || model is! String) return null;
      if (model.trim().isEmpty && provider.trim().isNotEmpty) return null;
      return (provider: provider.trim(), model: model.trim());
    } catch (_) {
      return null;
    }
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

  // ═══ 每輪記憶發送條數上限 ═══
  static const String _keyMemorySendLimit = 'memory_send_limit_v1';
  static const int defaultMemorySendLimit = 5;
  static const int maxMemorySendLimit = 500;

  static Future<int> getMemorySendLimit() async {
    final p = await SharedPreferences.getInstance();
    final value = p.getInt(_keyMemorySendLimit) ?? defaultMemorySendLimit;
    return value.clamp(1, maxMemorySendLimit);
  }

  static Future<void> saveMemorySendLimit(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyMemorySendLimit, value.clamp(1, maxMemorySendLimit));
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

  // ═══ 做夢整理（對話累積後自動梳理記憶）═══
  static const String _keyDreamCurationEnabled = 'dream_curation_enabled';
  static const String _keyDreamCurationThreshold = 'dream_curation_threshold';
  static const String _keyDreamCurationLastCount = 'dream_curation_last_count';

  static const int defaultDreamThreshold = 20;
  static const int minDreamThreshold = 5;
  static const int maxDreamThreshold = 100;

  static Future<void> saveDreamCurationEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyDreamCurationEnabled, v);
  }

  static Future<bool> getDreamCurationEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyDreamCurationEnabled) ?? false;
  }

  static Future<void> saveDreamCurationThreshold(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _keyDreamCurationThreshold,
      v.clamp(minDreamThreshold, maxDreamThreshold),
    );
  }

  static Future<int> getDreamCurationThreshold() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_keyDreamCurationThreshold) ?? defaultDreamThreshold;
    return v.clamp(minDreamThreshold, maxDreamThreshold);
  }

  /// 上次做夢整理時的 active 記憶總數。用於判斷是否累積到門檻。
  static Future<void> saveDreamCurationLastCount(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyDreamCurationLastCount, v);
  }

  static Future<int> getDreamCurationLastCount() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyDreamCurationLastCount) ?? 0;
  }

  /// 所有可切換的 ability 模組
  static const abilities = <String, String>{
    'emotion': '情緒座標',
    'bioclock': '生物鐘',
    'imagegen': '畫畫',
  };
}
