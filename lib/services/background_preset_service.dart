import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/background_preset.dart';
import '../theme/app_theme.dart';
import 'background_image_path_service.dart';
import 'background_foreground_service.dart';
import 'settings/theme_settings.dart';

class BackgroundPresetService {
  BackgroundPresetService._();

  static const int slotCount = 6;
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static const String _migrationKey = 'background_presets_schema_v1';
  static const String _activeSlotKey = 'background_presets_active_slot_v1';
  static const String _bindingsKey = 'background_preset_bindings_v1';

  static String _slotKey(int slot) => 'background_preset_slot_${slot}_v1';

  static int normalizeSlot(int slot) => slot.clamp(1, slotCount);

  static Future<void> ensureMigrated() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getInt(_migrationKey) ?? 0) >= 1) return;

    final legacy = BackgroundPreset(
      slot: 1,
      homePath: await ThemeSettings.getBackgroundImagePath('home'),
      homeScale: await ThemeSettings.getBackgroundImageScale('home'),
      homeOffsetX: await ThemeSettings.getBackgroundImageOffsetX('home'),
      homeOffsetY: await ThemeSettings.getBackgroundImageOffsetY('home'),
      homeBlur: await ThemeSettings.getBackgroundImageBlur('home'),
      chatPath: await ThemeSettings.getBackgroundImagePath('chat'),
      chatScale: await ThemeSettings.getBackgroundImageScale('chat'),
      chatOffsetX: await ThemeSettings.getBackgroundImageOffsetX('chat'),
      chatOffsetY: await ThemeSettings.getBackgroundImageOffsetY('chat'),
      chatBlur: await ThemeSettings.getBackgroundImageBlur('chat'),
      chatAiBubbleColor: await ThemeSettings.getChatBackgroundAiBubbleColor(),
      chatUserBubbleColor:
          await ThemeSettings.getChatBackgroundUserBubbleColor(),
      chatBubbleTextColor:
          await ThemeSettings.getChatBackgroundBubbleTextColor(),
      chatThinkingTextColor:
          await ThemeSettings.getChatBackgroundThinkingTextColor(),
      chatBubbleOpacity: await ThemeSettings.getChatBackgroundBubbleOpacity(),
    );
    await prefs.setString(
      _slotKey(1),
      jsonEncode((await _forStorage(legacy)).toJson()),
    );
    await prefs.setInt(_activeSlotKey, 1);
    await prefs.setInt(_migrationKey, 1);
  }

  static Future<int> getActiveSlot() async {
    await ensureMigrated();
    final prefs = await SharedPreferences.getInstance();
    return normalizeSlot(prefs.getInt(_activeSlotKey) ?? 1);
  }

  static Future<BackgroundPreset> loadSlot(int slot) async {
    await ensureMigrated();
    final normalized = normalizeSlot(slot);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_slotKey(normalized));
    if (raw == null || raw.trim().isEmpty) {
      return BackgroundPreset(slot: normalized);
    }
    late final BackgroundPreset stored;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return BackgroundPreset(slot: normalized);
      stored = BackgroundPreset.fromJson(
        Map<String, dynamic>.from(decoded),
        fallbackSlot: normalized,
      ).copyWith(slot: normalized);
    } catch (_) {
      return BackgroundPreset(slot: normalized);
    }
    final resolved = await _resolvePaths(stored);
    final portable = await _forStorage(resolved);
    if (portable.homePath != stored.homePath ||
        portable.chatPath != stored.chatPath) {
      await prefs.setString(
        _slotKey(normalized),
        jsonEncode(portable.toJson()),
      );
    }
    return resolved;
  }

  static Future<List<BackgroundPreset>> loadAll() async =>
      Future.wait(<Future<BackgroundPreset>>[
        for (var slot = 1; slot <= slotCount; slot++) loadSlot(slot),
      ]);

  static Future<void> saveAndActivate(BackgroundPreset preset) async {
    await ensureMigrated();
    final normalized = preset.copyWith(slot: normalizeSlot(preset.slot));
    final prefs = await SharedPreferences.getInstance();
    final resolved = await _resolvePaths(normalized);
    await prefs.setString(
      _slotKey(resolved.slot),
      jsonEncode((await _forStorage(resolved)).toJson()),
    );
    await prefs.setInt(_activeSlotKey, normalized.slot);
    await _mirrorLegacyKeys(resolved);
    applyToTheme(resolved);
    await _resolveAutoColors(resolved);
    revision.value++;
  }

  static Future<BackgroundPreset> activateSlot(int slot) async {
    final preset = await loadSlot(slot);
    await saveAndActivate(preset);
    return preset;
  }

  static Future<BackgroundPreset> loadActiveIntoTheme() async {
    final activeSlot = await getActiveSlot();
    var active = BackgroundPreset(slot: activeSlot);
    // Repair every saved slot after an iOS container move without changing the
    // user's selected slot or requiring them to open each background set.
    for (var slot = 1; slot <= slotCount; slot++) {
      final loaded = await loadSlot(slot);
      if (slot == activeSlot) active = loaded;
    }
    applyToTheme(active);
    await _resolveAutoColors(active);
    return active;
  }

  static void applyToTheme(BackgroundPreset preset) {
    YanciTheme.homeBackgroundImagePath = preset.homePath;
    YanciTheme.homeBackgroundImageScale = preset.homeScale;
    YanciTheme.homeBackgroundImageOffsetX = preset.homeOffsetX;
    YanciTheme.homeBackgroundImageOffsetY = preset.homeOffsetY;
    YanciTheme.homeBackgroundImageBlur = preset.homeBlur;
    YanciTheme.chatBackgroundImagePath = preset.chatPath;
    YanciTheme.chatBackgroundImageScale = preset.chatScale;
    YanciTheme.chatBackgroundImageOffsetX = preset.chatOffsetX;
    YanciTheme.chatBackgroundImageOffsetY = preset.chatOffsetY;
    YanciTheme.chatBackgroundImageBlur = preset.chatBlur;
    YanciTheme.chatBackgroundAiBubbleOverride = preset.chatAiBubbleColor == null
        ? null
        : Color(preset.chatAiBubbleColor!);
    YanciTheme.chatBackgroundUserBubbleOverride =
        preset.chatUserBubbleColor == null
        ? null
        : Color(preset.chatUserBubbleColor!);
    YanciTheme.chatBackgroundBubbleTextOverride =
        preset.chatBubbleTextColor == null
        ? null
        : Color(preset.chatBubbleTextColor!);
    YanciTheme.chatBackgroundThinkingTextOverride =
        preset.chatThinkingTextColor == null
        ? null
        : Color(preset.chatThinkingTextColor!);
    YanciTheme.chatBackgroundBubbleOpacityOverride = preset.chatBubbleOpacity;
  }

  /// 從聊天背景圖自動推導氣泡 / 輸入框配色，寫入 YanciTheme 的 auto 欄位。
  /// 沒有背景圖時清空所有 auto 欄位，讓 getter 回退到主題預設。
  static Future<void> _resolveAutoColors(BackgroundPreset preset) async {
    final path = preset.chatPath.trim();
    if (path.isEmpty) {
      YanciTheme.chatBackgroundAutoAiBubble = null;
      YanciTheme.chatBackgroundAutoUserBubble = null;
      YanciTheme.chatBackgroundAutoBubbleText = null;
      YanciTheme.chatBackgroundAutoThinkingText = null;
      YanciTheme.chatBackgroundAutoOpacity = null;
      YanciTheme.chatBackgroundAutoInputBarBg = null;
      YanciTheme.chatBackgroundAutoInputBarBorder = null;
      YanciTheme.chatBackgroundAutoInputBarText = null;
      return;
    }
    final palette = await BackgroundForegroundService.resolveChatBubblePalette(
      path,
    );
    if (palette == null) {
      YanciTheme.chatBackgroundAutoAiBubble = null;
      YanciTheme.chatBackgroundAutoUserBubble = null;
      YanciTheme.chatBackgroundAutoBubbleText = null;
      YanciTheme.chatBackgroundAutoThinkingText = null;
      YanciTheme.chatBackgroundAutoOpacity = null;
      YanciTheme.chatBackgroundAutoInputBarBg = null;
      YanciTheme.chatBackgroundAutoInputBarBorder = null;
      YanciTheme.chatBackgroundAutoInputBarText = null;
      return;
    }
    YanciTheme.chatBackgroundAutoAiBubble = palette.aiBubble;
    YanciTheme.chatBackgroundAutoUserBubble = palette.userBubble;
    YanciTheme.chatBackgroundAutoBubbleText = palette.bubbleText;
    YanciTheme.chatBackgroundAutoThinkingText = palette.thinkingText;
    YanciTheme.chatBackgroundAutoOpacity = palette.bubbleOpacity;
    YanciTheme.chatBackgroundAutoInputBarBg = palette.inputBarBg;
    YanciTheme.chatBackgroundAutoInputBarBorder = palette.inputBarBorder;
    YanciTheme.chatBackgroundAutoInputBarText = palette.inputBarText;
  }

  static Future<void> _mirrorLegacyKeys(BackgroundPreset preset) async {
    await Future.wait<void>(<Future<void>>[
      ThemeSettings.saveBackgroundImagePath('home', preset.homePath),
      ThemeSettings.saveBackgroundImageScale('home', preset.homeScale),
      ThemeSettings.saveBackgroundImageOffset(
        'home',
        x: preset.homeOffsetX,
        y: preset.homeOffsetY,
      ),
      ThemeSettings.saveBackgroundImageBlur('home', preset.homeBlur),
      ThemeSettings.saveBackgroundImagePath('chat', preset.chatPath),
      ThemeSettings.saveBackgroundImageScale('chat', preset.chatScale),
      ThemeSettings.saveBackgroundImageOffset(
        'chat',
        x: preset.chatOffsetX,
        y: preset.chatOffsetY,
      ),
      ThemeSettings.saveBackgroundImageBlur('chat', preset.chatBlur),
      ThemeSettings.saveChatBackgroundAiBubbleColor(preset.chatAiBubbleColor),
      ThemeSettings.saveChatBackgroundUserBubbleColor(
        preset.chatUserBubbleColor,
      ),
      ThemeSettings.saveChatBackgroundBubbleTextColor(
        preset.chatBubbleTextColor,
      ),
      ThemeSettings.saveChatBackgroundThinkingTextColor(
        preset.chatThinkingTextColor,
      ),
      ThemeSettings.saveChatBackgroundBubbleOpacity(preset.chatBubbleOpacity),
    ]);
  }

  static Future<Map<String, int>> _loadBindings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bindingsKey);
    if (raw == null || raw.trim().isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, int>{
          for (final entry in decoded.entries)
            if (entry.key.toString().trim().isNotEmpty && entry.value is num)
              entry.key.toString(): normalizeSlot((entry.value as num).toInt()),
        };
      }
    } catch (_) {}
    return <String, int>{};
  }

  static Future<int?> getCharacterBinding(String characterId) async {
    final id = characterId.trim();
    if (id.isEmpty) return null;
    return (await _loadBindings())[id];
  }

  static Future<Map<String, int>> getCharacterBindings() async =>
      Map<String, int>.unmodifiable(await _loadBindings());

  static Future<void> setCharacterBinding(String characterId, int? slot) async {
    final id = characterId.trim();
    if (id.isEmpty) return;
    final bindings = await _loadBindings();
    final previous = bindings[id];
    if (slot == null) {
      bindings.remove(id);
    } else {
      bindings[id] = normalizeSlot(slot);
    }
    final next = bindings[id];
    if (previous == next) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bindingsKey, jsonEncode(bindings));
    revision.value++;
  }

  static Future<BackgroundPreset?> boundPresetForCharacter(
    String characterId,
  ) async {
    final slot = await getCharacterBinding(characterId);
    return slot == null ? null : loadSlot(slot);
  }

  static Future<BackgroundPreset> _resolvePaths(BackgroundPreset preset) async {
    return preset.copyWith(
      homePath: await BackgroundImagePathService.resolve(
        preset.homePath,
        slot: preset.slot,
        scope: 'home',
      ),
      chatPath: await BackgroundImagePathService.resolve(
        preset.chatPath,
        slot: preset.slot,
        scope: 'chat',
      ),
    );
  }

  static Future<BackgroundPreset> _forStorage(BackgroundPreset preset) async {
    return preset.copyWith(
      homePath: await BackgroundImagePathService.forStorage(
        preset.homePath,
        slot: preset.slot,
        scope: 'home',
      ),
      chatPath: await BackgroundImagePathService.forStorage(
        preset.chatPath,
        slot: preset.slot,
        scope: 'chat',
      ),
    );
  }
}
