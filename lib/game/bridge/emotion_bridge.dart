/// 情緒修飾層：emotion_coordinates → 小人的表情/氣泡修飾。
/// 規劃表 表五：閾值全在這裡，遊戲層只認枚舉。
enum YanciMood { neutral, upset, playful, longing }

class EmotionBridge {
  /// M3 TODO：讀 EmotionCoordinates.bars(characterId) 映射：
  ///   負面情緒 ≥60 → upset；戲謔 ≥60 → playful；慾望 ≥60 → longing。
  /// M1 先返回 neutral。
  static Future<YanciMood> currentMood(String characterId) async {
    return YanciMood.neutral;
  }
}
