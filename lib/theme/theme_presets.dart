import 'package:flutter/material.dart';

/// 主題預設 — 每套定義完整的色彩系統
class ThemePreset {
  final String id;
  final String name;
  final String subtitle;
  final bool isDark;

  // 背景漸變（四色）
  final Color bg1, bg2, bg3, bg4;

  // 氣泡
  final Color aiBubble, userBubble;
  final Color aiBubbleBorder, userBubbleBorder;

  // 文字
  final Color textPrimary, textSecondary, textOnBubble;

  // 強調色
  final Color accent, accentLight, accentGlow;

  // 毛玻璃
  final Color glassWhite, glassBorder, glassInputBg;

  // 導航
  final Color navBarBg, navInactive;

  // 星光
  final Color starColor, starGlow;

  // 氣泡漸變（可選，設了就用漸變代替純色）
  final Color? aiBubbleTop;

  // 背景粒子效果：null=神經網路碎片（默認）, 'stars'=星光
  final String? bgEffect;

  const ThemePreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.isDark,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bg4,
    required this.aiBubble,
    required this.userBubble,
    required this.aiBubbleBorder,
    required this.userBubbleBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textOnBubble,
    required this.accent,
    required this.accentLight,
    required this.accentGlow,
    required this.glassWhite,
    required this.glassBorder,
    required this.glassInputBg,
    required this.navBarBg,
    required this.navInactive,
    required this.starColor,
    required this.starGlow,
    this.aiBubbleTop,
    this.bgEffect,
  });

  List<Color> get gradient => [bg1, bg2, bg3, bg4];
}

/// ═══════════════════════════════════
/// 七套主題 — yanci
/// ═══════════════════════════════════

const presets = <ThemePreset>[
  // ── 亮色組 ──
  dawnPreset,
  ivoryPreset,
  snowPreset,
  lattePreset,
  bloomPreset,
  pinkPreset,
  sodaPreset,
  // ── 暗色組 ──
  midnightPreset,
  nightlampPreset,
  tipsyPreset,
  mistPreset,
  bambooPreset,
  icedPreset,
  neonPreset,
];

// ─── 1. 晨光（亮色默認）───
// 真正的黎明色階：地平線暖桃 → 玫瑰粉 → 藤紫 → 淺藍灰
const dawnPreset = ThemePreset(
  id: 'dawn',
  name: '晨光',
  subtitle: '清晨透進紗簾的光',
  isDark: false,
  bg1: Color(0xFFF2DDD0),  // 地平線的暖桃光
  bg2: Color(0xFFECD4DC),  // 天際的玫瑰粉
  bg3: Color(0xFFE0D4E4),  // 中層淡藤紫
  bg4: Color(0xFFD8DCE8),  // 高空的淺長春花藍
  aiBubble: Color(0xFFFAF6F3),
  userBubble: Color(0xFFEFE4EC),
  aiBubbleBorder: Color(0x28A090B0),
  userBubbleBorder: Color(0x28B8A0C0),
  textPrimary: Color(0xFF484050),
  textSecondary: Color(0xFF787080),
  textOnBubble: Color(0xFF464050),
  accent: Color(0xFF9680B4),      // 藤花紫 — 清透明亮
  accentLight: Color(0xFFBCA8D0),  // 淡藤光
  accentGlow: Color(0x28B098C0),
  glassWhite: Color(0x80FFFFFF),
  glassBorder: Color(0x40FFFFFF),
  glassInputBg: Color(0xB3FFFFFF),
  navBarBg: Color(0xE6F8F4F2),
  navInactive: Color(0xFF908898),
  starColor: Color(0xBBE8E0F0),
  starGlow: Color(0x35D8D0E0),
);

// ─── 2. 深夜書房（暗色默認）───
// 同一個房間入了夜，琥珀金壓暗一階
const midnightPreset = ThemePreset(
  id: 'midnight',
  name: '深夜書房',
  subtitle: '同一個房間入了夜',
  isDark: true,
  bg1: Color(0xFF2A2028),
  bg2: Color(0xFF252030),
  bg3: Color(0xFF1E2530),
  bg4: Color(0xFF1C2628),
  // 氣泡回歸背景的紫黑同族（舊版棕調混紫底發髒）；
  // 琥珀感交給邊框和 accent 點綴
  aiBubble: Color(0xFF423A4A),
  userBubble: Color(0xFF2E3542),
  aiBubbleBorder: Color(0x48B8855C),
  userBubbleBorder: Color(0x38A080B0),
  textPrimary: Color(0xFFE8E0D8),
  textSecondary: Color(0xFF918C88),
  textOnBubble: Color(0xFFD8D0C8),
  accent: Color(0xFFB8855C),
  accentLight: Color(0xFFC49570),
  accentGlow: Color(0x40B8855C),
  glassWhite: Color(0x30000000),
  glassBorder: Color(0x20FFFFFF),
  glassInputBg: Color(0xB3252228),
  navBarBg: Color(0xE6201E22),
  navInactive: Color(0xFF706767),
  starColor: Color(0xDDEEDDCC),
  starGlow: Color(0x60EEDDCC),
);

// ─── 3. 墨竹 ───
// 深綠墨灰，竹林裡的書齋
const bambooPreset = ThemePreset(
  id: 'bamboo',
  name: '墨竹',
  subtitle: '竹林裡的書齋',
  isDark: true,
  bg1: Color(0xFF1A2420),
  bg2: Color(0xFF1C2822),
  bg3: Color(0xFF1E2A24),
  bg4: Color(0xFF1A2620),
  aiBubble: Color(0xFF384338),
  userBubble: Color(0xFF273A40),
  aiBubbleBorder: Color(0x387AA06A),
  userBubbleBorder: Color(0x38608050),
  textPrimary: Color(0xFFD0D8CC),
  textSecondary: Color(0xFF8A9282),
  textOnBubble: Color(0xFFC8D0C0),
  accent: Color(0xFF7AA06A),
  accentLight: Color(0xFF8AB87A),
  accentGlow: Color(0x307AA06A),
  glassWhite: Color(0x25000000),
  glassBorder: Color(0x18FFFFFF),
  glassInputBg: Color(0xB0202820),
  navBarBg: Color(0xE61A2420),
  navInactive: Color(0xFF5F7155),
  starColor: Color(0xAAC0D8B0),
  starGlow: Color(0x40C0D8B0),
);

// ─── 4. 象牙白 ───
// 暖白底，霧藍點綴，像窗外透進來的一點天色
const ivoryPreset = ThemePreset(
  id: 'ivory',
  name: '象牙白',
  subtitle: '窗外透進來的一點天色',
  isDark: false,
  bg1: Color(0xFFF5F3EE),
  bg2: Color(0xFFF2F0EA),
  bg3: Color(0xFFEFEDE6),
  bg4: Color(0xFFF7F5F0),
  aiBubble: Color(0xFFFBFAF7),
  userBubble: Color(0xFFCBD7EA),
  aiBubbleBorder: Color(0x388B9DB5),
  userBubbleBorder: Color(0x38A0AEC0),
  textPrimary: Color(0xFF2E3038),
  textSecondary: Color(0xFF525960),
  textOnBubble: Color(0xFF343840),
  accent: Color(0xFF5D7492),
  accentLight: Color(0xFFA0B0C4),
  accentGlow: Color(0x258B9DB5),
  glassWhite: Color(0x88FFFFFF),
  glassBorder: Color(0x48FFFFFF),
  glassInputBg: Color(0xB8FFFFFF),
  navBarBg: Color(0xE8FDFCFA),
  navInactive: Color(0xFF878F9A),
  starColor: Color(0x80D8DDE8),
  starGlow: Color(0x28D8DDE8),
);

// ─── 6. 霧紫 ───
// 紫灰調，像凌晨四點的霧
const mistPreset = ThemePreset(
  id: 'mist',
  name: '霧紫',
  subtitle: '凌晨四點的霧',
  isDark: true,
  bg1: Color(0xFF2A2035),
  bg2: Color(0xFF28203A),
  bg3: Color(0xFF242040),
  bg4: Color(0xFF202838),
  aiBubble: Color(0xFF4B385B),
  userBubble: Color(0xFF333A58),
  aiBubbleBorder: Color(0x38A080C0),
  userBubbleBorder: Color(0x388070A0),
  textPrimary: Color(0xFFD8D0E0),
  textSecondary: Color(0xFF938CA9),
  textOnBubble: Color(0xFFD0C8D8),
  accent: Color(0xFFA080C0),
  accentLight: Color(0xFFB090D0),
  accentGlow: Color(0x35A080C0),
  glassWhite: Color(0x28000000),
  glassBorder: Color(0x18FFFFFF),
  glassInputBg: Color(0xB0282030),
  navBarBg: Color(0xE6252030),
  navInactive: Color(0xFF736888),
  starColor: Color(0xBBD0C0E8),
  starGlow: Color(0x50D0C0E8),
);

/// 根據 ID 查找預設
ThemePreset findPreset(String id) {
  return presets.firstWhere((p) => p.id == id, orElse: () => presets[0]);
}

// ─── 8. 花信 ───
// 淡紫裡的粉玫瑰和康乃馨
const bloomPreset = ThemePreset(
  id: 'bloom',
  name: '花信',
  subtitle: '淡紫裡的粉玫瑰',
  isDark: false,
  bg1: Color(0xFFDCC9E7),
  bg2: Color(0xFFD6C2E2),
  bg3: Color(0xFFD1BCDD),
  bg4: Color(0xFFE0CEEA),
  aiBubble: Color(0xFFF9F4F5),
  aiBubbleTop: Color(0xFFF2D0DA),
  userBubble: Color(0xFFEFE4F8),
  aiBubbleBorder: Color(0x38C87C90),
  userBubbleBorder: Color(0x38B090C0),
  textPrimary: Color(0xFF504050),
  textSecondary: Color(0xFF584D58),
  textOnBubble: Color(0xFF483848),
  accent: Color(0xFFAD4963),
  accentLight: Color(0xFFD48C9E),
  accentGlow: Color(0x28C87C90),
  glassWhite: Color(0x85FFFFFF),
  glassBorder: Color(0x42FFFFFF),
  glassInputBg: Color(0xB5FFFFFF),
  navBarBg: Color(0xE6F8F0F8),
  navInactive: Color(0xFF978297),
  starColor: Color(0xBBE8D0E0),
  starGlow: Color(0x35E0C8D8),
);

// ─── 9. 冬夜 ───
// 深藍灰底，清冷透亮，冬天的夜晚
const icedPreset = ThemePreset(
  id: 'iced',
  name: '冬夜',
  subtitle: '清冷透亮的神經碎片',
  isDark: true,
  bg1: Color(0xFF161A22),
  bg2: Color(0xFF1A1E28),
  bg3: Color(0xFF141820),
  bg4: Color(0xFF181C24),
  aiBubble: Color(0xFF323A46),
  userBubble: Color(0xFF2A2E4E),
  aiBubbleBorder: Color(0x3870A0C8),
  userBubbleBorder: Color(0x3860A0D0),
  textPrimary: Color(0xFFD8DDE5),
  textSecondary: Color(0xFF808896),
  textOnBubble: Color(0xFFD0D8E0),
  accent: Color(0xFF68A8D8),
  accentLight: Color(0xFF80B8E0),
  accentGlow: Color(0x3068A8D8),
  glassWhite: Color(0x18FFFFFF),
  glassBorder: Color(0x15FFFFFF),
  glassInputBg: Color(0xB0181C24),
  navBarBg: Color(0xE6141820),
  navInactive: Color(0xFF5C667A),
  starColor: Color(0xCC90C0E8),
  starGlow: Color(0x4080B0D8),
);

// ─── 11. 夜燈 ───
// YANCI-32 同源：像素小屋熄了大燈之後，剩一盞燈黃
const nightlampPreset = ThemePreset(
  id: 'nightlamp',
  name: '夜燈',
  subtitle: '小屋熄燈後剩的那一盞',
  isDark: true,
  bg1: Color(0xFF1A1721),
  bg2: Color(0xFF1E1A26),
  bg3: Color(0xFF221D2B),
  bg4: Color(0xFF1C1823),
  aiBubble: Color(0xFF3F354E),
  userBubble: Color(0xFF2E2C48),
  aiBubbleBorder: Color(0x48C99A4B),
  userBubbleBorder: Color(0x38948DA1),
  textPrimary: Color(0xFFEFEAF2),
  textSecondary: Color(0xFF9C95AB),
  textOnBubble: Color(0xFFEFEAF2),
  accent: Color(0xFFF2C96D),
  accentLight: Color(0xFFF7D98D),
  accentGlow: Color(0x40F2C96D),
  glassWhite: Color(0x30000000),
  glassBorder: Color(0x20FFFFFF),
  glassInputBg: Color(0xB0221D2B),
  navBarBg: Color(0xE61A1721),
  navInactive: Color(0xFF7A7390),
  starColor: Color(0xCCF2C96D),
  starGlow: Color(0x40F2C96D),
);

// ─── 12. 微醺 ───
// 暗酒紅，毛衣那件的顏色，一杯之後的體溫
const tipsyPreset = ThemePreset(
  id: 'tipsy',
  name: '微醺',
  subtitle: '一杯之後的體溫',
  isDark: true,
  bg1: Color(0xFF2A1D20),
  bg2: Color(0xFF2E1F23),
  bg3: Color(0xFF261A1E),
  bg4: Color(0xFF301F24),
  aiBubble: Color(0xFF4F353D),
  userBubble: Color(0xFF3A2C42),
  aiBubbleBorder: Color(0x48E8A08A),
  userBubbleBorder: Color(0x38C08890),
  textPrimary: Color(0xFFF0E4E0),
  textSecondary: Color(0xFFA9908F),
  textOnBubble: Color(0xFFEEDFDC),
  accent: Color(0xFFE8A08A),
  accentLight: Color(0xFFF0B09A),
  accentGlow: Color(0x40E8A08A),
  glassWhite: Color(0x2E000000),
  glassBorder: Color(0x1EFFFFFF),
  glassInputBg: Color(0xB02A1D20),
  navBarBg: Color(0xE6261A1E),
  navInactive: Color(0xFF87716F),
  starColor: Color(0xBBF0C0B0),
  starGlow: Color(0x40F0C0B0),
);

// ─── 13. 初雪 ───
// 雪後的靜謐：世界被蒙上一層柔的白灰，只剩下很輕的淡藍影子
const snowPreset = ThemePreset(
  id: 'snow',
  name: '初雪',
  subtitle: '世界安靜下來的那一刻',
  isDark: false,
  bg1: Color(0xFFEAE6EA),  // 雪面微光
  bg2: Color(0xFFE4E0E6),  // 霜灰
  bg3: Color(0xFFDEDCE4),  // 雪影
  bg4: Color(0xFFEEEAEE),  // 新雪
  aiBubble: Color(0xFFF6F4F6),
  userBubble: Color(0xFFE6E2EC),
  aiBubbleBorder: Color(0x20687080),
  userBubbleBorder: Color(0x207882A0),
  textPrimary: Color(0xFF3C3E44),
  textSecondary: Color(0xFF6C6E76),
  textOnBubble: Color(0xFF3E4046),
  accent: Color(0xFF6878A0),      // 冬霧藍 — 柔和的灰藍
  accentLight: Color(0xFF8898B8),
  accentGlow: Color(0x247888A8),
  glassWhite: Color(0x88FFFFFF),
  glassBorder: Color(0x48FFFFFF),
  glassInputBg: Color(0xC0FFFFFF),
  navBarBg: Color(0xE8F2F0F4),
  navInactive: Color(0xFF808690),
  starColor: Color(0xBBF0EEF4),
  starGlow: Color(0x30E8E6F0),
);

// ─── 14. 卡布奇諾 ───
// 俯瞰咖啡杯：奶泡 → 拉花旋渦 → 咖啡環 → 杯緣奶沫
const lattePreset = ThemePreset(
  id: 'latte',
  name: '卡布奇諾',
  subtitle: '奶泡上的一圈拉花',
  isDark: false,
  bg1: Color(0xFFF2EAE0),  // 杯心奶泡
  bg2: Color(0xFFE0D2C4),  // 拉花交界
  bg3: Color(0xFFD4C4B4),  // 咖啡旋渦
  bg4: Color(0xFFEDE2D8),  // 杯緣奶沫
  aiBubble: Color(0xFFFAF6F0),     // 鮮奶泡白
  userBubble: Color(0xFFEDE0D2),   // 焦糖奶霜
  aiBubbleBorder: Color(0x08886050),   // 近乎無邊框
  userBubbleBorder: Color(0x08907060), // 近乎無邊框
  textPrimary: Color(0xFF4A4240),
  textSecondary: Color(0xFF7A706A),
  textOnBubble: Color(0xFF484040),
  accent: Color(0xFF8C6E5E),      // 冷調濃縮咖啡
  accentLight: Color(0xFFB09080),  // 烘焙淡棕
  accentGlow: Color(0x20A08070),
  glassWhite: Color(0x78FFFFFF),
  glassBorder: Color(0x38FFFFFF),
  glassInputBg: Color(0xB0FFF8F0),
  navBarBg: Color(0xE6F5EFE8),
  navInactive: Color(0xFF988E86),
  starColor: Color(0x80E8DCD0),
  starGlow: Color(0x20E0D4C8),
);

// ─── 10. 玫瑰露 ───
// 極淡的粉，像一滴玫瑰水暈開在白紙上
const pinkPreset = ThemePreset(
  id: 'blush',
  name: '玫瑰露',
  subtitle: '一滴暈開在指尖',
  isDark: false,
  bg1: Color(0xFFFAE8EC),  // 極淡玫瑰奶
  bg2: Color(0xFFF5E2E8),  // 霧粉
  bg3: Color(0xFFF0DDE4),  // 柔腮
  bg4: Color(0xFFFCF2F4),  // 近乎純白的粉
  aiBubble: Color(0xFFFDF8F8),
  userBubble: Color(0xFFF8ECF0),
  aiBubbleBorder: Color(0x20C88898),
  userBubbleBorder: Color(0x20D0A0A8),
  textPrimary: Color(0xFF504048),
  textSecondary: Color(0xFF887078),
  textOnBubble: Color(0xFF4C3840),
  accent: Color(0xFFC07888),      // 清透玫瑰
  accentLight: Color(0xFFE0A8B8),  // 花瓣粉
  accentGlow: Color(0x25D898A8),
  glassWhite: Color(0x85FFFFFF),
  glassBorder: Color(0x45FFFFFF),
  glassInputBg: Color(0xB8FFFFFF),
  navBarBg: Color(0xE8FDF8F8),
  navInactive: Color(0xFF9C8890),
  starColor: Color(0x90F0D8E0),
  starGlow: Color(0x28E8D0D8),
);

// ─── 薄荷氣泡 ───
// 氣泡水系：薄荷冰沙加一片萊姆，氣泡正在往上竄
const sodaPreset = ThemePreset(
  id: 'soda',
  name: '薄荷氣泡',
  subtitle: '氣泡正在往上竄',
  isDark: false,
  bg1: Color(0xFFD4ECE8),  // 冰塊表面
  bg2: Color(0xFFC8E4E2),  // 薄荷冰沙
  bg3: Color(0xFFBEDEDD),  // 蘇打水深處
  bg4: Color(0xFFDAF0EC),  // 杯口霧氣
  aiBubble: Color(0xFFF8FCFB),
  userBubble: Color(0xFFDCF0EA),
  aiBubbleBorder: Color(0x20388880),
  userBubbleBorder: Color(0x2050A098),
  textPrimary: Color(0xFF344240),
  textSecondary: Color(0xFF607470),
  textOnBubble: Color(0xFF364442),
  accent: Color(0xFF388880),      // 氣泡水的透明青
  accentLight: Color(0xFF5AAAA0),  // 薄荷亮光
  accentGlow: Color(0x2448A098),
  glassWhite: Color(0x85FFFFFF),
  glassBorder: Color(0x45FFFFFF),
  glassInputBg: Color(0xBAFFFFFF),
  navBarBg: Color(0xE8F2FAF8),
  navInactive: Color(0xFF788E8A),
  starColor: Color(0x90D8F0E8),
  starGlow: Color(0x28C8E8E0),
);

// ─── 霓虹雨 ───
// 賽博龐克：深藍紫的雨夜，氰青和品紅的霓虹倒影
const neonPreset = ThemePreset(
  id: 'neon',
  name: '霓虹雨',
  subtitle: '雨夜霓虹落在傘面上',
  isDark: true,
  bg1: Color(0xFF12101E),
  bg2: Color(0xFF151226),
  bg3: Color(0xFF0E0C18),
  bg4: Color(0xFF171430),
  aiBubble: Color(0xFF342B5B),
  userBubble: Color(0xFF152F3A),
  aiBubbleBorder: Color(0x50FF3E8E),
  userBubbleBorder: Color(0x4000E5D4),
  textPrimary: Color(0xFFE9E7F5),
  textSecondary: Color(0xFF938DB5),
  textOnBubble: Color(0xFFEDEBF8),
  accent: Color(0xFF00E5D4),
  accentLight: Color(0xFF55F0E2),
  accentGlow: Color(0x4000E5D4),
  glassWhite: Color(0x30000000),
  glassBorder: Color(0x24FF3E8E),
  glassInputBg: Color(0xB0151226),
  navBarBg: Color(0xE60E0C18),
  navInactive: Color(0xFF6A6390),
  starColor: Color(0xCC00E5D4),
  starGlow: Color(0x50FF3E8E),
);
