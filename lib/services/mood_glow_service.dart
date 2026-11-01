import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/context_mode.dart';
import '../theme/app_theme.dart';
import 'locale_strings.dart';

/// 心情流光生效範圍（側邊欄「頭像顯示」底下選）。
enum MoodGlowScope {
  off('off'),
  daily('daily'),
  rp('rp'),
  all('all');

  const MoodGlowScope(this.storageValue);
  final String storageValue;

  static MoodGlowScope parse(String? raw) => MoodGlowScope.values.firstWhere(
    (scope) => scope.storageValue == raw,
    orElse: () => MoodGlowScope.all,
  );

  bool appliesTo(ContextMode mode) => switch (this) {
    MoodGlowScope.off => false,
    MoodGlowScope.daily => mode == ContextMode.daily,
    MoodGlowScope.rp => mode == ContextMode.rp,
    MoodGlowScope.all => true,
  };
}

/// 心情流光顏色呈現（側邊欄「心情流光」底下選）。
/// - [theme]：融入主題色（色相往心情色轉一部分，亮度鎖在主題附近）。
/// - [independent]：直接用模型輸出的色號，不混主題色。預設。
enum MoodGlowBlend {
  theme('theme'),
  independent('independent');

  const MoodGlowBlend(this.storageValue);
  final String storageValue;

  static MoodGlowBlend parse(String? raw) => MoodGlowBlend.values.firstWhere(
    (mode) => mode.storageValue == raw,
    orElse: () => MoodGlowBlend.independent,
  );
}

/// 心情流光：角色每 [cooldownTurns] 輪最多用一次 `<mood_color>#RRGGBB</mood_color>`
/// 表示當下心情；顏色以約三成五混進主題色，套在聊天頁角色頭像外圈與通話流光。
///
/// - 每個窗口各存一份（SharedPreferences，不進 DB／不影響 cache 前綴）。
/// - 冷卻由 App 把關：太早寫的標籤照樣剝掉，但不換色。
/// - 範圍為 off 或不適用當前模式時：不注入說明、不換色，標籤仍會被剝掉。
abstract final class MoodGlowService {
  static const int cooldownTurns = 10;

  /// 心情色混進主題色的比例。
  static const double blend = 0.35;

  /// 使用者指定的固定色：是「他選的顏色」，要看得出來，混得少很多。
  static const double lockedBlend = 0.8;
  static const Duration transition = Duration(milliseconds: 1400);

  static const String _scopeKey = 'mood_glow_scope_v1';
  static const String _blendKey = 'mood_glow_blend_v1';
  static String _stateKey(String conversationId) =>
      'mood_glow_state_v1_$conversationId';

  static final RegExp _tagRe = RegExp(
    r'<mood_color>\s*#?([0-9a-fA-F]{6})\s*</mood_color>',
    caseSensitive: false,
  );
  /// 使用者指定的固定色：鎖住後一般 `<mood_color>` 一律忽略，
  /// 直到再出現新的固定色或 `<mood_color_unlock/>`。不受冷卻限制。
  static final RegExp _lockRe = RegExp(
    r'<mood_color_lock>\s*#?([0-9a-fA-F]{6})\s*</mood_color_lock>',
    caseSensitive: false,
  );
  static final RegExp _unlockRe = RegExp(
    r'<mood_color_unlock\s*/?>',
    caseSensitive: false,
  );
  static final RegExp _anyTagRe = RegExp(
    r'<mood_color(?:_lock)?>[\s\S]*?(</mood_color(?:_lock)?>|$)|<mood_color_unlock\s*/?>',
    caseSensitive: false,
  );

  /// 目前打開的窗口（聊天頁或通話頁綁定）的心情色；null = 沒有／不顯示。
  static final ValueNotifier<Color?> activeColor = ValueNotifier<Color?>(null);
  static String? _activeConversationId;

  /// 目前窗口的顏色是不是使用者指定的固定色（決定顯示時混多少）。
  static bool _activeLocked = false;

  /// 目前的顏色呈現方式；頭像／通話流光同時監聽它和 [activeColor]，
  /// 側邊欄一切換就重畫。啟動後由 [getBlend]／[bindConversation] 載入。
  static final ValueNotifier<MoodGlowBlend> blendMode =
      ValueNotifier<MoodGlowBlend>(MoodGlowBlend.independent);

  static Future<MoodGlowBlend> getBlend() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = MoodGlowBlend.parse(prefs.getString(_blendKey));
    blendMode.value = mode;
    return mode;
  }

  static Future<void> saveBlend(MoodGlowBlend mode) async {
    blendMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_blendKey, mode.storageValue);
  }

  static Future<MoodGlowScope> getScope() async {
    final prefs = await SharedPreferences.getInstance();
    return MoodGlowScope.parse(prefs.getString(_scopeKey));
  }

  static Future<void> saveScope(MoodGlowScope scope) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scopeKey, scope.storageValue);
  }

  static Future<bool> isEnabledFor(ContextMode mode) async =>
      (await getScope()).appliesTo(mode);

  /// 聊天頁／通話頁打開窗口時呼叫：載入該窗口的顏色給頭像用。
  static Future<void> bindConversation(
    String conversationId, {
    required ContextMode mode,
  }) async {
    _activeConversationId = conversationId;
    final enabled = await isEnabledFor(mode);
    await getBlend();
    final state = await _load(conversationId);
    if (_activeConversationId != conversationId) return;
    _activeLocked = enabled && state.locked;
    activeColor.value = enabled ? state.color : null;
  }

  /// 剝掉所有 `<mood_color>`（不計輪數、不換色）。追問／二段回覆用。
  static String strip(String text) => text.replaceAll(_anyTagRe, '');

  /// 主回覆處理：計一輪、在冷卻允許時換色，回傳已剝標籤的文字。
  static Future<String> processReply(
    String text, {
    required String conversationId,
    required ContextMode mode,
  }) async {
    final matches = _tagRe.allMatches(text).toList();
    final locks = _lockRe.allMatches(text).toList();
    final unlock = _unlockRe.hasMatch(text);
    final stripped = strip(text);
    if (!await isEnabledFor(mode)) return stripped;

    final state = await _load(conversationId);
    final turns = state.turns + 1;
    var next = state.copyWith(turns: turns);
    if (locks.isNotEmpty) {
      // 使用者要的固定色：立即生效、鎖住。
      next = next.copyWith(
        color: _parse(locks.last.group(1)!),
        setAtTurn: turns,
        locked: true,
      );
    } else if (unlock && state.locked) {
      // 改回自動：保留目前顏色，下一輪起就可以按心情換。
      next = next.copyWith(
        locked: false,
        setAtTurn: turns - cooldownTurns,
      );
    } else if (!state.locked &&
        matches.isNotEmpty &&
        state.turnsUntilNext(turns) == 0) {
      next = next.copyWith(
        color: _parse(matches.last.group(1)!),
        setAtTurn: turns,
      );
    }
    await _save(conversationId, next);
    if (_activeConversationId == conversationId) {
      final lockChanged = _activeLocked != next.locked;
      _activeLocked = next.locked;
      if (lockChanged && activeColor.value == next.color) {
        // 同色但鎖定狀態變了：顯示強度不同，強制通知重畫。
        activeColor.value = null;
      }
      activeColor.value = next.color;
    }
    return stripped;
  }

  /// 放進可快取 control 層：格式與規則（只在範圍設定改變時變動）。
  static String abilityPrompt() => L.pick(
    en: '### Mood Glow\nTo show your mood as a color, end a reply with <mood_color>#RRGGBB</mood_color> (at most once per $cooldownTurns replies; pick it yourself). If the user wants a fixed color: <mood_color_lock>#RRGGBB</mood_color_lock>; back to automatic: <mood_color_unlock/>.',
    zhTW: '### 心情流光\n想用顏色表達心情時，在回覆最後加 <mood_color>#RRGGBB</mood_color>（每 $cooldownTurns 輪最多一次，顏色自己挑）。對方要固定色時用 <mood_color_lock>#RRGGBB</mood_color_lock>，改回自動用 <mood_color_unlock/>。',
    zhCN: '### 心情流光\n想用颜色表达心情时，在回复最后加 <mood_color>#RRGGBB</mood_color>（每 $cooldownTurns 轮最多一次，颜色自己挑）。对方要固定色时用 <mood_color_lock>#RRGGBB</mood_color_lock>，改回自动用 <mood_color_unlock/>。',
  );

  /// 放進 request-only 動態層：目前顏色與冷卻狀態。
  static Future<String> statusPrompt(String conversationId) async {
    final state = await _load(conversationId);
    final wait = state.turnsUntilNext(state.turns);
    final current = state.color == null ? null : _hex(state.color!);
    if (state.locked && current != null) {
      return L.pick(
        en: 'Mood glow: locked to $current by the user. Keep it unless the user asks to change it or go back to automatic.',
        zhTW: '心情流光：目前固定為 $current（對方指定）。除非對方要換色或改回自動，否則保持不變。',
        zhCN: '心情流光：目前固定为 $current（对方指定）。除非对方要换色或改回自动，否则保持不变。',
      );
    }
    return L.pick(
      en: 'Mood glow: current color ${current ?? 'not set'}; ${wait == 0 ? 'you may set a new color this reply if you want.' : 'next change available in $wait replies (a tag before then is ignored).'}',
      zhTW: '心情流光：目前顏色 ${current ?? '尚未設定'}；${wait == 0 ? '這一輪想換的話可以換。' : '還要 $wait 輪才能再換（提早寫會被忽略）。'}',
      zhCN: '心情流光：目前颜色 ${current ?? '尚未设定'}；${wait == 0 ? '这一轮想换的话可以换。' : '还要 $wait 轮才能再换（提早写会被忽略）。'}',
    );
  }

  /// 顯示用顏色：在色相環上從主題色往心情色轉 [blend] 的角度（走最短弧），
  /// 而不是 RGB 直線混合——RGB 混對比色（藍＋橘）會在中間變成髒灰。
  /// 亮度鎖在主題 ±0.08、飽和度不高於主題 +0.1、也不低於主題的一半，
  /// 看起來是「今天的光偏暖／偏冷」，不會跳出主題。
  /// 獨立流光（[MoodGlowBlend.independent]）時直接回傳模型給的色號。
  static Color displayColor(Color mood, {Color? base, bool? locked}) {
    if (blendMode.value == MoodGlowBlend.independent) return mood;
    final isLocked = locked ?? _activeLocked;
    final mix = isLocked ? lockedBlend : blend;
    final lightRange = isLocked ? 0.15 : 0.08;
    final satHeadroom = isLocked ? 0.25 : 0.1;
    final anchor = HSLColor.fromColor(base ?? YanciTheme.accent);
    final target = HSLColor.fromColor(mood);
    // 心情色本身幾乎是灰階時，色相沒有意義：只微調明暗，不轉色相。
    final moodHasHue = target.saturation > 0.08;
    var delta = target.hue - anchor.hue;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    final hue = moodHasHue ? (anchor.hue + delta * mix) % 360 : anchor.hue;
    final saturation =
        (anchor.saturation + (target.saturation - anchor.saturation) * mix)
            .clamp(
              isLocked ? 0.0 : anchor.saturation * 0.5,
              (anchor.saturation + satHeadroom).clamp(0.0, 1.0),
            );
    final lightness =
        (anchor.lightness + (target.lightness - anchor.lightness) * mix)
            .clamp(anchor.lightness - lightRange, anchor.lightness + lightRange);
    return HSLColor.fromAHSL(
      1,
      hue < 0 ? hue + 360 : hue,
      saturation.toDouble(),
      lightness.toDouble().clamp(0.0, 1.0),
    ).toColor();
  }

  static Color _parse(String hex) => Color(int.parse('FF$hex', radix: 16));

  static String _hex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static Future<_MoodGlowState> _load(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_stateKey(conversationId));
    if (raw == null || raw.isEmpty) return const _MoodGlowState();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final colorValue = map['color'] as int?;
      return _MoodGlowState(
        color: colorValue == null ? null : Color(colorValue),
        turns: map['turns'] as int? ?? 0,
        setAtTurn: map['set_at'] as int? ?? 0,
        locked: map['locked'] as bool? ?? false,
      );
    } catch (_) {
      return const _MoodGlowState();
    }
  }

  static Future<void> _save(String conversationId, _MoodGlowState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _stateKey(conversationId),
      jsonEncode(<String, Object?>{
        'color': state.color?.toARGB32(),
        'turns': state.turns,
        'set_at': state.setAtTurn,
        'locked': state.locked,
      }),
    );
  }
}

class _MoodGlowState {
  const _MoodGlowState({
    this.color,
    this.turns = 0,
    this.setAtTurn = 0,
    this.locked = false,
  });

  final Color? color;

  /// 這個窗口累計處理過的主回覆數。
  final int turns;

  /// 上次換色時的 [turns]。
  final int setAtTurn;

  /// 使用者指定的固定色；鎖住時忽略一般心情色。
  final bool locked;

  /// 在累計 [atTurns] 輪的時點，還要等幾輪才能換色（0 = 可以換）。
  int turnsUntilNext(int atTurns) {
    if (color == null) return 0;
    final waited = atTurns - setAtTurn;
    return waited >= MoodGlowService.cooldownTurns
        ? 0
        : MoodGlowService.cooldownTurns - waited;
  }

  _MoodGlowState copyWith({
    Color? color,
    int? turns,
    int? setAtTurn,
    bool? locked,
  }) => _MoodGlowState(
    color: color ?? this.color,
    turns: turns ?? this.turns,
    setAtTurn: setAtTurn ?? this.setAtTurn,
    locked: locked ?? this.locked,
  );
}
