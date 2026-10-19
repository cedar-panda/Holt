// ignore_for_file: invalid_use_of_protected_member

part of 'memory_screen.dart';

extension _MemoryArchiveMethods on _MemoryScreenState {
  void _showArchive() async {
    final archived = await DatabaseHelper.getArchivedMemories(
      characterId: _characterId,
      contextMode: widget.contextMode,
      continuityId: widget.continuityId,
    );
    final selectedArchiveIds = <int>{};
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.isDark
                  ? const Color(0xFF1a1520).withValues(alpha: 0.98)
                  : Colors.white.withValues(alpha: 0.98),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(YanciTheme.radiusLg),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  L.pick(en: 'Dusty Box', zhTW: '積灰小盒子'),
                  style: YanciTheme.headingMedium,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Text(
                        '${archived.length} ${L.pick(en: 'items', zhTW: '條', zhCN: '条')}',
                        style: YanciTheme.bodySmall,
                      ),
                      const Spacer(),
                      if (archived.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              if (selectedArchiveIds.length ==
                                  archived.length) {
                                selectedArchiveIds.clear();
                              } else {
                                selectedArchiveIds
                                  ..clear()
                                  ..addAll(
                                    archived.map((row) => row['id'] as int),
                                  );
                              }
                            });
                          },
                          child: Text(
                            selectedArchiveIds.length == archived.length
                                ? L.pick(
                                    en: 'Clear selection',
                                    zhTW: '取消全選',
                                    zhCN: '取消全选',
                                  )
                                : L.pick(
                                    en: 'Select all',
                                    zhTW: '全選',
                                    zhCN: '全选',
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (selectedArchiveIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              final count =
                                  await DatabaseHelper.restoreFromArchives(
                                    selectedArchiveIds,
                                    characterId: _characterId,
                                  );
                              archived.removeWhere(
                                (row) => selectedArchiveIds.contains(row['id']),
                              );
                              setSheetState(selectedArchiveIds.clear);
                              await _loadMemories();
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    L.pick(
                                      en: '$count memories restored',
                                      zhTW: '已恢復 $count 條記憶',
                                      zhCN: '已恢复 $count 条记忆',
                                    ),
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.restore_rounded, size: 17),
                            label: Text(
                              L.pick(en: 'Restore', zhTW: '批量恢復', zhCN: '批量恢复'),
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(44),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final confirm = await _confirmDelete(
                                L.pick(
                                  en: 'Permanently delete ${selectedArchiveIds.length} selected archived memories? This cannot be undone.',
                                  zhTW:
                                      '永久刪除選取的 ${selectedArchiveIds.length} 條封存記憶？此操作無法復原。',
                                  zhCN:
                                      '永久删除选中的 ${selectedArchiveIds.length} 条归档记忆？此操作无法恢复。',
                                ),
                              );
                              if (!confirm) return;
                              final ids = Set<int>.from(selectedArchiveIds);
                              await DatabaseHelper.permanentlyDeleteArchives(
                                ids,
                                characterId: _characterId,
                              );
                              archived.removeWhere(
                                (row) => ids.contains(row['id']),
                              );
                              setSheetState(selectedArchiveIds.clear);
                              await _loadMemories();
                            },
                            icon: const Icon(
                              Icons.delete_forever_rounded,
                              size: 17,
                            ),
                            label: Text(
                              L.pick(en: 'Delete', zhTW: '永久刪除', zhCN: '永久删除'),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(44),
                              foregroundColor: Colors.red.shade400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: archived.isEmpty
                      ? Center(
                          child: Text(
                            L.pick(
                              en: 'The dusty box is empty. Nice.',
                              zhTW: '小盒子是空的，挺好。',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: archived.length,
                          itemBuilder: (ctx, i) {
                            final a = archived[i];
                            // 從 content_snapshot 解析原始記憶
                            Map<String, dynamic> snapshot = {};
                            try {
                              snapshot = jsonDecode(
                                a['content_snapshot'] as String? ?? '{}',
                              );
                            } catch (_) {}
                            final category =
                                snapshot['category'] as String? ?? '';
                            final content =
                                snapshot['content'] as String? ?? '';
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: YanciTheme.isDark
                                    ? Colors.white.withValues(alpha: 0.05)
                                    : Colors.grey.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(
                                  YanciTheme.radiusSm,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      SizedBox.square(
                                        dimension: 44,
                                        child: Checkbox(
                                          value: selectedArchiveIds.contains(
                                            a['id'],
                                          ),
                                          onChanged: (selected) {
                                            setSheetState(() {
                                              final id = a['id'] as int;
                                              if (selected == true) {
                                                selectedArchiveIds.add(id);
                                              } else {
                                                selectedArchiveIds.remove(id);
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.withValues(
                                            alpha: 0.15,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          category,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: YanciTheme.textSecondary,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      if (a['reason'] != null)
                                        Text(
                                          a['reason'] as String,
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: YanciTheme.textSecondary
                                                .withValues(alpha: 0.4),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    content,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: YanciTheme.textSecondary,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      // 恢復
                                      GestureDetector(
                                        onTap: () async {
                                          final id = a['id'] as int;
                                          final restored =
                                              await DatabaseHelper.restoreFromArchive(
                                                id,
                                                characterId: _characterId,
                                              );
                                          if (restored) {
                                            selectedArchiveIds.remove(id);
                                            archived.removeAt(i);
                                            setSheetState(() {});
                                            _loadMemories();
                                          } else {
                                            if (mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    L.pick(
                                                      en: 'Original memory not found',
                                                      zhTW: '原始記憶已不存在，無法恢復',
                                                    ),
                                                  ),
                                                  backgroundColor: Colors.orange
                                                      .withValues(alpha: 0.7),
                                                  behavior:
                                                      SnackBarBehavior.floating,
                                                  duration: const Duration(
                                                    milliseconds: 1500,
                                                  ),
                                                  margin: const EdgeInsets.only(
                                                    bottom: 80,
                                                    left: 16,
                                                    right: 16,
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: YanciTheme.accent.withValues(
                                              alpha: 0.1,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.restore_rounded,
                                                size: 14,
                                                color: YanciTheme.accent
                                                    .withValues(alpha: 0.6),
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                L.pick(
                                                  en: 'Restore',
                                                  zhTW: '恢復',
                                                ),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: YanciTheme.accent
                                                      .withValues(alpha: 0.7),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // 永久刪除
                                      GestureDetector(
                                        onTap: () async {
                                          final confirm = await _confirmDelete(
                                            L.pick(
                                              en: 'Permanently delete?',
                                              zhTW: '永久刪除？',
                                            ),
                                          );
                                          if (confirm) {
                                            await DatabaseHelper.permanentlyDelete(
                                              a['id'] as int,
                                              characterId: _characterId,
                                            );
                                            archived.removeAt(i);
                                            setSheetState(() {});
                                            _loadMemories();
                                          }
                                        },
                                        child: Icon(
                                          Icons.delete_outline_rounded,
                                          size: 16,
                                          color: Colors.red.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(String message) async {
    final ctrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: YanciTheme.bodyText.copyWith(fontSize: 14),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  onChanged: (v) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: L.pick(
                      en: 'Type "DELETE" to confirm',
                      zhTW: '請輸入 DELETE 以確認',
                    ),
                    hintStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  L.pick(en: 'Cancel', zhTW: '取消'),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ),
              TextButton(
                onPressed: ctrl.text.trim() == 'DELETE'
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(
                  L.pick(en: 'Delete', zhTW: '刪除'),
                  style: TextStyle(
                    color: ctrl.text.trim() == 'DELETE'
                        ? Colors.red.withValues(alpha: 0.7)
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return result ?? false;
  }
}
