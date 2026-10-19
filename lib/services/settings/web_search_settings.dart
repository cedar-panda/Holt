import 'package:shared_preferences/shared_preferences.dart';

import '../secure_store.dart';

/// Native web search is available in normal builds. Distributors can still
/// disable the complete live-search path explicitly at compile time.
const bool webSearchLiveFeatureEnabled = bool.fromEnvironment(
  'HOLT_ENABLE_LIVE_WEB_SEARCH',
  defaultValue: true,
);

/// Compatibility alias for the existing search pipeline.
const bool webSearchLiveDeveloperPreviewEnabled = webSearchLiveFeatureEnabled;

/// 原生網路搜尋的供應商策略。
enum WebSearchMode {
  auto('auto'),
  gemini('gemini'),
  openRouter('openrouter'),
  xai('xai'),
  relay('relay'),
  // 僅保留作舊資料兼容；讀取與保存時都會遷移為 auto，UI 不顯示。
  dual('dual');

  const WebSearchMode(this.storageValue);

  final String storageValue;

  static WebSearchMode fromStorage(String? value) => switch (value) {
    'gemini' => WebSearchMode.gemini,
    'openrouter' => WebSearchMode.openRouter,
    'xai' => WebSearchMode.xai,
    'relay' => WebSearchMode.relay,
    'dual' => WebSearchMode.auto,
    _ => WebSearchMode.auto,
  };
}

/// 原生網路搜尋的本機偏好。
///
/// API Key 仍由 `ApiSettings` 管理；這裡保存是否啟用、供應商策略、
/// 每日 provider launch 上限，以及各供應商的搜尋專用模型選擇。
/// 搜尋模型為空時降級到原有預設行為（OpenRouter = 內建預覽模型、
/// Gemini = 目前主 Gemini 模型）。
class WebSearchSettings {
  static const String _keyEnabled = 'web_search_enabled_v1';
  static const String _keyMode = 'web_search_mode_v1';
  static const String _keyDailyProviderLaunchCap =
      'web_search_daily_provider_launch_cap_v1';
  static const String _keyMaxResults = 'web_search_max_results_v1';
  static const String _keyOpenRouterSearchModel =
      'web_search_openrouter_model_v1';
  static const String _keyGeminiSearchModel = 'web_search_gemini_model_v1';
  static const String _keyXaiSearchModel = 'web_search_xai_model_v1';
  static const String _keyRelayEndpoint = 'web_search_relay_endpoint_v1';
  static const String _keyRelayApiKey = 'web_search_relay_api_key_v1';
  static const String _keyRelayModel = 'web_search_relay_model_v1';

  static const int minDailyProviderLaunchCap = 1;
  static const int maxDailyProviderLaunchCap = 100;
  static const int defaultDailyProviderLaunchCap = 20;
  static const int minMaxResults = 1;
  static const int maxMaxResults = 20;
  static const int defaultMaxResults = 2;

  static Future<bool> getEnabled() async {
    if (!webSearchLiveDeveloperPreviewEnabled) return false;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_keyEnabled) ?? true;
  }

  static Future<void> saveEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      _keyEnabled,
      value && webSearchLiveDeveloperPreviewEnabled,
    );
  }

  static Future<WebSearchMode> getMode() async {
    final preferences = await SharedPreferences.getInstance();
    return WebSearchMode.fromStorage(preferences.getString(_keyMode));
  }

  static Future<void> saveMode(WebSearchMode value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _keyMode,
      value == WebSearchMode.dual
          ? WebSearchMode.auto.storageValue
          : value.storageValue,
    );
  }

  static Future<int> getDailyProviderLaunchCap() async {
    final preferences = await SharedPreferences.getInstance();
    final value =
        preferences.getInt(_keyDailyProviderLaunchCap) ??
        defaultDailyProviderLaunchCap;
    return value.clamp(minDailyProviderLaunchCap, maxDailyProviderLaunchCap);
  }

  static Future<void> saveDailyProviderLaunchCap(int value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _keyDailyProviderLaunchCap,
      value.clamp(minDailyProviderLaunchCap, maxDailyProviderLaunchCap),
    );
  }

  static Future<int> getMaxResults() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(_keyMaxResults) ?? defaultMaxResults;
    return value.clamp(minMaxResults, maxMaxResults);
  }

  static Future<void> saveMaxResults(int value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _keyMaxResults,
      value.clamp(minMaxResults, maxMaxResults),
    );
  }

  // ═══ 搜尋專用模型（獨立於主聊天模型） ═══

  /// OpenRouter 搜尋模型。空字串代表降級到內建預設模型。
  static Future<String> getOpenRouterSearchModel() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyOpenRouterSearchModel) ?? '';
  }

  static Future<void> saveOpenRouterSearchModel(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyOpenRouterSearchModel, value.trim());
  }

  /// Gemini 搜尋模型。空字串代表降級到目前主 Gemini 模型。
  static Future<String> getGeminiSearchModel() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyGeminiSearchModel) ?? '';
  }

  static Future<void> saveGeminiSearchModel(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyGeminiSearchModel, value.trim());
  }

  static Future<String> getXaiSearchModel() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyXaiSearchModel) ?? '';
  }

  static Future<void> saveXaiSearchModel(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyXaiSearchModel, value.trim());
  }

  static Future<String> getRelayEndpoint() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyRelayEndpoint) ?? '';
  }

  static Future<void> saveRelayEndpoint(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyRelayEndpoint, value.trim());
  }

  static Future<String> getRelayApiKey() async {
    return SecureStore.read(_keyRelayApiKey);
  }

  static Future<void> saveRelayApiKey(String value) async {
    await SecureStore.write(_keyRelayApiKey, value.trim());
  }

  static Future<String> getRelayModel() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyRelayModel) ?? '';
  }

  static Future<void> saveRelayModel(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyRelayModel, value.trim());
  }
}
