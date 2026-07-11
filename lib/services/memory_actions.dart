import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import '../memory/retriever.dart';
import '../memory/spider_web_core.dart';
import '../models/memory.dart';
import 'locale_strings.dart';

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

  static String? lastSearchQueryFor(String windowId) =>
      _statesByWindow[windowId]?.lastSearchQuery;

  static void clearSearchQuery(String windowId) {
    _statesByWindow[windowId]?.lastSearchQuery = null;
  }

  static void releaseWindow(String windowId) {
    _statesByWindow.remove(windowId);
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
    r'<search_chat>([\s\S]*?)</search_chat>',
    multiLine: true,
  );
  static final _toolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*?</tool_calls?>',
    multiLine: true,
    caseSensitive: false,
  );

  /// 記憶寫入關閉時只剝離標籤，不執行任何落庫/搜尋動作。
  static String stripReply(String text, {required String windowId}) {
    _resetState(windowId);
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
  }) {
    final name = userNickname.isNotEmpty
        ? userNickname
        : (L.locale == 'en' ? 'the other person' : '對方');
    final charName = characterName.isNotEmpty
        ? characterName
        : (L.locale == 'en' ? '[char name]' : '角色名');
    if (L.locale == 'en') {
      return '''■ Memory
  <memo>[Category] Content @trigger1,trigger2</memo>
  Categories: Emotion | Preference | Promise | Important Event
  Preference: Only record truly meaningful preferences.
  Write in third person: use your character name and "$name". Example: "$name kissed $charName yesterday".
  Max 2 triggers, pick the most relevant words.
  Max 2 entries per reply. Only record what's truly worth keeping long-term.

  <memo_del>id</memo_del>  Delete outdated/wrong memories (comma-separated, recoverable)
  <memo_merge>id,id|[Category] new content @triggers</memo_merge>  Merge duplicates into one
  Only delete/merge what you're sure about. Injected memories carry ids like [#12·Promise] — never mention ids in conversation, refer to content directly.

  <persona_note>one sentence</persona_note>
  Use when you form a new lasting understanding of yourself, your speech patterns, or how you interact with $name. You must record this inner monologue or character profile update.

  <search_chat>keyword</search_chat>
  Internal retrieval for past conversations. Use when you vaguely remember something but need exact context. The system will provide hidden results; never mention searching, records, keywords, or tools to $name. Max 1 per reply.''';
    }
    return L.pick(
      en: '',
      zhTW:
          '''■ 記憶
  <memo>[類別] 內容 @觸發詞1,觸發詞2</memo>
  類別：情緒｜偏好｜約定｜重要事件
  偏好：只記真正有意義的偏好。
  建議用第三人稱記錄，如「$name昨天親了$charName」。
  觸發詞最多 2 個，選關聯性最高的詞。
  一次至多 2 條。只記你認為真正值得長久保留的。

  <memo_del>id</memo_del>  刪除過時記憶（逗號分隔多個，可恢復）
  <memo_merge>id,id|[類別] 新內容 @觸發詞</memo_merge>  合併重複記憶為一條
  系統帶入的記憶編號如 [#12·約定]，這些是給你看的提示，回覆時自然地聊內容就好。

  <persona_note>一句話</persona_note>
  當你對自己有新的認知，或是對$name有新的感覺時，可以記下來作為內心獨白。最多可記十二條，新進舊出。

  <search_chat>關鍵詞</search_chat>
  回想過去聊天內容時使用。一次最多 1 個。''',
    );
  }

  /// 處理模型回覆：執行標籤動作，返回剝離後的正文
  static Future<String> processReply(
    String text, {
    required String characterId,
    required String mode,
    required String windowId,
  }) async {
    final state = _resetState(windowId);
    if (!text.contains('<memo') &&
        !text.contains('<persona_note>') &&
        !text.contains('<search_chat>') &&
        !text.toLowerCase().contains('<tool_call')) {
      return text;
    }
    var out = text;

    // memo → 入庫
    int memoCount = 0;
    for (final m in _memoRe.allMatches(text)) {
      if (memoCount >= 4) break; // 防失控
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

      final points = await EmotionCoordinates.activePoints(characterId);
      int? emoX, emoY, emoRes;
      if (points.isNotEmpty) {
        final latest = points.first;
        emoX = latest.x.round();
        emoY = latest.y.round();
        emoRes = latest.concentration.round();
      }

      final newId = await DatabaseHelper.insertMemory(
        Memory(
          characterId: characterId,
          mode: mode,
          category: parsed[0],
          content: finalContent,
          confidence: 'high',
          triggers: parsed[2],
          emotionX: emoX,
          emotionY: emoY,
          emotionResonance: emoRes,
        ),
      );
      state.lastInsertedMemoryId ??= newId;
      state.actionLog.add('✚ 寫入 #$newId [${parsed[0]}] ${_clip(parsed[1])}');
      memoCount++;
    }
    int memoStripCount = 0;
    out = out.replaceAllMapped(
      _memoRe,
      (m) => memoStripCount++ < memoCount ? '' : m.group(0)!,
    );

    // persona_note → 角色自我註記
    int noteCount = 0;
    for (final m in _noteRe.allMatches(text)) {
      if (noteCount >= 2) break;
      final note = m.group(1)!.trim();
      if (note.isEmpty) continue;
      await DatabaseHelper.appendSelfNote(characterId, note);
      state.actionLog.add('✎ 自我註記 ${_clip(note)}');
      noteCount++;
    }
    int noteStripCount = 0;
    out = out.replaceAllMapped(
      _noteRe,
      (m) => noteStripCount++ < noteCount ? '' : m.group(0)!,
    );

    // memo_del → 歸檔（可恢復，模型誤刪不致命）
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
          .take(6);
      for (final id in ids) {
        await DatabaseHelper.archiveMemory(
          id,
          '模型刪除',
          characterId: characterId,
        );
        state.actionLog.add('🗑 刪除記憶（入回收區）');
      }
      delCount++;
    }
    int delStripCount = 0;
    out = out.replaceAllMapped(
      _delRe,
      (m) => delStripCount++ < delCount ? '' : m.group(0)!,
    );

    // memo_merge → 原條歸檔 + 合併條入庫
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
      final newId = await DatabaseHelper.insertMemory(
        Memory(
          characterId: characterId,
          mode: mode,
          category: parsed[0],
          content: parsed[1],
          confidence: 'high',
          triggers: parsed[2],
        ),
      );
      // 蛛網連線遷移：舊條的邊重指到合併後新條，合併不再剪網
      await SpiderWebCore.remapLinksAfterMerge(
        ids,
        newId,
        characterId: characterId,
      );
      for (final id in ids) {
        await DatabaseHelper.archiveMemory(
          id,
          '模型合併',
          characterId: characterId,
        );
      }
      state.actionLog.add(
        '⇄ 合併 ${ids.map((i) => '#$i').join(',')} → ${_clip(parsed[1])}',
      );
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
      final query = searchMatch.group(1)!.trim();
      if (query.isNotEmpty && state.lastSearchQuery == null) {
        // 只取第一個，防止模型一次發多個搜尋
        state.lastSearchQuery = query;
        state.actionLog.add('🔍 搜尋「$query」');
      }
      out = out.replaceFirst(_searchRe, '');
    }

    // DeepSeek / 部分 OpenAI-compatible 模型會把純文本標籤改寫成 tool_calls。
    for (final m in _toolCallsRe.allMatches(out)) {
      final query = _extractSearchQueryFromToolCall(m.group(0)!);
      if (query != null && query.isNotEmpty && state.lastSearchQuery == null) {
        state.lastSearchQuery = query;
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

  /// 解析 "[類別] 內容 @觸發詞" → [category, content, triggers]
  static String _canonicalCategory(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'emotion' || '情绪' => '情緒',
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
}

class _MemoryActionState {
  int? lastInsertedMemoryId;
  final List<String> actionLog = [];
  String? lastSearchQuery;
}
