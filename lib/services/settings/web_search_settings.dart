import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live web search is a developer preview. Debug builds can exercise it, while
/// release builds fail closed unless the distributor opts in explicitly with
/// `--dart-define=HOLT_ENABLE_LIVE_WEB_SEARCH=true` after reviewing the current
/// provider terms, target audience and regions.
const bool webSearchLiveDeveloperPreviewEnabled = bool.fromEnvironment(
  'HOLT_ENABLE_LIVE_WEB_SEARCH',
  defaultValue: kDebugMode,
);

/// 原生網路搜尋的供應商策略。
///
/// [dual] 代表同一段經使用者確認的請求會送往兩家供應商，結果分開顯示；
/// 它不是單一供應商失敗後才啟動的 fallback。
enum WebSearchMode {
  auto('auto'),
  gemini('gemini'),
  openRouter('openrouter'),
  dual('dual');

  const WebSearchMode(this.storageValue);

  final String storageValue;

  static WebSearchMode fromStorage(String? value) => switch (value) {
    'gemini' => WebSearchMode.gemini,
    'openrouter' => WebSearchMode.openRouter,
    'dual' => WebSearchMode.dual,
    _ => WebSearchMode.auto,
  };
}

/// 原生網路搜尋的本機偏好。
///
/// API Key 與模型仍由 `ApiSettings` 管理；這裡只保存是否啟用、供應商策略與
/// 每日 provider launch 上限，避免出現第二份憑證或模型來源。
class WebSearchSettings {
  static const String _keyEnabled = 'web_search_enabled_v1';
  static const String _keyMode = 'web_search_mode_v1';
  static const String _keyDailyProviderLaunchCap =
      'web_search_daily_provider_launch_cap_v1';

  static const int minDailyProviderLaunchCap = 1;
  static const int maxDailyProviderLaunchCap = 100;
  static const int defaultDailyProviderLaunchCap = 20;

  static Future<bool> getEnabled() async {
    if (!webSearchLiveDeveloperPreviewEnabled) return false;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_keyEnabled) ?? false;
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
    await preferences.setString(_keyMode, value.storageValue);
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
}
