import 'package:flutter/material.dart';

import '../memory/emotion_coordinates.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// ═══════════════════════════════════════════════
/// 情緒座標測試面板 V2
/// ═══════════════════════════════════════════════
/// 五維進度條 + circumplex 平面 + 混亂/共鳴
///
/// 長期維度（安全感、負面情緒）顯示 7 天滑動均值。
/// 瞬時維度（慾望、愜意、戲謔）顯示當前最高濃度。
class EmotionPanel extends StatefulWidget {
  static const bool kVisible = true;

  final String characterId;
  const EmotionPanel({super.key, required this.characterId});

  @override
  State<EmotionPanel> createState() => _EmotionPanelState();
}

class _EmotionPanelState extends State<EmotionPanel> {
  List<EmotionPoint> _points = [];
  Map<String, double> _bars = {};
  double _chaos = 0;
  int _windowCount = 0;
  bool _loading = true;

  static const double kResonanceBelow = 0.35;

  /// V2 五維配色
  static const dimColors = <String, Color>{
    '安全感': Color(0xFF5BA47A),
    '慾望': Color(0xFFC04A78),
    '愜意': Color(0xFFC9A876),
    '負面情緒': Color(0xFF8B6FC0),
    '戲謔': Color(0xFFA8B845),
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final points = await EmotionCoordinates.activePoints(widget.characterId);
    final bars = await EmotionCoordinates.bars(widget.characterId);
    final chaos = await EmotionCoordinates.currentChaos(widget.characterId);
    final cutoff = DateTime.now().subtract(
      const Duration(hours: EmotionCoordinates.kChaosWindowHours),
    );
    if (!mounted) return;
    setState(() {
      _points = points;
      _bars = bars;
      _chaos = chaos;
      _windowCount = points.where((p) => p.createdAt.isAfter(cutoff)).length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ═══ 標題行 ═══
          Row(
            children: [
              Text(
                L.pick(en: 'Emotion V2 · test', zhTW: '情緒座標 V2 · 測試'),
                style: YanciTheme.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                  color: YanciTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Builder(
                builder: (_) {
                  final resonating =
                      _windowCount >= 2 && _chaos < kResonanceBelow;
                  final label = resonating
                      ? '${L.pick(en: 'resonance', zhTW: '共鳴')} ${(1 - _chaos).toStringAsFixed(2)}'
                      : '${L.pick(en: 'chaos', zhTW: '混亂')} ${_chaos.toStringAsFixed(2)}';
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: YanciTheme.accent.withValues(
                        alpha: 0.08 + _chaos * 0.25,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 10, color: YanciTheme.accent),
                    ),
                  );
                },
              ),
              const Spacer(),
              GestureDetector(
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      title: Text(
                        L.pick(
                          en: 'Reset emotion coordinates?',
                          zhTW: '重置情緒座標？',
                        ),
                        style: TextStyle(
                          fontSize: 14,
                          color: YanciTheme.textPrimary,
                        ),
                      ),
                      content: Text(
                        L.pick(
                          en: 'All active emotion points will be dissipated.',
                          zhTW: '所有活躍情緒點會被清除（dissipated）。',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: YanciTheme.textSecondary,
                        ),
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
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                            L.pick(en: 'Reset', zhTW: '重置'),
                            style: TextStyle(
                              color: Colors.red.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    if (!mounted) return;
                    final n = await EmotionCoordinates.resetAll(
                      widget.characterId,
                    );
                    if (!mounted) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          L.pick(
                            en: 'Reset $n emotion points',
                            zhTW: '已重置 $n 個情緒點',
                          ),
                        ),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(milliseconds: 1200),
                      ),
                    );
                    setState(() => _loading = true);
                    _load();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.restart_alt_rounded,
                        size: 14,
                        color: Colors.red.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        L.pick(en: 'Reset', zhTW: '重置'),
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.red.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  setState(() => _loading = true);
                  _load();
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: YanciTheme.accent.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ═══ 座標平面 ═══
          AspectRatio(
            aspectRatio: 1.6,
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : CustomPaint(
                    painter: _PlanePainter(
                      points: _points,
                      axisColor: YanciTheme.textSecondary.withValues(
                        alpha: 0.25,
                      ),
                      lineColor: YanciTheme.accent.withValues(alpha: 0.35),
                    ),
                    child: const SizedBox.expand(),
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            L.pick(
              en: 'x: valence −/＋ · y: arousal −/＋ · line = chaos shape (24h)',
              zhTW: 'x 效價 負/正 · y 喚醒 負/正 · 連線 = 混亂的形狀（24h 內）',
            ),
            style: TextStyle(
              fontSize: 9,
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 10),

          // ═══ 圖例 ═══
          if (_points.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _points
                  .map((p) => p.type)
                  .toSet()
                  .map(
                    (t) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: dimColors[t] ?? Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          t,
                          style: TextStyle(
                            fontSize: 10,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 10),

          // ═══ 五維進度條 ═══
          ...kV2Dimensions.map((d) {
            final v = _bars[d] ?? 0;
            final color = dimColors[d] ?? Colors.grey;
            final isLongTerm = kLongTermDimensions.contains(d);
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(
                      d,
                      style: TextStyle(
                        fontSize: 10,
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Container(
                        height: 5,
                        color: Colors.white.withValues(alpha: 0.08),
                        child: Stack(
                          children: [
                            // 條填充（從左往右，不需中軸——V2 無效價方向分離）
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: (v / 100).clamp(0.0, 1.0),
                              child: Container(
                                color: color.withValues(alpha: 0.85),
                              ),
                            ),
                            // 長期維度標記：85 持久線
                            if (isLongTerm)
                              Positioned(
                                left: null,
                                right: null,
                                child: FractionallySizedBox(
                                  widthFactor: 0.85,
                                  alignment: Alignment.centerLeft,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Container(
                                      width: 1,
                                      color: Colors.white.withValues(
                                        alpha: 0.2,
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
                  SizedBox(
                    width: 30,
                    child: Text(
                      v > 0 ? v.round().toString() : '—',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 9,
                        color: YanciTheme.textSecondary.withValues(
                          alpha: v > 0 ? 0.8 : 0.3,
                        ),
                      ),
                    ),
                  ),
                  // 長期維度標註 avg
                  if (isLongTerm)
                    Text(
                      ' avg',
                      style: TextStyle(
                        fontSize: 7,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      ),
                    )
                  else
                    const SizedBox(width: 18),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// 座標平面畫筆（同 V1，配色改用 V2）
class _PlanePainter extends CustomPainter {
  final List<EmotionPoint> points;
  final Color axisColor;
  final Color lineColor;

  _PlanePainter({
    required this.points,
    required this.axisColor,
    required this.lineColor,
  });

  Offset _map(EmotionPoint p, Size size) => Offset(
    size.width / 2 + (p.x / 100) * (size.width / 2 - 8),
    size.height / 2 - (p.y / 100) * (size.height / 2 - 8),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final axisP = Paint()
      ..color = axisColor
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      axisP,
    );
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      axisP,
    );

    final cutoff = DateTime.now().subtract(
      const Duration(hours: EmotionCoordinates.kChaosWindowHours),
    );
    final windowPts = points.where((p) => p.createdAt.isAfter(cutoff)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (windowPts.length >= 2) {
      final lineP = Paint()
        ..color = lineColor
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(
          _map(windowPts.first, size).dx,
          _map(windowPts.first, size).dy,
        );
      for (final p in windowPts.skip(1)) {
        final o = _map(p, size);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, lineP);
    }

    for (final p in points) {
      final inWindow = p.createdAt.isAfter(cutoff);
      final color = _EmotionPanelState.dimColors[p.type] ?? Colors.grey;
      final dotP = Paint()
        ..color = color.withValues(alpha: inWindow ? 0.9 : 0.3);
      final r = 3 + (p.concentration / 100) * 4;
      canvas.drawCircle(_map(p, size), r, dotP);
    }
  }

  @override
  bool shouldRepaint(covariant _PlanePainter old) => old.points != points;
}
