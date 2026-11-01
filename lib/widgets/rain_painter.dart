import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../theme/app_theme.dart';

/// 雨絲跟著手機傾斜：讀加速度計算重力在螢幕上的方向，雨就往那邊落。
/// 只在 Android／iOS 上讀；Windows 與測試環境永遠是直直落下。
class _RainTilt {
  /// 雨最多斜幾度（弧度）。再斜雨就像在橫著飛，不好看。
  static const double maxAngle = 1.0; // ≈57°

  /// 重力在螢幕平面上的分量小於這個值（m/s²）就當作手機平放，雨回到直落。
  static const double flatThreshold = 3.0;

  /// 死區：手機歪不到 15° 雨就直落，平常拿手機的自然歪斜不理。
  static const double enterAngle = 15 * pi / 180;

  /// 遲滯：已經在斜的時候，要回到 12° 以內才變回直落，
  /// 在門檻附近晃不會反覆切換。
  static const double exitAngle = 12 * pi / 180;

  /// 每秒往目標角度靠攏的比例：手一轉雨不會瞬間甩過去。
  static const double followRate = 4.0;

  double target = 0;
  double current = 0;
  double? _lastT;
  bool _engaged = false;

  void updateFromAccelerometer(double ax, double ay) {
    // 加速度計讀的是重力的反作用力：直立時 y ≈ +9.8。
    // 重力在螢幕座標（x 右、y 下）的方向就是 (-ax, ay)。
    if (sqrt(ax * ax + ay * ay) < flatThreshold) {
      _engaged = false;
      target = 0;
      return;
    }
    final raw = atan2(-ax, ay);
    final tilt = raw.abs();
    _engaged = _engaged ? tilt >= exitAngle : tilt >= enterAngle;
    if (!_engaged) {
      target = 0;
      return;
    }
    // 從門檻那一點起算：剛過 15° 時是 0°，越歪越斜，不會一過門檻就跳 15°。
    final beyond = max(0.0, tilt - enterAngle);
    target = raw.sign * min(beyond, maxAngle);
  }

  /// 每幀依實際經過時間把角度往目標推，回傳這一幀要用的角度。
  double step(double t) {
    final prev = _lastT;
    _lastT = t;
    if (prev == null) return current;
    final dt = (t - prev).clamp(0.0, 0.1);
    final k = (dt * followRate).clamp(0.0, 1.0);
    current += (target - current) * k;
    return current;
  }
}

enum _RainDepth { far, focus, near }

/// 雨絲粒子資料
class _Raindrop {
  double x; // 0~1 正規化水平位置
  double y; // 0~1 正規化垂直位置（0=頂部）
  double length; // 雨絲長度 px
  double speed; // 下落速率係數
  double opacity;
  double sway; // 微風飄移相位
  double swayAmplitude;
  double strokeWidth;
  _RainDepth depth;

  _Raindrop({
    required this.x,
    required this.y,
    required this.length,
    required this.speed,
    required this.opacity,
    required this.sway,
    required this.swayAmplitude,
    required this.strokeWidth,
    required this.depth,
  });
}

/// 春·燕的雨絲粒子動畫
class RainWidget extends StatefulWidget {
  final ValueListenable<double> clock;
  final int dropCount;

  const RainWidget({super.key, required this.clock, this.dropCount = 35});

  @override
  State<RainWidget> createState() => _RainWidgetState();
}

class _RainWidgetState extends State<RainWidget> {
  late List<_Raindrop> _drops;
  final Random _random = Random();
  final _RainTilt _tilt = _RainTilt();
  StreamSubscription<AccelerometerEvent>? _tiltSub;

  static bool get _hasMotionSensor =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _drops = _generateDrops();
    if (_hasMotionSensor) {
      // 普通頻率（約 5 次／秒）就夠，畫面上另外做平滑，省電。
      _tiltSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen(
        (e) => _tilt.updateFromAccelerometer(e.x, e.y),
        // 沒有加速度計的裝置：安靜放棄，雨照常直落。
        onError: (_) => _tiltSub?.cancel(),
        cancelOnError: true,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 粒子層暫停（切到別頁、App 進背景）時，感測器也一起停。
    final active = TickerMode.valuesOf(context).enabled;
    final sub = _tiltSub;
    if (sub == null) return;
    if (active && sub.isPaused) sub.resume();
    if (!active && !sub.isPaused) sub.pause();
  }

  @override
  void dispose() {
    _tiltSub?.cancel();
    super.dispose();
  }

  List<_Raindrop> _generateDrops() {
    final drops = List.generate(widget.dropCount, (_) {
      // 固定景深：每根雨絲只在生成時抽一次層級，整個生命週期不改變，
      // 避免模糊度呼吸或閃爍。中景是對焦面，近景才有明顯散焦。
      final depthRoll = _random.nextDouble();
      late final double lengthScale;
      late final double speedScale;
      late final double opacityScale;
      late final double strokeWidth;
      late final _RainDepth depth;
      late final double swayAmplitude;

      if (depthRoll < 0.40) {
        // 遠景：短、細、慢、稍微柔化。
        depth = _RainDepth.far;
        lengthScale = 0.70 + _random.nextDouble() * 0.20;
        speedScale = 0.76 + _random.nextDouble() * 0.16;
        opacityScale = 0.55 + _random.nextDouble() * 0.20;
        strokeWidth = 0.80 + _random.nextDouble() * 0.20;
        swayAmplitude = 1.8 + _random.nextDouble() * 1.0;
      } else if (depthRoll < 0.85) {
        // 焦點層：最清楚，維持原本輕細雨絲的存在感。
        depth = _RainDepth.focus;
        lengthScale = 0.90 + _random.nextDouble() * 0.15;
        speedScale = 0.90 + _random.nextDouble() * 0.15;
        opacityScale = 0.80 + _random.nextDouble() * 0.20;
        strokeWidth = 1.00 + _random.nextDouble() * 0.20;
        swayAmplitude = 2.4 + _random.nextDouble() * 1.0;
      } else {
        // 近景：粗與散焦會攤開光量，因此中心透明度低於焦點層，
        // 避免掠過文字時形成又粗又亮的白棍。
        depth = _RainDepth.near;
        lengthScale = 1.15 + _random.nextDouble() * 0.30;
        speedScale = 1.08 + _random.nextDouble() * 0.20;
        opacityScale = 0.68 + _random.nextDouble() * 0.14;
        strokeWidth = 1.25 + _random.nextDouble() * 0.30;
        swayAmplitude = 2.8 + _random.nextDouble() * 1.2;
      }

      // 雨絲本身另有固定的短／中／長節奏，不讓「景深」單獨決定長度。
      // 長度只在生成時抽取一次，因此每根雨絲移動期間不會忽長忽短。
      final lengthRoll = _random.nextDouble();
      final double baseLength;
      if (lengthRoll < 0.34) {
        baseLength = 6.0 + _random.nextDouble() * 6.0;
      } else if (lengthRoll < 0.82) {
        baseLength = 13.0 + _random.nextDouble() * 11.0;
      } else {
        baseLength = 26.0 + _random.nextDouble() * 10.0;
      }

      return _Raindrop(
        x: _random.nextDouble(),
        y: _random.nextDouble(), // 初始隨機散佈，不要全從頂部開始
        length: baseLength * lengthScale,
        speed: (_random.nextDouble() * 0.4 + 0.8) * speedScale,
        opacity: (_random.nextDouble() * 0.28 + 0.22) * opacityScale,
        sway: _random.nextDouble() * 2 * pi,
        swayAmplitude: swayAmplitude,
        strokeWidth: strokeWidth,
        depth: depth,
      );
    });
    // CustomPainter 依序覆畫；固定由遠到近，讓遮擋關係符合景深。
    drops.sort((a, b) => a.depth.index.compareTo(b.depth.index));
    return drops;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RainPainter(drops: _drops, clock: widget.clock, tilt: _tilt),
        size: Size.infinite,
      ),
    );
  }
}

class _RainPainter extends CustomPainter {
  final List<_Raindrop> drops;
  final ValueListenable<double> clock;
  final _RainTilt tilt;
  final Paint _haze = Paint()..strokeCap = StrokeCap.round;
  final Paint _stroke = Paint()..strokeCap = StrokeCap.round;

  _RainPainter({required this.drops, required this.clock, required this.tilt})
    : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size screen) {
    final seconds = clock.value;
    // 傾斜時把整片雨轉過去；畫布放大到剛好蓋住旋轉後的螢幕，角落才不會缺雨。
    final angle = tilt.step(seconds);
    final c = cos(angle).abs();
    final s = sin(angle).abs();
    final size = Size(
      screen.width * c + screen.height * s,
      screen.width * s + screen.height * c,
    );
    canvas
      ..save()
      ..translate(screen.width / 2, screen.height / 2)
      ..rotate(-angle)
      ..translate(-size.width / 2, -size.height / 2);
    // 雨絲顏色跟主題星光色走，保持視覺協調
    final baseColor = YanciTheme.starColor;

    for (final drop in drops) {
      // 垂直位移：每滴以自己的速度往下移，超出底部就回到頂部
      // 對齊舊版速度，但改用永不整體復位的連續秒數。
      final yProgress = (drop.y + seconds * drop.speed / 4.0) % 1.3;
      if (yProgress > 1.05) continue; // 還沒重新進入畫面

      final currentY = yProgress * size.height;

      // 微風飄移：水平微擺，sin 波模擬風感
      final swayOffset =
          sin(seconds * 2 * pi * 0.1875 + drop.sway) * drop.swayAmplitude;
      final currentX = drop.x * size.width + swayOffset;

      // 接近邊緣淡出（進入和離開時）
      final edgeFade = yProgress < 0.05
          ? yProgress / 0.05
          : yProgress > 0.95
          ? (1.0 - yProgress) / 0.05
          : 1.0;

      // 雨絲：微傾斜的短線段（模擬微風中的雨）
      const angle = 0.06; // ≈3.4° 微傾
      final dx = sin(angle) * drop.length;
      final dy = cos(angle) * drop.length;
      final start = Offset(currentX, currentY);
      final end = Offset(currentX + dx, currentY + dy);
      final alpha = (drop.opacity * edgeFade).clamp(0.0, 1.0);

      // 三段透明度遞增保留上端漸隱，避免每根雨絲每幀建立 gradient
      // shader 與 MaskFilter。近景加一層極淡寬線模擬散焦。
      final delta = end - start;
      final p1 = start + delta * 0.38;
      final p2 = start + delta * 0.72;
      if (drop.depth == _RainDepth.near) {
        _haze
          ..color = baseColor.withValues(alpha: alpha * 0.14)
          ..strokeWidth = drop.strokeWidth * 2.3;
        canvas.drawLine(start, end, _haze);
      }
      final stroke = _stroke..strokeWidth = drop.strokeWidth;
      stroke.color = baseColor.withValues(alpha: alpha * 0.25);
      canvas.drawLine(start, p1, stroke);
      stroke.color = baseColor.withValues(alpha: alpha * 0.62);
      canvas.drawLine(p1, p2, stroke);
      stroke.color = baseColor.withValues(alpha: alpha);
      canvas.drawLine(p2, end, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RainPainter oldDelegate) {
    return !identical(oldDelegate.drops, drops);
  }
}
