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

  // 背景粒子效果：null=神經網路碎片（默認）, 'stars'=星光, 'rain'=雨絲, 'firefly'=螢火蟲, 'leaf'=落葉, 'snow'=飄雪
  final String? bgEffect;

  // 可縮放氣泡框 PNG（疊在純色氣泡外層，null=不使用）
  final String? bubbleAiAsset;
  final String? bubbleUserAsset;

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
    this.bubbleAiAsset,
    this.bubbleUserAsset,
  });

  List<Color> get gradient => [bg1, bg2, bg3, bg4];
}

/// ═══════════════════════════════════
/// 8 亮 + 8 暗 — yanci
/// ═══════════════════════════════════

const presets = <ThemePreset>[
  // ── 亮色組（8）──
  dawnPreset, // 曦光
  ivoryPreset, // 象牙白
  snowPreset, // 初雪
  changAnPreset, // 長安
  bloomPreset, // 花信
  pinkPreset, // 玫瑰露
  sodaPreset, // 海鹽蘇打
  taroPreset, // 奶芋
  // ── 暗色組（8）──
  nightlampPreset, // 夜燈
  yanciPreset, // 未洗硯
  tidalPreset, // 潮汐
  icedPreset, // 冬夜
  mistPreset, // 迷霧
  neonPreset, // 街角
  blazePreset, // 燎
  neonPinkPreset, // 夜櫻
];

// ─── 1. 曦光（亮色默認）───
// 真正的黎明色階：地平線暖桃 → 玫瑰粉 → 藤紫 → 淺藍灰
const dawnPreset = ThemePreset(
  id: 'dawn',
  name: '曦光',
  subtitle: '清晨透進紗簾的光',
  isDark: false,
  bg1: Color(0xFFF2DDD0), // 地平線的暖桃光
  bg2: Color(0xFFECD4DC), // 天際的玫瑰粉
  bg3: Color(0xFFE0D4E4), // 中層淡藤紫
  bg4: Color(0xFFD8DCE8), // 高空的淺長春花藍
  aiBubble: Color(0xFFFAF6F3),
  userBubble: Color(0xFFEFE4EC),
  aiBubbleBorder: Color(0x28A090B0),
  userBubbleBorder: Color(0x28B8A0C0),
  textPrimary: Color(0xFF484050),
  textSecondary: Color(0xFF787080),
  textOnBubble: Color(0xFF464050),
  accent: Color(0xFF9680B4), // 藤花紫 — 清透明亮
  accentLight: Color(0xFFBCA8D0), // 淡藤光
  accentGlow: Color(0x28B098C0),
  glassWhite: Color(0x80FFFFFF),
  glassBorder: Color(0x40FFFFFF),
  glassInputBg: Color(0xB3FFFFFF),
  navBarBg: Color(0xE6F8F4F2),
  navInactive: Color(0xFF908898),
  starColor: Color(0x66E8E0F0),
  starGlow: Color(0x1CD8D0E0),
);

// ─── 2. 象牙白 ───
// 暖白底，霧藍點綴，像窗外透進來的一點天色
const ivoryPreset = ThemePreset(
  id: 'ivory',
  name: '象牙白',
  subtitle: '窗外透進來的一點天色',
  isDark: false,
  bg1: Color(0xFFFAF9F6),
  bg2: Color(0xFFF8F7F3),
  bg3: Color(0xFFF6F4EF),
  bg4: Color(0xFFFCFBF8),
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
  starColor: Color(0x66E6EAF0),
  starGlow: Color(0x1CEEF1F5),
);

// ─── 3. 初雪 ───
// 雪後的靜謐：世界被蒙上一層柔的白灰，只剩下很輕的淡藍影子
const snowPreset = ThemePreset(
  id: 'snow',
  name: '初雪',
  subtitle: '世界安靜下來的那一刻',
  isDark: false,
  bg1: Color(0xFFEAE6EA), // 雪面微光
  bg2: Color(0xFFE4E0E6), // 霜灰
  bg3: Color(0xFFDEDCE4), // 雪影
  bg4: Color(0xFFEEEAEE), // 新雪
  aiBubble: Color(0xFFF6F4F6),
  userBubble: Color(0xFFE6E2EC),
  aiBubbleBorder: Color(0x20687080),
  userBubbleBorder: Color(0x207882A0),
  textPrimary: Color(0xFF3C3E44),
  textSecondary: Color(0xFF6C6E76),
  textOnBubble: Color(0xFF3E4046),
  accent: Color(0xFF6878A0), // 冬霧藍 — 柔和的灰藍
  accentLight: Color(0xFF8898B8),
  accentGlow: Color(0x247888A8),
  glassWhite: Color(0x88FFFFFF),
  glassBorder: Color(0x48FFFFFF),
  glassInputBg: Color(0xC0FFFFFF),
  navBarBg: Color(0xE8F2F0F4),
  navInactive: Color(0xFF808690),
  starColor: Color(0x66F0EEF4),
  starGlow: Color(0x1CE8E6F0),
);

// ─── 4. 長安 ───
// 紫禁城紅牆：古調夯土底 + 朱紅城牆的氣泡
const changAnPreset = ThemePreset(
  id: 'changan',
  name: '長安',
  subtitle: '十二樓前的朱牆',
  isDark: false,
  bg1: Color(0xFFD6CCC0), // 夯土暖灰
  bg2: Color(0xFFD0C6BA),
  bg3: Color(0xFFCCC0B4),
  bg4: Color(0xFFDAD0C6),
  aiBubble: Color(0xFFEAE2D6),
  userBubble: Color(0xFFC4908A), // 紅牆
  aiBubbleBorder: Color(0x28A33026),
  userBubbleBorder: Color(0x38A33026),
  textPrimary: Color(0xFF3A302C),
  textSecondary: Color(0xFF6E6058),
  textOnBubble: Color(0xFF3A302C),
  accent: Color(0xFFA33026), // 朱紅
  accentLight: Color(0xFFC04838),
  accentGlow: Color(0x28A33026),
  glassWhite: Color(0x78FFFFFF),
  glassBorder: Color(0x38FFFFFF),
  glassInputBg: Color(0xB0EDE6DC),
  navBarBg: Color(0xE6DCD4CA),
  navInactive: Color(0xFF8A7870),
  starColor: Color(0x60C0785C), // 夯土上的朱砂印
  starGlow: Color(0x1CB0604A),
);

// ─── 5. 花信 ───
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
  starColor: Color(0x66E8D0E0),
  starGlow: Color(0x1CE0C8D8),
);

// ─── 6. 玫瑰露 ───
// 極淡的粉，像一滴玫瑰水暈開在白紙上
const pinkPreset = ThemePreset(
  id: 'blush',
  name: '玫瑰露',
  subtitle: '一滴暈開在指尖',
  isDark: false,
  bg1: Color(0xFFFAE8EC), // 極淡玫瑰奶
  bg2: Color(0xFFF5E2E8), // 霧粉
  bg3: Color(0xFFF0DDE4), // 柔腮
  bg4: Color(0xFFFCF2F4), // 近乎純白的粉
  aiBubble: Color(0xFFFDF8F8),
  userBubble: Color(0xFFF8ECF0),
  aiBubbleBorder: Color(0x20C88898),
  userBubbleBorder: Color(0x20D0A0A8),
  textPrimary: Color(0xFF504048),
  textSecondary: Color(0xFF887078),
  textOnBubble: Color(0xFF4C3840),
  accent: Color(0xFFC07888), // 清透玫瑰
  accentLight: Color(0xFFE0A8B8), // 花瓣粉
  accentGlow: Color(0x25D898A8),
  glassWhite: Color(0x85FFFFFF),
  glassBorder: Color(0x45FFFFFF),
  glassInputBg: Color(0xB8FFFFFF),
  navBarBg: Color(0xE8FDF8F8),
  navInactive: Color(0xFF9C8890),
  starColor: Color(0x66F0D8E0),
  starGlow: Color(0x1CE8D0D8),
);

// ─── 7. 海鹽蘇打 ───
// 海鹽氣泡水系：鹹甜交織的清透感
const sodaPreset = ThemePreset(
  id: 'soda',
  name: '海鹽蘇打',
  subtitle: '鹹鹹甜甜的氣泡',
  isDark: false,
  bg1: Color(0xFFD4ECE8), // 冰塊表面
  bg2: Color(0xFFC8E4E2), // 海鹽氣泡
  bg3: Color(0xFFBEDEDD), // 蘇打水深處
  bg4: Color(0xFFDAF0EC), // 杯口霧氣
  aiBubble: Color(0xFFF8FCFB),
  userBubble: Color(0xFFDCF0EA),
  aiBubbleBorder: Color(0x20388880),
  userBubbleBorder: Color(0x2050A098),
  textPrimary: Color(0xFF344240),
  textSecondary: Color(0xFF607470),
  textOnBubble: Color(0xFF364442),
  accent: Color(0xFF388880), // 氣泡水的透明青
  accentLight: Color(0xFF5AAAA0), // 海鹽亮光
  accentGlow: Color(0x2448A098),
  glassWhite: Color(0x85FFFFFF),
  glassBorder: Color(0x45FFFFFF),
  glassInputBg: Color(0xBAFFFFFF),
  navBarBg: Color(0xE8F2FAF8),
  navInactive: Color(0xFF788E8A),
  starColor: Color(0x66D8F0E8),
  starGlow: Color(0x1CC8E8E0),
);

// ─── 8. 奶芋 ───
// 馬卡龍×莫蘭迪：芋泥牛奶色調，灰紫的安靜感
const taroPreset = ThemePreset(
  id: 'taro',
  name: '奶芋',
  subtitle: '芋泥加了一點牛奶',
  isDark: false,
  bg1: Color(0xFFE4DDE6),
  bg2: Color(0xFFDED6E0),
  bg3: Color(0xFFD8D0DC),
  bg4: Color(0xFFE8E0EA),
  aiBubble: Color(0xFFF3F0F5),
  userBubble: Color(0xFFD0C8D6),
  aiBubbleBorder: Color(0x288C7696),
  userBubbleBorder: Color(0x228C7696),
  textPrimary: Color(0xFF443E4A),
  textSecondary: Color(0xFF726A78),
  textOnBubble: Color(0xFF443E4A),
  accent: Color(0xFF8C7696),
  accentLight: Color(0xFFA68EAE),
  accentGlow: Color(0x288C7696),
  glassWhite: Color(0x80FFFFFF),
  glassBorder: Color(0x40FFFFFF),
  glassInputBg: Color(0xB5FFFFFF),
  navBarBg: Color(0xE6EAE4EC),
  navInactive: Color(0xFF8A7E90),
  starColor: Color(0x55D0C0D8),
  starGlow: Color(0x1CC8B8D0),
);

// ─── 9. 夜燈（暗色默認）───
// 小屋熄了大燈之後，剩一盞燈黃
// 配色邏輯｜單光源，深紫黑底調，只有燈是彩色的
const nightlampPreset = ThemePreset(
  id: 'nightlamp',
  name: '夜燈',
  subtitle: '小屋熄燈後剩的那一盞',
  isDark: true,
  bg1: Color(0xFF110F18), // 深紫黑
  bg2: Color(0xFF140F1C),
  bg3: Color(0xFF171220), // 燈暈
  bg4: Color(0xFF0F0D16), // 牆角
  aiBubble: Color(0xFF2A2238),
  userBubble: Color(0xFF221F34),
  aiBubbleBorder: Color(0x40F2C96D),
  userBubbleBorder: Color(0x28A096B4),
  textPrimary: Color(0xFFD9D4DE),
  textSecondary: Color(0xFF8A8098),
  textOnBubble: Color(0xFFD9D4DE),
  accent: Color(0xFFF2C96D), // 燈黃
  accentLight: Color(0xFFF8DA88),
  accentGlow: Color(0x38F2C96D),
  glassWhite: Color(0x20000000),
  glassBorder: Color(0x18FFFFFF),
  glassInputBg: Color(0xB0140F1C),
  navBarBg: Color(0xE6110F18),
  navInactive: Color(0xFF605878),
  starColor: Color(0x55F2C96D),
  starGlow: Color(0x18F2C96D),
);

// ─── 10. 未洗硯 ───
// 水墨落完、硯台沒洗、窗外月亮很白
// 配色邏輯｜五個種子角色：
//   base＝冷黑紙面、surface＝未乾墨面、ink＝月白字色、
//   accent＝窗外灰藍月光、mist＝硯邊薄霧。
//   大面積維持低彩度；灰藍只落在選中、邊緣與微光，避免整頁發藍。
const yanciPreset = ThemePreset(
  id: 'yanci',
  name: '未洗硯',
  subtitle: '寫完最後一筆沒有收',
  isDark: true,
  bg1: Color(0xFF121214),
  bg2: Color(0xFF151517),
  bg3: Color(0xFF18181B),
  bg4: Color(0xFF111113),
  aiBubble: Color(0xFF1E1E22),
  userBubble: Color(0xFF1A1C22),
  aiBubbleBorder: Color(0x30787880),
  userBubbleBorder: Color(0x28646E7A),
  textPrimary: Color(0xFFD8D6D2),
  textSecondary: Color(0xFF6E6C68),
  textOnBubble: Color(0xFFD4D2CE),
  accent: Color(0xFF8A9AAE),
  accentLight: Color(0xFFA0B0C4),
  accentGlow: Color(0x2A8A9AAE),
  glassWhite: Color(0x14000000),
  glassBorder: Color(0x10FFFFFF),
  glassInputBg: Color(0xC0151517),
  navBarBg: Color(0xF0121214),
  navInactive: Color(0xFF4A4A4E),
  starColor: Color(0x30D8D6D2),
  starGlow: Color(0x0ED8D6D2),
);

// ─── 11. 潮汐 ───
// 深海青綠，退潮留下的水光
const tidalPreset = ThemePreset(
  id: 'tidal',
  name: '潮汐',
  subtitle: '退潮後沙灘上的水痕',
  isDark: true,
  bg1: Color(0xFF0E1219),
  bg2: Color(0xFF101420),
  bg3: Color(0xFF0C1018),
  bg4: Color(0xFF0F131B),
  aiBubble: Color(0xFF162028),
  userBubble: Color(0xFF141D26),
  aiBubbleBorder: Color(0x385EAAA0),
  userBubbleBorder: Color(0x2C5EAAA0),
  textPrimary: Color(0xFFC8CED5),
  textSecondary: Color(0xFF6E7E88),
  textOnBubble: Color(0xFFC8CFD5),
  accent: Color(0xFF5EAAA0), // 青綠潮水
  accentLight: Color(0xFF78C0B6),
  accentGlow: Color(0x305EAAA0),
  glassWhite: Color(0x1A000000),
  glassBorder: Color(0x14FFFFFF),
  glassInputBg: Color(0xB00E1219),
  navBarBg: Color(0xE60C1018),
  navInactive: Color(0xFF4A6060),
  starColor: Color(0x505EAAA0),
  starGlow: Color(0x185EAAA0),
);

// ─── 12. 冬夜 ───
// 深藍灰底 × 深潭的沉，比原版更冷更深
const icedPreset = ThemePreset(
  id: 'iced',
  name: '冬夜',
  subtitle: '清冷透亮的神經碎片',
  isDark: true,
  bg1: Color(0xFF0C0E16),
  bg2: Color(0xFF0E1018),
  bg3: Color(0xFF0B0D14),
  bg4: Color(0xFF0D0F17),
  aiBubble: Color(0xFF161A28),
  userBubble: Color(0xFF141830),
  aiBubbleBorder: Color(0x386094D0),
  userBubbleBorder: Color(0x305078B4),
  textPrimary: Color(0xFFC5C9D3),
  textSecondary: Color(0xFF6A7284),
  textOnBubble: Color(0xFFC5C9D3),
  accent: Color(0xFF6094D0),
  accentLight: Color(0xFF78AAE0),
  accentGlow: Color(0x306094D0),
  glassWhite: Color(0x18000000),
  glassBorder: Color(0x14FFFFFF),
  glassInputBg: Color(0xB00C0E16),
  navBarBg: Color(0xE60B0D14),
  navInactive: Color(0xFF4C5670),
  starColor: Color(0x606094D0),
  starGlow: Color(0x1C6094D0),
);

// ─── 13. 迷霧 ───
// 紫灰調，像凌晨四點的霧
const mistPreset = ThemePreset(
  id: 'mist',
  name: '迷霧',
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
  starColor: Color(0x66D0C0E8),
  starGlow: Color(0x1CD0C0E8),
);

// ─── 14. 街角 ───
// 柏油路上的積水剛好映出街口綠燈
const neonPreset = ThemePreset(
  id: 'neon',
  name: '街角',
  subtitle: '柏油路上的積水剛好映出街口綠燈',
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
  textOnBubble: Color(0xFFE9E7F5),
  accent: Color(0xFF00E5D4),
  accentLight: Color(0xFF55F0E2),
  accentGlow: Color(0x4000E5D4),
  glassWhite: Color(0x30000000),
  glassBorder: Color(0x24FF3E8E),
  glassInputBg: Color(0xB0151226),
  navBarBg: Color(0xE60E0C18),
  navInactive: Color(0xFF6A6390),
  starColor: Color(0x6600E5D4),
  starGlow: Color(0x1CFF3E8E),
);

// ─── 15. 燎 ───
// 純黑底＋橙焰，營火熄了只剩最後一點餘燼
const blazePreset = ThemePreset(
  id: 'blaze',
  name: '燎',
  subtitle: '餘燼裡最後一點橙光',
  isDark: true,
  bg1: Color(0xFF0D0B0A),
  bg2: Color(0xFF100E0C),
  bg3: Color(0xFF0B0908),
  bg4: Color(0xFF0E0C0B),
  aiBubble: Color(0xFF1C1610),
  userBubble: Color(0xFF181210),
  aiBubbleBorder: Color(0x3CE48438),
  userBubbleBorder: Color(0x28C87830),
  textPrimary: Color(0xFFCBC5BF),
  textSecondary: Color(0xFF8A7E72),
  textOnBubble: Color(0xFFCBC5BF),
  accent: Color(0xFFE48438), // 餘燼橙
  accentLight: Color(0xFFF09850),
  accentGlow: Color(0x38E48438),
  glassWhite: Color(0x1A000000),
  glassBorder: Color(0x14FFFFFF),
  glassInputBg: Color(0xB00D0B0A),
  navBarBg: Color(0xE60B0908),
  navInactive: Color(0xFF685840),
  starColor: Color(0x50E48438),
  starGlow: Color(0x18E48438),
);

// ─── 16. 夜櫻 ───
// 長夜無聲，落櫻微光。
const neonPinkPreset = ThemePreset(
  id: 'neonpink',
  name: '夜櫻',
  subtitle: '長夜無聲，落櫻微光。',
  isDark: true,
  bg1: Color(0xFF0D0A0C),
  bg2: Color(0xFF100C0E),
  bg3: Color(0xFF0B090A),
  bg4: Color(0xFF0E0B0D),
  aiBubble: Color(0xFF1E1018),
  userBubble: Color(0xFF1A0C14),
  aiBubbleBorder: Color(0x48EE648C),
  userBubbleBorder: Color(0x30DC5A82),
  textPrimary: Color(0xFFCBC1C5),
  textSecondary: Color(0xFF8A7680),
  textOnBubble: Color(0xFFCBC0C5),
  accent: Color(0xFFEE648C), // 霓虹粉
  accentLight: Color(0xFFF880A0),
  accentGlow: Color(0x40EE648C),
  glassWhite: Color(0x1A000000),
  glassBorder: Color(0x16FFFFFF),
  glassInputBg: Color(0xB00D0A0C),
  navBarBg: Color(0xE60B090A),
  navInactive: Color(0xFF6E5060),
  starColor: Color(0x55EE648C),
  starGlow: Color(0x1CEE648C),
);

/// 根據 ID 查找預設
ThemePreset findPreset(String id) {
  if (id == swallowPreset.id) return swallowPreset;
  return presets.firstWhere((p) => p.id == id, orElse: () => presets[0]);
}

// ─── 春·燕（季節×動物特色主題）───
// 雨後青瓦的色調，燕子歸巢的春天
const swallowPreset = ThemePreset(
  id: 'swallow',
  name: '春·燕',
  subtitle: '燕子歸來的雨後',
  isDark: false,
  bg1: Color(0xFFE4DDD6), // 青瓦暖灰
  bg2: Color(0xFFDDD8D4), // 泥牆灰米
  bg3: Color(0xFFD6D4D8), // 雨後霧藍灰
  bg4: Color(0xFFE0DDD8), // 屋簷下的柔光
  aiBubble: Color(0xFFF6F4F2), // 羽白
  userBubble: Color(0xFFE8E0D6), // 巢泥暖棕
  aiBubbleBorder: Color(0x18506878),
  userBubbleBorder: Color(0x18786050),
  textPrimary: Color(0xFF3A3836),
  textSecondary: Color(0xFF6A6460),
  textOnBubble: Color(0xFF3C3A38),
  accent: Color(0xFF8B5E4B), // 銹紅——燕子腹羽
  accentLight: Color(0xFFB08470),
  accentGlow: Color(0x20906858),
  glassWhite: Color(0x80FFFFFF),
  glassBorder: Color(0x40FFFFFF),
  glassInputBg: Color(0xB5FFFFFF),
  navBarBg: Color(0xE8F0EDEA),
  navInactive: Color(0xFF8A8480),
  starColor: Color(0x66D8D0C8),
  starGlow: Color(0x1CD0C8C0),
  bgEffect: 'rain',
  bubbleAiAsset: 'assets/bubbles/swallow/ai.png',
  bubbleUserAsset: 'assets/bubbles/swallow/user.png',
);
