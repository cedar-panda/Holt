import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_theme.dart';

/// ═══════════════════════════════════════════════════════════
///  通話中央視覺：頭像 + 呼吸光環 + 真實振幅聲波
///  無障礙：頭像/波形為裝飾性元素，狀態靠文字傳達；
///  按鈕 ≥56dp、圖標白色置於深色實底（對比 ≥3:1）
/// ═══════════════════════════════════════════════════════════

/// 紅綠與主題調和：色相往 accent 拉近一步、飽和度跟主題親和，
/// 明度按暗/亮主題定錨（保證白色圖標對比）
class CallPalette {
  static Color _harmonize(double baseHue, {double blend = 0.15}) {
    final a = HSLColor.fromColor(YanciTheme.accent);
    var d = a.hue - baseHue;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    final hue = (baseHue + d * blend + 360) % 360;
    final sat = (0.52 + a.saturation * 0.18).clamp(0.42, 0.68).toDouble();
    final light = YanciTheme.isDark ? 0.50 : 0.44;
    return HSLColor.fromAHSL(1.0, hue, sat, light).toColor();
  }

  /// 接聽綠
  static Color get answerGreen => _harmonize(142);

  /// 掛斷紅
  static Color get hangupRed => _harmonize(4, blend: 0.10);
}

class CallCenterVisual extends StatefulWidget {
  final String? avatarPath;
  final String fallbackName;
  final ValueNotifier<double> level;

  /// ringing = 來電響鈴（頭像輕微擺動）
  final bool ringing;
  final bool thinking;
  final double avatarSize;

  /// 頭像邊緣流光的顏色；null 時用主題 accent。換色時會在
  /// [_glowTransition] 內從舊色平滑滑到新色（預留給「心情顏色」）。
  final Color? glowColor;

  const CallCenterVisual({
    super.key,
    required this.avatarPath,
    required this.fallbackName,
    required this.level,
    this.ringing = false,
    this.thinking = false,
    this.avatarSize = 132,
    this.glowColor,
  });

  @override
  State<CallCenterVisual> createState() => _CallCenterVisualState();
}

class _CallCenterVisualState extends State<CallCenterVisual>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;
  int _lastFrameMicros = -20000;
  bool _reduceMotion = false;
  // growable: true —— 下面每幀 removeLast + insert(0) 滾動，定長 list 會崩。
  // 只取最近幾幀做平滑，讓邊緣起伏不抖。
  final List<double> _history = List.filled(6, 0.0, growable: true);

  static const Duration _glowTransition = Duration(milliseconds: 1400);
  Color? _glowFrom;
  Color? _glowTo;
  double _glowStartedAt = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final micros = elapsed.inMicroseconds;
      final activeAudio = widget.ringing || widget.level.value > 0.035;
      final interval = activeAudio ? 16667 : 33333;
      if (micros - _lastFrameMicros < interval) return;
      _lastFrameMicros = micros;
      _t = elapsed.inMilliseconds / 1000.0;
      // 波形歷史：新值從中心湧出
      _history.removeLast();
      _history.insert(0, widget.level.value);
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(covariant CallCenterVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.glowColor != widget.glowColor) {
      // 從「此刻畫面上的顏色」出發，換色中途再換也不會跳。
      _glowFrom = _currentGlowColor();
      _glowTo = widget.glowColor;
      _glowStartedAt = _t;
    }
  }

  Color _currentGlowColor() {
    final target = _glowTo ?? widget.glowColor ?? YanciTheme.accent;
    final from = _glowFrom;
    if (from == null || _reduceMotion) return target;
    final progress =
        ((_t - _glowStartedAt) * 1000 / _glowTransition.inMilliseconds)
            .clamp(0.0, 1.0);
    if (progress >= 1) {
      _glowFrom = null;
      return target;
    }
    return Color.lerp(from, target, Curves.easeInOutCubic.transform(progress))!;
  }

  double get _smoothedLevel =>
      _history.fold<double>(0, (sum, v) => sum + v) / _history.length;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = YanciTheme.accent;
    final glowColor = _currentGlowColor();
    final lv = widget.level.value;
    // 響鈴擺動角度
    final wiggle = widget.ringing && !_reduceMotion
        ? sin(_t * 18) * 0.035 * (0.6 + 0.4 * sin(_t * 2.2))
        : 0.0;
    final thinkingBreath = widget.thinking && !_reduceMotion
        ? (sin((_t / 1.8) * 2 * pi) + 1) / 2
        : 0.0;
    final glow =
        0.10 +
        lv * 0.35 +
        thinkingBreath * 0.23 +
        (widget.ringing ? 0.08 + 0.06 * sin(_t * 6) : 0.0);
    final ringScale =
        1.0 + lv * 0.06 + thinkingBreath * 0.025 + 0.008 * sin(_t * 1.8);

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 頭像 + 光環 ──
          Transform.rotate(
            angle: wiggle,
            child: SizedBox(
              width: widget.avatarSize * 1.55,
              height: widget.avatarSize * 1.55,
              child: Stack(
                alignment: Alignment.center,
                // 流光起伏放大後會超出這個方框；不裁切，讓光自然溢出。
                clipBehavior: Clip.none,
                children: [
                  // 外層光暈（跟振幅呼吸）
                  Transform.scale(
                    scale: ringScale,
                    child: Container(
                      width: widget.avatarSize * 1.42,
                      height: widget.avatarSize * 1.42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            glowColor.withValues(alpha: glow * 0.55),
                            glowColor.withValues(alpha: glow * 0.18),
                            glowColor.withValues(alpha: 0),
                          ],
                          stops: const [0.55, 0.78, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // 頭像邊緣流光：聲音就從頭像本身發出來。輪廓隨振幅像水一樣
                  // 起伏、光帶緩慢繞圈；取代以前頭像下方那排聲波條。
                  ExcludeSemantics(
                    child: CustomPaint(
                      size: Size.square(widget.avatarSize * 1.55),
                      painter: _EdgeFlowPainter(
                        radius: widget.avatarSize / 2 + 3,
                        level: _smoothedLevel,
                        breath: thinkingBreath,
                        time: _reduceMotion ? 0 : _t,
                        color: glowColor,
                      ),
                    ),
                  ),
                  _buildAvatar(accent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(Color accent) {
    final path = widget.avatarPath;
    Widget inner;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      inner = ClipOval(
        child: Image.file(
          File(path),
          width: widget.avatarSize,
          height: widget.avatarSize,
          fit: BoxFit.cover,
        ),
      );
    } else {
      final initial = widget.fallbackName.isNotEmpty
          ? widget.fallbackName.characters.first
          : '?';
      inner = Container(
        width: widget.avatarSize,
        height: widget.avatarSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent.withValues(alpha: 0.16),
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              fontSize: widget.avatarSize * 0.36,
              color: accent,
              fontWeight: FontWeight.w600,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: YanciTheme.isDark ? 0.35 : 0.12,
            ),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: inner,
    );
  }
}

/// 頭像邊緣流光：貼著頭像外圈的一圈柔光輪廓。
///
/// 半徑由幾組不同頻率、緩慢漂移的正弦波疊加，振幅越大起伏越明顯；
/// 光帶用旋轉的 SweepGradient 做出「繞圈流動」的感覺。只畫一條 path
/// 兩次（柔光＋細芯），跟原本的聲波條同一個 ticker，不增加額外動畫源。
class _EdgeFlowPainter extends CustomPainter {
  _EdgeFlowPainter({
    required this.radius,
    required this.level,
    required this.breath,
    required this.time,
    required this.color,
  });

  final double radius;
  final double level;
  final double breath;
  final double time;
  final Color color;

  static const int _segments = 96;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final shaped = pow(level.clamp(0.0, 1.0), 0.75).toDouble();
    // 起伏幅度：2026-10-27 調為原本的 3 倍，2026-10-28 再 ×2.2（昭昭要求）。
    const amplitudeBoost = 3.0 * 2.2;
    final amplitude =
        radius * (0.012 + shaped * 0.075 + breath * 0.018) * amplitudeBoost;

    final path = Path();
    for (var i = 0; i <= _segments; i++) {
      final theta = 2 * pi * i / _segments;
      final wobble =
          sin(3 * theta + time * 1.3) * 0.55 +
          sin(5 * theta - time * 1.9) * 0.30 +
          sin(2 * theta + time * 0.7) * 0.15;
      final r = radius + amplitude * (1.15 + wobble);
      final point = center + Offset(cos(theta) * r, sin(theta) * r);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();

    final bounds = Rect.fromCircle(center: center, radius: radius * 1.3);
    Shader sweep(double alphaScale) => SweepGradient(
      colors: <Color>[
        color.withValues(alpha: 0.95 * alphaScale),
        color.withValues(alpha: 0.35 * alphaScale),
        color.withValues(alpha: 0.80 * alphaScale),
        color.withValues(alpha: 0.25 * alphaScale),
        color.withValues(alpha: 0.95 * alphaScale),
      ],
      transform: GradientRotation(time * 0.55),
    ).createShader(bounds);

    final glowStrength = (0.35 + shaped * 0.55 + breath * 0.2).clamp(0.0, 1.0);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 + shaped * 9
        ..shader = sweep(glowStrength * 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = sweep(0.45 + shaped * 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
    );
  }

  @override
  bool shouldRepaint(covariant _EdgeFlowPainter old) =>
      old.level != level ||
      old.time != time ||
      old.breath != breath ||
      old.color != color ||
      old.radius != radius;
}

/// 通話圓形操作鍵 — 實底、白圖標、≥56dp 觸控目標
class CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
  final String semanticLabel;
  final bool outlined;

  const CallActionButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    required this.semanticLabel,
    this.size = 64,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: outlined
                ? [color.withValues(alpha: 0.17), color.withValues(alpha: 0.09)]
                : [
                    Color.lerp(color, Colors.white, 0.08)!,
                    Color.lerp(color, Colors.black, 0.06)!,
                  ],
          ),
          border: Border.all(
            color: (outlined ? color : Colors.white).withValues(alpha: 0.42),
            width: 0.65,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: outlined ? 0.10 : 0.18),
              blurRadius: 10,
              spreadRadius: -2,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            splashColor: color.withValues(alpha: 0.10),
            highlightColor: color.withValues(alpha: 0.05),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(
                icon,
                size: size * 0.44,
                color: outlined ? color : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
