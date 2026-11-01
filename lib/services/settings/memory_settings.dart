import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 記憶系統設定（窗口摘要、模型寫入記憶、Token 預算、Prompt Caching）
class MemorySettings {
  // ═══ 摘要 ═══
  static const String _keySummarySource = 'summary_source';
  static const String _keySummaryModel = 'summary_model';
  static const String _keySummarySelection = 'summary_model_selection_v1';
  static const String _keyEmbeddingSelection =
      'memory_embedding_model_selection_v1';
  static const String _keyMemoryMode = 'memory_mode';
  static const String _keyCustomMemoryPrompt = 'custom_memory_prompt';
  static const String _keyRpSummaryMaxChars = 'rp_summary_max_chars_v1';
  static const String _keyRpSummaryAutoMaxChars =
      'rp_summary_auto_max_chars_v1';
  static const String _keyRpDynamicSummarySegments =
      'rp_dynamic_summary_segments_v1';
  static const String _keyRpDynamicSummaryMaxChars =
      'rp_dynamic_summary_max_chars_v1';
  static const String _keyRpContinuationSummaryMaxChars =
      'rp_continuation_summary_max_chars_v1';
  static const String _keyDailySummaryCustomRules =
      'daily_summary_custom_rules_v1';
  static const String _keyRpSummaryCustomRules = 'rp_summary_custom_rules_v1';
  static const String _keyRpWorldbookAutoWrite = 'rp_worldbook_auto_write_v1';
  static const String _keyRpWorldbookSummaryInterval =
      'rp_worldbook_summary_interval_v1';

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

  /// 空模型代表不啟用向量召回；來源與模型綁定儲存，
  /// 避免同名 embedding 模型被送到錯誤的 API。
  static Future<void> saveEmbeddingSelection({
    required String provider,
    required String model,
  }) async {
    final normalizedModel = model.trim();
    final normalizedProvider = normalizedModel.isEmpty ? '' : provider.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _keyEmbeddingSelection,
      jsonEncode({'provider': normalizedProvider, 'model': normalizedModel}),
    );
  }

  static Future<({String provider, String model})>
  getEmbeddingSelection() async {
    final p = await SharedPreferences.getInstance();
    final selection = _decodeSummarySelection(
      p.getString(_keyEmbeddingSelection),
    );
    return selection ?? (provider: '', model: '');
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

  static Future<void> saveRpSummaryMaxChars(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRpSummaryMaxChars, value.clamp(800, 4000));
  }

  static Future<int> getRpSummaryMaxChars() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyRpSummaryMaxChars) ?? 1600).clamp(800, 4000);
  }

  static Future<void> saveRpSummaryAutoMaxCharsEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyRpSummaryAutoMaxChars, value);
  }

  static Future<bool> getRpSummaryAutoMaxCharsEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyRpSummaryAutoMaxChars) ?? true;
  }

  static Future<void> saveRpDynamicSummarySegments(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRpDynamicSummarySegments, value.clamp(1, 4));
  }

  static Future<int> getRpDynamicSummarySegments() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyRpDynamicSummarySegments) ?? 1).clamp(1, 4);
  }

  static Future<void> saveRpDynamicSummaryMaxChars(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRpDynamicSummaryMaxChars, value.clamp(600, 4000));
  }

  static Future<int> getRpDynamicSummaryMaxChars() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyRpDynamicSummaryMaxChars) ?? 1400).clamp(600, 4000);
  }

  static Future<void> saveRpContinuationSummaryMaxChars(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRpContinuationSummaryMaxChars, value.clamp(1000, 6000));
  }

  static Future<int> getRpContinuationSummaryMaxChars() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyRpContinuationSummaryMaxChars) ?? 2400).clamp(
      1000,
      6000,
    );
  }

  static Future<void> saveSummaryCustomRules({
    required String contextMode,
    required String value,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      contextMode == 'rp'
          ? _keyRpSummaryCustomRules
          : _keyDailySummaryCustomRules,
      value.trim(),
    );
  }

  static Future<String> getSummaryCustomRules({
    required String contextMode,
  }) async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(
              contextMode == 'rp'
                  ? _keyRpSummaryCustomRules
                  : _keyDailySummaryCustomRules,
            ) ??
            '')
        .trim();
  }

  static Future<void> saveRpWorldbookAutoWriteEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyRpWorldbookAutoWrite, value);
  }

  static Future<bool> getRpWorldbookAutoWriteEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyRpWorldbookAutoWrite) ?? true;
  }

  static Future<void> saveRpWorldbookSummaryInterval(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRpWorldbookSummaryInterval, value.clamp(1, 20));
  }

  static Future<int> getRpWorldbookSummaryInterval() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyRpWorldbookSummaryInterval) ?? 4).clamp(1, 20);
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

  // ═══ 上下文發送限制（現行 UI 以消息條數控制）═══
  // 舊 Token 欄位保留供既有資料與相容路徑讀取；側邊欄只寫入條數欄位。
  static const String _keyContextTokenLimit = 'context_token_limit';
  static const String _keyContextLimitEnabled = 'context_limit_enabled';
  static const String _keyContextMessageLimit = 'context_message_limit_v1';
  static const String _keyContextSummaryTriggerMessages =
      'context_summary_trigger_messages_v1';
  static const String _keyCacheSummaryTriggerMessages =
      'cache_summary_trigger_messages_v1';
  static const int defaultContextMessageLimit = 20;
  static const int defaultContextSummaryTriggerMessages = 18;
  static const int defaultCacheSummaryTriggerMessages = 18;
  static const int minContextMessageLimit = 4;
  static const int maxContextMessageLimit = 200;

  static Future<void> saveContextTokenLimit(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyContextTokenLimit, v.clamp(1000, 200000));
  }

  static Future<int> getContextTokenLimit() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_keyContextTokenLimit) ?? 5000;
    return v < 1000 ? 5000 : v;
  }

  static Future<void> saveContextMessageLimit(int value) async {
    final p = await SharedPreferences.getInstance();
    final normalized = value.clamp(
      minContextMessageLimit,
      maxContextMessageLimit,
    );
    await p.setInt(_keyContextMessageLimit, normalized);
  }

  static Future<int> getContextMessageLimit() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyContextMessageLimit) ?? defaultContextMessageLimit)
        .clamp(minContextMessageLimit, maxContextMessageLimit);
  }

  static Future<void> saveContextSummaryTriggerMessages(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _keyContextSummaryTriggerMessages,
      value.clamp(2, maxContextMessageLimit),
    );
  }

  static Future<int> getContextSummaryTriggerMessages() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyContextSummaryTriggerMessages) ??
            defaultContextSummaryTriggerMessages)
        .clamp(2, maxContextMessageLimit);
  }

  static Future<void> saveCacheSummaryTriggerMessages(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyCacheSummaryTriggerMessages, value.clamp(2, 200));
  }

  static Future<int> getCacheSummaryTriggerMessages() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyCacheSummaryTriggerMessages) ??
            defaultCacheSummaryTriggerMessages)
        .clamp(2, 200);
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
  static const String _keySplitReplyNatural = 'split_reply_natural_enabled';

  // ═══ 窗口摘要總開關（舊 key 保留，避免升級後設定丟失）═══
  static const String _keyMemorySummarize = 'memory_summarize_enabled';
  static const String _keyCacheWindowSummary = 'cache_window_summary_enabled';
  static const String _keyContextWindowSummary =
      'context_window_summary_enabled';
  static const String _keyContextWindowSummaryTrigger =
      'context_window_summary_trigger_tokens';
  static const int windowSummaryTriggerMinTokens = 500;
  static const int windowSummaryTriggerMaxTokens = 200000;
  static const String _keyMemoryWriteEnabled = 'memory_write_enabled';
  static const String _keyTimelineEnabled = 'timeline_enabled';
  static const String _keySelfNotesEnabled = 'self_notes_enabled';
  static const String _keySelfNotesLongTermEnabled =
      'self_notes_long_term_enabled_v1';
  static const String _keySelfNotesInjectionLimit =
      'self_notes_injection_limit_v1';
  static const String _keyTimelinePromptMode = 'timeline_prompt_mode';

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

  static Future<void> saveWindowSummaryTriggerTokens(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _keyContextWindowSummaryTrigger,
      v.clamp(windowSummaryTriggerMinTokens, windowSummaryTriggerMaxTokens),
    );
  }

  static Future<int> getWindowSummaryTriggerTokens() async {
    final p = await SharedPreferences.getInstance();
    final stored = p.getInt(_keyContextWindowSummaryTrigger) ?? 6000;
    return stored.clamp(
      windowSummaryTriggerMinTokens,
      windowSummaryTriggerMaxTokens,
    );
  }

  // Compatibility aliases for callers and stored settings created before the
  // cache-specific summary exposed the same trigger control.
  static Future<void> saveContextWindowSummaryTriggerTokens(int v) =>
      saveWindowSummaryTriggerTokens(v);

  static Future<int> getContextWindowSummaryTriggerTokens() =>
      getWindowSummaryTriggerTokens();

  /// 模型自主寫入長期記憶開關。默認關閉。
  static Future<void> saveMemoryWriteEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyMemoryWriteEnabled, v);
  }

  static Future<bool> getMemoryWriteEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyMemoryWriteEnabled) ?? false;
  }

  /// 時間線只控制是否讀取、注入及寫入相關內容；不會改動任何 cache key 或位置。
  static Future<void> saveTimelineEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyTimelineEnabled, v);
  }

  static Future<bool> getTimelineEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyTimelineEnabled) ?? true;
  }

  /// 「偷偷記住你」面板及其 prompt 注入開關，預設開啟。
  static Future<void> saveSelfNotesEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    if (v && p.getString(_keyTimelinePromptMode) == 'plot') return;
    await p.setBool(_keySelfNotesEnabled, v);
  }

  static Future<bool> getSelfNotesEnabled() async {
    final p = await SharedPreferences.getInstance();
    final enabled = p.getBool(_keySelfNotesEnabled) ?? true;
    // RP 劇情時間線會固定關閉「偷偷記住你」；切回其他方案時保留使用者
    // 原本保存的值，不需要搬動或清除任何 cache。
    final promptMode = p.getString(_keyTimelinePromptMode) ?? 'normal';
    return enabled && promptMode != 'plot';
  }

  static Future<void> saveSelfNotesLongTermEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keySelfNotesLongTermEnabled, value);
  }

  static Future<bool> getSelfNotesLongTermEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keySelfNotesLongTermEnabled) ?? false;
  }

  static Future<void> saveSelfNotesInjectionLimit(int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keySelfNotesInjectionLimit, value.clamp(1, 12));
  }

  static Future<int> getSelfNotesInjectionLimit() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keySelfNotesInjectionLimit) ?? 12).clamp(1, 12);
  }

  static Future<void> saveTimelinePromptMode(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _keyTimelinePromptMode,
      mode == 'plot' ? 'plot' : 'normal',
    );
  }

  static Future<String> getTimelinePromptMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyTimelinePromptMode) ?? 'normal';
  }

  static Future<void> saveSplitReply(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keySplitReply, v);
  }

  static Future<bool> getSplitReply() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keySplitReply) ?? false;
  }

  /// 多氣泡的子開關「自然發言」：開＝像真的在聊天軟體打字；
  /// 關＝只告訴模型用空行分氣泡，不改它的說話方式。預設開。
  static Future<void> saveSplitReplyNatural(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keySplitReplyNatural, v);
  }

  static Future<bool> getSplitReplyNatural() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keySplitReplyNatural) ?? true;
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

  static String _dreamScopeCountKey({
    required String characterId,
    required String contextMode,
    required String continuityId,
    required String memoryMode,
  }) {
    final scope = <String>[
      characterId,
      contextMode,
      continuityId,
      memoryMode,
    ].map(Uri.encodeComponent).join(':');
    return '${_keyDreamCurationLastCount}_scope_v1:$scope';
  }

  /// 每個角色、日常/RP、故事線與記憶類型各自累積做夢門檻。
  /// null 代表此 scope 尚未建立計數，呼叫端可採用有界的首次整理策略。
  static Future<int?> getDreamCurationLastCountForScope({
    required String characterId,
    required String contextMode,
    required String continuityId,
    required String memoryMode,
  }) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(
      _dreamScopeCountKey(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        memoryMode: memoryMode,
      ),
    );
  }

  static Future<void> saveDreamCurationLastCountForScope({
    required String characterId,
    required String contextMode,
    required String continuityId,
    required String memoryMode,
    required int count,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _dreamScopeCountKey(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        memoryMode: memoryMode,
      ),
      count < 0 ? 0 : count,
    );
  }

  /// 所有可切換的 ability 模組
  static const abilities = <String, String>{
    'emotion': '情緒座標',
    'bioclock': '生物鐘',
    'imagegen': '畫畫',
  };
}
