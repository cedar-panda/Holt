import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';

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
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
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

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final bytes = await widget.imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  Future<void> _crop() async {
    if (_image == null || _isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final viewSize = MediaQuery.of(context).size;
      final cropDiameter = viewSize.width * 0.75;
      final cropCenter = Offset(viewSize.width / 2, viewSize.height / 2 - 30);
      final cropRect = Rect.fromCenter(
        center: cropCenter,
        width: cropDiameter,
        height: cropDiameter,
      );

      // 計算圖片在螢幕上的實際位置和縮放
      final matrix = _transformCtrl.value;
      final inv = Matrix4.inverted(matrix);

      // 圖片適配螢幕的基礎縮放
      final imgW = _image!.width.toDouble();
      final imgH = _image!.height.toDouble();
      final baseScale = viewSize.width / imgW;
      final displayH = imgH * baseScale;
      final offsetY = (viewSize.height - displayH) / 2;

      // 裁切區域 → 圖片座標
      final tl = _screenToImage(
        cropRect.topLeft,
        inv,
        baseScale,
        Offset(0, offsetY),
      );
      final br = _screenToImage(
        cropRect.bottomRight,
        inv,
        baseScale,
        Offset(0, offsetY),
      );

      final srcRect = Rect.fromLTRB(
        tl.dx.clamp(0, imgW),
        tl.dy.clamp(0, imgH),
        br.dx.clamp(0, imgW),
        br.dy.clamp(0, imgH),
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
    return Offset(vx / baseScale, (vy - displayOffset.dy) / baseScale);
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.of(context).size;
    final cropDiameter = viewSize.width * 0.75;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 圖片（可拖曳縮放）
          if (_image != null)
            InteractiveViewer(
              transformationController: _transformCtrl,
              minScale: 0.5,
              maxScale: 5.0,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              child: Image.file(
                widget.imageFile,
                fit: BoxFit.contain,
                width: viewSize.width,
                height: viewSize.height,
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // 圓形遮罩
          IgnorePointer(
            child: CustomPaint(
              size: viewSize,
              painter: _CropOverlayPainter(
                cropCenter: Offset(
                  viewSize.width / 2,
                  viewSize.height / 2 - 30,
                ),
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
