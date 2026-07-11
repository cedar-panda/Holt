import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 開屏動畫
/// 海獺落下 → Holt 逐字淡入 → 星光散開 → 推進主頁
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // 主控制器（logo 出現）
  late AnimationController _logoCtrl;
  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<Offset> _logoSlide;

  // 文字控制器
  late AnimationController _textCtrl;

  // 星光控制器
  late AnimationController _starCtrl;

  // 退場控制器
  late AnimationController _exitCtrl;
  late Animation<double> _exitOpacity;
  late Animation<Offset> _exitSlide;

  late Listenable _animationListenable;

  // 星光粒子
  final List<_StarParticle> _particles = [];

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _animationListenable = Listenable.merge([
      _logoCtrl,
      _textCtrl,
      _starCtrl,
      _exitCtrl,
    ]);
    _generateParticles();
    _startSequence();
  }

  void _initAnimations() {
    // ═══ 1. Logo：從上方滑落 + 縮放 + 淡入 ═══
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoSlide = Tween<Offset>(
      begin: const Offset(0, -0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOutBack));
    _logoScale = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOutBack));
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _logoCtrl,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
    );

    // ═══ 2. 文字「Holt」逐字淡入 ═══
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // ═══ 3. 星光散開 ═══
    _starCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    // ═══ 4. 退場 ═══
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _exitOpacity = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _exitCtrl, curve: Curves.easeIn));
    _exitSlide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, -0.08),
    ).animate(CurvedAnimation(parent: _exitCtrl, curve: Curves.easeIn));
  }

  void _generateParticles() {
    final rng = Random();
    for (var i = 0; i < 12; i++) {
      final angle = (i / 12) * 2 * pi + rng.nextDouble() * 0.5;
      final distance = 80.0 + rng.nextDouble() * 60;
      _particles.add(
        _StarParticle(
          angle: angle,
          distance: distance,
          size: 1.5 + rng.nextDouble() * 2.5,
          delay: rng.nextDouble() * 0.4,
        ),
      );
    }
  }

  Future<void> _startSequence() async {
    await Future.delayed(const Duration(milliseconds: 200));

    // Logo 落下
    _logoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 600));

    // 文字淡入
    _textCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 300));

    // 星光散開
    _starCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 1200));

    // 停留
    await Future.delayed(const Duration(milliseconds: 400));

    // 退場
    _exitCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 500));

    // 跳轉主頁
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _textCtrl.dispose();
    _starCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _animationListenable,
        builder: (context, _) {
          return FadeTransition(
            opacity: _exitOpacity,
            child: SlideTransition(
              position: _exitSlide,
              child: Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: YanciTheme.backgroundGradient,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ═══ Logo + 星光 ═══
                      SizedBox(
                        width: 260,
                        height: 260,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 星光粒子
                            ..._particles.map((p) {
                              final progress = _starCtrl.value;
                              final delayed =
                                  (progress - p.delay).clamp(0.0, 1.0) /
                                  (1.0 - p.delay);
                              final ease = Curves.easeOut.transform(
                                delayed.clamp(0.0, 1.0),
                              );
                              final x = cos(p.angle) * p.distance * ease;
                              final y = sin(p.angle) * p.distance * ease;
                              final opacity = delayed < 0.3
                                  ? delayed / 0.3
                                  : delayed > 0.7
                                  ? (1 - delayed) / 0.3
                                  : 1.0;
                              return Positioned(
                                left: 130 + x - p.size / 2,
                                top: 130 + y - p.size / 2,
                                child: Opacity(
                                  opacity: opacity.clamp(0.0, 1.0),
                                  child: Container(
                                    width: p.size,
                                    height: p.size,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: YanciTheme.starColor,
                                      boxShadow: [
                                        BoxShadow(
                                          color: YanciTheme.starGlow,
                                          blurRadius: p.size * 3,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
                            // Logo 圖片
                            SlideTransition(
                              position: _logoSlide,
                              child: ScaleTransition(
                                scale: _logoScale,
                                child: FadeTransition(
                                  opacity: _logoOpacity,
                                  child: Image.asset(
                                    'assets/images/holt_logo.png',
                                    width: 180,
                                    height: 180,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // ═══ 「Holt」逐字淡入 ═══
                      _buildHoltText(),
                      const SizedBox(height: 6),
                      // 小星星裝飾
                      FadeTransition(
                        opacity: CurvedAnimation(
                          parent: _textCtrl,
                          curve: const Interval(0.6, 1.0),
                        ),
                        child: Icon(
                          Icons.auto_awesome,
                          size: 10,
                          color: YanciTheme.accent.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHoltText() {
    const letters = ['H', 'o', 'l', 't'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(letters.length, (i) {
        final start = i * 0.2;
        final end = (start + 0.5).clamp(0.0, 1.0);
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: _textCtrl,
            curve: Interval(start, end, curve: Curves.easeOut),
          ),
          child: Text(
            letters[i],
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w300,
              color: YanciTheme.accent,
              letterSpacing: 6,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        );
      }),
    );
  }
}

class _StarParticle {
  final double angle;
  final double distance;
  final double size;
  final double delay;

  _StarParticle({
    required this.angle,
    required this.distance,
    required this.size,
    required this.delay,
  });
}
