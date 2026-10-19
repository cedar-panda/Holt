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
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.84);
  }

  @override
  void didUpdateWidget(covariant ImageCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paths.isEmpty && _controller.hasClients) {
      _controller.jumpTo(0);
      _currentIndex = 0;
    }
    if (widget.paths.length < oldWidget.paths.length &&
        _controller.hasClients &&
        (_controller.page ?? 0) >= widget.paths.length) {
      _controller.jumpToPage(math.max(0, widget.paths.length - 1));
      _currentIndex = math.max(0, widget.paths.length - 1);
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
      child: Stack(
        children: [
          PageView.builder(
            key: const ValueKey<String>('conversation-image-page-view'),
            controller: _controller,
            itemCount: widget.paths.length,
            clipBehavior: Clip.none,
            allowImplicitScrolling: true,
            physics: const BouncingScrollPhysics(parent: PageScrollPhysics()),
            onPageChanged: (index) {
              if (mounted) setState(() => _currentIndex = index);
            },
            itemBuilder: (context, index) {
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final page = _controller.hasClients
                      ? (_controller.page ?? _controller.initialPage.toDouble())
                      : _controller.initialPage.toDouble();
                  final distance = (page - index).abs().clamp(0.0, 2.0);
                  final opacity = 1.0 - (distance * 0.48).clamp(0.0, 0.78);
                  final scale = 1.0 - (distance * 0.055).clamp(0.0, 0.1);
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
          if (widget.paths.length > 1)
            Positioned(
              right: 16,
              bottom: 14,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    child: Text(
                      '${_currentIndex + 1}/${widget.paths.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1,
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

  Widget _buildCard(BuildContext context, int index, String path) {
    final card = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: ClipRRect(
        key: ValueKey<String>('conversation-image-card-$index'),
        borderRadius: BorderRadius.circular(24),
        child: path == 'generating'
            ? const NeuralGenerationBox()
            : Image.file(
                File(path),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => SizedBox(
                  width: 96,
                  height: 96,
                  child: Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: Semantics(
            button: widget.onTap != null || widget.onLongPress != null,
            label: 'Image ${index + 1} of ${widget.paths.length}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onTap?.call(path),
              onLongPress: () => widget.onLongPress?.call(path),
              child: card,
            ),
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
