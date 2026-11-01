import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../memory/database.dart';
import '../models/message.dart';
import '../models/context_mode.dart';
import '../services/character_timeline_service.dart';
import '../services/rp_character_timeline_service.dart';
import '../services/rp_story_service.dart';
import '../services/rp_story_state_service.dart';
import '../services/rp_worldbook_service.dart';
import '../services/rp_summary_prompt.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/token_tracker.dart';
import '../services/api_adapter.dart';
import '../services/app_error_log_service.dart';
import '../services/local_ai_service.dart';
import '../services/locale_strings.dart';
import '../services/recall_text_matcher.dart';
import '../services/user_persona_service.dart';

/// 窗口摘要器 — 鏈式摘要 + 關鍵詞提取
///
/// 三層結構：
/// - 關鍵詞層完整保存（最舊摘要壓縮而來，只作觸發索引）
/// - 摘要層   ≤ 3600 tokens（滾動更新，180-450t / block）
/// - 原文區   從成功游標起約 6000 tokens（邊界氣泡完整納入，可略超）
///
/// 觸發：token >= 6000
/// 鏈式：前次摘要 + 游標後完整氣泡批次 → 小模型 → 新 block
class ContextCompressor {
  static const int triggerTokens = 6000;
  static const int minCompressTokens = 500;
  static const int summaryCapTokens = 3600;
  static const int rpLiveContinuityMaxChars = 4000;
  static const int rpStoryReferenceReserveChars = 1200;
  static const int rpStoryContextMaxChars = 1800;
  static const int rpContinuationRecallReserveChars = 400;

  /// Legacy diagnostic value kept for old debug consumers. Recall labels are
  /// no longer evicted by a token cap; only matched event segments are sent to
  /// the chat model, so retaining the complete local index does not enlarge a
  /// normal prompt.
  @Deprecated('RP recall labels are retained without a storage token cap.')
  static const int keywordCapTokens =
      DatabaseHelper.contextKeywordIndexTokenCap;
  static const int latestSummaryBlocksForPrompt = 4;

  /// A message-count trigger is an explicit user-selected cadence. It must not
  /// inherit the token-based 500-token floor, otherwise a short oldest batch
  /// can keep the summary cursor at zero forever and every later retry will
  /// select the same unprocessable messages again.
  static int minimumSourceTokensForTrigger({int? triggerMessageLimit}) =>
      triggerMessageLimit == null ? minCompressTokens : 1;

  @visibleForTesting
  static int suggestedRpSummaryMaxCharsForSource(int sourceCharacters) {
    if (sourceCharacters >= 1200000) return 4000;
    if (sourceCharacters >= 700000) return 3400;
    if (sourceCharacters >= 300000) return 2800;
    if (sourceCharacters >= 100000) return 2200;
    return 1200;
  }

  static Future<int> effectiveRpSummaryMaxChars({
    required String characterId,
    required String continuityId,
  }) async {
    final userCeiling = await MemorySettings.getRpSummaryMaxChars();
    if (!await MemorySettings.getRpSummaryAutoMaxCharsEnabled()) {
      return userCeiling;
    }
    final sourceCharacters =
        await DatabaseHelper.getRpStorylineSourceCharacterCount(
          characterId: characterId,
          continuityId: continuityId,
        );
    return suggestedRpSummaryMaxCharsForSource(
      sourceCharacters,
    ).clamp(800, userCeiling).toInt();
  }

  /// User rules are optional preferences. They may shape emphasis and wording,
  /// but cannot replace the storage schema, source evidence, storyline scope,
  /// revision semantics, or other data-integrity requirements above them.
  static Future<String> summaryPromptForRequest({
    required ContextMode contextMode,
    required String characterId,
    required String continuityId,
  }) async {
    final rpMaxChars = contextMode == ContextMode.rp
        ? await effectiveRpSummaryMaxChars(
            characterId: characterId,
            continuityId: continuityId,
          )
        : RpSummaryPrompt.defaultMaxChars;
    final base = compressionPromptForMode(contextMode, rpMaxChars: rpMaxChars);
    final custom = await MemorySettings.getSummaryCustomRules(
      contextMode: contextMode.storageValue,
    );
    if (custom.isEmpty) return base;
    return '$base\n\n${L.pick(en: '''【User summary preferences】
Apply the following preferences only where they do not conflict with the required JSON schema, source evidence, storyline isolation, narrative layers, revision/source-range rules, or factual accuracy. Those system requirements always take priority.''', zhTW: '''【使用者自定義摘要偏好】
以下內容只調整摘要的關注重點與表達方式；若與必要 JSON schema、來源證據、故事線隔離、敘事層級、修訂／來源範圍規則或事實正確性衝突，必須以前述系統規則為準。''', zhCN: '''【用户自定义摘要偏好】
以下内容只调整摘要的关注重点与表达方式；若与必要 JSON schema、来源证据、故事线隔离、叙事层级、修订／来源范围规则或事实正确性冲突，必须以前述系统规则为准。''')}\n$custom';
  }

  // A character's summary chain is shared by all of that character's
  // conversations. Queue writes per character so two windows cannot both
  // read the same tail and then race to append incompatible next blocks.
  static final Map<String, Future<void>> _characterCompressionTails = {};

  // Multiple lifecycle callbacks for the same window can fire together
  // (threshold trigger, route close, app pause). They represent the same
  // snapshot, so share the in-flight result instead of summarising it twice.
  static final Map<String, Future<int>> _conversationCompressionFlights = {};

  // ═══ 壓縮 + 時間線候選 prompt ═══
  // 詳細規格由本地驗證器與測試承擔；正式 prompt 只保留正向准入條件，
  // 避免長禁令清單既燒 token，又把不希望出現的概念反覆提示給小模型。
  static const String _compressPromptZh = '''
整合【最近摘要基底】與帶有消息 ID、本地時間及發言者的【新對話內容】。
【最近摘要基底】最多包含最近兩份有效摘要，按較早到最新排列。兩份摘要可能互相包含；先合併重複內容，再加入本輪內容。

summary：輸出對小模型友善的具名輕手記，保留「前情提要」與「本次摘要」兩部分。
- 只記錄對話中明確發生的事：說過的話、做過的決定、發生的事件
- 禁止推測動機、補充因果、解讀言外之意；對話裡沒有的一個字都不要寫
- 不確定的細節寧可省略，不要寫成模糊斷言
- 保留關鍵情節、情緒轉折、重要決定、人物關係變化
- 保留具體的名字、地點、時間、數字；重要的話保留原詞
- 去掉寒暄、重複、過渡語
- 每一條都直接寫出雙方姓名；不使用「我、你、妳、使用者、User、AI」代稱
- 每輪輸出的 summary 是目前完整的滾動摘要，不是只描述本輪的增量附錄
- 最近摘要基底中的重點事件必須繼續存在。可以縮短措辭、合併重複事件或用新狀態更新舊狀態，但不能省略事件主體、發生內容、必要原因、結果及持續影響
- 已收束事件仍保留「起因、結果、影響」；只有 User 明確修正、來源被判定無效或舊狀態被新狀態取代時才改寫
- 內容完整優先，不為湊字數重複
- summary 欄位只放摘要正文，不要前綴說明
- 使用以下 Markdown 結構：
  ## 前情提要
  最多 10 條，整合【最近摘要基底】中仍有效的重點事件
  ## 本次摘要
  最多 5 條，整理【新對話內容】帶來的新增、修正與進展
- 每條直接以「- [MM/DD] 」或有時間時「- [MM/DD HH:mm] 」開頭；無可靠日期時只用「- 」
- 每條寫成一句有溫度但忠於原文的具名相處手記，保留情緒與互動細節
- 不使用編號區塊、粗體分類、主題標籤或公文式套殼

timeline：只從【新對話內容】提取屬於角色本人或雙方關係、對後續有持續回憶價值的候選。event 是已完成的角色事件或雙方共同事件；state 是目前仍持續的狀態，key 使用髮型、美甲、鬍子、住所、工作、寵物、健康、關係狀態、生理週期之一；狀態開始或結束本身使用 event。subject 使用 character；雙方共同事件或關係狀態使用 relationship。每項的 occurred_on 一律填寫 YYYY-MM-DD：原文有明確日期時使用該日期並標記 date_basis=explicit；原文是可依消息 local_time 換算的相對日期時，換算後標記 date_basis=relative；沒有劇情日期但符合記錄條件時，使用該消息的本地日期並標記 date_basis=message_time。source_message_ids 全部來自新對話，evidence 是來源原文片段，value 保留其核心用詞。「第 N 天」只保留在 value 與 evidence，不得填入 occurred_on；開始日由本地驗證器計算。同一項合併，按 occurred_on 從早到晚排列。
新對話明確說出角色「生理期第 N 天／開始／結束／今天仍在生理期」時必須輸出 character 候選：第 N 天或當下仍在生理期使用 state、key=生理週期；開始或結束使用 event；evidence 逐字取自來源消息。
時間線相關內容有關角色健康（含生理期），可能持續 2 天以上的不適，不論男女角色皆輸出到時間線，請甄別清楚是否為角色內容。

只輸出合法 JSON：{"summary":"文字","timeline":[{"type":"event","subject":"relationship","source_message_ids":[1],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","value":"第三人稱事件","evidence":"原文"},{"type":"state","subject":"character","source_message_ids":[2],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","key":"健康","value":"第三人稱狀態","evidence":"原文"}]}。無候選時 timeline 為空陣列。
''';

  static const String _compressPromptEn = '''
Combine 【Recent Summary Anchors】 with 【New Conversation】, whose messages include ids, local timestamps, and speaker roles. The anchor block contains up to the two most recent valid summaries in older-to-newer order. Merge their overlap before adding this batch.

summary: Output a small-model-friendly named interaction journal with Prior Context and This Update.
- Record only what explicitly happened: things said, decisions made, events that occurred
- Never infer motives, add causality, or read between the lines; write nothing absent from the conversation
- When a detail is uncertain, omit it rather than writing a vague claim
- Keep key events, emotional shifts, important decisions, and relationship changes
- Keep specific names, places, times, numbers, and important original wording
- Remove greetings, repetition, and filler
- Name both people directly in every entry. Do not use I, me, you, user, User, AI, or similar pronouns/role labels
- Output the complete current rolling summary, not an incremental note about this batch
- Every important event from the recent summary anchors must remain represented. Wording may be shortened, duplicates merged, and superseded state updated, but the actor, event, necessary cause, result, and lasting effect cannot be omitted
- A closed event still keeps its cause, result, and effect. Rewrite it only when the user explicitly corrects it, its source is invalidated, or a newer state replaces an older state
- Put only the summary body in the summary field, with no prefix
- Use this Markdown structure:
  ## Prior Context
  Up to 10 entries integrating still-valid important events from 【Recent Summary Anchors】
  ## This Update
  Up to 5 entries covering additions, corrections, and developments from 【New Conversation】
- Start each entry with "- [MM/DD] " or "- [MM/DD HH:mm] " when reliable; otherwise use "- "
- Write one warm but source-faithful named interaction note per entry, retaining emotional and interpersonal details
- Do not use numbered sections, bold category labels, topic wrappers, or report-style headings

timeline: Extract only lasting candidates belonging to the character or the shared relationship from 【New Conversation】. An event is a completed character event or shared event. A state is a condition that is still ongoing, whose key is hairstyle, nails, beard, residence, work, pet, health, relationship status, or menstrual cycle; use event for the start or end of a state itself. Use subject=character, or subject=relationship for shared events and relationship status. occurred_on must always be YYYY-MM-DD: use an explicit source date with date_basis=explicit; resolve a relative date from the message local_time with date_basis=relative; when no story date is stated but the item qualifies, use the message local date with date_basis=message_time. Cite only new source_message_ids, quote exact source text as evidence, and retain its core wording in value. Preserve wording such as "day N" only in value and evidence, never in occurred_on; the local validator derives its start date. Merge one item and order occurred_on oldest to newest.
When new conversation explicitly states that the character's period is on day N, started, ended, or is still active today, a character candidate is required. Day N or an active current period uses type=state and key=menstrual cycle; start/end uses type=event; evidence is an exact source substring.
For timeline content about the character's health (including menstruation), record discomfort that may last two or more days for characters of any gender, while carefully verifying that it belongs to the character.

Output valid JSON only: {"summary":"text","timeline":[{"type":"event","subject":"relationship","source_message_ids":[1],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","value":"third-person event","evidence":"exact quote"},{"type":"state","subject":"character","source_message_ids":[2],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","key":"health","value":"third-person state","evidence":"exact quote"}]}. Use an empty timeline array when none qualify.
''';

  @visibleForTesting
  static String compressionPromptForTesting({bool english = false}) =>
      english ? _compressPromptEn : _compressPromptZh;

  static String get currentCompressionPrompt =>
      L.locale == 'en' ? _compressPromptEn : _zhPrompt(_compressPromptZh);

  /// RP keeps the normal summary contract but replaces the entire daily
  /// timeline section. Daily health/menstrual ownership rules never enter the
  /// RP request.
  static String compressionPromptForMode(
    ContextMode mode, {
    int rpMaxChars = RpSummaryPrompt.defaultMaxChars,
  }) {
    final base = currentCompressionPrompt;
    if (mode == ContextMode.daily) return base;
    return RpSummaryPrompt.compose(base, rpMaxChars);
  }

  /// RP dossiers keep their own section vocabulary. Daily normalization would
  /// rewrite them into Prior Context / This Update and lose the dossier shape.
  static String normalizeRpSummaryFormat(String raw) {
    var text = raw.trim().replaceAll('\r\n', '\n');
    final fence = RegExp(
      r'^```(?:markdown)?\s*([\s\S]*?)\s*```$',
    ).firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    final lines = text.split('\n');
    while (lines.isNotEmpty &&
        RegExp(
          r'^(?:這是我整理的|这是我整理的|Here is (?:the|my)|Story Dossier|劇情摘要|剧情摘要)',
          caseSensitive: false,
        ).hasMatch(lines.first.trim())) {
      lines.removeAt(0);
    }
    return lines.join('\n').trim();
  }

  /// This rule scopes only the timeline field; the summary still covers both
  /// speakers normally.
  static String characterOnlyTimelineRule(
    String characterName, {
    DateTime? today,
  }) {
    final name = characterName.trim().isEmpty ? '角色本人' : characterName.trim();
    final date = today ?? DateTime.now();
    final todayText =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return L.pick(
      en: 'MANDATORY timeline-only rule: Today is $todayText. For character health or discomfort that may last two or more days, output timeline content only when it belongs to the character "$name". Never record the user\'s own health. If the subject cannot be confirmed as "$name", output no timeline item. Every candidate must include its own concrete occurred_on date (YYYY-MM-DD), resolved from source local_time and today\'s date. The summary field still covers both speakers normally.',
      zhTW:
          '強制要求（只約束時間線欄位）：今天日期是 $todayText。時間線相關內容涉及角色健康或可能持續 2 天以上的不適時，請輸出到時間線；時間線只記錄與「$name」本人有關的內容，不得記錄 user／使用者本人的健康內容。若無法確認是「$name」本人，請不要輸出時間線項目。每個候選都必須根據來源 local_time 與今天日期填寫各自具體的 occurred_on（YYYY-MM-DD）。summary 摘要正文仍正常記錄雙方內容。',
    );
  }

  /// Canonical storage contract shared by automatic summaries, manual
  /// summaries, full-block revisions, and keyword-source snapshots. Prompting
  /// asks the model for this shape; this finalizer guarantees it even when a
  /// provider ignores Markdown instructions or adds its own wrapper.
  static String normalizeSummaryFormat(String raw, {String? locale}) {
    var text = raw.trim().replaceAll('\r\n', '\n');
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    text = text
        .replaceFirst(
          RegExp(
            r'^(?:【\s*(?:手動摘要|手动摘要|Manual Summary)\s*】|'
            r'\[\s*(?:Manual Summary|手動摘要|手动摘要)\s*\])\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (text.isEmpty) return '';

    final activeLocale = locale ?? L.locale;
    final priorHeading = activeLocale == 'en' ? 'Prior Context' : '前情提要';
    final updateHeading = activeLocale == 'en' ? 'This Update' : '本次摘要';
    final headingPattern = RegExp(
      r'^\s*(?:#{1,6}\s*)?'
      r'(前情提要|前情摘要|先前摘要|本次摘要|最新摘要|'
      r'Prior Context|Previous Summary|Prior Summary|'
      r'This Update|Latest Summary|Recent Summary)\s*[:：]?\s*$',
      caseSensitive: false,
    );
    final priorAliases = <String>{
      '前情提要',
      '前情摘要',
      '先前摘要',
      'prior context',
      'previous summary',
      'prior summary',
    };

    final preamble = <String>[];
    final prior = <String>[];
    final update = <String>[];
    List<String>? target;
    var sawHeading = false;
    for (final line in text.split('\n')) {
      final match = headingPattern.firstMatch(line);
      if (match != null) {
        sawHeading = true;
        final label = (match.group(1) ?? '').toLowerCase();
        target = priorAliases.contains(label) ? prior : update;
        continue;
      }
      (target ?? preamble).add(line);
    }

    if (!sawHeading) {
      update.addAll(preamble);
      preamble.clear();
    } else if (preamble.any((line) => line.trim().isNotEmpty)) {
      // Preserve facts from a provider-added preface instead of silently
      // discarding them. They describe context before the first named part.
      prior.insertAll(0, preamble);
    }

    String journalBody(List<String> lines) {
      final entries = <String>[];
      for (final rawLine in lines) {
        var line = rawLine.trim();
        if (line.isEmpty || line == '—') continue;
        if (RegExp(r'^\*\*\d+\.\s+.+\*\*$').hasMatch(line)) continue;
        line = line
            .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
            .replaceFirst(RegExp(r'^[-*]\s+'), '')
            .replaceFirst(RegExp(r'^\*\*[^*]+[:：]\*\*\s*'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (line.isNotEmpty) entries.add('- $line');
      }
      return entries.isEmpty ? '—' : entries.join('\n');
    }

    return '## $priorHeading\n${journalBody(prior)}\n\n'
        '## $updateHeading\n${journalBody(update)}';
  }

  /// 簡中輸出強制指令：僅 zh_CN 語系附加；zh_TW / en 返回空字串。
  /// 壓縮請求使用獨立 adapter 調用，不進聊天緩存條目，因此調整摘要
  /// 與時間線規則不會改動 Claude 對話的緩存前綴。
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

  static const String _rpKeywordPromptZh = '''
從以下 RP 劇情摘要提取可用於日後召回原摘要的事件標籤。
每個標籤使用「具體對象＋實際行動／結果／轉折」或能唯一定位事件的專有詞組，使後續對話即使只提到事件的一部分，也能找到正確摘要。優先選擇具體事件、地點與事件的組合、關鍵物品及其用途、身份變化、組織行動、承諾內容、衝突結果或未解線索。
標籤本身必須具有事件意義；人名、稱謂或情緒只有和具體事件組合時才可使用。相似事件只保留辨識度最高的一項，不輸出近義重複標籤。
輸出 3 至 5 個高辨識度標籤，每項 2 至 16 個中文字，以逗號分隔。只輸出標籤列表。
''';

  static const String _rpKeywordPromptEn = '''
Extract event labels that can later recall this RP story summary.
Build each label from a concrete subject plus an actual action, outcome, or turn, or use a specific phrase that uniquely locates the event. Prefer concrete events, a place paired with its event, an important item and its use, an identity change, an organization action, the content of a promise, the result of a conflict, or an unresolved clue.
A label must carry event meaning. A name, title, or emotion may appear only when combined with a concrete event. Keep the most distinctive label for similar events and omit near-duplicates.
Output 3-5 high-identity labels, each 2-16 words, comma-separated. Output labels only.
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
  /// [messages] — 需要壓縮的完整消息氣泡
  /// [characterId] — 角色 ID
  ///
  /// 返回新摘要塊的 token 數，0 表示跳過
  static Future<int> compress({
    required List<Message> messages,
    required String characterId,
    String? conversationId,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    int minimumSourceTokens = minCompressTokens,
    int? sourceMessageStartIdOverride,
    int? displayAnchorMessageIdOverride,
    bool triggerWorldbook = true,
    bool isRepair = false,
    int? repairSummaryId,
  }) {
    final sourceMessages = summaryEligibleMessages(messages);
    if (sourceMessages.isEmpty) return Future<int>.value(0);
    final normalizedCharacterId = characterId.trim().isEmpty
        ? 'default'
        : characterId.trim();
    final normalizedConversationId = (conversationId ?? '').trim();

    if (normalizedConversationId.isNotEmpty) {
      final existing =
          _conversationCompressionFlights[normalizedConversationId];
      if (existing != null) {
        if (isRepair) {
          return existing.then(
            (_) => compress(
              messages: sourceMessages,
              characterId: characterId,
              conversationId: conversationId,
              contextMode: contextMode,
              continuityId: continuityId,
              minimumSourceTokens: minimumSourceTokens,
              sourceMessageStartIdOverride: sourceMessageStartIdOverride,
              displayAnchorMessageIdOverride: displayAnchorMessageIdOverride,
              triggerWorldbook: triggerWorldbook,
              isRepair: true,
              repairSummaryId: repairSummaryId,
            ),
          );
        }
        return existing;
      }
    }

    final chainKey =
        '$normalizedCharacterId\u0000${contextMode.storageValue}\u0000$continuityId';
    final previous =
        _characterCompressionTails[chainKey] ?? Future<void>.value();
    final gate = Completer<void>();
    final tail = gate.future;
    _characterCompressionTails[chainKey] = tail;

    late final Future<int> operation;
    operation = previous
        .then(
          (_) => _compressQueued(
            messages: sourceMessages,
            characterId: normalizedCharacterId,
            conversationId: normalizedConversationId,
            contextMode: contextMode,
            continuityId: continuityId,
            minimumSourceTokens: minimumSourceTokens,
            sourceMessageStartIdOverride: sourceMessageStartIdOverride,
            displayAnchorMessageIdOverride: displayAnchorMessageIdOverride,
            triggerWorldbook: triggerWorldbook,
            isRepair: isRepair,
            repairSummaryId: repairSummaryId,
          ),
        )
        .whenComplete(() {
          if (!gate.isCompleted) gate.complete();
          if (identical(_characterCompressionTails[chainKey], tail)) {
            _characterCompressionTails.remove(chainKey);
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
    required List<Message> messages,
    required String characterId,
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
    required int minimumSourceTokens,
    required int? sourceMessageStartIdOverride,
    required int? displayAnchorMessageIdOverride,
    required bool triggerWorldbook,
    required bool isRepair,
    required int? repairSummaryId,
  }) async {
    if (messages.isEmpty) return 0;
    if (!isRepair) {
      final db = await DatabaseHelper.database;
      final pending = await db.query(
        'context_summary_repairs',
        columns: const <String>['id'],
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND status != 'completed'",
        whereArgs: <Object?>[
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        limit: 1,
      );
      if (pending.isNotEmpty) return 0;
    }

    final rawTokens = messages.fold<int>(
      0,
      (total, message) => total + TokenEstimator.estimate(message.text),
    );
    if (rawTokens < minimumSourceTokens) return 0; // 太短不壓

    // Snowball chain: every new summary receives the two newest valid
    // summaries in the same mode/storyline, older first. Include archived
    // rows here because archiving only changes live-recall storage; it must
    // not silently remove a recent chain anchor from the next summary pass.
    final existingSummaries = await DatabaseHelper.getContextSummaries(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
      includeArchived: true,
    );
    final rollingSummaryAnchors = existingSummaries.length <= 2
        ? existingSummaries
        : existingSummaries.sublist(existingSummaries.length - 2);

    // 組裝輸入
    final identity = await _loadSummaryIdentity(
      characterId,
      conversationId: conversationId,
    );
    final identityPrompt = identity.format(includePersona: false);
    final rawText = messages
        .map(
          (message) => _formatSourceMessage(
            message,
            userName: identity.userName,
            characterName: identity.characterName,
          ),
        )
        .join('\n\n');
    final promptParts = <String>[
      await summaryPromptForRequest(
        contextMode: contextMode,
        characterId: characterId,
        continuityId: continuityId,
      ),
    ];
    if (identityPrompt.isNotEmpty) promptParts.add(identityPrompt);
    if (contextMode == ContextMode.daily) {
      promptParts.add(_namedJournalIdentityRule(identity));
      promptParts.add(
        characterOnlyTimelineRule(
          identity.characterName,
          today: DateTime.now(),
        ),
      );
    }
    final prompt = promptParts.join('\n\n');
    final sourceIds =
        messages
            .map((message) => message.id)
            .whereType<int>()
            .toList(growable: false)
          ..sort();
    final sourceWindowId = conversationId.isEmpty
        ? ''
        : await DatabaseHelper.ensureConversationWindowSummaryId(
            conversationId,
          );
    final userContent = StringBuffer();
    if (contextMode == ContextMode.rp) {
      userContent.writeln(
        await buildRpArchiveContext(
          characterId: characterId,
          continuityId: continuityId,
          conversationId: conversationId,
          sourceText: rawText,
        ),
      );
      userContent.writeln();
      userContent.writeln(
        L.pick(
          en: '【Existing Story Dossiers · older to newer】',
          zhTW: '【既有劇情摘要 · 較早到最新】',
          zhCN: '【既有剧情摘要 · 较早到最新】',
        ),
      );
      userContent.writeln(
        _formatRollingSummaryAnchors(
          rollingSummaryAnchors,
          contextMode: contextMode,
        ),
      );
      userContent.writeln();
      userContent.writeln(
        L.pick(
          en: '【Summary Source Range】',
          zhTW: '【摘要來源範圍】',
          zhCN: '【摘要来源范围】',
        ),
      );
      userContent.writeln(
        jsonEncode(<String, Object?>{
          'storyline_id': continuityId,
          'source_window_id': sourceWindowId,
          'source_conversation_id': conversationId,
          'source_message_start_id': sourceIds.isEmpty ? null : sourceIds.first,
          'source_message_end_id': sourceIds.isEmpty ? null : sourceIds.last,
        }),
      );
      userContent.writeln();
    } else if (rollingSummaryAnchors.isNotEmpty) {
      userContent.writeln(
        L.pick(en: '【Recent Summary Anchors】', zhTW: '【最近摘要基底】'),
      );
      userContent.writeln(
        _formatRollingSummaryAnchors(
          rollingSummaryAnchors,
          contextMode: contextMode,
        ),
      );
      userContent.writeln();
    }
    userContent.writeln(
      contextMode == ContextMode.rp
          ? L.pick(
              en: '【New Dialogue to Archive】',
              zhTW: '【本輪待歸檔對話】',
              zhCN: '【本轮待归档对话】',
            )
          : L.pick(en: '【New Conversation】', zhTW: '【新對話內容】'),
    );
    userContent.write(rawText);

    // 調用小模型。既有卷宗是連續性參考，不是永久標題清單；
    // 已結束且不再影響後續的事件可從新卷宗離開，原始摘要與
    // recall_segments 仍留在本地。不再依標題差異把舊事件強制灌回。
    final response = await _callModel(
      characterId: characterId,
      conversationId: conversationId,
      systemPrompt: prompt,
      userMessage: userContent.toString(),
    );
    final decoded = decodeSummaryEnvelope(response);
    if (contextMode == ContextMode.rp &&
        decoded.storylineId.isNotEmpty &&
        decoded.storylineId != continuityId) {
      developer.log(
        'RP summary storyline mismatch: expected=$continuityId '
        'actual=${decoded.storylineId}',
        name: 'ContextCompressor',
      );
      return 0;
    }
    var summaryText = contextMode == ContextMode.rp
        ? normalizeRpSummaryFormat(decoded.summary)
        : normalizeSummaryFormat(decoded.summary);
    if (summaryText.isEmpty) {
      try {
        await AppErrorLogService.record(
          error: const FormatException('摘要模型回傳內容無法解析為有效摘要'),
          trigger: 'automatic_summary_decode',
          source: 'summary',
        );
      } catch (_) {
        // Diagnostics must never replace the original summary failure.
      }
      return 0;
    }
    if (contextMode == ContextMode.rp) {
      final rpSummaryMaxChars = await effectiveRpSummaryMaxChars(
        characterId: characterId,
        continuityId: continuityId,
      );
      summaryText = compactRpSummaryToHardLimit(summaryText, rpSummaryMaxChars);
      developer.log(
        'RP summary projections decoded: '
        'characters=${decoded.storyCharacters.length} '
        'relationships=${decoded.relationships.length} '
        'states=${decoded.storyStates.length}',
        name: 'ContextCompressor',
      );
    }
    if (conversationId.isNotEmpty &&
        !await DatabaseHelper.messageSnapshotsStillCurrent(messages)) {
      developer.log(
        'Discarded stale summary result because its source was edited or deleted',
        name: 'ContextCompressor',
      );
      return 0;
    }
    final timelineCandidates = contextMode == ContextMode.daily
        ? await recoverMissingMenstrualCandidates(
            messages: messages,
            candidates: decoded.timeline,
            characterId: characterId,
          )
        : decoded.timeline;

    final summaryTokens = TokenEstimator.estimate(summaryText);
    final recallSegments = contextMode == ContextMode.rp
        ? buildRpRecallSegmentDrafts(
            summary: summaryText,
            modelSegments: decoded.recallSegments,
          )
        : const <ContextSummarySegmentDraft>[];
    final sourceConversationId = conversationId;

    final cursorMessageId = messages
        .map((message) => message.id ?? 0)
        .fold<int>(0, (largest, id) => id > largest ? id : largest);
    final displayAnchorMessageId = sourceConversationId.isEmpty
        ? null
        : displayAnchorMessageIdOverride ??
              await DatabaseHelper.getLatestMessageId(sourceConversationId);
    final int summaryId;
    if (isRepair && repairSummaryId != null) {
      summaryId = await DatabaseHelper.insertContextSummary(
        characterId: characterId,
        content: summaryText,
        tokenCount: summaryTokens,
        sourceWindowId: sourceWindowId,
        sourceConversationId: sourceConversationId,
        displayAnchorMessageId: displayAnchorMessageId ?? cursorMessageId,
        sourceMessageStartId:
            sourceMessageStartIdOverride ??
            (sourceIds.isEmpty ? null : sourceIds.first),
        sourceMessageEndId: sourceIds.isEmpty ? null : sourceIds.last,
        replaceSummaryId: repairSummaryId,
        replaceInvalidatedSummary: true,
        contextMode: contextMode,
        continuityId: continuityId,
        expectedSourceMessages: messages,
        allowPendingRepairs: true,
        recallSegments: recallSegments,
      );
    } else if (sourceConversationId.isNotEmpty && cursorMessageId > 0) {
      summaryId = await DatabaseHelper.insertContextSummaryAndAdvanceCursor(
        characterId: characterId,
        content: summaryText,
        tokenCount: summaryTokens,
        conversationId: sourceConversationId,
        cursorMessageId: cursorMessageId,
        displayAnchorMessageId: displayAnchorMessageId ?? cursorMessageId,
        sourceMessageStartId: sourceMessageStartIdOverride,
        sourceWindowId: sourceWindowId,
        contextMode: contextMode,
        continuityId: continuityId,
        expectedSourceMessages: messages,
        allowPendingRepairs: isRepair,
        recallSegments: recallSegments,
      );
    } else {
      summaryId = await DatabaseHelper.insertContextSummary(
        characterId: characterId,
        content: summaryText,
        tokenCount: summaryTokens,
        sourceWindowId: sourceWindowId,
        sourceConversationId: sourceConversationId,
        contextMode: contextMode,
        continuityId: continuityId,
        expectedSourceMessages: messages,
        recallSegments: recallSegments,
      );
    }
    if (summaryId <= 0) return 0;

    // RP projections are written only after their source summary exists.
    // Each service rechecks that revision inside its own transaction.
    if (contextMode == ContextMode.rp) {
      await RpCharacterTimelineService.storeSummaryCandidates(
        characterId: characterId,
        continuityId: continuityId,
        sourceConversationId: sourceConversationId,
        candidates: timelineCandidates,
        sourceMessages: messages,
        sourceSummaryId: summaryId,
      );
    } else {
      await CharacterTimelineService.storeSummaryCandidates(
        characterId: characterId,
        candidates: timelineCandidates,
        sourceMessages: messages,
      );
    }

    // Mutable RP state must point at the summary revision that proposed it.
    // Persisting it only after the summary exists also prevents an orphaned
    // state row when summary insertion or cursor advancement fails.
    if (contextMode == ContextMode.rp) {
      await RpStoryService.storeExtraction(
        characterId: characterId,
        continuityId: continuityId,
        sourceConversationId: sourceConversationId,
        characters: decoded.storyCharacters,
        relationships: decoded.relationships,
        sourceMessages: messages,
        sourceSummaryId: summaryId,
      );
      await RpStoryStateService.storeExtraction(
        characterId: characterId,
        continuityId: continuityId,
        sourceConversationId: sourceConversationId,
        states: decoded.storyStates,
        sourceMessages: messages,
        sourceSummaryId: summaryId,
      );
    }

    // 旋轉對話的 window_summary_id，讓舊的 sourceWindowId 被包含進未來的 prompt
    if (sourceConversationId.isNotEmpty) {
      await DatabaseHelper.rotateConversationWindowSummaryId(
        sourceConversationId,
      );
    }

    await recycleSupersededSummaries(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    if (contextMode == ContextMode.rp && triggerWorldbook) {
      unawaited(
        RpWorldbookService.maybeProcessAfterSummary(
          characterId: characterId,
          continuityId: continuityId,
          triggerConversationId: sourceConversationId,
        ),
      );
    }

    return summaryTokens;
  }

  /// 關窗壓縮：壓縮指定對話的最新內容
  static Future<int> compressOnClose({
    required String conversationId,
    required String characterId,
    int triggerTokenLimit = triggerTokens,
    int minTokenThreshold = triggerTokens,
    int? thresholdTokenCount,
    int? triggerMessageLimit,
    int? minMessageThreshold,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final cursor = await DatabaseHelper.getConversationSummaryCursor(
      conversationId,
    );
    final messages = summaryEligibleMessages(
      await DatabaseHelper.getMessagesAfterId(conversationId, cursor),
    );
    if (messages.isEmpty) return 0;

    if (triggerMessageLimit != null) {
      final minimum = minMessageThreshold ?? triggerMessageLimit;
      if (messages.length < minimum) return 0;
      final recentMsgs = selectWholeMessageBatch(messages, triggerMessageLimit);
      return compress(
        messages: recentMsgs,
        characterId: characterId,
        conversationId: conversationId,
        contextMode: contextMode,
        continuityId: continuityId,
        minimumSourceTokens: minimumSourceTokensForTrigger(
          triggerMessageLimit: triggerMessageLimit,
        ),
      );
    }

    final totalTokens = _estimateMessageTokens(messages);
    final comparableTokens = thresholdTokenCount ?? totalTokens;
    if (comparableTokens < minTokenThreshold) return 0; // 太短跳過

    final recentMsgs = selectWholeBubbleBatch(messages, triggerTokenLimit);

    return compress(
      messages: recentMsgs,
      characterId: characterId,
      conversationId: conversationId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
  }

  /// Remaining text after the last successfully persisted summary cursor.
  static Future<int> pendingTokenCount(String conversationId) async {
    final cursor = await DatabaseHelper.getConversationSummaryCursor(
      conversationId,
    );
    final messages = summaryEligibleMessages(
      await DatabaseHelper.getMessagesAfterId(conversationId, cursor),
    );
    return _estimateMessageTokens(messages);
  }

  /// Number of complete message bubbles not yet covered by the persisted
  /// summary cursor. This is the source of truth for message-count based
  /// summary thresholds.
  static Future<int> pendingMessageCount(String conversationId) async {
    final cursor = await DatabaseHelper.getConversationSummaryCursor(
      conversationId,
    );
    final messages = summaryEligibleMessages(
      await DatabaseHelper.getMessagesAfterId(conversationId, cursor),
    );
    return messages.length;
  }

  /// Only completed, user-visible bubbles participate in cadence and source
  /// selection. Internal RP continuation markers and half-written streaming
  /// rows previously made an 18-message trigger fire several turns early.
  @visibleForTesting
  static List<Message> summaryEligibleMessages(List<Message> messages) =>
      messages
          .where(
            (message) =>
                !message.isIncomplete &&
                !message.isRpChapterContinuation &&
                (message.promptVisibleText.trim().isNotEmpty ||
                    message.imagePaths.isNotEmpty),
          )
          .toList(growable: false);

  static int _estimateMessageTokens(List<Message> messages) =>
      messages.fold<int>(
        0,
        (total, message) =>
            total + TokenEstimator.estimate(message.promptVisibleText),
      );

  /// Select oldest pending messages until the token target is crossed. The
  /// crossing bubble is included in full, so a 5,800t prefix followed by a
  /// 700t bubble becomes a 6,500t batch rather than silently losing 700t.
  static List<Message> selectWholeBubbleBatch(
    List<Message> messages,
    int tokenLimit,
  ) {
    final eligible = summaryEligibleMessages(messages);
    if (eligible.isEmpty) return const [];
    final selected = <Message>[];
    int total = 0;
    for (final message in eligible) {
      selected.add(message);
      total += TokenEstimator.estimate(message.promptVisibleText);
      if (total >= tokenLimit) break;
    }
    return selected;
  }

  static List<Message> selectWholeMessageBatch(
    List<Message> messages,
    int messageLimit,
  ) {
    if (messages.isEmpty || messageLimit <= 0) return const [];
    return summaryEligibleMessages(
      messages,
    ).take(messageLimit).toList(growable: false);
  }

  /// 載入摘要包。
  /// latest summaries 取最近幾塊；keyword recall 只回傳命中的單段。
  static Future<Map<String, String>> loadSummaryPack(
    String characterId, {
    String currentMessage = '',
    String? excludeWindowId,
    bool includeLatestSummaries = true,
    bool includeKeywordRecall = true,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    int latestLimit = latestSummaryBlocksForPrompt,
    int? rpKeywordMaxChars,
    String alreadyInjected = '',
  }) async {
    final summaryParts = <String>[];
    if (includeLatestSummaries) {
      final summaries = await DatabaseHelper.getLatestContextSummaries(
        characterId,
        excludeWindowId: excludeWindowId,
        limit: latestLimit,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      summaryParts.addAll(
        summaries.reversed.map(
          (row) => _formatSummaryBlock(row, contextMode: contextMode),
        ),
      );
    }

    String keywordSummary = '';
    if (includeKeywordRecall) {
      final maxRpSegments = contextMode == ContextMode.rp
          ? await MemorySettings.getRpDynamicSummarySegments()
          : 1;
      final maxRpCharacters = contextMode == ContextMode.rp
          ? rpKeywordMaxChars ??
                await MemorySettings.getRpDynamicSummaryMaxChars()
          : null;
      final maxRecalled = contextMode == ContextMode.rp ? maxRpSegments : 1;
      // 兩段式：先只用關鍵詞欄位挑候選，再只撈候選的全文。
      // 以前每輪把整條故事線的摘要全文載入記憶體，標籤上千時會吃掉大量記憶體。
      final index = currentMessage.trim().isEmpty
          ? const <Map<String, dynamic>>[]
          : await DatabaseHelper.getRecallIndexRows(
              characterId,
              contextMode: contextMode,
              continuityId: continuityId,
            );
      final candidates = _preselectRecallCandidates(
        index,
        currentMessage: currentMessage,
        excludeWindowId: excludeWindowId,
        // 多留幾個，給後面的指紋去重、字數預算跳過使用。
        limit: maxRecalled * 4 < 8 ? 8 : maxRecalled * 4,
      );
      final keywords = await DatabaseHelper.fillRecallContents(candidates);
      keywordSummary =
          _recallKeywordSummarySegment(
            keywords,
            currentMessage: currentMessage,
            excludeWindowId: excludeWindowId,
            maxRecalledSummaries: maxRecalled,
            maxCharacters: maxRpCharacters,
            alreadyInjected: alreadyInjected,
          ) ??
          '';
    }

    return {
      'summary': summaryParts.join('\n\n'),
      'keywordSummaries': keywordSummary,
    };
  }

  /// 召回第一段：只看關鍵詞欄位挑出候選。排序規則與
  /// [_recallKeywordSummarySegment] 相同（分數高者先、同分較新者先）。
  static List<Map<String, dynamic>> _preselectRecallCandidates(
    List<Map<String, dynamic>> rows, {
    required String currentMessage,
    String? excludeWindowId,
    required int limit,
  }) {
    if (currentMessage.trim().isEmpty) return const <Map<String, dynamic>>[];
    final excluded = (excludeWindowId ?? '').trim();
    final eligibleRows = <Map<String, dynamic>>[];
    for (final row in rows) {
      final sourceWindowId = (row['source_window_id'] as String? ?? '').trim();
      if (excluded.isNotEmpty && sourceWindowId == excluded) continue;
      eligibleRows.add(row);
    }
    final rowMatches = RecallTextMatcher.bestKeywordMatches(
      currentMessage,
      eligibleRows.map((row) => row['keywords'] as String? ?? ''),
    );
    final matches = <({Map<String, dynamic> row, RecallKeywordMatch match})>[];
    for (var index = 0; index < eligibleRows.length; index++) {
      final match = rowMatches[index];
      if (match != null) {
        matches.add((row: eligibleRows[index], match: match));
      }
    }
    matches.sort((left, right) {
      final score = right.match.score.compareTo(left.match.score);
      if (score != 0) return score;
      return (right.row['created_at']?.toString() ?? '').compareTo(
        left.row['created_at']?.toString() ?? '',
      );
    });
    return <Map<String, dynamic>>[
      for (final entry in matches.take(limit)) entry.row,
    ];
  }

  /// Keep recent summary blocks active until their lane reaches its retention
  /// limit. Only then recycle the oldest unlocked blocks into labels. The
  /// archived original stays available to its chat history shortcut.
  static Future<void> recycleSupersededSummaries(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    @visibleForTesting Future<String> Function(String)? extractKeywords,
  }) async {
    var rows = await DatabaseHelper.getContextSummaries(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    bool overLimit() {
      if (rows.length < 2) return false;
      if (contextMode == ContextMode.rp) {
        // RP keeps exactly the newest four complete dossiers visible. Their
        // length must not make an earlier block disappear before a fifth one
        // exists; older blocks become durable event labels one by one.
        return rows.length > latestSummaryBlocksForPrompt;
      }
      final total = rows.fold<int>(
        0,
        (sum, row) => sum + (row['token_count'] as int? ?? 0),
      );
      return total > summaryCapTokens;
    }

    final failedIds = <int>{};
    while (overLimit()) {
      Map<String, dynamic>? oldest;
      for (final row in rows.take(rows.length - 1)) {
        final id = row['id'] as int;
        if ((row['locked'] as int? ?? 0) == 0 && !failedIds.contains(id)) {
          oldest = row;
          break;
        }
      }
      if (oldest == null) break;
      final id = oldest['id'] as int;
      final source = (oldest['content'] as String? ?? '').trim();
      if (source.isEmpty) {
        failedIds.add(id);
        continue;
      }
      try {
        final bool archived;
        if (contextMode == ContextMode.rp && extractKeywords == null) {
          archived =
              await DatabaseHelper.archiveContextSummaryWithStoredSegments(
                summaryId: id,
                characterId: characterId,
                contextMode: contextMode,
                continuityId: continuityId,
              );
        } else {
          final keywords = extractKeywords == null
              ? await _extractKeywordText(
                  characterId: characterId,
                  summaryContent: source,
                  contextMode: contextMode,
                )
              : await extractKeywords(source);
          if (keywords.trim().isEmpty) {
            failedIds.add(id);
            continue;
          }
          archived = await DatabaseHelper.archiveContextSummaryWithKeywords(
            summaryId: id,
            characterId: characterId,
            contextMode: contextMode,
            continuityId: continuityId,
            keywords: keywords.trim(),
            keywordTokenCount: TokenEstimator.estimate(keywords),
          );
        }
        if (!archived) failedIds.add(id);
      } catch (error) {
        developer.log(
          'Summary $id label extraction failed; keeping it active',
          name: 'ContextCompressor',
          error: error,
        );
        failedIds.add(id);
      }
      rows = await DatabaseHelper.getContextSummaries(
        characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
    }
    // Labels are the durable lookup index for every archived summary. Keep all
    // of them locally; prompt injection still selects only matched segments.
    await DatabaseHelper.restoreArchivedSummaryKeywords(
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
  }

  /// 獲取調試信息（測試入口用）
  static Future<Map<String, dynamic>> getDebugInfo(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final summaries = await DatabaseHelper.getContextSummaries(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final keywords = await DatabaseHelper.getContextKeywords(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final summaryTotal = await DatabaseHelper.getContextSummaryTokenTotal(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final keywordTotal = await DatabaseHelper.getContextKeywordTokenTotal(
      characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final rpStoryCharacterCount = contextMode == ContextMode.rp
        ? (await RpStoryService.listCharacters(
            characterId,
            continuityId: continuityId,
          )).length
        : 0;
    final rpStoryRelationshipCount = contextMode == ContextMode.rp
        ? (await RpStoryService.listRelationships(
            characterId,
            continuityId: continuityId,
          )).length
        : 0;
    final rpStoryStateCount = contextMode == ContextMode.rp
        ? (await RpStoryStateService.listStates(
            characterId,
            continuityId: continuityId,
            includeNonMain: true,
          )).length
        : 0;
    final rpRelationshipExtraction = contextMode == ContextMode.rp
        ? RpStoryService.latestExtractionReport(
            characterId,
            continuityId: continuityId,
          )?.toJson()
        : null;

    return {
      'summaryBlocks': summaries,
      'keywordBlocks': keywords,
      'summaryTokenTotal': summaryTotal,
      'keywordTokenTotal': keywordTotal,
      'summaryCap': summaryCapTokens,
      'keywordCap': null,
      'contextMode': contextMode.storageValue,
      'continuityId': continuityId,
      'rpStoryCharacterCount': rpStoryCharacterCount,
      'rpStoryRelationshipCount': rpStoryRelationshipCount,
      'rpStoryStateCount': rpStoryStateCount,
      'rpStoryExtraction': rpRelationshipExtraction,
      'rpRelationshipExtraction': rpRelationshipExtraction,
    };
  }

  /// Debug 修正：把「問題描述 + 原摘要」交給摘要模型，返回修正版並覆蓋摘要塊。
  static Future<String> reviseSummaryBlock({
    required int id,
    required String characterId,
    required String originalSummary,
    required String issue,
    ContextMode contextMode = ContextMode.daily,
  }) async {
    final revised = await _reviseSummaryText(
      characterId: characterId,
      originalSummary: originalSummary,
      issue: issue,
      requireFullFormat: true,
      contextMode: contextMode,
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
      requireFullFormat: false,
    );
    if (revisedSegment.isEmpty) return '';

    final revisedFull = normalizeSummaryFormat(
      _replaceRange(fullSummary, segmentStart, segmentEnd, revisedSegment),
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
      requireFullFormat: true,
    );
    if (revised.isEmpty) return '';

    final isEn = L.locale == 'en';
    final keywords = await _callModel(
      characterId: characterId,
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
      requireFullFormat: false,
    );
    if (revisedSegment.isEmpty) return '';

    final revisedFull = normalizeSummaryFormat(
      _replaceRange(fullSummary, segmentStart, segmentEnd, revisedSegment),
    );
    final isEn = L.locale == 'en';
    final keywords = await _callModel(
      characterId: characterId,
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

  /// 從摘要塊提取關鍵詞。呼叫端只有在成功取得非空結果後，才會於同一
  /// 筆 transaction 將摘要搬到關鍵詞層，避免模型失敗時先刪掉原資料。
  static Future<String> _extractKeywordText({
    required String characterId,
    required String summaryContent,
    ContextMode contextMode = ContextMode.daily,
  }) async {
    final isEn = L.locale == 'en';
    final prompt = contextMode == ContextMode.rp
        ? (isEn ? _rpKeywordPromptEn : _zhPrompt(_rpKeywordPromptZh))
        : (isEn ? _keywordPromptEn : _zhPrompt(_keywordPromptZh));

    final keywordText = await _callModel(
      characterId: characterId,
      systemPrompt: prompt,
      userMessage: summaryContent,
    );
    final filteredKeywordText = await _filterKeywordText(
      keywordText,
      characterId,
      maxItems: contextMode == ContextMode.rp ? 5 : null,
    );
    return filteredKeywordText;
  }

  static String? _recallKeywordSummarySegment(
    List<Map<String, dynamic>> keywordBlocks, {
    required String currentMessage,
    String? excludeWindowId,
    int maxRecalledSummaries = 1,
    int? maxCharacters,
    String alreadyInjected = '',
  }) {
    if (currentMessage.trim().isEmpty) return null;
    final excluded = (excludeWindowId ?? '').trim();
    final injectedFingerprint = alreadyInjected.toLowerCase().replaceAll(
      RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
      '',
    );

    final matches =
        <({Map<String, dynamic> block, RecallKeywordMatch match})>[];
    for (final block in keywordBlocks) {
      final sourceWindowId = (block['source_window_id'] as String? ?? '')
          .trim();
      if (excluded.isNotEmpty && sourceWindowId == excluded) continue;
      final source = (block['source_summary_content'] as String? ?? '').trim();
      if (source.isEmpty) continue;
      final match = RecallTextMatcher.bestKeywordMatch(
        currentMessage,
        block['keywords'] as String? ?? '',
      );
      if (match != null) matches.add((block: block, match: match));
    }
    matches.sort((left, right) {
      final score = right.match.score.compareTo(left.match.score);
      if (score != 0) return score;
      return (right.block['created_at']?.toString() ?? '').compareTo(
        left.block['created_at']?.toString() ?? '',
      );
    });
    final recalled = <String>[];
    final recalledSegmentIds = <String>{};
    final recalledFingerprints = <String>{};
    for (final candidate in matches) {
      final block = candidate.block;
      // Keywords are lookup aliases, not separate recall payloads. Multiple
      // different keywords may point at the same stored event segment; inject
      // that segment only once even when every alias is present in the turn.
      final segmentIdentity =
          '${block['source_summary_id'] ?? ''}:'
          '${block['segment_order'] ?? block['id'] ?? ''}';
      if (!recalledSegmentIds.add(segmentIdentity)) continue;
      final source = (block['source_summary_content'] as String? ?? '').trim();
      // New RP rows are already the exact one/two-paragraph segment emitted
      // by the summary model. Do not split or re-select them locally: a valid
      // retrieval keyword need not appear verbatim inside the copied prose.
      final segment = block['segment_order'] != null
          ? _SummarySegment(block['title']?.toString().trim() ?? '', source)
          : _pickMatchedSummarySegment(source, <String>[
              candidate.match.keyword,
            ]);
      if (segment == null) continue;
      final fingerprint = segment.content.toLowerCase().replaceAll(
        RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
        '',
      );
      if (injectedFingerprint.contains(fingerprint)) continue;
      if (fingerprint.isEmpty || !recalledFingerprints.add(fingerprint)) {
        continue;
      }
      final sourceWindowId = (block['source_window_id'] as String? ?? '')
          .trim();
      final createdAt = block['created_at'] as String? ?? '';
      final fittedSegment = maxCharacters == null
          ? segment
          : _fitSegmentToCharacterBudget(segment, maxCharacters);
      if (fittedSegment == null) continue;
      final formatted = _formatKeywordRecallBlock(
        fittedSegment,
        sourceWindowId: sourceWindowId,
        createdAt: createdAt,
      );
      final nextLength =
          recalled.fold<int>(0, (total, item) => total + item.length) +
          (recalled.isEmpty ? 0 : 2) +
          formatted.length;
      if (maxCharacters != null &&
          recalled.isNotEmpty &&
          nextLength > maxCharacters) {
        continue;
      }
      recalled.add(formatted);
      if (recalled.length >= maxRecalledSummaries) break;
    }
    return recalled.isEmpty ? null : recalled.join('\n\n');
  }

  static String _formatSummaryBlock(
    Map<String, dynamic> block, {
    ContextMode contextMode = ContextMode.daily,
  }) {
    final raw = block['content'] as String? ?? '';
    final content = contextMode == ContextMode.rp
        ? normalizeRpSummaryFormat(raw)
        : normalizeSummaryFormat(raw);
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

  static String _formatRollingSummaryAnchors(
    List<Map<String, dynamic>> anchors, {
    required ContextMode contextMode,
  }) {
    if (anchors.isEmpty) return '';
    return anchors.indexed
        .map((entry) {
          final ordinal = entry.$1 + 1;
          final label = L.pick(
            en: '【Summary anchor $ordinal · ${ordinal == anchors.length ? 'newest' : 'older'}】',
            zhTW:
                '【摘要基底 $ordinal · ${ordinal == anchors.length ? '最新' : '較早'}】',
            zhCN:
                '【摘要基底 $ordinal · ${ordinal == anchors.length ? '最新' : '较早'}】',
          );
          final raw = entry.$2['content']?.toString() ?? '';
          final content = contextMode == ContextMode.rp
              ? normalizeRpSummaryFormat(raw)
              : normalizeSummaryFormat(raw);
          return '$label\n$content';
        })
        .join('\n\n');
  }

  @visibleForTesting
  static String formatRollingSummaryAnchorsForTesting(
    List<String> anchors, {
    ContextMode contextMode = ContextMode.rp,
  }) => _formatRollingSummaryAnchors(
    anchors
        .map<Map<String, dynamic>>(
          (content) => <String, dynamic>{'content': content},
        )
        .toList(growable: false),
    contextMode: contextMode,
  );

  static List<String> _rpEventTitles(String summary) {
    final titles = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'^\s*\*\*\[[^\]]+\]\s*([^*\n]+?)\s*\*\*\s*$',
      multiLine: true,
    );
    for (final match in pattern.allMatches(summary)) {
      final title = match.group(1)?.trim() ?? '';
      final normalized = _normalizeCarryoverTitle(title);
      if (normalized.isNotEmpty && seen.add(normalized)) titles.add(title);
    }
    return titles;
  }

  static String _normalizeCarryoverTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

  static List<String> _missingRpCarryoverTitles(
    List<Map<String, dynamic>> anchors,
    String nextSummary,
  ) {
    if (anchors.isEmpty) return const <String>[];
    final next = _normalizeCarryoverTitle(nextSummary);
    final missing = <String>[];
    final seen = <String>{};
    for (final anchor in anchors) {
      for (final title in _rpEventTitles(anchor['content']?.toString() ?? '')) {
        final normalized = _normalizeCarryoverTitle(title);
        if (normalized.isEmpty || !seen.add(normalized)) continue;
        if (!next.contains(normalized)) missing.add(title);
      }
    }
    return missing;
  }

  static Map<String, String> _rpCarryoverBlocks(
    List<Map<String, dynamic>> anchors,
  ) {
    final blocks = <String, String>{};
    final headerPattern = RegExp(r'^\s*\*\*\[[^\]]+\]\s*([^*\n]+?)\s*\*\*\s*$');
    // Older-to-newer input means a later dossier can replace the compact
    // wording of the same stable event title without changing its identity.
    for (final anchor in anchors) {
      final lines = (anchor['content']?.toString() ?? '').split('\n');
      for (var i = 0; i < lines.length; i++) {
        final match = headerPattern.firstMatch(lines[i]);
        if (match == null) continue;
        final normalized = _normalizeCarryoverTitle(match.group(1) ?? '');
        if (normalized.isEmpty) continue;
        final body = <String>[];
        for (var j = i + 1; j < lines.length; j++) {
          final line = lines[j].trim();
          if (headerPattern.hasMatch(lines[j]) || line.startsWith('### ')) {
            break;
          }
          if (line.isNotEmpty && !line.startsWith('[劇情位置]')) body.add(line);
        }
        final compactBody = _compactRpCarryoverBody(body.join(' '));
        blocks[normalized] = compactBody.isEmpty
            ? lines[i].trim()
            : '${lines[i].trim()}\n$compactBody';
      }
    }
    return blocks;
  }

  static String _compactRpCarryoverBody(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 320) return text;
    final prefix = text.substring(0, 320);
    final lastBoundary = prefix.lastIndexOf(RegExp(r'[。！？.!?；;]'));
    if (lastBoundary >= 120) {
      return prefix.substring(0, lastBoundary + 1).trim();
    }
    return '${prefix.trimRight()}…';
  }

  static String _restoreMissingRpCarryoverEvents(
    List<Map<String, dynamic>> anchors,
    String nextSummary,
  ) {
    final missing = _missingRpCarryoverTitles(anchors, nextSummary);
    if (missing.isEmpty) return nextSummary.trim();
    final blocks = _rpCarryoverBlocks(anchors);
    final restored = <String>[];
    for (final title in missing) {
      final block = blocks[_normalizeCarryoverTitle(title)];
      if (block != null) restored.add(block);
    }
    if (restored.isEmpty) return nextSummary.trim();

    final insertion = restored.join('\n\n');
    final firstSection = RegExp(
      r'^###\s+',
      multiLine: true,
    ).firstMatch(nextSummary);
    if (firstSection == null) {
      return '### ——主線——\n$insertion\n\n${nextSummary.trim()}';
    }
    final remaining = nextSummary.substring(firstSection.end);
    final nextSection = RegExp(
      r'^###\s+',
      multiLine: true,
    ).firstMatch(remaining);
    final index = nextSection == null
        ? nextSummary.length
        : firstSection.end + nextSection.start;
    return '${nextSummary.substring(0, index).trimRight()}\n\n$insertion\n\n'
            '${nextSummary.substring(index).trimLeft()}'
        .trim();
  }

  @visibleForTesting
  static List<String> missingRpCarryoverTitlesForTesting({
    required List<String> anchors,
    required String nextSummary,
  }) => _missingRpCarryoverTitles(
    anchors
        .map<Map<String, dynamic>>(
          (content) => <String, dynamic>{'content': content},
        )
        .toList(growable: false),
    nextSummary,
  );

  @visibleForTesting
  static String restoreMissingRpCarryoverEventsForTesting({
    required List<String> anchors,
    required String nextSummary,
  }) => _restoreMissingRpCarryoverEvents(
    anchors
        .map<Map<String, dynamic>>(
          (content) => <String, dynamic>{'content': content},
        )
        .toList(growable: false),
    nextSummary,
  );

  /// Enforces the stored RP dossier ceiling after the provider response.
  /// A retained event always keeps prose: when the dossier is too dense, low
  /// priority closed blocks leave the current rolling map instead of surviving
  /// as title-only shells. Their older stored summaries/recall segments remain
  /// available for explicit retrieval.
  @visibleForTesting
  static String compactRpSummaryToHardLimit(String source, int maxCharacters) {
    final normalized = normalizeRpSummaryFormat(source).trim();
    if (normalized.isEmpty || normalized.length <= maxCharacters) {
      return normalized;
    }

    final entryPattern = RegExp(r'^\s*\*\*\[[^\]]+\]\s*([^*\n]+?)\s*\*\*\s*$');
    final blocks = <({String section, String header, String body})>[];
    var section = '### ——主線——';
    String? header;
    final body = <String>[];

    void flush() {
      final value = header;
      if (value == null) return;
      blocks.add((
        section: section,
        header: value,
        body: body.join(' ').trim(),
      ));
      body.clear();
    }

    for (final rawLine in normalized.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('### ')) {
        flush();
        header = null;
        section = line;
      } else if (entryPattern.hasMatch(line)) {
        flush();
        header = line;
      } else if (header != null &&
          line.isNotEmpty &&
          !line.startsWith('### ')) {
        body.add(line);
      }
    }
    flush();

    if (blocks.isEmpty) {
      return fitRpSummaryToCharacterBudget(normalized, maxCharacters);
    }

    int priority(int index) {
      final block = blocks[index];
      final haystack = '${block.header}\n${block.body}'.toLowerCase();
      var score = index; // 同等重要時優先近期進展。
      if (block.section.contains('主線') ||
          block.section.toLowerCase().contains('main')) {
        score += 80;
      } else if (block.section.contains('觀察') ||
          block.section.toLowerCase().contains('observation')) {
        score += 55;
      } else if (block.section.contains('支線') ||
          block.section.toLowerCase().contains('side')) {
        score += 35;
      }
      if (RegExp(
        r'\[(?:懸念|伏筆|衝突|關係|身份|不可逆|死亡／損失|unresolved|clue|conflict|relationship|identity|irreversible)',
        caseSensitive: false,
      ).hasMatch(block.header)) {
        score += 55;
      }
      if (RegExp(
        r'(未解|未完|待兌現|尚未|仍在|持續|當前|pending|unresolved|ongoing|still active)',
        caseSensitive: false,
      ).hasMatch(haystack)) {
        score += 45;
      }
      if (RegExp(
        r'(已結束|已收束|已兌現|已痊癒|不再影響|resolved|fulfilled|closed)',
        caseSensitive: false,
      ).hasMatch(haystack)) {
        score -= 35;
      }
      if (block.section.contains('氛圍') ||
          block.section.toLowerCase().contains('atmosphere')) {
        score -= 45;
      }
      return score;
    }

    String render(Set<int> selected) {
      final output = <String>[];
      String? renderedSection;
      for (var index = 0; index < blocks.length; index++) {
        if (!selected.contains(index)) continue;
        final block = blocks[index];
        final compactBody = _compactRpBodyToBudget(block.body, 180);
        if (compactBody.isEmpty) continue;
        if (renderedSection != block.section) {
          output.add(block.section);
          renderedSection = block.section;
        }
        output.add('${block.header}\n$compactBody');
      }
      return output.join('\n\n').trim();
    }

    final ranked = List<int>.generate(blocks.length, (index) => index)
      ..sort((left, right) {
        final byPriority = priority(right).compareTo(priority(left));
        return byPriority != 0 ? byPriority : right.compareTo(left);
      });
    final selected = <int>{};
    for (final index in ranked) {
      if (blocks[index].body.trim().isEmpty) continue;
      final candidate = <int>{...selected, index};
      if (render(candidate).length <= maxCharacters) selected.add(index);
    }
    final result = render(selected);
    if (result.isNotEmpty) return result;
    return fitRpSummaryToCharacterBudget(normalized, maxCharacters);
  }

  static String _compactRpBodyToBudget(String raw, int budget) {
    if (budget < 8 || raw.isEmpty) return '';
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= budget) return text;
    final window = text.substring(0, budget - 1);
    final boundary = window.lastIndexOf(RegExp(r'[。！？.!?；;]'));
    if (boundary >= (budget * 0.45).floor()) {
      return window.substring(0, boundary + 1).trim();
    }
    return '${window.trimRight()}…';
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
      if (matchedKeywords.any(
        (keyword) => RecallTextMatcher.containsPhrase(segment.content, keyword),
      )) {
        return segment;
      }
    }
    if (segments.length == 1) return segments.first;
    return null;
  }

  static List<_SummarySegment> _splitSummarySegments(String source) {
    final lines = source.split('\n');
    final segments = <_SummarySegment>[];
    final headingRe = RegExp(
      r'^\s*(?:[#>*\-]+\s*)?(前情提要|本次摘要|前情摘要|最新摘要|Prior Context|This Update|Previous Summary|Latest Summary|Prior Summary|Recent Summary|——主線——|——支線——|——氛圍——|——觀察區——|——Main——|——Side Threads——|——Atmosphere——|——Observation——)\s*[:：]?\s*$',
      caseSensitive: false,
    );
    final rpEntryRe = RegExp(r'^\s*\*\*\[([^\]]+)\]\s*([^*]+)\*\*\s*$');

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
        continue;
      }
      final entry = rpEntryRe.firstMatch(line);
      if (entry != null) {
        flush();
        currentTitle =
            '${entry.group(1)?.trim() ?? ''} · '
            '${entry.group(2)?.trim() ?? ''}';
        buffer.add(line);
      } else {
        buffer.add(line);
      }
    }
    flush();

    if (segments.isEmpty) {
      final trimmed = source.trim();
      return trimmed.isEmpty ? const [] : [_SummarySegment('', trimmed)];
    }
    if (segments.length == 1 && segments.first.content.length > 1200) {
      final paragraphs = segments.first.content
          .split(RegExp(r'\n\s*\n'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (paragraphs.length > 1) {
        return <_SummarySegment>[
          for (var index = 0; index < paragraphs.length; index += 2)
            _SummarySegment(
              segments.first.title,
              paragraphs.skip(index).take(2).join('\n\n'),
            ),
        ];
      }
    }
    return segments;
  }

  /// Fits an RP dossier to a character budget using complete event segments.
  /// It never cuts through a sentence or paragraph. This is intentionally a
  /// transport budget, not another summarisation layer.
  static String fitRpSummaryToCharacterBudget(
    String source,
    int maxCharacters, {
    bool preferLatest = false,
  }) {
    final normalized = normalizeRpSummaryFormat(source).trim();
    if (normalized.isEmpty || normalized.length <= maxCharacters) {
      return normalized;
    }
    final segments = _splitSummarySegments(normalized);
    if (segments.isEmpty) return '';
    final ordered = preferLatest ? segments.reversed : segments;
    final selected = <_SummarySegment>[];
    var used = 0;
    for (final segment in ordered) {
      final fitted = _fitSegmentToCharacterBudget(segment, maxCharacters);
      if (fitted == null) continue;
      final addition = fitted.content.length + (selected.isEmpty ? 0 : 2);
      if (selected.isNotEmpty && used + addition > maxCharacters) continue;
      selected.add(fitted);
      used += addition;
      if (used >= maxCharacters) break;
    }
    final output = preferLatest ? selected.reversed : selected;
    return output.map((item) => item.content).join('\n\n').trim();
  }

  static String fitRpSummariesToCharacterBudget(
    Iterable<String> summaries,
    int maxCharacters,
  ) {
    final source = summaries
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (source.isEmpty) return '';
    final selected = <String>[];
    var used = 0;
    for (final summary in source.reversed) {
      final remaining = maxCharacters - used - (selected.isEmpty ? 0 : 7);
      if (remaining < 200) break;
      final fitted = fitRpSummaryToCharacterBudget(
        summary,
        remaining,
        preferLatest: true,
      );
      if (fitted.isEmpty) continue;
      selected.add(fitted);
      used += fitted.length + (selected.length == 1 ? 0 : 7);
    }
    return selected.reversed.join('\n\n---\n\n');
  }

  /// Fits independently generated RP character/state/worldbook references
  /// into one request budget. Each non-empty source keeps its heading and as
  /// many complete lines as fit, preventing one subsystem from consuming the
  /// entire live-continuity allowance.
  static String fitRpReferencePartsToCharacterBudget(
    Iterable<String> parts,
    int maxCharacters,
  ) {
    final pending = parts
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (pending.isEmpty || maxCharacters <= 0) return '';
    if (pending.join('\n\n').length <= maxCharacters) {
      return pending.join('\n\n');
    }

    final selected = <String>[];
    var remaining = maxCharacters;
    for (var index = 0; index < pending.length; index++) {
      final remainingParts = pending.length - index;
      final separator = selected.isEmpty ? 0 : 2;
      final share = ((remaining - separator) / remainingParts).floor();
      if (share <= 0) break;
      final fitted = _fitCompleteLines(pending[index], share);
      if (fitted.isEmpty) continue;
      selected.add(fitted);
      remaining -= fitted.length + separator;
    }
    return selected.join('\n\n').trim();
  }

  /// Fits the five RP reference sources with explicit continuity priority.
  /// The first pass reserves weighted room for every non-empty subsystem; any
  /// unused room then flows from the highest-priority source downward.
  static String fitPrioritizedRpReferencePartsToCharacterBudget({
    required String storyState,
    required String story,
    required String worldbook,
    required String memory,
    required String timeline,
    required int maxCharacters,
  }) {
    final sources = <({String text, int weight})>[
      (text: storyState.trim(), weight: 5),
      (text: story.trim(), weight: 4),
      (text: worldbook.trim(), weight: 3),
      (text: memory.trim(), weight: 2),
      (text: timeline.trim(), weight: 1),
    ].where((source) => source.text.isNotEmpty).toList(growable: false);
    if (sources.isEmpty || maxCharacters <= 0) return '';
    final complete = sources.map((source) => source.text).join('\n\n');
    if (complete.length <= maxCharacters) return complete;

    final separatorBudget = (sources.length - 1) * 2;
    final contentBudget = maxCharacters > separatorBudget
        ? maxCharacters - separatorBudget
        : 0;
    final totalWeight = sources.fold<int>(
      0,
      (sum, source) => sum + source.weight,
    );
    final selected = List<String>.filled(sources.length, '');
    for (var index = 0; index < sources.length; index++) {
      final share = (contentBudget * sources[index].weight / totalWeight)
          .floor();
      selected[index] = _fitCompleteLines(sources[index].text, share);
    }

    int joinedLength() =>
        selected.where((part) => part.isNotEmpty).join('\n\n').length;

    // Reflow unused weighted room in priority order. A short state block gives
    // its spare budget to character/relationship context before old memories.
    for (var index = 0; index < sources.length; index++) {
      final remaining = maxCharacters - joinedLength();
      if (remaining <= 0) break;
      final addingNewPart =
          selected[index].isEmpty && selected.any((part) => part.isNotEmpty);
      final separatorCost = addingNewPart ? 2 : 0;
      final available = remaining - separatorCost;
      if (available <= 0) continue;
      final candidate = _fitCompleteLines(
        sources[index].text,
        selected[index].length + available,
      );
      if (candidate.length > selected[index].length) {
        selected[index] = candidate;
      }
    }
    return selected.where((part) => part.isNotEmpty).join('\n\n').trim();
  }

  static String _fitCompleteLines(String source, int maxCharacters) {
    final lines = source
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty || maxCharacters <= 0) return '';
    final kept = <String>[];
    var used = 0;
    for (final line in lines) {
      final addition = line.length + (kept.isEmpty ? 0 : 1);
      if (used + addition > maxCharacters) break;
      kept.add(line);
      used += addition;
    }
    // Keep a useful sentence even when a generated subsystem emits one very
    // long content line after its heading. Dropping the whole subsystem here
    // makes continuity disappear exactly when the reference is most dense.
    if (kept.length == 1 && lines.length > 1) {
      final remaining = maxCharacters - kept.first.length - 1;
      if (remaining <= 0) return '';
      final firstContent = _truncateAtSentenceBoundary(lines[1], remaining);
      if (firstContent.isEmpty) return '';
      kept.add(firstContent);
    }
    return kept.join('\n').trim();
  }

  static String _truncateAtSentenceBoundary(String source, int maxCharacters) {
    final text = source.trim();
    if (text.isEmpty || maxCharacters <= 0) return '';
    if (text.length <= maxCharacters) return text;
    final prefix = text.substring(0, maxCharacters);
    final matches = RegExp(r'[。！？.!?；;]').allMatches(prefix);
    if (matches.isNotEmpty) {
      final end = matches.last.end;
      final usefulBoundary = maxCharacters ~/ 2 < 24 ? maxCharacters ~/ 2 : 24;
      if (end >= usefulBoundary) {
        return prefix.substring(0, end).trim();
      }
    }
    if (maxCharacters <= 1) return '';
    return '${prefix.substring(0, maxCharacters - 1).trimRight()}…';
  }

  static _SummarySegment? _fitSegmentToCharacterBudget(
    _SummarySegment segment,
    int maxCharacters,
  ) {
    if (maxCharacters <= 0) return null;
    if (segment.content.length <= maxCharacters) return segment;
    var paragraphs = segment.content
        .split(RegExp(r'\n\s*\n'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.length == 1 && paragraphs.first.length > maxCharacters) {
      paragraphs = paragraphs.first
          .split(RegExp(r'(?<=[。！？.!?])\s*'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    final kept = <String>[];
    var used = 0;
    for (final paragraph in paragraphs) {
      final addition = paragraph.length + (kept.isEmpty ? 0 : 2);
      if (used + addition > maxCharacters) break;
      kept.add(paragraph);
      used += addition;
    }
    if (kept.isEmpty) return null;
    return _SummarySegment(segment.title, kept.join('\n\n'));
  }

  static String _dateLabel(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '';
    return '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }

  static Future<String> _filterKeywordText(
    String keywordText,
    String characterId, {
    int? maxItems,
  }) async {
    final forbidden = await _forbiddenKeywordTerms(characterId);
    final keywords = keywordText
        .split(RegExp(r'[,，、\n]'))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .where((k) {
          final normalized = k.toLowerCase();
          return !forbidden.contains(normalized);
        })
        .toList();

    final seen = <String>{};
    final deduped = <String>[];
    for (final keyword in keywords) {
      final key = keyword.toLowerCase().replaceAll(
        RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
        '',
      );
      if (key.isEmpty) continue;
      final overlaps = seen.any(
        (existing) =>
            existing == key ||
            (existing.length >= 4 && key.contains(existing)) ||
            (key.length >= 4 && existing.contains(key)),
      );
      if (overlaps) continue;
      seen.add(key);
      deduped.add(keyword);
      if (maxItems != null && deduped.length >= maxItems) break;
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
    try {
      terms.addAll(
        (await UserPersonaService.listPersonas()).map(
          (persona) => persona.displayName,
        ),
      );
    } catch (_) {
      // Summary keyword filtering remains usable during early schema repair.
    }

    return terms
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.length >= 2)
        .toSet();
  }

  static Future<String> _reviseSummaryText({
    required String characterId,
    required String originalSummary,
    required String issue,
    required bool requireFullFormat,
    ContextMode contextMode = ContextMode.daily,
  }) async {
    final isEn = L.locale == 'en';
    final identity = await _buildIdentityContext(characterId);
    final promptParts = <String>[
      contextMode == ContextMode.rp
          ? L.pick(
              en: 'Revise only the supplied RP story dossier according to the issue. Preserve its Core, Side Story, Atmosphere, Observation, character-file, category, and story-time structure. Keep established facts unless the issue corrects them. Output only the revised dossier, with no preamble or code fence.',
              zhTW:
                  '只依問題修正提供的 RP 劇情卷宗。保留核心、支線、氛圍、觀察區、新角色檔案、類別與時間線位置結構；除非問題明確修正，不得刪改既有事實。只輸出修正後卷宗，不要前言或 code fence。',
              zhCN:
                  '只依问题修正提供的 RP 剧情卷宗。保留核心、支线、氛围、观察区、新角色档案、类别与时间线位置结构；除非问题明确修正，不得删改既有事实。只输出修正后卷宗，不要前言或 code fence。',
            )
          : isEn
          ? _revisePromptEn
          : _zhPrompt(_revisePromptZh),
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
      characterId: characterId,
      systemPrompt: promptParts.join('\n\n'),
      userMessage: userMessage,
    );
    final cleaned = _cleanRevisedSummaryText(revised);
    if (!requireFullFormat) return cleaned;
    return contextMode == ContextMode.rp
        ? normalizeRpSummaryFormat(cleaned)
        : normalizeSummaryFormat(cleaned);
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

  static SummaryEnvelope decodeSummaryEnvelope(String response) {
    var text = response.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    if (text.isEmpty) return const SummaryEnvelope('', []);

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      // Some otherwise capable models add a one-line preface or suffix around
      // the requested JSON. Recover the complete balanced object, but never
      // invent a partial timeline from damaged JSON.
      final jsonObject = _firstBalancedJsonObject(text);
      if (jsonObject != null) {
        try {
          decoded = jsonDecode(jsonObject);
        } on FormatException {
          decoded = null;
        }
      }
    }

    if (decoded is Map) {
      final rawSummary = decoded['summary'];
      final summary = rawSummary is String ? rawSummary.trim() : '';
      final timeline = <TimelineEventCandidate>[];
      final rawTimeline = decoded['timeline'];
      if (rawTimeline is List) {
        for (final raw in rawTimeline) {
          if (raw is! Map) continue;
          final rawEntityIds = raw['subject_entity_ids'];
          final isRpTimelineShape =
              raw.containsKey('narrative_layer') ||
              raw.containsKey('subject_entity_ids') ||
              raw.containsKey('event_key');
          final explicitType = raw['type']?.toString().trim() ?? '';
          final explicitSubject = raw['subject']?.toString().trim() ?? '';
          final type = explicitType.isEmpty && isRpTimelineShape
              ? 'event'
              : explicitType;
          final subject = explicitSubject.isEmpty
              ? (isRpTimelineShape
                    ? (rawEntityIds is List && rawEntityIds.length > 1
                          ? 'relationship'
                          : 'character')
                    : '')
              : explicitSubject;
          if (!const {'event', 'state'}.contains(type) ||
              !const {'character', 'relationship'}.contains(subject)) {
            continue;
          }
          final rawIds = raw['source_message_ids'];
          if (rawIds is! List) continue;
          final ids =
              rawIds
                  .map(
                    (id) => switch (id) {
                      num value => value.toInt(),
                      String value => int.tryParse(value.trim()),
                      _ => null,
                    },
                  )
                  .whereType<int>()
                  .where((id) => id > 0)
                  .toSet()
                  .toList()
                ..sort();
          if (ids.isEmpty) continue;
          final occurredOn = raw['occurred_on'];
          final dateBasis = raw['date_basis'];
          final value = raw['value'];
          final evidence = raw['evidence'];
          final rawKey = raw['key'];
          if (occurredOn is! String ||
              dateBasis is! String ||
              value is! String ||
              evidence is! String ||
              (type == 'state' && rawKey is! String)) {
            continue;
          }
          timeline.add(
            TimelineEventCandidate(
              type: type,
              subject: subject,
              sourceMessageIds: ids,
              occurredOn: occurredOn,
              dateBasis: dateBasis,
              key: type == 'state' ? (rawKey as String) : null,
              value: value,
              evidence: evidence,
              eventKey: raw['event_key']?.toString().trim() ?? '',
              narrativeLayer:
                  raw['narrative_layer']?.toString().trim() ?? 'mainline',
              subjectEntityIds: rawEntityIds is List
                  ? rawEntityIds
                        .map((value) => value?.toString().trim() ?? '')
                        .where((value) => value.isNotEmpty)
                        .toSet()
                        .toList(growable: false)
                  : const <String>[],
            ),
          );
        }
      }
      return SummaryEnvelope(
        summary,
        timeline,
        storylineId: decoded['storyline_id']?.toString().trim() ?? '',
        storyCharacters: _mergeStoryCharacterCandidates(
          _objectMapList(decoded['story_characters']),
          _objectMapList(decoded['character_index']),
        ),
        relationships: _objectMapList(decoded['relationships']),
        storyStates: _objectMapList(decoded['story_states']),
        recallSegments: _decodeRecallSegments(
          decoded['recall_segments'],
          summary,
        ),
      );
    }

    final summaryField = RegExp(
      r'"summary"\s*:\s*("(?:\\.|[^"\\])*")',
    ).firstMatch(text);
    if (summaryField != null) {
      try {
        final summary = jsonDecode(summaryField.group(1)!) as String;
        final compactCharacters = _decodePartialObjectList(
          text,
          'character_index',
        );
        final storylineField = RegExp(
          r'"storyline_id"\s*:\s*("(?:\\.|[^"\\])*")',
        ).firstMatch(text);
        var storylineId = '';
        if (storylineField != null) {
          storylineId = (jsonDecode(storylineField.group(1)!) as String).trim();
        }
        return SummaryEnvelope(
          summary.trim(),
          const [],
          storylineId: storylineId,
          storyCharacters: _mergeStoryCharacterCandidates(
            const <Map<String, Object?>>[],
            compactCharacters,
          ),
        );
      } on FormatException {
        return const SummaryEnvelope('', []);
      }
    }
    if (!text.startsWith('{') && !text.startsWith('[')) {
      // Backward-compatible plain summary response. This keeps summaries
      // working with models that ignore the new JSON envelope, while safely
      // dropping timeline candidates.
      return SummaryEnvelope(text, const []);
    }
    return const SummaryEnvelope('', []);
  }

  static List<Map<String, Object?>> _objectMapList(Object? raw) {
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw
        .whereType<Map>()
        .map(
          (row) => <String, Object?>{
            for (final entry in row.entries) entry.key.toString(): entry.value,
          },
        )
        .toList(growable: false);
  }

  static List<Map<String, Object?>> _mergeStoryCharacterCandidates(
    List<Map<String, Object?>> detailed,
    List<Map<String, Object?>> compact,
  ) {
    final merged = <Map<String, Object?>>[];
    final names = <String>{};
    String key(Map<String, Object?> value) => (value['name']?.toString() ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

    for (final candidate in [...detailed, ...compact]) {
      final nameKey = key(candidate);
      final name = candidate['name']?.toString().trim() ?? '';
      if (nameKey.isEmpty || !names.add(nameKey)) continue;
      merged.add(<String, Object?>{
        if (!candidate.containsKey('entity_id')) 'entity_id': 'new',
        ...candidate,
        'name': name,
      });
      if (merged.length >= RpStoryService.characterExtractionLimit) break;
    }
    return List<Map<String, Object?>>.unmodifiable(merged);
  }

  static List<Map<String, Object?>> _decodePartialObjectList(
    String text,
    String key,
  ) {
    final marker = RegExp('"${RegExp.escape(key)}"\\s*:').firstMatch(text);
    if (marker == null) return const <Map<String, Object?>>[];
    final start = text.indexOf('[', marker.end);
    if (start < 0) return const <Map<String, Object?>>[];
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5c) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
        }
        continue;
      }
      if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x5b) {
        depth++;
      } else if (unit == 0x5d) {
        depth--;
        if (depth == 0) {
          try {
            return _objectMapList(jsonDecode(text.substring(start, index + 1)));
          } on FormatException {
            return const <Map<String, Object?>>[];
          }
        }
      }
    }
    return const <Map<String, Object?>>[];
  }

  static List<SummaryRecallSegment> _decodeRecallSegments(
    Object? raw,
    String summary,
  ) {
    if (raw is! List || summary.trim().isEmpty) {
      return const <SummaryRecallSegment>[];
    }
    final result = <SummaryRecallSegment>[];
    final usedOrders = <int>{};
    for (final value in raw.whereType<Map>()) {
      final rawOrder = value['segment_order'];
      final order = switch (rawOrder) {
        int number => number,
        num number => number.toInt(),
        String text => int.tryParse(text.trim()) ?? 0,
        _ => 0,
      };
      final content = value['content']?.toString().trim() ?? '';
      final anchor = value['anchor']?.toString().trim() ?? '';
      final title = value['title']?.toString().trim() ?? '';
      final rawKeywords = value['keywords'];
      final keywords = rawKeywords is List
          ? rawKeywords
                .map((item) => item?.toString().trim() ?? '')
                .where((item) => item.isNotEmpty)
                .toSet()
                .take(1)
                .toList(growable: false)
          : const <String>[];
      final hasValidLegacyContent =
          content.isNotEmpty &&
          !RegExp(r'\n\s*\n').hasMatch(content) &&
          summary.contains(content);
      final hasLightweightLocator =
          anchor.isNotEmpty || (content.isEmpty && title.isNotEmpty);
      // Legacy full-content rows must still bind to the replacement summary.
      // New rows may use an exact anchor, or title + order as a final fallback.
      if (order <= 0 ||
          usedOrders.contains(order) ||
          keywords.isEmpty ||
          (!hasValidLegacyContent && !hasLightweightLocator)) {
        continue;
      }
      usedOrders.add(order);
      result.add(
        SummaryRecallSegment(
          order: order,
          title: title,
          content: hasValidLegacyContent ? content : '',
          anchor: anchor,
          keywords: keywords,
        ),
      );
    }
    result.sort((left, right) => left.order.compareTo(right.order));
    return List<SummaryRecallSegment>.unmodifiable(result);
  }

  /// Produces a complete event-segment index even when a provider omits or
  /// slightly damages recall_segments. Model labels remain authoritative when
  /// they bind to the final summary; only uncovered summary text gets a local,
  /// deterministic fallback. No extra API request is made.
  static List<ContextSummarySegmentDraft> buildRpRecallSegmentDrafts({
    required String summary,
    Iterable<SummaryRecallSegment> modelSegments =
        const <SummaryRecallSegment>[],
  }) {
    final normalized = normalizeRpSummaryFormat(summary).trim();
    if (normalized.isEmpty) return const <ContextSummarySegmentDraft>[];

    final paragraphs =
        <({int order, int start, int end, String title, String content})>[];
    var searchOffset = 0;
    for (final segment in _splitSummarySegments(normalized).expand((segment) {
      final parts = segment.content
          .split(RegExp(r'\n\s*\n'))
          .map((paragraph) => paragraph.trim())
          .where((paragraph) => paragraph.isNotEmpty)
          .toList(growable: false);
      return <_SummarySegment>[
        for (var index = 0; index < parts.length; index++)
          _SummarySegment(index == 0 ? segment.title : '', parts[index]),
      ];
    })) {
      final content = segment.content.trim();
      var start = normalized.indexOf(content, searchOffset);
      if (start < 0) start = normalized.indexOf(content);
      if (start < 0 || content.isEmpty) continue;
      final end = start + content.length;
      paragraphs.add((
        order: paragraphs.length + 1,
        start: start,
        end: end,
        title: segment.title.trim(),
        content: content,
      ));
      searchOffset = end;
    }

    final indexed =
        <
          ({
            int start,
            int end,
            String title,
            String content,
            List<String> keywords,
          })
        >[];
    final usedParagraphs = <int>{};
    for (final segment in modelSegments) {
      if (segment.keywords.isEmpty) continue;
      final legacyContent = segment.content.trim();
      if (legacyContent.isNotEmpty &&
          !RegExp(r'\n\s*\n').hasMatch(legacyContent)) {
        final start = normalized.indexOf(legacyContent);
        if (start >= 0) {
          final end = start + legacyContent.length;
          indexed.add((
            start: start,
            end: end,
            title: segment.title.trim(),
            content: legacyContent,
            keywords: segment.keywords,
          ));
          for (var index = 0; index < paragraphs.length; index++) {
            final paragraph = paragraphs[index];
            if (paragraph.start < end && paragraph.end > start) {
              usedParagraphs.add(index);
            }
          }
          continue;
        }
      }

      int? matchedIndex;
      final anchor = segment.anchor.trim();
      if (anchor.isNotEmpty) {
        final startsWithMatches = <int>[
          for (var index = 0; index < paragraphs.length; index++)
            if (!usedParagraphs.contains(index) &&
                paragraphs[index].content.startsWith(anchor))
              index,
        ];
        if (startsWithMatches.length == 1) {
          matchedIndex = startsWithMatches.single;
        } else {
          final containsMatches = <int>[
            for (var index = 0; index < paragraphs.length; index++)
              if (!usedParagraphs.contains(index) &&
                  paragraphs[index].content.contains(anchor))
                index,
          ];
          if (containsMatches.length == 1) {
            matchedIndex = containsMatches.single;
          }
        }
      }

      final normalizedTitle = _normalizeRecallTitle(segment.title);
      if (matchedIndex == null && normalizedTitle.isNotEmpty) {
        final titleMatches = <int>[
          for (var index = 0; index < paragraphs.length; index++)
            if (!usedParagraphs.contains(index) &&
                _recallTitlesMatch(
                  normalizedTitle,
                  _normalizeRecallTitle(paragraphs[index].title),
                ))
              index,
        ];
        if (titleMatches.length == 1) matchedIndex = titleMatches.single;
      }

      final orderIndex = segment.order - 1;
      if (matchedIndex == null &&
          orderIndex >= 0 &&
          orderIndex < paragraphs.length &&
          !usedParagraphs.contains(orderIndex)) {
        matchedIndex = orderIndex;
      }
      if (matchedIndex == null) continue;

      final paragraph = paragraphs[matchedIndex];
      usedParagraphs.add(matchedIndex);
      indexed.add((
        start: paragraph.start,
        end: paragraph.end,
        title: segment.title.trim().isEmpty
            ? paragraph.title
            : segment.title.trim(),
        content: paragraph.content,
        keywords: segment.keywords,
      ));
    }

    for (final paragraph in paragraphs) {
      final content = paragraph.content;
      final start = paragraph.start;
      final end = paragraph.end;
      final covered = indexed.any(
        (item) => item.start < end && item.end > start,
      );
      if (covered) continue;
      final keywords = _fallbackRecallKeywords(
        _SummarySegment(paragraph.title, content),
      );
      if (keywords.isEmpty) continue;
      indexed.add((
        start: start,
        end: end,
        title: paragraph.title,
        content: content,
        keywords: keywords,
      ));
    }

    indexed.sort((left, right) => left.start.compareTo(right.start));
    return <ContextSummarySegmentDraft>[
      for (var index = 0; index < indexed.length; index++)
        ContextSummarySegmentDraft(
          order: index + 1,
          title: indexed[index].title,
          content: indexed[index].content,
          keywords: indexed[index].keywords,
          tokenCount: TokenEstimator.estimate(indexed[index].content),
        ),
    ];
  }

  static String _normalizeRecallTitle(String source) {
    return source
        .toLowerCase()
        .replaceAll(RegExp(r'[#*_>`\[\](){}：:·—–\-、，。！？；\s]+'), '')
        .trim();
  }

  static bool _recallTitlesMatch(String left, String right) {
    if (left.isEmpty || right.isEmpty) return false;
    return left == right || left.contains(right) || right.contains(left);
  }

  static List<String> _fallbackRecallKeywords(_SummarySegment segment) {
    final candidates = <String>[];
    void add(String value) {
      var cleaned = value
          .replaceAll(RegExp(r'[#*_>`\[\]]'), '')
          .replaceAll(RegExp(r'^[-—–·：:、，。！？；\s]+|[-—–·：:、，。！？；\s]+$'), '')
          .trim();
      final categorySeparator = cleaned.indexOf('·');
      if (categorySeparator >= 0 && categorySeparator + 1 < cleaned.length) {
        cleaned = cleaned.substring(categorySeparator + 1).trim();
      }
      if (RegExp(
        r'^(主線|支線|氛圍|觀察區|Main|Side Threads|Atmosphere|Observation)$',
        caseSensitive: false,
      ).hasMatch(cleaned)) {
        return;
      }
      if (cleaned.length < 2) return;
      if (cleaned.length > 28) cleaned = cleaned.substring(0, 28).trim();
      if (cleaned.length >= 2 && !candidates.contains(cleaned)) {
        candidates.add(cleaned);
      }
    }

    add(segment.title);
    for (final match in RegExp(
      r'[「『“\"]([^」』”\"]{2,24})[」』”\"]',
    ).allMatches(segment.content)) {
      add(match.group(1) ?? '');
    }
    final plain = segment.content
        .replaceAllMapped(
          RegExp(r'\*\*\[[^\]]+\]\s*([^*]+)\*\*'),
          (match) => match.group(1) ?? '',
        )
        .replaceAll(RegExp(r'[#*_>`]'), ' ');
    for (final clause in plain.split(RegExp(r'[。！？；\n]+'))) {
      final parts = clause.split(RegExp(r'[，,：:]'));
      for (final part in parts) {
        add(part);
        if (candidates.isNotEmpty) break;
      }
      if (candidates.isNotEmpty) break;
    }
    return candidates.take(1).toList(growable: false);
  }

  static String? _firstBalancedJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5C) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
        }
        continue;
      }
      if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x7B) {
        depth++;
      } else if (unit == 0x7D) {
        depth--;
        if (depth == 0) return text.substring(start, index + 1);
      }
    }
    return null;
  }

  @visibleForTesting
  static Map<String, Object> decodeCompressionResponseForTesting(
    String response,
  ) {
    final decoded = decodeSummaryEnvelope(response);
    return {'summary': decoded.summary, 'timeline': decoded.timeline};
  }

  /// 正常摘要偶爾會漏掉明確的生理週期候選。只有來源消息含有「第 N 天、
  /// 開始、結束、今天仍在」這類明確線索且首輪沒回候選時，才用同一摘要
  /// 模型做一次小型補提取；結果仍交由 CharacterTimelineService 驗證，
  /// 不直接落庫。
  static Future<List<TimelineEventCandidate>>
  recoverMissingMenstrualCandidates({
    required List<Message> messages,
    required List<TimelineEventCandidate> candidates,
    String characterId = 'default',
  }) async {
    final relevant = messages.where(_isCharacterMenstrualSource).toList();
    if (relevant.isEmpty ||
        candidates.any(
          (candidate) =>
              _hasMenstrualTerm(candidate.key ?? '') ||
              _hasMenstrualTerm(candidate.evidence),
        )) {
      return candidates;
    }

    try {
      final identity = await _loadSummaryIdentity(characterId);
      final response = await _callModel(
        characterId: characterId,
        systemPrompt: L.pick(
          en: '''
Extract menstrual timeline candidates explicitly stated in the supplied messages. Every speaker label ends in (user) or (char) and may include that person's real name. In a (user) message "I/my/me" is the user and "you/your" is the character; in a (char) message it is the reverse. Only extract statements about the character; drop anything the user says about themselves. Day N or a period explicitly still active today is type=state, subject=character, key=menstrual cycle. A stated start or end is type=event, subject=character. Use the message's local date to resolve occurred_on and quote an exact source substring as evidence.
Output valid JSON only: {"summary":"","timeline":[{"type":"state","subject":"character","source_message_ids":[1],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","key":"menstrual cycle","value":"period day N","evidence":"exact quote"}]}. Use an empty timeline array when there is no explicit candidate.
''',
          zhTW: '''
從消息中提取明確說出的角色生理週期候選。每條消息的 speaker 標記會以 (user) 或 (char) 結尾，並可能帶雙方真名：(user) 消息裡「我」是使用者、「你」是角色；(char) 消息裡相反。只提取屬於角色的敘述，使用者講自己的一律不要提取。生理期第 N 天或明確說今天仍在生理期，使用 type=state、subject=character、key=生理週期；明確開始或結束使用 type=event、subject=character。以消息本地日期換算 occurred_on，evidence 逐字引用來源片段。
只輸出合法 JSON：{"summary":"","timeline":[{"type":"state","subject":"character","source_message_ids":[1],"occurred_on":"YYYY-MM-DD","date_basis":"message_time|relative|explicit","key":"生理週期","value":"生理期第N天","evidence":"原文"}]}。沒有明確候選時 timeline 為空陣列。
''',
        ),
        userMessage: relevant
            .map(
              (message) => _formatSourceMessage(
                message,
                userName: identity.userName,
                characterName: identity.characterName,
              ),
            )
            .join('\n\n'),
      );
      final recovered = decodeSummaryEnvelope(response).timeline;
      if (recovered.isEmpty) return candidates;

      final merged = <TimelineEventCandidate>[...candidates];
      final seen = candidates.map(_timelineCandidateIdentity).toSet();
      for (final candidate in recovered) {
        if (seen.add(_timelineCandidateIdentity(candidate))) {
          merged.add(candidate);
        }
      }
      return merged;
    } catch (_) {
      // 補提取只是保險，不得讓已成功生成的摘要因第二次模型請求失敗。
      return candidates;
    }
  }

  @visibleForTesting
  static bool needsMenstrualRecoveryForTesting({
    required List<Message> messages,
    required List<TimelineEventCandidate> candidates,
  }) {
    return messages.any(_isCharacterMenstrualSource) &&
        !candidates.any(
          (candidate) =>
              _hasMenstrualTerm(candidate.key ?? '') ||
              _hasMenstrualTerm(candidate.evidence),
        );
  }

  /// 補提取只看「屬於角色」的生理週期敘述。使用者說自己的不進候選——
  /// 驗證器還會再擋一次，但不該先送去讓模型看。
  static bool _isCharacterMenstrualSource(Message message) =>
      _hasExplicitMenstrualCue(message.text) &&
      CharacterTimelineService.menstrualStatementBelongsToCharacter(message);

  static String _timelineCandidateIdentity(TimelineEventCandidate candidate) =>
      '${candidate.type}|${candidate.subject}|${candidate.occurredOn}|'
      '${candidate.key ?? ''}|${candidate.value}|'
      '${candidate.sourceMessageIds.join(',')}';

  static bool _hasMenstrualTerm(String text) => RegExp(
    r'生理期|生理週期|生理周期|經期|经期|月經|月经|'
    r'\bperiod\b|\bmenstrual\b|\bmenstruation\b',
    caseSensitive: false,
  ).hasMatch(text);

  static bool _hasExplicitMenstrualCue(String text) {
    final normalized = text.toLowerCase();
    if (!_hasMenstrualTerm(normalized)) return false;
    if (RegExp(
      r'(?:生理期|生理週期|生理周期|經期|经期|月經|月经|period|menstrual|menstruation)'
      r'[^。.!！?？]{0,18}(?:嗎|吗|嘛|是否|是不是|[?？])',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      return false;
    }
    return RegExp(
      r'第?\s*[0-9一二三四五六七八九十兩两]+\s*天|'
      r'開始|开始|來了|来了|來生理期|来生理期|來的生理期|来的生理期|'
      r'結束|结束|完了|已完|沒了|没了|停了|'
      r'今天.{0,8}(?:還是|还是|仍是|仍在|還在|还在|正在)?\s*(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'(?:還是|还是|仍是|仍在|還在|还在|正在).{0,8}(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'\bday\s*\d{1,2}\b|\bstarted\b|\bbegan\b|'
      r'\bended\b|\bfinished\b|\bis over\b|'
      r'\b(?:still|currently)\s+(?:on\s+)?(?:her\s+|your\s+)?period\b',
      caseSensitive: false,
    ).hasMatch(normalized);
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
    String characterId = 'default',
    String conversationId = '',
    required String systemPrompt,
    required String userMessage,
  }) async {
    var model = '';
    var provider = '';
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

      model = await MemorySettings.getSummaryModel();
      if (model.isEmpty) {
        model = await ApiSettings.getModel();
      }
      provider = await ApiSettings.resolveSummaryModelProvider(model);
      final adapter = await ApiSettings.buildAdapterForSummaryModel(model);
      ApiUsage? usage;
      final response = await adapter.sendMessage(
        messages: [
          {'role': 'user', 'content': userMessage},
        ],
        model: model,
        systemPrompt: systemPrompt,
        onUsage: (value) => usage = value,
      );
      await TokenTracker().recordRealUsage(
        provider: provider,
        model: model,
        usage: usage ?? const ApiUsage(),
        characterId: characterId,
        conversationId: conversationId,
        requestKind: ApiRequestKind.summary,
      );
      if (response.trim().isEmpty) {
        throw StateError('摘要模型回傳空內容');
      }
      return response;
    } catch (e, stackTrace) {
      developer.log(
        '窗口摘要失敗',
        error: e,
        stackTrace: stackTrace,
        name: 'ContextCompressor',
      );
      try {
        await AppErrorLogService.record(
          error: e,
          trigger: 'automatic_summary',
          source: 'summary',
          provider: provider,
          model: model,
        );
      } catch (_) {
        // A diagnostics write failure must not crash the chat maintenance job.
      }
      return '';
    }
  }

  static Future<_SummaryIdentity> _loadSummaryIdentity(
    String characterId, {
    String? conversationId,
  }) async {
    var userName = '';
    final scopedConversationId = (conversationId ?? '').trim();
    if (scopedConversationId.isNotEmpty) {
      final conversation = await DatabaseHelper.getConversation(
        scopedConversationId,
      );
      if (conversation != null) {
        userName = (await UserPersonaService.personaForConversation(
          conversation,
        )).displayName.trim();
      }
    }
    if (userName.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      userName = (prefs.getString('user_profile_nickname') ?? '').trim();
      if (userName.isEmpty) {
        userName = (await UserSettings.getUserName()).trim();
      }
    }

    final char = await DatabaseHelper.getCharacter(characterId);
    var roleName = (char?['name'] as String? ?? '').trim();
    if (roleName.isEmpty) {
      roleName = (await UserSettings.getCharacterName()).trim();
    }
    final persona = (char?['description'] as String? ?? '').trim();

    return _SummaryIdentity(
      userName: userName,
      characterName: roleName,
      persona: persona,
    );
  }

  /// Builds only the structured RP lane requested by the dossier model. It is
  /// request-only data: no extra system-prompt slot and no worldbook content.
  static Future<String> buildRpArchiveContext({
    required String characterId,
    required String continuityId,
    required String conversationId,
    required String sourceText,
  }) async {
    final storylines = await DatabaseHelper.getRpStorylines(
      characterId,
      includeArchived: true,
    );
    final storyline = storylines.cast<Map<String, Object?>>().firstWhere(
      (row) => row['id']?.toString() == continuityId,
      orElse: () => <String, Object?>{
        'id': continuityId,
        'name': '',
        'status': 'active',
      },
    );
    final allCharacters = await RpStoryService.listCharacters(
      characterId,
      continuityId: continuityId,
    );
    final lowerSource = sourceText.toLowerCase();
    bool mentioned(Map<String, dynamic> row) {
      final terms = <String>[
        row['name']?.toString() ?? '',
        ..._decodeJsonStrings(row['aliases_json']),
      ];
      return terms.any((term) {
        final normalized = term.trim().toLowerCase();
        return normalized.length >= 2 && lowerSource.contains(normalized);
      });
    }

    Map<String, Object?> select(Map<String, Object?> row, List<String> keys) =>
        <String, Object?>{
          for (final key in keys)
            if (row[key] != null) key: row[key],
        };

    // Archive requests receive only people who actually occur in this source
    // batch. Active/offstage cast remains stored in the dossier but must not
    // inflate every background summarization request.
    final involved = allCharacters
        .where(mentioned)
        .take(24)
        .toList(growable: false);
    // Subset: only those whose name/alias actually appears in this batch's
    // source text. This is the "matched existing" list — explicitly separate
    // from the full roster so the model knows which names are NOT yet filed.
    final matched = allCharacters
        .where(mentioned)
        .take(24)
        .toList(growable: false);
    final involvedKeys = involved
        .map((row) => row['entity_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    final allRelationships = await RpStoryService.listRelationships(
      characterId,
      continuityId: continuityId,
    );
    final relationships = allRelationships
        .where(
          (row) =>
              involvedKeys.contains(row['from_entity_key']) ||
              involvedKeys.contains(row['to_entity_key']),
        )
        .take(16)
        .map(
          (row) => select(row, const <String>[
            'from_entity_key',
            'to_entity_key',
            'from_name',
            'to_name',
            'direction',
            'current_relation',
            'origin',
            'closeness_catalyst',
            'forms_of_address',
            'shared_secrets',
            'conflicts',
            'knowledge_scope',
            'visibility',
          ]),
        )
        .toList(growable: false);
    final allStates = await RpStoryStateService.listStates(
      characterId,
      continuityId: continuityId,
    );
    final characterCard = await DatabaseHelper.getCharacter(characterId);
    final recalledWorldbook = await RpWorldbookService.recallPrompt(
      characterId: characterId,
      continuityId: continuityId,
      query: sourceText,
    );

    bool relatedState(Map<String, dynamic> state) {
      final type = state['state_type']?.toString() ?? '';
      if (type == 'scene' || type == 'plot') return true;
      return involvedKeys.contains(state['subject_entity_key']) ||
          involvedKeys.contains(state['object_entity_key']);
    }

    final relevantStates = allStates.where(relatedState).toList();
    final statesForModel =
        <Map<String, Object?>>[
              ...relevantStates
                  .where(RpStoryStateService.isActiveForRecall)
                  .take(12),
              ...relevantStates
                  .where(
                    (state) => !RpStoryStateService.isActiveForRecall(state),
                  )
                  .take(4),
            ]
            .map(
              (state) => select(state, const <String>[
                'state_key',
                'state_type',
                'subject_entity_key',
                'object_entity_key',
                'value',
                'status',
                'story_time',
              ]),
            )
            .toList(growable: false);

    final currentPersona = <String, Object?>{};
    if (conversationId.isNotEmpty) {
      final conversation = await DatabaseHelper.getConversation(conversationId);
      if (conversation != null) {
        final persona = await UserPersonaService.personaForConversation(
          conversation,
        );
        currentPersona.addAll(<String, Object?>{
          'display_name': persona.displayName,
          'pronouns': persona.pronouns,
          'bio': persona.bio,
          'prompt_content': persona.promptContent,
        });
      }
    }

    final participatingProfiles = <Map<String, Object?>>[
      if (characterCard != null)
        <String, Object?>{
          'profile_type': 'main_character_card',
          ...select(characterCard, const <String>[
            'id',
            'name',
            'gender',
            'relationship',
            'description',
            'race',
            'skill',
            'age',
            'height',
            'self_notes',
          ]),
        },
      if (currentPersona.isNotEmpty)
        <String, Object?>{
          'profile_type': 'current_user_persona',
          ...currentPersona,
        },
      ...involved.map(
        (row) => <String, Object?>{
          'profile_type': 'story_character',
          ...select(row, const <String>[
            'entity_key',
            'name',
            'aliases_json',
            'identities_json',
            'gender',
            'identity',
            'relation_to_leads',
            'personality',
            'appearance',
            'faction',
            'core_motivation',
            'current_stance',
          ]),
        },
      ),
    ];

    final buffer = StringBuffer()
      ..writeln('【當前故事線】')
      ..writeln(jsonEncode(select(storyline, const ['id', 'name', 'status'])))
      ..writeln()
      ..writeln('【本輪參與劇情的具體人設】')
      ..writeln(jsonEncode(participatingProfiles))
      ..writeln()
      ..writeln('【本輪關鍵詞召回的世界書】')
      ..writeln(recalledWorldbook)
      ..writeln()
      ..writeln('【現有劇情狀態】')
      ..writeln(jsonEncode(statesForModel))
      ..writeln()
      ..writeln('【現有人物關係】')
      ..writeln(jsonEncode(relationships))
      ..writeln()
      ..writeln('【本輪命中的既有人物】')
      ..writeln(
        '以下只列出姓名或別名確實出現在本輪正文中的已建檔人物，僅用於沿用 entity_id。正文中出現但不在此清單的名字即為新人物，必須以 entity_id="new" 建檔。',
      )
      ..write(
        jsonEncode(
          matched
              .map(
                (row) =>
                    select(row, const ['entity_key', 'name', 'aliases_json']),
              )
              .toList(growable: false),
        ),
      );
    return buffer.toString();
  }

  static List<String> _decodeJsonStrings(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<String> _buildIdentityContext(String characterId) async {
    final identity = await _loadSummaryIdentity(characterId);
    return identity.format(includePersona: true);
  }

  static String _namedJournalIdentityRule(_SummaryIdentity identity) {
    final userName = identity.userName.trim().isEmpty
        ? L.pick(en: 'the other person', zhTW: '對方', zhCN: '对方')
        : identity.userName.trim();
    final characterName = identity.characterName.trim().isEmpty
        ? L.pick(en: 'the character', zhTW: '角色', zhCN: '角色')
        : identity.characterName.trim();
    return L.pick(
      en: 'Named journal identity rule: speaker:$userName(user) is "$userName" and speaker:$characterName(char) is "$characterName". Every summary entry names them directly and never substitutes I/you/user/AI.',
      zhTW:
          '具名輕手記身分規則：speaker:$userName(user) 就是「$userName」，speaker:$characterName(char) 就是「$characterName」。每條摘要都直呼姓名，不得改寫成我／你／妳／使用者／User／AI。',
      zhCN:
          '具名轻手记身份规则：speaker:$userName(user) 就是“$userName”，speaker:$characterName(char) 就是“$characterName”。每条摘要都直呼姓名，不得改写成我／你／妳／用户／User／AI。',
    );
  }

  @visibleForTesting
  static String formatSourceMessageForTesting(
    Message message, {
    required String userName,
    required String characterName,
  }) => _formatSourceMessage(
    message,
    userName: userName,
    characterName: characterName,
  );

  static String _formatSourceMessage(
    Message message, {
    String userName = '',
    String characterName = '',
  }) {
    final time = message.createdAt.isUtc
        ? message.createdAt.toLocal()
        : message.createdAt;
    final localTime =
        '${time.year.toString().padLeft(4, '0')}-'
        '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final fallback = message.isUser
        ? L.pick(en: 'the other person', zhTW: '對方', zhCN: '对方')
        : L.pick(en: 'the character', zhTW: '角色', zhCN: '角色');
    final name = (message.isUser ? userName : characterName).trim();
    final role =
        '${name.isEmpty ? fallback : name}(${message.isUser ? 'user' : 'char'})';
    return '[msg:${message.id ?? 0} | local_time:$localTime | '
        'speaker:$role]\n${message.text}';
  }
}

class _SummaryIdentity {
  final String userName;
  final String characterName;
  final String persona;

  const _SummaryIdentity({
    required this.userName,
    required this.characterName,
    required this.persona,
  });

  String format({required bool includePersona}) {
    if (userName.isEmpty &&
        characterName.isEmpty &&
        (!includePersona || persona.isEmpty)) {
      return '';
    }

    if (L.locale == 'en') {
      final parts = <String>[];
      if (userName.isNotEmpty) parts.add('User name: $userName');
      if (characterName.isNotEmpty) {
        parts.add('Character name: $characterName');
      }
      if (includePersona && persona.isNotEmpty) {
        parts.add('Character card/persona:\n$persona');
      }
      return 'Identity anchors for disambiguation:\n${parts.join('\n')}';
    }

    final parts = <String>[];
    if (userName.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: 'user 名為：')}$userName');
    }
    if (characterName.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '模型扮演角色名為：')}$characterName');
    }
    if (includePersona && persona.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '角色人設卡：')}\n$persona');
    }
    return '${L.pick(en: '', zhTW: '人物辨識錨點：')}\n${parts.join('\n')}';
  }
}

class SummaryEnvelope {
  final String summary;
  final String storylineId;
  final List<TimelineEventCandidate> timeline;
  final List<Map<String, Object?>> storyCharacters;
  final List<Map<String, Object?>> relationships;
  final List<Map<String, Object?>> storyStates;
  final List<SummaryRecallSegment> recallSegments;

  const SummaryEnvelope(
    this.summary,
    this.timeline, {
    this.storylineId = '',
    this.storyCharacters = const <Map<String, Object?>>[],
    this.relationships = const <Map<String, Object?>>[],
    this.storyStates = const <Map<String, Object?>>[],
    this.recallSegments = const <SummaryRecallSegment>[],
  });
}

class SummaryRecallSegment {
  final int order;
  final String title;
  final String content;
  final String anchor;
  final List<String> keywords;

  const SummaryRecallSegment({
    required this.order,
    required this.keywords,
    this.title = '',
    this.content = '',
    this.anchor = '',
  });
}

class _SummarySegment {
  final String title;
  final String content;

  const _SummarySegment(this.title, this.content);
}
