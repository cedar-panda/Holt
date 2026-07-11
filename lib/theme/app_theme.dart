import 'package:flutter/material.dart';
import 'theme_presets.dart';

/// Project Yanci 設計系統 — 主題預設驅動
class YanciTheme {
  static ThemePreset _preset = presets[0]; // 默認「晨光」
  static String _fontChinese = 'Lora';
  static String _fontEnglish = 'LXGW WenKai TC';
  static double _fontScale = 1.0;

  // 自定義微調（覆蓋 preset）
  static double bubbleOpacity = 1.0;

  /// 氣泡明度微調 -1.0 ~ 1.0，實際偏移限幅 ±6% 明度。
  /// 限幅是有意的：全部主題的文字對比都是按 WCAG AA 校過的，
  /// 給無限滑桿等於發一把能把可讀性調碎的錘子。±6% 內最差對比仍 >4.5。
  static double bubbleBrightness = 0.0;
  static double bubbleRadius = 20.0;
  static double bubbleRadiusUser = 16.0;
  static bool starEnabled = true;
  static int starDensity = 12; // 粒子數
  static String homeBackgroundImagePath = '';
  static double homeBackgroundImageScale = 1.0;
  static double homeBackgroundImageOffsetX = 0.0;
  static double homeBackgroundImageOffsetY = 0.0;
  static String chatBackgroundImagePath = '';
  static double chatBackgroundImageScale = 1.0;
  static double chatBackgroundImageOffsetX = 0.0;
  static double chatBackgroundImageOffsetY = 0.0;

  // ═══ Getters ═══
  static ThemePreset get preset => _preset;
  static String get presetId => _preset.id;
  static bool get isDark => _preset.isDark;
  static String get fontChinese => _fontChinese;
  static String get fontEnglish => _fontEnglish;
  static double get fontScale => _fontScale;

  // ═══ Setters ═══
  static void setPreset(String id) => _preset = findPreset(id);
  static void setFont(String cn, String en) {
    _fontChinese = cn;
    _fontEnglish = en;
  }

  static void setFontScale(double v) => _fontScale = v;

  // 兼容舊代碼
  static void setDark(bool v) {
    // 如果當前 preset 的明暗不對，切到默認暗/亮
    if (v && !_preset.isDark) setPreset('nightlamp');
    if (!v && _preset.isDark) setPreset('ivory');
  }

  // ═══════════════════════════════════
  // 顏色（全部從 preset 讀）
  // ═══════════════════════════════════

  static Color get bgPink => _preset.bg1;
  static Color get bgLavender => _preset.bg2;
  static Color get bgSkyBlue => _preset.bg3;
  static Color get bgMint => _preset.bg4;
  static List<Color> get backgroundGradient => _preset.gradient;

  /// 氣泡明度偏移（見 bubbleBrightness 註釋）
  static Color _shiftBubble(Color c) {
    if (bubbleBrightness == 0) return c;
    final hsl = HSLColor.fromColor(c);
    final l = (hsl.lightness + bubbleBrightness * 0.06).clamp(0.0, 1.0);
    return hsl.withLightness(l).toColor();
  }

  static Color get aiBubble =>
      _shiftBubble(_preset.aiBubble).withValues(alpha: bubbleOpacity);
  static Color get userBubble =>
      _shiftBubble(_preset.userBubble).withValues(alpha: bubbleOpacity);

  /// AI 氣泡漸變（頂粉→底白），null 則純色
  static Gradient? get aiBubbleGradient {
    if (_preset.aiBubbleTop == null) return null;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        _shiftBubble(_preset.aiBubbleTop!).withValues(alpha: bubbleOpacity),
        _shiftBubble(_preset.aiBubble).withValues(alpha: bubbleOpacity),
      ],
    );
  }

  static Color get aiBubbleBorder => _preset.aiBubbleBorder;
  static String? get bgEffect => _preset.bgEffect;
  static Color get userBubbleBorder => _preset.userBubbleBorder;

  static Color get textPrimary => _preset.textPrimary;
  static Color get textSecondary => _preset.textSecondary;
  static Color get textAccent => accent;
  static Color get textOnBubble => _preset.textOnBubble;

  static Color get accent => _preset.accent;
  static Color get accentLight => _preset.accentLight;
  static Color get accentGlow => _preset.accentGlow;

  static Color get glassWhite => _preset.glassWhite;
  static Color get glassBorder => _preset.glassBorder;
  static Color get glassInputBg => _preset.glassInputBg;

  static Color get navBarBg => _preset.navBarBg;
  static Color get navActive => accent;
  static Color get navInactive => _preset.navInactive;

  static Color get starColor => _preset.starColor;
  static Color get starGlow => _preset.starGlow;

  // ═══════════════════════════════════
  // 衍生色（配色協調層）
  // ═══════════════════════════════════

  /// 面板/列表底色 — 跟隨明暗，取代寫死的 Colors.white
  /// （暗色主題下白底配淺色字會直接不可讀）
  static Color get surfacePanel => isDark
      ? _preset.navBarBg.withValues(alpha: 0.96)
      : Colors.white.withValues(alpha: 0.92);

  /// 心電圖主線 — 與背景拉開對比，但留在主題色系內：
  /// 暗色 → accentLight 大幅向白提亮（輕、清爽的亮線）
  /// 亮色 → accentLight 再提亮，透亮清爽不壓沉
  static Color get ecgLine => isDark
      ? Color.lerp(_preset.accentLight, Colors.white, 0.65)!
      : Color.lerp(_preset.accentLight, Colors.white, 0.3)!;

  /// 心電圖掃描頭亮點 — 比主線再亮半階
  static Color get ecgHead =>
      isDark ? Colors.white : Color.lerp(_preset.accentLight, Colors.white, 0.55)!;

  /// 心電圖光暈色 — 亮色主題用更輕盈的發光，不壓沉背景
  static Color get ecgGlow => isDark
      ? _preset.accent.withValues(alpha: 0.5)
      : _preset.accentLight.withValues(alpha: 0.45);

  // ═══════════════════════════════════
  // 間距
  // ═══════════════════════════════════
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;
  static const double spacingXxl = 48.0;

  // ═══════════════════════════════════
  // 圓角
  // ═══════════════════════════════════
  static const double radiusSm = 8.0;
  static const double radiusMd = 16.0;
  static const double radiusLg = 24.0;
  static const double radiusXl = 32.0;
  static double get radiusBubble => bubbleRadius;

  // ═══════════════════════════════════
  // 字體
  // ═══════════════════════════════════
  static String get fontFamily => _fontChinese;
  static List<String> get _fontFallback => [_fontEnglish];

  static const Map<String, String> fontPairings = {
    'Lora': 'LXGW WenKai TC',
    'LXGW WenKai TC': 'Lora',
  };

  static const Map<String, String> fontDisplayNames = {
    'Lora': 'Lora',
    'LXGW WenKai TC': '落霞文楷',
  };

  static double _s(double base) => base * _fontScale;
  static double _ui(double base) => base;

  static TextStyle get headingLarge => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: _s(24),
    fontWeight: FontWeight.w300,
    color: textAccent,
    letterSpacing: 2.0,
  );

  static TextStyle get headingMedium => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: _s(18),
    fontWeight: FontWeight.w400,
    color: textPrimary,
  );

  static TextStyle get bodyText => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: _s(15),
    fontWeight: FontWeight.w400,
    color: textOnBubble,
    height: 1.5,
  );

  static TextStyle get bodySmall => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: _s(13),
    fontWeight: FontWeight.w400,
    color: textSecondary,
  );

  static TextStyle get navLabel => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: _ui(11),
    fontWeight: FontWeight.w500,
  );

  // ═══════════════════════════════════
  // ThemeData
  // ═══════════════════════════════════
  static ThemeData get themeData {
    final base = isDark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      // 以 accent 為種子生成全套 colorScheme：
      // 沒有顯式指定顏色的控件（進度圈、Switch、TextButton、Slider…）
      // 從此跟隨主題強調色，而不是 Material 默認紫
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: isDark ? Brightness.dark : Brightness.light,
      ).copyWith(primary: accent, secondary: accentLight),
      scaffoldBackgroundColor: bgMint,
      textTheme: base.textTheme.apply(
        fontFamily: fontFamily,
        fontFamilyFallback: _fontFallback,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: headingMedium,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: navBarBg,
        selectedItemColor: navActive,
        unselectedItemColor: navInactive,
        selectedLabelStyle: navLabel,
        unselectedLabelStyle: navLabel,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
