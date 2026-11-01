import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import '../theme/app_theme.dart';
import 'ambient_particles_extra.dart';
import 'neural_field.dart';
import 'rain_painter.dart';
import 'starfield_painter.dart';

export 'ambient_particles_extra.dart'
    show
        EmojiRainWidget,
        FireworkWidget,
        GoldDustWidget,
        SkyWidget,
        SparkBurstWidget;

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
  final int goldCount;
  final int sparkCount;
  final int cloudCount;
  final int fireworkCount;
  final int emojiCount;

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
    this.goldCount = 30,
    this.sparkCount = 26,
    this.cloudCount = 6,
    this.fireworkCount = 26,
    this.emojiCount = 10,
  });

  /// 1～50 的每一段都要有意義，同時保留既有三個視覺錨點：
  /// 1 = 0.4x、12 = 1.0x（預設）、50 = 1.6x（既有最高密度）。
  /// 這不提高目前最高粒子量，只修掉 20～50 以前全部卡在 1.6x 的假範圍。
  static double densityScaleFor(int density) {
    final value = density.clamp(1, 50);
    if (value <= 12) {
      return 0.4 + ((value - 1) / 11) * 0.6;
    }
    return 1.0 + ((value - 12) / 38) * 0.6;
  }

  @override
  State<AmbientParticleField> createState() => _AmbientParticleFieldState();
}

class _AmbientParticleFieldState extends State<AmbientParticleField>
    with WidgetsBindingObserver {
  // 幀要跟螢幕 vsync 對齊：以前純 Timer 推幀會和螢幕刷新錯開，有時兩次更新擠在
  // 同一幀、有時空一格，連續移動（雨、漣漪）看起來一頓一頓。
  // 做法：Timer 只負責「睡到快要該更新的時候」，醒來後向排程器要一個 frame
  // callback，在下一個 vsync 才更新時鐘。這樣更新一定落在真正要畫的那一幀，
  // 而且只在需要時才要幀（不像 Ticker 會每個 vsync 都觸發一次合成，
  // 在 120Hz 螢幕上會讓毛玻璃等效果每秒重算 120 次）。
  // 正常 60fps；閒置或聊天正在忙時 30fps。退後台、路由被蓋住、reduce motion 一律停止。
  static const Duration _activeInterval = Duration(microseconds: 16667);
  static const Duration _quietInterval = Duration(microseconds: 33333);

  /// Timer 提早醒來的量，讓「要幀」剛好趕上目標時間點前最近的 vsync。
  static const Duration _vsyncLead = Duration(milliseconds: 4);
  static const Duration _idleAfter = Duration(seconds: 20);

  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  final Stopwatch _runClock = Stopwatch();
  Timer? _frameTimer;
  int? _frameCallbackId;
  Duration _clockOffset = Duration.zero;
  DateTime _lastInteraction = DateTime.now();
  bool _appActive = true;
  bool _reduceMotion = false;
  bool _routeVisible = true;
  bool _tickerModeEnabled = true;

  // ── 自適應降級（防弱機閃退）──
  // 連續慢幀就降一級粒子量；只降不升，避免粒子反覆重建「跳一下」。
  // 換頁／重開後是新的 State，自然回到滿級。
  static const List<double> _perfLevels = [1.0, 0.75, 0.55, 0.4];
  int _perfLevel = 0;
  int _slowFrameStreak = 0;
  final Stopwatch _frameGap = Stopwatch();

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
    // 從閒置回到操作：立刻要一幀，不必等滿 30fps 的間隔。
    if (wasIdle && !widget.isBusy) _rescheduleFrame(immediate: true);
  }

  bool get _shouldRun =>
      _appActive &&
      !_reduceMotion &&
      _routeVisible &&
      _tickerModeEnabled &&
      YanciTheme.starEnabled;

  /// 本身動得很慢的效果，60fps 看不出差別，固定走 30fps。
  static const Set<String> _slowEffects = {'sky', 'gold'};

  String get _selectedEffect =>
      YanciTheme.particleEffectIds.contains(widget.effect)
      ? widget.effect!
      : YanciTheme.particleEffect;

  Duration get _frameInterval {
    final idle = DateTime.now().difference(_lastInteraction) >= _idleAfter;
    return widget.isBusy || idle || _slowEffects.contains(_selectedEffect)
        ? _quietInterval
        : _activeInterval;
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

  void _cancelPendingFrame() {
    _frameTimer?.cancel();
    _frameTimer = null;
    final id = _frameCallbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _frameCallbackId = null;
    }
  }

  void _stopClock() {
    _cancelPendingFrame();
    // 暫停期間的空檔不能算成慢幀。
    _frameGap
      ..stop()
      ..reset();
    _slowFrameStreak = 0;
    if (_runClock.isRunning) {
      _clockOffset += _runClock.elapsed;
      _runClock
        ..stop()
        ..reset();
    }
  }

  void _rescheduleFrame({bool immediate = false}) {
    if (!_shouldRun) return;
    _cancelPendingFrame();
    _scheduleFrame(immediate ? Duration.zero : _frameInterval - _vsyncLead);
  }

  void _scheduleFrame(Duration delay) {
    if (!_shouldRun || _frameTimer != null || _frameCallbackId != null) return;
    _frameTimer = Timer(delay, () {
      _frameTimer = null;
      if (!_shouldRun) {
        _stopClock();
        return;
      }
      _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
        _onFrame,
      );
    });
  }

  void _onFrame(Duration _) {
    _frameCallbackId = null;
    if (!_shouldRun) {
      _stopClock();
      return;
    }
    _trackFrameBudget();
    // 位置一律由真實經過時間決定，掉幀時粒子仍在正確位置。
    final elapsed = _clockOffset + _runClock.elapsed;
    _clock.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _scheduleFrame(_frameInterval - _vsyncLead);
  }

  /// 兩次更新的實際間隔比預定間隔多出 3 倍以上（30fps 時約 >100ms）算慢幀；
  /// 連續 6 次才降級，偶發的 GC 或切頁卡頓不會誤判。
  void _trackFrameBudget() {
    if (_frameGap.isRunning) {
      final gap = _frameGap.elapsedMicroseconds;
      final budget = _frameInterval.inMicroseconds * 3;
      if (gap > budget) {
        _slowFrameStreak++;
        if (_slowFrameStreak >= 6 && _perfLevel < _perfLevels.length - 1) {
          _slowFrameStreak = 0;
          _perfLevel++;
          if (mounted) setState(() {});
        }
      } else {
        _slowFrameStreak = 0;
      }
    }
    _frameGap
      ..reset()
      ..start();
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

  /// 每種效果的粒子硬上限：密度拉滿也不會超過，弱機不至於被壓垮。
  /// 密度滑桿最大值（主題工坊 1–50）。
  static const int _maxDensity = 50;

  static const Map<String, int> _maxParticles = {
    'neural': 30,
    'stars': 40,
    'rain': 48,
    'ripple': 12,
    'ember': 36,
    'dandelion': 28,
    'gold': 45,
    'spark': 40,
    'sky': 9,
    'firework': 40,
    'emoji': 18,
  };

  int _scaledCount(int baseCount, String effect) {
    final scale = AmbientParticleField.densityScaleFor(YanciTheme.starDensity);
    final raw = (baseCount * scale * _perfLevels[_perfLevel]).round();
    return raw.clamp(1, _maxParticles[effect] ?? 30).toInt();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: YanciTheme.particleRevision,
      builder: (context, _, _) => _buildParticleField(),
    );
  }

  Widget _buildParticleField() {
    final selected = _selectedEffect;
    final childKey = ValueKey(
      'ambient-$selected-${YanciTheme.starDensity}-'
      '${YanciTheme.starColor.toARGB32()}-${YanciTheme.starGlow.toARGB32()}-'
      'p$_perfLevel${selected == 'emoji' ? '-${YanciTheme.particleEmojis.join()}' : ''}'
      '${selected == 'sky' ? '-${YanciTheme.cloudStyle}' : ''}',
    );

    final child = switch (selected) {
      'stars' => StarfieldWidget(
        key: childKey,
        clock: _clock,
        starCount: _scaledCount(widget.starCount, 'stars'),
      ),
      'rain' => RainWidget(
        key: childKey,
        clock: _clock,
        dropCount: _scaledCount(widget.rainCount, 'rain'),
      ),
      'ripple' => RippleParticleWidget(
        key: childKey,
        clock: _clock,
        rippleCount: _scaledCount(widget.rippleCount, 'ripple'),
      ),
      'ember' => EmberParticleWidget(
        key: childKey,
        clock: _clock,
        emberCount: _scaledCount(widget.emberCount, 'ember'),
      ),
      'gold' => GoldDustWidget(
        key: childKey,
        clock: _clock,
        flakeCount: _scaledCount(widget.goldCount, 'gold'),
      ),
      'spark' => SparkBurstWidget(
        key: childKey,
        clock: _clock,
        sparkCount: _scaledCount(widget.sparkCount, 'spark'),
      ),
      'sky' => SkyWidget(
        key: childKey,
        clock: _clock,
        cloudCount: _scaledCount(widget.cloudCount, 'sky'),
      ),
      'firework' => FireworkWidget(
        key: childKey,
        clock: _clock,
        sparkCount: _scaledCount(widget.fireworkCount, 'firework'),
        // 密度拉滿才有 5% 機率整片齊放。
        salvoChance: YanciTheme.starDensity >= _maxDensity ? 0.05 : 0,
      ),
      'emoji' => EmojiRainWidget(
        key: childKey,
        clock: _clock,
        emojis: YanciTheme.particleEmojis,
        dropCount: _scaledCount(widget.emojiCount, 'emoji'),
      ),
      'dandelion' => DandelionParticleWidget(
        key: childKey,
        clock: _clock,
        seedCount: _scaledCount(widget.dandelionCount, 'dandelion'),
      ),
      _ => NeuralFieldWidget(
        key: childKey,
        clock: _clock,
        nodeCount: _scaledCount(widget.neuralCount, 'neural'),
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
      final opacity = (0.28 + impact * 0.30).clamp(0.28, 0.58);
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
  final Paint _mistOuterPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _mistInnerPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _ringCorePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _crestPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _backCrestPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _strikePaint = Paint()..strokeCap = StrokeCap.round;
  final Paint _splashOuterPaint = Paint();
  final Paint _splashInnerPaint = Paint();
  final Paint _beadPaint = Paint();

  _RipplePainter({required this.ripples, required this.clock})
    : super(repaint: clock);

  /// 繪製單圈水紋：初生時銳利，散開時以兩層寬筆畫向內外化開。
  /// 不使用逐圈動態高斯模糊，避免高密度時每幀反覆建立昂貴濾鏡。
  void _drawWaterRing(
    Canvas canvas,
    Offset center,
    double rx,
    double ry,
    double ringP, // 該圈自身的生命進度 0.0(初生) -> 1.0(徹底化開)
    Color baseColor,
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

    // 兩層低透明度寬線模擬水霧。視覺仍從圈線向兩側化開，
    // 但不再為每一圈、每一幀建立 MaskFilter。
    final disperseCurve = pow(ringP, 1.45).toDouble();
    final spreadWidth = baseStroke * (1.0 + disperseCurve * 3.2);

    _mistOuterPaint
      ..color = baseColor.withValues(alpha: (alpha * 0.18).clamp(0.0, 0.28))
      ..strokeWidth = spreadWidth * 1.75;
    canvas.drawOval(rect, _mistOuterPaint);
    _mistInnerPaint
      ..color = baseColor.withValues(alpha: (alpha * 0.36).clamp(0.0, 0.50))
      ..strokeWidth = spreadWidth;
    canvas.drawOval(rect, _mistInnerPaint);

    // 2. 整圈連貫的細水紋（在後半段隨模糊拉高而提前淡出，交棒給上面的模糊帶）
    final sharpRetention = pow(1.0 - ringP, 1.8).toDouble();
    final coreAlpha = (alpha * 0.72 * sharpRetention).clamp(0.0, 1.0);
    if (coreAlpha > 0.01) {
      _ringCorePaint
        ..color = baseColor.withValues(alpha: coreAlpha)
        ..strokeWidth = baseStroke * (0.85 + ringP * 0.4);
      canvas.drawOval(rect, _ringCorePaint);
    }

    // 3. 前後波峰受光高光弧（剛激起時清晰清脆，散開過程中逐漸軟化融入水霧）
    final crestAlpha = (alpha * sharpRetention).clamp(0.0, 1.0);
    if (crestAlpha > 0.012) {
      _crestPaint
        ..color = baseColor.withValues(alpha: crestAlpha)
        ..strokeWidth = baseStroke * (1.15 - ringP * 0.25);

      // 前緣迎光主波峰（下方弧段）
      canvas.drawArc(rect, pi * 0.18, pi * 0.64, false, _crestPaint);

      // 後緣次波峰（上方弧段）
      _backCrestPaint
        ..color = baseColor.withValues(
          alpha: (crestAlpha * 0.76).clamp(0.0, 1.0),
        )
        ..strokeWidth = baseStroke * (0.95 - ringP * 0.2);
      canvas.drawArc(rect, pi * 1.22, pi * 0.56, false, _backCrestPaint);
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
        _strikePaint
          ..color = baseColor.withValues(alpha: strikeAlpha)
          ..strokeWidth = 0.65 + r.impact * 0.65
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(center.dx, tailY),
          Offset(center.dx, headY),
          _strikePaint,
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
      _splashOuterPaint.color = baseColor.withValues(
        alpha: (flashAlpha * 0.22).clamp(0.0, 0.24),
      );
      canvas.drawOval(
        splashRect.inflate(1.2 + r.impact * 1.8),
        _splashOuterPaint,
      );
      _splashInnerPaint.color = baseColor.withValues(
        alpha: flashAlpha.clamp(0.0, 0.72),
      );
      canvas.drawOval(splashRect, _splashInnerPaint);
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
        _beadPaint.color = baseColor.withValues(
          alpha: beadAlpha.clamp(0.0, 0.92),
        );
        canvas.drawCircle(beadCenter, beadRadius.clamp(0.3, 1.6), _beadPaint);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = (clock.value / 16.0) % 1.0;
    final baseColor = YanciTheme.starColor;

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

      final baseStroke = 1.0 + r.impact * 0.6;

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
        size: 1.6 + _random.nextDouble() * 2.2, // 1.6~3.8px
        opacity: 0.45 + _random.nextDouble() * 0.45,
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
  final Paint _haloOuterPaint = Paint();
  final Paint _haloInnerPaint = Paint();
  final Paint _corePaint = Paint();

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
        _haloOuterPaint
          ..color = glowColor.withValues(
            alpha: (alpha * 0.22).clamp(0.0, 0.30),
          ),
      );
      canvas.drawCircle(
        offset,
        currentSize * 1.3,
        _haloInnerPaint
          ..color = glowColor.withValues(
            alpha: (alpha * 0.38).clamp(0.0, 0.48),
          ),
      );
      canvas.drawCircle(
        offset,
        currentSize,
        _corePaint..color = baseColor.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EmberPainter oldDelegate) {
    return !identical(oldDelegate.embers, embers);
  }
}

// ─────────────────────────────────────────────────────────────
// 3. 飛花（純花瓣；保留 dandelion key 相容舊設定）— DandelionParticleWidget
// ─────────────────────────────────────────────────────────────

class _FallingPetal {
  final double startX;
  final double startY;
  final double driftX;
  final double travelY;
  final double size;
  final double opacity;
  final double swayAmp;
  final double phase;
  final double rotationPhase;
  final int swayWaves;
  final int flipWaves;
  final bool isSnow; // true = 雪花, false = 花瓣

  const _FallingPetal({
    required this.startX,
    required this.startY,
    required this.driftX,
    required this.travelY,
    required this.size,
    required this.opacity,
    required this.swayAmp,
    required this.phase,
    required this.rotationPhase,
    required this.swayWaves,
    required this.flipWaves,
    this.isSnow = false,
  });
}

/// 飛花：花瓣由上方與側上方落下，隨風擺盪並自然翻面。
/// 公開類名與設定 key 保持不變，舊資料不需要遷移。
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
  late final List<_FallingPetal> _petals;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _petals = _generatePetals();
  }

  List<_FallingPetal> _generatePetals() {
    // 純花瓣：不再混雪花（雪花繪製分支留著相容，不會再生成）。
    return List.generate(widget.seedCount, (i) {
      return _FallingPetal(
        startX: -0.08 + _random.nextDouble() * 1.08,
        startY: -0.28 + _random.nextDouble() * 0.34,
        driftX: -0.12 + _random.nextDouble() * 0.34,
        travelY: 1.04 + _random.nextDouble() * 0.34,
        size: 3.5 + _random.nextDouble() * 4.0,
        // 少了雪花的亮點，花瓣本身提亮一點，淺底上才不會太淡。
        opacity: 0.30 + _random.nextDouble() * 0.35,
        swayAmp: 7.0 + _random.nextDouble() * 18.0,
        phase: _random.nextDouble(),
        rotationPhase: _random.nextDouble() * 2 * pi,
        swayWaves: 1 + _random.nextInt(3),
        flipWaves: 2 + _random.nextInt(3),
        isSnow: false,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DandelionPainter(petals: _petals, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _DandelionPainter extends CustomPainter {
  final List<_FallingPetal> petals;
  final ValueListenable<double> clock;
  final Paint _softPaint = Paint()..style = PaintingStyle.fill;
  final Paint _bodyPaint = Paint()..style = PaintingStyle.fill;
  final Path _petalPath = Path()
    ..moveTo(0, -1)
    ..quadraticBezierTo(0.78, -0.35, 0.12, 1)
    ..quadraticBezierTo(-0.64, 0.28, 0, -1)
    ..close();

  _DandelionPainter({required this.petals, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (clock.value / 24.0) % 1.0;
    final baseColor = YanciTheme.starColor;

    for (final petal in petals) {
      final u = (t + petal.phase) % 1.0;
      final swayPhase = u * 2 * pi * petal.swayWaves + petal.rotationPhase;
      final currentX =
          (petal.startX + petal.driftX * u) * size.width +
          sin(swayPhase) * petal.swayAmp;
      final currentY = (petal.startY + petal.travelY * u) * size.height;
      if (currentX < -30 ||
          currentX > size.width + 30 ||
          currentY < -30 ||
          currentY > size.height + 30) {
        continue;
      }

      // 生命週期首尾柔和淡入淡出，避免跨越邊界時閃跳
      final edgeFade = u < 0.10
          ? (u / 0.10)
          : u > 0.90
          ? ((1.0 - u) / 0.10)
          : 1.0;
      final alpha = (petal.opacity * edgeFade).clamp(0.0, 0.78);
      if (alpha < 0.02) continue;

      final flip =
          0.35 +
          0.65 * cos(u * 2 * pi * petal.flipWaves + petal.rotationPhase).abs();
      final rotation =
          petal.rotationPhase * 0.35 +
          sin(swayPhase) * 0.62 +
          petal.driftX * 0.8;

      if (petal.isSnow) {
        // ── 雪花：半透明小圓點 + 柔光暈 ──
        final snowCenter = Offset(currentX, currentY);
        final snowRadius = petal.size * 0.65;
        // 外層柔光
        _softPaint.color = baseColor.withValues(alpha: alpha * 0.18);
        canvas.drawCircle(snowCenter, snowRadius * 1.6, _softPaint);
        // 核心
        _bodyPaint.color = baseColor.withValues(alpha: alpha * 0.92);
        canvas.drawCircle(snowCenter, snowRadius, _bodyPaint);
      } else {
        // ── 花瓣 ──
        canvas
          ..save()
          ..translate(currentX, currentY)
          ..rotate(rotation)
          ..scale(petal.size, petal.size * flip);
        _softPaint.color = baseColor.withValues(alpha: alpha * 0.16);
        canvas
          ..save()
          ..scale(1.18, 1.18)
          ..drawPath(_petalPath, _softPaint)
          ..restore();
        _bodyPaint.color = baseColor.withValues(alpha: alpha);
        canvas
          ..drawPath(_petalPath, _bodyPaint)
          ..restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DandelionPainter oldDelegate) {
    return !identical(oldDelegate.petals, petals);
  }
}
