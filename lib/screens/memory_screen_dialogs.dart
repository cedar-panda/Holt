// ignore_for_file: invalid_use_of_protected_member

part of 'memory_screen.dart';

extension _MemoryDialogMethods on _MemoryScreenState {
  void _showAddMemoryDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ManagedTextControllers(
        initialValues: <String>[
          L.pick(en: 'Important Event', zhTW: '重要事件'),
          '',
          '',
        ],
        builder: (ctx, controllers) => AlertDialog(
          backgroundColor: YanciTheme.surfacePanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            L.pick(en: 'Write a memory', zhTW: '寫入記憶'),
            style: YanciTheme.headingMedium,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controllers[0],
                  style: YanciTheme.bodyText,
                  decoration: InputDecoration(
                    labelText: L.pick(
                      en: 'Category',
                      zhTW: '類別（關係/偏好/約定/習慣/重要事件）',
                    ),
                    labelStyle: YanciTheme.bodySmall,
                  ),
                ),
                TextField(
                  controller: controllers[1],
                  maxLines: 3,
                  style: YanciTheme.bodyText,
                  decoration: InputDecoration(
                    labelText: L.pick(
                      en: 'Content ("I" = char, "you" = user)',
                      zhTW: '內容（「我」= 角色，「你」= 用戶）',
                    ),
                    labelStyle: YanciTheme.bodySmall,
                  ),
                ),
                TextField(
                  controller: controllers[2],
                  style: YanciTheme.bodyText,
                  decoration: InputDecoration(
                    labelText: L.pick(
                      en: 'Triggers (comma separated, optional)',
                      zhTW: '觸發詞（逗號分隔，可空）',
                    ),
                    labelStyle: YanciTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                L.pick(en: 'Cancel', zhTW: '取消'),
                style: TextStyle(color: YanciTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () async {
                final content = controllers[1].text.trim();
                if (content.isEmpty) return;
                final result = await MemoryGuardService.guardNewMemory(
                  candidate: Memory(
                    characterId: _characterId,
                    contextMode:
                        widget.contextMode ??
                        await ContextModeSettings.effectiveMode(_characterId),
                    continuityId: _rpStorylineScope
                        ? widget.continuityId
                        : 'main',
                    mode: await _bucket(),
                    category: controllers[0].text.trim().isEmpty
                        ? (L.pick(en: 'Important Event', zhTW: '重要事件'))
                        : controllers[0].text.trim(),
                    content: content,
                    confidence: 'high',
                    triggers: controllers[2].text.trim(),
                  ),
                  source: 'memory_ui',
                );
                debugPrint(
                  '[MemoryAddDebug] character=$_characterId '
                  'result=${result.disposition.name}',
                );
                if (!ctx.mounted || !mounted) return;
                Navigator.pop(ctx);
                if (result.disposition ==
                    GuardedMemoryWriteDisposition.proposalCreated) {
                  setState(() {
                    _tabIndex = 1;
                    _isGraphView = false;
                  });
                }
                await _loadMemories();
                await _refreshReviewCounts();
                if (!mounted) return;
                final message = switch (result.disposition) {
                  GuardedMemoryWriteDisposition.inserted => L.pick(
                    en: 'Memory saved',
                    zhTW: '記憶已保存',
                    zhCN: '记忆已保存',
                  ),
                  GuardedMemoryWriteDisposition.skippedDuplicate => L.pick(
                    en: 'An equivalent memory already exists, so no duplicate was added',
                    zhTW: '已有等價記憶，未新增重複條目',
                    zhCN: '已有等价记忆，未新增重复条目',
                  ),
                  GuardedMemoryWriteDisposition.proposalCreated => L.pick(
                    en: 'Possible duplicate found. Review it before saving.',
                    zhTW: '發現疑似重複，已送到待確認提案',
                    zhCN: '发现疑似重复，已送到待确认提案',
                  ),
                };
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(message)));
              },
              child: Text(
                L.pick(en: 'Save', zhTW: '保存'),
                style: TextStyle(
                  color: YanciTheme.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBudgetSettings() async {
    var budget = await MemorySettings.getMemBudgetTotal();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? const Color(0xFF1a1520).withValues(alpha: 0.98)
                : Colors.white.withValues(alpha: 0.98),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(YanciTheme.radiusLg),
            ),
          ),
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
              const SizedBox(height: 20),
              Text(
                L.pick(en: 'Memory Token Budget', zhTW: '記憶注入預算'),
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 4),
              Text(
                L.pick(
                  en: 'How many tokens of memory to inject per turn',
                  zhTW: '每輪注入多少 token 的記憶',
                ),
                style: YanciTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    '${budget}t',
                    style: YanciTheme.headingMedium.copyWith(
                      color: YanciTheme.accent,
                      fontSize: 20,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    L.pick(
                      en: 'Current: ≈${_totalTokens}t used',
                      zhTW: '目前 ≈${_totalTokens}t',
                    ),
                    style: YanciTheme.bodySmall.copyWith(
                      color: _totalTokens > budget
                          ? Colors.orange
                          : YanciTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.6),
                  inactiveTrackColor: YanciTheme.accent.withValues(alpha: 0.15),
                  thumbColor: YanciTheme.accent,
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: budget.toDouble(),
                  min: 300,
                  max: 4000,
                  divisions: 37,
                  onChanged: (v) {
                    final newVal = v.round();
                    setSheetState(() => budget = newVal);
                    MemorySettings.saveMemBudgetTotal(newVal);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'Memories exceeding the budget will not be injected this turn',
                  zhTW: '超出預算的記憶不會在該輪注入',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      setState(() {
        _searchResults = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      final result = await DatabaseHelper.searchMemoriesForCharacter(
        keyword,
        characterId: _characterId,
        limit: null,
        contextMode: widget.contextMode,
        continuityId: widget.continuityId,
      );
      if (!mounted || _searchController.text.trim() != keyword) return;
      setState(() {
        _searchResults = result;
        _searching = false;
      });
    });
  }

  Future<void> _showSendLimitSettings() async {
    var value = _memorySendLimit;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  L.pick(
                    en: 'Chat memory send limit',
                    zhTW: '對話記憶發送限制',
                    zhCN: '对话记忆发送限制',
                  ),
                  style: YanciTheme.headingMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  L.pick(
                    en: 'At most $value recalled memories per chat request. Manual summary batches are separate.',
                    zhTW: '每次對話請求最多召回 $value 條；不影響手動批次整理',
                    zhCN: '每次对话请求最多召回 $value 条；不影响手动批次整理',
                  ),
                  style: YanciTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                Slider(
                  min: 1,
                  max: MemorySettings.maxMemorySendLimit.toDouble(),
                  divisions: MemorySettings.maxMemorySendLimit - 1,
                  value: value.toDouble(),
                  label: '$value',
                  onChanged: (next) {
                    setSheetState(() => value = next.round());
                  },
                  onChangeEnd: (next) async {
                    final saved = next.round();
                    await MemorySettings.saveMemorySendLimit(saved);
                    if (mounted) {
                      setState(() {
                        _memorySendLimit = saved;
                      });
                    }
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: [10, 25, 50, 100]
                      .map(
                        (preset) => ChoiceChip(
                          label: Text('$preset'),
                          selected: value == preset,
                          onSelected: (_) async {
                            setSheetState(() => value = preset);
                            await MemorySettings.saveMemorySendLimit(preset);
                            if (mounted) {
                              setState(() {
                                _memorySendLimit = preset;
                              });
                            }
                          },
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMemorySelection(Memory memory) {
    if (_curationRunning) return;
    final id = memory.id;
    if (id == null) return;
    setState(() {
      _selectionMode = true;
      _resumableCurationJob = false;
      if (!_selectedMemoryIds.add(id)) _selectedMemoryIds.remove(id);
    });
    unawaited(SpiderWebStateService.clearCurationJob(_characterId));
  }

  void _selectAllVisible() {
    final visible = _searchController.text.trim().isEmpty
        ? _memories
        : _searchResults;
    setState(() {
      _selectionMode = true;
      _resumableCurationJob = false;
      for (final memory in visible) {
        if (memory.id != null) _selectedMemoryIds.add(memory.id!);
      }
    });
    unawaited(SpiderWebStateService.clearCurationJob(_characterId));
  }

  void _startSelectionMode() {
    setState(() {
      _isGraphView = false;
      _selectionMode = true;
      _resumableCurationJob = false;
    });
    unawaited(SpiderWebStateService.clearCurationJob(_characterId));
  }

  void _clearSelection() {
    setState(() {
      _selectionMode = false;
      _resumableCurationJob = false;
      _selectedMemoryIds.clear();
    });
    unawaited(SpiderWebStateService.clearCurationJob(_characterId));
  }
}
