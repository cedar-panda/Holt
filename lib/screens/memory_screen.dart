import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../memory/database.dart';
import '../memory/spider_web_layers.dart';

import '../services/token_estimator.dart';
import '../models/memory.dart';
import '../services/settings_manager.dart';
import '../services/memory_curation_service.dart';
import '../services/existing_memory_scanner.dart';
import '../widgets/spider_web_graph_view.dart';
import '../widgets/memory_layer_rail.dart';
import '../widgets/memory_review_tab.dart';
import '../widgets/memory_summary_tab.dart';
import '../services/memory_guard_service.dart';
import '../services/spider_web_state_service.dart';

/// 記憶庫頁面 — V2：扁平列表 + 浮動回收站
class MemoryScreen extends StatefulWidget {
  final String characterId;
  final int initialTab;
  final int? initialSourceMessageId;

  const MemoryScreen({
    super.key,
    this.characterId = 'default',
    this.initialTab = 0,
    this.initialSourceMessageId,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen>
    with SingleTickerProviderStateMixin {
  List<Memory> _memories = [];
  List<Memory> _graphMemories = [];
  List<Map<String, dynamic>> _spiderLinks = [];
  List<SpiderWebLayerPlan> _layers = [];
  int _activeLayerIndex = 0;
  int _archivedCount = 0;
  int _totalTokens = 0;
  late String _characterId;
  bool _loading = true;
  bool _isSpiderWebEnabled = false;
  // 條目是日常查找與整理的主要入口；蛛網保留為使用者主動切換的視圖。
  bool _isGraphView = false;
  int _memorySendLimit = MemorySettings.defaultMemorySendLimit;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<Memory> _searchResults = [];
  bool _searching = false;
  final Set<int> _selectedMemoryIds = {};
  bool _selectionMode = false;
  bool _curationRunning = false;
  int _curationCompletedBatches = 0;
  int _curationTotalBatches = 0;
  bool _resumableCurationJob = false;
  Map<int, SpiderWebNodePosition> _savedNodePositions = {};

  int _tabIndex = 0; // 0=記憶庫, 1=待確認, 2=摘要
  int? _reviewSourceMessageId;
  int _reviewTotal = 0;
  int _reviewUnread = 0;
  bool _summaryModified = false;

  int get _suggestedRelationCount => _spiderLinks
      .where((link) => link['status']?.toString() == 'suggested')
      .length;

  // 回收站氣泡動畫
  late AnimationController _archiveAnimCtrl;

  @override
  void initState() {
    super.initState();
    _characterId = widget.characterId;
    _tabIndex = widget.initialTab.clamp(0, 2);
    _reviewSourceMessageId = widget.initialSourceMessageId;
    _archiveAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _initCharacterId();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _archiveAnimCtrl.dispose();
    super.dispose();
  }

  Future<void> _initCharacterId() async {
    if (_characterId == 'default') {
      _characterId = await UserSettings.getActiveCharacterId();
    }
    final char = await DatabaseHelper.getCharacter(_characterId);
    if (char != null) {
      _isSpiderWebEnabled = (char['is_spider_web_enabled'] as int? ?? 0) == 1;
    }
    _memorySendLimit = await MemorySettings.getMemorySendLimit();
    _savedNodePositions = await SpiderWebStateService.loadPositions(
      _characterId,
    );
    await _loadMemories();
    await _restoreCurationJob();
  }

  Future<String> _bucket() async =>
      (await MemorySettings.getMemoryMode()) == 'story' ? 'story' : 'romance';

  Future<void> _loadMemories() async {
    final bucket = await _bucket();
    final permanent = await DatabaseHelper.getPermanentMemories(
      bucket,
      characterId: _characterId,
    );
    final allActive = await DatabaseHelper.getActiveMemories(
      bucket,
      characterId: _characterId,
    );
    final archived = await DatabaseHelper.getArchivedCount(
      characterId: _characterId,
    );
    final links = await DatabaseHelper.getSpiderWebLinks(_characterId);
    final reviewCounts = await MemoryGuardService.counts(_characterId);
    // 合併去重（permanent 可能跟 allActive 重疊）
    final seen = <int>{};
    final merged = <Memory>[];
    for (final m in [...permanent, ...allActive]) {
      if (m.id != null && !seen.add(m.id!)) continue;
      merged.add(m);
    }
    final graphMemories = _isSpiderWebEnabled
        ? await DatabaseHelper.getAllActiveMemories(characterId: _characterId)
        : merged;
    final layers = SpiderWebLayerPlanner.build(
      memories: graphMemories,
      links: links,
    );

    int tokens = 0;
    for (final m in merged) {
      tokens += TokenEstimator.estimate(
        '[#${m.id}·${m.category}] ${m.content}',
      );
    }

    if (!mounted) return;
    setState(() {
      _memories = merged;
      _graphMemories = graphMemories;
      _spiderLinks = links;
      _layers = layers;
      if (_layers.isEmpty) {
        _activeLayerIndex = 0;
      } else {
        _activeLayerIndex = _activeLayerIndex.clamp(0, _layers.length - 1);
      }
      _archivedCount = archived;
      _totalTokens = tokens;
      _reviewTotal = reviewCounts.total;
      _reviewUnread = reviewCounts.unread;
      final activeIds = graphMemories
          .map((memory) => memory.id)
          .whereType<int>()
          .toSet();
      _selectedMemoryIds.removeWhere((id) => !activeIds.contains(id));
      _loading = false;
    });
  }

  Future<void> _restoreCurationJob() async {
    final job = await SpiderWebStateService.loadCurationJob(_characterId);
    if (job == null || !job.canResume || !mounted) return;
    final allActive = await DatabaseHelper.getAllActiveMemories(
      characterId: _characterId,
    );
    if (!mounted) return;
    final activeIds = allActive
        .map((memory) => memory.id)
        .whereType<int>()
        .toSet();
    final resumable = job.memoryIds.where(activeIds.contains).toSet();
    if (resumable.length < 2) {
      await SpiderWebStateService.clearCurationJob(_characterId);
      return;
    }
    setState(() {
      _isGraphView = false;
      _selectionMode = true;
      _resumableCurationJob = true;
      _selectedMemoryIds
        ..clear()
        ..addAll(resumable);
    });
  }

  Future<void> _refreshReviewCounts() async {
    final counts = await MemoryGuardService.counts(_characterId);
    if (!mounted) return;
    setState(() {
      _reviewTotal = counts.total;
      _reviewUnread = counts.unread;
    });
  }

  void _selectTab(int index) {
    if (_tabIndex == index) return;
    final shouldDiscardPendingJob = !_curationRunning;
    setState(() {
      _tabIndex = index;
      _selectionMode = false;
      _resumableCurationJob = false;
      _selectedMemoryIds.clear();
    });
    // Switching tabs must not erase an in-flight model job. If the app is
    // interrupted before the request returns, the ids remain recoverable and
    // the next visit offers an explicit manual retry instead of spending
    // tokens again by itself.
    if (shouldDiscardPendingJob) {
      unawaited(SpiderWebStateService.clearCurationJob(_characterId));
    }
  }

  // ═══════════════════════════════════
  // 手動寫入記憶
  // ═══════════════════════════════════

  void _showAddMemoryDialog() {
    final categoryCtrl = TextEditingController(
      text: L.pick(en: 'Important Event', zhTW: '重要事件'),
    );
    final contentCtrl = TextEditingController();
    final triggersCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Write a memory', zhTW: '寫入記憶'),
          style: YanciTheme.headingMedium,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: categoryCtrl,
                style: YanciTheme.bodyText,
                decoration: InputDecoration(
                  labelText: L.pick(
                    en: 'Category',
                    zhTW: '類別（情緒/關係/偏好/約定/習慣/重要事件）',
                  ),
                  labelStyle: YanciTheme.bodySmall,
                ),
              ),
              TextField(
                controller: contentCtrl,
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
                controller: triggersCtrl,
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
              final content = contentCtrl.text.trim();
              if (content.isEmpty) return;
              final result = await MemoryGuardService.guardNewMemory(
                candidate: Memory(
                  characterId: _characterId,
                  mode: await _bucket(),
                  category: categoryCtrl.text.trim().isEmpty
                      ? (L.pick(en: 'Important Event', zhTW: '重要事件'))
                      : categoryCtrl.text.trim(),
                  content: content,
                  confidence: 'high',
                  triggers: triggersCtrl.text.trim(),
                ),
                source: 'memory_ui',
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
    );
  }

  // ═══════════════════════════════════
  // 整理
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // Token 預算設定（單一 slider）
  // ═══════════════════════════════════

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
                  children: [10, 25, 50, 100, 500]
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

  Future<void> _sendSelectedForCuration() async {
    if (_curationRunning || _selectedMemoryIds.length < 2) return;
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
      final result = await MemoryCurationService.analyzeAndLink(
        characterId: _characterId,
        memories: selected,
        onBatchProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _curationCompletedBatches = completed;
            _curationTotalBatches = total;
          });
        },
      );
      await SpiderWebStateService.clearCurationJob(_characterId);
      if (!mounted) return;
      setState(() {
        _curationRunning = false;
        _curationCompletedBatches = 0;
        _curationTotalBatches = 0;
        _selectionMode = false;
        _resumableCurationJob = false;
        _selectedMemoryIds.clear();
      });
      await _loadMemories();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Analysis complete: ${result.createdLinks} relation suggestions, ${result.duplicateProposals} duplicate proposals',
              zhTW:
                  '分析完成：${result.createdLinks} 條關係建議、${result.duplicateProposals} 組去重提案',
              zhCN:
                  '分析完成：${result.createdLinks} 条关系建议、${result.duplicateProposals} 组去重提案',
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
      );
      if (!mounted) return;
      setState(() {
        _curationRunning = false;
        _selectionMode = false;
        _reviewSourceMessageId = null;
        _selectedMemoryIds.clear();
        if (result.duplicateProposals > 0) _tabIndex = 1;
      });
      await _loadMemories();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: result.duplicateProposals > 0
                  ? 'On-device check complete: ${result.duplicateProposals} duplicate proposals are ready for review.'
                  : 'On-device check complete: ${result.suggestedRelations} relation suggestions. Open Relation suggestions above to review links.',
              zhTW: result.duplicateProposals > 0
                  ? '本機檢查完成：${result.duplicateProposals} 組去重提案已進入待確認。'
                  : '本機檢查完成：${result.suggestedRelations} 條關係建議。連線請由上方「關係建議」確認。',
              zhCN: result.duplicateProposals > 0
                  ? '本机检查完成：${result.duplicateProposals} 组去重提案已进入待确认。'
                  : '本机检查完成：${result.suggestedRelations} 条关系建议。连线请由上方“关系建议”确认。',
            ),
          ),
        ),
      );
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

  Future<void> _showAnalysisChoice() async {
    if (_curationRunning || _selectedMemoryIds.length < 2) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                L.pick(
                  en: 'Process selected memories',
                  zhTW: '處理已選記憶',
                  zhCN: '处理已选记忆',
                ),
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 6),
              Text(
                L.pick(
                  en: 'Both options create suggestions first. Existing memories are never changed automatically.',
                  zhTW: '兩種方式都只先建立建議，不會自動改動既有記憶。',
                  zhCN: '两种方式都只先建立建议，不会自动改动既有记忆。',
                ),
                style: YanciTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.pop(context, 'local'),
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
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'model'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(
                  L.pick(
                    en: 'Summary model · process all ${_selectedMemoryIds.length} in automatic batches · uses tokens',
                    zhTW:
                        '摘要模型 · 全部 ${_selectedMemoryIds.length} 條自動分批 · 會使用 token',
                    zhCN:
                        '摘要模型 · 全部 ${_selectedMemoryIds.length} 条自动分批 · 会使用 token',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'local') {
      await _scanExistingMemories(memoryIds: _selectedMemoryIds);
    } else if (choice == 'model') {
      await _sendSelectedForCuration();
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
              _linkMemoryPreview(firstMemory, dialogContext: ctx),
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
              _linkMemoryPreview(secondMemory, dialogContext: ctx),
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
    if (action.startsWith('archive:')) {
      final memoryId = int.tryParse(action.substring('archive:'.length));
      if (memoryId != null) await _deleteMemories({memoryId});
      return;
    }
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

  Widget _linkMemoryPreview(
    Map<String, dynamic> memory, {
    required BuildContext dialogContext,
  }) {
    final memoryId = (memory['id'] as num?)?.toInt();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                memory['category']?.toString() ?? '',
                style: YanciTheme.bodySmall.copyWith(color: YanciTheme.accent),
              ),
              const SizedBox(height: 4),
              Text(
                memory['content']?.toString() ?? '',
                style: YanciTheme.bodyText,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          key: ValueKey('archive-link-memory-$memoryId'),
          onPressed: memoryId == null
              ? null
              : () => Navigator.pop(dialogContext, 'archive:$memoryId'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.red.shade400,
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.delete_outline_rounded, size: 17),
          label: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
        ),
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
    );
  }

  void _showLinkList({
    required List<Map<String, dynamic>> links,
    required String title,
    IconData icon = Icons.polyline_rounded,
    String initialFilter = 'all',
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

  // ═══════════════════════════════════
  // 記憶方案設定
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 回收站
  // ═══════════════════════════════════

  void _showArchive() async {
    final archived = await DatabaseHelper.getArchivedMemories(
      characterId: _characterId,
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

  // ═══════════════════════════════════
  // 確認彈窗
  // ═══════════════════════════════════

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

  // ═══════════════════════════════════
  // Build
  // ═══════════════════════════════════

  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  // 頂部欄
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: YanciTheme.spacingSm,
                      vertical: YanciTheme.spacingXs,
                    ),
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                icon: Icon(
                                  Icons.arrow_back_ios_rounded,
                                  size: 20,
                                  color: YanciTheme.textPrimary,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 44,
                                  minHeight: 44,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(_summaryModified),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L.get('memory_title'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.headingMedium,
                                ),
                                Text(
                                  '${_isSpiderWebEnabled ? _graphMemories.length : _memories.length} ${L.pick(en: 'memories', zhTW: '條', zhCN: '条')} · ≈${_totalTokens}t${_layers.isNotEmpty && _isGraphView ? ' · ${_activeLayerIndex + 1}/${_layers.length}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 10,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isSpiderWebEnabled)
                                IconButton(
                                  icon: Icon(
                                    _isGraphView
                                        ? Icons.list_rounded
                                        : Icons.hub_rounded,
                                    size: 18,
                                    color: YanciTheme.accent,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 44,
                                    minHeight: 44,
                                  ),
                                  tooltip: _isGraphView
                                      ? (L.pick(
                                          en: 'List View',
                                          zhTW: '切換條目記憶',
                                        ))
                                      : (L.pick(
                                          en: 'Spider Web',
                                          zhTW: '切換蛛網記憶',
                                        )),
                                  onPressed: () {
                                    setState(() {
                                      _isGraphView = !_isGraphView;
                                    });
                                  },
                                ),
                              IconButton(
                                onPressed: _showSendLimitSettings,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 44,
                                  minHeight: 44,
                                ),
                                tooltip: L.pick(
                                  en: 'Chat memory send limit: $_memorySendLimit',
                                  zhTW: '對話記憶發送限制：$_memorySendLimit 條',
                                  zhCN: '对话记忆发送限制：$_memorySendLimit 条',
                                ),
                                icon: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Icon(
                                      Icons.outbox_rounded,
                                      size: 18,
                                      color: YanciTheme.accent,
                                    ),
                                    Positioned(
                                      right: -9,
                                      top: -9,
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          minWidth: 18,
                                        ),
                                        height: 18,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 3,
                                        ),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: YanciTheme.accent,
                                          borderRadius: BorderRadius.circular(
                                            9,
                                          ),
                                        ),
                                        child: Text(
                                          '$_memorySendLimit',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 8,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.tune_rounded,
                                  size: 18,
                                  color: YanciTheme.accent,
                                ),
                                padding: EdgeInsets.zero,
                                tooltip: L.pick(
                                  en: 'Settings and add',
                                  zhTW: '設定與新增',
                                ),
                                onSelected: (value) {
                                  if (value == 'budget') {
                                    _showBudgetSettings();
                                  } else if (value == 'add') {
                                    if (_isSpiderWebEnabled) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            L.pick(
                                              en: 'Manual additions are disabled while Spider Web Memory is on. Let AI nodes expand it.',
                                              zhTW:
                                                  '開啟蛛網記憶時禁止手動新增，請交由 AI 節點自行擴展',
                                            ),
                                          ),
                                          backgroundColor: Colors.red.shade400,
                                        ),
                                      );
                                    } else {
                                      _showAddMemoryDialog();
                                    }
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'budget',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.tune_rounded,
                                          size: 18,
                                          color: YanciTheme.textPrimary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          L.pick(
                                            en: 'Memory injection budget',
                                            zhTW: '記憶注入預算',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'add',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.add_circle_outline,
                                          size: 18,
                                          color: _isSpiderWebEnabled
                                              ? YanciTheme.textSecondary
                                              : YanciTheme.textPrimary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          L.pick(
                                            en: 'Add memory',
                                            zhTW: '新增記憶',
                                          ),
                                          style: TextStyle(
                                            color: _isSpiderWebEnabled
                                                ? YanciTheme.textSecondary
                                                : YanciTheme.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 膠囊 TabBar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: _buildCapsuleTabBar(),
                  ),

                  if (_tabIndex == 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                      child: _buildMemorySearch(),
                    ),

                  if (_tabIndex == 0 && !_selectionMode)
                    _buildMemoryActionRow(),

                  // 記憶、待確認提案或摘要
                  Expanded(
                    child: switch (_tabIndex) {
                      0 => _buildMemoryBody(),
                      1 => MemoryReviewTab(
                        characterId: _characterId,
                        sourceMessageId: _reviewSourceMessageId,
                        onChanged: () => unawaited(_refreshReviewCounts()),
                      ),
                      _ => MemorySummaryTab(
                        characterId: _characterId,
                        onSummaryModified: () {
                          _summaryModified = true;
                        },
                      ),
                    },
                  ),
                  if (_tabIndex == 0 && _selectionMode) _buildSelectionBar(),
                ],
              ),
            ),

            // 積灰小盒子浮動按鈕
            if (_tabIndex == 0 && !_selectionMode)
              Positioned(
                right: 20,
                bottom: 20 + MediaQuery.of(context).padding.bottom,
                child: GestureDetector(
                  onTap: () async {
                    // Q 彈動效：縮 → 彈回
                    _archiveAnimCtrl.forward(from: 0.0);
                    await Future.delayed(const Duration(milliseconds: 150));
                    _showArchive();
                  },
                  child: AnimatedBuilder(
                    animation: _archiveAnimCtrl,
                    builder: (ctx, child) {
                      // 0→0.5: scale 1.0→0.85, 0.5→1.0: scale 0.85→1.05→1.0
                      final t = _archiveAnimCtrl.value;
                      double scale;
                      if (t < 0.4) {
                        scale = 1.0 - 0.15 * (t / 0.4);
                      } else {
                        final b = (t - 0.4) / 0.6;
                        // overshoot then settle
                        scale = 0.85 + 0.2 * Curves.elasticOut.transform(b);
                      }
                      return Transform.scale(
                        scale: scale.clamp(0.8, 1.15),
                        child: child,
                      );
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.transparent,
                        border: Border.all(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.15,
                          ),
                          width: 1,
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 20,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.45,
                            ),
                          ),
                          if (_archivedCount > 0)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    _archivedCount > 99
                                        ? '99'
                                        : '$_archivedCount',
                                    style: const TextStyle(
                                      fontSize: 8,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
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
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemorySearch() {
    return SizedBox(
      height: 44,
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: YanciTheme.bodyText.copyWith(fontSize: 13),
        decoration: InputDecoration(
          hintText: L.pick(
            en: 'Search content, keyword or category',
            zhTW: '搜尋內容、關鍵詞或類別',
            zhCN: '搜索内容、关键词或类别',
          ),
          hintStyle: YanciTheme.bodySmall,
          prefixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(13),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              : const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: L.pick(
                    en: 'Clear search',
                    zhTW: '清除搜尋',
                    zhCN: '清除搜索',
                  ),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
          filled: true,
          fillColor: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.055)
              : Colors.white.withValues(alpha: 0.55),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildMemoryBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final hasQuery = _searchController.text.trim().isNotEmpty;
    if (hasQuery) {
      if (!_searching && _searchResults.isEmpty) {
        return Center(
          child: Text(
            L.pick(
              en: 'No matching memories',
              zhTW: '沒有符合的記憶',
              zhCN: '没有符合的记忆',
            ),
            style: YanciTheme.bodySmall,
          ),
        );
      }
      return _buildMemoryList(_searchResults);
    }
    if (_isSpiderWebEnabled && _isGraphView) return _buildLayeredGraph();
    if (_memories.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            L.pick(
              en: 'No memories yet.\nThey\'ll grow from your conversations.',
              zhTW: '還沒有記憶。\n它們會從你們的對話中長出來。',
              zhCN: '还没有记忆。\n它们会从你们的对话中长出来。',
            ),
            textAlign: TextAlign.center,
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    return _buildMemoryList(_memories);
  }

  Widget _buildMemoryList(List<Memory> memories) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
      itemCount: memories.length,
      itemBuilder: (context, index) => _memoryTile(
        memories[index],
        showDivider: index < memories.length - 1,
      ),
    );
  }

  Widget _buildMemoryActionRow() {
    final hasQuery = _searchController.text.trim().isNotEmpty;
    final showingList = !_isGraphView || hasQuery;
    final canScan = _isSpiderWebEnabled && _graphMemories.length >= 2;
    final pendingRelations = _suggestedRelationCount;
    if ((!showingList || _memories.isEmpty) &&
        !canScan &&
        pendingRelations == 0) {
      return const SizedBox.shrink();
    }
    final quietSide = BorderSide(
      color: YanciTheme.textSecondary.withValues(alpha: 0.18),
      width: 0.8,
    );
    final quietStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      backgroundColor: Colors.transparent,
      foregroundColor: YanciTheme.textSecondary.withValues(alpha: 0.82),
      side: quietSide,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          alignment: WrapAlignment.start,
          spacing: 7,
          runSpacing: 6,
          children: [
            if (showingList && _memories.isNotEmpty)
              OutlinedButton(
                onPressed: _curationRunning ? null : _startSelectionMode,
                style: quietStyle,
                child: Text(L.pick(en: 'Select', zhTW: '多選', zhCN: '多选')),
              ),
            if (canScan)
              OutlinedButton(
                onPressed: _curationRunning
                    ? null
                    : () => _scanExistingMemories(),
                style: quietStyle,
                child: _curationRunning
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        L.pick(
                          en: 'On-device deduplication check',
                          zhTW: '本機記憶去重檢查',
                          zhCN: '本机记忆去重检查',
                        ),
                      ),
              ),
            if (pendingRelations > 0)
              OutlinedButton(
                onPressed: _showSuggestedRelations,
                style: quietStyle.copyWith(
                  foregroundColor: WidgetStatePropertyAll(YanciTheme.accent),
                  side: WidgetStatePropertyAll(
                    BorderSide(
                      color: YanciTheme.accent.withValues(alpha: 0.28),
                      width: 0.8,
                    ),
                  ),
                ),
                child: Text(
                  L.pick(
                    en: 'Suggestions $pendingRelations',
                    zhTW: '關係建議 $pendingRelations',
                    zhCN: '关系建议 $pendingRelations',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLayeredGraph() {
    if (_layers.isEmpty) return const SizedBox.shrink();
    final layer = _layers[_activeLayerIndex];
    return Stack(
      children: [
        Positioned.fill(
          child: SpiderWebGraphView(
            key: ValueKey('spider-layer-${layer.id}'),
            memories: layer.memories.map((m) => m.toMap()).toList(),
            memoryGroups: [
              for (final web in layer.webs)
                web.memories.map((m) => m.toMap()).toList(),
            ],
            smallWebGroups: [for (final web in layer.webs) web.isSmall],
            links: layer.links,
            savedPositions: _savedNodePositions,
            viewportRightInset: 70,
            externalLinkCount: layer.crossLayerLinkCount,
            onNodeTapped: _showMemoryNode,
            onLinkTapped: _showMemoryLink,
            onNodePositionChanged: _saveNodePosition,
            onExternalLinksTapped: layer.crossLayerLinks.isEmpty
                ? null
                : () => _showCrossLayerLinks(layer),
            onLinksTapped: () => _showLinkList(
              links: layer.links,
              title: L.pick(
                en: '${layer.links.length} memory relations',
                zhTW: '${layer.links.length} 條記憶關係',
                zhCN: '${layer.links.length} 条记忆关系',
              ),
            ),
            // The same on-device check now lives in the shared action row so
            // list and spider-web modes use one discoverable location.
            onZeroLinksAction: null,
          ),
        ),
        Positioned(
          top: 58,
          right: 10,
          bottom: 18,
          child: MemoryLayerRail(
            layers: _layers,
            selectedIndex: _activeLayerIndex,
            onSelected: (index) => setState(() => _activeLayerIndex = index),
          ),
        ),
      ],
    );
  }

  void _showMemoryNode(Map<String, dynamic> memoryMap) {
    final memoryId = (memoryMap['id'] as num?)?.toInt();
    final nodeLinks = memoryId == null
        ? const <Map<String, dynamic>>[]
        : _spiderLinks
              .where(
                (link) =>
                    link['memory_id_1'] == memoryId ||
                    link['memory_id_2'] == memoryId,
              )
              .toList(growable: false);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          memoryMap['category']?.toString() ?? '',
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          memoryMap['content']?.toString() ?? '',
          style: YanciTheme.bodyText,
        ),
        actions: [
          if (nodeLinks.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _showLinkList(
                  links: nodeLinks,
                  title: L.pick(
                    en: '${nodeLinks.length} memory links',
                    zhTW: '${nodeLinks.length} 條記憶連線',
                    zhCN: '${nodeLinks.length} 条记忆连线',
                  ),
                );
              },
              icon: const Icon(Icons.polyline_rounded, size: 17),
              label: Text(L.pick(en: 'Links', zhTW: '查看連線', zhCN: '查看连线')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar() {
    final analysisCount = _selectedMemoryIds.length;
    final progressLabel = _curationRunning && _curationTotalBatches > 0
        ? L.pick(
            en: 'Batch $_curationCompletedBatches/$_curationTotalBatches',
            zhTW: '批次 $_curationCompletedBatches/$_curationTotalBatches',
            zhCN: '批次 $_curationCompletedBatches/$_curationTotalBatches',
          )
        : L.pick(
            en: 'Process $analysisCount',
            zhTW: '處理 $analysisCount 條',
            zhCN: '处理 $analysisCount 条',
          );
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 9),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          border: Border(
            top: BorderSide(color: YanciTheme.accent.withValues(alpha: 0.15)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _curationRunning ? null : _clearSelection,
                  tooltip: L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消'),
                  icon: const Icon(Icons.close_rounded),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L.pick(
                          en: '${_selectedMemoryIds.length} selected',
                          zhTW: '已選 ${_selectedMemoryIds.length} 條',
                          zhCN: '已选 ${_selectedMemoryIds.length} 条',
                        ),
                        style: YanciTheme.bodySmall,
                      ),
                      if (_resumableCurationJob)
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFFD86B72),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                L.pick(
                                  en: 'Previous analysis did not finish',
                                  zhTW: '上次分析未完成，可重新送出',
                                  zhCN: '上次分析未完成，可重新发送',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 10,
                                  color: const Color(0xFFD86B72),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _curationRunning ? null : _selectAllVisible,
                  child: Text(
                    L.pick(en: 'Select visible', zhTW: '全選可見', zhCN: '全选可见'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _selectedMemoryIds.isEmpty || _curationRunning
                        ? null
                        : _deleteSelectedMemories,
                    icon: const Icon(Icons.delete_outline_rounded, size: 17),
                    label: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      foregroundColor: Colors.red.shade400,
                      side: BorderSide(
                        color: Colors.red.withValues(alpha: 0.24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _selectedMemoryIds.length >= 2 && !_curationRunning
                        ? _showAnalysisChoice
                        : null,
                    icon: _curationRunning
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded, size: 17),
                    label: Text(progressLabel),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
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

  // ═══════════════════════════════════
  // 膠囊 TabBar
  // ═══════════════════════════════════

  Widget _buildReviewCountBadge() {
    final unread = _reviewUnread > 0;
    final color = unread
        ? const Color(0xFFD86B72)
        : YanciTheme.textSecondary.withValues(alpha: 0.18);
    final label = _reviewTotal > 9 ? '9+' : '$_reviewTotal';
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const ValueKey('memory-review-count-badge'),
        dimension: 18,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    (unread
                            ? const Color(0xFFD86B72)
                            : YanciTheme.textSecondary)
                        .withValues(alpha: unread ? 0.2 : 0.08),
                blurRadius: 2.4,
                spreadRadius: 0.25,
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: unread ? Colors.white : YanciTheme.textSecondary,
                fontSize: label.length > 1 ? 8 : 9,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCapsuleTabBar() {
    final labels = [
      L.pick(en: 'Memories', zhTW: '記憶'),
      L.pick(en: 'Review', zhTW: '待確認'),
      L.pick(en: 'Summary', zhTW: '摘要'),
    ];
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(22),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / labels.length;
          return Stack(
            children: [
              // Sliding capsule
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                left: _tabIndex * tabWidth,
                top: 3,
                bottom: 3,
                width: tabWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
              // Tab labels
              Row(
                children: List.generate(labels.length, (i) {
                  final selected = _tabIndex == i;
                  return Expanded(
                    child: Semantics(
                      button: true,
                      selected: selected,
                      label: i == 1 && _reviewTotal > 0
                          ? '${labels[i]}, $_reviewTotal'
                          : labels[i],
                      child: GestureDetector(
                        onTap: () => _selectTab(i),
                        behavior: HitTestBehavior.opaque,
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                labels[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected
                                      ? YanciTheme.accent
                                      : YanciTheme.textSecondary.withValues(
                                          alpha: 0.58,
                                        ),
                                ),
                              ),
                              if (i == 1 && _reviewTotal > 0) ...[
                                const SizedBox(width: 5),
                                _buildReviewCountBadge(),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════
  // 記憶卡片
  // ═══════════════════════════════════

  Widget _memoryTile(Memory m, {required bool showDivider}) {
    final selected = m.id != null && _selectedMemoryIds.contains(m.id);
    return Column(
      children: [
        _SwipeDeleteReveal(
          key: ValueKey(m.id),
          enabled: !_selectionMode,
          onDeletePressed: m.id == null ? null : () => _deleteMemories({m.id!}),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => _toggleMemorySelection(m),
            onTap: _selectionMode ? () => _toggleMemorySelection(m) : null,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: selected
                    ? YanciTheme.accent.withValues(alpha: 0.09)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                border: selected
                    ? Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.48),
                        width: 0.9,
                      )
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: YanciTheme.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          m.category,
                          style: TextStyle(
                            fontSize: 10,
                            color: YanciTheme.accent,
                          ),
                        ),
                      ),
                      if (m.isPermanent) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.push_pin_rounded,
                          size: 10,
                          color: YanciTheme.accent.withValues(alpha: 0.4),
                        ),
                      ],
                      const Spacer(),
                      if (_selectionMode)
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    m.content,
                    style: YanciTheme.bodyText.copyWith(fontSize: 13),
                  ),
                  if (m.triggers.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      m.triggers
                          .split(RegExp(r'[,，、]'))
                          .map((t) => '#${t.trim()}')
                          .join(' '),
                      style: TextStyle(
                        fontSize: 10,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (showDivider) const _MemoryFadeDivider(),
      ],
    );
  }
}

class _MemoryFadeDivider extends StatelessWidget {
  const _MemoryFadeDivider();

  @override
  Widget build(BuildContext context) {
    final line = YanciTheme.textSecondary.withValues(alpha: 0.16);
    return ExcludeSemantics(
      child: SizedBox(
        height: 10,
        child: Center(
          child: Container(
            height: 0.7,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, line, line, Colors.transparent],
                stops: const [0, 0.46, 0.54, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A non-destructive swipe affordance. The gesture only reveals an explicit
/// button; it can never dismiss the row or mutate memory data by itself.
class _SwipeDeleteReveal extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Future<void> Function()? onDeletePressed;

  const _SwipeDeleteReveal({
    super.key,
    required this.child,
    required this.enabled,
    required this.onDeletePressed,
  });

  @override
  State<_SwipeDeleteReveal> createState() => _SwipeDeleteRevealState();
}

class _SwipeDeleteRevealState extends State<_SwipeDeleteReveal> {
  static const double _actionWidth = 88;
  double _offset = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(_SwipeDeleteReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _offset != 0) _close();
  }

  void _close() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    setState(() {
      _dragging = true;
      _offset = (_offset + (details.primaryDelta ?? 0)).clamp(
        -_actionWidth,
        0.0,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    final velocity = details.primaryVelocity ?? 0;
    final reveal = velocity < -240 || (velocity <= 240 && _offset < -36);
    setState(() {
      _dragging = false;
      _offset = reveal ? -_actionWidth : 0;
    });
  }

  Future<void> _delete() async {
    _close();
    await widget.onDeletePressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final revealWidth = (-_offset).clamp(0.0, _actionWidth);
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      child: Stack(
        children: [
          // The memory card is intentionally translucent. Paint the
          // destructive action only inside the portion actually revealed
          // by the swipe, otherwise it bleeds through a closed row.
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: revealWidth,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerRight,
                minWidth: _actionWidth,
                maxWidth: _actionWidth,
                child: SizedBox(
                  width: _actionWidth,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onDeletePressed == null ? null : _delete,
                      child: Semantics(
                        button: true,
                        label: L.pick(
                          en: 'Delete memory',
                          zhTW: '刪除記憶',
                          zhCN: '删除记忆',
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.red.shade400,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除'),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.red.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_offset, 0, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}
