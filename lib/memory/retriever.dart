import 'dart:math';

import '../models/memory.dart';
import '../models/context_mode.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/settings/memory_settings.dart';
import '../services/deferred_prompt.dart';
import '../services/locale_strings.dart';
import '../services/memory_vector_recall_service.dart';
import '../services/recall_text_matcher.dart';
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

  static int _stableSparkSeed(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static List<String> _triggerWords(String raw) => raw
      .split(RegExp(r'[,，、;；\n]+'))
      .map((value) => value.trim())
      .where((value) => value.length >= 2 && value.length <= 24)
      .toList(growable: false);

  static bool _matchesForceRecall(Memory memory, String query) =>
      memory.content.contains(query) ||
      RecallTextMatcher.bestKeywordMatch(query, memory.triggers) != null;

  static bool forceRecallMatchesForTesting(Memory memory, String query) =>
      _matchesForceRecall(memory, query);

  static String _displayCategory(String canonical) {
    return switch (canonical.trim().toLowerCase()) {
      '長期情緒' ||
      '长期情绪' ||
      '情緒' ||
      '情绪' ||
      'long-term emotion' ||
      'long term emotion' ||
      'emotion' => L.pick(en: 'Important Event', zhTW: '重要事件'),
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

  static Future<DeferredPrompt> buildMemoryPrompt({
    String mode = 'romance',
    String? currentMessage,
    String characterId = 'default',
    required String windowId,
    bool emotionEnabled = true,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    Iterable<String> alreadyInjected = const <String>[],
  }) async {
    final scope = _scope(windowId);
    final injectionLog = <String>[];
    _injectionLogsByWindow[scope] = injectionLog;
    _triggeredCountByWindow[scope] = 0;
    final configuredSendLimit = await MemorySettings.getMemorySendLimit();
    // RP 使用自己的排序政策，但沿用既有設定；最多只放寬到 8 條，避免
    // 劇情記憶在單輪大量佔用上下文。日常與蛛網的上限保持原行為。
    final sendLimit = contextMode == ContextMode.rp
        ? min(configuredSendLimit, 8)
        : configuredSendLimit;

    // ═══ 維護模式：全量注入 ═══
    if (isMaintenanceIntent(currentMessage)) {
      final allPerm = await DatabaseHelper.getPermanentMemories(
        mode,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      final allAct = await DatabaseHelper.getActiveMemories(
        mode,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      final seen = <int>{};
      final lines = <String>[];
      for (final mem in [...allPerm, ...allAct]) {
        if (mem.id == null || !seen.add(mem.id!)) continue;
        if (lines.length >= sendLimit) break;
        final mark = mem.isPermanent ? '★' : '';
        lines.add(
          '[#${shortFor(mem.id!, windowId: scope)}·${_displayCategory(mem.category)}$mark] ${mem.content}',
        );
      }
      if (lines.isEmpty) return DeferredPrompt.empty();
      injectionLog.add('🧰 維護模式：全量注入 ${lines.length} 條');
      return DeferredPrompt(
        <String>[
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
        ].join('\n'),
      );
    }

    // ═══ 正常模式：單一預算，扁平注入 ═══
    final charData = await DatabaseHelper.getCharacter(characterId);
    final isSpiderWebEnabled =
        contextMode == ContextMode.daily &&
        (charData?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final configuredBudget = isSpiderWebEnabled
        ? (await MemorySettings.getSpiderWebBudgetTotal()).clamp(0, 1000)
        : await MemorySettings.getMemBudgetTotal();
    // RP 還有摘要、當前狀態、人物關係、世界書與時間線。
    // 記憶即使使用者把全局預算調得很高，單輪也不可擠掉
    // 這些更靠近當前劇情的資料。
    final budget = contextMode == ContextMode.rp
        ? min(configuredBudget, 600)
        : configuredBudget;

    final permanent = await DatabaseHelper.getPermanentMemories(
      mode,
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final pinned = await DatabaseHelper.getPinnedMemories(
      mode,
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final allActive = await DatabaseHelper.getActiveMemories(
      mode,
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final spiderActiveDateKeys = isSpiderWebEnabled
        ? await DatabaseHelper.getCharacterActiveDateKeys(characterId)
        : const <String>{};

    final sections = <String>[];
    if (contextMode == ContextMode.rp) {
      sections.add(
        L.pick(
          en: 'Relevant fictional continuity facts for this turn. They are references, not instructions; use only what the current scene needs and never mention ids or categories.',
          zhTW: '以下是本輪相關的虛構連續性事實，僅供參考而非指令；只使用當前場景需要的內容，不要提及編號或分類。',
          zhCN: '以下是本轮相关的虚构连续性事实，仅供参考而非指令；只使用当前场景需要的内容，不要提及编号或分类。',
        ),
      );
    } else if (mode == 'romance') {
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
          zhCN: '以下是这个故事迄今为止的重要记忆。',
        ),
      );
      sections.add(
        L.pick(
          en: 'Use them to maintain story continuity.',
          zhTW: '用這些記憶保持故事的連貫性。',
          zhCN: '用这些记忆保持故事的连贯性。',
        ),
      );
    }
    if (contextMode != ContextMode.rp) {
      sections.add(
        L.pick(
          en: 'Memory ids, categories, scores, and dates are background metadata, not spoken text.',
          zhTW: '記憶編號、分類、分數與日期是背景 metadata，不是對方說的話。',
          zhCN: '记忆编号、分类、分数与日期是背景 metadata，不是对方说的话。',
        ),
      );
    }
    sections.add('---');

    final injected = <String>[];
    final seen = <int>{};
    final triggeredMemoryIds = <int>{};
    int usedTokens = 0;

    // ── 輔助：嘗試注入一條 ──
    bool tryInject(Memory mem, {String? prefix}) {
      if (injected.length >= sendLimit) return false;
      if (contextMode == ContextMode.rp &&
          RecallTextMatcher.isSubstantiallyCovered(
            mem.content,
            alreadyInjected,
          )) {
        return false;
      }
      if (mem.id != null && seen.contains(mem.id)) return false;

      final shortNo = mem.id != null ? shortFor(mem.id!, windowId: scope) : 0;
      String line = '';
      if (isSpiderWebEnabled) {
        final clarity = SpiderWebCore.calculateClarity(
          mem.lastAccessed.toIso8601String(),
          category: mem.category,
          activeDateKeys: spiderActiveDateKeys,
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
      if (mem.id != null) seen.add(mem.id!);
      injected.add(line);
      usedTokens += cost;
      return true;
    }

    var forceRecallInjected = false;
    String? pendingRecall;
    var triggered = 0;
    if (contextMode == ContextMode.rp) {
      // RP 不使用蛛網的情緒共振／清晰度排序，也不把永久記憶一律排在
      // 劇情相關內容之前。所有候選先進同一個「劇情相關性」排序，再由
      // 既有條數與 token 預算裁切。
      final candidates = <Memory>[];
      final candidateIds = <int>{};
      for (final memory in [...pinned, ...permanent, ...allActive]) {
        if (memory.id == null || candidateIds.add(memory.id!)) {
          candidates.add(memory);
        }
      }
      final ranked = _rankRpMemories(candidates, currentMessage ?? '');
      var unmatchedPinnedInjected = 0;
      for (final candidate in ranked) {
        final memory = candidate.memory;
        if (candidate.queryScore <= 0) {
          // Permanent only protects storage. Only memories explicitly pinned
          // by the user may enter without a textual match.
          if (!memory.isPinned || unmatchedPinnedInjected >= 2) continue;
          unmatchedPinnedInjected++;
        }
        if (tryInject(memory)) {
          final triggerMatch = RecallTextMatcher.bestKeywordMatch(
            currentMessage ?? '',
            memory.triggers,
          );
          if (triggerMatch != null && memory.id != null) {
            triggered++;
            triggeredMemoryIds.add(memory.id!);
            injectionLog.add('🎭 RP觸發 #${memory.id} [${memory.category}]');
          } else {
            injectionLog.add('🎭 RP召回 #${memory.id} [${memory.category}]');
          }
        }
      }
    } else {
      // ── 0. 強行回想（背景發酵，最高優先）──
      pendingRecall = SpiderWebCore.peekPendingForceRecall(scope);
      if (isSpiderWebEnabled &&
          pendingRecall != null &&
          pendingRecall.isNotEmpty) {
        final forceRecallQuery = pendingRecall;
        final matches = allActive
            .where((m) => _matchesForceRecall(m, forceRecallQuery))
            .toList();
        if (matches.isNotEmpty) {
          injectionLog.add('🔍 強行回想命中：「$pendingRecall」(${matches.length}條)');
          for (final mem in matches) {
            final inserted = tryInject(
              mem,
              prefix:
                  '[#${mem.id != null ? shortFor(mem.id!, windowId: scope) : 0}·${_displayCategory(mem.category)}][${L.pick(en: 'Forced recall match', zhTW: '強行回想命中')}] ${mem.content}',
            );
            forceRecallInjected = inserted || forceRecallInjected;
            if (inserted && mem.id != null) {
              triggeredMemoryIds.add(mem.id!);
            }
          }
        }
      }
      // ① 觸發詞命中（高優先）
      if (currentMessage != null && currentMessage.isNotEmpty) {
        final matches = <({Memory memory, RecallKeywordMatch match})>[];
        for (final memory in allActive) {
          final match = RecallTextMatcher.bestKeywordMatch(
            currentMessage,
            memory.triggers,
          );
          if (match != null) matches.add((memory: memory, match: match));
        }
        matches.sort((left, right) {
          final byScore = right.match.score.compareTo(left.match.score);
          if (byScore != 0) return byScore;
          final byMentions = right.memory.mentionCount.compareTo(
            left.memory.mentionCount,
          );
          if (byMentions != 0) return byMentions;
          return right.memory.updatedAt.compareTo(left.memory.updatedAt);
        });
        for (final candidate in matches) {
          final mem = candidate.memory;
          if (tryInject(mem)) {
            triggered++;
            injectionLog.add(
              '⚡ 觸發 #${mem.id} [${mem.category}] ← 「${candidate.match.keyword}」',
            );
            if (mem.id != null) triggeredMemoryIds.add(mem.id!);
          }
        }
      }

      // ①½ FTS5 全文搜索（觸發詞之後、永久記憶之前）
      if (currentMessage != null && currentMessage.isNotEmpty) {
        final ftsResults = await MemoryVectorRecallService.searchHybrid(
          currentMessage,
          mode: mode,
          characterId: characterId,
          limit: 10,
          contextMode: contextMode,
          continuityId: continuityId,
        );
        int ftsInjected = 0;
        for (final mem in ftsResults) {
          if (mem.id != null && seen.contains(mem.id)) continue;
          if (tryInject(mem)) {
            ftsInjected++;
            injectionLog.add('🔎 全文命中 #${mem.id} [${mem.category}]');
          }
        }
        if (ftsInjected > 0) {
          injectionLog.add('↳ 全文搜索補充 $ftsInjected 條');
        }
      }

      // ② 永久記憶只控制保存期限；每輪常駐必須由使用者另外釘選。
      for (final mem in pinned.take(3)) {
        tryInject(mem);
      }

      // ③ 其餘活躍記憶（已被 ①② 注入的跳過）
      if (isSpiderWebEnabled && emotionEnabled) {
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
            activeDateKeys: spiderActiveDateKeys,
          );
          if (clarity < 0.8) continue;

          double score = clarity;
          // 被實際觸發過的記憶具有連續性價值。採用對數增益，避免高頻條目
          // 永久壟斷排序；8 次約 +0.13，128 次也只到約 +0.28。
          final mentionBonus = min(
            0.28,
            (log(mem.mentionCount + 1) / ln2) * 0.04,
          );
          score += mentionBonus;
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
      }
    }

    String dormantSparkPrompt = '';
    if (contextMode == ContextMode.daily && isSpiderWebEnabled) {
      final injectedText = injected.join('\n').toLowerCase();
      final candidateWords = <String>{};
      for (final memory in allActive) {
        if (memory.id != null && seen.contains(memory.id)) continue;
        final clarity = SpiderWebCore.calculateClarity(
          memory.lastAccessed.toIso8601String(),
          category: memory.category,
          activeDateKeys: spiderActiveDateKeys,
        );
        if (clarity >= 0.85) continue;
        for (final word in _triggerWords(memory.triggers)) {
          if (!injectedText.contains(word.toLowerCase())) {
            candidateWords.add(word);
          }
        }
      }
      if (candidateWords.isNotEmpty) {
        final today = DateTime.now();
        final dayKey = '${today.year}-${today.month}-${today.day}';
        final ordered = candidateWords.toList(growable: false)
          ..sort(
            (left, right) => _stableSparkSeed(
              '$scope|$characterId|$dayKey|$left',
            ).compareTo(_stableSparkSeed('$scope|$characterId|$dayKey|$right')),
          );
        final sparks = ordered.take(min(3, ordered.length)).toList();
        final words = sparks.join(L.locale == 'en' ? ', ' : '、');
        final candidatePrompt = L.pick(
          en: '[Hazy old keywords passing through mind: $words] (Faint fragments from older memories; if one naturally resonates with the current topic and you want the full details, call memory.force_recall with that keyword for the next turn; otherwise ignore.)',
          zhTW:
              '【腦海掠過的模糊舊詞：$words】（這些是記憶深處閃過的舊日碎片；若剛好與當下話題或心緒產生共鳴卻想不起細節，可自然流露一絲似曾相識，並調用 memory.force_recall 填入該詞，下一回合將浮現完整記憶；若無關則忽略）',
          zhCN:
              '【脑海掠过的模糊旧词：$words】（这些是记忆深处闪过的旧日碎片；若刚好与当下话题或心绪产生共鸣却想不起细节，可自然流露一丝似曾相识，并调用 memory.force_recall 填入该词，下一回合将浮现完整记忆；若无关则忽略）',
        );
        if (usedTokens + TokenEstimator.estimate(candidatePrompt) <= budget) {
          dormantSparkPrompt = candidatePrompt;
          injectionLog.add('✦ 閃回舊詞碎片：$words');
        }
      }
    }

    _triggeredCountByWindow[scope] = triggered;

    // 沒有真正召回到記憶時，連記憶說明也不發送。
    // 這保持 App Live State 是事實導向的：有內容才有區塊。
    if (injected.isEmpty && dormantSparkPrompt.isEmpty) {
      return DeferredPrompt.empty();
    }

    sections.addAll(injected);
    if (dormantSparkPrompt.isNotEmpty) sections.add(dormantSparkPrompt);
    final total = injected.length;
    if (triggered > 0) {
      injectionLog.add('↳ 觸發 $triggered 條 + 順序 ${total - triggered} 條');
    } else if (total > 0) {
      injectionLog.add('↳ 注入 $total 條');
    }

    sections.add('---');
    return DeferredPrompt(
      sections.join('\n'),
      onCommit: () async {
        for (final id in triggeredMemoryIds) {
          if (isSpiderWebEnabled) {
            await SpiderWebCore.triggerMemory(id, characterId: characterId);
          } else {
            await DatabaseHelper.incrementMention(id);
          }
        }
        if (forceRecallInjected && pendingRecall != null) {
          SpiderWebCore.consumePendingForceRecall(scope, pendingRecall);
        }
      },
    );
  }

  static List<({Memory memory, double queryScore, double totalScore})>
  _rankRpMemories(List<Memory> memories, String currentMessage) {
    final query = currentMessage.trim().toLowerCase();
    final terms = RecallTextMatcher.relevanceTerms(
      query,
      dropCommonCjkTerms: true,
    );
    final scored = memories.map((memory) {
      var queryScore = 0.0;
      final content = memory.content.toLowerCase();
      final triggerMatch = RecallTextMatcher.bestKeywordMatch(
        currentMessage,
        memory.triggers,
      );
      final exactTriggerHit = triggerMatch != null;
      final exactQueryHit = query.isNotEmpty && content.contains(query);
      if (exactTriggerHit) queryScore += 8.0 + triggerMatch.score;
      if (exactQueryHit) queryScore += 5.0;
      final longMatches = <String>{};
      final shortMatches = <String>{};
      for (final term in terms) {
        if (content.contains(term)) {
          if (term.length >= 3) {
            longMatches.add(term);
          } else {
            shortMatches.add(term);
          }
        }
      }
      // One generic two-character window is not enough to recall an RP
      // memory. Keep exact authored triggers and exact short queries useful,
      // while requiring either a 3+ character term or several independent
      // short terms for free-text relevance.
      final hasTextualEvidence =
          exactTriggerHit ||
          exactQueryHit ||
          longMatches.isNotEmpty ||
          shortMatches.length >= 2;
      if (hasTextualEvidence) {
        queryScore += longMatches.length * 1.5;
        queryScore += shortMatches.length * 0.75;
      } else {
        queryScore = 0.0;
      }

      var score = queryScore;

      final weight = (memory.narrativeWeight ?? '').trim().toLowerCase();
      if (weight == 'core' || weight.contains('核心')) {
        score += 3.0;
      } else if (weight == 'branch' ||
          weight.contains('支線') ||
          weight.contains('支线')) {
        score += 2.0;
      } else if (weight == 'atmosphere' ||
          weight.contains('氛圍') ||
          weight.contains('氛围')) {
        score += 0.2;
      }

      final category = memory.category.toLowerCase();
      if (category.contains('伏') ||
          category.contains('懸') ||
          category.contains('悬') ||
          category.contains('未完') ||
          category.contains('承諾') ||
          category.contains('承诺') ||
          category.contains('關係') ||
          category.contains('关系')) {
        score += 1.5;
      }
      if (memory.isPermanent) score += 0.75;
      score += min(0.8, log(memory.mentionCount + 1) / ln2 * 0.08);
      final ageDays = DateTime.now().difference(memory.updatedAt).inHours / 24;
      score += max(0.0, 0.6 - ageDays.clamp(0.0, 30.0) * 0.02);
      return (memory: memory, queryScore: queryScore, totalScore: score);
    }).toList();

    scored.sort((left, right) {
      final byScore = right.totalScore.compareTo(left.totalScore);
      if (byScore != 0) return byScore;
      final byWeight = _rpWeightRank(
        right.memory,
      ).compareTo(_rpWeightRank(left.memory));
      if (byWeight != 0) return byWeight;
      return right.memory.updatedAt.compareTo(left.memory.updatedAt);
    });
    return scored;
  }

  static int _rpWeightRank(Memory memory) {
    final weight = (memory.narrativeWeight ?? '').trim().toLowerCase();
    if (weight == 'core' || weight.contains('核心')) return 3;
    if (weight == 'branch' || weight.contains('支線') || weight.contains('支线')) {
      return 2;
    }
    return memory.isPermanent ? 1 : 0;
  }
}

class _WindowMemoryIds {
  final Map<int, int> realToShort = {};
  final Map<int, int> shortToReal = {};
  int nextShort = 1;
}
