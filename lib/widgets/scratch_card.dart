import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../services/scratch_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

// ═══════════════════════════════════════════════════════════════
// 刮刮樂系統
// ── ScratchCardDialog：居中全屏刮刮樂（手動刮 / 自動刮）
// ── ScratchMiniCard：刮完後縮小跟隨氣泡的迷你結果卡片
// ═══════════════════════════════════════════════════════════════

/// 彈出居中刮刮樂，刮完返回 true（代表需要刷新迷你卡片）
Future<bool?> showScratchDialog(
  BuildContext context, {
  required String messageId,
  required ScratchData data,
  required String characterId,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    pageBuilder: (_, _, _) => _ScratchCardDialog(
      messageId: messageId,
      data: data,
      characterId: characterId,
    ),
  );
}

// ═══ 全屏刮刮樂 ═══

class _ScratchCardDialog extends StatefulWidget {
  final String messageId;
  final ScratchData data;
  final String characterId;

  const _ScratchCardDialog({
    required this.messageId,
    required this.data,
    required this.characterId,
  });

  @override
  State<_ScratchCardDialog> createState() => _ScratchCardDialogState();
}

class _ScratchCardDialogState extends State<_ScratchCardDialog>
    with TickerProviderStateMixin {
  static const _cardW = 260.0;
  static const _cardH = 140.0;
  static const _radius = 14.0;

  final _scratches = <List<Offset>>[];
  List<Offset>? _current;
  double _scratchPercent = 0;
  bool _revealed = false;
  bool _autoMode = false;

  late AnimationController _revealCtrl;
  late Animation<double> _revealScale;
  late AnimationController _exitCtrl;

  @override
  void initState() {
    super.initState();

    _revealCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _revealScale = CurvedAnimation(
      parent: _revealCtrl,
      curve: Curves.elasticOut,
    );

    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _autoMode = widget.data.who != 'user';
    if (_autoMode) {
      Future.delayed(const Duration(milliseconds: 400), _autoScratch);
    }
  }

  @override
  void dispose() {
    _revealCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  // ═══ 自動刮（模型自己刮）═══
  void _autoScratch() {
    final rng = Random();
    // 生成 4~6 條隨機弧線
    final paths = <List<Offset>>[];
    final strokes = 4 + rng.nextInt(3);
    for (int s = 0; s < strokes; s++) {
      final pts = <Offset>[];
      final startX = 20.0 + rng.nextDouble() * (_cardW - 40);
      final startY = 20.0 + rng.nextDouble() * (_cardH - 40);
      double x = startX, y = startY;
      final steps = 12 + rng.nextInt(8);
      for (int i = 0; i < steps; i++) {
        x += (rng.nextDouble() - 0.4) * 28;
        y += (rng.nextDouble() - 0.5) * 16;
        x = x.clamp(4, _cardW - 4);
        y = y.clamp(4, _cardH - 4);
        pts.add(Offset(x, y));
      }
      paths.add(pts);
    }

    int pathIdx = 0;
    int ptIdx = 0;
    Timer.periodic(const Duration(milliseconds: 35), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (pathIdx >= paths.length) {
        timer.cancel();
        unawaited(_reveal());
        return;
      }
      final path = paths[pathIdx];
      if (ptIdx == 0) {
        _scratches.add([path[0]]);
      }
      ptIdx++;
      if (ptIdx >= path.length) {
        pathIdx++;
        ptIdx = 0;
      } else {
        _scratches.last.add(path[ptIdx]);
      }
      setState(() {
        _scratchPercent =
            (pathIdx * 20 + ptIdx * 2).clamp(0, 100).toDouble() / 100;
      });
    });
  }

  // ═══ 手動刮 ═══
  void _onPanStart(DragStartDetails d) {
    if (_revealed) return;
    final local = _globalToCard(d.globalPosition);
    if (local == null) return;
    _current = [local];
    _scratches.add(_current!);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_revealed || _current == null) return;
    final local = _globalToCard(d.globalPosition);
    if (local == null) return;
    _current!.add(local);
    _updatePercent();
    setState(() {});
    if (_scratchPercent > 0.55) unawaited(_reveal());
  }

  void _onPanEnd(DragEndDetails _) {
    _current = null;
  }

  Offset? _globalToCard(Offset global) {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > _cardW ||
        local.dy > _cardH) {
      return null;
    }
    return local;
  }

  void _updatePercent() {
    // 粗估：用覆蓋面積近似
    final totalArea = _cardW * _cardH;
    double covered = 0;
    for (final stroke in _scratches) {
      for (int i = 1; i < stroke.length; i++) {
        covered += (stroke[i] - stroke[i - 1]).distance * 28; // 筆刷寬 28
      }
    }
    _scratchPercent = (covered / totalArea).clamp(0, 1);
  }

  // ═══ 揭曉 ═══
  Future<void> _reveal() async {
    if (_revealed) return;
    _revealed = true;
    _revealCtrl.forward();

    // messageId 是冪等鍵；即使同一張卡被開兩個 dialog 或上次在
    // 「入帳後、標記前」中斷，也只會結算一次。
    await ScratchService.claimScratch(
      widget.messageId,
      characterId: widget.characterId,
    );

    // 延遲後縮小退場
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      _exitCtrl.forward().then((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    });
  }

  final _cardKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _exitCtrl,
      builder: (_, _) {
        final exitT = _exitCtrl.value;
        return Opacity(
          opacity: 1 - exitT,
          child: Transform.scale(
            scale: 1 - exitT * 0.6,
            child: Center(
              child: GestureDetector(
                onPanStart: _autoMode ? null : _onPanStart,
                onPanUpdate: _autoMode ? null : _onPanUpdate,
                onPanEnd: _autoMode ? null : _onPanEnd,
                child: Container(
                  key: _cardKey,
                  width: _cardW,
                  height: _cardH,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_radius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_radius),
                    child: Stack(
                      children: [
                        // 底層：獎品
                        _buildPrizeLayer(),
                        // 覆蓋層：銀灰 + 手指擦除
                        if (!_revealed)
                          CustomPaint(
                            size: const Size(_cardW, _cardH),
                            painter: _ScratchOverlayPainter(
                              scratches: _scratches,
                            ),
                          ),
                        // 揭曉動畫
                        if (_revealed)
                          ScaleTransition(
                            scale: _revealScale,
                            child: Center(
                              child: Container(
                                constraints: const BoxConstraints(
                                  maxWidth: _cardW - 24,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF2C96D),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    Expanded(
                                      child: Builder(
                                        builder: (context) {
                                          final labels = widget.data.prizes
                                              .map(
                                                (p) => p.coins > 0
                                                    ? '+${p.coins}'
                                                    : p.label,
                                              )
                                              .join(' ➝ ');
                                          return Text(
                                            labels,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF1A1721),
                                              decoration: TextDecoration.none,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    Builder(
                                      builder: (context) {
                                        final totalCoins = widget.data.prizes
                                            .fold(0, (sum, p) => sum + p.coins);
                                        if (totalCoins > 0) {
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              left: 4,
                                            ),
                                            child: Image.asset(
                                              'assets/images/shell_coin.png',
                                              width: 18,
                                              height: 18,
                                              filterQuality: FilterQuality.none,
                                            ),
                                          );
                                        }
                                        return const SizedBox.shrink();
                                      },
                                    ),
                                  ],
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
          ),
        );
      },
    );
  }

  Widget _buildPrizeLayer() {
    return Container(
      width: _cardW,
      height: _cardH,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2435), Color(0xFF1A1721)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.data.prizes.map((prize) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (prize.coins > 0) ...[
                      Image.asset(
                        'assets/images/shell_coin.png',
                        width: 24,
                        height: 24,
                        filterQuality: FilterQuality.none,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '+${prize.coins}',
                        style: const TextStyle(
                          fontSize: 24,
                          decoration: TextDecoration.none,
                          color: Color(0xFFF2C96D),
                        ),
                      ),
                    ] else
                      Text(
                        prize.label,
                        style: const TextStyle(
                          fontSize: 18,
                          decoration: TextDecoration.none,
                          color: Color(0xFFEFEAF2),
                        ),
                      ),
                  ],
                ),
                if (prize != widget.data.prizes.last)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: Icon(
                      Icons.arrow_downward,
                      color: Color(0xFF7A7A82),
                      size: 16,
                    ),
                  ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ═══ 覆蓋層 painter：銀灰底 + 擦除痕跡 ═══

class _ScratchOverlayPainter extends CustomPainter {
  final List<List<Offset>> scratches;

  _ScratchOverlayPainter({required this.scratches});

  @override
  void paint(Canvas canvas, Size size) {
    // 存到 layer 才能用 BlendMode.clear
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    // 銀灰底 + 微噪點紋理
    final bgPaint = Paint()..color = const Color(0xFFB8B8C0);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 噪點
    final rng = Random(42); // 固定種子，每幀一樣
    final noisePaint = Paint();
    for (int i = 0; i < 300; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final brightness = 0.65 + rng.nextDouble() * 0.25;
      noisePaint.color = Color.fromRGBO(
        (brightness * 255).round(),
        (brightness * 255).round(),
        (brightness * 258).round(),
        0.4,
      );
      canvas.drawCircle(Offset(x, y), 0.8 + rng.nextDouble() * 0.6, noisePaint);
    }

    // "刮一刮" 提示（只在沒開始刮時顯示）
    if (scratches.isEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: L.pick(en: 'S C R A T C H', zhTW: '刮 一 刮'),
          style: const TextStyle(
            color: Color(0xFF7A7A82),
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 6,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
      );
    }

    // 擦除痕跡
    final clearPaint = Paint()
      ..blendMode = ui.BlendMode.clear
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 28
      ..style = PaintingStyle.stroke;

    for (final stroke in scratches) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, clearPaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScratchOverlayPainter old) => true;
}

// ═══ 迷你結果卡片（氣泡下方常駐）═══

class ScratchMiniCard extends StatelessWidget {
  final String messageId;
  final ScratchData data;
  final String characterId;

  const ScratchMiniCard({
    super.key,
    required this.messageId,
    required this.data,
    required this.characterId,
  });

  @override
  Widget build(BuildContext context) {
    if (data.scratched) {
      return _buildResult();
    } else {
      return GestureDetector(
        onTap: () => showScratchDialog(
          context,
          messageId: messageId,
          data: data,
          characterId: characterId,
        ),
        child: _buildUnscratched(),
      );
    }
  }

  Widget _buildResult() {
    final totalCoins = data.prizes.fold(0, (sum, p) => sum + p.coins);
    final hasCoins = totalCoins > 0;
    final labels = data.prizes
        .map((p) => p.coins > 0 ? '+${p.coins}' : p.label)
        .join(' ➝ ');

    final isDark = YanciTheme.isDark;

    // 黑金風格 (Dark) / 派對風格 (Light)
    final bgColors = isDark
        ? [const Color(0xFF2A2424), const Color(0xFF1F1A1A)]
        : [const Color(0xFFFFF0F5), const Color(0xFFFFE4E1)];
    final borderColor = isDark
        ? (hasCoins
              ? const Color(0xFFFFD700).withValues(alpha: 0.6)
              : const Color(0xFF453F52))
        : (hasCoins
              ? const Color(0xFFFF69B4).withValues(alpha: 0.6)
              : const Color(0xFFD8BFD8));
    final textColor = isDark
        ? (hasCoins ? const Color(0xFFFFD700) : const Color(0xFF9A94A6))
        : (hasCoins ? const Color(0xFFFF1493) : const Color(0xFF800080));
    final titleColor = isDark
        ? const Color(0xFF8B8178)
        : const Color(0xFFDB7093);

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: bgColors),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: hasCoins && isDark
            ? [
                BoxShadow(
                  color: const Color(0xFFFFD700).withValues(alpha: 0.15),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          if (hasCoins) ...[
            Image.asset(
              'assets/images/shell_coin.png',
              width: 16,
              height: 16,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              labels,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: textColor,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: titleColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              L.pick(en: 'Scratch Card', zhTW: '刮刮樂'),
              style: TextStyle(
                fontSize: 10,
                color: titleColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnscratched() {
    final isDark = YanciTheme.isDark;
    final bgColor = isDark ? const Color(0xFF25202A) : const Color(0xFFF8F0FA);
    final borderColor = isDark
        ? const Color(0xFF453F52)
        : const Color(0xFFE0D4E5);
    final textColor = isDark
        ? const Color(0xFFB8B8C0)
        : const Color(0xFF9E7FA6);

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.stars_rounded, size: 16, color: textColor),
          const SizedBox(width: 6),
          Text(
            L.pick(en: 'Unopened scratch card', zhTW: '未刮開的刮刮樂'),
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
