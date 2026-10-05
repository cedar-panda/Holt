import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../utils/latest_request_gate.dart';

@visibleForTesting
double avatarCropMinimumScale({
  required Size displayedImageSize,
  required double cropDiameter,
}) {
  final shortestDisplayedSide = math.min(
    displayedImageSize.width,
    displayedImageSize.height,
  );
  if (shortestDisplayedSide <= 0) return 1;
  return (cropDiameter / shortestDisplayedSide).clamp(0.1, 1.0).toDouble();
}

/// 簡易圓形頭像裁剪器
///
/// 用戶可雙指縮放、拖曳移動圖片，圓形遮罩顯示最終裁切區域。
/// 返回裁切後的正方形圖片路徑，或 null（取消）。
class AvatarCropperScreen extends StatefulWidget {
  final File imageFile;
  final String outputPath;

  const AvatarCropperScreen({
    super.key,
    required this.imageFile,
    required this.outputPath,
  });

  /// 顯示裁剪頁面，返回裁切後的檔案路徑
  static Future<String?> show(
    BuildContext context, {
    required File imageFile,
    required String outputPath,
  }) async {
    // Profile fields may still own the iOS text-input connection when the
    // picker returns. Release it before pushing the crop route so the keyboard
    // cannot resize or cover the crop canvas and confirmation control.
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    if (!context.mounted) return null;
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        requestFocus: true,
        builder: (_) =>
            AvatarCropperScreen(imageFile: imageFile, outputPath: outputPath),
      ),
    );
  }

  @override
  State<AvatarCropperScreen> createState() => _AvatarCropperScreenState();
}

class _AvatarCropperScreenState extends State<AvatarCropperScreen> {
  final TransformationController _transformCtrl = TransformationController();
  ui.Image? _image;
  bool _isProcessing = false;
  final LatestRequestGate _loadGate = LatestRequestGate();

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final generation = _loadGate.begin();
    final sourcePath = widget.imageFile.path;
    final bytes = await widget.imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted ||
        sourcePath != widget.imageFile.path ||
        !_loadGate.isCurrent(generation)) {
      frame.image.dispose();
      return;
    }
    final oldImage = _image;
    setState(() => _image = frame.image);
    oldImage?.dispose();
  }

  @override
  void didUpdateWidget(covariant AvatarCropperScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _loadImage();
    }
  }

  @override
  void dispose() {
    _loadGate.invalidate();
    _image?.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  Future<void> _crop() async {
    if (_image == null || _isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final viewSize = MediaQuery.of(context).size;
      final metrics = _cropMetrics(viewSize);
      final cropDiameter = metrics.cropDiameter;
      final cropCenter = metrics.cropCenter;

      // 計算圖片在螢幕上的實際位置和縮放
      final matrix = _transformCtrl.value;
      final inv = Matrix4.inverted(matrix);
      final interactionScale = matrix.getMaxScaleOnAxis().clamp(
        _minimumInteractionScale(metrics),
        5.0,
      );

      final imgW = _image!.width.toDouble();
      final imgH = _image!.height.toDouble();
      final sourceCenter = _screenToImage(
        cropCenter,
        inv,
        metrics.baseScale,
        metrics.displayRect.topLeft,
      );
      // 以裁切框中心推導正方形來源區域，整個區域再夾回原圖邊界；
      // 不再把超出圖片的矩形硬拉伸到 512px。
      final sourceSide = (cropDiameter / (metrics.baseScale * interactionScale))
          .clamp(1.0, math.min(imgW, imgH))
          .toDouble();
      final sourceLeft = (sourceCenter.dx - sourceSide / 2)
          .clamp(0.0, imgW - sourceSide)
          .toDouble();
      final sourceTop = (sourceCenter.dy - sourceSide / 2)
          .clamp(0.0, imgH - sourceSide)
          .toDouble();
      final srcRect = Rect.fromLTWH(
        sourceLeft,
        sourceTop,
        sourceSide,
        sourceSide,
      );

      // 裁切並輸出 512x512
      const outputSize = 512;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        _image!,
        srcRect,
        const Rect.fromLTWH(0, 0, 512, 512),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(outputSize, outputSize);
      final byteData = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) throw Exception('Failed to encode image');

      final outFile = File(widget.outputPath);
      await outFile.writeAsBytes(byteData.buffer.asUint8List());

      if (mounted) Navigator.of(context).pop(widget.outputPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Crop failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        setState(() => _isProcessing = false);
      }
    }
  }

  double _minimumInteractionScale(_CropMetrics metrics) {
    return avatarCropMinimumScale(
      displayedImageSize: metrics.displayRect.size,
      cropDiameter: metrics.cropDiameter,
    );
  }

  _CropMetrics _cropMetrics(Size viewSize) {
    if (_image == null) {
      return _CropMetrics(
        cropCenter: viewSize.center(Offset.zero),
        cropDiameter: viewSize.width * 0.75,
        baseScale: 1,
        displayRect: Offset.zero & viewSize,
      );
    }
    final imgW = _image!.width.toDouble();
    final imgH = _image!.height.toDouble();
    // Image.file(fit: contain) 的實際圖片邊界，不假設圖片永遠以寬度填滿。
    final baseScale = math.min(viewSize.width / imgW, viewSize.height / imgH);
    final displaySize = Size(imgW * baseScale, imgH * baseScale);
    final displayRect = Rect.fromCenter(
      center: viewSize.center(Offset.zero),
      width: displaySize.width,
      height: displaySize.height,
    );
    final cropDiameter = math.min(
      viewSize.width * 0.75,
      math.min(displayRect.width, displayRect.height),
    );
    return _CropMetrics(
      cropCenter: displayRect.center,
      cropDiameter: cropDiameter,
      baseScale: baseScale,
      displayRect: displayRect,
    );
  }

  Offset _screenToImage(
    Offset screen,
    Matrix4 inv,
    double baseScale,
    Offset displayOffset,
  ) {
    // screen → display space (undo InteractiveViewer transform)
    final s = inv.storage;
    final sx = screen.dx, sy = screen.dy;
    final vx = s[0] * sx + s[4] * sy + s[12];
    final vy = s[1] * sx + s[5] * sy + s[13];
    // display space → image space
    return Offset(
      (vx - displayOffset.dx) / baseScale,
      (vy - displayOffset.dy) / baseScale,
    );
  }

  void _settleImageAtCropEdge(Size viewSize) {
    if (_image == null) return;
    final metrics = _cropMetrics(viewSize);
    final matrix = _transformCtrl.value.clone();
    final scale = matrix.getMaxScaleOnAxis().clamp(
      _minimumInteractionScale(metrics),
      5.0,
    );
    final cropRect = Rect.fromCircle(
      center: metrics.cropCenter,
      radius: metrics.cropDiameter / 2,
    );
    final scaledLeft = metrics.displayRect.left * scale;
    final scaledRight = metrics.displayRect.right * scale;
    final scaledTop = metrics.displayRect.top * scale;
    final scaledBottom = metrics.displayRect.bottom * scale;
    final minX = cropRect.right - scaledRight;
    final maxX = cropRect.left - scaledLeft;
    final minY = cropRect.bottom - scaledBottom;
    final maxY = cropRect.top - scaledTop;
    final currentX = matrix.storage[12];
    final currentY = matrix.storage[13];
    final nextX = currentX.clamp(minX, maxX).toDouble();
    final nextY = currentY.clamp(minY, maxY).toDouble();
    if ((nextX - currentX).abs() < 0.01 && (nextY - currentY).abs() < 0.01) {
      return;
    }
    matrix.storage[12] = nextX;
    matrix.storage[13] = nextY;
    _transformCtrl.value = matrix;
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.of(context).size;
    final metrics = _cropMetrics(viewSize);
    final cropDiameter = metrics.cropDiameter;
    final minimumScale = _minimumInteractionScale(metrics);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 圖片（可拖曳縮放）
          if (_image != null)
            InteractiveViewer(
              transformationController: _transformCtrl,
              minScale: minimumScale,
              maxScale: 5.0,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              clipBehavior: Clip.none,
              onInteractionEnd: (_) => _settleImageAtCropEdge(viewSize),
              child: Image.file(
                widget.imageFile,
                fit: BoxFit.contain,
                width: viewSize.width,
                height: viewSize.height,
                filterQuality: FilterQuality.high,
                gaplessPlayback: true,
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // 圓形遮罩
          IgnorePointer(
            child: CustomPaint(
              size: viewSize,
              painter: _CropOverlayPainter(
                cropCenter: metrics.cropCenter,
                cropDiameter: cropDiameter,
              ),
            ),
          ),

          // 頂部按鈕
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: IconButton(
              icon: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 28,
              ),
              onPressed: () => Navigator.of(context).pop(null),
            ),
          ),

          // 底部確認按鈕
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _isProcessing ? null : _crop,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.accent,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: _isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          L.pick(en: 'Confirm', zhTW: '確認'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
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

class _CropMetrics {
  final Offset cropCenter;
  final double cropDiameter;
  final double baseScale;
  final Rect displayRect;

  const _CropMetrics({
    required this.cropCenter,
    required this.cropDiameter,
    required this.baseScale,
    required this.displayRect,
  });
}

/// 圓形裁切遮罩 — 圓圈外半透明黑色，圓圈內透明
class _CropOverlayPainter extends CustomPainter {
  final Offset cropCenter;
  final double cropDiameter;

  _CropOverlayPainter({required this.cropCenter, required this.cropDiameter});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(
        Rect.fromCenter(
          center: cropCenter,
          width: cropDiameter,
          height: cropDiameter,
        ),
      )
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.6));

    // 圓形邊框
    canvas.drawCircle(
      cropCenter,
      cropDiameter / 2,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter old) =>
      cropCenter != old.cropCenter || cropDiameter != old.cropDiameter;
}
