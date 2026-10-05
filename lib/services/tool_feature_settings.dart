import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ToolFeatureState {
  const ToolFeatureState({
    this.imageGenerationEnabled = true,
    this.shellEconomyEnabled = true,
    this.diaryEnabled = true,
    this.toolPromptsEnabled = true,
  });

  final bool imageGenerationEnabled;
  final bool shellEconomyEnabled;
  final bool diaryEnabled;
  final bool toolPromptsEnabled;

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
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ToolFeatureState &&
        other.imageGenerationEnabled == imageGenerationEnabled &&
        other.shellEconomyEnabled == shellEconomyEnabled &&
        other.diaryEnabled == diaryEnabled &&
        other.toolPromptsEnabled == toolPromptsEnabled;
  }

  @override
  int get hashCode => Object.hash(
    imageGenerationEnabled,
    shellEconomyEnabled,
    diaryEnabled,
    toolPromptsEnabled,
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
