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
import '../models/context_mode.dart';
import '../services/settings/context_mode_settings.dart';
import '../services/settings_manager.dart';
import '../services/memory_curation_service.dart';
import '../services/memory_vector_recall_service.dart';
import '../services/existing_memory_scanner.dart';
import '../widgets/spider_web_graph_view.dart';
import '../widgets/memory_layer_rail.dart';
import '../widgets/memory_capsule_tab_bar.dart';
import '../widgets/memory_list_tile.dart';
import '../widgets/memory_screen_header.dart';
import '../widgets/memory_archive_fab.dart';
import '../widgets/memory_search_field.dart';
import '../widgets/memory_review_tab.dart';
import '../widgets/memory_summary_tab.dart';
import '../widgets/themed_notice.dart';
import '../services/memory_guard_service.dart';
import '../services/spider_web_state_service.dart';

/// 記憶庫頁面 — V2：扁平列表 + 浮動回收站
class MemoryScreen extends StatefulWidget {
  final String characterId;
  final int initialTab;
  final int? initialSourceMessageId;
  final ContextMode? contextMode;
  final String continuityId;
  final String? scopeLabel;

  const MemoryScreen({
    super.key,
    this.characterId = 'default',
    this.initialTab = 0,
    this.initialSourceMessageId,
    this.contextMode,
    this.continuityId = 'main',
    this.scopeLabel,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

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
  Set<String> _spiderActiveDateKeys = const <String>{};

  int _tabIndex = 0; // 0=記憶庫, 1=待確認, 2=摘要
  int? _reviewSourceMessageId;
  int _reviewTotal = 0;
  int _reviewUnread = 0;
  bool _summaryModified = false;

  bool get _rpStorylineScope => widget.contextMode == ContextMode.rp;
  bool get _spiderWebAvailable => _isSpiderWebEnabled && !_rpStorylineScope;

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
    if (!_rpStorylineScope) await _restoreCurationJob();
  }

  Future<String> _bucket() async =>
      (await MemorySettings.getMemoryMode()) == 'story' ? 'story' : 'romance';

  Future<void> _loadMemories() async {
    final bucket = await _bucket();
    final modes = widget.contextMode == null
        ? const <ContextMode>[ContextMode.daily, ContextMode.rp]
        : <ContextMode>[widget.contextMode!];
    final permanentGroups = await Future.wait<List<Memory>>([
      for (final mode in modes)
        DatabaseHelper.getPermanentMemories(
          bucket,
          characterId: _characterId,
          contextMode: mode,
          continuityId: mode == ContextMode.rp ? widget.continuityId : 'main',
        ),
    ]);
    final activeGroups = await Future.wait<List<Memory>>([
      for (final mode in modes)
        DatabaseHelper.getActiveMemories(
          bucket,
          characterId: _characterId,
          contextMode: mode,
          continuityId: mode == ContextMode.rp ? widget.continuityId : 'main',
        ),
    ]);
    final permanent = permanentGroups.expand((group) => group).toList();
    final allActive = activeGroups.expand((group) => group).toList();
    final archived = await DatabaseHelper.getArchivedCount(
      characterId: _characterId,
      contextMode: widget.contextMode,
      continuityId: widget.continuityId,
    );
    final activeDateKeys = _spiderWebAvailable
        ? await DatabaseHelper.getCharacterActiveDateKeys(_characterId)
        : const <String>{};
    final links = await DatabaseHelper.getSpiderWebLinks(_characterId);
    final reviewCounts = await MemoryGuardService.counts(
      _characterId,
      contextMode: widget.contextMode,
      continuityId: widget.continuityId,
    );
    // 合併去重（permanent 可能跟 allActive 重疊）
    final seen = <int>{};
    final merged = <Memory>[];
    for (final m in [...permanent, ...allActive]) {
      if (m.id != null && !seen.add(m.id!)) continue;
      merged.add(m);
    }
    final graphMemories = _spiderWebAvailable
        ? await DatabaseHelper.getAllActiveMemories(
            characterId: _characterId,
            contextMode: ContextMode.daily,
          )
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
      _spiderActiveDateKeys = activeDateKeys;
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
    final counts = await MemoryGuardService.counts(
      _characterId,
      contextMode: widget.contextMode,
      continuityId: widget.continuityId,
    );
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
                    zhTW: '類別（關係/偏好/約定/習慣/重要事件）',
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
                  contextMode:
                      widget.contextMode ??
                      await ContextModeSettings.effectiveMode(_characterId),
                  continuityId: _rpStorylineScope
                      ? widget.continuityId
                      : 'main',
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

  // ═══════════════════════════════════
  // 記憶方案設定
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 回收站
  // ═══════════════════════════════════

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
                  MemoryScreenHeader(
                    isSpiderWebEnabled: _spiderWebAvailable,
                    isGraphView: _isGraphView,
                    memoryCount: _spiderWebAvailable
                        ? _graphMemories.length
                        : _memories.length,
                    totalTokens: _totalTokens,
                    activeLayerIndex: _activeLayerIndex,
                    layerCount: _layers.length,
                    memorySendLimit: _memorySendLimit,
                    onBack: () => Navigator.of(context).pop(_summaryModified),
                    onToggleGraph: () {
                      setState(() {
                        _isGraphView = !_isGraphView;
                      });
                    },
                    onSendLimitPressed: _showSendLimitSettings,
                    onBudgetPressed: _showBudgetSettings,
                    onAddMemory: _showAddMemoryDialog,
                    onManualAddBlocked: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            L.pick(
                              en: 'Manual additions are disabled while Spider Web Memory is on. Let AI nodes expand it.',
                              zhTW: '開啟蛛網記憶時禁止手動新增，請交由 AI 節點自行擴展',
                            ),
                          ),
                          backgroundColor: Colors.red.shade400,
                        ),
                      );
                    },
                  ),

                  // 膠囊 TabBar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: MemoryCapsuleTabBar(
                      selectedIndex: _tabIndex,
                      reviewTotal: _reviewTotal,
                      reviewUnread: _reviewUnread,
                      onTabSelected: _selectTab,
                    ),
                  ),

                  if (_rpStorylineScope)
                    Padding(
                      padding: const EdgeInsets.only(top: 1, bottom: 3),
                      child: Text(
                        widget.scopeLabel?.trim().isNotEmpty == true
                            ? 'RP · ${widget.scopeLabel!.trim()}'
                            : 'RP',
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 11,
                          color: YanciTheme.accent.withValues(alpha: 0.72),
                        ),
                      ),
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
                        contextMode: widget.contextMode,
                        continuityId: widget.continuityId,
                        // The review tab owns proposal state, but the memory
                        // list is cached by this parent. Reload both after a
                        // proposal is accepted so archived merge targets do
                        // not remain visible until the screen is reopened.
                        onChanged: () => unawaited(_loadMemories()),
                      ),
                      _ => MemorySummaryTab(
                        characterId: _characterId,
                        contextMode: widget.contextMode,
                        continuityId: widget.continuityId,
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

            if (_tabIndex == 0 && !_selectionMode)
              MemoryArchiveFab(
                archivedCount: _archivedCount,
                animationController: _archiveAnimCtrl,
                onOpen: _showArchive,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemorySearch() {
    return MemorySearchField(
      controller: _searchController,
      searching: _searching,
      onChanged: _onSearchChanged,
      onClear: () {
        _searchController.clear();
        _onSearchChanged('');
      },
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
    if (_spiderWebAvailable && _isGraphView) return _buildLayeredGraph();
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
      itemBuilder: (context, index) {
        final memory = memories[index];
        final selected =
            memory.id != null && _selectedMemoryIds.contains(memory.id);
        return MemoryListTile(
          key: ValueKey(memory.id),
          memory: memory,
          showDivider: index < memories.length - 1,
          selected: selected,
          selectionMode: _selectionMode,
          onToggleSelection: () => _toggleMemorySelection(memory),
          onDeletePressed: memory.id == null
              ? null
              : () => _deleteMemories({memory.id!}),
        );
      },
    );
  }

  Widget _buildMemoryActionRow() {
    final hasQuery = _searchController.text.trim().isNotEmpty;
    final showingList = !_isGraphView || hasQuery;
    final canScan = _spiderWebAvailable && _graphMemories.length >= 2;
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
          child: RepaintBoundary(
            child: SpiderWebGraphView(
              key: ValueKey('spider-layer-${layer.id}'),
              memories: layer.memories.map((m) => m.toMap()).toList(),
              memoryGroups: [
                for (final web in layer.webs)
                  web.memories.map((m) => m.toMap()).toList(),
              ],
              smallWebGroups: [for (final web in layer.webs) web.isSmall],
              links: layer.links,
              activeDateKeys: _spiderActiveDateKeys,
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

  // ═══════════════════════════════════
  // 記憶卡片
  // ═══════════════════════════════════
}
