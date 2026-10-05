import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../memory/database.dart';
import '../utils/latest_request_gate.dart';

/// 用量監控面板
class UsageDashboardScreen extends StatefulWidget {
  const UsageDashboardScreen({super.key});

  @override
  State<UsageDashboardScreen> createState() => _UsageDashboardScreenState();
}

class _UsageDashboardScreenState extends State<UsageDashboardScreen> {
  int _period = 0; // 0=今天 1=本週 2=本月
  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _dailyData = [];
  List<Map<String, dynamic>> _modelBreakdown = [];
  List<Map<String, dynamic>> _requestKindBreakdown = [];
  bool _isLoading = true;
  final LatestRequestGate _loadGate = LatestRequestGate();

  static List<String> get _periods => [
    L.get('usage_period_today'),
    L.get('usage_period_week'),
    L.get('usage_period_month'),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  (DateTime, DateTime) _getRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_period) {
      case 0:
        return (today, today.add(const Duration(days: 1)));
      case 1:
        final weekStart = today.subtract(Duration(days: today.weekday - 1));
        return (weekStart, today.add(const Duration(days: 1)));
      case 2:
        final monthStart = DateTime(now.year, now.month, 1);
        return (monthStart, today.add(const Duration(days: 1)));
      default:
        return (today, today.add(const Duration(days: 1)));
    }
  }

  Future<void> _loadData() async {
    final generation = _loadGate.begin();
    final period = _period;
    final (from, to) = _getRange();
    final summary = await DatabaseHelper.getUsageSummary(from, to);
    final daily = await DatabaseHelper.getDailyUsage(from, to);
    final models = await DatabaseHelper.getUsageByModel(from, to);
    final requestKinds = await DatabaseHelper.getUsageByRequestKind(from, to);

    if (!mounted || period != _period || !_loadGate.isCurrent(generation)) {
      return;
    }
    setState(() {
      _summary = summary;
      _dailyData = daily;
      _modelBreakdown = models;
      _requestKindBreakdown = requestKinds;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // 頂部
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 20,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        L.get('usage_header'),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              // 時段切換
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingMd,
                ),
                child: Row(
                  children: List.generate(3, (i) {
                    final isActive = i == _period;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _period = i;
                            _isLoading = true;
                          });
                          _loadData();
                        },
                        child: Container(
                          margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: isActive
                                ? YanciTheme.accent.withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              YanciTheme.radiusSm,
                            ),
                          ),
                          child: Text(
                            _periods[i],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isActive
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: isActive
                                  ? YanciTheme.accent
                                  : YanciTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: YanciTheme.spacingMd),
              // 內容
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: YanciTheme.spacingMd,
                        ),
                        children: [
                          _buildSummaryCards(),
                          if (_requestKindBreakdown.isNotEmpty) ...[
                            const SizedBox(height: YanciTheme.spacingLg),
                            _buildRequestKindBreakdown(),
                          ],
                          if (_dailyData.length > 1) ...[
                            const SizedBox(height: YanciTheme.spacingLg),
                            _buildChart(),
                          ],
                          const SizedBox(height: YanciTheme.spacingLg),
                          _buildModelBreakdown(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══ 摘要卡片 ═══
  Widget _buildSummaryCards() {
    final cost = (_summary['total_cost'] as num?)?.toDouble() ?? 0.0;
    final prompt = (_summary['total_prompt'] as num?)?.toInt() ?? 0;
    final completion = (_summary['total_completion'] as num?)?.toInt() ?? 0;
    final cacheHit = (_summary['total_cache_hit'] as num?)?.toInt() ?? 0;
    final requests = (_summary['total_requests'] as num?)?.toInt() ?? 0;
    final knownCostRequests =
        (_summary['known_cost_requests'] as num?)?.toInt() ?? 0;

    return Column(
      children: [
        // 主卡片：費用
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: YanciTheme.aiBubble.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(color: YanciTheme.accent.withValues(alpha: 0.2)),
          ),
          child: Column(
            children: [
              Text(
                knownCostRequests == 0
                    ? '—'
                    : cost < 0.001
                    ? '< \$0.001'
                    : '\$${cost.toStringAsFixed(4)}',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w300,
                  color: YanciTheme.accent,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                L.fmt('n_period_total', [_periods[_period]]),
                style: YanciTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 三格
        Row(
          children: [
            _miniCard('$requests', L.get('usage_requests')),
            const SizedBox(width: 8),
            _miniCard(_formatK(prompt + completion), 'tokens'),
            const SizedBox(width: 8),
            _miniCard(
              cacheHit > 0 ? _formatK(cacheHit) : '—',
              L.get('usage_cache_hit'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          L.get('usage_reference_notice'),
          textAlign: TextAlign.center,
          style: YanciTheme.bodySmall.copyWith(
            color: YanciTheme.textSecondary.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _miniCard(String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: YanciTheme.glassWhite,
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: YanciTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: YanciTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestKindBreakdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(L.get('usage_request_breakdown'), style: YanciTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _requestKindBreakdown
              .map((item) {
                final kind = item['request_kind'] as String? ?? 'unknown';
                final requests = (item['requests'] as num?)?.toInt() ?? 0;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.glassWhite,
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _requestKindLabel(kind),
                          style: TextStyle(
                            fontSize: 11,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        TextSpan(
                          text: '  $requests',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: YanciTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              })
              .toList(growable: false),
        ),
      ],
    );
  }

  String _requestKindLabel(String kind) {
    const keys = <String, String>{
      'chat': 'usage_kind_chat',
      'summary': 'usage_kind_summary',
      'memory': 'usage_kind_memory',
      'embedding': 'usage_kind_embedding',
      'worldbook': 'usage_kind_worldbook',
      'guide': 'usage_kind_guide',
      'image': 'usage_kind_image',
      'signature': 'usage_kind_signature',
      'call': 'usage_kind_call',
      'sticker': 'usage_kind_sticker',
      'conversation_title': 'usage_kind_conversation_title',
      'keep_alive': 'usage_kind_keep_alive',
      'web_search': 'usage_kind_web_search',
      'tts': 'usage_kind_tts',
    };
    return L.get(keys[kind] ?? 'usage_kind_unknown');
  }

  // ═══ 折線圖 ═══
  Widget _buildChart() {
    return Container(
      height: 160,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      ),
      child: CustomPaint(
        size: const Size(double.infinity, 128),
        painter: _UsageChartPainter(
          data: _dailyData,
          accentColor: YanciTheme.accent,
          textColor: YanciTheme.textSecondary,
          gridColor: YanciTheme.textSecondary.withValues(alpha: 0.1),
        ),
      ),
    );
  }

  // ═══ 模型分佈 ═══
  Widget _buildModelBreakdown() {
    if (_modelBreakdown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(YanciTheme.spacingLg),
          child: Text(
            L.get('usage_no_data'),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(L.get('usage_model_dist'), style: YanciTheme.bodySmall),
        const SizedBox(height: 8),
        ..._modelBreakdown.map((m) {
          final model = m['model'] as String? ?? '?';
          final provider = m['provider'] as String? ?? '';
          final tokens = (m['total_tokens'] as num?)?.toInt() ?? 0;
          final cost = (m['cost'] as num?)?.toDouble() ?? 0.0;
          final reqs = (m['requests'] as num?)?.toInt() ?? 0;
          final knownCostRequests =
              (m['known_cost_requests'] as num?)?.toInt() ?? 0;

          // 短名
          final shortName = model.contains('/') ? model.split('/').last : model;

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: YanciTheme.glassWhite,
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shortName,
                        style: YanciTheme.bodyText.copyWith(fontSize: 13),
                      ),
                      Text(
                        provider.isEmpty
                            ? L.fmt('n_reqs_tokens', [reqs, _formatK(tokens)])
                            : '$provider · ${L.fmt('n_reqs_tokens', [reqs, _formatK(tokens)])}',
                        style: TextStyle(
                          fontSize: 10,
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  knownCostRequests == 0
                      ? '—'
                      : cost < 0.001
                      ? '< \$0.001'
                      : '\$${cost.toStringAsFixed(4)}',
                  style: TextStyle(
                    fontSize: 13,
                    color: YanciTheme.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  String _formatK(int n) {
    if (n < 1000) return '$n';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000).round()}k';
  }
}

/// 簡易折線圖
class _UsageChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> data;
  final Color accentColor;
  final Color textColor;
  final Color gridColor;

  _UsageChartPainter({
    required this.data,
    required this.accentColor,
    required this.textColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final costs = data
        .map((d) => (d['cost'] as num?)?.toDouble() ?? 0.0)
        .toList();
    final maxCost = costs.reduce(max);
    if (maxCost == 0) return;

    final chartH = size.height - 20;
    final chartW = size.width - 10;
    final stepX = chartW / (data.length - 1).clamp(1, 999);

    // 網格
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 0; i < 3; i++) {
      final y = chartH * i / 2;
      canvas.drawLine(Offset(0, y), Offset(chartW, y), gridPaint);
    }

    // 填充
    final fillPath = Path()..moveTo(0, chartH);
    final linePath = Path();

    for (var i = 0; i < costs.length; i++) {
      final x = i * stepX;
      final y = chartH - (costs[i] / maxCost * chartH);
      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo((costs.length - 1) * stepX, chartH);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: 0.2),
            accentColor.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(0, 0, chartW, chartH)),
    );

    canvas.drawPath(
      linePath,
      Paint()
        ..color = accentColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // 點
    for (var i = 0; i < costs.length; i++) {
      final x = i * stepX;
      final y = chartH - (costs[i] / maxCost * chartH);
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = accentColor);
    }

    // 日期標籤
    final labelStyle = TextStyle(fontSize: 9, color: textColor);
    for (var i = 0; i < data.length; i++) {
      if (data.length > 7 && i % 2 != 0 && i != data.length - 1) continue;
      final date = (data[i]['date'] as String? ?? '').substring(5);
      final tp = TextPainter(
        text: TextSpan(text: date, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(i * stepX - tp.width / 2, chartH + 4));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
