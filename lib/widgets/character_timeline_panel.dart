import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../memory/database.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/character_timeline_service.dart';
import '../services/rp_character_timeline_service.dart';
import '../services/settings/context_mode_settings.dart';
import '../models/context_mode.dart';
import '../services/scratch_service.dart';
import '../services/tool_feature_settings.dart';
import '../utils/latest_request_gate.dart';
import 'shop_backpack_sheets.dart';
import 'coin_amount_text.dart';
import 'context_mode_pill.dart';
import 'shell_coin_icon.dart';

/// 角色時間線 — 橫軸 + 上下交錯
/// 一條橫線貫穿，節點圓點在線上，內容交替顯示在線的上方/下方
/// 左舊右新，可左右滑動
class CharacterTimelinePanel extends StatefulWidget {
  final String characterId;
  final ContextMode? modeOverride;
  final String? rpContinuityId;
  final String? rpStorylineLabel;
  final bool showContextModeControl;
  final bool showEconomyActions;
  final bool initiallyCollapsed;
  final bool fullScreenVertical;

  const CharacterTimelinePanel({
    super.key,
    required this.characterId,
    this.modeOverride,
    this.rpContinuityId,
    this.rpStorylineLabel,
    this.showContextModeControl = true,
    this.showEconomyActions = true,
    this.initiallyCollapsed = false,
    this.fullScreenVertical = false,
  });

  @override
  State<CharacterTimelinePanel> createState() => _CharacterTimelinePanelState();
}

class _CharacterTimelinePanelState extends State<CharacterTimelinePanel> {
  List<_TimelineNode> _nodes = [];
  bool _loading = true;
  DateTime _selectedDate = DateTime.now();
  final ScrollController _scrollCtrl = ScrollController();
  int _charCoins = 0;
  bool _shellEconomyEnabled = true;
  bool _shopEnabled = true;
  StreamSubscription<CharacterCoinsChanged>? _coinsSub;
  final LatestRequestGate _loadGate = LatestRequestGate();
  final LatestRequestGate _coinsGate = LatestRequestGate();
  ContextMode _mode = ContextMode.daily;
  bool _globalRpEnabled = false;
  List<Map<String, Object?>> _rpStorylines = const <Map<String, Object?>>[];
  String _rpContinuityId = 'main';
  String _rpStorylineLabel = '';
  late bool _collapsed;

  // 佈局常量
  static const double _nodeWidth = 76.0;
  static const double _lineGap = 20.0; // 節點之間的線段寬度
  static const double _contentHeight = 50.0; // 上/下內容區高度
  static const double _lineZoneHeight = 20.0; // 中間線+圓點區域高度
  static const double _stalkHeight = 10.0; // 圓點到內容的豎線
  static const double _totalHeight =
      _contentHeight * 2 + _lineZoneHeight + _stalkHeight * 2;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.initiallyCollapsed;
    ContextModeSettings.revision.addListener(_handleContextModeChanged);
    ToolFeatureSettings.state.addListener(_handleToolFeaturesChanged);
    _load();
    _loadCoins();
    _coinsSub = ScratchService.characterCoinsChanged.listen((event) {
      if (!mounted ||
          !_shellEconomyEnabled ||
          event.characterId != widget.characterId) {
        return;
      }
      setState(() => _charCoins = event.coins);
    });
  }

  Future<void> _loadCoins() async {
    final generation = _coinsGate.begin();
    final characterId = widget.characterId;
    final features = await ToolFeatureSettings.load();
    if (!features.shellEconomyEnabled) {
      if (mounted && _coinsGate.isCurrent(generation)) {
        setState(() {
          _shellEconomyEnabled = false;
          _shopEnabled = features.shopEnabled;
          _charCoins = 0;
        });
      }
      return;
    }
    final coins = await ScratchService.getCoins(characterId);
    if (mounted &&
        characterId == widget.characterId &&
        _coinsGate.isCurrent(generation)) {
      setState(() {
        _shellEconomyEnabled = true;
        _shopEnabled = features.shopEnabled;
        _charCoins = coins;
      });
    }
  }

  void _handleToolFeaturesChanged() {
    final features = ToolFeatureSettings.state.value;
    if (!mounted) return;
    setState(() {
      _shellEconomyEnabled = features.shellEconomyEnabled;
      _shopEnabled = features.shopEnabled;
    });
    if (features.shellEconomyEnabled) unawaited(_loadCoins());
  }

  @override
  void didUpdateWidget(covariant CharacterTimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId ||
        oldWidget.modeOverride != widget.modeOverride ||
        oldWidget.rpContinuityId != widget.rpContinuityId ||
        oldWidget.rpStorylineLabel != widget.rpStorylineLabel) {
      _load();
      _loadCoins();
    }
  }

  @override
  void dispose() {
    ContextModeSettings.revision.removeListener(_handleContextModeChanged);
    ToolFeatureSettings.state.removeListener(_handleToolFeaturesChanged);
    _loadGate.invalidate();
    _coinsGate.invalidate();
    _coinsSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _handleContextModeChanged() {
    if (mounted) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = _loadGate.begin();
    final characterId = widget.characterId;
    setState(() => _loading = true);

    final globalRp = await ContextModeSettings.getGlobalRpEnabled();
    final preferred = ContextModeSettings.preferredModeFromCharacter(
      await DatabaseHelper.getCharacter(characterId),
    );
    final mode = widget.modeOverride ?? (globalRp ? ContextMode.rp : preferred);
    var rpStorylines = const <Map<String, Object?>>[];
    var rpContinuityId = widget.rpContinuityId ?? _rpContinuityId;
    var rpStorylineLabel = widget.rpStorylineLabel?.trim() ?? _rpStorylineLabel;
    if (mode == ContextMode.rp) {
      await DatabaseHelper.ensureDefaultRpStoryline(characterId);
      rpStorylines = await DatabaseHelper.getRpStorylines(characterId);
      if (rpStorylines.isNotEmpty) {
        final selected = rpStorylines.firstWhere(
          (row) => row['id']?.toString() == rpContinuityId,
          orElse: () => rpStorylines.first,
        );
        rpContinuityId = selected['id']?.toString() ?? 'main';
        final storedName = selected['name']?.toString().trim() ?? '';
        if (rpStorylineLabel.isEmpty) {
          rpStorylineLabel = storedName.isEmpty
              ? L.pick(en: 'Main storyline', zhTW: '主要故事線', zhCN: '主要故事线')
              : storedName;
        }
      }
    }
    final states = mode == ContextMode.daily
        ? await CharacterTimelineService.getStates(characterId)
        : <Map<String, dynamic>>[];
    final monthStart = DateTime(_selectedDate.year, _selectedDate.month);
    final monthEnd = DateTime(_selectedDate.year, _selectedDate.month + 1);
    final events = mode == ContextMode.daily
        ? await CharacterTimelineService.getEvents(
            characterId,
            from: monthStart,
            until: monthEnd,
            limit: 200,
            ascending: true,
          )
        : await RpCharacterTimelineService.getEntries(
            characterId,
            continuityId: rpContinuityId,
            limit: 200,
          );

    final nodes = <_TimelineNode>[];

    for (final s in states) {
      final parsed = DateTime.tryParse(s['updated_at'] as String? ?? '');
      if (parsed == null) continue;
      final dt = parsed.isUtc ? parsed.toLocal() : parsed;
      nodes.add(
        _TimelineNode(
          id: s['id'] as int,
          type: _NodeType.state,
          key: s['key'] as String? ?? '',
          value: s['value'] as String? ?? '',
          date: dt,
          sequenceOrder: s['id'] as int? ?? 0,
        ),
      );
    }

    for (final e in events) {
      final storyTime = e['story_time_text'] as String? ?? '';
      final parsed =
          DateTime.tryParse(storyTime) ??
          DateTime.tryParse(e['created_at'] as String? ?? '');
      if (parsed == null) continue;
      final dt = parsed.isUtc ? parsed.toLocal() : parsed;
      nodes.add(
        _TimelineNode(
          id: e['id'] as int,
          type: _NodeType.event,
          key: '',
          value:
              '${e['value'] as String? ?? ''}'
              '${e['scene'] == 'model_user_correction' ? L.pick(en: ' (corrected)', zhTW: '（修正）', zhCN: '（修正）') : ''}',
          date: dt,
          storyTimeText: storyTime,
          sequenceOrder: e['sequence_order'] as int? ?? e['id'] as int? ?? 0,
        ),
      );
    }

    // 按月過濾
    if (mode == ContextMode.daily) {
      nodes.retainWhere(
        (n) =>
            n.date.year == _selectedDate.year &&
            n.date.month == _selectedDate.month,
      );
    }

    // 左舊右新（升序）
    nodes.sort(
      mode == ContextMode.rp
          ? (a, b) => a.sequenceOrder.compareTo(b.sequenceOrder)
          : (a, b) => a.date.compareTo(b.date),
    );

    if (!mounted ||
        characterId != widget.characterId ||
        !_loadGate.isCurrent(generation)) {
      return;
    }
    setState(() {
      _nodes = nodes;
      _loading = false;
      _globalRpEnabled = globalRp;
      _mode = mode;
      _rpStorylines = rpStorylines;
      _rpContinuityId = rpContinuityId;
      _rpStorylineLabel = rpStorylineLabel;
    });

    // 滾到最右（最新）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          characterId == widget.characterId &&
          _loadGate.isCurrent(generation) &&
          _scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _setMode(ContextMode mode) async {
    var preferredModeSaved = false;
    if (_globalRpEnabled) {
      if (mode != ContextMode.daily) return;
      final confirmed = await confirmDisableGlobalRp(context);
      if (!mounted || !confirmed) return;
      await ContextModeSettings.setCharacterPreferredMode(
        widget.characterId,
        mode,
      );
      preferredModeSaved = true;
      await ContextModeSettings.setGlobalRpEnabled(false);
      if (!mounted) return;
      setState(() {
        _globalRpEnabled = false;
        _mode = mode;
      });
    }
    if (!preferredModeSaved) {
      await ContextModeSettings.setCharacterPreferredMode(
        widget.characterId,
        mode,
      );
    }
    final differs = await ContextModeSettings.latestWindowDiffers(
      widget.characterId,
      mode,
    );
    if (!mounted) return;
    final base = mode == ContextMode.rp
        ? L.pick(
            en: 'This companion is now in RP mode.',
            zhTW: '該夥伴已打開RP模式',
            zhCN: '该伙伴已打开RP模式',
          )
        : L.pick(
            en: 'This companion has returned to daily mode.',
            zhTW: '該夥伴已回歸日常',
            zhCN: '该伙伴已回归日常',
          );
    final next = !differs
        ? ''
        : mode == ContextMode.rp
        ? L.pick(
            en: ' Open a new window to begin RP.',
            zhTW: ' 請開啟新窗口進行RP',
            zhCN: ' 请开启新窗口进行RP',
          )
        : L.pick(
            en: ' Open a new window to begin your daily life.',
            zhTW: ' 請開啟新窗口開始你們的日常',
            zhCN: ' 请开启新窗口开始你们的日常',
          );
    showContextModeNotice(context, '$base$next');
    await _load();
  }

  // ═══════════════════════════════════
  // 月份選擇
  // ═══════════════════════════════════

  void _pickDate() async {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final months = <DateTime>[];
    for (int i = 0; i < 12; i++) {
      months.add(DateTime(now.year, now.month - i));
    }

    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel.withValues(alpha: 0.98),
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
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: months.map((m) {
                final isActive =
                    m.year == _selectedDate.year &&
                    m.month == _selectedDate.month;
                final label = '${m.year}.${m.month.toString().padLeft(2, '0')}';
                return GestureDetector(
                  onTap: () => Navigator.pop(ctx, m),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? YanciTheme.accent.withValues(alpha: 0.15)
                          : YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.grey.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isActive
                            ? YanciTheme.accent.withValues(alpha: 0.3)
                            : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: YanciTheme.fontFamily,
                        color: isActive
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
      _load();
    }
  }

  Future<void> _pickRpStoryline() async {
    if (_rpStorylines.length < 2) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: YanciTheme.surfacePanel,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                L.pick(
                  en: 'View storyline timeline',
                  zhTW: '查看哪一條故事線',
                  zhCN: '查看哪一条故事线',
                ),
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 10),
              for (var index = 0; index < _rpStorylines.length; index++)
                ListTile(
                  minTileHeight: 48,
                  title: Text(
                    (_rpStorylines[index]['name']?.toString().trim() ?? '')
                            .isEmpty
                        ? L.pick(
                            en: 'Storyline ${index + 1}',
                            zhTW: '故事線 ${index + 1}',
                            zhCN: '故事线 ${index + 1}',
                          )
                        : _rpStorylines[index]['name'].toString(),
                  ),
                  trailing:
                      _rpStorylines[index]['id']?.toString() == _rpContinuityId
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: YanciTheme.accent,
                        )
                      : null,
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _rpStorylines[index]['id']?.toString(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null || selected == _rpContinuityId) return;
    setState(() => _rpContinuityId = selected);
    await _load();
  }

  // ═══════════════════════════════════
  // Build
  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final monthLabel =
        '${_selectedDate.year}.${_selectedDate.month.toString().padLeft(2, '0')}';

    return Column(
      mainAxisSize: widget.fullScreenVertical
          ? MainAxisSize.max
          : MainAxisSize.min,
      children: [
        // ═══ 角色貝殼餘額 ═══
        if (widget.showEconomyActions && (_shellEconomyEnabled || _shopEnabled))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                if (_shellEconomyEnabled)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 7,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ShellCoinIcon(size: 20),
                        const SizedBox(width: 6),
                        CoinAmountText(_charCoins),
                      ],
                    ),
                  ),
                if (_shellEconomyEnabled && _shopEnabled)
                  const SizedBox(width: 8),
                if (_shopEnabled)
                  Tooltip(
                    message: L.pick(en: 'Backpack', zhTW: '背包'),
                    child: Semantics(
                      button: true,
                      label: L.pick(en: 'Backpack', zhTW: '背包'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (ctx) => BackpackBottomSheet(
                              ownerId: widget.characterId,
                            ),
                          );
                        },
                        child: SizedBox.square(
                          dimension: 40,
                          child: Center(
                            child: Icon(
                              Icons.backpack_outlined,
                              size: 18,
                              color: YanciTheme.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (widget.showEconomyActions && (_shellEconomyEnabled || _shopEnabled))
          const SizedBox(height: 14),
        // ═══ 標題行 ═══
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            children: [
              if (widget.showContextModeControl) ...[
                ContextModePill(
                  mode: _mode,
                  enabled: true,
                  onChanged: (mode) => unawaited(_setMode(mode)),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                L.pick(en: 'Timeline', zhTW: '時間線'),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: YanciTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  color: YanciTheme.textPrimary.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 2),
              Semantics(
                button: true,
                expanded: !_collapsed,
                label: _collapsed
                    ? L.pick(
                        en: 'Expand timeline',
                        zhTW: '展開時間線',
                        zhCN: '展开时间线',
                      )
                    : L.pick(
                        en: 'Collapse timeline',
                        zhTW: '收起時間線',
                        zhCN: '收起时间线',
                      ),
                child: IconButton(
                  key: const ValueKey('character-timeline-collapse'),
                  onPressed: () => setState(() => _collapsed = !_collapsed),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: AnimatedRotation(
                    turns: _collapsed ? 0 : .5,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 17,
                      color: YanciTheme.accent.withValues(alpha: .58),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              if (_mode == ContextMode.rp)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap:
                      widget.rpContinuityId == null && _rpStorylines.length > 1
                      ? _pickRpStoryline
                      : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 116),
                          child: Text(
                            _rpStorylineLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: YanciTheme.fontFamily,
                              color: YanciTheme.accent.withValues(alpha: 0.72),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.rpContinuityId == null &&
                            _rpStorylines.length > 1) ...[
                          const SizedBox(width: 3),
                          Icon(
                            Icons.unfold_more_rounded,
                            size: 14,
                            color: YanciTheme.accent.withValues(alpha: 0.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              else
                // 無邊框日期調節
                GestureDetector(
                  onTap: _pickDate,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        monthLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: YanciTheme.fontFamily,
                          color: YanciTheme.accent.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        Icons.unfold_more_rounded,
                        size: 14,
                        color: YanciTheme.accent.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        if (!_collapsed) const SizedBox(height: 8),

        // ═══ 時間線 ═══
        if (!_collapsed)
          if (widget.fullScreenVertical)
            Expanded(child: _buildVerticalTimeline())
          else
            SizedBox(
              height: _totalHeight,
              child: _loading
                  ? Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: YanciTheme.accent.withValues(alpha: 0.4),
                        ),
                      ),
                    )
                  : _nodes.isEmpty
                  ? Center(
                      child: Text(
                        _mode == ContextMode.rp
                            ? L.pick(
                                en: 'No story events yet',
                                zhTW: '這條故事線還沒有事件',
                                zhCN: '这条故事线还没有事件',
                              )
                            : L.pick(
                                en: 'Nothing this month yet',
                                zhTW: '這個月還沒有足跡',
                                zhCN: '这个月还没有足迹',
                              ),
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: YanciTheme.fontFamily,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (ctx, constraints) {
                        return SingleChildScrollView(
                          controller: _scrollCtrl,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: CustomPaint(
                            painter: _TimelineAxisPainter(
                              nodeCount: _nodes.length,
                              nodeWidth: _nodeWidth,
                              lineGap: _lineGap,
                              totalHeight: _totalHeight,
                              contentHeight: _contentHeight,
                              stalkHeight: _stalkHeight,
                              lineZoneHeight: _lineZoneHeight,
                              lineColor: YanciTheme.accent.withValues(
                                alpha: 0.15,
                              ),
                              dotColor: YanciTheme.accent,
                              dotColorAlt: YanciTheme.accent.withValues(
                                alpha: 0.5,
                              ),
                              nodes: _nodes,
                            ),
                            child: SizedBox(
                              width:
                                  _nodes.length * (_nodeWidth + _lineGap) -
                                  _lineGap +
                                  8, // 尾部留點空間
                              height: _totalHeight,
                              child: Stack(
                                children: List.generate(
                                  _nodes.length,
                                  (i) => _buildNodeContent(i),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
      ],
    );
  }

  Widget _buildVerticalTimeline() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: YanciTheme.accent.withValues(alpha: 0.4),
          ),
        ),
      );
    }
    if (_nodes.isEmpty) {
      return Center(
        child: Text(
          L.pick(
            en: 'No story events yet',
            zhTW: '這條故事線還沒有事件',
            zhCN: '这条故事线还没有事件',
          ),
          style: YanciTheme.bodySmall.copyWith(
            color: YanciTheme.textSecondary.withValues(alpha: 0.42),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
      itemCount: _nodes.length,
      itemBuilder: (context, index) {
        final node = _nodes[index];
        final isState = node.type == _NodeType.state;
        final timeLabel = node.storyTimeText.trim().isNotEmpty
            ? node.storyTimeText.trim()
            : L.pick(
                en: 'Scene ${node.sequenceOrder}',
                zhTW: '第 ${node.sequenceOrder} 節',
                zhCN: '第 ${node.sequenceOrder} 节',
              );
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 24,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    if (index < _nodes.length - 1)
                      Positioned(
                        top: 16,
                        bottom: 0,
                        child: Container(
                          width: 1,
                          color: YanciTheme.accent.withValues(alpha: 0.2),
                        ),
                      ),
                    Positioned(
                      top: 11,
                      child: Container(
                        width: isState ? 9 : 7,
                        height: isState ? 9 : 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isState
                              ? YanciTheme.accent
                              : YanciTheme.accent.withValues(alpha: 0.58),
                          boxShadow: isState
                              ? [
                                  BoxShadow(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.2,
                                    ),
                                    blurRadius: 7,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                      side: BorderSide(
                        color: YanciTheme.themedCardBorder(),
                        width: 0.6,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                      onTap: () => _showNodeDetail(node),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  timeLabel,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 10,
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  isState
                                      ? L.pick(
                                          en: 'State',
                                          zhTW: '狀態',
                                          zhCN: '状态',
                                        )
                                      : L.pick(
                                          en: 'Event',
                                          zhTW: '事件',
                                          zhCN: '事件',
                                        ),
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 9.5,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.55,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              node.value,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodyText.copyWith(height: 1.45),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════
  // 點擊節點展開完整內容
  // ═══════════════════════════════════

  void _showNodeDetail(_TimelineNode node) {
    HapticFeedback.selectionClick();
    final isState = node.type == _NodeType.state;
    final dateStr = _mode == ContextMode.rp
        ? node.storyTimeText.trim().isNotEmpty
              ? node.storyTimeText.trim()
              : L.pick(
                  en: 'Story order ${node.sequenceOrder}',
                  zhTW: '劇情順序 ${node.sequenceOrder}',
                  zhCN: '剧情顺序 ${node.sequenceOrder}',
                )
        : '${node.date.year}.${node.date.month.toString().padLeft(2, '0')}.${node.date.day.toString().padLeft(2, '0')}  '
              '${node.date.hour.toString().padLeft(2, '0')}:${node.date.minute.toString().padLeft(2, '0')}';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.45,
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel.withValues(alpha: 0.98),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(YanciTheme.radiusLg),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 拉條
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 標籤 + 日期 + 刪除
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isState
                        ? YanciTheme.accent.withValues(alpha: 0.12)
                        : YanciTheme.textSecondary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isState
                        ? L.pick(en: 'State', zhTW: '狀態')
                        : L.pick(en: 'Event', zhTW: '事件'),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: YanciTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      color: isState
                          ? YanciTheme.accent
                          : YanciTheme.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: YanciTheme.fontFamily,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: L.pick(en: 'Delete', zhTW: '刪除'),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                  ),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: ctx,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(
                          L.pick(
                            en: 'Delete timeline entry?',
                            zhTW: '刪除此時間線項目？',
                          ),
                        ),
                        content: Text(
                          L.pick(
                            en: 'This only deletes this timeline entry. Chat messages and summaries remain unchanged.',
                            zhTW: '只會刪除這個時間線項目，不會刪除聊天消息或摘要。',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: Text(L.pick(en: 'Delete', zhTW: '刪除')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                    if (_mode == ContextMode.rp) {
                      await RpCharacterTimelineService.deleteEntry(
                        characterId: widget.characterId,
                        id: node.id,
                        continuityId: _rpContinuityId,
                      );
                    } else {
                      await CharacterTimelineService.deleteEntry(
                        characterId: widget.characterId,
                        id: node.id,
                      );
                    }
                    if (!mounted) return;
                    Navigator.of(context).pop();
                    _load();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 完整內容（可滾動）
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  node.value,
                  style: TextStyle(
                    fontSize: 14,
                    fontFamily: YanciTheme.fontFamily,
                    height: 1.6,
                    color: YanciTheme.textPrimary.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 節點內容（上/下交錯）
  // ═══════════════════════════════════

  Widget _buildNodeContent(int index) {
    final node = _nodes[index];
    final isAbove = index.isEven; // 偶數在上，奇數在下
    final isState = node.type == _NodeType.state;
    final dateStr = _mode == ContextMode.rp
        ? node.storyTimeText.trim().isNotEmpty
              ? node.storyTimeText.trim()
              : '#${node.sequenceOrder}'
        : '${node.date.month}/${node.date.day}';

    final left = index * (_nodeWidth + _lineGap);

    // 上方區域：y = 0，高度 = _contentHeight
    // 下方區域：y = _contentHeight + _stalkHeight + _lineZoneHeight + _stalkHeight
    final topY = 0.0;
    final bottomY =
        _contentHeight + _stalkHeight + _lineZoneHeight + _stalkHeight;

    final displayText = node.value;

    return Positioned(
      left: left,
      top: isAbove ? topY : bottomY,
      width: _nodeWidth,
      height: _contentHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showNodeDetail(node),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: isAbove
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            // 日期
            Text(
              dateStr,
              textScaler: const TextScaler.linear(1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                fontFamily: YanciTheme.fontFamily,
                color: YanciTheme.textSecondary.withValues(alpha: 0.45),
                height: 1.0,
              ),
            ),
            const SizedBox(height: 2),
            // 內容文字
            Text(
              displayText,
              textScaler: const TextScaler.linear(1),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontFamily: YanciTheme.fontFamily,
                height: 1.3,
                color: isState
                    ? YanciTheme.accent.withValues(alpha: 0.85)
                    : YanciTheme.textPrimary.withValues(alpha: 0.65),
                fontWeight: isState ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════
// CustomPainter：橫軸 + 圓點 + 豎線
// ═══════════════════════════════════

class _TimelineAxisPainter extends CustomPainter {
  final int nodeCount;
  final double nodeWidth;
  final double lineGap;
  final double totalHeight;
  final double contentHeight;
  final double stalkHeight;
  final double lineZoneHeight;
  final Color lineColor;
  final Color dotColor;
  final Color dotColorAlt;
  final List<_TimelineNode> nodes;

  _TimelineAxisPainter({
    required this.nodeCount,
    required this.nodeWidth,
    required this.lineGap,
    required this.totalHeight,
    required this.contentHeight,
    required this.stalkHeight,
    required this.lineZoneHeight,
    required this.lineColor,
    required this.dotColor,
    required this.dotColorAlt,
    required this.nodes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodeCount == 0) return;

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final stalkPaint = Paint()
      ..color = lineColor
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // 橫軸 Y 座標（正中間）
    final axisY = contentHeight + stalkHeight + lineZoneHeight / 2;

    // 畫橫軸主線
    final firstX = nodeWidth / 2;
    final lastX = (nodeCount - 1) * (nodeWidth + lineGap) + nodeWidth / 2;
    canvas.drawLine(
      Offset(firstX - 12, axisY),
      Offset(lastX + 12, axisY),
      linePaint,
    );

    // 畫每個節點的圓點和豎線
    for (int i = 0; i < nodeCount; i++) {
      final cx = i * (nodeWidth + lineGap) + nodeWidth / 2;
      final isAbove = i.isEven;
      final isState = nodes[i].type == _NodeType.state;

      // 圓點
      final dotPaint = Paint()
        ..color = isState ? dotColor : dotColorAlt
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(cx, axisY), isState ? 3.5 : 2.5, dotPaint);

      // 圓點外圈（狀態節點加一圈淡環）
      if (isState) {
        final ringPaint = Paint()
          ..color = dotColor.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawCircle(Offset(cx, axisY), 6.0, ringPaint);
      }

      // 豎線：從圓點到內容區
      if (isAbove) {
        // 向上：從 axisY 到 contentHeight
        canvas.drawLine(
          Offset(cx, axisY - (isState ? 6.0 : 2.5) - 1),
          Offset(cx, contentHeight),
          stalkPaint,
        );
      } else {
        // 向下：從 axisY 到 bottomY
        final bottomY =
            contentHeight + stalkHeight + lineZoneHeight + stalkHeight;
        canvas.drawLine(
          Offset(cx, axisY + (isState ? 6.0 : 2.5) + 1),
          Offset(cx, bottomY),
          stalkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TimelineAxisPainter oldDelegate) {
    return oldDelegate.nodeCount != nodeCount ||
        oldDelegate.lineColor != lineColor;
  }
}

// ═══════════════════════════════════
// 數據模型
// ═══════════════════════════════════

enum _NodeType { state, event }

class _TimelineNode {
  final int id;
  final _NodeType type;
  final String key;
  final String value;
  final DateTime date;
  final String storyTimeText;
  final int sequenceOrder;

  _TimelineNode({
    required this.id,
    required this.type,
    required this.key,
    required this.value,
    required this.date,
    this.storyTimeText = '',
    required this.sequenceOrder,
  });
}
