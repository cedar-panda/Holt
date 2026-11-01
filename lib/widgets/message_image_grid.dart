import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'neural_generation_box.dart';

/// 已發送訊息的圖片（縮略圖，點開看原圖）。
/// 1 張：方形縮略圖；2 張：並排；3 張：一排三張；
/// 4 張以上：2×2，第 4 格若還有更多，蓋一層 `+N`。
/// `'generating'` 是生成中的佔位路徑，顯示動畫、不可點。
class MessageImageGrid extends StatelessWidget {
  static const double _gap = 4;
  static const double _radius = 12;

  /// 單張縮略圖邊長。
  static const double singleSize = 150;

  /// 多張時每格的最大邊長。
  static const double cellSize = 72;

  /// 整組圖最多佔螢幕寬的比例。氣泡兩側還有頭像與留白，
  /// 舊版固定 ~300pt 寬會超出可用空間，溢出的部分畫到頭像上。
  static const double _maxScreenFraction = 0.55;

  final List<String> paths;
  final ValueChanged<String>? onTap;
  final ValueChanged<String>? onLongPress;

  const MessageImageGrid({
    super.key,
    required this.paths,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    // ChatBubble 在 IntrinsicWidth 內量測：寬度必須是有限的固定值，
    // 不能用 LayoutBuilder（它不支援 intrinsic 量測）。
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width * _maxScreenFraction;
    final dpr = media.devicePixelRatio;

    if (paths.length == 1) {
      final side = math.min(singleSize, maxWidth);
      return SizedBox(
        width: side,
        height: side,
        child: _tile(paths.first, 0, decodeWidth: (side * dpr).round()),
      );
    }

    final columns = paths.length == 3 ? 3 : 2;
    final shown = math.min(paths.length, 4);
    final cell = math.min(cellSize, (maxWidth - _gap * (columns - 1)) / columns);
    final width = cell * columns + _gap * (columns - 1);
    final rowCount = (shown / columns).ceil();
    final more = paths.length - shown;
    final decodeWidth = (cell * dpr).round();

    final rows = <Widget>[];
    for (var r = 0; r < rowCount; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < columns; c++) {
        final i = r * columns + c;
        if (i >= shown) break;
        if (c > 0) cells.add(const SizedBox(width: _gap));
        cells.add(
          SizedBox(
            width: cell,
            height: cell,
            child: _tile(
              paths[i],
              i,
              decodeWidth: decodeWidth,
              moreCount: (i == shown - 1 && more > 0) ? more : null,
            ),
          ),
        );
      }
      if (r > 0) rows.add(const SizedBox(height: _gap));
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }

    return SizedBox(
      width: width,
      height: rowCount * cell + (rowCount - 1) * _gap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _tile(
    String path,
    int index, {
    required int decodeWidth,
    int? moreCount,
  }) {
    final generating = path == 'generating';
    Widget image = generating
        ? const NeuralGenerationBox()
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            // 只按縮略圖尺寸解碼，九張大圖不會整張進記憶體。
            cacheWidth: decodeWidth,
            filterQuality: FilterQuality.medium,
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
          );
    image = SizedBox.expand(child: image);
    if (moreCount != null) {
      // 不再整格壓黑＋大粗字：圖照常顯示，右下角一顆小膠囊標剩幾張。
      image = Stack(
        fit: StackFit.expand,
        children: [
          image,
          Positioned(
            right: 5,
            bottom: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: 0.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '+$moreCount',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.94),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                    height: 1.2,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Semantics(
      button: !generating && onTap != null,
      label: 'Image ${index + 1} of ${paths.length}',
      child: GestureDetector(
        key: ValueKey<String>('message-image-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: generating || onTap == null ? null : () => onTap!(path),
        onLongPress: generating || onLongPress == null
            ? null
            : () => onLongPress!(path),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: image,
        ),
      ),
    );
  }
}

/// 全螢幕看圖：多張可左右滑，可縮放、可保存目前這張。
class ImageGalleryViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  final ValueChanged<String> onSave;

  const ImageGalleryViewer({
    super.key,
    required this.paths,
    required this.initialIndex,
    required this.onSave,
  });

  @override
  State<ImageGalleryViewer> createState() => _ImageGalleryViewerState();
}

class _ImageGalleryViewerState extends State<ImageGalleryViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.paths.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white70, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          PageView.builder(
            key: const ValueKey<String>('image-gallery-page-view'),
            controller: _controller,
            itemCount: widget.paths.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => Stack(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const SizedBox.expand(),
                ),
                Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.file(
                      File(widget.paths[i]),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white38,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: padding.top + 8,
            right: 16,
            child: Row(
              children: [
                _roundButton(
                  Icons.save_alt_rounded,
                  () => widget.onSave(widget.paths[_index]),
                ),
                const SizedBox(width: 12),
                _roundButton(
                  Icons.close_rounded,
                  () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          if (widget.paths.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: padding.bottom + 20,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      child: Text(
                        '${_index + 1}/${widget.paths.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1,
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
