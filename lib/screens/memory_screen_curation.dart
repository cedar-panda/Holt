// ignore_for_file: invalid_use_of_protected_member

part of 'memory_screen.dart';

class _MemoryCurationChoice {
  final bool local;
  final bool vector;
  final bool summary;

  const _MemoryCurationChoice.local()
    : local = true,
      vector = false,
      summary = false;

  const _MemoryCurationChoice.models({
    required this.vector,
    required this.summary,
  }) : local = false;
}

class _MemoryConnectionReport {
  final int firstId;
  final int secondId;
  final String type;
  final double strength;
  final String reason;

  const _MemoryConnectionReport({
    required this.firstId,
    required this.secondId,
    required this.type,
    required this.strength,
    this.reason = '',
  });
}

extension _MemoryCurationMethods on _MemoryScreenState {
  Future<void> _sendSelectedForCuration({
    required bool useVector,
    required bool useSummary,
  }) async {
    if (_curationRunning || _selectedMemoryIds.length < 2) return;
    if (!useVector && !useSummary) return;
    if (!useSummary) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Vector candidates must be reviewed by the summary model before links are changed.',
              zhTW: '向量只提供候選，必須交由摘要模型判斷後才能變更連線。',
              zhCN: '向量只提供候选，必须交由摘要模型判断后才能变更连线。',
            ),
          ),
        ),
      );
      return;
    }
    final byId = <int, Memory>{
      for (final memory in [..._graphMemories, ..._memories, ..._searchResults])
        if (memory.id != null) memory.id!: memory,
    };
    final selected = _selectedMemoryIds
        .map((id) => byId[id])
        .whereType<Memory>()
        .toList();
    if (selected.length < 2) return;
    final batchCount = MemoryCurationService.buildAnalysisBatches(
      selected,
    ).length;
    final jobIds = selected.map((memory) => memory.id!).toList(growable: false);
    await SpiderWebStateService.saveCurationJob(
      _characterId,
      SpiderWebCurationJob(
        memoryIds: jobIds,
        status: 'running',
        updatedAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _curationRunning = true;
      _curationCompletedBatches = 0;
      _curationTotalBatches = batchCount;
      _resumableCurationJob = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Processing all ${selected.length} memories in $batchCount automatic batches',
            zhTW: '將處理全部 ${selected.length} 條記憶，自動分成 $batchCount 批',
            zhCN: '将处理全部 ${selected.length} 条记忆，自动分成 $batchCount 批',
          ),
        ),
      ),
    );
    try {
      MemoryVectorCurationResult? vectorResult;
      Object? vectorError;
      if (useVector) {
        try {
          vectorResult = await MemoryVectorRecallService.analyzeSelected(
            characterId: _characterId,
            memories: selected,
          );
        } catch (error) {
          vectorError = error;
          if (!useSummary) rethrow;
        }
      }
      final result = await MemoryCurationService.analyzeAndLink(
        characterId: _characterId,
        memories: selected,
        vectorCandidates:
            vectorResult?.candidates ?? const <MemoryVectorPairCandidate>[],
        onBatchProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _curationCompletedBatches = completed;
            _curationTotalBatches = total;
          });
        },
        applyImmediately: false,
        persistSuggestions: false,
      );
      final reports = <_MemoryConnectionReport>[
        for (final relation in result.relations)
          _MemoryConnectionReport(
            firstId: relation.mainId,
            secondId: relation.relatedId,
            type: relation.type,
            strength: relation.score,
            reason: relation.reason,
          ),
      ];
      await SpiderWebStateService.clearCurationJob(_characterId);
      if (!mounted) return;
      setState(() {
        _curationRunning = false;
        _curationCompletedBatches = 0;
        _curationTotalBatches = 0;
        _resumableCurationJob = false;
      });
      final accepted = await _showMemoryConnectionReport(
        memories: selected,
        relations: reports,
        preview: true,
        note: vectorError == null
            ? L.pick(
                en: 'Preview only. Nothing has been linked, merged, or deleted yet.',
                zhTW: '目前只是預覽，尚未連線、合併或刪除任何記憶。',
                zhCN: '目前只是预览，尚未连线、合并或删除任何记忆。',
              )
            : L.pick(
                en: 'The vector pass failed; the summary model produced this read-only preview. Nothing has changed yet.',
                zhTW: '向量階段失敗；這份唯讀預覽由摘要模型產生，目前尚未變更任何記憶。',
                zhCN: '向量阶段失败；这份只读预览由摘要模型生成，目前尚未变更任何记忆。',
              ),
      );
      if (!accepted || !mounted) return;
      final applied = await MemoryCurationService.applyReviewedRelations(
        characterId: _characterId,
        memories: selected,
        relations: result.relations,
      );
      if (!mounted) return;
      setState(() {
        _selectionMode = false;
        _selectedMemoryIds.clear();
      });
      await _loadMemories();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Applied ${applied.createdLinks + applied.updatedLinks} connections and ${applied.mergedGroups} memory merges.',
              zhTW:
                  '已套用 ${applied.createdLinks + applied.updatedLinks} 組連線與 ${applied.mergedGroups} 組記憶合併。',
              zhCN:
                  '已应用 ${applied.createdLinks + applied.updatedLinks} 组连线与 ${applied.mergedGroups} 组记忆合并。',
            ),
          ),
        ),
      );
    } catch (error) {
      await SpiderWebStateService.saveCurationJob(
        _characterId,
        SpiderWebCurationJob(
          memoryIds: jobIds,
          status: 'failed',
          updatedAt: DateTime.now(),
          error: '$error',
        ),
      );
      if (!mounted) return;
      setState(() {
        _curationRunning = false;
        _curationCompletedBatches = 0;
        _curationTotalBatches = 0;
        _resumableCurationJob = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Relation analysis failed: $error',
              zhTW: '關聯分析失敗：$error',
              zhCN: '关联分析失败：$error',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _scanExistingMemories({Iterable<int>? memoryIds}) async {
    if (_curationRunning) return;
    final allowed = memoryIds?.toSet();
    final source = <int, Memory>{
      for (final memory in [..._graphMemories, ..._memories, ..._searchResults])
        if (memory.id != null) memory.id!: memory,
    };
    final selected = source.values
        .where((memory) => allowed == null || allowed.contains(memory.id))
        .take(MemorySettings.maxMemorySendLimit)
        .toList(growable: false);
    if (selected.length < 2) return;
    setState(() => _curationRunning = true);
    try {
      final result = await ExistingMemoryScanner.scan(
        characterId: _characterId,
        memories: selected,
        applyImmediately: false,
        persistSuggestions: false,
      );
      if (!mounted) return;
      setState(() {
        _curationRunning = false;
        _reviewSourceMessageId = null;
      });
      final accepted = await _showMemoryConnectionReport(
        memories: selected,
        relations: <_MemoryConnectionReport>[
          for (final relation in result.relations)
            _MemoryConnectionReport(
              firstId: relation.firstId,
              secondId: relation.secondId,
              type: relation.type,
              strength: relation.strength,
              reason: '',
            ),
        ],
        preview: true,
        note: L.pick(
          en: 'On-device preview only. Nothing has been linked, merged, or deleted yet.',
          zhTW: '這只是本機預覽，尚未連線、合併或刪除任何記憶。',
          zhCN: '这只是本机预览，尚未连线、合并或删除任何记忆。',
        ),
      );
      if (!accepted || !mounted) return;
      await ExistingMemoryScanner.scan(
        characterId: _characterId,
        memories: selected,
        applyImmediately: true,
      );
      if (!mounted) return;
      setState(() {
        _selectionMode = false;
        _selectedMemoryIds.clear();
      });
      await _loadMemories();
    } catch (error) {
      if (!mounted) return;
      setState(() => _curationRunning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local memory scan failed: $error',
              zhTW: '本地記憶掃描失敗：$error',
              zhCN: '本地记忆扫描失败：$error',
            ),
          ),
        ),
      );
    }
  }

  Future<bool> _showMemoryConnectionReport({
    required List<Memory> memories,
    required List<_MemoryConnectionReport> relations,
    int createdLinks = 0,
    int updatedLinks = 0,
    int unchangedLinks = 0,
    int protectedLinks = 0,
    int mergedGroups = 0,
    int protectedProposals = 0,
    String? note,
    bool preview = false,
  }) async {
    if (!mounted) return false;
    final byId = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    final relatedIds = <int>{
      for (final relation in relations) ...[
        relation.firstId,
        relation.secondId,
      ],
    };
    final unrelated = byId.values
        .where((memory) => !relatedIds.contains(memory.id))
        .toList(growable: false);
    final unrelatedDaily = unrelated
        .where((memory) => memory.contextMode == ContextMode.daily)
        .toList(growable: false);
    final unrelatedRp = unrelated
        .where((memory) => memory.contextMode == ContextMode.rp)
        .toList(growable: false);
    final dailyRelations = relations
        .where(
          (relation) =>
              byId[relation.firstId]?.contextMode == ContextMode.daily &&
              byId[relation.secondId]?.contextMode == ContextMode.daily,
        )
        .toList(growable: false);
    final rpMergeRelations = relations
        .where(
          (relation) =>
              byId[relation.firstId]?.contextMode == ContextMode.rp &&
              byId[relation.secondId]?.contextMode == ContextMode.rp,
        )
        .toList(growable: false);
    final hasDaily = memories.any(
      (memory) => memory.contextMode == ContextMode.daily,
    );
    final hasRp = memories.any(
      (memory) => memory.contextMode == ContextMode.rp,
    );
    final rpOnly = hasRp && !hasDaily;
    final mixedModes = hasRp && hasDaily;
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.82,
        child: Container(
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              ExcludeSemantics(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: rpOnly
                              ? 'RP memory organization results'
                              : mixedModes
                              ? 'Memory organization results'
                              : 'Memory connection report',
                          zhTW: rpOnly
                              ? 'RP 記憶整理結果'
                              : mixedModes
                              ? '記憶整理結果'
                              : '記憶連線報告',
                          zhCN: rpOnly
                              ? 'RP 记忆整理结果'
                              : mixedModes
                              ? '记忆整理结果'
                              : '记忆连线报告',
                        ),
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                      onPressed: () => Navigator.pop(sheetContext, false),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
                  children: [
                    Text(
                      L.pick(
                        en: rpOnly
                            ? '$mergedGroups groups merged · ${rpMergeRelations.length} duplicate groups reviewed · ${unrelatedRp.length} memories kept${protectedProposals == 0 ? '' : ' · $protectedProposals require review'}'
                            : mixedModes
                            ? '${dailyRelations.length} daily connections · $mergedGroups RP groups merged · ${unrelated.length} memories kept${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · ${protectedLinks + protectedProposals} protected'}'
                            : '${dailyRelations.length} connections · $createdLinks new · $updatedLinks updated · $unchangedLinks unchanged · $mergedGroups merged · ${unrelatedDaily.length} unrelated${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · ${protectedLinks + protectedProposals} protected'}',
                        zhTW: rpOnly
                            ? '已合併 $mergedGroups 組 · 檢查 ${rpMergeRelations.length} 組重複內容 · 保留 ${unrelatedRp.length} 條記憶${protectedProposals == 0 ? '' : ' · $protectedProposals 組需確認'}'
                            : mixedModes
                            ? '日常 ${dailyRelations.length} 組關聯 · RP 已合併 $mergedGroups 組 · 保留 ${unrelated.length} 條記憶${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · 受保護 ${protectedLinks + protectedProposals} 組'}'
                            : '${dailyRelations.length} 組關聯 · 新增 $createdLinks · 更新 $updatedLinks · 未變更 $unchangedLinks · 已合併 $mergedGroups 組 · ${unrelatedDaily.length} 條未發現關聯${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · 受保護 ${protectedLinks + protectedProposals} 組'}',
                        zhCN: rpOnly
                            ? '已合并 $mergedGroups 组 · 检查 ${rpMergeRelations.length} 组重复内容 · 保留 ${unrelatedRp.length} 条记忆${protectedProposals == 0 ? '' : ' · $protectedProposals 组需确认'}'
                            : mixedModes
                            ? '日常 ${dailyRelations.length} 组关联 · RP 已合并 $mergedGroups 组 · 保留 ${unrelated.length} 条记忆${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · 受保护 ${protectedLinks + protectedProposals} 组'}'
                            : '${dailyRelations.length} 组关联 · 新增 $createdLinks · 更新 $updatedLinks · 未变更 $unchangedLinks · 已合并 $mergedGroups 组 · ${unrelatedDaily.length} 条未发现关联${protectedLinks == 0 && protectedProposals == 0 ? '' : ' · 受保护 ${protectedLinks + protectedProposals} 组'}',
                      ),
                      style: YanciTheme.bodySmall,
                    ),
                    if (note != null && note.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(note, style: YanciTheme.bodySmall),
                    ],
                    if (dailyRelations.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _reportSectionTitle(
                        L.pick(en: 'Connections', zhTW: '相關記憶', zhCN: '相关记忆'),
                      ),
                      const SizedBox(height: 6),
                      for (final relation in dailyRelations) ...[
                        _buildConnectionReportRow(
                          relation,
                          byId[relation.firstId],
                          byId[relation.secondId],
                        ),
                        Divider(
                          height: 18,
                          thickness: 0.6,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.12,
                          ),
                        ),
                      ],
                    ],
                    if (rpMergeRelations.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _reportSectionTitle(
                        L.pick(
                          en: 'RP memory consolidation',
                          zhTW: 'RP 記憶合併整理',
                          zhCN: 'RP 记忆合并整理',
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final relation in rpMergeRelations) ...[
                        _buildConnectionReportRow(
                          relation,
                          byId[relation.firstId],
                          byId[relation.secondId],
                          mergeOnly: true,
                        ),
                        Divider(
                          height: 18,
                          thickness: 0.6,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.12,
                          ),
                        ),
                      ],
                    ],
                    if (unrelatedDaily.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _reportSectionTitle(
                        L.pick(
                          en: 'No connection created · memories kept',
                          zhTW: '未建立連線 · 記憶保留',
                          zhCN: '未建立连线 · 记忆保留',
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        L.pick(
                          en: 'No strong relationship was found. These memories remain unchanged and are not marked for deletion.',
                          zhTW: '目前沒有找到足夠明確的關聯；這些記憶會原樣保留，也不代表建議刪除。',
                          zhCN: '目前没有找到足够明确的关联；这些记忆会原样保留，也不代表建议删除。',
                        ),
                        style: YanciTheme.bodySmall.copyWith(height: 1.4),
                      ),
                      const SizedBox(height: 4),
                      for (final memory in unrelatedDaily)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            memory.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: YanciTheme.bodyText,
                          ),
                        ),
                    ],
                    if (unrelatedRp.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _reportSectionTitle(
                        L.pick(
                          en: 'RP memories do not require links',
                          zhTW: 'RP 記憶無需強制連線',
                          zhCN: 'RP 记忆无需强制连线',
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        L.pick(
                          en: 'No clear story relationship was found. RP memories can remain independent without forced links and will still participate in later recall.',
                          zhTW:
                              '目前沒有找到足夠明確的劇情關聯。RP 記憶可以獨立保留，不需要勉強連線，仍會正常參與後續召回。',
                          zhCN:
                              '目前没有找到足够明确的剧情关联。RP 记忆可以独立保留，不需要勉强连线，仍会正常参与后续召回。',
                        ),
                        style: YanciTheme.bodySmall.copyWith(height: 1.4),
                      ),
                      const SizedBox(height: 4),
                      for (final memory in unrelatedRp)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            memory.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: YanciTheme.bodyText,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (preview)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheetContext, false),
                            child: Text(
                              L.pick(
                                en: 'Keep unchanged',
                                zhTW: '保留原樣',
                                zhCN: '保留原样',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: relations.isEmpty
                                ? null
                                : () => Navigator.pop(sheetContext, true),
                            child: Text(
                              L.pick(
                                en: 'Apply reviewed changes',
                                zhTW: '套用已審內容',
                                zhCN: '应用已审内容',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return accepted ?? false;
  }

  Widget _reportSectionTitle(String text) => Text(
    text,
    style: YanciTheme.bodyText.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _buildConnectionReportRow(
    _MemoryConnectionReport relation,
    Memory? first,
    Memory? second, {
    bool mergeOnly = false,
  }) {
    final firstText = first?.content.trim() ?? '#${relation.firstId}';
    final secondText = second?.content.trim() ?? '#${relation.secondId}';
    final relationLabel = mergeOnly
        ? L.pick(en: 'Duplicate content', zhTW: '重複內容', zhCN: '重复内容')
        : switch (relation.type) {
            'duplicate_candidate' => L.pick(
              en: 'Duplicate',
              zhTW: '重複',
              zhCN: '重复',
            ),
            'same_event' => L.pick(
              en: 'Same event',
              zhTW: '同一事件',
              zhCN: '同一事件',
            ),
            'temporal' => L.pick(
              en: 'Continuation',
              zhTW: '前後延續',
              zhCN: '前后延续',
            ),
            'conflict_update' => L.pick(
              en: 'Possible update',
              zhTW: '可能有更新',
              zhCN: '可能有更新',
            ),
            _ => L.pick(en: 'Related', zhTW: '相關', zhCN: '相关'),
          };
    return Semantics(
      label: '$relationLabel: $firstText, $secondText',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$relationLabel · ${(relation.strength * 100).round()}%',
              style: YanciTheme.bodySmall.copyWith(color: YanciTheme.accent),
            ),
            const SizedBox(height: 5),
            Text(
              '$firstText\n${mergeOnly ? '＋' : '↔'} $secondText',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: YanciTheme.bodyText.copyWith(height: 1.35),
            ),
            if (relation.reason.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                relation.reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: YanciTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showAnalysisChoice() async {
    if (_curationRunning || _selectedMemoryIds.length < 2) return;
    final embedding = await MemorySettings.getEmbeddingSelection();
    final summaryModel = await MemorySettings.getSummaryModel();
    final summaryProvider = await MemorySettings.getSummaryProvider();
    if (!mounted) return;
    var useVector = embedding.model.isNotEmpty;
    var useSummary = summaryModel.isNotEmpty;
    final choice = await showModalBottomSheet<_MemoryCurationChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => FractionallySizedBox(
          heightFactor: 0.78,
          child: Container(
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L.pick(
                          en: 'Review selected memories',
                          zhTW: '審核已選記憶',
                          zhCN: '审核已选记忆',
                        ),
                        style: YanciTheme.headingMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        L.pick(
                          en: 'The first pass is read-only. You will review every proposed connection or merge before any stored memory changes.',
                          zhTW: '第一階段只做唯讀分析；所有連線與合併都會先顯示預覽，確認後才變更已存記憶。',
                          zhCN: '第一阶段只做只读分析；所有连线与合并都会先显示预览，确认后才更改已存记忆。',
                        ),
                        style: YanciTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => Navigator.pop(
                          context,
                          const _MemoryCurationChoice.local(),
                        ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          alignment: Alignment.centerLeft,
                        ),
                        icon: const Icon(Icons.shield_outlined, size: 19),
                        label: Text(
                          L.pick(
                            en: 'On-device memory deduplication check',
                            zhTW: '本機記憶去重檢查',
                            zhCN: '本机记忆去重检查',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: useVector,
                        onChanged:
                            embedding.model.isEmpty || summaryModel.isEmpty
                            ? null
                            : (value) => setSheetState(() {
                                useVector = value ?? false;
                                if (useVector) useSummary = true;
                              }),
                        title: Text(
                          L.pick(
                            en: 'Vector relation pass',
                            zhTW: '向量關聯',
                            zhCN: '向量关联',
                          ),
                          style: YanciTheme.bodyText,
                        ),
                        subtitle: Text(
                          embedding.model.isEmpty
                              ? L.pick(
                                  en: 'No embedding model selected',
                                  zhTW: '尚未選擇向量模型',
                                  zhCN: '尚未选择向量模型',
                                )
                              : summaryModel.isEmpty
                              ? L.pick(
                                  en: 'Select a summary model to review vector candidates',
                                  zhTW: '請先選擇摘要模型審核向量候選',
                                  zhCN: '请先选择摘要模型审核向量候选',
                                )
                              : '${embedding.provider} / ${embedding.model}',
                          style: YanciTheme.bodySmall,
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: useSummary,
                        onChanged: summaryModel.isEmpty || useVector
                            ? null
                            : (value) => setSheetState(
                                () => useSummary = value ?? false,
                              ),
                        title: Text(
                          L.pick(
                            en: 'Summary model review',
                            zhTW: '摘要共用模型整理',
                            zhCN: '摘要共用模型整理',
                          ),
                          style: YanciTheme.bodyText,
                        ),
                        subtitle: Text(
                          summaryModel.isEmpty
                              ? L.pick(
                                  en: 'No summary model selected',
                                  zhTW: '尚未選擇摘要共用模型',
                                  zhCN: '尚未选择摘要共用模型',
                                )
                              : '${summaryProvider.isEmpty ? L.pick(en: 'Current source', zhTW: '目前來源', zhCN: '当前来源') : summaryProvider} / $summaryModel',
                          style: YanciTheme.bodySmall,
                        ),
                      ),
                      if (useVector)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            L.pick(
                              en: 'Vectors only suggest candidates. The summary model independently checks summaries, memories and existing links.',
                              zhTW: '向量只提出候選；摘要模型會再依摘要、已選記憶及既有連線獨立判斷。',
                              zhCN: '向量只提出候选；摘要模型会再依摘要、已选记忆及已有连线独立判断。',
                            ),
                            style: YanciTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                    child: FilledButton(
                      onPressed: !useSummary
                          ? null
                          : () => Navigator.pop(
                              context,
                              _MemoryCurationChoice.models(
                                vector: useVector,
                                summary: useSummary,
                              ),
                            ),
                      child: Text(
                        L.pick(
                          en: 'Analyze and preview',
                          zhTW: '分析並預覽',
                          zhCN: '分析并预览',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice?.local == true) {
      await _scanExistingMemories(memoryIds: _selectedMemoryIds);
    } else if (choice != null) {
      await _sendSelectedForCuration(
        useVector: choice.vector,
        useSummary: choice.summary,
      );
    }
  }

  Future<bool> _confirmMemoryArchive({
    required int count,
    required bool includesPermanent,
  }) async {
    final message = count == 1
        ? L.pick(
            en: 'Move this memory to the dusty box?',
            zhTW: '將這條記憶移到積灰小盒子？',
            zhCN: '将这条记忆移到积灰小盒子？',
          )
        : L.pick(
            en: 'Move $count selected memories to the dusty box?',
            zhTW: '將選取的 $count 條記憶移到積灰小盒子？',
            zhCN: '将选中的 $count 条记忆移到积灰小盒子？',
          );
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Move to archive', zhTW: '移至積灰小盒子', zhCN: '移至积灰小盒子'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(message, style: YanciTheme.bodyText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Continue', zhTW: '繼續', zhCN: '继续'),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
    if (result != true) return false;
    if (!includesPermanent) return true;
    if (!mounted) return false;
    return _confirmDelete(
      L.pick(
        en: 'Permanent-memory protection is active. Type DELETE only if you still want to move the protected selection to the archive.',
        zhTW: '這批內容包含永久記憶。若仍要將受保護記憶移至積灰小盒子，請輸入 DELETE 再次確認。',
        zhCN: '这批内容包含永久记忆。若仍要将受保护记忆移至积灰小盒子，请输入 DELETE 再次确认。',
      ),
    );
  }

  Future<void> _deleteMemories(Set<int> ids) async {
    if (ids.isEmpty) return;
    final visibleById = <int, Memory>{
      for (final memory in [..._graphMemories, ..._memories, ..._searchResults])
        if (memory.id != null) memory.id!: memory,
    };
    final includesPermanent = ids.any(
      (id) => visibleById[id]?.isPermanent ?? false,
    );
    final confirmed = await _confirmMemoryArchive(
      count: ids.length,
      includesPermanent: includesPermanent,
    );
    if (!confirmed) return;

    final archived = await DatabaseHelper.archiveMemories(
      ids,
      ids.length == 1 ? '用戶手動刪除' : '用戶批次刪除',
      characterId: _characterId,
    );
    if (!mounted) return;
    _clearSelection();
    await _loadMemories();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: '$archived memories moved to the dusty box',
            zhTW: '已將 $archived 條記憶移到積灰小盒子',
            zhCN: '已将 $archived 条记忆移到积灰小盒子',
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSelectedMemories() =>
      _deleteMemories(Set<int>.from(_selectedMemoryIds));
}
