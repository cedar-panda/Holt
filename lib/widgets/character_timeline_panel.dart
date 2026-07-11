import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/character_timeline_service.dart';
import '../services/scratch_service.dart';
import 'shop_backpack_sheets.dart';
import 'coin_amount_text.dart';

/// 角色時間線 — 橫軸 + 上下交錯
/// 一條橫線貫穿，節點圓點在線上，內容交替顯示在線的上方/下方
/// 左舊右新，可左右滑動
class CharacterTimelinePanel extends StatefulWidget {
  final String characterId;

  const CharacterTimelinePanel({super.key, required this.characterId});

  @override
  State<CharacterTimelinePanel> createState() => _CharacterTimelinePanelState();
}

class _CharacterTimelinePanelState extends State<CharacterTimelinePanel> {
  List<_TimelineNode> _nodes = [];
  bool _loading = true;
  DateTime _selectedDate = DateTime.now();
  final ScrollController _scrollCtrl = ScrollController();
  int _charCoins = 0;
  StreamSubscription<CharacterCoinsChanged>? _coinsSub;

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
    _load();
    _loadCoins();
    _coinsSub = ScratchService.characterCoinsChanged.listen((event) {
      if (!mounted || event.characterId != widget.characterId) return;
      setState(() => _charCoins = event.coins);
    });
  }

  Future<void> _loadCoins() async {
    final coins = await ScratchService.getCoins(widget.characterId);
    if (mounted) setState(() => _charCoins = coins);
  }

  @override
  void didUpdateWidget(covariant CharacterTimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId) {
      _load();
      _loadCoins();
    }
  }

  @override
  void dispose() {
    _coinsSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final states = await CharacterTimelineService.getStates(widget.characterId);
    final events = await CharacterTimelineService.getEvents(
      widget.characterId,
      limit: 50,
    );

    final nodes = <_TimelineNode>[];

    for (final s in states) {
      final dt =
          DateTime.tryParse(s['updated_at'] as String? ?? '') ?? DateTime.now();
      nodes.add(
        _TimelineNode(
          type: _NodeType.state,
          key: s['key'] as String? ?? '',
          value: s['value'] as String? ?? '',
          date: dt,
        ),
      );
    }

    for (final e in events) {
      final dt =
          DateTime.tryParse(e['created_at'] as String? ?? '') ?? DateTime.now();
      nodes.add(
        _TimelineNode(
          type: _NodeType.event,
          key: '',
          value: e['value'] as String? ?? '',
          date: dt,
        ),
      );
    }

    // 按月過濾
    nodes.retainWhere(
      (n) =>
          n.date.year == _selectedDate.year &&
          n.date.month == _selectedDate.month,
    );

    // 左舊右新（升序）
    nodes.sort((a, b) => a.date.compareTo(b.date));

    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _loading = false;
    });

    // 滾到最右（最新）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
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

  // ═══════════════════════════════════
  // Build
  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final monthLabel =
        '${_selectedDate.year}.${_selectedDate.month.toString().padLeft(2, '0')}';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ═══ 角色貝殼餘額 ═══
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.6),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/shell_coin.png',
                      width: 20,
                      height: 20,
                      filterQuality: FilterQuality.none,
                    ),
                    const SizedBox(width: 6),
                    CoinAmountText(_charCoins),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (ctx) =>
                        BackpackBottomSheet(ownerId: widget.characterId),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.white.withValues(alpha: 0.6),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.backpack_outlined,
                        size: 18,
                        color: YanciTheme.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // ═══ 標題行 ═══
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(
                Icons.timeline_rounded,
                size: 14,
                color: YanciTheme.accent.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Text(
                L.pick(en: 'Timeline', zhTW: '時間線'),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: YanciTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  color: YanciTheme.textPrimary.withValues(alpha: 0.7),
                ),
              ),
              const Spacer(),
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

        const SizedBox(height: 8),

        // ═══ 橫軸時間線 ═══
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
                    L.pick(en: 'Nothing this month yet', zhTW: '這個月還沒有足跡'),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: YanciTheme.fontFamily,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.35),
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
                          lineColor: YanciTheme.accent.withValues(alpha: 0.15),
                          dotColor: YanciTheme.accent,
                          dotColorAlt: YanciTheme.accent.withValues(alpha: 0.5),
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

  // ═══════════════════════════════════
  // 節點內容（上/下交錯）
  // ═══════════════════════════════════

  Widget _buildNodeContent(int index) {
    final node = _nodes[index];
    final isAbove = index.isEven; // 偶數在上，奇數在下
    final isState = node.type == _NodeType.state;
    final dateStr = '${node.date.month}/${node.date.day}';

    final left = index * (_nodeWidth + _lineGap);

    // 上方區域：y = 0，高度 = _contentHeight
    // 下方區域：y = _contentHeight + _stalkHeight + _lineZoneHeight + _stalkHeight
    final topY = 0.0;
    final bottomY =
        _contentHeight + _stalkHeight + _lineZoneHeight + _stalkHeight;

    return Positioned(
      left: left,
      top: isAbove ? topY : bottomY,
      width: _nodeWidth,
      height: _contentHeight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: isAbove
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          // 日期
          Text(
            dateStr,
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
            isState && node.key.isNotEmpty
                ? '${node.key}·${node.value}'
                : node.value,
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
  final _NodeType type;
  final String key;
  final String value;
  final DateTime date;

  _TimelineNode({
    required this.type,
    required this.key,
    required this.value,
    required this.date,
  });
}
