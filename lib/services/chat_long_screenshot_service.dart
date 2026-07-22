import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../theme/app_theme.dart';
import 'locale_strings.dart';

class ChatLongScreenshotResult {
  final String path;
  final int width;
  final int height;

  const ChatLongScreenshotResult({
    required this.path,
    required this.width,
    required this.height,
  });
}

/// Renders chat bubbles in short, safe chunks and stitches them off the UI
/// isolate. A single giant Flutter layer is unreliable on long conversations
/// because mobile GPUs commonly impose texture-size limits.
class ChatLongScreenshotService {
  ChatLongScreenshotService._();

  static const int _chunkSize = 4;
  static const int _maxOutputHeight = 20000;

  static Future<ChatLongScreenshotResult> captureAndSave({
    required BuildContext context,
    required List<Widget> items,
    required Color backgroundColor,
    double pixelRatio = 2,
  }) async {
    if (items.isEmpty) {
      throw StateError('No chat content to capture');
    }

    final media = MediaQuery.of(context);
    final logicalWidth = media.size.width;
    final ratio = pixelRatio.clamp(1.0, 2.0).toDouble();
    final rendered = await showGeneralDialog<_LongScreenshotDialogResult>(
      context: context,
      barrierDismissible: false,
      barrierLabel: L.pick(en: 'Creating long screenshot', zhTW: '正在生成長截圖'),
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, _, _) => _LongScreenshotCaptureHost(
        items: items,
        logicalWidth: logicalWidth,
        pixelRatio: ratio,
        backgroundColor: backgroundColor,
      ),
    );

    if (rendered == null) {
      throw StateError('Long screenshot was interrupted');
    }
    if (rendered.error != null) {
      throw StateError(rendered.error!);
    }
    final bytes = rendered.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Long screenshot returned no image data');
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/holt_longshot_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(path).writeAsBytes(bytes, flush: true);
    await Gal.putImage(path);

    return ChatLongScreenshotResult(
      path: path,
      width: rendered.width,
      height: rendered.height,
    );
  }
}

class _LongScreenshotCaptureHost extends StatefulWidget {
  final List<Widget> items;
  final double logicalWidth;
  final double pixelRatio;
  final Color backgroundColor;

  const _LongScreenshotCaptureHost({
    required this.items,
    required this.logicalWidth,
    required this.pixelRatio,
    required this.backgroundColor,
  });

  @override
  State<_LongScreenshotCaptureHost> createState() =>
      _LongScreenshotCaptureHostState();
}

class _LongScreenshotCaptureHostState
    extends State<_LongScreenshotCaptureHost> {
  final GlobalKey _boundaryKey = GlobalKey();
  final List<Uint8List> _pngChunks = <Uint8List>[];
  final List<int> _chunkWidths = <int>[];
  final List<int> _chunkHeights = <int>[];
  late final List<List<Widget>> _chunks;
  int _chunkIndex = 0;

  @override
  void initState() {
    super.initState();
    _chunks = <List<Widget>>[
      for (
        var i = 0;
        i < widget.items.length;
        i += ChatLongScreenshotService._chunkSize
      )
        widget.items.sublist(
          i,
          (i + ChatLongScreenshotService._chunkSize).clamp(
            0,
            widget.items.length,
          ),
        ),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureAllChunks());
  }

  Future<void> _captureAllChunks() async {
    try {
      for (var i = 0; i < _chunks.length; i++) {
        if (!mounted) return;
        if (_chunkIndex != i) {
          setState(() => _chunkIndex = i);
        }

        // Two settled frames plus a short grace period allow local file images
        // and sticker futures to finish painting before the boundary is read.
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;

        final boundary = _boundaryKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary) {
          throw StateError('Long screenshot surface is unavailable');
        }
        final image = await boundary.toImage(pixelRatio: widget.pixelRatio);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) {
            throw StateError('Could not encode screenshot chunk');
          }
          _pngChunks.add(data.buffer.asUint8List());
          _chunkWidths.add(image.width);
          _chunkHeights.add(image.height);
        } finally {
          image.dispose();
        }
      }

      final stitched = await compute<Map<String, Object>, Map<String, Object>>(
        _stitchLongScreenshot,
        <String, Object>{
          'chunks': _pngChunks,
          'widths': _chunkWidths,
          'heights': _chunkHeights,
          'maxHeight': ChatLongScreenshotService._maxOutputHeight,
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        _LongScreenshotDialogResult(
          bytes: stitched['bytes']! as Uint8List,
          width: stitched['width']! as int,
          height: stitched['height']! as int,
        ),
      );
    } catch (error, stack) {
      debugPrint('Long screenshot failed: $error\n$stack');
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(_LongScreenshotDialogResult(error: error.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chunk = _chunks[_chunkIndex];
    return PopScope(
      canPop: false,
      child: Material(
        color: widget.backgroundColor,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: widget.logicalWidth,
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: ColoredBox(
                    key: ValueKey<int>(_chunkIndex),
                    color: widget.backgroundColor,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: chunk,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ColoredBox(
                color: widget.backgroundColor,
                child: SafeArea(
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      label: L.pick(
                        en: 'Creating long screenshot, ${_chunkIndex + 1} of ${_chunks.length}',
                        zhTW:
                            '正在生成長截圖，第 ${_chunkIndex + 1} 段，共 ${_chunks.length} 段',
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: YanciTheme.accent,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            L.pick(
                              en: 'Creating long screenshot…',
                              zhTW: '正在生成長截圖……',
                            ),
                            style: TextStyle(
                              color: YanciTheme.textPrimary,
                              fontFamily: YanciTheme.fontFamily,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${_chunkIndex + 1} / ${_chunks.length}',
                            style: TextStyle(
                              color: YanciTheme.textSecondary,
                              fontFamily: YanciTheme.fontFamily,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LongScreenshotDialogResult {
  final Uint8List? bytes;
  final int width;
  final int height;
  final String? error;

  const _LongScreenshotDialogResult({
    this.bytes,
    this.width = 0,
    this.height = 0,
    this.error,
  });
}

Map<String, Object> _stitchLongScreenshot(Map<String, Object> payload) {
  final chunks = (payload['chunks']! as List).cast<Uint8List>();
  final widths = (payload['widths']! as List).cast<int>();
  final heights = (payload['heights']! as List).cast<int>();
  final maxHeight = payload['maxHeight']! as int;
  if (chunks.isEmpty || widths.isEmpty || heights.isEmpty) {
    throw StateError('No screenshot chunks to stitch');
  }

  final sourceWidth = widths.reduce((a, b) => a > b ? a : b);
  final sourceHeight = heights.fold<int>(0, (sum, height) => sum + height);
  final scale = sourceHeight > maxHeight ? maxHeight / sourceHeight : 1.0;
  final outputWidth = (sourceWidth * scale).round().clamp(1, sourceWidth);
  final scaledHeights = heights
      .map((height) => (height * scale).round().clamp(1, height))
      .toList(growable: false);
  final outputHeight = scaledHeights.fold<int>(
    0,
    (sum, height) => sum + height,
  );
  final output = img.Image(
    width: outputWidth,
    height: outputHeight,
    numChannels: 4,
  );

  var y = 0;
  for (var i = 0; i < chunks.length; i++) {
    var decoded = img.decodePng(chunks[i]);
    if (decoded == null) throw StateError('Could not decode screenshot chunk');
    if (decoded.width != outputWidth || decoded.height != scaledHeights[i]) {
      decoded = img.copyResize(
        decoded,
        width: outputWidth,
        height: scaledHeights[i],
        interpolation: img.Interpolation.linear,
      );
    }
    img.compositeImage(output, decoded, dstY: y);
    y += decoded.height;
  }

  return <String, Object>{
    'bytes': Uint8List.fromList(img.encodePng(output, level: 6)),
    'width': outputWidth,
    'height': outputHeight,
  };
}

@visibleForTesting
Map<String, Object> stitchLongScreenshotChunksForTesting(
  Map<String, Object> payload,
) => _stitchLongScreenshot(payload);
