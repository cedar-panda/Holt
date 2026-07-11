/// 結構化 System Prompt（支持 prompt caching）
/// static → 人設卡內容（不變，可緩存）
/// dynamic → 記憶注入 + 時間 + 表情包（每次變）
class StructuredPrompt {
  final String staticPart;
  final String? profilePart;
  final String dynamicPart;

  StructuredPrompt({
    required this.staticPart,
    this.profilePart,
    this.dynamicPart = '',
  });

  /// 不支持 caching 的 provider 直接合成一個字串
  String get combined {
    final parts = <String>[staticPart];
    if (profilePart != null && profilePart!.isNotEmpty) {
      parts.add(profilePart!);
    }
    if (dynamicPart.isNotEmpty) {
      parts.add(dynamicPart);
    }
    return parts.join('\n\n');
  }
}

/// API 統一接口
abstract class ApiAdapter {
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  });

  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  });
}

/// 共用：Anthropic 風格滾動緩存斷點（1 小時 TTL）
/// 掛在「最新 user 之前的最後一條消息」的最後一個 block 上，
/// 緩存邊界停在純歷史上，含 dynamic 的最新消息為未緩存增量。
class CacheBreakpoint {
  static void applyRolling(
    List<Map<String, dynamic>> allMessages, {
    int minIndex = 1,
    int? maxIndexExclusive,
    Map<String, String>? cacheControl,
  }) {
    final control = cacheControl ?? {'type': 'ephemeral'};
    var limit = maxIndexExclusive ?? allMessages.length;
    if (limit > allMessages.length) limit = allMessages.length;
    if (limit < minIndex) limit = minIndex;

    // OpenRouter / Anthropic 的 prefix cache 最穩定邊界：
    // 最新 user 會塞入每輪變動的 dynamic prompt，所以只標它前一條。
    if (limit <= minIndex) return;
    final idx = limit - 1;

    final content = allMessages[idx]['content'];

    // 無論原本是 List 還是 String，都統一轉為 blocks 格式
    final blocks = toBlocks(content);
    if (blocks.isNotEmpty) {
      blocks.last['cache_control'] = Map<String, String>.from(control);
    }
    allMessages[idx]['content'] = blocks;
  }

  static int latestUserIndex(List<Map<String, dynamic>> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') return i;
    }
    return -1;
  }

  /// 把純字串 content 統一為 blocks 格式（已是 blocks 的原樣保留）
  static List<Map<String, dynamic>> toBlocks(dynamic content) {
    if (content is List) {
      return content.map((b) => Map<String, dynamic>.from(b as Map)).toList();
    }
    return <Map<String, dynamic>>[
      {'type': 'text', 'text': content?.toString() ?? ''},
    ];
  }
}

/// 緩存會話錨點：以對話為單位
/// 換新對話 = 新 session（前綴本就不同，乾淨切開）；
/// 進出同一對話 = 同 session（命中中的緩存不被打斷）。
/// chat_screen 進入對話時設置。
class CacheSession {
  static String conversationId = '';
}
