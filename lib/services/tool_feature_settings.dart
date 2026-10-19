import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/context_mode.dart';

@immutable
class ToolFeatureState {
  const ToolFeatureState({
    this.imageGenerationEnabled = true,
    this.shellEconomyEnabled = true,
    this.diaryEnabled = true,
    this.toolPromptsEnabled = true,
    this.modelGreetingEnabled = true,
    this.emailDraftEnabled = true,
    this.rpDailyLifeToolsEnabled = false,
  });

  final bool imageGenerationEnabled;
  final bool shellEconomyEnabled;
  final bool diaryEnabled;
  final bool toolPromptsEnabled;
  final bool modelGreetingEnabled;
  final bool emailDraftEnabled;

  /// RP 是平行時空：貝殼經濟、首頁便箋、郵件草稿、X 發文、婚姻等
  /// 日常生活類工具預設不注入 RP。開啟後 RP 與日常相同。
  final bool rpDailyLifeToolsEnabled;

  /// 本輪實際可用的工具狀態（只用於 prompt 組裝，不寫回全域 state）。
  ToolFeatureState forContext(ContextMode mode) =>
      mode == ContextMode.rp && !rpDailyLifeToolsEnabled
      ? copyWith(
          shellEconomyEnabled: false,
          modelGreetingEnabled: false,
          emailDraftEnabled: false,
        )
      : this;

  /// X 發文、婚姻提示等不在上述欄位裡的日常工具，用這個判斷。
  bool dailyLifeToolsAllowed(ContextMode mode) =>
      mode != ContextMode.rp || rpDailyLifeToolsEnabled;

  // Keep the old accessors as compatibility aliases while the app migrates
  // from four visible switches to one capability switch.
  bool get shopEnabled => shellEconomyEnabled;
  bool get scratchEnabled => shellEconomyEnabled;
  bool get transferEnabled => shellEconomyEnabled;
  bool get coinSnapshotEnabled => shellEconomyEnabled;

  ToolFeatureState copyWith({
    bool? imageGenerationEnabled,
    bool? shellEconomyEnabled,
    @Deprecated('Use shellEconomyEnabled') bool? shopEnabled,
    @Deprecated('Use shellEconomyEnabled') bool? scratchEnabled,
    @Deprecated('Use shellEconomyEnabled') bool? transferEnabled,
    @Deprecated('Use shellEconomyEnabled') bool? coinSnapshotEnabled,
    bool? diaryEnabled,
    bool? toolPromptsEnabled,
    bool? modelGreetingEnabled,
    bool? emailDraftEnabled,
    bool? rpDailyLifeToolsEnabled,
  }) {
    final economy =
        shellEconomyEnabled ??
        shopEnabled ??
        scratchEnabled ??
        transferEnabled ??
        coinSnapshotEnabled;
    return ToolFeatureState(
      imageGenerationEnabled:
          imageGenerationEnabled ?? this.imageGenerationEnabled,
      shellEconomyEnabled: economy ?? this.shellEconomyEnabled,
      diaryEnabled: diaryEnabled ?? this.diaryEnabled,
      toolPromptsEnabled: toolPromptsEnabled ?? this.toolPromptsEnabled,
      modelGreetingEnabled: modelGreetingEnabled ?? this.modelGreetingEnabled,
      emailDraftEnabled: emailDraftEnabled ?? this.emailDraftEnabled,
      rpDailyLifeToolsEnabled:
          rpDailyLifeToolsEnabled ?? this.rpDailyLifeToolsEnabled,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ToolFeatureState &&
        other.imageGenerationEnabled == imageGenerationEnabled &&
        other.shellEconomyEnabled == shellEconomyEnabled &&
        other.diaryEnabled == diaryEnabled &&
        other.toolPromptsEnabled == toolPromptsEnabled &&
        other.modelGreetingEnabled == modelGreetingEnabled &&
        other.emailDraftEnabled == emailDraftEnabled &&
        other.rpDailyLifeToolsEnabled == rpDailyLifeToolsEnabled;
  }

  @override
  int get hashCode => Object.hash(
    imageGenerationEnabled,
    shellEconomyEnabled,
    diaryEnabled,
    toolPromptsEnabled,
    modelGreetingEnabled,
    emailDraftEnabled,
    rpDailyLifeToolsEnabled,
  );
}

/// Global feature switches shared by settings, prompt assembly and local UI.
/// Existing preference keys are retained so upgrades do not reset user choices.
abstract final class ToolFeatureSettings {
  static const String _imageGenerationKey = 'ability_imagegen_enabled';
  static const String _shellEconomyKey = 'ability_shell_economy_enabled';
  // Legacy keys are read once for migration and mirrored on writes so an
  // older build cannot silently restore a different capability state.
  static const String _shopKey = 'shop_enabled';
  static const String _scratchKey = 'ability_scratch_card_enabled';
  static const String _transferKey = 'ability_transfer_enabled';
  static const String _coinSnapshotKey = 'ability_coin_snapshot_enabled';
  static const String _diaryKey = 'ability_daily_diary_enabled';
  static const String _toolPromptsKey = 'ability_tool_prompts_enabled';
  static const String _modelGreetingKey = 'ability_model_greeting_enabled';
  static const String _emailDraftKey = 'ability_email_draft_enabled';
  static const String _rpDailyLifeToolsKey = 'ability_rp_daily_life_tools_enabled';

  static final ValueNotifier<ToolFeatureState> state =
      ValueNotifier<ToolFeatureState>(const ToolFeatureState());

  static Future<ToolFeatureState> load() async {
    final preferences = await SharedPreferences.getInstance();
    final economy = preferences.containsKey(_shellEconomyKey)
        ? (preferences.getBool(_shellEconomyKey) ?? true)
        : _legacyEconomyValue(preferences);
    final loaded = ToolFeatureState(
      imageGenerationEnabled: preferences.getBool(_imageGenerationKey) ?? true,
      shellEconomyEnabled: economy,
      diaryEnabled: preferences.getBool(_diaryKey) ?? true,
      toolPromptsEnabled: preferences.getBool(_toolPromptsKey) ?? true,
      modelGreetingEnabled: preferences.getBool(_modelGreetingKey) ?? true,
      emailDraftEnabled: preferences.getBool(_emailDraftKey) ?? true,
      rpDailyLifeToolsEnabled:
          preferences.getBool(_rpDailyLifeToolsKey) ?? false,
    );
    if (!preferences.containsKey(_shellEconomyKey)) {
      await preferences.setBool(_shellEconomyKey, economy);
    }
    if (state.value != loaded) state.value = loaded;
    return loaded;
  }

  static Future<void> setImageGenerationEnabled(bool value) =>
      _set(_imageGenerationKey, value, (current) {
        return current.copyWith(imageGenerationEnabled: value);
      });

  static Future<void> setShellEconomyEnabled(bool value) => _setEconomy(value);

  static Future<void> setShopEnabled(bool value) => _setEconomy(value);

  static Future<void> setScratchEnabled(bool value) => _setEconomy(value);

  static Future<void> setTransferEnabled(bool value) => _setEconomy(value);

  static Future<void> setCoinSnapshotEnabled(bool value) => _setEconomy(value);

  static Future<void> setDiaryEnabled(bool value) =>
      _set(_diaryKey, value, (current) {
        return current.copyWith(diaryEnabled: value);
      });

  static Future<void> setToolPromptsEnabled(bool value) =>
      _set(_toolPromptsKey, value, (current) {
        return current.copyWith(toolPromptsEnabled: value);
      });

  static Future<void> setModelGreetingEnabled(bool value) =>
      _set(_modelGreetingKey, value, (current) {
        return current.copyWith(modelGreetingEnabled: value);
      });

  static Future<void> setEmailDraftEnabled(bool value) =>
      _set(_emailDraftKey, value, (current) {
        return current.copyWith(emailDraftEnabled: value);
      });

  static Future<void> setRpDailyLifeToolsEnabled(bool value) =>
      _set(_rpDailyLifeToolsKey, value, (current) {
        return current.copyWith(rpDailyLifeToolsEnabled: value);
      });

  static Future<void> _set(
    String key,
    bool value,
    ToolFeatureState Function(ToolFeatureState current) update,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, value);
    state.value = update(state.value);
  }

  static bool _legacyEconomyValue(SharedPreferences preferences) {
    final legacyKeys = <String>[
      _shopKey,
      _scratchKey,
      _transferKey,
      _coinSnapshotKey,
    ];
    if (!legacyKeys.any(preferences.containsKey)) return true;
    return legacyKeys.any((key) => preferences.getBool(key) ?? true);
  }

  static Future<void> _setEconomy(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_shellEconomyKey, value);
    // Keep downgrade behavior deterministic without exposing these as UI
    // controls anymore.
    await Future.wait([
      preferences.setBool(_shopKey, value),
      preferences.setBool(_scratchKey, value),
      preferences.setBool(_transferKey, value),
      preferences.setBool(_coinSnapshotKey, value),
    ]);
    state.value = state.value.copyWith(shellEconomyEnabled: value);
  }
}
