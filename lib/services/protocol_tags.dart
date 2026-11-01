/// Holt 隱藏協議標籤的唯一清單。
///
/// 串流解碼（ModelStreamDecoder）、可見輸出（VisibleModelOutput）、
/// 氣泡顯示、工具剝離、聯網搜尋收尾都從這裡取。新增標籤只改這一處，
/// 處理器（解析標籤內容的地方）另外寫。
abstract final class ProtocolTags {
  /// 成對出現：`<tag ...>內容</tag>`。
  static const Set<String> block = <String>{
    'emo',
    'emo_resolve',
    'mood_color',
    'mood_color_lock',
    'memo',
    'memo_del',
    'memo_merge',
    'memo_update',
    'memo_link',
    'force_recall',
    'persona_note',
    'draw',
    'clock',
    'clock_keep',
    'clock_update',
    'clock_del',
    'life_fix',
    'home',
    'whisper',
    'search_chat',
    'search_web',
    'call',
    'x_post',
    'pack_star',
    'email_draft',
    'holt_diary',
    'holt_persona_draft',
    'tool_call',
    'tool_calls',
  };

  /// 單獨出現：`<tag .../>`。
  static const Set<String> standalone = <String>{
    'scratch',
    'transfer',
    'transfer_accept',
    'transfer_decline',
    'buy',
    'shop_view',
    'sign_marriage',
    'propose_marriage',
    'decline_call',
    'hangup',
    'mood_color_unlock',
  };

  static final String blockPattern = block.join('|');
  static final String standalonePattern = standalone.join('|');

  /// 從任一協議標籤的開頭一路刪到字串結尾（串流中途、殘缺標籤用）。
  static final RegExp openToEnd = RegExp(
    '<(?:$blockPattern|$standalonePattern)\\b[\\s\\S]*\$',
  );

  /// 模型偶爾不包 `[[HOLT_ACTIONS]]` 哨兵、直接吐 `{"actions":[...]}`。
  static final RegExp bareJsonActionStart = RegExp(r'\{\s*"actions"\s*:\s*\[');

  /// 從 [start]（指向 `{`）找配對的 `}`，會跳過 JSON 字串裡的括號與跳脫字元。
  /// 回傳 `}` 之後的位置；沒閉合回傳 -1。
  static int matchingJsonEnd(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == 0x5C) {
          escaped = true; // \
        } else if (ch == 0x22) {
          inString = false; // "
        }
        continue;
      }
      if (ch == 0x22) {
        inString = true;
      } else if (ch == 0x7B) {
        depth++; // {
      } else if (ch == 0x7D) {
        depth--; // }
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }

  /// 剝掉所有裸 JSON 動作區塊；沒閉合的一路刪到結尾（fail-closed）。
  static String stripBareJsonActions(String text) {
    var result = text;
    var searchFrom = 0;
    while (true) {
      final match = bareJsonActionStart.firstMatch(
        result.substring(searchFrom),
      );
      if (match == null) return result;
      final start = searchFrom + match.start;
      final end = matchingJsonEnd(result, start);
      if (end < 0) return result.substring(0, start);
      result = result.substring(0, start) + result.substring(end);
      searchFrom = start;
    }
  }
}
