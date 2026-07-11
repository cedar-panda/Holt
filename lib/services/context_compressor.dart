import 'dart:async';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import '../memory/database.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/local_ai_service.dart';
import '../services/locale_strings.dart';

/// 窗口摘要器 — 鏈式摘要 + 關鍵詞提取
///
/// 三層結構：
/// - 關鍵詞層 ≤ 1800 tokens（最舊摘要壓縮而來，觸發召回用）
/// - 摘要層   ≤ 3600 tokens（滾動更新，180-450t / block）
/// - 原文區   最新 ≤ 6000 tokens（未壓縮，觸發壓縮的計數池）
///
/// 觸發：token >= 6000
/// 鏈式：前次摘要 + 新 6000t → 小模型 → 新 block
class ContextCompressor {
  static const int triggerTokens = 6000;
  static const int minCompressTokens = 500;
  static const int summaryCapTokens = 3600;
  static const int keywordCapTokens = 1800;
  static const int latestSummaryBlocksForPrompt = 4;

  // A character's summary chain is shared by all of that character's
  // conversations. Queue writes per character so two windows cannot both
  // read the same tail and then race to append incompatible next blocks.
  static final Map<String, Future<void>> _characterCompressionTails = {};

  // Multiple lifecycle callbacks for the same window can fire together
  // (threshold trigger, route close, app pause). They represent the same
  // snapshot, so share the in-flight result instead of summarising it twice.
  static final Map<String, Future<int>> _conversationCompressionFlights = {};

  // ═══ 壓縮 prompt ═══
  // 「錯亂事實」的兩大根源已針對性加規則：
  //   1. 腦補——小模型愛推測動機、補因果 → 「只記明確發生的」
  //   2. 傳話漂移——鏈式整合時每輪 paraphrase 舊摘要，多輪後事實變形
  //      → 「前次摘要原樣保留措辭，只刪減與追加，不改寫」
  static const String _compressPromptZh = '''
你是窗口摘要器。將以下對話內容壓縮成簡潔的摘要。

規則：
- 只記錄對話中明確發生的事：說過的話、做過的決定、發生的事件
- 禁止推測動機、補充因果、解讀言外之意；對話裡沒有的一個字都不要寫
- 不確定的細節寧可省略，不要寫成模糊斷言
- 保留關鍵情節、情緒轉折、重要決定、人物關係變化
- 保留具體的名字、地點、時間、數字；重要的話保留原詞
- 去掉寒暄、重複、過渡語
- 用第三人稱，簡潔客觀
- 輸出 180-450 tokens（中文約 180-450 字）
- 只輸出摘要內容，不要前綴說明

如果有前次摘要：其中的內容原樣保留措辭，只做刪減與追加，不要改寫換說法。
''';

  static const String _compressPromptEn = '''
You are a context compressor. Compress the following conversation into a concise summary.

Rules:
- Record only what explicitly happened: things said, decisions made, events that occurred
- Never infer motives, add causality, or read between the lines; write nothing that is not in the conversation
- When a detail is uncertain, omit it rather than writing a vague claim
- Keep key events, emotional shifts, important decisions, relationship changes
- Keep specific names, places, times, numbers; keep important lines verbatim
- Remove greetings, repetition, filler
- Use third person, concise and objective
- Output 180-450 tokens
- Output only the summary, no prefix

If a previous summary is provided: keep its wording as-is, only trim or append — do not rephrase.
''';

  /// 簡中輸出強制指令：僅 zh_CN 語系附加；zh_TW / en 返回空字串，
  /// 既有語系的 prompt 文本逐字節不變（緩存前綴穩定鐵律，見
  /// docs/cache完整攻略指南）。壓縮請求本身不進聊天緩存條目。
  static String get _zhCnDirective =>
      L.locale == 'zh_CN' ? '\n请注意：请使用简体中文输出。' : '';

  static String _zhPrompt(String source) =>
      '${L.pick(en: '', zhTW: source)}$_zhCnDirective';

  // ═══ 關鍵詞提取 prompt ═══
  static const String _keywordPromptZh = '''
從以下摘要中提取關鍵詞。每 100 字（約 100 tokens）提取 1 個最重要的關鍵詞。
關鍵詞應該是具體的（人名、地名、事件名、物品名），不要選泛詞。
不要把 user 名、角色名、暱稱、稱謂當作關鍵詞。
每個關鍵詞用逗號分隔，只輸出關鍵詞列表。
''';

  static const String _keywordPromptEn = '''
Extract keywords from the following summary. Extract 1 keyword per ~100 tokens.
Keywords should be specific (names, places, events, items), not generic words.
Do not use the user's name, the character's name, nicknames, or pronouns as keywords.
Output only a comma-separated keyword list.
''';

  static const String _revisePromptZh = '''
你是窗口摘要修正器。根據使用者指出的問題，重寫這段窗口摘要。

規則：
- 只修正被指出的問題，不要新增沒有根據的內容
- 默認保留原摘要段格式：段落數、換行、項目符號、標籤、順序、語氣密度都不要改
- 除非使用者明確要求改格式，不要改成條列、標題、編號，也不要新增 P1/P2/段落一之類標記
- 保留重要情節、人物關係、情緒轉折、決定與具體資訊
- 用第三人稱，簡潔客觀
- 只輸出這一段修正後摘要，不要輸出其他段，不要前綴說明
''';

  static const String _revisePromptEn = '''
You are a window-summary editor. Rewrite this summary according to the issue described by the user.

Rules:
- Only fix the described issue; do not invent unsupported details
- Preserve the original segment format by default: paragraph count, line breaks, bullets, labels, ordering, and density
- Unless the user explicitly asks for a format change, do not convert it into bullets/headings/numbered sections, and do not add P1/P2/Paragraph labels
- Preserve key events, relationships, emotional shifts, decisions, and specifics
- Use third person, concise and objective
- Output only this revised segment, no other segments, no prefix
''';

  /// 執行壓縮（由觸發點調用）
  ///
  /// [messages] — 需要壓縮的對話原文（最近 6000t）
  /// [characterId] — 角色 ID
  ///
  /// 返回新摘要塊的 token 數，0 表示跳過
  static Future<int> compress({
    required List<Map<String, String>> messages,
    required String characterId,
    String? conversationId,
  }) {
    final normalizedCharacterId = characterId.trim().isEmpty
        ? 'default'
        : characterId.trim();
    final normalizedConversationId = (conversationId ?? '').trim();

    if (normalizedConversationId.isNotEmpty) {
      final existing =
          _conversationCompressionFlights[normalizedConversationId];
      if (existing != null) return existing;
    }

    final previous =
        _characterCompressionTails[normalizedCharacterId] ??
        Future<void>.value();
    final gate = Completer<void>();
    final tail = gate.future;
    _characterCompressionTails[normalizedCharacterId] = tail;

    late final Future<int> operation;
    operation = previous
        .then(
          (_) => _compressQueued(
            messages: messages,
            characterId: normalizedCharacterId,
            conversationId: normalizedConversationId,
          ),
        )
        .whenComplete(() {
          if (!gate.isCompleted) gate.complete();
          if (identical(
            _characterCompressionTails[normalizedCharacterId],
            tail,
          )) {
            _characterCompressionTails.remove(normalizedCharacterId);
          }
          if (normalizedConversationId.isNotEmpty &&
              identical(
                _conversationCompressionFlights[normalizedConversationId],
                operation,
              )) {
            _conversationCompressionFlights.remove(normalizedConversationId);
          }
        });

    if (normalizedConversationId.isNotEmpty) {
      _conversationCompressionFlights[normalizedConversationId] = operation;
    }
    return operation;
  }

  static Future<int> _compressQueued({
    required List<Map<String, String>> messages,
    required String characterId,
    required String conversationId,
  }) async {
    if (messages.isEmpty) return 0;

    // 構建原文
    final rawText = messages
        .map((m) => '[${m['role']}] ${m['content']}')
        .join('\n');
    final rawTokens = TokenEstimator.estimate(rawText);
    if (rawTokens < minCompressTokens) return 0; // 太短不壓

    // 取前次摘要（最新一塊）
    final existingSummaries = await DatabaseHelper.getContextSummaries(
      characterId,
    );
    String? prevSummary;
    if (existingSummaries.isNotEmpty) {
      prevSummary = existingSummaries.last['content'] as String;
    }

    // 組裝輸入
    final isEn = L.locale == 'en';
    final identity = await _buildIdentityContext(characterId);
    final promptParts = <String>[
      isEn ? _compressPromptEn : _zhPrompt(_compressPromptZh),
    ];
    if (identity.isNotEmpty) promptParts.add(identity);
    final prompt = promptParts.join('\n\n');
    final userContent = StringBuffer();
    if (prevSummary != null && prevSummary.isNotEmpty) {
      userContent.writeln(L.pick(en: '【Previous Summary】', zhTW: '【前次摘要】'));
      userContent.writeln(prevSummary);
      userContent.writeln();
    }
    userContent.writeln(L.pick(en: '【New Conversation】', zhTW: '【新對話內容】'));
    userContent.write(rawText);

    // 調用小模型
    final summaryText = await _callModel(
      systemPrompt: prompt,
      userMessage: userContent.toString(),
    );
    if (summaryText.isEmpty) return 0;

    final summaryTokens = TokenEstimator.estimate(summaryText);
    final sourceConversationId = conversationId;
    final sourceWindowId = sourceConversationId.isEmpty
        ? ''
        : await DatabaseHelper.ensureConversationWindowSummaryId(
            sourceConversationId,
          );

    // 存入摘要層
    await DatabaseHelper.insertContextSummary(
      characterId: characterId,
      content: summaryText,
      tokenCount: summaryTokens,
      sourceWindowId: sourceWindowId,
      sourceConversationId: sourceConversationId,
    );

    // 旋轉對話的 window_summary_id，讓舊的 sourceWindowId 被包含進未來的 prompt
    if (sourceConversationId.isNotEmpty) {
      await DatabaseHelper.rotateConversationWindowSummaryId(
        sourceConversationId,
      );
    }

    // 檢查摘要層是否溢出 → 擠出舊塊 → 提取關鍵詞
    await _enforceCapAndExtractKeywords(characterId);

    return summaryTokens;
  }

  /// 關窗壓縮：壓縮指定對話的最新內容
  static Future<int> compressOnClose({
    required String conversationId,
    required String characterId,
    int triggerTokenLimit = triggerTokens,
    int minTokenThreshold = triggerTokens,
    int? thresholdTokenCount,
  }) async {
    final messages = await DatabaseHelper.getMessages(conversationId);
    if (messages.isEmpty) return 0;

    // 估算 token
    final allText = messages.map((m) => m.text).join('\n');
    final totalTokens = TokenEstimator.estimate(allText);
    final comparableTokens = thresholdTokenCount ?? totalTokens;
    if (comparableTokens < minTokenThreshold) return 0; // 太短跳過

    // 取最近一段觸發窗口內的消息；單條最新消息超過上限時仍保留它，
    // 避免長訊息讓關窗摘要收成空窗口。
    final recentMsgs = <Map<String, String>>[];
    int accum = 0;
    for (int i = messages.length - 1; i >= 0; i--) {
      final t = TokenEstimator.estimate(messages[i].text);
      if (accum + t > triggerTokenLimit && recentMsgs.isNotEmpty) break;
      accum += t;
      recentMsgs.insert(0, {
        'role': messages[i].isUser ? 'user' : 'assistant',
        'content': messages[i].text,
      });
      if (accum >= triggerTokenLimit) break;
    }

    return compress(
      messages: recentMsgs,
      characterId: characterId,
      conversationId: conversationId,
    );
  }

  /// 載入摘要包。
  /// latest summaries 取最近幾塊；keyword recall 只回傳命中的單段。
  static Future<Map<String, String>> loadSummaryPack(
    String characterId, {
    String currentMessage = '',
    String? excludeWindowId,
    bool includeLatestSummaries = true,
    bool includeKeywordRecall = true,
  }) async {
    final summaryParts = <String>[];
    if (includeLatestSummaries) {
      final summaries = await DatabaseHelper.getLatestContextSummaries(
        characterId,
        excludeWindowId: excludeWindowId,
        limit: latestSummaryBlocksForPrompt,
      );
      summaryParts.addAll(summaries.reversed.map(_formatSummaryBlock));
    }

    String keywordSummary = '';
    if (includeKeywordRecall) {
      final keywords = await DatabaseHelper.getContextKeywords(characterId);
      keywordSummary =
          _recallKeywordSummarySegment(
            keywords,
            currentMessage: currentMessage,
            excludeWindowId: excludeWindowId,
          ) ??
          '';
    }

    return {
      'summary': summaryParts.join('\n\n'),
      'keywordSummaries': keywordSummary,
    };
  }

  /// 獲取調試信息（測試入口用）
  static Future<Map<String, dynamic>> getDebugInfo(String characterId) async {
    final summaries = await DatabaseHelper.getContextSummaries(characterId);
    final keywords = await DatabaseHelper.getContextKeywords(characterId);
    final summaryTotal = await DatabaseHelper.getContextSummaryTokenTotal(
      characterId,
    );
    final keywordTotal = await DatabaseHelper.getContextKeywordTokenTotal(
      characterId,
    );

    return {
      'summaryBlocks': summaries,
      'keywordBlocks': keywords,
      'summaryTokenTotal': summaryTotal,
      'keywordTokenTotal': keywordTotal,
      'summaryCap': summaryCapTokens,
      'keywordCap': keywordCapTokens,
    };
  }

  /// Debug 修正：把「問題描述 + 原摘要」交給摘要模型，返回修正版並覆蓋摘要塊。
  static Future<String> reviseSummaryBlock({
    required int id,
    required String characterId,
    required String originalSummary,
    required String issue,
  }) async {
    final revised = await _reviseSummaryText(
      characterId: characterId,
      originalSummary: originalSummary,
      issue: issue,
    );
    if (revised.isEmpty) return '';

    await DatabaseHelper.updateContextSummary(
      id: id,
      content: revised,
      tokenCount: TokenEstimator.estimate(revised),
    );
    return revised;
  }

  /// Debug 修正：只把被編輯的摘要段交給模型，返回後替換原 block 內同一段。
  static Future<String> reviseSummaryBlockSegment({
    required int id,
    required String characterId,
    required String fullSummary,
    required int segmentStart,
    required int segmentEnd,
    required String originalSegment,
    required String issue,
  }) async {
    final revisedSegment = await _reviseSummaryText(
      characterId: characterId,
      originalSummary: originalSegment,
      issue: issue,
    );
    if (revisedSegment.isEmpty) return '';

    final revisedFull = _replaceRange(
      fullSummary,
      segmentStart,
      segmentEnd,
      revisedSegment,
    );
    await DatabaseHelper.updateContextSummary(
      id: id,
      content: revisedFull,
      tokenCount: TokenEstimator.estimate(revisedFull),
    );
    return revisedFull;
  }

  /// Debug 修正：覆蓋 keyword block 保存的舊摘要快照，並重新提取關鍵詞。
  static Future<String> reviseKeywordSourceSummary({
    required int id,
    required String characterId,
    required String originalSummary,
    required String issue,
  }) async {
    final revised = await _reviseSummaryText(
      characterId: characterId,
      originalSummary: originalSummary,
      issue: issue,
    );
    if (revised.isEmpty) return '';

    final isEn = L.locale == 'en';
    final keywords = await _callModel(
      systemPrompt: isEn ? _keywordPromptEn : _zhPrompt(_keywordPromptZh),
      userMessage: revised,
    );
    final filtered = await _filterKeywordText(keywords, characterId);
    await DatabaseHelper.updateContextKeywordBlock(
      id: id,
      keywords: filtered,
      tokenCount: TokenEstimator.estimate(filtered),
      sourceSummaryContent: revised,
    );
    return revised;
  }

  /// Debug 修正：只修 keyword block 來源摘要中的單段，不把整塊摘要送給模型。
  static Future<String> reviseKeywordSourceSummarySegment({
    required int id,
    required String characterId,
    required String fullSummary,
    required int segmentStart,
    required int segmentEnd,
    required String originalSegment,
    required String issue,
    required String existingKeywords,
  }) async {
    final revisedSegment = await _reviseSummaryText(
      characterId: characterId,
      originalSummary: originalSegment,
      issue: issue,
    );
    if (revisedSegment.isEmpty) return '';

    final revisedFull = _replaceRange(
      fullSummary,
      segmentStart,
      segmentEnd,
      revisedSegment,
    );
    final isEn = L.locale == 'en';
    final keywords = await _callModel(
      systemPrompt: isEn ? _keywordPromptEn : _zhPrompt(_keywordPromptZh),
      userMessage: revisedSegment,
    );
    final filtered = await _filterKeywordText(keywords, characterId);
    final mergedKeywords = _mergeKeywordText(existingKeywords, filtered);
    await DatabaseHelper.updateContextKeywordBlock(
      id: id,
      keywords: mergedKeywords,
      tokenCount: TokenEstimator.estimate(mergedKeywords),
      sourceSummaryContent: revisedFull,
    );
    return revisedFull;
  }

  // ═══ 內部方法 ═══

  /// 強制摘要層上限 + 關鍵詞提取
  static Future<void> _enforceCapAndExtractKeywords(String characterId) async {
    var total = await DatabaseHelper.getContextSummaryTokenTotal(characterId);

    while (total > summaryCapTokens) {
      final db = await DatabaseHelper.database;
      final candidates = await db.query(
        'context_summaries',
        where: 'character_id = ? AND (locked IS NULL OR locked = 0)',
        whereArgs: [characterId],
        orderBy: 'created_at ASC, id ASC',
        limit: 1,
      );
      if (candidates.isEmpty) break;
      final oldest = candidates.first;

      final oldContent = oldest['content'] as String;
      final keywordText = await _extractKeywordText(
        characterId: characterId,
        summaryContent: oldContent,
      );
      if (keywordText.isEmpty) {
        developer.log(
          'Keyword extraction failed; preserving summary ${oldest['id']} for a later retry',
          name: 'ContextCompressor',
        );
        break;
      }

      final summaryId = oldest['id'] as int;
      final moved = await db.transaction<bool>((txn) async {
        final stillExists = await txn.query(
          'context_summaries',
          columns: ['id'],
          where: 'id = ? AND character_id = ?',
          whereArgs: [summaryId, characterId],
          limit: 1,
        );
        if (stillExists.isEmpty) return false;

        await txn.insert('context_keywords', {
          'character_id': characterId,
          'source_window_id': oldest['source_window_id'] as String? ?? '',
          'source_conversation_id':
              oldest['source_conversation_id'] as String? ?? '',
          'keywords': keywordText,
          'token_count': TokenEstimator.estimate(keywordText),
          'source_summary_id': summaryId,
          'source_summary_content': oldContent,
          'created_at': DateTime.now().toIso8601String(),
        });
        await txn.delete(
          'context_summaries',
          where: 'id = ? AND character_id = ?',
          whereArgs: [summaryId, characterId],
        );
        return true;
      });
      if (!moved) continue;

      total = await DatabaseHelper.getContextSummaryTokenTotal(characterId);
    }

    // 強制關鍵詞層上限
    var kwTotal = await DatabaseHelper.getContextKeywordTokenTotal(characterId);
    while (kwTotal > keywordCapTokens) {
      await DatabaseHelper.deleteOldestContextKeyword(characterId);
      kwTotal = await DatabaseHelper.getContextKeywordTokenTotal(characterId);
    }
  }

  /// 從摘要塊提取關鍵詞。呼叫端只有在成功取得非空結果後，才會於同一
  /// 筆 transaction 將摘要搬到關鍵詞層，避免模型失敗時先刪掉原資料。
  static Future<String> _extractKeywordText({
    required String characterId,
    required String summaryContent,
  }) async {
    final isEn = L.locale == 'en';
    final prompt = isEn ? _keywordPromptEn : _zhPrompt(_keywordPromptZh);

    final keywordText = await _callModel(
      systemPrompt: prompt,
      userMessage: summaryContent,
    );
    final filteredKeywordText = await _filterKeywordText(
      keywordText,
      characterId,
    );
    return filteredKeywordText;
  }

  static String? _recallKeywordSummarySegment(
    List<Map<String, dynamic>> keywordBlocks, {
    required String currentMessage,
    String? excludeWindowId,
  }) {
    final query = currentMessage.trim().toLowerCase();
    if (query.isEmpty) return null;
    final excluded = (excludeWindowId ?? '').trim();

    for (final block in keywordBlocks.reversed) {
      final sourceWindowId = (block['source_window_id'] as String? ?? '')
          .trim();
      if (excluded.isNotEmpty && sourceWindowId == excluded) continue;
      final source = (block['source_summary_content'] as String? ?? '').trim();
      if (source.isEmpty) continue;
      final matchedKeywords = (block['keywords'] as String? ?? '')
          .split(RegExp(r'[,，、\n]'))
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.length >= 2 && query.contains(k))
          .toList();
      if (matchedKeywords.isEmpty) continue;

      final segment = _pickMatchedSummarySegment(source, matchedKeywords);
      if (segment == null) continue;
      return _formatKeywordRecallBlock(
        segment,
        sourceWindowId: sourceWindowId,
        createdAt: block['created_at'] as String? ?? '',
      );
    }
    return null;
  }

  static String _formatSummaryBlock(Map<String, dynamic> block) {
    final content = (block['content'] as String? ?? '').trim();
    if (content.isEmpty) return '';
    final windowId = (block['source_window_id'] as String? ?? '').trim();
    final date = _dateLabel(block['created_at'] as String? ?? '');
    final meta = [
      if (windowId.isNotEmpty) '#$windowId',
      if (date.isNotEmpty) date,
    ].join(' | ');
    if (meta.isEmpty) return content;
    if (L.locale == 'en') return '[Window Summary $meta]\n$content';
    return '${L.pick(en: '', zhTW: '【窗口摘要')} $meta】\n$content';
  }

  static String _formatKeywordRecallBlock(
    _SummarySegment segment, {
    required String sourceWindowId,
    required String createdAt,
  }) {
    final date = _dateLabel(createdAt);
    final meta = [
      if (sourceWindowId.isNotEmpty) '#$sourceWindowId',
      if (date.isNotEmpty) date,
    ].join(' | ');
    final title = segment.title.trim();
    final header = L.locale == 'en'
        ? '[Keyword-matched old summary${meta.isEmpty ? '' : ' $meta'}]'
        : L.pick(en: '', zhTW: '【關鍵詞命中的舊摘要${meta.isEmpty ? '' : ' $meta'}】');
    if (title.isEmpty) return '$header\n${segment.content}';
    return '$header\n【$title】\n${segment.content}';
  }

  static _SummarySegment? _pickMatchedSummarySegment(
    String source,
    List<String> matchedKeywords,
  ) {
    final segments = _splitSummarySegments(source);
    for (final segment in segments.reversed) {
      final lower = segment.content.toLowerCase();
      if (matchedKeywords.any(lower.contains)) return segment;
    }
    if (segments.length == 1) return segments.first;
    return null;
  }

  static List<_SummarySegment> _splitSummarySegments(String source) {
    final lines = source.split('\n');
    final segments = <_SummarySegment>[];
    final headingRe = RegExp(
      r'^\s*(?:[#>*\-]+\s*)?(前情摘要|最新摘要|Previous Summary|Latest Summary|Prior Summary|Recent Summary)\s*[:：]?\s*$',
      caseSensitive: false,
    );

    String currentTitle = '';
    final buffer = <String>[];

    void flush() {
      final content = buffer.join('\n').trim();
      if (content.isNotEmpty) {
        segments.add(_SummarySegment(currentTitle, content));
      }
      buffer.clear();
    }

    for (final line in lines) {
      final match = headingRe.firstMatch(line);
      if (match != null) {
        flush();
        currentTitle = match.group(1)?.trim() ?? '';
      } else {
        buffer.add(line);
      }
    }
    flush();

    if (segments.isEmpty) {
      final trimmed = source.trim();
      return trimmed.isEmpty ? const [] : [_SummarySegment('', trimmed)];
    }
    return segments;
  }

  static String _dateLabel(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '';
    return '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }

  static Future<String> _filterKeywordText(
    String keywordText,
    String characterId,
  ) async {
    final forbidden = await _forbiddenKeywordTerms(characterId);
    final keywords = keywordText
        .split(RegExp(r'[,，、\n]'))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .where((k) {
          final normalized = k.toLowerCase();
          return !forbidden.any(
            (term) => normalized == term || normalized.contains(term),
          );
        })
        .toList();

    final seen = <String>{};
    final deduped = <String>[];
    for (final keyword in keywords) {
      final key = keyword.toLowerCase();
      if (seen.add(key)) deduped.add(keyword);
    }
    return deduped.join(', ');
  }

  static Future<Set<String>> _forbiddenKeywordTerms(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    final char = await DatabaseHelper.getCharacter(characterId);
    final terms = <String>{
      prefs.getString('user_profile_nickname') ?? '',
      prefs.getString('user_profile_pronouns') ?? '',
      await UserSettings.getUserName(),
      await UserSettings.getCharacterName(),
      char?['name'] as String? ?? '',
      char?['draw_anchor_user'] as String? ?? '',
      char?['draw_anchor_char'] as String? ?? '',
    };

    return terms
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.length >= 2)
        .toSet();
  }

  static Future<String> _reviseSummaryText({
    required String characterId,
    required String originalSummary,
    required String issue,
  }) async {
    final isEn = L.locale == 'en';
    final identity = await _buildIdentityContext(characterId);
    final promptParts = <String>[
      isEn ? _revisePromptEn : _zhPrompt(_revisePromptZh),
    ];
    if (identity.isNotEmpty) promptParts.add(identity);

    final issueHeader = L.pick(en: '【Issue】', zhTW: '【需要修正的問題】');
    final summaryHeader = L.pick(
      en: '【Original Summary Segment】',
      zhTW: '【原摘要段】',
    );
    final userMessage =
        '$issueHeader\n$issue\n\n$summaryHeader\n$originalSummary';

    final revised = await _callModel(
      systemPrompt: promptParts.join('\n\n'),
      userMessage: userMessage,
    );
    return _cleanRevisedSummaryText(revised);
  }

  static String _replaceRange(
    String text,
    int start,
    int end,
    String replacement,
  ) {
    if (start < 0 || end < start || end > text.length) return text;
    return '${text.substring(0, start)}$replacement${text.substring(end)}';
  }

  static String _cleanRevisedSummaryText(String text) {
    var out = text.trim();
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$').firstMatch(out);
    if (fence != null) out = fence.group(1)!.trim();
    out = out
        .replaceFirst(
          RegExp(r'^(修正後摘要|修正後|摘要|Revised Summary|Revised)\s*[:：]\s*'),
          '',
        )
        .trim();
    return out;
  }

  static String _mergeKeywordText(String existing, String added) {
    final seen = <String>{};
    final merged = <String>[];
    for (final source in [existing, added]) {
      for (final raw in source.split(RegExp(r'[,，]'))) {
        final keyword = raw.trim();
        final key = keyword.toLowerCase();
        if (keyword.isEmpty || seen.contains(key)) continue;
        seen.add(key);
        merged.add(keyword);
      }
    }
    return merged.join(', ');
  }

  /// 調用小模型（摘要綁定模型）
  static Future<String> _callModel({
    required String systemPrompt,
    required String userMessage,
  }) async {
    try {
      final source = await MemorySettings.getSummarySource();

      if (source == 'local' && LocalAiService.isReady) {
        final local = LocalAiService();
        return await local.sendMessage(
          messages: [
            {'role': 'user', 'content': userMessage},
          ],
          model: 'local',
          systemPrompt: systemPrompt,
        );
      }

      var model = await MemorySettings.getSummaryModel();
      if (model.isEmpty) {
        model = await ApiSettings.getModel();
      }
      final adapter = await ApiSettings.buildAdapter();
      return await adapter.sendMessage(
        messages: [
          {'role': 'user', 'content': userMessage},
        ],
        model: model,
        systemPrompt: systemPrompt,
      );
    } catch (e) {
      developer.log('窗口摘要失敗', error: e, name: 'ContextCompressor');
      return '';
    }
  }

  static Future<String> _buildIdentityContext(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    var userName = (prefs.getString('user_profile_nickname') ?? '').trim();
    if (userName.isEmpty) userName = (await UserSettings.getUserName()).trim();

    final char = await DatabaseHelper.getCharacter(characterId);
    var roleName = (char?['name'] as String? ?? '').trim();
    if (roleName.isEmpty) {
      roleName = (await UserSettings.getCharacterName()).trim();
    }
    final persona = (char?['description'] as String? ?? '').trim();

    if (userName.isEmpty && roleName.isEmpty && persona.isEmpty) return '';

    if (L.locale == 'en') {
      final parts = <String>[];
      if (userName.isNotEmpty) parts.add('User name: $userName');
      if (roleName.isNotEmpty) parts.add('Character name: $roleName');
      if (persona.isNotEmpty) parts.add('Character card/persona:\n$persona');
      return 'Identity anchors for disambiguation:\n${parts.join('\n')}';
    }

    final parts = <String>[];
    if (userName.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: 'user 名為：')}$userName');
    }
    if (roleName.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '模型扮演角色名為：')}$roleName');
    }
    if (persona.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '角色人設卡：')}\n$persona');
    }
    return '${L.pick(en: '', zhTW: '人物辨識錨點：')}\n${parts.join('\n')}';
  }
}

class _SummarySegment {
  final String title;
  final String content;

  const _SummarySegment(this.title, this.content);
}
