import 'dart:async';
import 'dart:developer' as developer;

import '../memory/database.dart';
import '../models/memory.dart';
import 'character_timeline_service.dart';
import 'locale_strings.dart';
import 'memory_curation_service.dart';
import 'settings/memory_settings.dart';

/// 做夢整理：對話累積後自動梳理記憶。
///
/// 觸發條件：開關開啟 ＋ 自上次做夢以來新增的 active 記憶數 ≥ 門檻。
/// 執行內容：用 BM25 為新記憶組出語義相關的批次，交給
/// [MemoryCurationService] 做關聯發現、重複檢測、衝突標記。
///
/// 模型跟隨摘要模型設定，不另開選項。
class DreamCurationService {
  static bool _running = false;

  /// 做夢專用 prompt：在原始整理規則之上，額外要求模型輸出一句夢境摘要。
  static const String _dreamSystemPrompt = '''
You organize an existing long-term memory graph. Analyze only the supplied memories.
Return strict JSON and no prose:
{"dream_summary":"One sentence describing what the character dreamed about in this batch, written in output_language.","relations":[{"main_id":1,"related_id":2,"score":0.97,"type":"duplicate_candidate","reason":"same promise and date","merge":{"category":"Important Event","content":"[7/24] One complete, coherent memory.","triggers":["promise"]}}]}

Rules:
- Link only memories that clearly describe the same event, entity, preference, promise, or continuing fact.
- type must be related, same_event, temporal, duplicate_candidate, or conflict_update.
- Use duplicate_candidate only when the core fact is effectively repeated.
- Use conflict_update when a number, date, negation, promise, or state has changed.
- Every human-readable string in reason, merge, and dream_summary must use output_language.
- score must be 0..1. Omit anything below 0.92.
- main_id is the broader or more durable memory; related_id is the narrower memory.
- A memory may connect to multiple other memories. Return every qualifying pair; never limit a memory to one relation.
- For duplicate_candidate, merge is required. Its content must be one coherent long-term memory that preserves all compatible facts, not two source texts joined together.
- A merge content may contain at most one bracketed record date such as [7/24], placed at the beginning. If the sources share that date, write it only once.
- Never invent a fact or an id. Only return a reviewable merge preview; never claim that a memory was changed or deleted.
- If there is no strong relation, return {"dream_summary":"...","relations":[]}.
- dream_summary: Summarize what these memories are about in one natural sentence (≤30 characters). This is a label for the dream session, not a literary description.
''';

  /// 回覆完成後呼叫。判斷是否滿足觸發條件，滿足就跑一輪做夢整理。
  /// 用 [unawaited] 包在外面以免阻塞聊天主流程。
  static Future<void> maybeTrigger({
    required String characterId,
  }) async {
    if (_running) return;

    final enabled = await MemorySettings.getDreamCurationEnabled();
    if (!enabled) return;

    final threshold = await MemorySettings.getDreamCurationThreshold();
    final lastCount = await MemorySettings.getDreamCurationLastCount();
    final currentCount = await _activeMemoryCount(characterId);

    final delta = currentCount - lastCount;
    if (delta < threshold) return;

    _running = true;
    try {
      developer.log(
        '做夢整理觸發：delta=$delta threshold=$threshold',
        name: 'DreamCuration',
      );

      final allMemories = await DatabaseHelper.getAllActiveMemories(
        characterId: characterId,
      );
      if (allMemories.length < 2) return;

      // ═══ BM25 組批：為每條新記憶搜相關舊記憶，組成語義相關的批次 ═══
      final newMemories = _selectNewMemories(allMemories, lastCount);
      final batches = await _buildSmartBatches(
        newMemories: newMemories,
        allMemories: allMemories,
        characterId: characterId,
      );

      if (batches.isEmpty) {
        // 沒有有效批次但已到門檻，更新計數避免每輪都重試
        await MemorySettings.saveDreamCurationLastCount(currentCount);
        return;
      }

      var totalProposed = 0;
      var totalCreated = 0;
      var totalDuplicates = 0;
      final dreamSummaries = <String>[];

      for (final batch in batches) {
        if (batch.length < 2) continue;
        final result = await MemoryCurationService.analyzeAndLink(
          characterId: characterId,
          memories: batch,
          systemPromptOverride: _dreamSystemPrompt,
        );
        totalProposed += result.proposedRelations;
        totalCreated += result.createdLinks;
        totalDuplicates += result.duplicateProposals;
        if (result.dreamSummary != null) {
          dreamSummaries.add(result.dreamSummary!);
        }
      }

      await MemorySettings.saveDreamCurationLastCount(currentCount);

      // ═══ 寫入 timeline ═══
      if (dreamSummaries.isNotEmpty) {
        final summary = dreamSummaries.length == 1
            ? dreamSummaries.first
            : dreamSummaries.join('；');
        final label = L.pick(en: '🌙 Dream: ', zhTW: '🌙 做夢：');
        await CharacterTimelineService.addEvent(
          characterId,
          '$label$summary',
        );
        developer.log(
          '做夢摘要寫入 timeline: $summary',
          name: 'DreamCuration',
        );
      }

      developer.log(
        '做夢整理完成：${batches.length} 批次, '
        '$totalProposed 關聯, $totalCreated 連線, '
        '$totalDuplicates 重複提案',
        name: 'DreamCuration',
      );
    } catch (e) {
      developer.log('做夢整理失敗', error: e, name: 'DreamCuration');
    } finally {
      _running = false;
    }
  }

  /// 取當前角色的 active 記憶數（跨 mode）。
  static Future<int> _activeMemoryCount(String characterId) async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS cnt FROM memories "
      "WHERE status = 'active' AND character_id = ?",
      [characterId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 從全量記憶中挑出「上次做夢之後新增的」——按 id 降序排列，
  /// 取 (currentCount - lastCount) 條最新的。
  static List<Memory> _selectNewMemories(
    List<Memory> allSorted,
    int lastCount,
  ) {
    // allSorted 已按 created_at DESC，取前 delta 條就是新記憶
    final delta = allSorted.length - lastCount;
    if (delta <= 0) return const [];
    return allSorted.sublist(0, delta.clamp(0, allSorted.length));
  }

  /// 用 BM25 為新記憶組批：每條新記憶搜出相關舊記憶，湊成一個語義相關的批次。
  /// 同一條舊記憶可能被多條新記憶命中——去重後放入同一批次。
  static Future<List<List<Memory>>> _buildSmartBatches({
    required List<Memory> newMemories,
    required List<Memory> allMemories,
    required String characterId,
  }) async {
    if (newMemories.isEmpty) return const [];

    final newIds = <int>{for (final m in newMemories) if (m.id != null) m.id!};
    final allById = <int, Memory>{
      for (final m in allMemories) if (m.id != null) m.id!: m,
    };

    // 按 mode 分組——不同 mode 的記憶不該混在一個批次裡比對
    final byMode = <String, List<Memory>>{};
    for (final m in newMemories) {
      byMode.putIfAbsent(m.mode, () => []).add(m);
    }

    final batches = <List<Memory>>[];

    for (final entry in byMode.entries) {
      final mode = entry.key;
      final modeNewMemories = entry.value;

      // 收集這個 mode 下所有需要放入批次的記憶 id
      final batchIds = <int>{};
      for (final m in modeNewMemories) {
        if (m.id != null) batchIds.add(m.id!);
      }

      // 每條新記憶用 BM25 搜相關舊記憶
      for (final m in modeNewMemories) {
        final query = '${m.content} ${m.triggers}'.trim();
        if (query.isEmpty) continue;
        try {
          final related = await DatabaseHelper.searchMemoriesByText(
            query,
            mode: mode,
            characterId: characterId,
            limit: 8,
          );
          for (final r in related) {
            if (r.id != null && !newIds.contains(r.id)) {
              batchIds.add(r.id!);
            }
          }
        } catch (_) {
          // FTS5 不可用——靜默跳過，只用新記憶組批
        }
      }

      // 把收集到的 id 轉成 Memory 列表
      final batchMemories = <Memory>[
        for (final id in batchIds)
          if (allById.containsKey(id)) allById[id]!,
      ];

      // 再按 MemoryCurationService 的 token 預算切分
      final subBatches = MemoryCurationService.buildAnalysisBatches(
        batchMemories,
      );
      batches.addAll(subBatches);
    }

    return batches;
  }
}
