import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class MemoryCapsuleTabBar extends StatelessWidget {
  final int selectedIndex;
  final int reviewTotal;
  final int reviewUnread;
  final ValueChanged<int> onTabSelected;

  const MemoryCapsuleTabBar({
    super.key,
    required this.selectedIndex,
    required this.reviewTotal,
    required this.reviewUnread,
    required this.onTabSelected,
  });

  Widget _buildReviewCountBadge() {
    final unread = reviewUnread > 0;
    final color = unread
        ? const Color(0xFFD86B72)
        : YanciTheme.textSecondary.withValues(alpha: 0.18);
    final label = reviewTotal > 9 ? '9+' : '$reviewTotal';
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const ValueKey('memory-review-count-badge'),
        dimension: 18,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    (unread
                            ? const Color(0xFFD86B72)
                            : YanciTheme.textSecondary)
                        .withValues(alpha: unread ? 0.2 : 0.08),
                blurRadius: 2.4,
                spreadRadius: 0.25,
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: unread ? Colors.white : YanciTheme.textSecondary,
                fontSize: label.length > 1 ? 8 : 9,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = [
      L.pick(en: 'Memories', zhTW: '記憶'),
      L.pick(en: 'Review', zhTW: '待確認'),
      L.pick(en: 'Summary', zhTW: '摘要'),
    ];
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(22),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / labels.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                left: selectedIndex * tabWidth,
                top: 3,
                bottom: 3,
                width: tabWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
              Row(
                children: List.generate(labels.length, (index) {
                  final selected = selectedIndex == index;
                  return Expanded(
                    child: Semantics(
                      button: true,
                      selected: selected,
                      label: index == 1 && reviewTotal > 0
                          ? '${labels[index]}, $reviewTotal'
                          : labels[index],
                      child: GestureDetector(
                        onTap: () => onTabSelected(index),
                        behavior: HitTestBehavior.opaque,
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                labels[index],
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected
                                      ? YanciTheme.accent
                                      : YanciTheme.textSecondary.withValues(
                                          alpha: 0.58,
                                        ),
                                ),
                              ),
                              if (index == 1 && reviewTotal > 0) ...[
                                const SizedBox(width: 5),
                                _buildReviewCountBadge(),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }
}
