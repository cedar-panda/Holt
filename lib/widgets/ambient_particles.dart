import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'neural_field.dart';
import 'rain_painter.dart';
import 'starfield_painter.dart';

/// 主題背景粒子入口。只負責選擇與密度換算，不改動各動畫本身。
class AmbientParticleField extends StatefulWidget {
  final String? effect;
  final bool isBusy;
  final int neuralCount;
  final int starCount;
  final int rainCount;
  final int rippleCount;
  final int emberCount;
  final int dandelionCount;

  const AmbientParticleField({
    super.key,
    this.effect,
    this.isBusy = false,
    this.neuralCount = 18,
    this.starCount = 18,
    this.rainCount = 30,
    this.rippleCount = 7,
    this.emberCount = 22,
    this.dandelionCount = 16,
  });

  @override
  State<AmbientParticleField> createState() => _AmbientParticleFieldState();
}

class _AmbientParticleFieldState extends State<AmbientParticleField>
    with WidgetsBindingObserver {
  static const Duration _activeInterval = Duration(milliseconds: 33);
  static const Duration _quietInterval = Duration(milliseconds: 67);
  static const Duration _idleAfter = Duration(seconds: 20);

  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  final Stopwatch _runClock = Stopwatch();
  Timer? _frameTimer;
  Duration _clockOffset = Duration.zero;
  DateTime _lastInteraction = DateTime.now();
  bool _appActive = true;
  bool _reduceMotion = false;
  bool _routeVisible = true;
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _routeVisible = ModalRoute.of(context)?.isCurrent ?? true;
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant AmbientParticleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isBusy != widget.isBusy) _rescheduleFrame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncClock();
  }

  void _handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent || !_routeVisible) return;
    final wasIdle = DateTime.now().difference(_lastInteraction) >= _idleAfter;
    _lastInteraction = DateTime.now();
    if (wasIdle && !widget.isBusy) _rescheduleFrame(immediate: true);
  }

  bool get _shouldRun =>
      _appActive &&
      !_reduceMotion &&
      _routeVisible &&
      _tickerModeEnabled &&
      YanciTheme.starEnabled;

  Duration get _frameInterval {
    final idle = DateTime.now().difference(_lastInteraction) >= _idleAfter;
    return widget.isBusy || idle ? _quietInterval : _activeInterval;
  }

  void _syncClock() {
    if (!_shouldRun) {
      _stopClock();
      if (_reduceMotion) _clock.value = 0;
      return;
    }
    if (!_runClock.isRunning) _runClock.start();
    _scheduleFrame(Duration.zero);
  }

  void _stopClock() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (_runClock.isRunning) {
      _clockOffset += _runClock.elapsed;
      _runClock
        ..stop()
        ..reset();
    }
  }

  void _rescheduleFrame({bool immediate = false}) {
    if (!_shouldRun) return;
    _frameTimer?.cancel();
    _frameTimer = null;
    _scheduleFrame(immediate ? Duration.zero : _frameInterval);
  }

  void _scheduleFrame(Duration delay) {
    if (!_shouldRun || _frameTimer != null) return;
    _frameTimer = Timer(delay, _publishFrame);
  }

  void _publishFrame() {
    _frameTimer = null;
    if (!_shouldRun) {
      _stopClock();
      return;
    }
    final elapsed = _clockOffset + _runClock.elapsed;
    _clock.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _scheduleFrame(_frameInterval);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handlePointerEvent,
    );
    WidgetsBinding.instance.removeObserver(this);
    _stopClock();
    _clock.dispose();
    super.dispose();
  }

  int _scaledCount(int baseCount) {
    final scale = (YanciTheme.starDensity / 12.0).clamp(0.4, 1.6);
    return max(1, (baseCount * scale).round());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: YanciTheme.particleRevision,
      builder: (context, _, _) => _buildParticleField(),
    );
  }

  Widget _buildParticleField() {
    final selected = YanciTheme.particleEffectIds.contains(widget.effect)
        ? widget.effect!
        : YanciTheme.particleEffect;
    final childKey = ValueKey(
      'ambient-$selected-${YanciTheme.starDensity}-'
      '${YanciTheme.starColor.toARGB32()}-${YanciTheme.starGlow.toARGB32()}',
    );

    final child = switch (selected) {
      'stars' => StarfieldWidget(
        key: childKey,
        clock: _clock,
        starCount: _scaledCount(widget.starCount),
      ),
      'rain' => RainWidget(
        key: childKey,
        clock: _clock,
        dropCount: _scaledCount(widget.rainCount),
      ),
      'ripple' => RippleParticleWidget(
        key: childKey,
        clock: _clock,
        rippleCount: _scaledCount(widget.rippleCount),
      ),
      'ember' => EmberParticleWidget(
        key: childKey,
        clock: _clock,
        emberCount: _scaledCount(widget.emberCount),
      ),
      'dandelion' => DandelionParticleWidget(
        key: childKey,
        clock: _clock,
        seedCount: _scaledCount(widget.dandelionCount),
      ),
      _ => NeuralFieldWidget(
        key: childKey,
        clock: _clock,
        nodeCount: _scaledCount(widget.neuralCount),
      ),
    };

    return IgnorePointer(child: ExcludeSemantics(child: child));
  }
}

// ─────────────────────────────────────────────────────────────
// 1. 偶發漣漪（落水波紋）— RippleParticleWidget
// ─────────────────────────────────────────────────────────────

class _RippleSlot {
  final double x;
  final double y;
  final double impact; // 0.0(微滴輕點) ~ 1.0(大水滴重砸)，決定衝擊力與圈大小
  final double maxRadiusX;
  final double aspectRatio; // 垂直/水平軸比例（扁橢圓透視）
  final double baseOpacity;
  final double phase;
  final int cycles;

  const _RippleSlot({
    required this.x,
    required this.y,
    required this.impact,
    required this.maxRadiusX,
    required this.aspectRatio,
    required this.baseOpacity,
    required this.phase,
    required this.cycles,
  });
}

/// 偶發漣漪：水滴墜落砸入水面（小水滴配小圈、大水滴配大圈），內圈先平息、散開時向兩側模糊化開
class RippleParticleWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int rippleCount;

  const RippleParticleWidget({
    super.key,
    required this.clock,
    this.rippleCount = 7,
  }) : assert(rippleCount > 0);

  @override
  State<RippleParticleWidget> createState() => _RippleParticleWidgetState();
}

class _RippleParticleWidgetState extends State<RippleParticleWidget> {
  late final List<_RippleSlot> _ripples;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _ripples = _generateRipples();
  }

  List<_RippleSlot> _generateRipples() {
    return List.generate(widget.rippleCount, (index) {
      // 均勻錯開相位，避免同時出現或同時空白
      final basePhase =
          (index + _random.nextDouble() * 0.6) / widget.rippleCount;
      final y = 0.18 + _random.nextDouble() * 0.68;

      // 透視規律：越靠螢幕上方（遠處水面）橢圓越扁、尺寸略小；越靠下方（近處水面）略微圓潤、尺寸略大
      final depthFactor = ((y - 0.18) / 0.68).clamp(0.0, 1.0);
      final aspect =
          0.30 + depthFactor * 0.14 + (_random.nextDouble() - 0.5) * 0.04;

      // 水滴衝擊力量級（0.0 ~ 1.0）：小水滴偏多，偶爾出現飽滿的大水滴，更有自然節奏
      final rawImpact = pow(_random.nextDouble(), 1.25).toDouble();
      final impact = (0.12 + rawImpact * 0.88).clamp(0.12, 1.0);

      // 衝擊力直接決定圈的最大半徑（小水滴 22~36px，大水滴 55~82px，再疊加遠近透視）
      final baseRadius = 20.0 + impact * 54.0;
      final radiusX = baseRadius * (0.78 + depthFactor * 0.34);

      // 大衝擊力的水滴激起的波峰稍微更亮一些，且因為擴散遠，用 1 週期慢速走完
      final opacity = (0.15 + impact * 0.22).clamp(0.15, 0.38);
      final cycles = impact > 0.62 ? 1 : (_random.nextBool() ? 1 : 2);

      // 把可用寬度切成等份，再於各自區段內取隨機落點。
      // 低密度只剩少量漣漪時仍會覆蓋左、中、右，不會因一次亂數
      // 全落在同一側，接著整個動畫週期反覆使用偏側的固定落點。
      final horizontalBand = 0.76 / widget.rippleCount;
      final x = 0.12 + horizontalBand * (index + _random.nextDouble());

      return _RippleSlot(
        x: x,
        y: y,
        impact: impact,
        maxRadiusX: radiusX,
        aspectRatio: aspect.clamp(0.28, 0.46),
        baseOpacity: opacity,
        phase: basePhase % 1.0,
        cycles: cycles,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RipplePainter(ripples: _ripples, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final List<_RippleSlot> ripples;
  final ValueListenable<double> clock;

  _RipplePainter({required this.ripples, required this.clock})
    : super(repaint: clock);

  /// 繪製單圈水紋：初生時銳利清晰，隨 ringP 推進逐漸展寬筆畫並拉高模糊，以圈線為中心向兩側化開消失
  void _drawWaterRing(
    Canvas canvas,
    Offset center,
    double rx,
    double ry,
    double ringP, // 該圈自身的生命進度 0.0(初生) -> 1.0(徹底化開)
    Color baseColor,
    Color glowColor,
    double peakAlpha,
    double baseStroke,
  ) {
    if (ringP <= 0.0 || ringP >= 1.0 || rx <= 0.5 || ry <= 0.2) return;

    // 整體生命包絡線：前 12% 快速浮現，之後平滑衰減
    final fade = ringP < 0.12
        ? (ringP / 0.12)
        : pow(1.0 - (ringP - 0.12) / 0.88, 1.55).toDouble();
    final alpha = (peakAlpha * fade).clamp(0.0, 1.0);
    if (alpha <= 0.008) return;

    final rect = Rect.fromCenter(
      center: center,
      width: rx * 2.0,
      height: ry * 2.0,
    );

    // ── 核心物理：散開時以圈線為中心向內外兩側模糊化開 ──
    // 隨著 ringP 從 0 -> 1，模糊半徑從 0.6 一路拉高到 5.2，線寬也從 1x 張開到 4.2x
    final disperseCurve = pow(ringP, 1.45).toDouble();
    final blurSigma = 0.6 + disperseCurve * 4.6;
    final spreadWidth = baseStroke * (1.0 + disperseCurve * 3.2);

    // 1. 向圈線兩側散開的水霧柔光帶（越到尾聲越寬、越柔，像融進水裡）
    final diffusePaint = Paint()
      ..color = baseColor.withValues(alpha: (alpha * 0.62).clamp(0.0, 0.7))
      ..style = PaintingStyle.stroke
      ..strokeWidth = spreadWidth
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
    canvas.drawOval(rect, diffusePaint);

    // 2. 整圈連貫的細水紋（在後半段隨模糊拉高而提前淡出，交棒給上面的模糊帶）
    final sharpRetention = pow(1.0 - ringP, 1.8).toDouble();
    final coreAlpha = (alpha * 0.55 * sharpRetention).clamp(0.0, 1.0);
    if (coreAlpha > 0.01) {
      final basePaint = Paint()
        ..color = baseColor.withValues(alpha: coreAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = baseStroke * (0.85 + ringP * 0.4);
      canvas.drawOval(rect, basePaint);
    }

    // 3. 前後波峰受光高光弧（剛激起時清晰清脆，散開過程中逐漸軟化融入水霧）
    final crestAlpha = (alpha * sharpRetention).clamp(0.0, 1.0);
    if (crestAlpha > 0.012) {
      final crestBlur = ringP * 1.8;
      final crestPaint = Paint()
        ..color = baseColor.withValues(alpha: crestAlpha)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = baseStroke * (1.15 - ringP * 0.25)
        ..maskFilter = crestBlur > 0.2
            ? MaskFilter.blur(BlurStyle.normal, crestBlur)
            : null;

      // 前緣迎光主波峰（下方弧段）
      canvas.drawArc(rect, pi * 0.18, pi * 0.64, false, crestPaint);

      // 後緣次波峰（上方弧段）
      final backCrestPaint = Paint()
        ..color = baseColor.withValues(
          alpha: (crestAlpha * 0.76).clamp(0.0, 1.0),
        )
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = baseStroke * (0.95 - ringP * 0.2)
        ..maskFilter = crestBlur > 0.2
            ? MaskFilter.blur(BlurStyle.normal, crestBlur)
            : null;
      canvas.drawArc(rect, pi * 1.22, pi * 0.56, false, backCrestPaint);
    }
  }

  /// 繪製水滴「墜落砸入 ＋ 水坑閃光 ＋ 回彈水珠」，強度完全與 impact 掛鉤
  void _drawDropImpact(
    Canvas canvas,
    Offset center,
    _RippleSlot r,
    double p, // 整體活躍進度 0.0 -> 1.0
    Color baseColor,
  ) {
    // 階段 A：水滴從上方急速墜落砸向水心（p: 0.0 -> 0.075）
    const strikeEnd = 0.075;
    if (p < strikeEnd) {
      final sp = p / strikeEnd; // 0.0(高處) -> 1.0(砸中水面)
      // 重力加速曲線：越接近水面越快
      final accel = sp * sp;
      final fallHeight = (10.0 + r.impact * 22.0) * r.aspectRatio * 2.2;
      final headY = center.dy - (1.0 - accel) * fallHeight;
      // 尾跡長度隨速度拉長，在接觸水面瞬間收縮砸入
      final streakLen =
          (3.5 + r.impact * 11.0) * sin(sp * pi * 0.85).clamp(0.2, 1.0);
      final tailY = headY - streakLen;

      final strikeAlpha =
          (r.baseOpacity * (0.7 + r.impact * 0.6) * sin(sp * pi)).clamp(
            0.0,
            0.9,
          );
      if (strikeAlpha > 0.01) {
        final streakPaint = Paint()
          ..color = baseColor.withValues(alpha: strikeAlpha)
          ..strokeWidth = 0.65 + r.impact * 0.65
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(center.dx, tailY),
          Offset(center.dx, headY),
          streakPaint,
        );
      }
      return;
    }

    // 階段 B：砸入水面瞬間的凹坑橫向閃光 ＋ 水柱回彈（p: 0.075 -> 0.27）
    const splashSpan = 0.195;
    final ip = (p - strikeEnd) / splashSpan; // 0.0(剛砸中) -> 1.0(水珠落回)
    if (ip < 0.0 || ip >= 1.0) return;

    // 1. 砸中瞬間的扁平水坑折光（大衝擊力時明顯炸開一下，小水滴僅微弱一點）
    if (ip < 0.55) {
      final flashP = ip / 0.55;
      final flashAlpha =
          (1.0 - flashP) * r.baseOpacity * (0.9 + r.impact * 0.85);
      final craterW = (2.8 + r.impact * 6.5) * (0.5 + flashP * 0.7);
      final craterH = craterW * r.aspectRatio;
      final splashRect = Rect.fromCenter(
        center: center,
        width: craterW,
        height: craterH,
      );
      final splashPaint = Paint()
        ..color = baseColor.withValues(alpha: flashAlpha.clamp(0.0, 0.9))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.8 + r.impact * 1.2);
      canvas.drawOval(splashRect, splashPaint);
    }

    // 2. 反作用力向上彈起的回跳水珠（小衝擊力 < 0.28 時幾乎不彈起，大衝擊力彈得高且清晰）
    if (r.impact > 0.25) {
      final jetStrength = ((r.impact - 0.25) / 0.75).clamp(0.0, 1.0);
      // 拋物線運動：向上衝起 -> 頂點微頓 -> 重力落回水心
      final parabola = sin(ip * pi);
      final bounceHeight = (1.5 + jetStrength * 5.2) * parabola;
      final beadCenter = Offset(center.dx, center.dy - bounceHeight);
      final beadRadius = (0.65 + jetStrength * 0.85) * (1.0 - ip * 0.55);
      final beadAlpha =
          (1.0 - pow(ip, 1.4).toDouble()) *
          r.baseOpacity *
          (0.85 + jetStrength * 0.7);

      if (beadAlpha > 0.015) {
        final beadPaint = Paint()
          ..color = baseColor.withValues(alpha: beadAlpha.clamp(0.0, 0.92))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.4);
        canvas.drawCircle(beadCenter, beadRadius.clamp(0.3, 1.6), beadPaint);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = (clock.value / 16.0) % 1.0;
    final baseColor = YanciTheme.starColor;
    final glowColor = YanciTheme.starGlow;

    for (final r in ripples) {
      final cyclePos = (t * r.cycles + r.phase) % 1.0;

      // 每個週期前 70% 時間為活躍期（含墜落＋擴散），後 30% 留白靜止
      const activePortion = 0.70;
      if (cyclePos > activePortion) continue;

      final p = cyclePos / activePortion; // 0.0 -> 1.0
      final center = Offset(r.x * size.width, r.y * size.height);

      // 先畫水滴墜落與砸入水心的動態
      _drawDropImpact(canvas, center, r, p, baseColor);

      // 水滴在 p = 0.075 砸中水面後，漣漪才正式從中心往外炸開
      const strikeOffset = 0.075;
      if (p <= strikeOffset) continue;
      final waveP = (p - strikeOffset) / (1.0 - strikeOffset); // 0.0 -> 1.0

      final baseStroke = 0.72 + r.impact * 0.48;

      // ── 第一圈：最外層主波（帶走最多能量，活滿全程 0.0 -> 1.0，推到最遠才化開）──
      final eased1 = 1.0 - pow(1.0 - waveP, 2.35).toDouble();
      final rx1 = r.maxRadiusX * eased1;
      final ry1 = rx1 * r.aspectRatio;
      _drawWaterRing(
        canvas,
        center,
        rx1,
        ry1,
        waveP,
        baseColor,
        glowColor,
        r.baseOpacity,
        baseStroke,
      );

      // ── 第二圈：中層次波（能量較小，在 waveP = 0.08 浮現，到 0.72 就提前化開消失）──
      const ring2Start = 0.08;
      const ring2Life = 0.64; // 0.08 + 0.64 = 0.72 結束（比外圈早消散）
      if (waveP > ring2Start && waveP < ring2Start + ring2Life) {
        final ring2P = (waveP - ring2Start) / ring2Life; // 0.0 -> 1.0
        final eased2 = 1.0 - pow(1.0 - ring2P, 2.15).toDouble();
        final rx2 = r.maxRadiusX * 0.62 * eased2;
        final ry2 = rx2 * r.aspectRatio;
        _drawWaterRing(
          canvas,
          center,
          rx2,
          ry2,
          ring2P,
          baseColor,
          glowColor,
          r.baseOpacity * 0.76,
          baseStroke * 0.82,
        );
      }

      // ── 第三圈：最內層餘波（僅大水滴激起，且在 waveP = 0.48 前就早早融化，讓水心先歸於平靜）──
      const ring3Start = 0.16;
      const ring3Life = 0.32; // 0.16 + 0.32 = 0.48 結束（最先消散！）
      if (r.impact > 0.62 &&
          waveP > ring3Start &&
          waveP < ring3Start + ring3Life) {
        final ring3P = (waveP - ring3Start) / ring3Life; // 0.0 -> 1.0
        final eased3 = 1.0 - pow(1.0 - ring3P, 1.85).toDouble();
        final rx3 = r.maxRadiusX * 0.32 * eased3;
        final ry3 = rx3 * r.aspectRatio;
        _drawWaterRing(
          canvas,
          center,
          rx3,
          ry3,
          ring3P,
          baseColor,
          glowColor,
          r.baseOpacity * 0.52,
          baseStroke * 0.68,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) {
    return !identical(oldDelegate.ripples, ripples);
  }
}

// ─────────────────────────────────────────────────────────────
// 2. 逆流餘燼（往上飄的微光）— EmberParticleWidget
// ─────────────────────────────────────────────────────────────

class _Ember {
  final double x;
  final double startY;
  final double travelDistance;
  final double size;
  final double opacity;
  final double swayAmp;
  final double swayPhase;
  final int swayWaves;
  final double phase;
  final int cycles;

  const _Ember({
    required this.x,
    required this.startY,
    required this.travelDistance,
    required this.size,
    required this.opacity,
    required this.swayAmp,
    required this.swayPhase,
    required this.swayWaves,
    required this.phase,
    required this.cycles,
  });
}

/// 逆流餘燼：從螢幕中下方緩慢升起的溫暖微光，伴隨熱氣流 S 型搖曳並在中段熄滅
class EmberParticleWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int emberCount;

  const EmberParticleWidget({
    super.key,
    required this.clock,
    this.emberCount = 22,
  }) : assert(emberCount > 0);

  @override
  State<EmberParticleWidget> createState() => _EmberParticleWidgetState();
}

class _EmberParticleWidgetState extends State<EmberParticleWidget> {
  late final List<_Ember> _embers;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _embers = _generateEmbers();
  }

  List<_Ember> _generateEmbers() {
    return List.generate(widget.emberCount, (_) {
      return _Ember(
        x: 0.06 + _random.nextDouble() * 0.88,
        startY: 0.78 + _random.nextDouble() * 0.26, // 從底部 78%~104% 處升起
        travelDistance: 0.42 + _random.nextDouble() * 0.36, // 向上飄移距離
        size: 1.0 + _random.nextDouble() * 2.0, // 1.0~3.0px
        opacity: 0.25 + _random.nextDouble() * 0.45,
        swayAmp: 6.0 + _random.nextDouble() * 14.0, // S 型擺幅 px
        swayPhase: _random.nextDouble() * 2 * pi,
        swayWaves: _random.nextBool() ? 1 : 2,
        phase: _random.nextDouble(),
        cycles: _random.nextBool() ? 1 : 2,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _EmberPainter(embers: _embers, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _EmberPainter extends CustomPainter {
  final List<_Ember> embers;
  final ValueListenable<double> clock;

  _EmberPainter({required this.embers, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (clock.value / 14.0) % 1.0;
    final baseColor = YanciTheme.starColor;
    final glowColor = YanciTheme.starGlow;

    for (final e in embers) {
      final u = (t * e.cycles + e.phase) % 1.0; // 0.0(剛升起) -> 1.0(燃盡消失)

      // 垂直位置：由下往上飄
      final currentY = (e.startY - u * e.travelDistance) * size.height;
      if (currentY < -10 || currentY > size.height + 10) continue;

      // 水平位置：隨上升氣流 S 型搖擺（越往上擺幅稍微放大）
      final sway =
          sin(u * 2 * pi * e.swayWaves + e.swayPhase) *
          e.swayAmp *
          (0.6 + u * 0.6);
      final currentX = e.x * size.width + sway;

      // 亮度包絡線：前 18% 漸亮，後段隨上升逐漸冷卻變暗並縮小
      final envelope = u < 0.18
          ? (u / 0.18)
          : pow(1.0 - (u - 0.18) / 0.82, 1.5).toDouble();

      // 微弱的火光呼吸閃動
      final flicker = 0.85 + 0.15 * sin(u * 2 * pi * 3.0 + e.swayPhase);
      final alpha = (e.opacity * envelope * flicker).clamp(0.0, 0.95);
      if (alpha < 0.02) continue;

      // 尺寸隨燃盡微微收縮
      final currentSize = e.size * (1.0 - u * 0.45);
      final offset = Offset(currentX, currentY);

      // 多層半透明圓保留暖光暈，避免每顆餘燼逐幀高斯模糊。
      canvas.drawCircle(
        offset,
        currentSize * 1.8,
        Paint()
          ..color = glowColor.withValues(
            alpha: (alpha * 0.14).clamp(0.0, 0.20),
          ),
      );
      canvas.drawCircle(
        offset,
        currentSize * 1.3,
        Paint()
          ..color = glowColor.withValues(
            alpha: (alpha * 0.25).clamp(0.0, 0.34),
          ),
      );
      canvas.drawCircle(
        offset,
        currentSize,
        Paint()..color = baseColor.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EmberPainter oldDelegate) {
    return !identical(oldDelegate.embers, embers);
  }
}

// ─────────────────────────────────────────────────────────────
// 3. 蒲公英絨（無重力隨風）— DandelionParticleWidget
// ─────────────────────────────────────────────────────────────

class _DandelionSeed {
  final double startX;
  final double startY;
  final double driftX;
  final double driftY;
  final double size;
  final double opacity;
  final double bobAmp;
  final double phase;
  final double gustPhase;
  final int gusts;

  const _DandelionSeed({
    required this.startX,
    required this.startY,
    required this.driftX,
    required this.driftY,
    required this.size,
    required this.opacity,
    required this.bobAmp,
    required this.phase,
    required this.gustPhase,
    required this.gusts,
  });
}

/// 蒲公英絨：帶著毛茸茸柔光的小光點，「停頓懸浮 —— 被微風吹動斜飄 —— 再停頓」的無重力節奏
class DandelionParticleWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int seedCount;

  const DandelionParticleWidget({
    super.key,
    required this.clock,
    this.seedCount = 16,
  }) : assert(seedCount > 0);

  @override
  State<DandelionParticleWidget> createState() =>
      _DandelionParticleWidgetState();
}

class _DandelionParticleWidgetState extends State<DandelionParticleWidget> {
  late final List<_DandelionSeed> _seeds;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _seeds = _generateSeeds();
  }

  List<_DandelionSeed> _generateSeeds() {
    return List.generate(widget.seedCount, (_) {
      return _DandelionSeed(
        startX: _random.nextDouble(),
        startY: _random.nextDouble(),
        // 斜向微風位移：緩慢往右上或右下斜飄
        driftX: 0.14 + _random.nextDouble() * 0.18,
        driftY: (_random.nextDouble() - 0.45) * 0.16,
        size: 1.4 + _random.nextDouble() * 1.8, // 1.4~3.2px
        opacity: 0.22 + _random.nextDouble() * 0.38,
        bobAmp: 4.0 + _random.nextDouble() * 7.0, // 停頓時的上下浮沉感 px
        phase: _random.nextDouble(),
        gustPhase: _random.nextDouble() * 2 * pi,
        gusts: _random.nextInt(2) + 2, // 單次循環內經歷 2~3 次微風吹拂與停頓
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DandelionPainter(seeds: _seeds, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _DandelionPainter extends CustomPainter {
  final List<_DandelionSeed> seeds;
  final ValueListenable<double> clock;

  _DandelionPainter({required this.seeds, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (clock.value / 20.0) % 1.0;
    final baseColor = YanciTheme.starColor;

    for (final s in seeds) {
      final u = (t + s.phase) % 1.0;

      // 非勻速微風曲線：導數 = 1 + 0.82*cos(...)，在波谷處幾乎停滯懸浮，波峰處隨風斜飄
      final omega = 2 * pi * s.gusts;
      final windAdvance =
          u + (sin(omega * u + s.gustPhase) - sin(s.gustPhase)) / omega * 0.82;

      final rawX = (s.startX + windAdvance * s.driftX) % 1.0;
      final rawY = (s.startY + windAdvance * s.driftY) % 1.0;

      // 無重力上下輕微浮沉
      final bobOffset = sin(u * 2 * pi * s.gusts + s.gustPhase) * s.bobAmp;

      final currentX = rawX * size.width;
      final currentY = rawY * size.height + bobOffset;

      // 生命週期首尾柔和淡入淡出，避免跨越邊界時閃跳
      final edgeFade = u < 0.10
          ? (u / 0.10)
          : u > 0.90
          ? ((1.0 - u) / 0.10)
          : 1.0;
      final alpha = (s.opacity * edgeFade).clamp(0.0, 0.9);
      if (alpha < 0.02) continue;

      final center = Offset(currentX, currentY);

      // 1. 疊色軟圈模擬絨毛，避免逐粒高斯模糊。
      canvas.drawCircle(
        center,
        s.size * 2.0,
        Paint()..color = baseColor.withValues(alpha: alpha * 0.10),
      );
      canvas.drawCircle(
        center,
        s.size * 1.35,
        Paint()..color = baseColor.withValues(alpha: alpha * 0.22),
      );

      // 2. 內層柔光核心
      canvas.drawCircle(
        center,
        s.size * 0.75,
        Paint()..color = baseColor.withValues(alpha: alpha * 0.9),
      );

      // 3. 若隱若現的極細絨絲小尾巴（隨風微微擺動角度）
      if (s.size > 1.8) {
        final swayAngle =
            -0.35 + 0.25 * cos(omega * u + s.gustPhase); // 隨風力傾角變化
        final stemLen = s.size * 2.6;
        final tailOffset = Offset(
          center.dx + sin(swayAngle) * stemLen,
          center.dy + cos(swayAngle) * stemLen,
        );
        final stemPaint = Paint()
          ..color = baseColor.withValues(alpha: alpha * 0.32)
          ..strokeWidth = 0.55
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(center, tailOffset, stemPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DandelionPainter oldDelegate) {
    return !identical(oldDelegate.seeds, seeds);
  }
}
