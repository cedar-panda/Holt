import 'package:flutter/material.dart';

import '../memory/spider_web_layers.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// Right-side plane selector. It renders metadata only; MemoryScreen mounts a
/// graph for the selected plane, so hidden planes own no painter or ticker.
class MemoryLayerRail extends StatelessWidget {
  final List<SpiderWebLayerPlan> layers;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const MemoryLayerRail({
    super.key,
    required this.layers,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (layers.length <= 1) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: L.pick(en: 'Memory layers', zhTW: '記憶層級', zhCN: '记忆层级'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const buttonHeight = 44.0;
          const layerStep = 30.0;
          final contentHeight = buttonHeight + (layers.length - 1) * layerStep;
          final rail = SizedBox(
            width: 60,
            height: contentHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < layers.length; index++)
                  Positioned(
                    top: index * layerStep,
                    left: 0,
                    right: 0,
                    height: buttonHeight,
                    child: _LayerPlaneButton(
                      layer: layers[index],
                      index: index,
                      selected: index == selectedIndex,
                      onTap: () => onSelected(index),
                    ),
                  ),
              ],
            ),
          );
          if (!constraints.hasBoundedHeight ||
              contentHeight <= constraints.maxHeight) {
            return rail;
          }
          return SingleChildScrollView(child: rail);
        },
      ),
    );
  }
}

class _LayerPlaneButton extends StatelessWidget {
  final SpiderWebLayerPlan layer;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  const _LayerPlaneButton({
    required this.layer,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = L.pick(
      en: 'Layer ${index + 1}, ${layer.memories.length} memories',
      zhTW: '第 ${index + 1} 層，${layer.memories.length} 條記憶',
      zhCN: '第 ${index + 1} 层，${layer.memories.length} 条记忆',
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: '${layer.label} · ${layer.memories.length}',
        child: InkResponse(
          onTap: onTap,
          containedInkWell: false,
          highlightShape: BoxShape.circle,
          radius: 24,
          child: SizedBox.expand(
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(48, 30),
                  painter: _PlanePainter(selected: selected),
                ),
                if (layer.crossLayerLinkCount > 0)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: ExcludeSemantics(
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: YanciTheme.accent,
                          shape: BoxShape.circle,
                          boxShadow: selected
                              ? [
                                  BoxShadow(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.55,
                                    ),
                                    blurRadius: 5,
                                  ),
                                ]
                              : null,
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

class _PlanePainter extends CustomPainter {
  final bool selected;

  const _PlanePainter({required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.10, size.height * 0.45)
      ..lineTo(size.width * 0.73, size.height * 0.24)
      ..lineTo(size.width * 0.91, size.height * 0.58)
      ..lineTo(size.width * 0.27, size.height * 0.79)
      ..close();
    if (selected) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..color = YanciTheme.accent.withValues(alpha: 0.24)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.0 : 1.15
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = YanciTheme.accent.withValues(alpha: selected ? 0.92 : 0.28),
    );
  }

  @override
  bool shouldRepaint(covariant _PlanePainter oldDelegate) =>
      oldDelegate.selected != selected;
}
