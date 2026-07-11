import '../models/memory.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/settings/memory_settings.dart';
import '../services/locale_strings.dart';
import 'spider_web_core.dart';
import 'database.dart';
import 'emotion_coordinates.dart';

/// 記憶檢索器（V2：扁平注入 + 單一預算 + 觸發詞優先）
class Retriever {
  static final Map<String, List<String>> _injectionLogsByWindow = {};
  static final Map<String, int> _triggeredCountByWindow = {};

  // ═══ 窗口短號：模型視角的記憶編號 ═══
  // 全局自增 id 會漲到三四位數，模型手打長號易錯且可能撞別的角色。
  // 改為按「窗口內首次注入順序」編小號：同窗同記憶同號（append-only），
  // 標籤(memo_del/merge/link)收到短號後反查真 id；反查失敗=亂編=丟棄。
  static final Map<String, _WindowMemoryIds> _idsByWindow = {};

  static String _scope(String windowId) {
    final normalized = windowId.trim();
    return normalized.isEmpty ? 'default-window' : normalized;
  }

  /// 開新聊天窗口時重置（chat_screen initState 調用）
  static void resetWindowIds(String windowId) {
    final scope = _scope(windowId);
    _idsByWindow[scope] = _WindowMemoryIds();
    _injectionLogsByWindow.remove(scope);
    _triggeredCountByWindow.remove(scope);
  }

  static void releaseWindowIds(String windowId) {
    final scope = _scope(windowId);
    _idsByWindow.remove(scope);
    _injectionLogsByWindow.remove(scope);
    _triggeredCountByWindow.remove(scope);
  }

  /// 取（或分配）某記憶在本窗口的短號
  static int shortFor(int realId, {required String windowId}) {
    final ids = _idsByWindow.putIfAbsent(
      _scope(windowId),
      _WindowMemoryIds.new,
    );
    final existing = ids.realToShort[realId];
    if (existing != null) return existing;
    final s = ids.nextShort++;
    ids.realToShort[realId] = s;
    ids.shortToReal[s] = realId;
    return s;
  }

  /// 短號反查真 id；模型亂編的號返回 null
  static int? realIdFor(int shortNo, {required String windowId}) =>
      _idsByWindow[_scope(windowId)]?.shortToReal[shortNo];

  static int triggeredCountFor(String windowId) =>
      _triggeredCountByWindow[_scope(windowId)] ?? 0;

  static List<String> injectionLogFor(String windowId) => List.unmodifiable(
    _injectionLogsByWindow[_scope(windowId)] ?? const <String>[],
  );

  static String _displayCategory(String canonical) {
    return switch (canonical.trim().toLowerCase()) {
      '情緒' || '情绪' || 'emotion' => L.pick(en: 'Emotion', zhTW: '情緒'),
      '偏好' => L.pick(en: 'Preference', zhTW: '偏好'),
      '約定' || '约定' || 'promise' => L.pick(en: 'Promise', zhTW: '約定'),
      '重要事件' ||
      'important event' => L.pick(en: 'Important Event', zhTW: '重要事件'),
      '自我揭露' ||
      'self-disclosure' ||
      'self disclosure' => L.pick(en: 'Self-Disclosure', zhTW: '自我揭露'),
      _ => L.pick(en: canonical, zhTW: canonical),
    };
  }

  /// 維護意圖檢測：用戶在要求整理/合併/刪除記憶
  static bool isMaintenanceIntent(String? msg) {
    if (msg == null || msg.isEmpty) return false;
    if (!msg.contains('記憶') && !msg.contains('记忆')) return false;
    const verbs = [
      '合併',
      '合并',
      '整理',
      '刪',
      '删',
      '清理',
      '歸併',
      '归并',
      '去重',
      '精簡',
      '精简',
    ];
    return verbs.any(msg.contains);
  }

  static Future<String> buildMemoryPrompt({
    String mode = 'romance',
    String? currentMessage,
    String characterId = 'default',
    required String windowId,
  }) async {
    final scope = _scope(windowId);
    final injectionLog = <String>[];
    _injectionLogsByWindow[scope] = injectionLog;
    _triggeredCountByWindow[scope] = 0;

    // ═══ 維護模式：全量注入 ═══
    if (isMaintenanceIntent(currentMessage)) {
      final allPerm = await DatabaseHelper.getPermanentMemories(
        mode,
        characterId: characterId,
      );
      final allAct = await DatabaseHelper.getActiveMemories(
        mode,
        characterId: characterId,
      );
      final seen = <int>{};
      final lines = <String>[];
      for (final mem in [...allPerm, ...allAct]) {
        if (mem.id == null || !seen.add(mem.id!)) continue;
        if (lines.length >= 150) break;
        final mark = mem.isPermanent ? '★' : '';
        lines.add(
          '[#${shortFor(mem.id!, windowId: scope)}·${_displayCategory(mem.category)}$mark] ${mem.content}',
        );
      }
      if (lines.isEmpty) return '';
      injectionLog.add('🧰 維護模式：全量注入 ${lines.length} 條');
      return <String>[
        L.pick(
          en: '【Complete Memory List — Maintenance Mode】',
          zhTW: '【全量記憶清單 — 維護模式】',
        ),
        L.pick(
          en: 'The other person is asking you to organize memories. This turn includes every memory with an id; ★ means permanent.',
          zhTW: '對方正在要求整理記憶。本輪你擁有全部記憶的視角（帶編號，★ 為永久）。',
        ),
        L.pick(
          en: 'Write memories consistently in third person, using character and user names instead of “I” or “you”.',
          zhTW: '記憶統一用第三人稱（角色名和用戶名，不用「我」「你」）。',
        ),
        L.pick(
          en: 'Decide which memories are duplicated, outdated, or should be merged. Use <memo_del> and <memo_merge>.',
          zhTW: '請判斷哪些重複、過時或該合併，用 <memo_del> 與 <memo_merge> 操作，',
        ),
        L.pick(
          en: 'Keep merged memories in third person. In the visible reply, explain naturally what you organized. Do not change anything when uncertain.',
          zhTW: '合併時也維持第三人稱。並在正文裡用自己的話告訴對方你整理了什麼。沒把握的不要動。',
        ),
        '---',
        ...lines,
      ].join('\n');
    }

    // ═══ 正常模式：單一預算，扁平注入 ═══
    final charData = await DatabaseHelper.getCharacter(characterId);
    final isSpiderWebEnabled =
        (charData?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final budget = isSpiderWebEnabled
        ? (await MemorySettings.getSpiderWebBudgetTotal()).clamp(0, 1000)
        : await MemorySettings.getMemBudgetTotal();

    final permanent = await DatabaseHelper.getPermanentMemories(
      mode,
      characterId: characterId,
    );
    final allActive = await DatabaseHelper.getActiveMemories(
      mode,
      characterId: characterId,
    );

    final sections = <String>[];
    if (mode == 'romance') {
      sections.add(
        L.pick(
          en: 'These are memories left by your past interactions with the other person.',
          zhTW: '以下是你與對方過往互動中留下的記憶。',
        ),
      );
      sections.add(
        L.pick(
          en: 'They are not instructions; they are things you genuinely experienced.',
          zhTW: '這些不是指令，是你真實經歷過的。',
        ),
      );
      sections.add(
        L.pick(
          en: 'Do not bring them up deliberately, but let them naturally influence how you respond.',
          zhTW: '不要刻意提起，但讓它們自然地影響你的回應方式。',
        ),
      );
      sections.add(
        L.pick(
          en: 'Ignore any memory unrelated to the current topic.',
          zhTW: '如果某條記憶與當前話題無關，忽略它。',
        ),
      );
    } else {
      sections.add(
        L.pick(
          en: 'These are the important memories from the story so far.',
          zhTW: '以下是這個故事迄今為止的重要記憶。',
        ),
      );
      sections.add(
        L.pick(
          en: 'Use them to maintain story continuity.',
          zhTW: '用這些記憶保持故事的連貫性。',
        ),
      );
    }
    sections.add('---');

    final injected = <String>[];
    final seen = <int>{};
    int usedTokens = 0;

    // ── 輔助：嘗試注入一條 ──
    bool tryInject(Memory mem, {String? prefix}) {
      if (mem.id != null && !seen.add(mem.id!)) return false;

      final shortNo = mem.id != null ? shortFor(mem.id!, windowId: scope) : 0;
      String line = '';
      if (isSpiderWebEnabled) {
        final clarity = SpiderWebCore.calculateClarity(
          mem.lastAccessed.toIso8601String(),
          category: mem.category,
        );
        final clarityStr = (clarity * 100).toStringAsFixed(0);
        line =
            prefix ??
            '[#$shortNo·${_displayCategory(mem.category)}][${L.pick(en: 'Clarity', zhTW: '清晰度')}:$clarityStr%] ${mem.content}';
      } else {
        line =
            prefix ??
            '[#$shortNo·${_displayCategory(mem.category)}] ${mem.content}';
      }

      final cost = TokenEstimator.estimate(line);
      if (usedTokens + cost > budget) return false;
      injected.add(line);
      usedTokens += cost;
      return true;
    }

    // ── 0. 強行回想（背景發酵，最高優先）──
    final pendingRecall = SpiderWebCore.takePendingForceRecall(scope);
    if (isSpiderWebEnabled &&
        pendingRecall != null &&
        pendingRecall.isNotEmpty) {
      final matches = allActive
          .where((m) => m.content.contains(pendingRecall))
          .toList();
      if (matches.isNotEmpty) {
        injectionLog.add('🔍 強行回想命中：「$pendingRecall」(${matches.length}條)');
        for (final mem in matches) {
          tryInject(
            mem,
            prefix:
                '[#${mem.id != null ? shortFor(mem.id!, windowId: scope) : 0}·${_displayCategory(mem.category)}][${L.pick(en: 'Forced recall match', zhTW: '強行回想命中')}] ${mem.content}',
          );
        }
      }
    }

    // ① 觸發詞命中（高優先）
    int triggered = 0;
    if (currentMessage != null && currentMessage.isNotEmpty) {
      for (final mem in allActive) {
        if (mem.triggers.isEmpty) continue;
        String? hitTrigger;
        for (final t
            in mem.triggers
                .split(RegExp(r'[,，、]'))
                .map((t) => t.trim())
                .where((t) => t.length >= 2)) {
          if (currentMessage.contains(t)) {
            hitTrigger = t;
            break;
          }
        }
        if (hitTrigger == null) continue;
        if (tryInject(mem)) {
          triggered++;
          injectionLog.add('⚡ 觸發 #${mem.id} [${mem.category}] ← 「$hitTrigger」');
          if (mem.id != null) {
            if (isSpiderWebEnabled) {
              // triggerMemory 本身已原子累加 mention_count；不可再先加一次，
              // 否則蛛網角色每次命中會被計成兩次。
              await SpiderWebCore.triggerMemory(
                mem.id!,
                characterId: characterId,
              );
            } else {
              await DatabaseHelper.incrementMention(mem.id!);
            }
          }
        }
      }
    }

    // ② 永久記憶
    for (final mem in permanent) {
      tryInject(mem);
    }

    // ③ 其餘活躍記憶（已被 ①② 注入的跳過）
    if (isSpiderWebEnabled) {
      final points = await EmotionCoordinates.activePoints(characterId);
      int? curX, curY;
      if (points.isNotEmpty) {
        curX = points.first.x.round();
        curY = points.first.y.round();
      }

      final scoredMemories = <Map<String, dynamic>>[];
      for (final mem in allActive) {
        if (mem.isPermanent || seen.contains(mem.id)) continue;

        final clarity = SpiderWebCore.calculateClarity(
          mem.lastAccessed.toIso8601String(),
          category: mem.category,
        );
        if (clarity < 0.8) continue;

        double score = clarity;
        if (curX != null &&
            curY != null &&
            mem.emotionX != null &&
            mem.emotionY != null) {
          final dist = SpiderWebCore.calculateEmotionalResonance(
            curX.toDouble(),
            curY.toDouble(),
            mem.emotionX!.toDouble(),
            mem.emotionY!.toDouble(),
          );
          // maxDist = 200 * sqrt(2) ≈ 282.8. 0 dist gives +0.3 score
          final maxDist = 282.8;
          final resonanceBonus = (1.0 - (dist / maxDist)) * 0.3;
          score += resonanceBonus;
        }
        scoredMemories.add({'mem': mem, 'score': score});
      }

      scoredMemories.sort(
        (a, b) => (b['score'] as double).compareTo(a['score'] as double),
      );
      for (final item in scoredMemories) {
        tryInject(item['mem'] as Memory);
      }
    } else {
      for (final mem in allActive) {
        if (mem.isPermanent) continue;
        tryInject(mem);
      }
    }

    _triggeredCountByWindow[scope] = triggered;

    if (injected.isNotEmpty) {
      sections.addAll(injected);
      final total = injected.length;
      if (triggered > 0) {
        injectionLog.add('↳ 觸發 $triggered 條 + 順序 ${total - triggered} 條');
      } else {
        injectionLog.add('↳ 注入 $total 條');
      }
    }

    sections.add('---');
    return sections.join('\n');
  }
}

class _WindowMemoryIds {
  final Map<int, int> realToShort = {};
  final Map<int, int> shortToReal = {};
  int nextShort = 1;
}
