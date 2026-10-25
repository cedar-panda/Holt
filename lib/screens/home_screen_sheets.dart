// ignore_for_file: invalid_use_of_protected_member

part of 'home_screen.dart';

String _formatNoteTimestamp(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return '';
  final parsed = DateTime.tryParse(value)?.toLocal();
  if (parsed != null) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(parsed.month)}/${twoDigits(parsed.day)} '
        '${twoDigits(parsed.hour)}:${twoDigits(parsed.minute)}';
  }
  final friendly = value.replaceFirst('T', ' ');
  return friendly.length <= 16 ? friendly : friendly.substring(0, 16);
}

extension _HomeSheetMethods on _HomeScreenState {
  double get _homeCarouselOffsetY => _HomeScreenState._homeCarouselOffsetY;

  void _showNotesSheet() {
    final characterId = _activeCharacterId;
    final ctrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: YanciTheme.surfacePanel.withValues(alpha: 0.98),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YanciTheme.radiusSheet),
                ),
                border: Border(
                  top: BorderSide(color: YanciTheme.glassBorder, width: 0.5),
                ),
              ),
              padding: const EdgeInsets.all(YanciTheme.spacingMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  Row(
                    children: [
                      Icon(
                        Icons.sticky_note_2_outlined,
                        size: 16,
                        color: YanciTheme.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        L.get('note_title'),
                        style: YanciTheme.headingMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          autofocus: true,
                          style: YanciTheme.bodyText.copyWith(fontSize: 14),
                          decoration: YanciTheme.themedInputDecoration(
                            hintText: L.pick(
                              en: 'Write something…',
                              zhTW: '寫點什麼……',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          await DatabaseHelper.addNote(
                            ctrl.text.trim(),
                            characterId: characterId,
                          );
                          ctrl.clear();
                          if (characterId == _activeCharacterId) {
                            _loadLatestNote(characterId: characterId);
                          }
                          setSheetState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: YanciTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(
                              YanciTheme.radiusSm,
                            ),
                          ),
                          child: Icon(
                            Icons.send_rounded,
                            size: 18,
                            color: YanciTheme.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: DatabaseHelper.getNotes(
                      limit: 10,
                      characterId: characterId,
                    ),
                    builder: (ctx, snap) {
                      if (!snap.hasData || snap.data!.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(YanciTheme.spacingMd),
                          child: Text(
                            L.get('note_empty'),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        );
                      }
                      return Column(
                        children: snap.data!.map((n) {
                          return Dismissible(
                            key: ValueKey(n['id']),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: Icon(
                                Icons.delete_outline,
                                size: 16,
                                color: Colors.red.withValues(alpha: 0.5),
                              ),
                            ),
                            onDismissed: (_) {
                              final id = n['id'] as int;
                              DatabaseHelper.deleteNote(id).then((_) {
                                if (characterId == _activeCharacterId) {
                                  _loadLatestNote(characterId: characterId);
                                }
                                setSheetState(() {});
                              });
                            },
                            child: Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: YanciTheme.aiBubble.withValues(
                                  alpha: 0.3,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      n['content'] as String,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _formatNoteTimestamp(n['created_at']),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.35),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showConversationList() async {
    final charId = _activeCharacterId;
    final allConversations = await DatabaseHelper.getConversations(
      characterId: charId,
    );
    var historyFilter = await ContextModeSettings.historyFilter(charId);
    if (!mounted) return;

    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final safeH = MediaQuery.of(context).size.height - topPad - bottomPad;
    // 與 _buildHomePage 一致：歷史浮層隨輪盤下移，保留原有間距。
    final visibleH = safeH - 66.0;
    final carouselBottom =
        topPad + visibleH / 3 + 28 + 12 + _homeCarouselOffsetY;
    final topInset = carouselBottom;
    // 底部：菜單欄高度(66) + 底部 padding + 菜單上方間距
    final bottomInset = 66.0 + (bottomPad > 0 ? bottomPad : 16.0) + 12.0;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'history',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (_, anim, _, child) {
        final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curve, child: child);
      },
      pageBuilder: (dialogCtx, _, _) {
        var searchResults = List<Conversation>.from(allConversations);
        var conversations = ContextModeSettings.filterConversations(
          searchResults,
          historyFilter,
        );
        final searchCtrl = TextEditingController();
        // 搜尋世代號：每字一查是 async 的，慢的舊查詢後到會把
        // 新結果覆蓋回去——只採納最新一代的結果
        var searchGeneration = 0;

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final historySurface = YanciTheme.isDark
                ? const Color(0xF5201D24)
                : Colors.white.withValues(alpha: 0.97);
            return Padding(
              padding: EdgeInsets.only(
                top: topInset,
                bottom: bottomInset,
                left: 24,
                right: 24,
              ),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: historySurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.7),
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: YanciTheme.isDark ? 0.4 : 0.12,
                        ),
                        blurRadius: 32,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                        // ── 頂部：退出 + 標題 ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 10, 16, 0),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () => Navigator.pop(dialogCtx),
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                L.get('history_title'),
                                style: YanciTheme.headingMedium.copyWith(
                                  fontSize: 15,
                                ),
                              ),
                              const Spacer(),
                              HistoryModePill(
                                value: historyFilter.name,
                                backgroundColor: historySurface,
                                onChanged: (raw) {
                                  final next = ConversationHistoryFilter.values
                                      .firstWhere((value) => value.name == raw);
                                  setDialogState(() {
                                    historyFilter = next;
                                    conversations =
                                        ContextModeSettings.filterConversations(
                                          searchResults,
                                          next,
                                        );
                                  });
                                  unawaited(
                                    ContextModeSettings.setHistoryFilter(
                                      charId,
                                      next,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),

                        // ── 搜索框 ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                          child: Container(
                            height: 38,
                            decoration: BoxDecoration(
                              color: YanciTheme.isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.grey.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: searchCtrl,
                              style: YanciTheme.bodyText.copyWith(fontSize: 13),
                              decoration: InputDecoration(
                                hintText: L.pick(en: 'Search…', zhTW: '搜索……'),
                                hintStyle: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.35,
                                  ),
                                  fontSize: 13,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  size: 18,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                              ),
                              onChanged: (query) async {
                                final gen = ++searchGeneration;
                                final q = query.trim();
                                final results = q.isEmpty
                                    ? await DatabaseHelper.getConversations(
                                        characterId: charId,
                                      )
                                    : await DatabaseHelper.searchConversations(
                                        q,
                                        characterId: charId,
                                      );
                                // 已有更新的輸入 → 這批結果過期，丟棄
                                if (gen != searchGeneration) return;
                                setDialogState(() {
                                  searchResults = List.from(results);
                                  conversations =
                                      ContextModeSettings.filterConversations(
                                        searchResults,
                                        historyFilter,
                                      );
                                });
                              },
                            ),
                          ),
                        ),

                        // ── 對話列表 ──
                        if (conversations.isEmpty)
                          Expanded(
                            child: Center(
                              child: Text(
                                L.get('history_empty'),
                                textAlign: TextAlign.center,
                                style: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Expanded(
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              itemCount: conversations.length,
                              itemBuilder: (listCtx, i) {
                                final conv = conversations[i];
                                final dateStr = conv.updatedAt
                                    .toIso8601String()
                                    .substring(0, 16)
                                    .replaceAll('T', ' ');
                                return InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () async {
                                    Navigator.pop(dialogCtx);
                                    await _pushChatRoute(
                                      arguments: conv.id,
                                      restoreCharacterId: charId,
                                    );
                                    await _refreshAfterChatReturn();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        // 星標指示
                                        if (conv.isStarred)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: Icon(
                                              Icons.star_rounded,
                                              size: 14,
                                              color: YanciTheme.accent
                                                  .withValues(alpha: 0.7),
                                            ),
                                          ),
                                        // 標題+日期
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  ContextModeLabel(
                                                    mode: conv.contextMode,
                                                    compact: true,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      conv.title ??
                                                          L.pick(
                                                            en: 'New chat',
                                                            zhTW: '新對話',
                                                          ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: YanciTheme.bodyText
                                                          .copyWith(
                                                            fontSize: 14,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                dateStr,
                                                style: YanciTheme.bodySmall
                                                    .copyWith(
                                                      color: YanciTheme
                                                          .textSecondary
                                                          .withValues(
                                                            alpha: 0.45,
                                                          ),
                                                      fontSize: 11,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // ── 操作按鈕（加大點擊範圍 44×44）──
                                        _historyAction(
                                          icon: Icons.edit_outlined,
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.4),
                                          onTap: () =>
                                              _editConversationTitle(conv),
                                        ),
                                        _historyAction(
                                          icon: conv.isStarred
                                              ? Icons.star_rounded
                                              : Icons.star_border_rounded,
                                          color: conv.isStarred
                                              ? YanciTheme.accent
                                              : YanciTheme.textSecondary
                                                    .withValues(alpha: 0.4),
                                          onTap: () async {
                                            await DatabaseHelper.toggleStarConversation(
                                              conv.id,
                                              !conv.isStarred,
                                            );
                                            final updated =
                                                await DatabaseHelper.getConversations(
                                                  characterId: charId,
                                                );
                                            setDialogState(() {
                                              searchResults = List.from(
                                                updated,
                                              );
                                              conversations =
                                                  ContextModeSettings.filterConversations(
                                                    searchResults,
                                                    historyFilter,
                                                  );
                                            });
                                          },
                                        ),
                                        _historyAction(
                                          icon: Icons.delete_outline_rounded,
                                          color: Colors.red.withValues(
                                            alpha: 0.4,
                                          ),
                                          onTap: () async {
                                            final confirm = await showDialog<bool>(
                                              context: listCtx,
                                              builder: (dlgCtx) => AlertDialog(
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        YanciTheme.radiusMd,
                                                      ),
                                                ),
                                                backgroundColor:
                                                    YanciTheme.surfacePanel,
                                                content: Text(
                                                  L.pick(
                                                    en: 'Delete this conversation?',
                                                    zhTW: '確認刪除這段對話？',
                                                  ),
                                                  style: YanciTheme.bodyText
                                                      .copyWith(fontSize: 14),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                          dlgCtx,
                                                          false,
                                                        ),
                                                    child: Text(
                                                      L.get('cancel'),
                                                      style: TextStyle(
                                                        color: YanciTheme
                                                            .textSecondary,
                                                      ),
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                          dlgCtx,
                                                          true,
                                                        ),
                                                    child: Text(
                                                      L.get('confirm_delete'),
                                                      style: TextStyle(
                                                        color: Colors.red
                                                            .withValues(
                                                              alpha: 0.7,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              if (KeepAliveService
                                                      .instance
                                                      .activeConversationId ==
                                                  conv.id) {
                                                await KeepAliveService.instance
                                                    .stop();
                                              }
                                              await DatabaseHelper.deleteConversation(
                                                conv.id,
                                              );
                                              final updated =
                                                  await DatabaseHelper.getConversations(
                                                    characterId: charId,
                                                  );
                                              setDialogState(() {
                                                searchResults = List.from(
                                                  updated,
                                                );
                                                conversations =
                                                    ContextModeSettings.filterConversations(
                                                      searchResults,
                                                      historyFilter,
                                                    );
                                              });
                                            }
                                          },
                                        ),
                                      ],
                                    ),
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
          },
        );
      },
    );
  }

  Widget _historyAction({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(icon, size: 18, color: color)),
      ),
    );
  }

  void _editConversationTitle(Conversation conv) {
    final ctrl = TextEditingController(text: conv.title ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSheet),
          side: BorderSide(color: YanciTheme.glassBorder, width: 0.5),
        ),
        title: Text(
          L.get('history_edit_title'),
          style: YanciTheme.headingMedium,
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: YanciTheme.bodyText,
          decoration: YanciTheme.themedInputDecoration(
            hintText: L.pick(en: 'Enter a title…', zhTW: '輸入標題……'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final title = ctrl.text.trim();
              if (title.isNotEmpty) {
                await DatabaseHelper.updateConversation(conv.id, title: title);
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              // 重新加載歷史列表
              if (!mounted) return;
              Navigator.pop(context);
              _showConversationList();
            },
            child: Text(
              L.get('confirm_ok'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }
}
