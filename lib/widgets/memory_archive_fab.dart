import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class MemoryArchiveFab extends StatelessWidget {
  final int archivedCount;
  final AnimationController animationController;
  final VoidCallback onOpen;

  const MemoryArchiveFab({
    super.key,
    required this.archivedCount,
    required this.animationController,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 20,
      bottom: 20 + MediaQuery.of(context).padding.bottom,
      child: GestureDetector(
        onTap: () async {
          animationController.forward(from: 0.0);
          await Future.delayed(const Duration(milliseconds: 150));
          onOpen();
        },
        child: AnimatedBuilder(
          animation: animationController,
          builder: (ctx, child) {
            final t = animationController.value;
            final double scale;
            if (t < 0.4) {
              scale = 1.0 - 0.15 * (t / 0.4);
            } else {
              final b = (t - 0.4) / 0.6;
              scale = 0.85 + 0.2 * Curves.elasticOut.transform(b);
            }
            return Transform.scale(scale: scale.clamp(0.8, 1.15), child: child);
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.transparent,
              border: Border.all(
                color: YanciTheme.textSecondary.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                ),
                if (archivedCount > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: YanciTheme.accent.withValues(alpha: 0.7),
                      ),
                      child: Center(
                        child: Text(
                          archivedCount > 99 ? '99' : '$archivedCount',
                          style: const TextStyle(
                            fontSize: 8,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
