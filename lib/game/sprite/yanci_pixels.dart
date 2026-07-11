import 'dart:ui';

/// 佔位像素小人 —— YANCI-32 配色，16×24。
///
/// 全局 overlay 和 Flame 遊戲共用同一份數據。
/// Aseprite sprite sheet 畫好之後，只需要換掉這個文件的實現
/// （改成從 assets 載圖），兩邊自動跟上。
///
/// 字符 → 顏色映射（一格一字符，'.' = 透明）：
///   O 夜墨線稿  K 墨髮  k 髮光  S 膚  s 膚影
///   W 月白眼白  E 瞳琥珀  R 酒紅毛衣  D 衣物陰影  B 墨青褲
class YanciPixels {
  static const Map<String, int> _palette = {
    'O': 0xFF1A1721, // 夜墨
    'K': 0xFF3D3A45, // 墨髮
    'k': 0xFF59545F, // 髮光
    'S': 0xFFF0D5B8, // 膚
    's': 0xFFD3A687, // 膚影
    'W': 0xFFEFEAF2, // 月白
    'E': 0xFFC99A4B, // 瞳琥珀
    'R': 0xFF5C2E35, // 酒紅
    'D': 0xFF2B2633, // 暗紫灰（衣物陰影）
    'B': 0xFF384252, // 墨青
  };

  /// 站姿（呼吸由外層 Transform 做，不佔幀）
  static const List<String> idle = [
    '................',
    '.....OOOOOO.....',
    '....OKKKKKKO....',
    '...OKKKKKKKKO...',
    '...OKkKKKKkKO...',
    '...OKKKKKKKKO...',
    '...OKSSSSSSKO...',
    '..OKSSSSSSSSKO..',
    '..OKSWESSWESKO..',
    '..OKSSSSSSSSKO..',
    '..OKsSSSSSSsKO..',
    '..OKOSSSSSSOKO..',
    '..OKKOssssOKKO..',
    '..OKORRRRRROKO..',
    '..OkORRRRRROkO..',
    '...ORRRRRRRRO...',
    '...OsRRRRRRsO...',
    '....ORRRRRRO....',
    '....ODRRRRDO....',
    '...OBBBBBBBBO...',
    '...OBBBBBBBBO...',
    '....OSS..SSO....',
    '....Oss..ssO....',
    '....OOO..OOO....',
  ];

  /// 眨眼（只有眼睛那一行不同）
  static const List<String> blink = [
    '................',
    '.....OOOOOO.....',
    '....OKKKKKKO....',
    '...OKKKKKKKKO...',
    '...OKkKKKKkKO...',
    '...OKKKKKKKKO...',
    '...OKSSSSSSKO...',
    '..OKSSSSSSSSKO..',
    '..OKSssSSssSKO..',
    '..OKSSSSSSSSKO..',
    '..OKsSSSSSSsKO..',
    '..OKOSSSSSSOKO..',
    '..OKKOssssOKKO..',
    '..OKORRRRRROKO..',
    '..OkORRRRRROkO..',
    '...ORRRRRRRRO...',
    '...OsRRRRRRsO...',
    '....ORRRRRRO....',
    '....ODRRRRDO....',
    '...OBBBBBBBBO...',
    '...OBBBBBBBBO...',
    '....OSS..SSO....',
    '....Oss..ssO....',
    '....OOO..OOO....',
  ];

  /// 收腿（蹦跳步的騰空幀：走路 = idle 和 tuck 交替 + 水平位移；
  /// 被揪起來也是這幀——裙擺在、腿縮著）
  static const List<String> tuck = [
    '................',
    '.....OOOOOO.....',
    '....OKKKKKKO....',
    '...OKKKKKKKKO...',
    '...OKkKKKKkKO...',
    '...OKKKKKKKKO...',
    '...OKSSSSSSKO...',
    '..OKSSSSSSSSKO..',
    '..OKSWESSWESKO..',
    '..OKSSSSSSSSKO..',
    '..OKsSSSSSSsKO..',
    '..OKOSSSSSSOKO..',
    '..OKKOssssOKKO..',
    '..OKORRRRRROKO..',
    '..OkORRRRRROkO..',
    '...ORRRRRRRRO...',
    '...OsRRRRRRsO...',
    '....ORRRRRRO....',
    '....ODRRRRDO....',
    '...OBBBBBBBBO...',
    '...OBBBBBBBBO...',
    '....Oss..ssO....',
    '....OOO..OOO....',
    '................',
  ];

  /// 把一幀畫到 canvas。[scale] 是整數縮放倍數，像素感三件套之一。
  static void paintFrame(Canvas canvas, List<String> frame, double scale) {
    final paint = Paint()..filterQuality = FilterQuality.none;
    for (int y = 0; y < frame.length; y++) {
      final row = frame[y];
      for (int x = 0; x < row.length; x++) {
        final color = _palette[row[x]];
        if (color == null) continue;
        paint.color = Color(color);
        canvas.drawRect(
          Rect.fromLTWH(x * scale, y * scale, scale, scale),
          paint,
        );
      }
    }
  }
}
