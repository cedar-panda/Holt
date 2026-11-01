import 'dart:convert';
import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'background_foreground_service.dart';
import '../utils/app_directories.dart';

enum SendButtonImageValidation {
  valid,
  notPng,
  notSquare,
  noTransparentBackground,
  notWhiteLineArt,
  unreadable,
}

/// 圖片壓縮 & 編碼服務
///
/// 壓縮交給 image_picker（選圖時 maxWidth/imageQuality），
/// 這裡只負責：複製到 app 目錄 + base64 編碼送 API。
class ImageService {
  static const List<int> _pngMagic = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  static SendButtonImageValidation validateSendButtonPngBytes(List<int> bytes) {
    if (bytes.length < _pngMagic.length) {
      return SendButtonImageValidation.notPng;
    }
    for (var i = 0; i < _pngMagic.length; i++) {
      if (bytes[i] != _pngMagic[i]) return SendButtonImageValidation.notPng;
    }
    img.Image? decoded;
    try {
      decoded = img.decodePng(Uint8List.fromList(bytes));
    } catch (_) {
      return SendButtonImageValidation.unreadable;
    }
    if (decoded == null) return SendButtonImageValidation.unreadable;
    if (decoded.width != decoded.height) {
      return SendButtonImageValidation.notSquare;
    }
    var transparentPixels = 0;
    var visiblePixels = 0;
    var whiteLinePixels = 0;
    for (final pixel in decoded) {
      final alpha = pixel.a.toInt();
      if (alpha <= 16) {
        transparentPixels++;
        continue;
      }
      visiblePixels++;
      final red = pixel.r.toInt();
      final green = pixel.g.toInt();
      final blue = pixel.b.toInt();
      final darkest = <int>[red, green, blue].reduce(math.min);
      final lightest = <int>[red, green, blue].reduce(math.max);
      if (darkest >= 180 && lightest - darkest <= 56) {
        whiteLinePixels++;
      }
    }
    if (transparentPixels == 0) {
      return SendButtonImageValidation.noTransparentBackground;
    }
    if (visiblePixels == 0 || whiteLinePixels / visiblePixels < 0.85) {
      return SendButtonImageValidation.notWhiteLineArt;
    }
    return SendButtonImageValidation.valid;
  }

  static Future<SendButtonImageValidation> validateSendButtonPng(
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) return SendButtonImageValidation.unreadable;
    return validateSendButtonPngBytes(await source.readAsBytes());
  }

  /// Copies a validated, byte-identical custom send-button PNG into Documents.
  static Future<String> copySendButtonToAppDir(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Send-button image does not exist', sourcePath);
    }
    final validation = await validateSendButtonPng(sourcePath);
    if (validation != SendButtonImageValidation.valid) {
      throw FormatException(validation.name);
    }
    final dir = await getAppDocumentsDirectory();
    final outPath = p.join(
      dir.path,
      'send_button_images',
      'send_button_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await Directory(p.dirname(outPath)).create(recursive: true);
    final sourceLength = await source.length();
    final copied = await source.copy(outPath);
    if (await copied.length() != sourceLength) {
      await copied.delete();
      throw FileSystemException(
        'Send-button image copy was incomplete',
        outPath,
      );
    }
    return outPath;
  }

  /// Deletes only App-owned custom send-button images.
  static Future<void> deleteSendButtonFile(String path) async {
    if (path.trim().isEmpty) return;
    try {
      final dir = await getAppDocumentsDirectory();
      final root = p.normalize(p.join(dir.path, 'send_button_images'));
      final target = p.normalize(path);
      if (!p.isWithin(root, target)) return;
      final file = File(target);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 同一毫秒內多張圖並行複製時，靠這個序號保證檔名不撞。
  static int _copySequence = 0;

  /// 複製圖片到 app 目錄（防止相簿清理後丟失）
  ///
  /// 多圖發送會用 Future.wait 並行呼叫；舊版只用毫秒時間戳命名，
  /// 同一毫秒的幾張圖會寫進同一個檔案互相覆蓋（顯示只剩一張、
  /// 檔案內容被交錯寫壞後 provider 回「無法處理圖片」）。
  static Future<String> copyToAppDir(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) return sourcePath;

    final dir = await getAppDocumentsDirectory();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.jpg';
    final name =
        'img_${DateTime.now().microsecondsSinceEpoch}_${_copySequence++}$ext';
    final outPath = p.join(dir.path, 'chat_images', name);
    await Directory(p.dirname(outPath)).create(recursive: true);
    await file.copy(outPath);
    return outPath;
  }

  /// 複製全域背景圖到 app 目錄。
  ///
  /// 背景圖是外觀資產，必須原檔複製，不做壓縮、裁切或重編碼。
  static Future<String> copyBackgroundToAppDir(
    String sourcePath,
    String scope,
  ) async {
    final file = File(sourcePath);
    if (!await file.exists()) return sourcePath;

    final dir = await getAppDocumentsDirectory();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.jpg';
    final safeScope = scope.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    // 新圖先完整落盤，成功後才清理舊圖；失敗時保留目前背景。
    final name = 'bg_${safeScope}_${DateTime.now().microsecondsSinceEpoch}$ext';
    final outPath = p.join(dir.path, 'background_images', name);
    await Directory(p.dirname(outPath)).create(recursive: true);
    final sourceLength = await file.length();
    final copied = await file.copy(outPath);
    final copiedLength = await copied.length();
    if (copiedLength != sourceLength) {
      await copied.delete();
      throw FileSystemException(
        'Background copy was not byte-preserving',
        outPath,
      );
    }
    await _deleteBackgroundImages(scope, except: outPath);
    return outPath;
  }

  /// 刪除指定 scope 的所有背景圖文件（換圖/清除時調用）
  static Future<void> deleteBackgroundImages(String scope) async {
    await _deleteBackgroundImages(scope);
  }

  static Future<void> _deleteBackgroundImages(
    String scope, {
    String? except,
  }) async {
    try {
      final dir = await getAppDocumentsDirectory();
      final safeScope = scope.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final bgDir = Directory(p.join(dir.path, 'background_images'));
      if (!await bgDir.exists()) return;
      await for (final f in bgDir.list()) {
        if (f is File &&
            f.path != except &&
            p.basename(f.path).startsWith('bg_${safeScope}_')) {
          BackgroundForegroundService.invalidate(f.path);
          await f.delete();
        }
      }
    } catch (_) {}
  }

  /// 刪除單一已保存的背景檔。只接受 App 的 background_images 目錄，避免
  /// 外部選圖路徑或其他媒體被誤刪。
  static Future<void> deleteBackgroundFile(String path) async {
    if (path.trim().isEmpty) return;
    try {
      final dir = await getAppDocumentsDirectory();
      final root = p.normalize(p.join(dir.path, 'background_images'));
      final target = p.normalize(path);
      if (!p.isWithin(root, target)) return;
      final file = File(target);
      if (await file.exists()) {
        BackgroundForegroundService.invalidate(target);
        await file.delete();
      }
    } catch (_) {}
  }

  /// 簡單去除圖片白底（從四個角落進行 Flood Fill）
  static Future<String?> removeWhiteBackground(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) return null;

    if (!image.hasAlpha) {
      image = image.convert(numChannels: 4);
    }

    final targetImage =
        image; // Use non-null reference to avoid closure demotion

    final width = targetImage.width;
    final height = targetImage.height;

    // We will start flood fill from the 4 corners.
    // If the corner is close to white, we flood fill it with transparent.
    // Near white tolerance: R>220, G>220, B>220 (lowered to catch anti-aliased fringes)
    bool isNearWhite(img.Pixel p) {
      return p.r > 220 && p.g > 220 && p.b > 220;
    }

    final visited = List.generate(height, (_) => List.filled(width, false));
    final queue = Queue<List<int>>();

    void tryEnqueue(int x, int y) {
      if (x >= 0 && x < width && y >= 0 && y < height) {
        if (!visited[y][x] && isNearWhite(targetImage.getPixel(x, y))) {
          visited[y][x] = true;
          queue.add([x, y]);
        }
      }
    }

    tryEnqueue(0, 0);
    tryEnqueue(width - 1, 0);
    tryEnqueue(0, height - 1);
    tryEnqueue(width - 1, height - 1);

    final dx = [0, 0, 1, -1];
    final dy = [1, -1, 0, 0];
    final transparent = img.ColorRgba8(0, 0, 0, 0);

    while (queue.isNotEmpty) {
      final pt = queue.removeFirst();
      final x = pt[0];
      final y = pt[1];

      targetImage.setPixel(x, y, transparent);

      for (int i = 0; i < 4; i++) {
        final nx = x + dx[i];
        final ny = y + dy[i];
        if (nx >= 0 &&
            nx < width &&
            ny >= 0 &&
            ny < height &&
            !visited[ny][nx]) {
          if (isNearWhite(targetImage.getPixel(nx, ny))) {
            visited[ny][nx] = true;
            queue.add([nx, ny]);
          }
        }
      }
    }

    final outBytes = img.encodePng(targetImage);
    final dir = await getAppDocumentsDirectory();
    final name = 'transparent_${DateTime.now().millisecondsSinceEpoch}.png';
    final outPath = p.join(dir.path, 'shop_items', name);
    await Directory(p.dirname(outPath)).create(recursive: true);
    final outFile = File(outPath);
    await outFile.writeAsBytes(outBytes);
    return outPath;
  }

  /// 將圖片轉為 base64 data URL（送 API 用）
  ///
  /// image_picker 在 Android 上可能把不含透明通道的 PNG 重新編碼成
  /// JPEG，卻保留原本的 .png 檔名。因此 MIME 必須依檔案內容判斷，
  /// 不能相信副檔名，否則上游會以 media type 不相符拒絕整個請求。
  /// 長邊上限：Anthropic 視覺最優尺寸，超過只是白燒 token
  static const int _kMaxSide = 1568;

  /// 體積閾值：已知格式且小於它的圖直接放行，省一次完整解碼
  static const int _kSkipBytes = 600 * 1024;

  static bool _hasSignature(
    List<int> bytes,
    List<int> signature, {
    int offset = 0,
  }) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  static String? _detectMimeType(List<int> bytes) {
    if (_hasSignature(bytes, const [0xff, 0xd8, 0xff])) {
      return 'image/jpeg';
    }
    if (_hasSignature(bytes, const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ])) {
      return 'image/png';
    }
    if (_hasSignature(bytes, const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
        _hasSignature(bytes, const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
      return 'image/gif';
    }
    if (_hasSignature(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        _hasSignature(bytes, const [0x57, 0x45, 0x42, 0x50], offset: 8)) {
      return 'image/webp';
    }
    return null;
  }

  /// 已編碼結果的小型 LRU：窗口內的舊圖每輪都會重送，避免每輪重新解碼。
  /// key 含檔案大小與修改時間，檔案被替換時自然失效。
  static const int _kDataUrlCacheSize = 24;
  static final LinkedHashMap<String, String> _dataUrlCache =
      LinkedHashMap<String, String>();

  static Future<String?> toBase64DataUrl(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final cacheKey =
        '$imagePath|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final cached = _dataUrlCache.remove(cacheKey);
    if (cached != null) {
      _dataUrlCache[cacheKey] = cached;
      return cached;
    }

    final bytes = await file.readAsBytes();
    // 解碼／重新編碼是純 Dart 運算，放到背景 isolate，避免多圖時卡 UI。
    // 用 compute 而不是 Isolate.run：Web 版沒有 dart:isolate。
    final dataUrl = await compute(_encodeForApi, bytes);
    _dataUrlCache[cacheKey] = dataUrl;
    while (_dataUrlCache.length > _kDataUrlCacheSize) {
      _dataUrlCache.remove(_dataUrlCache.keys.first);
    }
    return dataUrl;
  }

  /// 送 API 前的圖片正規化（在背景 isolate 執行）。
  ///
  /// - 一律先解碼驗證：壞檔在本地擋下，不送出去讓 provider 整輪 400。
  /// - 小於 [_kSkipBytes] 的 JPEG／PNG／WebP 原樣送出（位元組不變）。
  /// - GIF 一律轉檔：Gemini 不收 GIF。
  /// - 其他情況縮到長邊 [_kMaxSide]；有透明通道 → PNG，否則 → JPEG。
  ///   （舊版不透明的大 PNG 截圖仍重編成 PNG，一張 1～2MB，多圖很容易撐爆請求。）
  static String _encodeForApi(Uint8List source) {
    var bytes = source;
    var mime = _detectMimeType(bytes);

    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) {
      throw const FormatException('無法辨識圖片內容，請將圖片另存為 PNG、JPEG、GIF 或 WebP 後重試');
    }

    final passThrough =
        bytes.length <= _kSkipBytes &&
        (mime == 'image/jpeg' || mime == 'image/png' || mime == 'image/webp');
    if (!passThrough) {
      var normalized = decoded;
      final maxSide = normalized.width > normalized.height
          ? normalized.width
          : normalized.height;
      if (maxSide > _kMaxSide) {
        normalized = normalized.width >= normalized.height
            ? img.copyResize(normalized, width: _kMaxSide)
            : img.copyResize(normalized, height: _kMaxSide);
      }

      if (normalized.hasAlpha) {
        bytes = img.encodePng(normalized);
        mime = 'image/png';
      } else {
        bytes = img.encodeJpg(normalized, quality: 82);
        mime = 'image/jpeg';
      }
    }

    return 'data:$mime;base64,${base64Encode(bytes)}';
  }
}
