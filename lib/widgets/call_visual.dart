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
  final double avatarSize;

  const CallCenterVisual({
    super.key,
    required this.avatarPath,
    required this.fallbackName,
    required this.level,
    this.ringing = false,
    this.avatarSize = 132,
  });

  @override
  State<CallCenterVisual> createState() => _CallCenterVisualState();
}

class _CallCenterVisualState extends State<CallCenterVisual>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;
  int _lastFrameMicros = -20000;
  // growable: true —— 下面每幀 removeLast + insert(0) 滾動，定長 list 會崩。
  final List<double> _history = List.filled(24, 0.0, growable: true);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final micros = elapsed.inMicroseconds;
      if (micros - _lastFrameMicros < 16000) return;
      _lastFrameMicros = micros;
      _t = elapsed.inMilliseconds / 1000.0;
      // 波形歷史：新值從中心湧出
      _history.removeLast();
      _history.insert(0, widget.level.value);
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = YanciTheme.accent;
    final lv = widget.level.value;
    // 響鈴擺動角度
    final wiggle = widget.ringing
        ? sin(_t * 18) * 0.035 * (0.6 + 0.4 * sin(_t * 2.2))
        : 0.0;
    final glow =
        0.10 + lv * 0.35 + (widget.ringing ? 0.08 + 0.06 * sin(_t * 6) : 0.0);
    final ringScale = 1.0 + lv * 0.06 + 0.012 * sin(_t * 1.8);

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
                            accent.withValues(alpha: glow * 0.55),
                            accent.withValues(alpha: glow * 0.18),
                            accent.withValues(alpha: 0),
                          ],
                          stops: const [0.55, 0.78, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // 細環
                  Transform.scale(
                    scale: ringScale,
                    child: Container(
                      width: widget.avatarSize + 14,
                      height: widget.avatarSize + 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accent.withValues(alpha: 0.25 + lv * 0.35),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  _buildAvatar(accent),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          // ── 聲波（真實振幅驅動）──
          SizedBox(
            height: 44,
            child: widget.ringing
                ? null
                : ExcludeSemantics(
                    child: CustomPaint(
                      size: const Size(230, 44),
                      painter: _WaveBarsPainter(
                        history: _history,
                        accent: accent,
                        time: _t,
                      ),
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

/// 中心對稱聲波條：最新振幅在中央、往兩側衰減湧開
class _WaveBarsPainter extends CustomPainter {
  final List<double> history;
  final Color accent;
  final double time;

  _WaveBarsPainter({
    required this.history,
    required this.accent,
    required this.time,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = history.length; // 單側條數
    final totalBars = n * 2 - 1;
    final gap = size.width / totalBars;
    final barW = gap * 0.52;
    final cy = size.height / 2;
    final minH = size.height * 0.10;

    for (int i = 0; i < totalBars; i++) {
      final dist = (i - (n - 1)).abs(); // 距中心
      var v = history[dist];
      // 每根加一點相位微擾，避免完全鏡像的機械感
      v *= 0.82 + 0.18 * sin(time * 7 + i * 1.7);
      // 非線性提亮：小振幅也要看得見起伏（0.3 → 0.38）
      final shaped = pow(v.clamp(0.0, 1.0), 0.8).toDouble();
      final h = max(minH, shaped * size.height * 0.92);
      final alpha = (0.72 - dist / n * 0.45).clamp(0.18, 0.85).toDouble();
      final paint = Paint()
        ..color = accent.withValues(alpha: alpha)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = barW;
      final x = gap * i + gap / 2;
      canvas.drawLine(Offset(x, cy - h / 2), Offset(x, cy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveBarsPainter old) => true;
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
      child: Material(
        color: outlined ? color.withValues(alpha: 0.12) : color,
        shape: CircleBorder(
          side: outlined
              ? BorderSide(color: color.withValues(alpha: 0.55), width: 1.4)
              : BorderSide.none,
        ),
        elevation: outlined ? 0 : 3,
        shadowColor: color.withValues(alpha: 0.4),
        child: InkWell(
          customBorder: const CircleBorder(),
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
    );
  }
}
