import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/background_foreground_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_presets.dart';

/// Shared bottom navigation presentation used by the home screen and the
/// onboarding theme preview. The preview only changes density; labels, icons,
/// active state, and theme treatment stay on the same visual grammar.
class YanciBottomNavBar extends StatelessWidget {
  const YanciBottomNavBar({
    super.key,
    required this.activeIndex,
    this.onTap,
    this.reduceMotion = false,
    this.compact = false,
    this.themePreset,
    this.backgroundPalette,
  });

  final int activeIndex;
  final ValueChanged<int>? onTap;
  final bool reduceMotion;
  final bool compact;
  final ThemePreset? themePreset;
  final BackgroundForegroundPalette? backgroundPalette;

  static const _icons = [
    Icons.people_outline_rounded,
    Icons.auto_awesome,
    Icons.account_circle_outlined,
  ];

  List<String> get _labels => [
    L.get('nav_character'),
    L.get('nav_chat'),
    L.get('nav_me'),
  ];

  @override
  Widget build(BuildContext context) {
    final radius = compact ? 27.0 : 33.0;
    final navHeight = compact ? 54.0 : 66.0;
    final theme = themePreset ?? YanciTheme.preset;
    final imageColor = backgroundPalette?.dominant;
    final imageIsDark =
        imageColor != null && imageColor.computeLuminance() < 0.4;
    final imageSurface = imageColor == null
        ? null
        : Color.lerp(
            imageIsDark ? const Color(0xFF171719) : const Color(0xFFFAFAF8),
            imageColor,
            0.14,
          )!;
    final imageForeground = imageSurface == null
        ? null
        : BackgroundForegroundService.forColor(imageSurface);
    final horizontalPadding = compact ? 0.0 : 24.0;
    final bottomPadding = compact
        ? 0.0
        : MediaQuery.of(context).padding.bottom > 0
        ? MediaQuery.of(context).padding.bottom
        : 16.0;
    final shadowColor = theme.isDark
        ? Colors.black.withValues(alpha: 0.38)
        : Colors.black.withValues(alpha: 0.13);

    return Padding(
      padding: EdgeInsets.only(
        left: horizontalPadding,
        right: horizontalPadding,
        bottom: bottomPadding,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: _YanciNavHoleClipper(borderRadius: radius),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor.withValues(
                        alpha: theme.isDark ? 0.3 : 0.1,
                      ),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: shadowColor.withValues(
                        alpha: theme.isDark ? 0.15 : 0.05,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color:
                        imageSurface ??
                        (theme.isDark
                            ? Colors.white.withValues(alpha: 0.04)
                            : Colors.white.withValues(alpha: 0.35)),
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color:
                          imageForeground?.secondary.withValues(alpha: 0.18) ??
                          Colors.white.withValues(
                            alpha: theme.isDark ? 0.08 : 0.5,
                          ),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: navHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var index = 0; index < _icons.length; index++)
                  _YanciNavItem(
                    icon: _icons[index],
                    label: _labels[index],
                    selected: index == activeIndex,
                    reduceMotion: reduceMotion,
                    compact: compact,
                    accent: imageForeground?.primary ?? theme.accent,
                    inactiveColor:
                        imageForeground?.secondary ?? theme.navInactive,
                    onTap: onTap == null ? null : () => onTap!(index),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _YanciNavItem extends StatelessWidget {
  const _YanciNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.reduceMotion,
    required this.compact,
    required this.accent,
    required this.inactiveColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool reduceMotion;
  final bool compact;
  final Color accent;
  final Color inactiveColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: selected ? 1 : 0),
          duration: duration,
          curve: Curves.easeOutCubic,
          builder: (context, progress, child) {
            final color = Color.lerp(inactiveColor, accent, progress)!;
            final padding = EdgeInsets.lerp(
              EdgeInsets.symmetric(
                horizontal: compact ? 4 : 10,
                vertical: compact ? 3 : 6,
              ),
              EdgeInsets.symmetric(
                horizontal: compact ? 7 : 14,
                vertical: compact ? 4 : 7,
              ),
              progress,
            )!;

            return Container(
              constraints: BoxConstraints(
                minWidth: compact ? 38 : 48,
                minHeight: compact ? 42 : 48,
              ),
              padding: padding,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12 * progress),
                borderRadius: BorderRadius.circular(
                  (compact ? 21 : 24).toDouble(),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: (compact ? 18 : 22) + progress,
                    color: color,
                  ),
                  SizedBox(height: compact ? 1 : 3),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 8 : 10,
                      fontWeight:
                          FontWeight.lerp(
                            FontWeight.w400,
                            FontWeight.w600,
                            progress,
                          ) ??
                          FontWeight.w400,
                      color: color,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _YanciNavHoleClipper extends CustomClipper<Path> {
  const _YanciNavHoleClipper({required this.borderRadius});

  final double borderRadius;

  @override
  Path getClip(Size size) {
    final inner = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(borderRadius),
    );
    final innerPath = Path()..addRRect(inner);
    final outerPath = Path()..addRect((Offset.zero & size).inflate(50));
    return Path.combine(PathOperation.difference, outerPath, innerPath);
  }

  @override
  bool shouldReclip(_YanciNavHoleClipper oldClipper) =>
      oldClipper.borderRadius != borderRadius;
}
