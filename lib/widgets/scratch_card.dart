import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../services/scratch_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'themed_notice.dart';
import 'shell_coin_icon.dart';

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
  /// 疊在 accent 底色上的文字／貝殼：亮色主題用深色、暗色主題用白色。
  Color _onAccentColor() => YanciTheme.accent.computeLuminance() > 0.179
      ? const Color(0xFF1A1721)
      : const Color(0xFFFFFFFF);

  static const _cardW = 260.0;
  static const _cardH = 140.0;
  static const _radius = 14.0;

  final _scratches = <List<Offset>>[];
  List<Offset>? _current;
  double _scratchPercent = 0;
  bool _revealed = false;
  bool _settling = false;
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
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      unawaited(_reveal());
      return;
    }
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
    if (_revealed || _settling) return;
    _settling = true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    try {
      // Settle first, then expose the revealed UI. The wallet journal makes
      // this retry-safe if the process stops between credit and persistence.
      final claim = await ScratchService.claimScratch(
        widget.messageId,
        characterId: widget.characterId,
      );
      if (claim.data == null) throw StateError('Scratch data no longer exists');
    } catch (error) {
      if (!mounted) return;
      setState(() => _settling = false);
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Could not settle this card. Please try again.',
          zhTW: '這張刮刮卡還沒入帳，請再試一次。',
        ),
        tone: ThemedNoticeTone.error,
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _settling = false;
      _revealed = true;
    });
    if (reduceMotion) {
      _revealCtrl.value = 1;
    } else {
      _revealCtrl.forward();
    }

    // 延遲後縮小退場
    Future.delayed(
      reduceMotion ? Duration.zero : const Duration(milliseconds: 1600),
      () {
        if (!mounted) return;
        if (reduceMotion) {
          Navigator.of(context).pop(true);
          return;
        }
        _exitCtrl.forward().then((_) {
          if (mounted) Navigator.of(context).pop(true);
        });
      },
    );
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
                        color: Colors.black.withValues(
                          alpha: YanciTheme.isDark ? 0.42 : 0.16,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                      BoxShadow(
                        color: YanciTheme.accent.withValues(alpha: 0.16),
                        blurRadius: 30,
                        spreadRadius: -6,
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
                              tint: YanciTheme.accent,
                              hint: L.pick(en: 'S C R A T C H', zhTW: '刮 一 刮'),
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
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent,
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color: YanciTheme.accent.withValues(
                                        alpha: 0.35,
                                      ),
                                      blurRadius: 14,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
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
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.4,
                                              color: _onAccentColor(),
                                              fontFamily: YanciTheme.fontFamily,
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
                                            child: ShellCoinIcon(
                                              size: 18,
                                              color: _onAccentColor(),
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

  /// 獎品底層：跟主題走的面板色，帶一點 accent 色調與細內框；
  /// 左上角一枚小小的「刮刮樂」票根標。
  Widget _buildPrizeLayer() {
    final accent = YanciTheme.accent;
    final base = YanciTheme.isDark
        ? Color.lerp(const Color(0xFF17151C), accent, 0.10)!
        : Color.lerp(const Color(0xFFFFFFFF), accent, 0.08)!;
    final deep = YanciTheme.isDark
        ? Color.lerp(const Color(0xFF0F0D13), accent, 0.18)!
        : Color.lerp(const Color(0xFFF6F3F8), accent, 0.16)!;
    final labelColor = YanciTheme.textPrimary.withValues(alpha: 0.86);
    return Container(
      width: _cardW,
      height: _cardH,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, deep],
        ),
      ),
      child: Stack(
        children: [
          // 細內框：像票券的壓線
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_radius - 5),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.28),
                    width: 0.8,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 13,
            child: Text(
              L.pick(en: 'SCRATCH CARD', zhTW: '刮刮樂'),
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
                color: accent.withValues(alpha: 0.7),
                fontFamily: YanciTheme.fontFamily,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Center(
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
                          ShellCoinIcon(size: 22),
                          const SizedBox(width: 6),
                          Text(
                            '+${prize.coins}',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                              decoration: TextDecoration.none,
                              color: accent,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                        ] else
                          Text(
                            prize.label,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1,
                              decoration: TextDecoration.none,
                              color: labelColor,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                      ],
                    ),
                    if (prize != widget.data.prizes.last)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: accent.withValues(alpha: 0.45),
                          size: 16,
                        ),
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ 覆蓋層 painter：銀灰底 + 擦除痕跡 ═══

class _ScratchOverlayPainter extends CustomPainter {
  final List<List<Offset>> scratches;

  /// 主題 accent：銀箔帶一點主題色調，不再是死灰。
  final Color tint;
  final String hint;

  _ScratchOverlayPainter({
    required this.scratches,
    required this.tint,
    required this.hint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    // 存到 layer 才能用 BlendMode.clear
    canvas.saveLayer(rect, Paint());

    // 銀箔：帶 accent 色調的金屬漸層
    final silver = Color.lerp(const Color(0xFFC9C8D0), tint, 0.18)!;
    final light = Color.lerp(const Color(0xFFEDECF1), tint, 0.10)!;
    final dark = Color.lerp(const Color(0xFFA9A8B2), tint, 0.22)!;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light, silver, dark, silver, light],
          stops: const [0, 0.3, 0.55, 0.8, 1],
        ).createShader(rect),
    );

    // 斜向反光條：兩道很淡的高光，讓箔面有金屬感
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0x00FFFFFF),
          const Color(0x55FFFFFF),
          const Color(0x00FFFFFF),
          const Color(0x00FFFFFF),
          const Color(0x33FFFFFF),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.18, 0.26, 0.34, 0.58, 0.64, 0.7],
      ).createShader(rect);
    canvas.drawRect(rect, sheen);

    // 細噪點：箔面顆粒感（固定種子，每幀一樣）
    final rng = Random(42);
    final noisePaint = Paint();
    for (int i = 0; i < 260; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final bright = rng.nextBool();
      noisePaint.color = (bright ? const Color(0xFFFFFFFF) : dark).withValues(
        alpha: 0.10 + rng.nextDouble() * 0.12,
      );
      canvas.drawCircle(Offset(x, y), 0.6 + rng.nextDouble() * 0.5, noisePaint);
    }

    // 「刮一刮」提示（只在沒開始刮時顯示），兩側配小星芒
    if (scratches.isEmpty) {
      final ink = Color.lerp(const Color(0xFF6E6C78), tint, 0.25)!;
      final tp = TextPainter(
        text: TextSpan(
          text: hint,
          style: TextStyle(
            color: ink.withValues(alpha: 0.85),
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 6,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      final origin = Offset(
        (size.width - tp.width) / 2,
        (size.height - tp.height) / 2,
      );
      tp.paint(canvas, origin);
      final sparkle = Paint()
        ..color = ink.withValues(alpha: 0.55)
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round;
      void star(Offset c, double r) {
        canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), sparkle);
        canvas.drawLine(c - Offset(0, r), c + Offset(0, r), sparkle);
      }

      final midY = origin.dy + tp.height / 2;
      star(Offset(origin.dx - 14, midY), 3.5);
      star(Offset(origin.dx + tp.width + 10, midY), 3.5);
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

  /// 迷你卡片共用外框：主題面板色＋一點 accent 色調、細邊、柔影，
  /// 跟聊天氣泡同一套語言（不再是寫死的黑金／派對粉）。
  BoxDecoration _miniDecoration({required bool highlighted}) {
    final accent = YanciTheme.accent;
    final panel = YanciTheme.surfacePanel;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(panel, accent, highlighted ? 0.10 : 0.04)!,
          Color.lerp(panel, accent, highlighted ? 0.18 : 0.07)!,
        ],
      ),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: highlighted
            ? accent.withValues(alpha: 0.42)
            : YanciTheme.glassBorder.withValues(alpha: 0.6),
        width: 0.8,
      ),
      boxShadow: [
        BoxShadow(
          color: (highlighted ? accent : Colors.black).withValues(
            alpha: highlighted ? 0.14 : (YanciTheme.isDark ? 0.18 : 0.06),
          ),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  Widget _tag(String text) {
    final accent = YanciTheme.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 0.6,
          color: accent.withValues(alpha: 0.9),
          fontWeight: FontWeight.w600,
          fontFamily: YanciTheme.fontFamily,
        ),
      ),
    );
  }

  Widget _buildResult() {
    final totalCoins = data.prizes.fold(0, (sum, p) => sum + p.coins);
    final hasCoins = totalCoins > 0;
    final labels = data.prizes
        .map((p) => p.coins > 0 ? '+${p.coins}' : p.label)
        .join(' ➝ ');
    final accent = YanciTheme.accent;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: _miniDecoration(highlighted: hasCoins),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          if (hasCoins)
            ShellCoinIcon(size: 16)
          else
            Icon(
              Icons.auto_awesome_outlined,
              size: 15,
              color: YanciTheme.textSecondary.withValues(alpha: 0.7),
            ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              labels,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: hasCoins
                    ? accent
                    : YanciTheme.textPrimary.withValues(alpha: 0.75),
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _tag(L.pick(en: 'Scratch', zhTW: '刮刮樂')),
        ],
      ),
    );
  }

  Widget _buildUnscratched() {
    final accent = YanciTheme.accent;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: _miniDecoration(highlighted: false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 15, color: accent),
          const SizedBox(width: 7),
          Text(
            L.pick(en: 'Unopened scratch card', zhTW: '未刮開的刮刮樂'),
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textPrimary.withValues(alpha: 0.8),
              fontWeight: FontWeight.w500,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          const SizedBox(width: 8),
          _tag(L.pick(en: 'Tap to scratch', zhTW: '點開刮')),
        ],
      ),
    );
  }
}
