/// 結構化 System Prompt（支持 prompt caching）
/// static → 人設卡內容（不變，可緩存）
/// dynamic → 記憶注入 + 時間 + 表情包（仍屬 system context）
///
/// Claude 的快取層級是 tools → system → messages。若 system 每輪改變，
/// 後面的歷史快取會整段失效；因此開啟 Claude cache 時，聊天窗口會另外提供
/// [cacheStableDynamicPart]。它只在該窗口生命週期內固定，不會混入 user。
class StructuredPrompt {
  final String staticPart;
  final String? profilePart;
  final String dynamicPart;
  final String? cacheStableDynamicPart;
  final String cacheChannel;

  StructuredPrompt({
    required this.staticPart,
    this.profilePart,
    this.dynamicPart = '',
    this.cacheStableDynamicPart,
    this.cacheChannel = 'text',
  });

  /// Cache off 用即時 dynamic；Claude cache on 用窗口固定快照。
  String dynamicForCache({required bool enabled}) =>
      enabled ? (cacheStableDynamicPart ?? dynamicPart) : dynamicPart;

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

typedef ApiUsageCallback = void Function(ApiUsage usage);

/// 單次 API 請求自己的用量與診斷。不得再由消費端讀 provider 的全域
/// 「最後一筆」，否則聊天、摘要、命名與保活併發時會互相覆蓋。
class ApiUsage {
  final int promptTokens;
  final int completionTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final Map<String, int> raw;
  final Map<String, Object?> diagnostics;

  const ApiUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.raw = const <String, int>{},
    this.diagnostics = const <String, Object?>{},
  });

  bool get hasTokenCounts => promptTokens > 0 || completionTokens > 0;

  factory ApiUsage.fromStats(
    Map<String, int> stats, {
    String cacheReadKey = 'cache_read',
    String cacheCreationKey = 'cache_creation',
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) {
    return ApiUsage(
      promptTokens: stats['prompt_tokens'] ?? 0,
      completionTokens: stats['completion_tokens'] ?? 0,
      cacheReadTokens: stats[cacheReadKey] ?? 0,
      cacheCreationTokens: stats[cacheCreationKey] ?? 0,
      raw: Map<String, int>.unmodifiable(stats),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }
}

/// API 統一接口
abstract class ApiAdapter {
  /// [messages] 中 role=user 的正文是用戶原文。Adapter 不得把記憶、時間、
  /// Thinking 或其他系統內容拼入其中；這些內容只能來自 systemPrompt /
  /// structuredPrompt。
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  });

  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  });

  /// 中止目前由此 adapter 建立的 HTTP 串流。沒有遠端串流的 adapter 可沿用
  /// 預設 no-op；網路 adapter 必須覆寫並 close active client。
  void cancelActive() {}
}

/// 共用：Anthropic 風格滾動緩存斷點（1 小時 TTL）
/// 掛在「最新 user 之前的最後一條消息」的最後一個 block 上，
/// 緩存邊界停在純歷史上，最新 user 永遠不帶 cache_control。
class CacheBreakpoint {
  static void applyAt(
    List<Map<String, dynamic>> allMessages,
    int index, {
    Map<String, String>? cacheControl,
  }) {
    if (index < 0 || index >= allMessages.length) return;
    final blocks = toBlocks(allMessages[index]['content']);
    if (blocks.isEmpty) return;
    blocks.last['cache_control'] = Map<String, String>.from(
      cacheControl ?? const {'type': 'ephemeral'},
    );
    allMessages[index]['content'] = blocks;
  }

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
    // 最新 user 是本輪增量，所以只標它前一條。
    if (limit <= minIndex) return;
    final idx = limit - 1;

    applyAt(allMessages, idx, cacheControl: control);
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
