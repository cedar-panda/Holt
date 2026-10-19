import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Sidebar-only contrast tokens.
///
/// Light presets previously reused the intentionally quiet global secondary
/// color and then reduced its opacity again. That double fading made the
/// entire drawer look disabled. Keep dark themes unchanged while pulling
/// light-theme labels and icons toward the primary ink color.
abstract final class SidebarVisualTokens {
  static Color get primary => YanciTheme.textPrimary;

  static Color get secondary => YanciTheme.isDark
      ? YanciTheme.textSecondary
      : Color.lerp(YanciTheme.textSecondary, YanciTheme.textPrimary, 0.46)!;

  static Color get accent => YanciTheme.isDark
      ? YanciTheme.accent
      : Color.lerp(YanciTheme.accent, YanciTheme.textPrimary, 0.12)!;
}
