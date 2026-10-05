import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'neural_generation_box.dart';

/// Horizontally browsable image cards. The selected card stays fully visible;
/// neighboring cards remain as a low-opacity stacked hint rather than being
/// embedded in the text bubble.
class ImageCardStack extends StatefulWidget {
  final List<String> paths;
  final double height;
  final bool removable;
  final ValueChanged<int>? onRemove;
  final ValueChanged<String>? onTap;
  final ValueChanged<String>? onLongPress;

  const ImageCardStack({
    super.key,
    required this.paths,
    this.height = 218,
    this.removable = false,
    this.onRemove,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<ImageCardStack> createState() => _ImageCardStackState();
}

class _ImageCardStackState extends State<ImageCardStack> {
  late PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.78);
  }

  @override
  void didUpdateWidget(covariant ImageCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paths.isEmpty && _controller.hasClients) {
      _controller.jumpTo(0);
    }
    if (widget.paths.length < oldWidget.paths.length &&
        _controller.hasClients &&
        (_controller.page ?? 0) >= widget.paths.length) {
      _controller.jumpToPage(math.max(0, widget.paths.length - 1));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.paths.isEmpty) return const SizedBox.shrink();
    // ChatBubble is measured inside IntrinsicWidth. Keep the stack finite so
    // an image-only message cannot request an infinite-width child.
    final availableWidth = MediaQuery.sizeOf(context).width;
    return SizedBox(
      height: widget.height,
      width: math.min(320, availableWidth * 0.78),
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.paths.length,
        clipBehavior: Clip.none,
        itemBuilder: (context, index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final page = _controller.hasClients
                  ? (_controller.page ?? _controller.initialPage.toDouble())
                  : _controller.initialPage.toDouble();
              final distance = (page - index).abs().clamp(0.0, 2.0);
              final opacity = 1.0 - (distance * 0.42).clamp(0.0, 0.72);
              final scale = 1.0 - (distance * 0.045).clamp(0.0, 0.08);
              return Center(
                child: Opacity(
                  opacity: opacity,
                  child: Transform.scale(scale: scale, child: child),
                ),
              );
            },
            child: _buildCard(context, index, widget.paths[index]),
          );
        },
      ),
    );
  }

  Widget _buildCard(BuildContext context, int index, String path) {
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.black.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.32),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: YanciTheme.isDark ? 0.22 : 0.06,
            ),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: path == 'generating'
          ? const NeuralGenerationBox()
          : Image.file(
              File(path),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                ),
              ),
            ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onTap?.call(path),
            onLongPress: () => widget.onLongPress?.call(path),
            child: card,
          ),
        ),
        if (widget.removable)
          Positioned(
            top: 10,
            right: 12,
            child: Semantics(
              button: true,
              label: 'Remove image ${index + 1}',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onRemove?.call(index),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.black.withValues(alpha: 0.48)
                        : Colors.white.withValues(alpha: 0.78),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: YanciTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
