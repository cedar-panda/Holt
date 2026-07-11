import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/theme_presets.dart';

/// 主題與外觀設定（配色、氣泡、星光、字體）
class ThemeSettings {
  // ═══ 主題 ═══
  static const String _keyDarkMode = 'dark_mode';
  static const String _keyThemePreset = 'theme_preset';
  // 沿用舊 key 名稱；現在語意是「我的頁快捷切換綁定的日/夜主題」
  static const String _keyShortcutLightPreset = 'last_light_preset';
  static const String _keyShortcutDarkPreset = 'last_dark_preset';
  static const String _keyBubbleOpacity = 'bubble_opacity';
  static const String _keyBubbleRadius = 'bubble_radius';
  static const String _keyStarEnabled = 'star_enabled';
  static const String _keyStarDensity = 'star_density';

  static Future<void> saveDarkMode(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyDarkMode, v);
  }

  static Future<bool> getDarkMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyDarkMode) ?? false;
  }

  static Future<void> saveThemePreset(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyThemePreset, v);
    await _syncDarkModeForPreset(p, v);
  }

  static Future<String> getThemePreset() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyThemePreset) ?? 'ivory';
  }

  static Future<String> getLastLightPreset() async {
    final p = await SharedPreferences.getInstance();
    return _validPresetForMode(
          p.getString(_keyShortcutLightPreset),
          dark: false,
        ) ??
        'ivory';
  }

  static Future<String> getLastDarkPreset() async {
    final p = await SharedPreferences.getInstance();
    return _validPresetForMode(
          p.getString(_keyShortcutDarkPreset),
          dark: true,
        ) ??
        'nightlamp';
  }

  static Future<void> saveLightShortcutPreset(String id) async {
    final p = await SharedPreferences.getInstance();
    if (_validPresetForMode(id, dark: false) == null) return;
    await p.setString(_keyShortcutLightPreset, id);
  }

  static Future<void> saveDarkShortcutPreset(String id) async {
    final p = await SharedPreferences.getInstance();
    if (_validPresetForMode(id, dark: true) == null) return;
    await p.setString(_keyShortcutDarkPreset, id);
  }

  static String? _validPresetForMode(String? id, {required bool dark}) {
    if (id == null || !presets.any((p) => p.id == id)) return null;
    final preset = findPreset(id);
    return preset.isDark == dark ? id : null;
  }

  static Future<void> _syncDarkModeForPreset(
    SharedPreferences p,
    String id,
  ) async {
    if (!presets.any((preset) => preset.id == id)) return;
    final preset = findPreset(id);
    await p.setBool(_keyDarkMode, preset.isDark);
  }

  static Future<void> saveBubbleOpacity(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyBubbleOpacity, v);
  }

  static Future<double> getBubbleOpacity() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_keyBubbleOpacity) ?? 1.0;
  }

  static Future<void> saveBubbleBrightness(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('bubble_brightness', v);
  }

  static Future<double> getBubbleBrightness() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble('bubble_brightness') ?? 0.0;
  }

  static Future<void> saveBubbleRadius(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyBubbleRadius, v);
  }

  static Future<double> getBubbleRadius() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_keyBubbleRadius) ?? 20.0;
  }

  static Future<void> saveStarEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyStarEnabled, v);
  }

  static Future<bool> getStarEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyStarEnabled) ?? true;
  }

  static Future<void> saveStarDensity(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyStarDensity, v);
  }

  static Future<int> getStarDensity() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyStarDensity) ?? 12;
  }

  // ═══ 自定義圖片背景（首頁 / 對話分開）═══
  static String _backgroundPathKey(String scope) => 'bg_image_${scope}_path';
  static String _backgroundScaleKey(String scope) => 'bg_image_${scope}_scale';
  static String _backgroundOffsetXKey(String scope) =>
      'bg_image_${scope}_offset_x';
  static String _backgroundOffsetYKey(String scope) =>
      'bg_image_${scope}_offset_y';

  static Future<void> saveBackgroundImagePath(String scope, String path) async {
    final p = await SharedPreferences.getInstance();
    if (path.isEmpty) {
      await p.remove(_backgroundPathKey(scope));
    } else {
      await p.setString(_backgroundPathKey(scope), path);
    }
  }

  static Future<String> getBackgroundImagePath(String scope) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_backgroundPathKey(scope)) ?? '';
  }

  static Future<void> saveBackgroundImageScale(
    String scope,
    double scale,
  ) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_backgroundScaleKey(scope), scale);
  }

  static Future<double> getBackgroundImageScale(String scope) async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_backgroundScaleKey(scope)) ?? 1.0;
  }

  static Future<void> saveBackgroundImageOffset(
    String scope, {
    required double x,
    required double y,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(
      _backgroundOffsetXKey(scope),
      x.clamp(-0.5, 0.5).toDouble(),
    );
    await p.setDouble(
      _backgroundOffsetYKey(scope),
      y.clamp(-0.5, 0.5).toDouble(),
    );
  }

  static Future<double> getBackgroundImageOffsetX(String scope) async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_backgroundOffsetXKey(scope)) ?? 0.0;
  }

  static Future<double> getBackgroundImageOffsetY(String scope) async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_backgroundOffsetYKey(scope)) ?? 0.0;
  }

  // ═══ 自定義色覆蓋 ═══

  static Future<void> saveCustomColor(String key, String hex) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('custom_color_$key', hex);
  }

  static Future<String?> getCustomColor(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('custom_color_$key');
  }

  static Future<void> clearCustomColors() async {
    final p = await SharedPreferences.getInstance();
    final keys = p.getKeys().where((k) => k.startsWith('custom_color_'));
    for (final k in keys) {
      await p.remove(k);
    }
  }

  // ═══ 字體 ═══
  static const String _keyFontChinese = 'font_chinese';
  static const String _keyFontEnglish = 'font_english';
  static const String _keyFontSizeScale = 'font_size_scale';

  static Future<void> saveFontChinese(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyFontChinese, v);
  }

  static Future<String> getFontChinese() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyFontChinese);
    return saved == 'Lora' || saved == 'LXGW WenKai TC' ? saved! : 'Lora';
  }

  static Future<void> saveFontEnglish(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyFontEnglish, v);
  }

  static Future<String> getFontEnglish() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyFontEnglish);
    return saved == 'Lora' || saved == 'LXGW WenKai TC'
        ? saved!
        : 'LXGW WenKai TC';
  }

  static Future<void> saveFontSizeScale(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyFontSizeScale, v);
  }

  static Future<double> getFontSizeScale() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_keyFontSizeScale) ?? 1.0;
  }

  // ═══ 歷史選色 ═══
  static const String _keyColorHistory = 'color_history';

  static Future<void> saveColorHistory(List<String> hexList) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyColorHistory, hexList);
  }

  static Future<List<String>> getColorHistory() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_keyColorHistory) ?? [];
  }
}
