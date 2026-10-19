// ignore_for_file: invalid_use_of_protected_member

part of 'memory_screen.dart';

extension _MemoryLinkMethods on _MemoryScreenState {
  void _saveNodePosition(int memoryId, double localX, double localY) {
    _savedNodePositions[memoryId] = SpiderWebNodePosition(localX, localY);
    unawaited(
      SpiderWebStateService.savePositions(_characterId, _savedNodePositions),
    );
  }

  Future<void> _showMemoryLink(
    Map<String, dynamic> link,
    Map<String, dynamic> firstMemory,
    Map<String, dynamic> secondMemory,
  ) async {
    final firstId = (link['memory_id_1'] as num?)?.toInt();
    final secondId = (link['memory_id_2'] as num?)?.toInt();
    final relationId = (link['id'] as num?)?.toInt();
    if (firstId == null || secondId == null || relationId == null) return;
    final status = link['status']?.toString() ?? 'confirmed';
    final type = link['relation_type']?.toString() ?? 'related';
    final strength = ((link['strength'] as num?)?.toDouble() ?? 1).clamp(
      0.0,
      1.0,
    );
    final reason = link['reason']?.toString().trim() ?? '';
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Memory link', zhTW: '記憶連線', zhCN: '记忆连线'),
          style: YanciTheme.headingMedium,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _linkMemoryPreview(firstMemory),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: YanciTheme.accent.withValues(alpha: 0.2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.polyline_rounded,
                        size: 17,
                        color: YanciTheme.accent,
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: YanciTheme.accent.withValues(alpha: 0.2),
                      ),
                    ),
                  ],
                ),
              ),
              _linkMemoryPreview(secondMemory),
              const SizedBox(height: 14),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  Chip(
                    avatar: Icon(
                      status == 'suggested'
                          ? Icons.help_outline_rounded
                          : Icons.link_rounded,
                      size: 15,
                    ),
                    label: Text(_relationStatusLabel(status)),
                  ),
                  Chip(label: Text(_relationTypeLabel(type))),
                  Chip(label: Text('${(strength * 100).round()}%')),
                  Chip(
                    label: Text(
                      _relationSourceLabel(
                        link['source']?.toString() ?? 'legacy',
                      ),
                    ),
                  ),
                ],
              ),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reason
                      .split(',')
                      .where((value) => value.trim().isNotEmpty)
                      .map((value) => _relationReasonLabel(value.trim()))
                      .join(' · '),
                  style: YanciTheme.bodySmall.copyWith(height: 1.4),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          if (status == 'suggested') ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'reject'),
              child: Text(
                L.pick(en: 'Not related', zhTW: '不是關聯', zhCN: '不是关联'),
              ),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, 'confirm'),
              child: Text(
                L.pick(en: 'Confirm link', zhTW: '確認連線', zhCN: '确认连线'),
              ),
            ),
          ] else
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx, 'unlink'),
              icon: const Icon(Icons.link_off_rounded, size: 17),
              label: Text(L.pick(en: 'Unlink', zhTW: '解除連線', zhCN: '解除连线')),
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            ),
          if (type == 'duplicate_candidate')
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx, 'review'),
              icon: const Icon(Icons.rule_rounded, size: 17),
              label: Text(
                L.pick(en: 'Review proposal', zhTW: '查看去重提案', zhCN: '查看去重提案'),
              ),
            ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'review') {
      setState(() {
        _tabIndex = 1;
        _isGraphView = false;
        _reviewSourceMessageId = null;
      });
      return;
    }
    if (action == 'confirm' || action == 'reject') {
      await DatabaseHelper.resolveSpiderWebRelation(
        _characterId,
        relationId,
        confirmed: action == 'confirm',
      );
      if (action == 'reject' && type == 'duplicate_candidate') {
        final proposals = await MemoryGuardService.listForReview(_characterId);
        for (final proposal in proposals) {
          if (!proposal.isExistingDuplicateScan ||
              proposal.targetIds.toSet().length != 2) {
            continue;
          }
          final targets = proposal.targetIds.toSet();
          if (targets.contains(firstId) && targets.contains(secondId)) {
            await MemoryGuardService.reject(proposal.id, _characterId);
          }
        }
      }
      await _loadMemories();
      return;
    }
    if (action != 'unlink') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Unlink memories?', zhTW: '解除這條記憶連線？', zhCN: '解除这条记忆连线？'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          L.pick(
            en: 'The memories will remain. Only the line between them will be removed.',
            zhTW: '兩條記憶都會保留，只移除它們之間的連線。',
            zhCN: '两条记忆都会保留，只移除它们之间的连线。',
          ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            child: Text(L.pick(en: 'Unlink', zhTW: '解除連線', zhCN: '解除连线')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DatabaseHelper.deleteSpiderWebLink(_characterId, firstId, secondId);
    await _loadMemories();
  }

  String _relationStatusLabel(String status) => switch (status) {
    'suggested' => L.pick(en: 'Suggested', zhTW: '待確認', zhCN: '待确认'),
    _ => L.pick(en: 'Confirmed', zhTW: '已確認', zhCN: '已确认'),
  };

  String _relationTypeLabel(String type) => switch (type) {
    'same_event' => L.pick(en: 'Same event', zhTW: '同一事件', zhCN: '同一事件'),
    'temporal' => L.pick(en: 'Timeline', zhTW: '時間延續', zhCN: '时间延续'),
    'duplicate_candidate' => L.pick(
      en: 'Possible duplicate',
      zhTW: '疑似重複',
      zhCN: '疑似重复',
    ),
    'conflict_update' => L.pick(
      en: 'State conflict',
      zhTW: '狀態衝突',
      zhCN: '状态冲突',
    ),
    _ => L.pick(en: 'Related', zhTW: '一般關聯', zhCN: '一般关联'),
  };

  String _relationSourceLabel(String source) => switch (source) {
    'local_scan' => L.pick(en: 'Local scan', zhTW: '本地掃描', zhCN: '本地扫描'),
    'model' => L.pick(en: 'Summary model', zhTW: '摘要模型', zhCN: '摘要模型'),
    'user' => L.pick(en: 'User decision', zhTW: '使用者確認', zhCN: '用户确认'),
    'merge_remap' => L.pick(en: 'Merge remap', zhTW: '合併轉接', zhCN: '合并转接'),
    _ => L.pick(en: 'Existing link', zhTW: '舊版連線', zhCN: '旧版连线'),
  };

  String _relationReasonLabel(String reason) {
    if (reason.startsWith('content_similarity:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'content similarity $value%',
        zhTW: '正文相似 $value%',
        zhCN: '正文相似 $value%',
      );
    }
    if (reason.startsWith('trigger_overlap:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'trigger overlap $value%',
        zhTW: '觸發詞重疊 $value%',
        zhCN: '触发词重叠 $value%',
      );
    }
    if (reason.startsWith('model_relation:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'summary-model confidence $value%',
        zhTW: '摘要模型信心 $value%',
        zhCN: '摘要模型置信度 $value%',
      );
    }
    return switch (reason) {
      'exact_content' => L.pick(
        en: 'same normalized content',
        zhTW: '正規化後內容一致',
        zhCN: '正规化后内容一致',
      ),
      'same_category' => L.pick(en: 'same category', zhTW: '同類別', zhCN: '同类别'),
      'negation_conflict' => L.pick(
        en: 'negation differs',
        zhTW: '否定語意不同',
        zhCN: '否定语意不同',
      ),
      'state_conflict' => L.pick(
        en: 'state transition differs',
        zhTW: '狀態轉折不同',
        zhCN: '状态转折不同',
      ),
      'number_conflict' => L.pick(
        en: 'date or number differs',
        zhTW: '日期或數字不同',
        zhCN: '日期或数字不同',
      ),
      'model_memo_link' => L.pick(
        en: 'suggested during conversation',
        zhTW: '對話中提出的關聯',
        zhCN: '对话中提出的关联',
      ),
      _ => reason,
    };
  }

  Widget _linkMemoryPreview(Map<String, dynamic> memory) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          memory['category']?.toString() ?? '',
          style: YanciTheme.bodySmall.copyWith(color: YanciTheme.accent),
        ),
        const SizedBox(height: 4),
        Text(memory['content']?.toString() ?? '', style: YanciTheme.bodyText),
      ],
    );
  }

  void _showCrossLayerLinks(SpiderWebLayerPlan layer) {
    _showLinkList(
      links: layer.crossLayerLinks,
      title: L.pick(
        en: '${layer.crossLayerLinkCount} cross-layer links',
        zhTW: '${layer.crossLayerLinkCount} 條跨層連線',
        zhCN: '${layer.crossLayerLinkCount} 条跨层连线',
      ),
      icon: Icons.layers_rounded,
    );
  }

  void _showSuggestedRelations() {
    _showLinkList(
      links: _spiderLinks,
      title: L.pick(en: 'Relation suggestions', zhTW: '關係建議', zhCN: '关系建议'),
      icon: Icons.rule_rounded,
      initialFilter: 'suggested',
      allowClearSuggested: true,
    );
  }

  Future<void> _confirmAndClearSuggestedRelations(
    BuildContext sheetContext,
    int count,
  ) async {
    if (count <= 0) return;
    final expected = MemoryReviewTab.clearConfirmationWord();
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final canDelete = controller.text.trim() == expected;
          return AlertDialog(
            backgroundColor: YanciTheme.surfacePanel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              L.pick(
                en: 'Clear all relation suggestions?',
                zhTW: '清除所有關係建議？',
                zhCN: '清除所有关系建议？',
              ),
              style: YanciTheme.headingMedium,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L.pick(
                    en: 'This will reject all $count unconfirmed relation suggestions for this character. Memories and confirmed links will remain unchanged. Type "$expected" to continue.',
                    zhTW:
                        '這會拒絕目前角色的 $count 條未確認關係建議。記憶與已確認連線都不會變更。請輸入「$expected」繼續。',
                    zhCN:
                        '这会拒绝当前角色的 $count 条未确认关系建议。记忆与已确认连线都不会更改。请输入“$expected”继续。',
                  ),
                  style: YanciTheme.bodyText,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.none,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setDialogState(() {}),
                  onSubmitted: (_) {
                    if (!canDelete) return;
                    FocusManager.instance.primaryFocus?.unfocus();
                    Navigator.pop(dialogContext, true);
                  },
                  decoration: InputDecoration(hintText: expected),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
              ),
              FilledButton(
                onPressed: canDelete
                    ? () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        Navigator.pop(dialogContext, true);
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade400,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.red.shade400.withValues(
                    alpha: 0.18,
                  ),
                ),
                child: Text(
                  L.pick(en: 'Clear all', zhTW: '清除所有', zhCN: '清除所有'),
                ),
              ),
            ],
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (confirmed != true || !mounted) return;

    if (sheetContext.mounted && Navigator.canPop(sheetContext)) {
      Navigator.pop(sheetContext);
    }
    final cleared = await MemoryGuardService.rejectAllSuggestedRelations(
      _characterId,
    );
    await _loadMemories();
    if (!mounted) return;
    showThemedPillNotice(
      context,
      L.pick(
        en: 'Cleared $cleared relation suggestions',
        zhTW: '已清除 $cleared 條關係建議',
        zhCN: '已清除 $cleared 条关系建议',
      ),
    );
  }

  void _showLinkList({
    required List<Map<String, dynamic>> links,
    required String title,
    IconData icon = Icons.polyline_rounded,
    String initialFilter = 'all',
    bool allowClearSuggested = false,
  }) {
    var filter = initialFilter;
    final byId = <int, Map<String, dynamic>>{
      for (final memory in _graphMemories)
        if (memory.id != null) memory.id!: memory.toMap(),
    };
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final visibleLinks = links
              .where((link) {
                return switch (filter) {
                  'confirmed' => link['status']?.toString() == 'confirmed',
                  'suggested' => link['status']?.toString() == 'suggested',
                  'duplicate' =>
                    link['relation_type']?.toString() == 'duplicate_candidate',
                  'conflict' =>
                    link['relation_type']?.toString() == 'conflict_update',
                  _ => true,
                };
              })
              .toList(growable: false);
          final suggestedCount = links
              .where((link) => link['status']?.toString() == 'suggested')
              .length;
          return DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.3,
            maxChildSize: 0.82,
            builder: (ctx, controller) => Container(
              decoration: BoxDecoration(
                color: YanciTheme.surfacePanel,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                    child: Row(
                      children: [
                        Icon(icon, color: YanciTheme.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(title, style: YanciTheme.headingMedium),
                        ),
                        if (allowClearSuggested && suggestedCount > 0)
                          TextButton(
                            onPressed: () => _confirmAndClearSuggestedRelations(
                              ctx,
                              suggestedCount,
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red.shade300,
                              minimumSize: const Size(0, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            child: Text(
                              L.pick(
                                en: 'Clear all',
                                zhTW: '清除所有',
                                zhCN: '清除所有',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final entry in <String, String>{
                          'all': L.pick(en: 'All', zhTW: '全部', zhCN: '全部'),
                          'confirmed': L.pick(
                            en: 'Confirmed',
                            zhTW: '已確認',
                            zhCN: '已确认',
                          ),
                          'suggested': L.pick(
                            en: 'Suggested',
                            zhTW: '待確認',
                            zhCN: '待确认',
                          ),
                          'duplicate': L.pick(
                            en: 'Duplicates',
                            zhTW: '重複',
                            zhCN: '重复',
                          ),
                          'conflict': L.pick(
                            en: 'Conflicts',
                            zhTW: '衝突',
                            zhCN: '冲突',
                          ),
                        }.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 7),
                            child: ChoiceChip(
                              label: Text(entry.value),
                              selected: filter == entry.key,
                              onSelected: (_) =>
                                  setSheetState(() => filter = entry.key),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: visibleLinks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final link = visibleLinks[index];
                        final firstId = (link['memory_id_1'] as num?)?.toInt();
                        final secondId = (link['memory_id_2'] as num?)?.toInt();
                        final first = firstId == null ? null : byId[firstId];
                        final second = secondId == null ? null : byId[secondId];
                        if (first == null || second == null) {
                          return const SizedBox.shrink();
                        }
                        return Material(
                          color: YanciTheme.accent.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(
                            YanciTheme.radiusSm,
                          ),
                          child: ListTile(
                            minVerticalPadding: 12,
                            leading: Icon(
                              link['status'] == 'suggested'
                                  ? Icons.help_outline_rounded
                                  : Icons.polyline_rounded,
                              color: link['relation_type'] == 'conflict_update'
                                  ? Colors.orange.shade400
                                  : YanciTheme.accent,
                            ),
                            title: Text(
                              '${first['category'] ?? ''} ↔ ${second['category'] ?? ''}',
                              style: YanciTheme.bodyText,
                            ),
                            subtitle: Text(
                              '${_relationStatusLabel(link['status']?.toString() ?? 'confirmed')} · ${_relationTypeLabel(link['relation_type']?.toString() ?? 'related')}\n${first['content'] ?? ''}\n${second['content'] ?? ''}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodySmall,
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              Navigator.pop(ctx);
                              _showMemoryLink(link, first, second);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
