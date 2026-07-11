import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';

class PixelArtEditor extends StatefulWidget {
  final int gridSize;

  const PixelArtEditor({super.key, this.gridSize = 24});

  @override
  State<PixelArtEditor> createState() => _PixelArtEditorState();
}

class _PixelArtEditorState extends State<PixelArtEditor> {
  late List<List<Color?>> _grid;

  // Color Picker State
  double _hue = 0.0;
  double _saturation = 1.0;
  double _value = 1.0;

  // Palette
  final List<Color> _savedColors = [
    Colors.black,
    Colors.white,
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.yellow,
    Colors.purple,
    Colors.orange,
  ];

  Color get _currentColor =>
      HSVColor.fromAHSV(1.0, _hue, _saturation, _value).toColor();

  // Tool
  bool _isEraser = false;

  // Undo stack
  final List<List<List<Color?>>> _undoStack = [];
  static const int _maxUndo = 30;

  @override
  void initState() {
    super.initState();
    _resetGrid();
  }

  void _resetGrid() {
    _grid = List.generate(
      widget.gridSize,
      (_) => List.generate(widget.gridSize, (_) => null),
    );
  }

  /// 深拷貝 grid
  List<List<Color?>> _cloneGrid() {
    return _grid.map((row) => List<Color?>.from(row)).toList();
  }

  /// 推入 undo 快照（在筆畫開始前呼叫）
  void _pushUndo() {
    _undoStack.add(_cloneGrid());
    if (_undoStack.length > _maxUndo) {
      _undoStack.removeAt(0);
    }
  }

  /// 撤回
  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _grid = _undoStack.removeLast();
    });
  }

  void _updatePixel(Offset localPosition, Size size) {
    final cellWidth = size.width / widget.gridSize;
    final cellHeight = size.height / widget.gridSize;

    final x = (localPosition.dx / cellWidth).floor();
    final y = (localPosition.dy / cellHeight).floor();

    if (x >= 0 && x < widget.gridSize && y >= 0 && y < widget.gridSize) {
      setState(() {
        _grid[y][x] = _isEraser ? null : _currentColor;
      });
    }
  }

  // ── 匯出圖片 ──

  Future<void> _exportAndSave() async {
    // 輸出倍率：2.5x（24 → 60）
    const double scale = 2.5;
    final int outSize = (widget.gridSize * scale).round();

    final image = img.Image(width: outSize, height: outSize, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));

    for (int y = 0; y < widget.gridSize; y++) {
      for (int x = 0; x < widget.gridSize; x++) {
        final color = _grid[y][x];
        if (color != null) {
          final c = img.ColorRgba8(
            (color.r * 255.0).round().clamp(0, 255),
            (color.g * 255.0).round().clamp(0, 255),
            (color.b * 255.0).round().clamp(0, 255),
            (color.a * 255.0).round().clamp(0, 255),
          );
          final px0 = (x * scale).round();
          final py0 = (y * scale).round();
          final px1 = ((x + 1) * scale).round().clamp(0, outSize);
          final py1 = ((y + 1) * scale).round().clamp(0, outSize);
          for (int py = py0; py < py1; py++) {
            for (int px = px0; px < px1; px++) {
              image.setPixel(px, py, c);
            }
          }
        }
      }
    }

    final pngData = img.encodePng(image);
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/pixel_art_$timestamp.png');
    await file.writeAsBytes(pngData);

    if (mounted) {
      Navigator.of(context).pop(file.path);
    }
  }

  // ── 匯入外部 PNG 到畫布 ──

  Future<void> _importPngToCanvas() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: ImageSource.gallery);
    if (xFile == null) return;

    try {
      final bytes = await File(xFile.path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('decode failed');

      // 縮放到 gridSize × gridSize（最鄰近插值，保留銳利像素感）
      final resized = img.copyResize(
        decoded,
        width: widget.gridSize,
        height: widget.gridSize,
        interpolation: img.Interpolation.nearest,
      );

      _pushUndo();
      setState(() {
        for (int y = 0; y < widget.gridSize; y++) {
          for (int x = 0; x < widget.gridSize; x++) {
            final p = resized.getPixel(x, y);
            final a = p.a.toInt();
            if (a < 10) {
              _grid[y][x] = null; // 近乎透明的像素視為空
            } else {
              _grid[y][x] = Color.fromARGB(
                a,
                p.r.toInt(),
                p.g.toInt(),
                p.b.toInt(),
              );
            }
          }
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(
                en: 'Imported ${decoded.width}×${decoded.height} image to the canvas',
                zhTW: '已將 ${decoded.width}×${decoded.height} 圖片匯入畫布',
              ),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(en: 'Unable to read this image', zhTW: '無法讀取此圖片'),
            ),
          ),
        );
      }
    }
  }

  // ── 數字碼 匯出 / 匯入 ──

  String _exportNumericCode() {
    final palette = <Color>[];
    for (int y = 0; y < widget.gridSize; y++) {
      for (int x = 0; x < widget.gridSize; x++) {
        final c = _grid[y][x];
        if (c != null && !palette.contains(c)) {
          palette.add(c);
        }
      }
    }

    final buffer = StringBuffer();
    buffer.write('1'); // version
    buffer.write(palette.length.toString().padLeft(2, '0'));
    for (final c in palette) {
      buffer.write(c.toARGB32().toString().padLeft(10, '0'));
    }

    // RLE
    int currentIdx = -1;
    int currentCount = 0;

    void flush() {
      if (currentCount > 0) {
        buffer.write(currentCount.toString().padLeft(3, '0'));
        buffer.write(currentIdx.toString().padLeft(2, '0'));
      }
    }

    for (int y = 0; y < widget.gridSize; y++) {
      for (int x = 0; x < widget.gridSize; x++) {
        final c = _grid[y][x];
        final idx = c == null ? 0 : (palette.indexOf(c) + 1);
        if (idx == currentIdx) {
          currentCount++;
        } else {
          flush();
          currentIdx = idx;
          currentCount = 1;
        }
      }
    }
    flush();

    return buffer.toString();
  }

  void _importNumericCode(String code) {
    try {
      if (code.isEmpty || code[0] != '1') throw Exception('Invalid version');
      int pos = 1;

      final paletteSize = int.parse(code.substring(pos, pos + 2));
      pos += 2;

      final palette = <Color>[];
      for (int i = 0; i < paletteSize; i++) {
        final val = int.parse(code.substring(pos, pos + 10));
        palette.add(Color(val));
        pos += 10;
      }

      _pushUndo();
      int gridIdx = 0;
      while (pos < code.length && gridIdx < widget.gridSize * widget.gridSize) {
        final count = int.parse(code.substring(pos, pos + 3));
        pos += 3;
        final idx = int.parse(code.substring(pos, pos + 2));
        pos += 2;

        for (int i = 0; i < count; i++) {
          final y = gridIdx ~/ widget.gridSize;
          final x = gridIdx % widget.gridSize;
          if (idx == 0) {
            _grid[y][x] = null;
          } else {
            _grid[y][x] = palette[idx - 1];
          }
          gridIdx++;
        }
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Invalid image code', zhTW: '無效的圖片碼')),
          ),
        );
      }
    }
  }

  void _showExportDialog() {
    final code = _exportNumericCode();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          L.pick(en: 'Export image code', zhTW: '導出圖片碼'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              L.pick(
                en: 'Copy the numeric code below to save or share this pattern:',
                zhTW: '複製下方的數字碼來保存或分享此圖案：',
              ),
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black45,
              child: SelectableText(
                code,
                style: TextStyle(
                  color: YanciTheme.accent,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L.pick(en: 'Done', zhTW: '完成')),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          L.pick(en: 'Import image code', zhTW: '導入圖片碼'),
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          maxLines: 4,
          decoration: InputDecoration(
            hintText: L.pick(en: 'Paste the numeric code…', zhTW: '請貼上數字碼…'),
            hintStyle: const TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _importNumericCode(controller.text.trim());
            },
            child: Text(
              L.pick(en: 'Import', zhTW: '導入'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: YanciTheme.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L.pick(en: 'Pixel Canvas', zhTW: '像素畫板'),
                  style: YanciTheme.headingMedium.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 匯入 PNG 圖片
                    IconButton(
                      icon: const Icon(
                        Icons.image_outlined,
                        color: Colors.white70,
                      ),
                      tooltip: L.pick(
                        en: 'Import image to canvas',
                        zhTW: '匯入圖片到畫布',
                      ),
                      onPressed: _importPngToCanvas,
                    ),
                    // 導入圖片碼
                    IconButton(
                      icon: const Icon(Icons.download, color: Colors.white70),
                      tooltip: L.pick(en: 'Import image code', zhTW: '導入圖片碼'),
                      onPressed: () => _showImportDialog(),
                    ),
                    // 導出圖片碼
                    IconButton(
                      icon: const Icon(Icons.share, color: Colors.white70),
                      tooltip: L.pick(en: 'Export image code', zhTW: '導出圖片碼'),
                      onPressed: () => _showExportDialog(),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: YanciTheme.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 畫布區
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      border: Border.all(
                        color: YanciTheme.glassBorder,
                        width: 2,
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          onPanDown: (details) {
                            _pushUndo();
                            _updatePixel(
                              details.localPosition,
                              constraints.biggest,
                            );
                          },
                          onPanUpdate: (details) => _updatePixel(
                            details.localPosition,
                            constraints.biggest,
                          ),
                          child: CustomPaint(
                            size: constraints.biggest,
                            painter: _GridPainter(
                              grid: _grid,
                              gridSize: widget.gridSize,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // 撤回按鈕
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: _undoStack.isNotEmpty ? _undo : null,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.undo_rounded,
                        size: 18,
                        color: _undoStack.isNotEmpty
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary.withValues(alpha: 0.25),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        L.pick(en: 'Undo', zhTW: '撤回'),
                        style: YanciTheme.bodySmall.copyWith(
                          color: _undoStack.isNotEmpty
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.25,
                                ),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),

            // 調色盤與工具區
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: YanciTheme.glassInputBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YanciTheme.glassBorder),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: _currentColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            _buildGradientSlider(
                              label: L.pick(en: 'Hue', zhTW: '色相'),
                              value: _hue / 360.0,
                              colors: const [
                                Color(0xFFFF0000),
                                Color(0xFFFFFF00),
                                Color(0xFF00FF00),
                                Color(0xFF00FFFF),
                                Color(0xFF0000FF),
                                Color(0xFFFF00FF),
                                Color(0xFFFF0000),
                              ],
                              onChanged: (v) =>
                                  setState(() => _hue = v * 360.0),
                            ),
                            const SizedBox(height: 8),
                            _buildGradientSlider(
                              label: L.pick(en: 'Saturation', zhTW: '飽和度'),
                              value: _saturation,
                              colors: [
                                HSVColor.fromAHSV(
                                  1.0,
                                  _hue,
                                  0.0,
                                  _value,
                                ).toColor(),
                                HSVColor.fromAHSV(
                                  1.0,
                                  _hue,
                                  1.0,
                                  _value,
                                ).toColor(),
                              ],
                              onChanged: (v) => setState(() => _saturation = v),
                            ),
                            const SizedBox(height: 8),
                            _buildGradientSlider(
                              label: L.pick(en: 'Brightness', zhTW: '亮度'),
                              value: _value,
                              colors: [
                                Colors.black,
                                HSVColor.fromAHSV(
                                  1.0,
                                  _hue,
                                  _saturation,
                                  1.0,
                                ).toColor(),
                              ],
                              onChanged: (v) => setState(() => _value = v),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        L.pick(en: 'Tools', zhTW: '工具'),
                        style: YanciTheme.bodySmall,
                      ),
                      const SizedBox(width: 12),
                      _buildToolBtn(
                        Icons.brush,
                        !_isEraser,
                        () => setState(() => _isEraser = false),
                      ),
                      const SizedBox(width: 8),
                      _buildToolBtn(
                        Icons.format_color_reset,
                        _isEraser,
                        () => setState(() => _isEraser = true),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: YanciTheme.accent.withValues(
                            alpha: 0.2,
                          ),
                          foregroundColor: YanciTheme.accent,
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(L.pick(en: 'Save color', zhTW: '儲存顏色')),
                        onPressed: () {
                          if (!_savedColors.contains(_currentColor)) {
                            setState(
                              () => _savedColors.insert(0, _currentColor),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 32,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _savedColors.length,
                      itemBuilder: (context, index) {
                        final color = _savedColors[index];
                        return GestureDetector(
                          onTap: () {
                            final hsv = HSVColor.fromColor(color);
                            setState(() {
                              _hue = hsv.hue;
                              _saturation = hsv.saturation;
                              _value = hsv.value;
                              _isEraser = false;
                            });
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      _pushUndo();
                      setState(() {
                        _resetGrid();
                      });
                    },
                    child: Text(
                      L.pick(en: 'Clear', zhTW: '清空'),
                      style: TextStyle(color: YanciTheme.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: YanciTheme.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _exportAndSave,
                    child: Text(
                      L.pick(en: 'Finish and export', zhTW: '完成並匯出'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGradientSlider({
    required String label,
    required double value,
    required List<Color> colors,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label, style: YanciTheme.bodySmall)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) {
                  final percent =
                      (details.localPosition.dx / constraints.maxWidth).clamp(
                        0.0,
                        1.0,
                      );
                  onChanged(percent);
                },
                onPanUpdate: (details) {
                  final percent =
                      (details.localPosition.dx / constraints.maxWidth).clamp(
                        0.0,
                        1.0,
                      );
                  onChanged(percent);
                },
                child: Container(
                  height: 24,
                  alignment: Alignment.centerLeft,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: LinearGradient(colors: colors),
                        ),
                      ),
                      Positioned(
                        left: (value * constraints.maxWidth - 8).clamp(
                          0.0,
                          constraints.maxWidth - 16,
                        ),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolBtn(IconData icon, bool isActive, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isActive
              ? YanciTheme.accent.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? YanciTheme.accent : Colors.transparent,
          ),
        ),
        child: Icon(
          icon,
          color: isActive ? YanciTheme.accent : YanciTheme.textSecondary,
          size: 20,
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final List<List<Color?>> grid;
  final int gridSize;

  _GridPainter({required this.grid, required this.gridSize});

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = size.width / gridSize;
    final cellHeight = size.height / gridSize;

    // Draw background grid lines (optional, faint)
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 0; i <= gridSize; i++) {
      canvas.drawLine(
        Offset(0, i * cellHeight),
        Offset(size.width, i * cellHeight),
        gridPaint,
      );
      canvas.drawLine(
        Offset(i * cellWidth, 0),
        Offset(i * cellWidth, size.height),
        gridPaint,
      );
    }

    // Draw pixels
    final pixelPaint = Paint()..style = PaintingStyle.fill;
    for (int y = 0; y < gridSize; y++) {
      for (int x = 0; x < gridSize; x++) {
        final color = grid[y][x];
        if (color != null) {
          pixelPaint.color = color;
          canvas.drawRect(
            Rect.fromLTWH(x * cellWidth, y * cellHeight, cellWidth, cellHeight),
            pixelPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) {
    return true; // Simplified for this use case
  }
}
