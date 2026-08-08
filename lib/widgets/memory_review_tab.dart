import 'package:flutter/material.dart';

import '../models/memory_action_proposal.dart';
import '../memory/database.dart';
import '../services/locale_strings.dart';
import '../services/memory_guard_service.dart';
import '../theme/app_theme.dart';

class MemoryReviewTab extends StatefulWidget {
  final String characterId;
  final int? sourceMessageId;
  final VoidCallback? onChanged;

  const MemoryReviewTab({
    super.key,
    required this.characterId,
    this.sourceMessageId,
    this.onChanged,
  });

  /// A reply-focused inbox must still surface proposals explicitly created by
  /// the user's on-device deduplication check. Those proposals are not bound
  /// to a chat message and were previously hidden by the source filter.
  @visibleForTesting
  static bool visibleInSourceReview(
    MemoryActionProposal proposal,
    int sourceMessageId,
  ) =>
      proposal.sourceMessageId == sourceMessageId ||
      proposal.isExistingDuplicateScan;

  @override
  State<MemoryReviewTab> createState() => _MemoryReviewTabState();
}

class _MemoryReviewTabState extends State<MemoryReviewTab> {
  List<MemoryActionProposal> _proposals = const [];
  bool _loading = true;
  bool _showOnlySource = true;
  String? _busyId;
  final Map<String, Map<String, Object?>> _editedMergePreviews = {};

  List<MemoryActionProposal> get _visible {
    final sourceMessageId = widget.sourceMessageId;
    if (!_showOnlySource || sourceMessageId == null) return _proposals;
    return _proposals
        .where(
          (proposal) =>
              MemoryReviewTab.visibleInSourceReview(proposal, sourceMessageId),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _reload(markSeen: true);
  }

  @override
  void didUpdateWidget(covariant MemoryReviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId ||
        oldWidget.sourceMessageId != widget.sourceMessageId) {
      _showOnlySource = true;
      _reload(markSeen: true);
    }
  }

  Future<void> _reload({bool markSeen = false}) async {
    if (mounted) setState(() => _loading = true);
    await MemoryGuardService.consolidateExistingDuplicateProposals(
      widget.characterId,
    );
    if (markSeen) {
      await MemoryGuardService.markSeen(
        widget.characterId,
        sourceMessageId: widget.sourceMessageId,
        includeLocalScan: widget.sourceMessageId != null,
      );
    }
    final proposals = await MemoryGuardService.listForReview(
      widget.characterId,
    );
    if (!mounted) return;
    setState(() {
      _proposals = proposals;
      final activeIds = proposals.map((proposal) => proposal.id).toSet();
      _editedMergePreviews.removeWhere((id, _) => !activeIds.contains(id));
      _loading = false;
    });
    widget.onChanged?.call();
  }

  Future<void> _reject(MemoryActionProposal proposal) async {
    await _run(proposal.id, () async {
      await MemoryGuardService.reject(proposal.id, widget.characterId);
      if (proposal.isExistingDuplicateScan && proposal.targetIds.length == 2) {
        await DatabaseHelper.deleteSpiderWebLink(
          widget.characterId,
          proposal.targetIds.first,
          proposal.targetIds.last,
        );
      }
    });
  }

  Future<void> _discardStaleProposal(MemoryActionProposal proposal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          L.pick(
            en: 'Delete this expired proposal?',
            zhTW: '刪除這則失效提案？',
            zhCN: '删除这则失效提案？',
          ),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          L.pick(
            en: 'Only this proposal will be removed. No existing memories will be deleted or changed.',
            zhTW: '只會移除這則待確認提案，不會刪除或變更任何既有記憶。',
            zhCN: '只会移除这则待确认提案，不会删除或变更任何既有记忆。',
          ),
          style: YanciTheme.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade400,
              foregroundColor: Colors.white,
            ),
            child: Text(
              L.pick(en: 'Delete proposal', zhTW: '刪除提案', zhCN: '删除提案'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(proposal.id, () async {
      // Deliberately do not use _reject(): discarding a stale inbox item must
      // not mutate its memories or their suggested spider-web relation.
      await MemoryGuardService.reject(proposal.id, widget.characterId);
    });
  }

  Future<void> _snooze(MemoryActionProposal proposal) async {
    await _run(proposal.id, () async {
      if (proposal.action == MemoryActionProposal.actionLink) {
        final result = await MemoryGuardService.execute(
          proposal.id,
          widget.characterId,
          linkDecision: MemoryGuardService.linkDecisionDefer,
        );
        _requireCompleted(result);
      } else {
        await MemoryGuardService.snooze(proposal.id, widget.characterId);
      }
    });
  }

  Future<void> _keepExisting(MemoryActionProposal proposal) async {
    await _run(proposal.id, () async {
      await MemoryGuardService.reject(proposal.id, widget.characterId);
    });
  }

  Future<void> _useNewCandidate(MemoryActionProposal proposal) async {
    final targetPermanent = proposal.targetSnapshots.any(
      (target) => target['permanent'] == true,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          L.pick(en: 'Use the new memory?', zhTW: '改用新記憶？', zhCN: '改用新记忆？'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          L.pick(
            en: targetPermanent
                ? 'The old permanent memory will move to the archive. Its permanent protection and web links will carry over to the new memory.'
                : 'The old memory will move to the archive and its web links will carry over to the new memory.',
            zhTW: targetPermanent
                ? '舊的永久記憶會移至回收區；永久保護與蛛網連線都會繼承到新記憶。'
                : '舊記憶會移至回收區，蛛網連線會繼承到新記憶。',
            zhCN: targetPermanent
                ? '旧的永久记忆会移至回收区；永久保护与蛛网连线都会继承到新记忆。'
                : '旧记忆会移至回收区，蛛网连线会继承到新记忆。',
          ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(L.pick(en: 'Use new', zhTW: '使用新條', zhCN: '使用新条')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (targetPermanent &&
        !await _confirmPermanentProposal(
          L.pick(
            en: 'replace this protected memory',
            zhTW: '替換這條受保護記憶',
            zhCN: '替换这条受保护记忆',
          ),
        )) {
      return;
    }
    await _run(proposal.id, () async {
      final result = await MemoryGuardService.execute(
        proposal.id,
        widget.characterId,
        createDecision: MemoryGuardService.createDecisionUseNew,
      );
      _requireCompleted(result);
    });
  }

  Future<void> _mergeCandidate(MemoryActionProposal proposal) async {
    final preview = _effectiveMergePreview(proposal);
    final categoryController = TextEditingController(
      text: preview['category']?.toString() ?? '',
    );
    final contentController = TextEditingController(
      text: preview['content']?.toString() ?? '',
    );
    final triggersController = TextEditingController(
      text: preview['triggers']?.toString() ?? '',
    );
    final edited = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          L.pick(en: 'Review merged memory', zhTW: '檢查合併後記憶', zhCN: '检查合并后记忆'),
          style: YanciTheme.headingMedium,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: categoryController,
                decoration: InputDecoration(
                  labelText: L.pick(en: 'Category', zhTW: '類別', zhCN: '类别'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contentController,
                minLines: 3,
                maxLines: 7,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Merged content',
                    zhTW: '合併後內容',
                    zhCN: '合并后内容',
                  ),
                  helperText: L.pick(
                    en: 'Keep every date, promise and state change that still matters.',
                    zhTW: '請保留仍有效的日期、承諾與狀態變化。',
                    zhCN: '请保留仍有效的日期、承诺与状态变化。',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: triggersController,
                decoration: InputDecoration(
                  labelText: L.pick(en: 'Triggers', zhTW: '觸發詞', zhCN: '触发词'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          FilledButton.tonal(
            onPressed: () {
              final content = contentController.text.trim();
              if (content.isEmpty) return;
              Navigator.pop(context, <String, Object?>{
                'category': categoryController.text.trim(),
                'content': content,
                'triggers': triggersController.text.trim(),
              });
            },
            child: Text(L.pick(en: 'Merge', zhTW: '確認合併', zhCN: '确认合并')),
          ),
        ],
      ),
    );
    categoryController.dispose();
    contentController.dispose();
    triggersController.dispose();
    if (edited == null || !mounted) return;
    if (proposal.targetSnapshots.any((target) => target['permanent'] == true) &&
        !await _confirmPermanentProposal(
          L.pick(
            en: 'merge protected memories',
            zhTW: '合併受保護記憶',
            zhCN: '合并受保护记忆',
          ),
        )) {
      return;
    }
    await _run(proposal.id, () async {
      final result = await MemoryGuardService.execute(
        proposal.id,
        widget.characterId,
        createDecision: MemoryGuardService.createDecisionMerge,
        createResultOverride: edited,
      );
      _requireCompleted(result);
    });
  }

  void _requireCompleted(String result) {
    if (result == MemoryActionProposal.statusCompleted) return;
    throw StateError(
      result == MemoryActionProposal.statusStale
          ? L.pick(
              en: 'The memories changed while this proposal was waiting. Please review the latest state.',
              zhTW: '等待確認期間記憶已有變動，請重新檢查最新狀態。',
              zhCN: '等待确认期间记忆已有变动，请重新检查最新状态。',
            )
          : L.pick(
              en: 'The proposal could not be applied.',
              zhTW: '這個提案未能套用。',
              zhCN: '这个提案未能套用。',
            ),
    );
  }

  Future<void> _accept(MemoryActionProposal proposal) async {
    final isMerge = proposal.action == MemoryActionProposal.actionMerge;
    final isLink = proposal.action == MemoryActionProposal.actionLink;
    Map<String, Object?>? mergeOverride;
    if (isMerge) {
      mergeOverride = _editedMergePreviews[proposal.id];
      if (mergeOverride == null) {
        mergeOverride = await _editMergePreview(proposal);
        if (mergeOverride == null || !mounted) return;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          isLink
              ? L.pick(
                  en: 'Connect these memories?',
                  zhTW: '確認這組記憶連線？',
                  zhCN: '确认这组记忆连线？',
                )
              : isMerge
              ? L.pick(en: 'Merge memories?', zhTW: '合併這些記憶？')
              : L.pick(en: 'Move to archive?', zhTW: '移至回收區？'),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          isLink
              ? L.pick(
                  en: 'Every memory in this proposal will be connected to the others. No memory content will change.',
                  zhTW: '這組內的記憶會彼此建立連線，不會修改任何記憶內容。',
                  zhCN: '这组内的记忆会彼此建立连线，不会修改任何记忆内容。',
                )
              : isMerge
              ? L.pick(
                  en: 'The originals will be archived and their web links will move to the merged memory.',
                  zhTW: '原記憶會進入回收區，現有蛛網連線會轉移到合併後的記憶。',
                )
              : L.pick(
                  en: 'Nothing is permanently deleted. You can restore it from the archive.',
                  zhTW: '這不會永久刪除，之後仍可從回收區還原。',
                ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isLink
                  ? L.pick(en: 'Connect', zhTW: '確認連線', zhCN: '确认连线')
                  : isMerge
                  ? L.pick(en: 'Merge', zhTW: '確認合併')
                  : L.pick(en: 'Archive', zhTW: '移至回收區'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final includesPermanent = proposal.targetSnapshots.any(
      (target) => target['permanent'] == true,
    );
    if (!isLink &&
        includesPermanent &&
        !await _confirmPermanentProposal(
          isMerge
              ? L.pick(
                  en: 'merge protected memories',
                  zhTW: '合併受保護記憶',
                  zhCN: '合并受保护记忆',
                )
              : L.pick(
                  en: 'archive protected memories',
                  zhTW: '封存受保護記憶',
                  zhCN: '归档受保护记忆',
                ),
        )) {
      return;
    }

    await _run(proposal.id, () async {
      final result = await MemoryGuardService.execute(
        proposal.id,
        widget.characterId,
        linkDecision: isLink ? MemoryGuardService.linkDecisionConfirm : null,
        mergeResultOverride: mergeOverride,
      );
      _requireCompleted(result);
    });
  }

  Future<Map<String, Object?>?> _editMergePreview(
    MemoryActionProposal proposal,
  ) async {
    final preview = _effectiveMergePreview(proposal);
    final categoryController = TextEditingController(
      text: preview['category']?.toString() ?? '',
    );
    final contentController = TextEditingController(
      text: preview['content']?.toString() ?? '',
    );
    final triggersController = TextEditingController(
      text: preview['triggers']?.toString() ?? '',
    );
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          L.pick(en: 'Review merged memory', zhTW: '檢查合併後記憶', zhCN: '检查合并后记忆'),
          style: YanciTheme.headingMedium,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: categoryController,
                decoration: InputDecoration(
                  labelText: L.pick(en: 'Category', zhTW: '類別', zhCN: '类别'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contentController,
                minLines: 3,
                maxLines: 7,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Merged content',
                    zhTW: '合併後內容',
                    zhCN: '合并后内容',
                  ),
                  helperText: L.pick(
                    en: 'Keep important dates, numbers, promises and state changes.',
                    zhTW: '請保留重要日期、數字、承諾與狀態變化。',
                    zhCN: '请保留重要日期、数字、承诺与状态变化。',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: triggersController,
                decoration: InputDecoration(
                  labelText: L.pick(en: 'Triggers', zhTW: '觸發詞', zhCN: '触发词'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          FilledButton.tonal(
            onPressed: () {
              final content = contentController.text.trim();
              if (content.isEmpty) return;
              Navigator.pop(context, <String, Object?>{
                'category': categoryController.text.trim(),
                'content': content,
                'triggers': triggersController.text.trim(),
              });
            },
            child: Text(L.pick(en: 'Save preview', zhTW: '儲存預覽', zhCN: '保存预览')),
          ),
        ],
      ),
    );
    categoryController.dispose();
    contentController.dispose();
    triggersController.dispose();
    if (result != null && mounted) {
      setState(() => _editedMergePreviews[proposal.id] = result);
    }
    return result;
  }

  Map<String, Object?> _effectiveMergePreview(MemoryActionProposal proposal) =>
      <String, Object?>{
        ...proposal.mergePreview,
        ...?_editedMergePreviews[proposal.id],
      };

  Future<bool> _confirmPermanentProposal(String action) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: YanciTheme.surfacePanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            L.pick(
              en: 'Permanent memory protection',
              zhTW: '永久記憶保護',
              zhCN: '永久记忆保护',
            ),
            style: YanciTheme.headingMedium,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.pick(
                  en: 'You are about to $action. Type PERMANENT to confirm this second step.',
                  zhTW: '你即將$action。請輸入 PERMANENT 完成第二次確認。',
                  zhCN: '你即将$action。请输入 PERMANENT 完成第二次确认。',
                ),
                style: YanciTheme.bodyText,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'PERMANENT'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
            ),
            FilledButton.tonal(
              onPressed: controller.text.trim() == 'PERMANENT'
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(L.pick(en: 'Confirm', zhTW: '確認', zhCN: '确认')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result ?? false;
  }

  Future<void> _run(String id, Future<void> Function() operation) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      await operation();
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _reload();
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final visible = _visible;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 92),
        children: [
          if (widget.sourceMessageId != null) _buildSourceFilter(),
          if (visible.isEmpty)
            _buildEmptyState(sourceFiltered: _showOnlySource)
          else
            for (final proposal in visible) _buildProposalCard(proposal),
        ],
      ),
    );
  }

  Widget _buildSourceFilter() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 15,
            color: YanciTheme.textSecondary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              _showOnlySource
                  ? L.pick(
                      en: 'This reply + on-device checks',
                      zhTW: '這則回覆＋本機檢查',
                      zhCN: '这则回复＋本机检查',
                    )
                  : L.pick(en: 'Showing all proposals', zhTW: '顯示所有提案'),
              style: YanciTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _showOnlySource = !_showOnlySource),
            child: Text(
              _showOnlySource
                  ? L.pick(en: 'Show all', zhTW: '顯示全部')
                  : L.pick(en: 'This reply', zhTW: '這則回覆'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({required bool sourceFiltered}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 330),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_outlined,
              size: 34,
              color: YanciTheme.textSecondary.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 12),
            Text(
              sourceFiltered && widget.sourceMessageId != null
                  ? L.pick(
                      en: 'No proposal from this reply or on-device checks',
                      zhTW: '這則回覆與本機檢查沒有待確認提案',
                      zhCN: '这则回复与本机检查没有待确认提案',
                    )
                  : L.pick(en: 'Nothing needs review', zhTW: '目前沒有待確認提案'),
              style: YanciTheme.bodyText,
            ),
            const SizedBox(height: 6),
            Text(
              L.pick(
                en: 'Model suggestions never change existing memories until you approve them.',
                zhTW: '模型建議在你確認前，不會改動現有記憶。',
              ),
              textAlign: TextAlign.center,
              style: YanciTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProposalCard(MemoryActionProposal proposal) {
    final isBusy = _busyId == proposal.id;
    final isCreate = proposal.action == MemoryActionProposal.actionCreate;
    final isMerge = proposal.action == MemoryActionProposal.actionMerge;
    final isLink = proposal.action == MemoryActionProposal.actionLink;
    final disabled = isBusy || !proposal.canExecute;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: YanciTheme.surfacePanel.withValues(alpha: 0.82),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _statusColor(proposal).withValues(alpha: 0.28),
          width: 0.7,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _statusColor(proposal).withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    isCreate
                        ? Icons.compare_arrows_rounded
                        : isLink
                        ? Icons.hub_outlined
                        : isMerge
                        ? proposal.isExistingDuplicateScan
                              ? Icons.filter_none_rounded
                              : Icons.merge_rounded
                        : Icons.archive_outlined,
                    size: 18,
                    color: _statusColor(proposal),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isCreate
                            ? L.pick(
                                en: 'Possible duplicate memory',
                                zhTW: '疑似重複記憶',
                                zhCN: '疑似重复记忆',
                              )
                            : isLink
                            ? L.pick(
                                en: 'Connect ${proposal.targetIds.length} memories',
                                zhTW: '連線 ${proposal.targetIds.length} 條相關記憶',
                                zhCN: '连线 ${proposal.targetIds.length} 条相关记忆',
                              )
                            : isMerge
                            ? proposal.isExistingDuplicateScan
                                  ? L.pick(
                                      en: 'Existing duplicate candidate',
                                      zhTW: '既有記憶疑似重複',
                                      zhCN: '既有记忆疑似重复',
                                    )
                                  : L.pick(
                                      en: 'Merge ${proposal.targetIds.length} memories',
                                      zhTW:
                                          '合併 ${proposal.targetIds.length} 條記憶',
                                    )
                            : L.pick(
                                en: 'Archive ${proposal.targetIds.length} memories',
                                zhTW: '移動 ${proposal.targetIds.length} 條記憶到回收區',
                              ),
                        style: YanciTheme.bodyText.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _statusLabel(proposal),
                        style: TextStyle(
                          fontSize: 11,
                          color: _statusColor(proposal),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isBusy)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (isCreate) ...[
              _sectionLabel(L.pick(en: 'EXISTING', zhTW: '現有記憶', zhCN: '现有记忆')),
              const SizedBox(height: 6),
            ],
            for (final target in proposal.targetSnapshots) _buildTarget(target),
            if (isCreate) ...[
              _buildCandidatePreview(proposal),
              _buildDuplicateEvidence(proposal),
              _buildMergePreview(proposal),
            ] else if (isMerge) ...[
              if (proposal.duplicateScore > 0)
                _buildDuplicateEvidence(proposal),
              _buildMergePreview(proposal),
            ],
            if (proposal.error.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                proposal.error,
                style: TextStyle(fontSize: 11, color: Colors.red.shade300),
              ),
            ],
            const SizedBox(height: 8),
            if (proposal.isStale)
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => _discardStaleProposal(proposal),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    foregroundColor: Colors.red.shade300,
                    side: BorderSide(
                      color: Colors.red.shade300.withValues(alpha: 0.5),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(
                    L.pick(en: 'Delete proposal', zhTW: '刪除提案', zhCN: '删除提案'),
                  ),
                ),
              )
            else if (isCreate)
              _buildCreateActions(proposal, disabled: disabled, isBusy: isBusy)
            else
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: isBusy ? null : () => _reject(proposal),
                    child: Text(
                      isMerge
                          ? L.pick(
                              en: 'Keep separate',
                              zhTW: '保留原狀',
                              zhCN: '保留原状',
                            )
                          : isLink
                          ? L.pick(
                              en: 'Do not connect',
                              zhTW: '不建立連線',
                              zhCN: '不建立连线',
                            )
                          : L.pick(en: 'Reject', zhTW: '拒絕', zhCN: '拒绝'),
                    ),
                  ),
                  if (proposal.status == MemoryActionProposal.statusPending)
                    TextButton(
                      onPressed: isBusy ? null : () => _snooze(proposal),
                      child: Text(
                        isLink
                            ? L.pick(
                                en: 'Move to relation suggestions',
                                zhTW: '移到關係建議',
                                zhCN: '移到关系建议',
                              )
                            : L.pick(en: 'Later', zhTW: '稍後', zhCN: '稍后'),
                      ),
                    ),
                  FilledButton.tonal(
                    onPressed: disabled ? null : () => _accept(proposal),
                    child: Text(
                      isMerge
                          ? L.pick(
                              en: 'Review & merge',
                              zhTW: '確認合併',
                              zhCN: '确认合并',
                            )
                          : isLink
                          ? L.pick(
                              en: 'Confirm links',
                              zhTW: '確認連線',
                              zhCN: '确认连线',
                            )
                          : L.pick(
                              en: 'Review & archive',
                              zhTW: '確認移除',
                              zhCN: '确认移除',
                            ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateActions(
    MemoryActionProposal proposal, {
    required bool disabled,
    required bool isBusy,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (proposal.status == MemoryActionProposal.statusPending)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: isBusy ? null : () => _snooze(proposal),
              child: Text(L.pick(en: 'Later', zhTW: '稍後', zhCN: '稍后')),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: disabled ? null : () => _keepExisting(proposal),
              style: FilledButton.styleFrom(minimumSize: const Size(112, 44)),
              child: Text(
                L.pick(en: 'Keep existing', zhTW: '保留舊條', zhCN: '保留旧条'),
              ),
            ),
            OutlinedButton(
              onPressed: disabled ? null : () => _useNewCandidate(proposal),
              style: OutlinedButton.styleFrom(minimumSize: const Size(104, 44)),
              child: Text(L.pick(en: 'Use new', zhTW: '使用新條', zhCN: '使用新条')),
            ),
            OutlinedButton.icon(
              onPressed: disabled ? null : () => _mergeCandidate(proposal),
              style: OutlinedButton.styleFrom(minimumSize: const Size(96, 44)),
              icon: const Icon(Icons.merge_rounded, size: 17),
              label: Text(L.pick(en: 'Merge', zhTW: '合併', zhCN: '合并')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTarget(Map<String, dynamic> target) {
    final id = target['id'];
    final category = target['category']?.toString() ?? '';
    final content = target['content']?.toString() ?? '';
    final permanent = target['permanent'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              permanent ? Icons.lock_outline_rounded : Icons.circle,
              size: permanent ? 13 : 6,
              color: YanciTheme.textSecondary.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '#$id${category.isEmpty ? '' : ' · $category'}  $content',
              style: YanciTheme.bodySmall.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 9,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
        color: YanciTheme.textSecondary,
      ),
    );
  }

  Widget _buildCandidatePreview(MemoryActionProposal proposal) {
    final candidate = proposal.candidatePreview;
    final category = candidate['category']?.toString() ?? '';
    final content = candidate['content']?.toString() ?? '';
    final triggers = candidate['triggers']?.toString() ?? '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 5),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: YanciTheme.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.16),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(
            L.pick(en: 'NEW CANDIDATE', zhTW: '候選新記憶', zhCN: '候选新记忆'),
          ),
          const SizedBox(height: 5),
          Text(
            '[${category.isEmpty ? L.pick(en: 'Memory', zhTW: '記憶', zhCN: '记忆') : category}] $content',
            style: YanciTheme.bodySmall.copyWith(height: 1.45),
          ),
          if (triggers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('@$triggers', style: YanciTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _buildDuplicateEvidence(MemoryActionProposal proposal) {
    final percent = (proposal.duplicateScore * 100).round().clamp(0, 100);
    final reasons = proposal.duplicateReasons;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: YanciTheme.textSecondary.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.rule_rounded,
                size: 15,
                color: YanciTheme.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  L.pick(
                    en: 'Local duplicate score: $percent%',
                    zhTW: '本地重複判定：$percent%',
                    zhCN: '本地重复判定：$percent%',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 5),
            for (final reason in reasons.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• ${_duplicateReasonLabel(reason)}',
                  style: YanciTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _duplicateReasonLabel(String reason) {
    if (reason.startsWith('content_similarity:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'Content similarity $value%',
        zhTW: '正文相似 $value%',
        zhCN: '正文相似 $value%',
      );
    }
    if (reason.startsWith('trigger_overlap:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'Trigger overlap $value%',
        zhTW: '觸發詞重疊 $value%',
        zhCN: '触发词重叠 $value%',
      );
    }
    if (reason.startsWith('model_relation:')) {
      final value = reason.split(':').last;
      return L.pick(
        en: 'Summary-model confidence $value%',
        zhTW: '摘要模型信心 $value%',
        zhCN: '摘要模型置信度 $value%',
      );
    }
    return switch (reason) {
      'exact_content' => L.pick(
        en: 'Content is identical after normalization',
        zhTW: '內容正規化後完全一致',
        zhCN: '内容正规化后完全一致',
      ),
      'same_category' => L.pick(
        en: 'Same category',
        zhTW: '類別相同',
        zhCN: '类别相同',
      ),
      'negation_conflict' => L.pick(
        en: 'Negation differs · never skipped automatically',
        zhTW: '否定語意不同 · 禁止自動略過',
        zhCN: '否定语意不同 · 禁止自动略过',
      ),
      'state_conflict' => L.pick(
        en: 'State transition differs · never skipped automatically',
        zhTW: '狀態變化不同 · 禁止自動略過',
        zhCN: '状态变化不同 · 禁止自动略过',
      ),
      'number_conflict' => L.pick(
        en: 'Date or number differs · never skipped automatically',
        zhTW: '日期或數字不同 · 禁止自動略過',
        zhCN: '日期或数字不同 · 禁止自动略过',
      ),
      'permanent_conflict' => L.pick(
        en: 'Permanent-memory state differs',
        zhTW: '永久記憶狀態不同',
        zhCN: '永久记忆状态不同',
      ),
      _ => reason,
    };
  }

  Widget _buildMergePreview(MemoryActionProposal proposal) {
    final preview = _effectiveMergePreview(proposal);
    final category = preview['category']?.toString() ?? '';
    final content = preview['content']?.toString() ?? '';
    final triggers = preview['triggers']?.toString() ?? '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 5),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: YanciTheme.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'MERGED PREVIEW', zhTW: '合併後預覽'),
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                    color: YanciTheme.accent,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _busyId == null
                    ? () => _editMergePreview(proposal)
                    : null,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: Text(
                  L.pick(en: 'Edit preview', zhTW: '編輯預覽', zhCN: '编辑预览'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '[${category.isEmpty ? L.pick(en: 'Memory', zhTW: '記憶') : category}] $content',
            style: YanciTheme.bodySmall.copyWith(height: 1.45),
          ),
          if (triggers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('@$triggers', style: YanciTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  String _statusLabel(MemoryActionProposal proposal) {
    return switch (proposal.status) {
      MemoryActionProposal.statusSnoozed => L.pick(
        en: 'Saved for later',
        zhTW: '已放到稍後',
      ),
      MemoryActionProposal.statusStale => L.pick(
        en: 'Memory changed · review required',
        zhTW: '記憶已變動 · 需重新檢查',
      ),
      MemoryActionProposal.statusFailed => L.pick(
        en: 'Apply failed · no memory was lost',
        zhTW: '套用失敗 · 記憶未丟失',
      ),
      _ when proposal.action == MemoryActionProposal.actionCreate => L.pick(
        en: 'Held by the local duplicate guard · not saved yet',
        zhTW: '本地去重防護攔下 · 尚未寫入',
        zhCN: '本地去重防护拦下 · 尚未写入',
      ),
      _ when proposal.isExistingDuplicateScan => L.pick(
        en: 'Found by the local existing-memory scan · no change applied',
        zhTW: '本地既有記憶掃描發現 · 尚未改動',
        zhCN: '本地既有记忆扫描发现 · 尚未改动',
      ),
      _ => L.pick(
        en: 'Suggested by the model',
        zhTW: '模型提出的建議',
        zhCN: '模型提出的建议',
      ),
    };
  }

  Color _statusColor(MemoryActionProposal proposal) {
    return switch (proposal.status) {
      MemoryActionProposal.statusStale => Colors.orange.shade400,
      MemoryActionProposal.statusFailed => Colors.red.shade300,
      MemoryActionProposal.statusSnoozed => YanciTheme.textSecondary,
      _ => YanciTheme.accent,
    };
  }
}
