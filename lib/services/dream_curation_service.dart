import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/memory.dart';
import 'locale_strings.dart';
import 'memory_curation_service.dart';
import 'memory_vector_recall_service.dart';
import 'settings/memory_settings.dart';

/// 做夢整理：對話累積後自動梳理記憶。
///
/// 觸發條件：開關開啟 ＋ 自上次做夢以來新增的 active 記憶數 ≥ 門檻。
/// 執行內容：用全文／向量混合召回為新記憶組出相關批次，交給
/// [MemoryCurationService] 做關聯發現、重複檢測、衝突標記。
///
/// 模型跟隨摘要模型設定，不另開選項。
class DreamCurationService {
  static bool _running = false;

  static const String _dreamSystemPromptEn = '''
You organize an existing long-term memory graph. Analyze only the supplied memories.
Return strict JSON and no prose:
{"dream_summary":"One sentence describing what the character dreamed about in this batch, written in output_language.","relations":[{"main_id":1,"related_id":2,"score":0.97,"type":"duplicate_candidate","reason":"same promise and date","merge":{"category":"Important Event","content":"[7/24] One complete, coherent memory.","triggers":["promise"]}}]}

Rules:
- Link only memories that clearly describe the same event, entity, preference, promise, or continuing fact.
- type must be related, same_event, temporal, duplicate_candidate, or conflict_update.
- related: compatible but independent facts about the same entity or topic.
- same_event: different memories describing the same concrete event.
- temporal: memories in the same thread with an explicit before/after or continuation relationship.
- duplicate_candidate: the same core fact is effectively repeated; a merge preview is required.
- conflict_update: the same fact changed or conflicts in number, date, negation, promise, or state.
- Every human-readable string in reason, merge, and dream_summary must use output_language.
- score must be 0..1. Omit anything below 0.92.
- main_id is the broader or more durable memory; related_id is the narrower memory.
- A memory may connect to multiple other memories. Return every qualifying pair; never limit a memory to one relation.
- For duplicate_candidate, merge is required. Its content must be one coherent long-term memory that preserves all compatible facts, not two source texts joined together.
- A merge content may contain at most one bracketed record date such as [7/24], placed at the beginning. If the sources share that date, write it only once.
- The merged memory must contain only the memory itself. Never append process notes such as "duplicate memories merged".
- Never invent a fact or an id. Only return a reviewable merge preview; never claim that a memory was changed or deleted.
- existing_links and existing_link_memories describe stored relations touching this batch. Do not return an unchanged confirmed relation or add a redundant transitive edge. Independently reassess suggested relations.
- user_rejected_pairs are explicit user decisions. Never propose those pairs again.
- Vector candidates are hints only. Independently judge the relationship from the supplied memories and evidence.
- Do not create a generic related edge merely because two memories share a broad category.
- If there is no strong relation, return {"dream_summary":"...","relations":[]}.
- dream_summary: Summarize what these memories are about in one natural sentence (≤120 English characters). This is a session label, not a literary description.
''';

  static const String _dreamSystemPromptZhTw = '''
你負責整理既有的長期記憶關聯圖。只分析本次提供的記憶。
只輸出合法 JSON，不要附加說明：
{"dream_summary":"使用 output_language 寫一句本批記憶主題","relations":[{"main_id":1,"related_id":2,"score":0.97,"type":"duplicate_candidate","reason":"同一承諾與日期","merge":{"category":"重要事件","content":"[7/24] 一條重構後完整連貫的記憶。","triggers":["承諾"]}}]}

規則：
- 只有明確涉及同一事件、實體、偏好、承諾或持續事實的記憶才能建立關聯。
- type 只能是 related、same_event、temporal、duplicate_candidate 或 conflict_update。
- related：同一實體或主題下彼此相容、但可獨立成立的事實。
- same_event：不同記憶描述同一個具體事件。
- temporal：同一事件脈絡中存在明確先後、延續或後續結果。
- duplicate_candidate：核心事實實質重複，必須提供 merge 預覽。
- conflict_update：同一事實在數字、日期、否定、承諾或狀態上發生改變或衝突。
- reason、merge 與 dream_summary 中所有可讀文字必須使用 output_language。
- score 必須介於 0 到 1；低於 0.92 的項目不要輸出。
- main_id 是涵蓋較廣或更耐久的記憶；related_id 是較窄的記憶。
- 一條記憶可連到多條其他記憶；輸出所有合格配對，不得限制為一條關聯。
- duplicate_candidate 必須含 merge。merge.content 必須依核心事實重構成一條連貫的長期記憶，不得直接把兩段來源拼接。
- merge.content 最多只能有一個如 [7/24] 的日期標記，置於開頭；來源日期相同時只寫一次。
- merge.content 只保留記憶本身，不得附加「重複記憶已合併」等處理說明。
- 不得虛構事實或 id。只能提供可審核的合併預覽，不得宣稱已修改或刪除記憶。
- existing_links 與 existing_link_memories 是本批記憶周邊已保存的連線及端點內容。不得重複輸出未發生變化的已確認關聯，也不得建立沒有新增資訊的傳遞性連線；待確認關聯必須重新獨立判斷。
- user_rejected_pairs 是使用者明確拒絕的配對，不得再次提出。
- 向量候選只負責提供可能相關的配對；必須根據記憶正文與證據自行判斷關係是否成立。
- 不得只因兩條記憶屬於相同寬泛類別，就建立 related 關聯。
- 沒有強關聯時輸出 {"dream_summary":"...","relations":[]}。
- dream_summary：用一句自然語句概括本批記憶主題（不超過 30 個中文字），只作整理批次標籤，不寫文學描寫。
''';

  static const String _dreamSystemPromptZhCn = '''
你负责整理既有的长期记忆关联图。只分析本次提供的记忆。
只输出合法 JSON，不要附加说明：
{"dream_summary":"使用 output_language 写一句本批记忆主题","relations":[{"main_id":1,"related_id":2,"score":0.97,"type":"duplicate_candidate","reason":"同一承诺与日期","merge":{"category":"重要事件","content":"[7/24] 一条重构后完整连贯的记忆。","triggers":["承诺"]}}]}

规则：
- 只有明确涉及同一事件、实体、偏好、承诺或持续事实的记忆才能建立关联。
- type 只能是 related、same_event、temporal、duplicate_candidate 或 conflict_update。
- related：同一实体或主题下彼此相容、但可独立成立的事实。
- same_event：不同记忆描述同一个具体事件。
- temporal：同一事件脉络中存在明确先后、延续或后续结果。
- duplicate_candidate：核心事实实质重复，必须提供 merge 预览。
- conflict_update：同一事实在数字、日期、否定、承诺或状态上发生改变或冲突。
- reason、merge 与 dream_summary 中所有可读文字必须使用 output_language。
- score 必须介于 0 到 1；低于 0.92 的项目不要输出。
- main_id 是涵盖较广或更耐久的记忆；related_id 是较窄的记忆。
- 一条记忆可连到多条其他记忆；输出所有合格配对，不得限制为一条关联。
- duplicate_candidate 必须含 merge。merge.content 必须依核心事实重构成一条连贯的长期记忆，不得直接把两段来源拼接。
- merge.content 最多只能有一个如 [7/24] 的日期标记，置于开头；来源日期相同时只写一次。
- merge.content 只保留记忆本身，不得附加“重复记忆已合并”等处理说明。
- 不得虚构事实或 id。只能提供可审核的合并预览，不得宣称已修改或删除记忆。
- existing_links 与 existing_link_memories 是本批记忆周边已保存的连线及端点内容。不得重复输出未发生变化的已确认关联，也不得建立没有新增信息的传递性连线；待确认关联必须重新独立判断。
- user_rejected_pairs 是用户明确拒绝的配对，不得再次提出。
- 向量候选只负责提供可能相关的配对；必须根据记忆正文与证据自行判断关系是否成立。
- 不得只因两条记忆属于相同宽泛类别，就建立 related 关联。
- 没有强关联时输出 {"dream_summary":"...","relations":[]}。
- dream_summary：用一句自然语句概括本批记忆主题（不超过 30 个中文字），只作整理批次标签，不写文学描写。
''';

  static String _dreamSystemPromptForLocale(String locale) => switch (locale) {
    'zh_CN' => _dreamSystemPromptZhCn,
    'zh_TW' => _dreamSystemPromptZhTw,
    _ => _dreamSystemPromptEn,
  };

  static String get _dreamSystemPrompt => _dreamSystemPromptForLocale(L.locale);

  /// 回覆完成後呼叫。判斷是否滿足觸發條件，滿足就跑一輪做夢整理。
  /// 用 [unawaited] 包在外面以免阻塞聊天主流程。
  static Future<void> maybeTrigger({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String memoryMode,
  }) async {
    if (_running) return;

    final enabled = await MemorySettings.getDreamCurationEnabled();
    if (!enabled) return;

    final threshold = await MemorySettings.getDreamCurationThreshold();
    final allInLane = await DatabaseHelper.getAllActiveMemories(
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final allMemories = allInLane
        .where((memory) => memory.mode == memoryMode)
        .toList(growable: false);
    final currentCount = allMemories.length;
    final storedLastCount =
        await MemorySettings.getDreamCurationLastCountForScope(
          characterId: characterId,
          contextMode: contextMode.storageValue,
          continuityId: continuityId,
          memoryMode: memoryMode,
        );
    if (storedLastCount != null && storedLastCount > currentCount) {
      // 記憶被刪除或封存後重新以目前 active 數量為基準，避免門檻卡死。
      await _saveScopeCount(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        memoryMode: memoryMode,
        count: currentCount,
      );
      return;
    }
    // 升級後每個 scope 首次只整理最近一個門檻量，避免把整庫一次送出。
    final lastCount =
        storedLastCount ??
        (currentCount > threshold ? currentCount - threshold : 0);

    final delta = currentCount - lastCount;
    if (delta < threshold) return;

    _running = true;
    try {
      developer.log(
        '做夢整理觸發：scope=${contextMode.storageValue}/$continuityId/'
        '$memoryMode delta=$delta threshold=$threshold',
        name: 'DreamCuration',
      );
      if (allMemories.length < 2) return;

      // ═══ 全文組批：只在同一日常/RP、故事線與記憶模式內找相關記憶 ═══
      final newMemories = _selectNewMemories(allMemories, lastCount);
      final batches = await _buildSmartBatches(
        newMemories: newMemories,
        allMemories: allMemories,
        characterId: characterId,
      );

      if (batches.isEmpty) {
        // 沒有有效批次但已到門檻，更新計數避免每輪都重試
        await _saveScopeCount(
          characterId: characterId,
          contextMode: contextMode,
          continuityId: continuityId,
          memoryMode: memoryMode,
          count: currentCount,
        );
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

      await _saveScopeCount(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        memoryMode: memoryMode,
        count: currentCount,
      );

      developer.log(
        '做夢整理完成：${batches.length} 批次, '
        '$totalProposed 關聯, $totalCreated 連線, '
        '$totalDuplicates 重複提案, ${dreamSummaries.length} 批次標籤',
        name: 'DreamCuration',
      );
    } catch (e) {
      developer.log('做夢整理失敗', error: e, name: 'DreamCuration');
    } finally {
      _running = false;
    }
  }

  static Future<void> _saveScopeCount({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String memoryMode,
    required int count,
  }) => MemorySettings.saveDreamCurationLastCountForScope(
    characterId: characterId,
    contextMode: contextMode.storageValue,
    continuityId: continuityId,
    memoryMode: memoryMode,
    count: count,
  );

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

  /// 用全文召回為新記憶組批：每條新記憶搜出相關舊記憶，湊成一個語義相關的批次。
  /// 同一條舊記憶可能被多條新記憶命中——去重後放入同一批次。
  static Future<List<List<Memory>>> _buildSmartBatches({
    required List<Memory> newMemories,
    required List<Memory> allMemories,
    required String characterId,
  }) async {
    if (newMemories.isEmpty) return const [];

    final newIds = <int>{
      for (final m in newMemories)
        if (m.id != null) m.id!,
    };
    final allById = <int, Memory>{
      for (final m in allMemories)
        if (m.id != null) m.id!: m,
    };

    // contextMode 是日常/RP 車道，continuityId 是故事線。
    // 三個軸必須同時一致，才能進入同一批次。
    final byScope =
        <
          ({ContextMode contextMode, String continuityId, String mode}),
          List<Memory>
        >{};
    for (final m in newMemories) {
      final scope = (
        contextMode: m.contextMode,
        continuityId: m.continuityId,
        mode: m.mode,
      );
      byScope.putIfAbsent(scope, () => []).add(m);
    }

    final batches = <List<Memory>>[];

    for (final entry in byScope.entries) {
      final scope = entry.key;
      final scopedNewMemories = entry.value;

      // 收集這個 mode 下所有需要放入批次的記憶 id
      final batchIds = <int>{};
      for (final m in scopedNewMemories) {
        if (m.id != null) batchIds.add(m.id!);
      }

      // 每條新記憶只搜尋同車道、同故事線、同記憶模式的舊記憶。
      for (final m in scopedNewMemories) {
        final query = '${m.content} ${m.triggers}'.trim();
        if (query.isEmpty) continue;
        try {
          final related = await MemoryVectorRecallService.searchHybrid(
            query,
            mode: scope.mode,
            characterId: characterId,
            contextMode: scope.contextMode,
            continuityId: scope.continuityId,
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

  @visibleForTesting
  static Future<List<List<Memory>>> buildSmartBatchesForTesting({
    required List<Memory> newMemories,
    required List<Memory> allMemories,
    required String characterId,
  }) => _buildSmartBatches(
    newMemories: newMemories,
    allMemories: allMemories,
    characterId: characterId,
  );

  @visibleForTesting
  static String dreamSystemPromptForTesting(String locale) =>
      _dreamSystemPromptForLocale(locale);
}
