import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 待發圖片：正方形橫排，可左右滑。
/// 叉叉畫在格子內側（橫向列表會裁掉凸出的部分），可點範圍 34pt。
/// 未滿 [maxImages] 張時，尾端有一格「＋」。
class PendingImageTray extends StatelessWidget {
  static const double tileSize = 68;
  static const int maxImages = 9;

  final List<String> paths;
  final ValueChanged<int> onRemove;
  final ValueChanged<String>? onTap;
  final VoidCallback? onAdd;

  const PendingImageTray({
    super.key,
    required this.paths,
    required this.onRemove,
    this.onTap,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    final showAdd = onAdd != null && paths.length < maxImages;
    final itemCount = paths.length + (showAdd ? 1 : 0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: tileSize,
          child: ListView.separated(
            key: const ValueKey<String>('pending-image-tray'),
            scrollDirection: Axis.horizontal,
            itemCount: itemCount,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index >= paths.length) return _AddTile(onTap: onAdd!);
              return _ImageTile(
                path: paths[index],
                index: index,
                total: paths.length,
                onTap: onTap,
                onRemove: onRemove,
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, right: 2),
          child: Text(
            '${paths.length}/$maxImages',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              height: 1,
              color: YanciTheme.textSecondary.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
}

class _ImageTile extends StatelessWidget {
  final String path;
  final int index;
  final int total;
  final ValueChanged<String>? onTap;
  final ValueChanged<int> onRemove;

  const _ImageTile({
    required this.path,
    required this.index,
    required this.total,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    const size = PendingImageTray.tileSize;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: onTap != null,
              label: 'Image ${index + 1} of $total',
              child: GestureDetector(
                key: ValueKey<String>('pending-image-$index'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null ? null : () => onTap!(path),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.08),
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Semantics(
              button: true,
              label: 'Remove image ${index + 1}',
              child: GestureDetector(
                key: ValueKey<String>('pending-image-remove-$index'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onRemove(index),
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final VoidCallback onTap;

  const _AddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    const size = PendingImageTray.tileSize;
    return Semantics(
      button: true,
      label: 'Add image',
      child: GestureDetector(
        key: const ValueKey<String>('pending-image-add'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: YanciTheme.textSecondary.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          child: Icon(
            Icons.add_rounded,
            color: YanciTheme.textSecondary.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
