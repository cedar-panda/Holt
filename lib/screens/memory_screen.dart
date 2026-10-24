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
import '../widgets/managed_text_controllers.dart';
import '../services/memory_guard_service.dart';
import '../services/spider_web_state_service.dart';

part 'memory_screen_dialogs.dart';
part 'memory_screen_curation.dart';
part 'memory_screen_links.dart';
part 'memory_screen_archive.dart';

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
  bool _allowResultPop = false;

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

  // ═══════════════════════════════════
  // 整理
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // Token 預算設定（單一 slider）
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 記憶方案設定
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 回收站
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 確認彈窗
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // Build
  // ═══════════════════════════════════

  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowResultPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popWithSummaryResult();
      },
      child: Scaffold(
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
                      onBack: _popWithSummaryResult,
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
      ),
    );
  }

  void _popWithSummaryResult() {
    if (!mounted || _allowResultPop) return;
    setState(() => _allowResultPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_summaryModified);
    });
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
          onTogglePinned: memory.id == null
              ? null
              : () async {
                  await DatabaseHelper.setMemoryPinned(
                    memory.id!,
                    !memory.isPinned,
                  );
                  await _loadMemories();
                },
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
