import 'dart:convert';
import 'dart:collection';
import 'package:image/image.dart' as img;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// 圖片壓縮 & 編碼服務
///
/// 壓縮交給 image_picker（選圖時 maxWidth/imageQuality），
/// 這裡只負責：複製到 app 目錄 + base64 編碼送 API。
class ImageService {
  /// 複製圖片到 app 目錄（防止相簿清理後丟失）
  static Future<String> copyToAppDir(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) return sourcePath;

    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.jpg';
    final name = 'img_${DateTime.now().millisecondsSinceEpoch}$ext';
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

    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.jpg';
    final safeScope = scope.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    // 換圖前先清同 scope 的舊圖——舊版每次都存新時間戳文件，
    // 換十次背景磁盤裡躺十張，清除按鈕也只清設定不刪文件
    await deleteBackgroundImages(scope);
    final name = 'bg_${safeScope}_${DateTime.now().millisecondsSinceEpoch}$ext';
    final outPath = p.join(dir.path, 'background_images', name);
    await Directory(p.dirname(outPath)).create(recursive: true);
    await file.copy(outPath);
    return outPath;
  }

  /// 刪除指定 scope 的所有背景圖文件（換圖/清除時調用）
  static Future<void> deleteBackgroundImages(String scope) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeScope = scope.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final bgDir = Directory(p.join(dir.path, 'background_images'));
      if (!await bgDir.exists()) return;
      await for (final f in bgDir.list()) {
        if (f is File && p.basename(f.path).startsWith('bg_${safeScope}_')) {
          await f.delete();
        }
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
    final dir = await getApplicationDocumentsDirectory();
    final name = 'transparent_${DateTime.now().millisecondsSinceEpoch}.png';
    final outPath = p.join(dir.path, 'shop_items', name);
    await Directory(p.dirname(outPath)).create(recursive: true);
    final outFile = File(outPath);
    await outFile.writeAsBytes(outBytes);
    return outPath;
  }

  /// 將圖片轉為 base64 data URL（送 API 用）
  /// 不做二次壓縮——image_picker 選圖時已壓過
  /// 長邊上限：Anthropic 視覺最優尺寸，超過只是白燒 token
  static const int _kMaxSide = 1568;

  /// 體積閾值：小於它且不知尺寸的圖直接放行，省一次解碼
  static const int _kSkipBytes = 600 * 1024;

  static Future<String?> toBase64DataUrl(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) return null;

    var bytes = await file.readAsBytes();

    // ═══ 壓縮：原圖整張 base64 會概率性撞 provider 體積上限
    // （手機原相機照片動輒 4~12MB，base64 再膨脹 1.33x）═══
    if (bytes.length > _kSkipBytes) {
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          var im = decoded;
          final maxSide = im.width > im.height ? im.width : im.height;
          if (maxSide > _kMaxSide) {
            im = im.width >= im.height
                ? img.copyResize(im, width: _kMaxSide)
                : img.copyResize(im, height: _kMaxSide);
          }
          bytes = img.encodeJpg(im, quality: 82);
          return 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      } catch (_) {
        // 解碼失敗就按原樣發，至少不擋路
      }
    }

    final b64 = base64Encode(bytes);
    final ext = p.extension(imagePath).toLowerCase();
    final mime = ext == '.png' ? 'image/png' : 'image/jpeg';
    return 'data:$mime;base64,$b64';
  }
}
