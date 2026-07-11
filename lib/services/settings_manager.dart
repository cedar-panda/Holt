/// 設定管理 — Barrel Export
///
/// 所有設定已拆分為獨立模組：
///   ApiSettings      → settings/api_settings.dart      （API 供應商、Key、模型、buildAdapter）
///   MemorySettings   → settings/memory_settings.dart   （窗口摘要、Token 預算、Caching）
///   TtsSettings      → settings/tts_settings.dart      （TTS 語音）
///   ThemeSettings    → settings/theme_settings.dart    （主題、氣泡、星光、字體）
///   UserSettings     → settings/user_settings.dart     （用戶檔案、角色、雜項）
///
/// 替換對照（全局搜尋替換即可）：
///   SettingsManager.saveApiKey         → ApiSettings.saveApiKey
///   SettingsManager.getApiProvider     → ApiSettings.getApiProvider
///   SettingsManager.buildAdapter       → ApiSettings.buildAdapter
///   SettingsManager.getMemorySummarize → MemorySettings.getWindowSummaryEnabled
///   SettingsManager.getEnablePromptCaching → MemorySettings.getEnablePromptCaching
///   SettingsManager.getTtsProvider     → TtsSettings.getTtsProvider
///   SettingsManager.saveThemePreset    → ThemeSettings.saveThemePreset
///   SettingsManager.getFontChinese     → ThemeSettings.getFontChinese
///   SettingsManager.saveUserName       → UserSettings.saveUserName
///   SettingsManager.getActiveCharacterId → UserSettings.getActiveCharacterId
library;

export 'settings/api_settings.dart';
export 'settings/memory_settings.dart';
export 'settings/tts_settings.dart';
export 'settings/theme_settings.dart';
export 'settings/user_settings.dart';
