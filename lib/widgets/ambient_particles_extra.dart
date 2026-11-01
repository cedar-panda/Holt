import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_presets.dart';

// 2026-10-29 新增的四種背景粒子：金粉、電火花、雲朵與日月、emoji 雨。
// 共同原則（防弱機閃退）：
// - 不用逐幀模糊濾鏡；需要柔邊的東西（雲、emoji）在建立時一次烘成 ui.Image。
// - 每幀只做平移／旋轉／縮放與少量 drawLine / drawRect / drawImageRect。
// - Paint 物件重複使用，不在迴圈裡 new。

// ─────────────────────────────────────────────────────────────
// 1. 金粉 — GoldDustWidget
// ─────────────────────────────────────────────────────────────

class _GoldFlake {
  final double x;
  final double y;
  final double speed; // px/s
  final double size;
  final double rotSpeed;
  final double phase;
  final double glintRate;
  final double sway;

  const _GoldFlake({
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
    required this.rotSpeed,
    required this.phase,
    required this.glintRate,
    required this.sway,
  });
}

/// 很細的金色亮片慢慢飄落並翻轉；翻到某個角度會短暫閃一下十字光。
class GoldDustWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int flakeCount;

  const GoldDustWidget({super.key, required this.clock, this.flakeCount = 30})
    : assert(flakeCount > 0);

  @override
  State<GoldDustWidget> createState() => _GoldDustWidgetState();
}

class _GoldDustWidgetState extends State<GoldDustWidget> {
  late final List<_GoldFlake> _flakes;

  @override
  void initState() {
    super.initState();
    final rng = Random();
    double r(double min, double span) => min + rng.nextDouble() * span;
    _flakes = List.generate(
      widget.flakeCount,
      (_) => _GoldFlake(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        speed: r(6, 10),
        size: r(1.2, 1.6),
        rotSpeed: r(-1.5, 3.0),
        phase: rng.nextDouble(),
        glintRate: r(0.25, 0.35),
        sway: r(4, 6),
      ),
      growable: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GoldDustPainter(flakes: _flakes, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _GoldDustPainter extends CustomPainter {
  final List<_GoldFlake> flakes;
  final ValueListenable<double> clock;
  final Paint _flake = Paint()..style = PaintingStyle.fill;
  final Paint _glint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.0;

  _GoldDustPainter({required this.flakes, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = clock.value;
    // 金粉就是金色，不混主題色（混了會發灰發土）。只按底色挑深淺：
    // 暗底用亮金，淺底用飽和的深金，翻面時在暗面和亮面之間閃。
    final (shadowGold, brightGold) = _goldShades();
    final glintColor = YanciTheme.isDark
        ? const Color(0xFFFFF8E1)
        : brightGold;
    final travel = size.height + 24;

    for (final f in flakes) {
      final y = (f.y * travel + t * f.speed) % travel - 12;
      final x =
          f.x * size.width + sin(t * 0.8 + f.phase * 2 * pi) * f.sway;
      final rot = f.phase * 2 * pi + t * f.rotSpeed;
      final face = cos(rot).abs();

      _flake.color = Color.lerp(
        shadowGold,
        brightGold,
        face * face,
      )!.withValues(alpha: 0.55 + 0.4 * face);
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(rot * 0.5)
        ..scale(1, 0.35 + 0.65 * face)
        ..drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: f.size * 2,
            height: f.size * 2,
          ),
          _flake,
        )
        ..restore();

      // 只有正對光的那一瞬間閃：sin^40 讓閃光又短又少。
      final s = sin(t * f.glintRate + f.phase * 2 * pi);
      if (s <= 0.9) continue;
      final glint = pow(s, 40).toDouble();
      if (glint < 0.05) continue;
      final len = f.size * 5 * glint;
      _glint.color = glintColor.withValues(alpha: 0.9 * glint);
      canvas
        ..drawLine(Offset(x - len, y), Offset(x + len, y), _glint)
        ..drawLine(Offset(x, y - len), Offset(x, y + len), _glint);
    }
  }

  static ThemePreset? _goldPreset;
  static (Color, Color) _goldCache = (_deepGold, _paleGold);

  static const Color _paleGold = Color(0xFFFFE08A);
  static const Color _richGold = Color(0xFFF5C542);
  static const Color _deepGold = Color(0xFFC8920F);
  static const Color _darkestGold = Color(0xFF8A6100);

  /// 暗面＋亮面兩個金色。淺底時暗面沿「金 → 深金」找到夠對比的那一格，
  /// 色相一直是金，不會像通用調色那樣被拉向主題紅。
  static (Color, Color) _goldShades() {
    final preset = YanciTheme.preset;
    if (identical(_goldPreset, preset)) return _goldCache;
    _goldPreset = preset;
    if (YanciTheme.isDark) {
      return _goldCache = (_deepGold, _paleGold);
    }
    final bg = YanciTheme.particleBackdrop;
    double contrast(Color c) {
      final a = c.computeLuminance();
      final b = bg.computeLuminance();
      return (max(a, b) + 0.05) / (min(a, b) + 0.05);
    }

    var shadow = _darkestGold;
    for (var i = 0; i <= 10; i++) {
      final c = Color.lerp(_deepGold, _darkestGold, i / 10)!;
      if (contrast(c) >= 2.4) {
        shadow = c;
        break;
      }
    }
    var bright = shadow;
    for (var i = 0; i <= 10; i++) {
      final c = Color.lerp(_richGold, shadow, i / 10)!;
      if (contrast(c) >= 1.6) {
        bright = c;
        break;
      }
    }
    return _goldCache = (shadow, bright);
  }

  @override
  bool shouldRepaint(covariant _GoldDustPainter oldDelegate) =>
      !identical(oldDelegate.flakes, flakes);
}

// ─────────────────────────────────────────────────────────────
// 2. 電火花 — SparkBurstWidget
// ─────────────────────────────────────────────────────────────

class _Spark {
  double x;
  double y;
  double px;
  double py;
  double vx;
  double vy;
  final double life;
  double age = 0;
  bool bounced = false;

  _Spark({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
  }) : px = x,
       py = y;
}

class _Flash {
  final Offset at;
  double age = 0;
  _Flash(this.at);
}

/// 火星是有速度、會被重力拉、會彈一下的模擬，不是時間的封閉式，
/// 所以狀態放在這裡，由 painter 每幀用時鐘差推進。
class _SparkSim {
  final int sparksPerBurst;
  final Random _rng = Random();
  final List<_Spark> sparks = <_Spark>[];
  final List<_Flash> flashes = <_Flash>[];
  double? _lastT;
  double _next = 0.6;
  Offset? _lastAt;
  bool _double = false;

  static const int _maxLiveSparks = 120;
  static const double _flashLife = 0.16;

  _SparkSim(this.sparksPerBurst);

  double _r(double min, double max) => min + _rng.nextDouble() * (max - min);

  void step(double t, Size size) {
    final prev = _lastT;
    _lastT = t;
    if (prev == null) return;
    var dt = t - prev;
    if (dt <= 0) return; // 同一幀重畫，或時鐘被歸零
    if (dt > 0.1) dt = 0.1; // 暫停回來不要一次跳太遠

    _next -= dt;
    if (_next <= 0) {
      _next = _r(1.6, 3.6);
      // 連炸時留在同一點，像接觸不良。
      final at = _double && _lastAt != null
          ? _lastAt!
          : Offset(
              _r(0.12, 0.88) * size.width,
              _r(0.08, 0.55) * size.height,
            );
      _lastAt = at;
      _double = false;
      flashes.add(_Flash(at));
      if (sparks.length < _maxLiveSparks) {
        for (var i = 0; i < sparksPerBurst; i++) {
          final a =
              _r(-pi * 0.95, pi * 0.05) + (_rng.nextBool() ? 0 : pi * 0.9);
          final sp = _r(60, 190);
          sparks.add(
            _Spark(
              x: at.dx,
              y: at.dy,
              vx: cos(a) * sp,
              vy: sin(a) * sp - _r(10, 60),
              life: _r(0.45, 1.1),
            ),
          );
        }
      }
      if (_rng.nextDouble() < 0.3) {
        _next = _r(0.12, 0.25);
        _double = true;
      }
    }

    for (final f in flashes) {
      f.age += dt;
    }
    flashes.removeWhere((f) => f.age >= _flashLife);

    final floor = size.height - 64;
    final drag = pow(0.985, dt * 60).toDouble();
    for (final s in sparks) {
      s.age += dt;
      s.px = s.x;
      s.py = s.y;
      s.vy += 420 * dt;
      s.vx *= drag;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      if (!s.bounced && s.y > floor) {
        s.y = floor;
        s.vy *= -0.32;
        s.vx *= 0.5;
        s.bounced = true;
      }
    }
    sparks.removeWhere((s) => s.age >= s.life);
  }
}

/// 沒有電線，只有「啪」的那一下：白光一閃，一把火星往外噴、
/// 被重力拉成弧線往下掉，從白燒成橘再變紅後熄掉。
class SparkBurstWidget extends StatefulWidget {
  final ValueListenable<double> clock;

  /// 每次炸開噴出的火星數（跟密度走）。
  final int sparkCount;

  const SparkBurstWidget({
    super.key,
    required this.clock,
    this.sparkCount = 26,
  }) : assert(sparkCount > 0);

  @override
  State<SparkBurstWidget> createState() => _SparkBurstWidgetState();
}

class _SparkBurstWidgetState extends State<SparkBurstWidget> {
  late final _SparkSim _sim = _SparkSim(widget.sparkCount);

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SparkPainter(sim: _sim, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final _SparkSim sim;
  final ValueListenable<double> clock;
  final Paint _flash = Paint()..style = PaintingStyle.fill;
  final Paint _streak = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  static ThemePreset? _tonePreset;
  static List<Color> _tones = const <Color>[];

  /// 熱 → 主色 → 冷卻，三段都從主題強調色來，並保證和底色分得開。
  static List<Color> _sparkTones() {
    final preset = YanciTheme.preset;
    if (identical(_tonePreset, preset)) return _tones;
    _tonePreset = preset;
    final accent = YanciTheme.accent.withValues(alpha: 1);
    final light = YanciTheme.accentLight.withValues(alpha: 1);
    final hot = YanciTheme.isDark
        ? Color.lerp(light, Colors.white, 0.65)!
        : Color.lerp(light, Colors.white, 0.25)!;
    return _tones = <Color>[
      YanciTheme.particleTone(hot, minContrast: 2.2),
      YanciTheme.particleTone(light, minContrast: 2.6),
      YanciTheme.particleTone(accent, minContrast: 2.6),
    ];
  }

  _SparkPainter({required this.sim, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    sim.step(clock.value, size);

    final tones = _sparkTones();
    final hot = tones[0];
    final mid = tones[1];
    final cool = tones[2];
    for (final f in sim.flashes) {
      final k = 1 - f.age / _SparkSim._flashLife;
      final r = 26 + 30 * (1 - k);
      _flash.shader = ui.Gradient.radial(
        f.at,
        r,
        <Color>[
          hot.withValues(alpha: 0.95 * k),
          mid.withValues(alpha: 0.55 * k),
          mid.withValues(alpha: 0),
        ],
        const <double>[0, 0.3, 1],
      );
      canvas.drawCircle(f.at, r, _flash);
    }
    _flash.shader = null;

    for (final s in sim.sparks) {
      final k = s.age / s.life;
      final base = k < 0.25 ? hot : (k < 0.6 ? mid : cool);
      _streak
        ..color = base.withValues(alpha: (1 - k) * 0.95)
        ..strokeWidth = 1.6 - k * 0.8;
      canvas.drawLine(Offset(s.px, s.py), Offset(s.x, s.y), _streak);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      !identical(oldDelegate.sim, sim);
}

// ─────────────────────────────────────────────────────────────
// 3. 雲朵與日月 — SkyWidget
// ─────────────────────────────────────────────────────────────

class _CloudLayer {
  final double width;
  final double soft; // 1 = 最糊
  final double speed; // px/s（風速倍率 1 時）
  final double alpha;
  final double minScale;
  final double maxScale;

  const _CloudLayer(
    this.width,
    this.soft,
    this.speed,
    this.alpha,
    this.minScale,
    this.maxScale,
  );
}

/// 遠層小、最糊、最慢；近層大、邊緣較清楚、最快（視差）。
const List<_CloudLayer> _cloudLayers = <_CloudLayer>[
  _CloudLayer(68, 1.0, 3.5, 0.55, 0.75, 1.05),
  _CloudLayer(108, 0.62, 7, 0.72, 0.85, 1.1),
  _CloudLayer(156, 0.32, 11, 0.86, 0.9, 1.2),
];

/// 一張烘好的雲：[ratio] 是烘圖倍率，換算回邏輯像素時用。
class _CloudSprite {
  final ui.Image image;
  final double ratio;

  const _CloudSprite(this.image, this.ratio);
}

/// 10 種雲形 × 3 層景深，每種風格第一次用到時一次烘好，之後整個 App 共用。
/// 柔邊以 1x 烘（本來就糊，不需高解析度）；硬邊按螢幕倍率烘，邊緣才不鋸齒。
abstract final class _CloudAtlas {
  static final Map<String, List<List<_CloudSprite>>> _sprites =
      <String, List<List<_CloudSprite>>>{};

  static List<List<_CloudSprite>> spritesFor(String style) =>
      _sprites[style] ??= _build(style == 'hard');

  static List<List<_CloudSprite>> _build(bool hard) {
    final rng = Random(20261029);
    final views = ui.PlatformDispatcher.instance.views;
    final ratio = hard && views.isNotEmpty
        ? views.first.devicePixelRatio.clamp(1.0, 3.0)
        : 1.0;
    return List.generate(10, (i) {
      final shape = _shape(i % 4, rng);
      return [
        for (final layer in _cloudLayers)
          // 硬邊模式下最遠一層仍用柔邊，前清楚後朦朧，景深不丟。
          hard && layer.soft < 0.9
              ? _CloudSprite(_renderHard(shape, layer, ratio), ratio)
              : _CloudSprite(_render(shape, layer), 1),
      ];
    }, growable: false);
  }

  static List<(double, double, double)> _shape(int kind, Random rng) {
    double r(double min, double max) => min + rng.nextDouble() * (max - min);
    final puffs = <(double, double, double)>[];
    switch (kind) {
      case 0: // 積雲：圓頂
        final n = 5 + rng.nextInt(3);
        for (var i = 0; i < n; i++) {
          final k = i / (n - 1);
          puffs.add((
            0.15 + 0.7 * k,
            0.62 - sin(k * pi) * r(0.18, 0.3),
            r(0.14, 0.22),
          ));
        }
        puffs.add((0.5, 0.66, 0.24));
      case 1: // 扁雲：中間厚、兩頭收，不再是一條等粗的長條
        final n = 6 + rng.nextInt(2);
        for (var i = 0; i < n; i++) {
          final k = i / (n - 1);
          final bump = sin(k * pi);
          puffs.add((
            0.14 + 0.72 * k,
            0.64 - bump * r(0.1, 0.16),
            0.07 + bump * r(0.08, 0.11),
          ));
        }
      case 2: // 雙峰
        for (final cx in const [0.32, 0.66]) {
          for (var i = 0; i < 4; i++) {
            puffs.add((cx + r(-0.12, 0.12), 0.5 + r(-0.12, 0.1), r(0.12, 0.19)));
          }
        }
      default: // 小團雲：聚攏一點，硬邊時才不會散成幾顆圓點
        final n = 4 + rng.nextInt(3);
        for (var i = 0; i < n; i++) {
          puffs.add((r(0.28, 0.72), r(0.46, 0.64), r(0.1, 0.16)));
        }
    }
    return puffs;
  }

  static ui.Image _render(List<(double, double, double)> shape, _CloudLayer layer) {
    final width = layer.width;
    final pad = width * 0.16;
    final w = (width + pad * 2).ceil();
    final h = (width * 0.62 + pad * 2).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();
    final inner = max(0.05, 0.62 - layer.soft * 0.55); // 越軟，實心核心越小
    for (final (px, py, pr) in shape) {
      final center = Offset(pad + px * width, pad + py * width * 0.62);
      final radius = pr * width * (1 + layer.soft * 0.35);
      paint.shader = ui.Gradient.radial(
        center,
        radius,
        const <Color>[
          Color.fromRGBO(255, 255, 255, 0.9),
          Color.fromRGBO(255, 255, 255, 0.75),
          Color.fromRGBO(255, 255, 255, 0),
        ],
        <double>[0, inner, 1],
      );
      canvas.drawCircle(center, radius, paint);
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    return image;
  }

  /// 硬邊卡通雲：圓團聯集、底部收成圓潤的扁底，下面墊一道陰影。
  /// 「柔和的硬邊」：輪廓清楚，但所有轉角都是圓的，邊緣再糊一點點，
  /// 不會有切出來的尖角。白色本體與灰色陰影都會被 modulate 染成主題色系。
  static ui.Image _renderHard(
    List<(double, double, double)> shape,
    _CloudLayer layer,
    double ratio,
  ) {
    final width = layer.width;
    final pad = width * 0.16;
    final w = width + pad * 2;
    final h = width * 0.62 + pad * 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);

    var floor = 0.0;
    var left = double.infinity;
    var right = 0.0;
    var smallest = double.infinity;
    final puffs = <(Offset, double)>[];
    for (final (px, py, pr) in shape) {
      final center = Offset(pad + px * width, pad + py * width * 0.62);
      final radius = pr * width;
      puffs.add((center, radius));
      floor = max(floor, center.dy);
      left = min(left, center.dx);
      right = max(right, center.dx);
      smallest = min(smallest, radius);
    }

    // 扁底：圓角膠囊。圓團低於扁底的部分壓扁，底線就是一條順滑的弧，
    // 不是直接切平（直接切會在圓團和底線交界處留下尖角）。
    final baseHeight = smallest * 1.1;
    final bottom = floor + baseHeight * 0.35;
    final body = Path()
      ..addRRect(
        RRect.fromLTRBR(
          left - smallest * 0.6,
          bottom - baseHeight,
          right + smallest * 0.6,
          bottom,
          Radius.circular(baseHeight / 2),
        ),
      );
    for (final (center, radius) in puffs) {
      final overflow = center.dy + radius - bottom;
      // 超出底線的圓團改畫成上圓下扁的橢圓，剛好收在底線上。
      final squash = overflow > 0 ? (radius * 2 - overflow) / (radius * 2) : 1.0;
      final rect = Rect.fromLTRB(
        center.dx - radius,
        center.dy - radius,
        center.dx + radius,
        center.dy - radius + radius * 2 * squash,
      );
      body.addOval(rect);
    }

    final soften = MaskFilter.blur(BlurStyle.normal, width * 0.008);
    final shadowDrop = width * 0.035;
    canvas
      ..save()
      ..translate(0, shadowDrop)
      ..drawPath(
        body,
        Paint()
          ..color = const Color(0xFF9A9A9A)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.014),
      )
      ..restore()
      ..drawPath(
        body,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..maskFilter = soften,
      );

    final picture = recorder.endRecording();
    final image = picture.toImageSync((w * ratio).ceil(), (h * ratio).ceil());
    picture.dispose();
    return image;
  }
}

class _Cloud {
  final ui.Image image;
  final double ratio;
  final int layer;
  double x;
  final double yFraction;
  final double scale;
  final double speedJitter;

  _Cloud({
    required this.image,
    required this.ratio,
    required this.layer,
    required this.x,
    required this.yFraction,
    required this.scale,
    required this.speedJitter,
  });

  double get width => image.width / ratio * scale;
  double get height => image.height / ratio * scale;
}

class _SkySim {
  final int cloudCount;
  final Random _rng = Random();
  final List<_Cloud> clouds = <_Cloud>[];
  double? _lastT;
  double wind = 1;

  _SkySim(this.cloudCount);

  double _r(double min, double max) => min + _rng.nextDouble() * (max - min);

  /// 風：兩道慢正弦疊起來。疊到 0 以下就是「停一會」，疊到高點是一陣快風；
  /// 都是波，所以停下與起步都是緩的，不會突然頓住。
  static double windAt(double t) => max(
    0,
    0.85 + 0.95 * sin(t * 0.11) + 0.55 * sin(t * 0.047 + 1.7),
  );

  _Cloud _spawn(Size size, double x) {
    final roll = _rng.nextDouble();
    final layer = roll < 0.4 ? 0 : (roll < 0.75 ? 1 : 2);
    final spec = _cloudLayers[layer];
    final sprites = _CloudAtlas.spritesFor(YanciTheme.cloudStyle);
    final sprite = sprites[_rng.nextInt(sprites.length)][layer];
    final widthScale = min(1.0, size.width / 280);
    return _Cloud(
      image: sprite.image,
      ratio: sprite.ratio,
      layer: layer,
      x: x,
      yFraction: _r(0.0, 0.2),
      scale: _r(spec.minScale, spec.maxScale) * widthScale,
      speedJitter: _r(0.8, 1.2),
    );
  }

  void step(double t, Size size) {
    if (clouds.isEmpty) {
      for (var i = 0; i < cloudCount; i++) {
        clouds.add(_spawn(size, _r(-0.2, 1.0) * size.width));
      }
      clouds.sort((a, b) => a.layer.compareTo(b.layer));
    }
    final prev = _lastT;
    _lastT = t;
    wind = windAt(t);
    if (prev == null) return;
    var dt = t - prev;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;

    var respawned = false;
    for (var i = 0; i < clouds.length; i++) {
      final c = clouds[i];
      c.x += _cloudLayers[c.layer].speed * c.speedJitter * wind * dt;
      if (c.x > size.width + 10) {
        final next = _spawn(size, 0);
        next.x = -next.width - _r(10, 80);
        clouds[i] = next;
        respawned = true;
      }
    }
    if (respawned) clouds.sort((a, b) => a.layer.compareTo(b.layer));
  }
}

/// 頂部飄雲；白天太陽、晚上月牙，依本地時間在天上走。
/// 清晨（約 5–7 點）與傍晚（約 17–19 點）天邊染一點暖色。
class SkyWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int cloudCount;

  const SkyWidget({super.key, required this.clock, this.cloudCount = 6})
    : assert(cloudCount > 0);

  @override
  State<SkyWidget> createState() => _SkyWidgetState();
}

class _SkyWidgetState extends State<SkyWidget> {
  late final _SkySim _sim = _SkySim(widget.cloudCount);

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SkyPainter(sim: _sim, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  final _SkySim sim;
  final ValueListenable<double> clock;
  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _cloud = Paint()..filterQuality = FilterQuality.low;

  static final Path _crescent = Path.combine(
    PathOperation.difference,
    Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: 12)),
    Path()..addOval(Rect.fromCircle(center: const Offset(6, -4), radius: 11)),
  );

  _SkyPainter({required this.sim, required this.clock})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    sim.step(clock.value, size);
    final dark = YanciTheme.isDark;
    final now = DateTime.now();
    final hour = now.hour + now.minute / 60;
    final day = hour >= 6 && hour < 18;
    final progress = day ? (hour - 6) / 12 : ((hour - 18 + 24) % 24) / 12;
    final body = Offset(
      size.width * (0.1 + 0.8 * progress),
      size.height * 0.17 - sin(progress * pi) * size.height * 0.08,
    );
    final dusk = max(
      0.0,
      1 - min((hour - 6).abs(), (hour - 18).abs()) / 1.5,
    );

    if (dusk > 0) {
      final band = Rect.fromLTWH(0, 0, size.width, size.height * 0.4);
      _fill.shader = ui.Gradient.linear(
        band.topCenter,
        band.bottomCenter,
        <Color>[
          Color.fromRGBO(255, 150, 90, 0.22 * dusk),
          const Color.fromRGBO(255, 150, 90, 0),
        ],
      );
      canvas.drawRect(band, _fill);
    }

    // 淺色主題的底色接近白：太陽、月亮、雲往文字次色拉一點才看得見。
    final ink = YanciTheme.textSecondary.withValues(alpha: 1);
    if (day) {
      final sun = YanciTheme.particleTone(
        dusk > 0 ? const Color(0xFFFFB36B) : const Color(0xFFFFD98A),
        minContrast: 1.8,
      );
      _fill.shader = ui.Gradient.radial(
        body,
        46,
        <Color>[
          sun.withValues(alpha: 0.95),
          sun.withValues(alpha: 0.85),
          sun.withValues(alpha: 0.3),
          sun.withValues(alpha: 0),
        ],
        const <double>[0, 0.28, 0.32, 1],
      );
      canvas.drawCircle(body, 46, _fill);
      _fill.shader = null;
    } else {
      final moon = dark
          ? const Color(0xFFF3EFD9)
          : YanciTheme.particleTone(
              Color.lerp(const Color(0xFFF7F2DD), ink, 0.28)!,
              minContrast: 1.8,
            );
      _fill.shader = ui.Gradient.radial(
        body,
        40,
        <Color>[moon.withValues(alpha: 0.35), moon.withValues(alpha: 0)],
      );
      canvas.drawCircle(body, 40, _fill);
      _fill
        ..shader = null
        ..color = moon.withValues(alpha: 0.95);
      canvas
        ..save()
        ..translate(body.dx, body.dy)
        ..drawPath(_crescent, _fill)
        ..restore();
    }

    // 雲帶一點主題色，再保證和底色分得開；硬邊雲的陰影是烘在圖裡的灰，
    // 經 modulate 後自動變成同色系的深一階。
    final cloudTint = _cloudTint();
    _cloud.colorFilter = ColorFilter.mode(cloudTint, BlendMode.modulate);
    final nightDim = day ? 1.0 : 0.55;
    for (final c in sim.clouds) {
      final spec = _cloudLayers[c.layer];
      final alpha = spec.alpha * (dark ? 0.42 : 0.9) * nightDim;
      _cloud.color = Color.fromRGBO(255, 255, 255, alpha.clamp(0.0, 1.0));
      final y = size.height * c.yFraction - c.layer * 4;
      canvas.drawImageRect(
        c.image,
        Rect.fromLTWH(0, 0, c.image.width.toDouble(), c.image.height.toDouble()),
        Rect.fromLTWH(c.x, y, c.width, c.height),
        _cloud,
      );
    }
  }

  static ThemePreset? _cloudPreset;
  static Color _cloudTintCache = Colors.white;

  static Color _cloudTint() {
    final preset = YanciTheme.preset;
    if (identical(_cloudPreset, preset)) return _cloudTintCache;
    _cloudPreset = preset;
    final accent = YanciTheme.accent.withValues(alpha: 1);
    final base = Color.lerp(
      Colors.white,
      accent,
      YanciTheme.isDark ? 0.08 : 0.12,
    )!;
    return _cloudTintCache = YanciTheme.particleTone(base, minContrast: 1.5);
  }

  @override
  bool shouldRepaint(covariant _SkyPainter oldDelegate) =>
      !identical(oldDelegate.sim, sim);
}

// ─────────────────────────────────────────────────────────────
// 5. 煙花 — FireworkWidget
// ─────────────────────────────────────────────────────────────

class _Rocket {
  final double x;
  final double targetY;
  final double startY;
  final double riseTime;
  final int tone;

  /// 炸開後最外圈大約飛多遠（px）。小煙花約 60–80，大煙花接近半個螢幕。
  final double radius;
  final bool big;
  double age = 0;

  _Rocket({
    required this.x,
    required this.targetY,
    required this.startY,
    required this.riseTime,
    required this.tone,
    required this.radius,
    required this.big,
  });

  double get y {
    final k = (age / riseTime).clamp(0.0, 1.0);
    final eased = 1 - pow(1 - k, 2.2).toDouble(); // 越升越慢，到頂停住才炸
    return startY + (targetY - startY) * eased;
  }
}

class _FireworkSpark {
  double x;
  double y;
  double px;
  double py;
  double vx;
  double vy;
  final double life;
  final int tone;
  final double twinkle;
  final double weight; // 線寬倍率：大煙花的火花粗一點
  double age = 0;

  _FireworkSpark({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.tone,
    required this.twinkle,
    required this.weight,
  }) : px = x,
       py = y;
}

class _FireworkFlash {
  final Offset at;
  final int tone;
  final double scale;
  double age = 0;

  _FireworkFlash(this.at, this.tone, this.scale);
}

class _FireworkSim {
  final int sparksPerShell;

  /// 每次發射時「整片齊放」（7–10 發、高度錯開）的機率；只有密度拉滿才 > 0。
  final double salvoChance;
  final Random _rng = Random();
  final List<_Rocket> rockets = <_Rocket>[];
  final List<_FireworkSpark> sparks = <_FireworkSpark>[];
  final List<_FireworkFlash> flashes = <_FireworkFlash>[];
  double? _lastT;
  double _next = 0.4;

  static const int _maxLiveSparks = 640;
  static const double flashLife = 0.22;

  /// 大煙花出現的機率。
  static const double _bigChance = 0.25;

  /// 速度 → 飛行距離：每幀乘 0.975 的阻力下，總位移約為初速 × 0.667 秒。
  static const double _dragTravelSeconds = 0.667;
  static const double _drag = 0.975;

  /// 一發煙花用幾個顏色（調色盤索引），每發各自抽。
  static const int toneCount = 4;

  _FireworkSim(this.sparksPerShell, {this.salvoChance = 0});

  double _r(double min, double max) => min + _rng.nextDouble() * (max - min);

  void _launch(
    Size size, {
    bool? big,
    double? targetFraction,
    double delay = 0,
  }) {
    final isBig = big ?? _rng.nextDouble() < _bigChance;
    final shortSide = min(size.width, size.height * 0.8);
    final radius = isBig
        ? _r(0.38, 0.5) * shortSide // 直徑接近螢幕寬，快佔滿
        : _r(60, 80);
    // 大煙花炸在畫面中段，才有空間整個開出來；小的可以高一點。
    final target =
        targetFraction ?? (isBig ? _r(0.28, 0.42) : _r(0.12, 0.42));
    rockets.add(
      _Rocket(
        x: (isBig ? _r(0.3, 0.7) : _r(0.15, 0.85)) * size.width,
        startY: size.height + 8,
        targetY: target * size.height,
        riseTime: (isBig ? _r(1.3, 1.7) : _r(0.9, 1.3)),
        tone: _rng.nextInt(toneCount),
        radius: radius,
        big: isBig,
      )..age = -delay,
    );
  }

  /// 7–10 發同時升空，炸開高度分層錯開，像整片齊放。
  void _salvo(Size size) {
    final count = 7 + _rng.nextInt(4);
    final bands = List<int>.generate(count, (i) => i)..shuffle(_rng);
    for (var i = 0; i < count; i++) {
      // 高度從 0.1 到 0.6 均分成 count 層，每發各佔一層再加一點抖動。
      final band = bands[i];
      final fraction = 0.1 + 0.5 * (band + _r(0.2, 0.8)) / count;
      _launch(
        size,
        big: _rng.nextDouble() < 0.2,
        targetFraction: fraction,
        delay: _r(0, 0.6),
      );
    }
  }

  void _burst(_Rocket r) {
    final at = Offset(r.x, r.targetY);
    final scale = r.radius / 70;
    flashes.add(_FireworkFlash(at, r.tone, scale.clamp(1.0, 3.0)));
    final room = _maxLiveSparks - sparks.length;
    if (room <= 0) return;
    // 一半的煙花帶第二色外圈。
    final ringTone = _rng.nextBool() ? (r.tone + 1) % toneCount : r.tone;
    // 大煙花火花多一些，圓周才不會稀疏；但不超過剩餘名額。
    final n = min(room, r.big ? (sparksPerShell * 2.2).round() : sparksPerShell);
    final speed = r.radius / _dragTravelSeconds;
    final life = r.big ? _r(2.2, 3.0) : _r(1.3, 2.0);
    final weight = r.big ? 1.4 : 1.0;
    for (var i = 0; i < n; i++) {
      final a = 2 * pi * i / n + _r(-0.08, 0.08);
      final outer = i.isEven;
      final sp = speed * (outer ? _r(0.92, 1.05) : _r(0.55, 0.75));
      sparks.add(
        _FireworkSpark(
          x: at.dx,
          y: at.dy,
          vx: cos(a) * sp,
          vy: sin(a) * sp,
          life: life * _r(0.9, 1.1),
          tone: outer ? ringTone : r.tone,
          twinkle: _r(0, 2 * pi),
          weight: weight,
        ),
      );
    }
  }

  void step(double t, Size size) {
    final prev = _lastT;
    _lastT = t;
    if (prev == null) return;
    var dt = t - prev;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;

    _next -= dt;
    if (_next <= 0) {
      if (salvoChance > 0 && _rng.nextDouble() < salvoChance) {
        _salvo(size);
        _next = _r(4.5, 6.0); // 齊放之後讓天空空一下
      } else {
        _launch(size);
        // 偶爾連發兩顆，像在放一串。
        if (_rng.nextDouble() < 0.25) _launch(size, big: false);
        _next = _r(1.8, 3.6);
      }
    }

    for (final r in rockets) {
      r.age += dt;
    }
    for (final r in rockets.where((r) => r.age >= r.riseTime).toList()) {
      _burst(r);
    }
    rockets.removeWhere((r) => r.age >= r.riseTime);

    for (final f in flashes) {
      f.age += dt;
    }
    flashes.removeWhere((f) => f.age >= flashLife);

    final drag = pow(_drag, dt * 60).toDouble();
    for (final s in sparks) {
      s.age += dt;
      s.px = s.x;
      s.py = s.y;
      s.vy += 55 * dt; // 輕輕的重力，花瓣狀散開後慢慢垂下
      s.vx *= drag;
      s.vy *= drag;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
    }
    sparks.removeWhere((s) => s.age >= s.life);
  }
}

/// 煙花：一顆光點從下方升起，到頂「啪」地開成一圈，
/// 內圈外圈兩種主題色，慢慢垂落、尾端閃一閃後熄掉。
/// 顏色全部取自主題強調色（含左右偏色），並保證跟底色分得開。
class FireworkWidget extends StatefulWidget {
  final ValueListenable<double> clock;

  /// 每發煙花炸開的火花數（跟密度走）。
  final int sparkCount;

  /// 整片齊放（7–10 發）的機率；密度拉滿時由外層傳 0.05。
  final double salvoChance;

  const FireworkWidget({
    super.key,
    required this.clock,
    this.sparkCount = 26,
    this.salvoChance = 0,
  }) : assert(sparkCount > 0);

  @override
  State<FireworkWidget> createState() => _FireworkWidgetState();
}

class _FireworkWidgetState extends State<FireworkWidget> {
  late final _FireworkSim _sim = _FireworkSim(
    widget.sparkCount,
    salvoChance: widget.salvoChance,
  );

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FireworkPainter(sim: _sim, clock: widget.clock),
        size: Size.infinite,
      ),
    );
  }
}

class _FireworkPainter extends CustomPainter {
  final _FireworkSim sim;
  final ValueListenable<double> clock;
  final Paint _flash = Paint()..style = PaintingStyle.fill;
  final Paint _dot = Paint()..style = PaintingStyle.fill;
  final Paint _streak = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  _FireworkPainter({required this.sim, required this.clock})
    : super(repaint: clock);

  static ThemePreset? _tonePreset;
  static List<Color> _tones = const <Color>[];

  /// 主題強調色、淺強調色、往左右各偏一點色相的兩個鄰近色。
  static List<Color> _fireworkTones() {
    final preset = YanciTheme.preset;
    if (identical(_tonePreset, preset)) return _tones;
    _tonePreset = preset;
    final accent = YanciTheme.accent.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(accent);
    final sat = max(hsl.saturation, 0.45);
    Color shifted(double deg) => hsl
        .withHue((hsl.hue + deg + 360) % 360)
        .withSaturation(sat)
        .toColor();
    final lift = YanciTheme.isDark ? 0.35 : 0.0;
    final raw = <Color>[
      Color.lerp(accent, Colors.white, lift)!,
      Color.lerp(YanciTheme.accentLight.withValues(alpha: 1), Colors.white, lift)!,
      Color.lerp(shifted(38), Colors.white, lift)!,
      Color.lerp(shifted(-38), Colors.white, lift)!,
    ];
    return _tones = <Color>[
      for (final c in raw) YanciTheme.particleTone(c, minContrast: 2.6),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    sim.step(clock.value, size);
    final tones = _fireworkTones();
    final t = clock.value;

    // 升空：亮點＋一小段往下的尾巴。
    for (final r in sim.rockets) {
      if (r.age < 0) continue; // 齊放時錯開發射，還沒輪到
      final c = tones[r.tone];
      final y = r.y;
      final k = (r.age / r.riseTime).clamp(0.0, 1.0);
      _streak
        ..strokeWidth = 1.4
        ..shader = ui.Gradient.linear(
          Offset(r.x, y),
          Offset(r.x, y + 26),
          <Color>[c.withValues(alpha: 0.75), c.withValues(alpha: 0)],
        );
      canvas.drawLine(Offset(r.x, y), Offset(r.x, y + 26), _streak);
      _streak.shader = null;
      _dot.color = c.withValues(alpha: 0.6 + 0.35 * k);
      canvas.drawCircle(Offset(r.x, y), 1.8, _dot);
    }

    // 炸開那一下的光暈。
    for (final f in sim.flashes) {
      final c = tones[f.tone];
      final k = 1 - f.age / _FireworkSim.flashLife;
      final r = (18 + 26 * (1 - k)) * f.scale;
      _flash.shader = ui.Gradient.radial(
        f.at,
        r,
        <Color>[
          c.withValues(alpha: 0.55 * k),
          c.withValues(alpha: 0.18 * k),
          c.withValues(alpha: 0),
        ],
        const <double>[0, 0.4, 1],
      );
      canvas.drawCircle(f.at, r, _flash);
    }
    _flash.shader = null;

    // 火花：拖一小段尾巴，最後三成生命閃爍熄滅。
    for (final s in sim.sparks) {
      final k = s.age / s.life;
      var alpha = k < 0.7 ? 0.92 - k * 0.4 : (1 - k) / 0.3 * 0.64;
      if (k > 0.55) alpha *= 0.55 + 0.45 * sin(t * 18 + s.twinkle).abs();
      final c = tones[s.tone].withValues(alpha: alpha.clamp(0.0, 1.0));
      _streak
        ..color = c
        ..strokeWidth = (1.5 - k * 0.6) * s.weight;
      final tailX = s.x - (s.x - s.px) * 3;
      final tailY = s.y - (s.y - s.py) * 3;
      canvas.drawLine(Offset(tailX, tailY), Offset(s.x, s.y), _streak);
      _dot.color = c;
      canvas.drawCircle(Offset(s.x, s.y), (1.3 - k * 0.5) * s.weight, _dot);
    }
  }

  @override
  bool shouldRepaint(covariant _FireworkPainter oldDelegate) =>
      !identical(oldDelegate.sim, sim);
}

// ─────────────────────────────────────────────────────────────
// 4. emoji 雨 — EmojiRainWidget
// ─────────────────────────────────────────────────────────────

class _EmojiDrop {
  final int sprite;
  final double x;
  final double y;
  final double speed;
  final double size;
  final double phase;
  final double sway;

  const _EmojiDrop({
    required this.sprite,
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
    required this.phase,
    required this.sway,
  });
}

/// 使用者自訂的 emoji（最多 5 種）從上方飄落，一邊晃一邊轉。
/// 每個 emoji 只在建立時用 TextPainter 烘成一張圖，之後每幀只畫圖。
class EmojiRainWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final List<String> emojis;
  final int dropCount;

  const EmojiRainWidget({
    super.key,
    required this.clock,
    required this.emojis,
    this.dropCount = 10,
  }) : assert(dropCount > 0);

  @override
  State<EmojiRainWidget> createState() => _EmojiRainWidgetState();
}

/// 烘 emoji 的字級；繪製時用它把圖換算回落下的大小。
const double _emojiSpriteFontSize = 72;

/// 四周留白（字級的比例）。彩色 emoji 的圖形常超出字體行高，
/// 貓頭、海豚等會被切掉；留白讓整個字形都烘進圖裡。
const double _emojiSpritePadding = _emojiSpriteFontSize * 0.3;

class _EmojiRainWidgetState extends State<EmojiRainWidget> {
  late final List<_EmojiDrop> _drops;
  List<ui.Image> _sprites = const <ui.Image>[];

  @override
  void initState() {
    super.initState();
    _sprites = _renderSprites(
      widget.emojis.isEmpty ? YanciTheme.defaultParticleEmojis : widget.emojis,
    );
    final rng = Random();
    double r(double min, double span) => min + rng.nextDouble() * span;
    _drops = List.generate(
      widget.dropCount,
      (i) => _EmojiDrop(
        sprite: i % max(1, _sprites.length),
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        speed: r(12, 10),
        size: r(16, 10),
        phase: rng.nextDouble() * 2 * pi,
        sway: r(8, 10),
      ),
      growable: false,
    );
  }

  static List<ui.Image> _renderSprites(List<String> emojis) {
    final images = <ui.Image>[];
    for (final emoji in emojis.take(YanciTheme.maxParticleEmojis)) {
      final painter = TextPainter(
        text: TextSpan(
          text: emoji,
          // 不鎖 height: 1.0：鎖了行高會比 emoji 圖形矮，上下被裁。
          style: const TextStyle(fontSize: _emojiSpriteFontSize),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = max(1, (painter.width + _emojiSpritePadding * 2).ceil());
      final h = max(1, (painter.height + _emojiSpritePadding * 2).ceil());
      final recorder = ui.PictureRecorder();
      painter.paint(
        Canvas(recorder),
        const Offset(_emojiSpritePadding, _emojiSpritePadding),
      );
      painter.dispose();
      final picture = recorder.endRecording();
      images.add(picture.toImageSync(w, h));
      picture.dispose();
    }
    return images;
  }

  @override
  void dispose() {
    for (final image in _sprites) {
      image.dispose();
    }
    _sprites = const <ui.Image>[];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _EmojiRainPainter(
          drops: _drops,
          sprites: _sprites,
          clock: widget.clock,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _EmojiRainPainter extends CustomPainter {
  final List<_EmojiDrop> drops;
  final List<ui.Image> sprites;
  final ValueListenable<double> clock;
  final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  _EmojiRainPainter({
    required this.drops,
    required this.sprites,
    required this.clock,
  }) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || sprites.isEmpty) return;
    final t = clock.value;
    _paint.color = Color.fromRGBO(
      255,
      255,
      255,
      YanciTheme.isDark ? 0.7 : 0.8,
    );
    final travel = size.height + 60;
    for (final d in drops) {
      final image = sprites[d.sprite % sprites.length];
      final y = (d.y * travel + t * d.speed) % travel - 30;
      final x = d.x * size.width + sin(t * 0.9 + d.phase) * d.sway;
      // d.size 是 emoji 本身的大小；圖含留白，按字級等比換算，
      // 留白不會把 emoji 縮小。
      final scale = d.size / _emojiSpriteFontSize;
      final dst = Rect.fromCenter(
        center: Offset.zero,
        width: image.width * scale,
        height: image.height * scale,
      );
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(sin(t * 0.8 + d.phase) * 0.4)
        ..drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          dst,
          _paint,
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EmojiRainPainter oldDelegate) =>
      !identical(oldDelegate.drops, drops) ||
      !identical(oldDelegate.sprites, sprites);
}
