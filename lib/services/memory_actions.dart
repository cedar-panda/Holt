import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import '../memory/retriever.dart';
import '../models/memory.dart';
import '../models/context_mode.dart';
import 'locale_strings.dart';
import 'model_action_protocol.dart';
import 'memory_guard_service.dart';
import 'settings/memory_settings.dart';

/// 模型自主記憶動作
///
/// 模型在回覆中用標籤聲明記憶動作，落庫前剝離執行：
/// - `<memo>[類別] 內容 @觸發詞</memo>`  → 主動寫入記憶（高置信度）
/// - `<persona_note>一句話</persona_note>` → 角色自我註記（隨靜態注入）
///
/// 與 `<think>` / [sticker:ID] 同一思路：純文本協議，全 provider 通用，
/// 不依賴 function calling。
class MemoryActions {
  static final Map<String, _MemoryActionState> _statesByWindow = {};

  static _MemoryActionState _resetState(String windowId) {
    final state = _MemoryActionState();
    _statesByWindow[windowId] = state;
    return state;
  }

  static int? lastInsertedMemoryIdFor(String windowId) =>
      _statesByWindow[windowId]?.lastInsertedMemoryId;

  static List<String> lastActionLogFor(String windowId) => List.unmodifiable(
    _statesByWindow[windowId]?.actionLog ?? const <String>[],
  );

  static List<String> lastProposalIdsFor(String windowId) => List.unmodifiable(
    _statesByWindow[windowId]?.proposalIds ?? const <String>[],
  );

  static void registerProposal(
    String windowId, {
    required String proposalId,
    required String log,
  }) {
    final state = _statesByWindow.putIfAbsent(windowId, _MemoryActionState.new);
    if (state.proposalIds.contains(proposalId)) return;
    state.proposalIds.add(proposalId);
    if (log.trim().isNotEmpty) state.actionLog.add(log.trim());
  }

  /// Lets another private model-action processor contribute to the same
  /// per-reply activity log without owning or resetting memory state.
  static void registerExternalAction(String windowId, String log) {
    final normalized = log.trim();
    if (normalized.isEmpty) return;
    final state = _statesByWindow.putIfAbsent(windowId, _MemoryActionState.new);
    state.actionLog.add(normalized);
  }

  static String? lastSearchQueryFor(String windowId) =>
      _statesByWindow[windowId]?.lastSearchQuery;

  static String lastSearchScopeFor(String windowId) =>
      _statesByWindow[windowId]?.lastSearchScope ?? 'current';

  static void clearSearchQuery(String windowId) {
    _statesByWindow[windowId]?.lastSearchQuery = null;
  }

  static void releaseWindow(String windowId) {
    _statesByWindow.remove(windowId);
  }

  static Future<void> bindSelfNotesToMessage(
    String windowId,
    int messageId,
  ) async {
    final ids = _statesByWindow[windowId]?.selfNoteIds ?? const <int>[];
    await DatabaseHelper.bindSelfNotesToMessage(ids, messageId);
  }

  static String _clip(String s, [int n = 26]) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  static final _memoRe = RegExp(r'<memo>([\s\S]*?)</memo>', multiLine: true);
  static final _noteRe = RegExp(
    r'<persona_note>([\s\S]*?)</persona_note>',
    multiLine: true,
  );
  static final _delRe = RegExp(
    r'<memo_del>([\s\S]*?)</memo_del>',
    multiLine: true,
  );
  static final _mergeRe = RegExp(
    r'<memo_merge>([\s\S]*?)</memo_merge>',
    multiLine: true,
  );
  static final _updateRe = RegExp(
    r'<memo_update>([\s\S]*?)</memo_update>',
    multiLine: true,
  );
  static final _searchRe = RegExp(
    r'''<search_chat(?:\s+scope=["']?(current|daily|rp|all)["']?)?>([\s\S]*?)</search_chat>''',
    multiLine: true,
    caseSensitive: false,
  );
  static final _toolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*?</tool_calls?>',
    multiLine: true,
    caseSensitive: false,
  );

  /// 記憶寫入關閉時只剝離標籤，不執行任何落庫/搜尋動作。
  static String stripReply(
    String text, {
    required String windowId,
    bool resetState = true,
    bool captureSearchQuery = false,
  }) {
    text = ModelActionProtocol.normalizeForLegacyProcessors(text);
    late final _MemoryActionState state;
    if (resetState) {
      state = _resetState(windowId);
    } else {
      state = _statesByWindow.putIfAbsent(windowId, _MemoryActionState.new);
    }
    if (captureSearchQuery) _captureSearchQuery(text, state);
    return text
        .replaceAll(_memoRe, '')
        .replaceAll(_noteRe, '')
        .replaceAll(_delRe, '')
        .replaceAll(_mergeRe, '')
        .replaceAll(_updateRe, '')
        .replaceAll(_searchRe, '')
        .replaceAllMapped(
          _toolCallsRe,
          (m) => _extractSearchQueryFromToolCall(m.group(0)!) != null
              ? ''
              : m.group(0)!,
        )
        .trim();
  }

  /// 注入到靜態 prompt 的能力說明（文本固定，緩存安全）
  /// [userNickname] 運行時填入用戶暱稱，解決記憶中「你」「我」混淆
  static String abilityPrompt({
    String userNickname = '',
    String characterName = '',
    ContextMode contextMode = ContextMode.daily,
  }) {
    final name = userNickname.isNotEmpty
        ? userNickname
        : (L.locale == 'en' ? 'the other person' : '對方');
    final charName = characterName.isNotEmpty
        ? characterName
        : (L.locale == 'en' ? '[char name]' : '角色名');
    if (contextMode == ContextMode.rp) {
      return L.pick(
        en: '''■ RP memory
  {"type":"memory.propose","arguments":{"category":"Category","content":"durable fact in third person","triggers":["event trigger","specific result"]}}
  Keep only durable plot facts, relationship changes, promises, established setting facts, and unresolved threads supported by this RP window. Use third person, max 2 entries and 2 triggers each.
  {"type":"search.chat","arguments":{"scope":"rp","query":"keyword"}}
  Search exact past context when needed. Prefer scope="rp" in RP; use all only when cross-mode context is genuinely useful. Never mention searching or hidden records.
  If the latest user message explicitly corrects a supplied RP chronology/state record, you may update that existing record only:
  {"type":"rp.timeline.correct","arguments":{"event_key":"existing event_key","value":"corrected event fact","story_time":"optional corrected story time","evidence":"exact quote from the latest user message"}}
  {"type":"rp.state.correct","arguments":{"state_key":"existing state_key","value":"corrected current fact","status":"valid status for this state type","evidence":"exact quote from the latest user message"}}
  Reuse a key shown in the supplied references. Never create a key, infer a correction from character dialogue, or revise a record without an exact quote from the latest user message.''',
        zhTW: '''■ RP 記憶
  {"type":"memory.propose","arguments":{"category":"類別","content":"第三人稱耐久事實","triggers":["事件觸發詞","具體結果"]}}
  只記本 RP 窗口正文支持、對後續有持續價值的劇情事實、關係轉折、承諾、已確立設定與未完線索。使用第三人稱，每次最多 2 條，每條最多 2 個觸發詞。
  {"type":"search.chat","arguments":{"scope":"rp","query":"關鍵詞"}}
  需要精確過往內容時才搜尋；RP 中優先選 rp，只有確實需要跨模式時才選 all。不得向使用者提及搜尋或隱藏記錄。
  若最新一則 user 訊息明確指出已注入的 RP 時間線／劇情狀態記錯，可只修正該既有記錄：
  {"type":"rp.timeline.correct","arguments":{"event_key":"既有 event_key","value":"修正後事件事實","story_time":"可選的修正後劇情時間","evidence":"最新 user 訊息中的逐字原文"}}
  {"type":"rp.state.correct","arguments":{"state_key":"既有 state_key","value":"修正後當前事實","status":"該狀態類型的合法值","evidence":"最新 user 訊息中的逐字原文"}}
  必須沿用參考區塊提供的 key。不得自創 key、不得把角色台詞視為 user 修正，也不得在沒有最新 user 逐字證據時改動記錄。''',
        zhCN: '''■ RP 记忆
  {"type":"memory.propose","arguments":{"category":"类别","content":"第三人称耐久事实","triggers":["事件触发词","具体结果"]}}
  只记本 RP 窗口正文支持、对后续有持续价值的剧情事实、关系转折、承诺、已确立设定与未完线索。使用第三人称，每次最多 2 条，每条最多 2 个触发词。
  {"type":"search.chat","arguments":{"scope":"rp","query":"关键词"}}
  需要精确过往内容时才搜索；RP 中优先选择 rp，只有确实需要跨模式时才选 all。不得向用户提及搜索或隐藏记录。
  若最新一条 user 消息明确指出已注入的 RP 时间线／剧情状态记错，可只修正该既有记录：
  {"type":"rp.timeline.correct","arguments":{"event_key":"既有 event_key","value":"修正后事件事实","story_time":"可选的修正后剧情时间","evidence":"最新 user 消息中的逐字原文"}}
  {"type":"rp.state.correct","arguments":{"state_key":"既有 state_key","value":"修正后当前事实","status":"该状态类型的合法值","evidence":"最新 user 消息中的逐字原文"}}
  必须沿用参考区块提供的 key。不得自创 key、不得把角色台词视为 user 修正，也不得在没有最新 user 逐字证据时改动记录。''',
      );
    }
    if (L.locale == 'en') {
      return '''■ Memory
  {"type":"memory.propose","arguments":{"category":"Preference | Promise | Important Event","content":"third-person durable fact","triggers":["event trigger"]}}
      Categories: Preference | Promise | Important Event
  Preference: Only record truly meaningful preferences.
  Write in third person: use your character name and "$name". Example: "$name kissed $charName yesterday".
  Max 2 triggers, pick the most relevant words.
  Max 2 entries per reply. Only record what's truly worth keeping long-term.

  {"type":"memory.delete","arguments":{"ids":["id"]}}  Delete outdated/wrong memories (recoverable)
  {"type":"memory.merge","arguments":{"ids":["id1","id2"],"category":"Category","content":"rebuilt fact","triggers":["trigger"]}}  Merge duplicates into one
  Only delete/merge what you're sure about. Injected memories carry ids like [#12·Promise] — never mention ids in conversation, refer to content directly.

  {"type":"self_note.add","arguments":{"content":"one sentence"}}
  Use when you form a new lasting understanding of yourself, your speech patterns, or how you interact with $name. You must record this inner monologue or character profile update.

  {"type":"search.chat","arguments":{"scope":"daily","query":"keyword"}}
  Internal retrieval for past conversations. Prefer daily here; choose rp or all only when genuinely useful. The system will provide hidden results; never mention searching, records, keywords, or tools to $name. Max 1 per reply.''';
    }
    return L.pick(
      en: '',
      zhTW:
          '''■ 記憶
  {"type":"memory.propose","arguments":{"category":"偏好｜約定｜重要事件","content":"第三人稱耐久事實","triggers":["事件觸發詞"]}}
  類別：偏好｜約定｜重要事件
  偏好：只記真正有意義的偏好。
  建議用第三人稱記錄，如「$name昨天親了$charName」。
  觸發詞最多 2 個，選關聯性最高的詞。
  一次至多 2 條。只記你認為真正值得長久保留的。

  {"type":"memory.delete","arguments":{"ids":["id"]}}  刪除過時記憶（可恢復）
  {"type":"memory.merge","arguments":{"ids":["id1","id2"],"category":"類別","content":"重構後內容","triggers":["觸發詞"]}}  合併重複記憶為一條
  系統帶入的記憶編號如 [#12·約定]，這些是給你看的提示，回覆時自然地聊內容就好。

  {"type":"self_note.add","arguments":{"content":"一句話"}}
  當你對自己有新的認知，或是對$name有新的感覺時，可以記下來作為內心獨白。最多可記十二條，新進舊出。

  {"type":"search.chat","arguments":{"scope":"daily","query":"關鍵詞"}}
  回想過去聊天內容時使用；日常模式優先選 daily，只有確實需要時才選 rp 或 all。一次最多 1 個。''',
    );
  }

  /// 處理模型回覆：執行標籤動作，返回剝離後的正文
  static Future<String> processReply(
    String text, {
    required String characterId,
    required String mode,
    required String windowId,
    bool emotionEnabled = true,
    bool resetState = true,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    String provider = '',
    String modelId = '',
    String modelVersion = '',
    int? sourceMessageId,
  }) async {
    text = ModelActionProtocol.normalizeForLegacyProcessors(text);
    final state = resetState
        ? _resetState(windowId)
        : _statesByWindow.putIfAbsent(windowId, _MemoryActionState.new);
    final lowerText = text.toLowerCase();
    if (!lowerText.contains('<memo') &&
        !lowerText.contains('<persona_note>') &&
        !lowerText.contains('<search_chat>') &&
        !lowerText.contains('<tool_call')) {
      return text;
    }
    var out = text;

    // memo → 入庫
    int memoCount = 0;
    for (final m in _memoRe.allMatches(text)) {
      if (memoCount >= 2) break; // RP／摘要模型每次最多提出兩條待確認記憶。
      final raw = m.group(1)!.trim();
      if (raw.isEmpty) continue;
      final parsed = _parseEntry(raw);
      if (parsed == null) continue;
      final now = DateTime.now();
      final dateStr = '${now.month}/${now.day}';
      var finalContent = parsed[1];
      if (!finalContent.startsWith('[$dateStr]')) {
        finalContent = '[$dateStr] $finalContent';
      }

      // 情緒座標按範圍讀：RP 故事線與日常各自一份（平行時空）。
      final points = emotionEnabled
          ? await EmotionCoordinates.activePoints(
              EmotionCoordinates.scopeId(characterId, contextMode, continuityId),
            )
          : const <EmotionPoint>[];
      int? emoX, emoY, emoRes;
      if (points.isNotEmpty) {
        final latest = points.first;
        emoX = latest.x.round();
        emoY = latest.y.round();
        emoRes = latest.concentration.round();
      }

      final result = await MemoryGuardService.guardNewMemory(
        candidate: Memory(
          characterId: characterId,
          contextMode: contextMode,
          continuityId: continuityId,
          mode: mode,
          category: parsed[0],
          content: finalContent,
          confidence: 'high',
          sourceConversationId: windowId,
          triggers: parsed[2],
          emotionX: emoX,
          emotionY: emoY,
          emotionResonance: emoRes,
        ),
        source: 'model',
        sourceConversationId: windowId,
      );
      switch (result.disposition) {
        case GuardedMemoryWriteDisposition.inserted:
          state.lastInsertedMemoryId ??= result.memoryId;
          state.actionLog.add(
            '✚ 寫入 #${result.memoryId} [${parsed[0]}] ${_clip(parsed[1])}',
          );
          break;
        case GuardedMemoryWriteDisposition.skippedDuplicate:
          state.actionLog.add('≋ 已略過重複記憶 [${parsed[0]}] ${_clip(parsed[1])}');
          break;
        case GuardedMemoryWriteDisposition.proposalCreated:
          if (result.proposalId != null) {
            state.proposalIds.add(result.proposalId!);
          }
          state.actionLog.add(
            result.existingMemoryId == null ? '◌ 模型記憶待你確認' : '◌ 疑似重複記憶已送往提案匣',
          );
          break;
      }
      memoCount++;
    }
    // The first two valid tags are the only ones allowed to reach storage,
    // but every control tag is private protocol and must be removed from the
    // visible reply. Leaving overflow tags on screen would both leak the
    // protocol and make the hard limit look as if it had failed.
    out = out.replaceAll(_memoRe, '');

    // persona_note → 角色自我註記
    int noteCount = 0;
    for (final m in _noteRe.allMatches(text)) {
      if (noteCount >= 2) break;
      final note = m.group(1)!.trim();
      if (note.isEmpty) continue;
      final retainLongTerm = await MemorySettings.getSelfNotesLongTermEnabled();
      final result = await DatabaseHelper.appendSelfNoteDetailed(
        characterId,
        note,
        retainLongTerm: retainLongTerm,
        provider: provider,
        modelId: modelId,
        modelVersion: modelVersion,
        sourceConversationId: windowId,
        sourceMessageIds: <int>[?sourceMessageId],
      );
      if (result.accepted) {
        if (result.recordId != null) state.selfNoteIds.add(result.recordId!);
        state.actionLog.add('✎ 自我註記 ${_clip(note)}');
      }
      noteCount++;
    }
    int noteStripCount = 0;
    out = out.replaceAllMapped(
      _noteRe,
      (m) => noteStripCount++ < noteCount ? '' : m.group(0)!,
    );

    // memo_del → 待確認提案；模型不得直接改動記憶。
    int delCount = 0;
    for (final m in _delRe.allMatches(text)) {
      // 模型給的是窗口短號 → 反查真 id；查不到=亂編，丟棄
      final ids = m
          .group(1)!
          .split(RegExp(r'[,，\s]+'))
          .map(int.tryParse)
          .whereType<int>()
          .map((shortNo) => Retriever.realIdFor(shortNo, windowId: windowId))
          .whereType<int>()
          .take(6)
          .toSet()
          .toList();
      final proposalId = await MemoryGuardService.proposeDelete(
        characterId: characterId,
        mode: mode,
        sourceConversationId: windowId,
        targetIds: ids,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      if (proposalId != null) {
        state.proposalIds.add(proposalId);
        state.actionLog.add('◌ 提出刪除記憶建議');
      }
      delCount++;
    }
    int delStripCount = 0;
    out = out.replaceAllMapped(
      _delRe,
      (m) => delStripCount++ < delCount ? '' : m.group(0)!,
    );

    // memo_merge → 待確認提案；確認前不建立新條、不遷移連線。
    int mergeCount = 0;
    for (final m in _mergeRe.allMatches(text)) {
      if (mergeCount >= 2) break;
      final body = m.group(1)!.trim();
      final sep = body.indexOf('|');
      if (sep <= 0) continue;
      // 短號 → 真 id（亂編的丟棄）
      final ids = body
          .substring(0, sep)
          .split(RegExp(r'[,，\s]+'))
          .map(int.tryParse)
          .whereType<int>()
          .map((shortNo) => Retriever.realIdFor(shortNo, windowId: windowId))
          .whereType<int>()
          .toList();
      if (ids.length < 2) continue;
      final parsed = _parseEntry(body.substring(sep + 1).trim());
      if (parsed == null) continue;
      final proposalId = await MemoryGuardService.proposeMerge(
        characterId: characterId,
        mode: mode,
        sourceConversationId: windowId,
        targetIds: ids,
        category: parsed[0],
        content: parsed[1],
        triggers: parsed[2],
        contextMode: contextMode,
        continuityId: continuityId,
      );
      if (proposalId != null) {
        state.proposalIds.add(proposalId);
        state.actionLog.add('◌ 提出合併 ${ids.length} 條記憶建議 → ${_clip(parsed[1])}');
      }
      mergeCount++;
    }
    int mergeStripCount = 0;
    out = out.replaceAllMapped(
      _mergeRe,
      (m) => mergeStripCount++ < mergeCount ? '' : m.group(0)!,
    );
    out = out.replaceAll(_updateRe, '');

    // search_chat → 記錄查詢詞，由 chat_screen 觸發二次調用
    final searchMatch = _searchRe.firstMatch(out);
    if (searchMatch != null) {
      final scope = searchMatch.group(1)?.trim() ?? 'current';
      final query = searchMatch.group(2)!.trim();
      if (query.isNotEmpty && state.lastSearchQuery == null) {
        // 只取第一個，防止模型一次發多個搜尋
        state.lastSearchQuery = query;
        state.lastSearchScope = scope;
        state.actionLog.add('🔍 搜尋「$query」');
      }
      out = out.replaceFirst(_searchRe, '');
    }

    // DeepSeek / 部分 OpenAI-compatible 模型會把純文本標籤改寫成 tool_calls。
    for (final m in _toolCallsRe.allMatches(out)) {
      final query = _extractSearchQueryFromToolCall(m.group(0)!);
      if (query != null && query.isNotEmpty && state.lastSearchQuery == null) {
        state.lastSearchQuery = query;
        state.lastSearchScope = _extractSearchScopeFromToolCall(m.group(0)!);
        state.actionLog.add('🔍 搜尋「$query」');
      }
    }
    out = out.replaceAllMapped(
      _toolCallsRe,
      (m) => _extractSearchQueryFromToolCall(m.group(0)!) != null
          ? ''
          : m.group(0)!,
    );

    return out.trim();
  }

  static String? _extractSearchQueryFromToolCall(String block) {
    final lower = block.toLowerCase();
    if (!RegExp(
      r'''name\s*=\s*["']search_chat["']''',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return null;
    }

    final parameterMatch = RegExp(
      r'''<parameter\s+name\s*=\s*["']keyword["']\s*>([\s\S]*?)</parameter>''',
      caseSensitive: false,
    ).firstMatch(block);
    if (parameterMatch != null) {
      final query = parameterMatch.group(1)!.trim();
      if (query.isNotEmpty) return query;
    }

    final jsonMatch = RegExp(
      r'''["']keyword["']\s*:\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(block);
    if (jsonMatch != null) {
      final query = jsonMatch.group(1)!.trim();
      if (query.isNotEmpty) return query;
    }

    final anyParam = RegExp(
      r'<parameter[^>]*>([\s\S]*?)</parameter>',
      caseSensitive: false,
    ).firstMatch(block);
    final query = anyParam?.group(1)?.trim();
    return query == null || query.isEmpty ? null : query;
  }

  static String _extractSearchScopeFromToolCall(String block) {
    final match = RegExp(
      r'''(?:<parameter\s+name\s*=\s*["']scope["']\s*>\s*|["']scope["']\s*:\s*["'])(current|daily|rp|all)''',
      caseSensitive: false,
    ).firstMatch(block);
    return match?.group(1)?.toLowerCase() ?? 'current';
  }

  /// 解析 "[類別] 內容 @觸發詞" → [category, content, triggers]
  static String _canonicalCategory(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'long-term emotion' ||
      'long term emotion' ||
      'emotion' ||
      '长期情绪' ||
      '情绪' ||
      '長期情緒' ||
      '情緒' => '重要事件',
      'preference' => '偏好',
      'promise' || '约定' => '約定',
      'important event' || '重要事件' => '重要事件',
      'self-disclosure' || 'self disclosure' || '自我揭露' => '自我揭露',
      _ => raw.trim(),
    };
  }

  static List<String>? _parseEntry(String raw) {
    var category = '重要事件';
    var content = raw;
    final match = RegExp(r'^\[(.+?)\]\s*([\s\S]+)$').firstMatch(raw);
    if (match != null) {
      category = _canonicalCategory(match.group(1)!);
      content = match.group(2)!.trim();
    }
    var triggers = '';
    final atIdx = content.lastIndexOf('@');
    if (atIdx > 0) {
      final tail = content.substring(atIdx + 1).trim();
      if (tail.length <= 40 && !tail.contains('。') && !tail.contains('.')) {
        triggers = tail;
        content = content.substring(0, atIdx).trim();
      }
    }
    if (content.isEmpty) return null;
    return [category, content, triggers];
  }

  static void _captureSearchQuery(String text, _MemoryActionState state) {
    if (state.lastSearchQuery != null) return;

    final tagMatch = _searchRe.firstMatch(text);
    final tagQuery = tagMatch?.group(2)?.trim();
    if (tagQuery != null && tagQuery.isNotEmpty) {
      state.lastSearchQuery = tagQuery;
      state.lastSearchScope = tagMatch?.group(1)?.trim() ?? 'current';
      state.actionLog.add('🔍 搜尋「$tagQuery」');
      return;
    }

    for (final match in _toolCallsRe.allMatches(text)) {
      final query = _extractSearchQueryFromToolCall(match.group(0)!);
      if (query != null && query.isNotEmpty) {
        state.lastSearchQuery = query;
        state.lastSearchScope = _extractSearchScopeFromToolCall(
          match.group(0)!,
        );
        state.actionLog.add('🔍 搜尋「$query」');
        return;
      }
    }
  }
}

class _MemoryActionState {
  int? lastInsertedMemoryId;
  final List<String> actionLog = [];
  final List<String> proposalIds = [];
  final List<int> selfNoteIds = [];
  String? lastSearchQuery;
  String lastSearchScope = 'current';
}
