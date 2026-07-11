/// 遊戲層全部常數 —— 魔法數字禁止散落在別處（審核表 A-3）
class GameConfig {
  // ═══ 像素規格（跟《像素遊戲內嵌規劃表》一致）═══
  static const int tileSize = 16;
  static const int spriteW = 16;
  static const int spriteH = 24;

  /// 整數縮放倍率（按 viewport 寬度取整數倍）
  /// 手機 / 小窗 → 2×，平板 / 桌面 → 3×，大螢幕 → 4×
  /// 保證像素永遠對齊，不出半像素模糊。
  static double pixelScaleFor(double viewportWidth) {
    if (viewportWidth >= 1920) return 4;
    if (viewportWidth >= 600) return 3;
    return 2;
  }

  /// 不需要 viewport 的場景用的預設值（SharedPreferences 載入前等）
  static const double defaultPixelScale = 3;

  // ═══ 佔位地圖（M1：Tiled 地圖就位前的代碼房間）═══
  static const int mapCols = 20;
  static const int mapRows = 14;

  // ═══ 全局小人 overlay ═══
  static const String prefsSpriteEnabled = 'pixel_sprite_enabled';
  static const String prefsSpriteX = 'pixel_sprite_x';
  static const String prefsSpriteY = 'pixel_sprite_y';

  /// 小人日常行為節奏（毫秒）
  static const int idleTickMs = 2600;
  static const double strollChance = 0.10; // 每次 tick 有 10% 起身散步
  static const double bubbleChanceOnTap = 0.35;
}
