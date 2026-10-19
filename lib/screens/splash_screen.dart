import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../services/settings_manager.dart';

/// 開屏動畫
/// 海獺落下 → Holt 逐字淡入 → 星光散開 → 推進主頁
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.showLanguagePicker = false});

  final bool showLanguagePicker;

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
  bool _navigationStarted = false;
  bool _showLanguagePicker = false;
  bool _choosingLanguage = false;
  bool _reduceMotion = false;
  String? _selectedLocale;

  @override
  void initState() {
    super.initState();
    _showLanguagePicker = widget.showLanguagePicker;
    _selectedLocale = widget.showLanguagePicker ? L.locale : null;
    _initAnimations();
    _animationListenable = Listenable.merge([
      _logoCtrl,
      _textCtrl,
      _starCtrl,
      _exitCtrl,
    ]);
    _generateParticles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startSequence();
    });
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
          size: 2.2 + rng.nextDouble() * 3.0,
          delay: rng.nextDouble() * 0.4,
        ),
      );
    }
  }

  Future<void> _startSequence() async {
    if (_navigationStarted) return;
    final shouldChooseLanguage =
        widget.showLanguagePicker ||
        await UserSettings.shouldShowFirstLaunchLanguage();
    if (!mounted) return;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);

    if (_reduceMotion) {
      _logoCtrl.value = 1;
      _textCtrl.value = 1;
      if (shouldChooseLanguage) {
        setState(() => _showLanguagePicker = true);
      } else {
        await _navigateAfterSplash();
      }
      return;
    }
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;

    // Logo 落下
    _logoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    // 文字淡入
    _textCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // 星光散開
    _starCtrl.forward();
    if (shouldChooseLanguage) {
      await Future.delayed(const Duration(milliseconds: 320));
      if (mounted) setState(() => _showLanguagePicker = true);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    // 停留
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    // 退場
    _exitCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) await _navigateAfterSplash();
  }

  Future<void> _navigateAfterSplash() async {
    if (_navigationStarted) return;
    _navigationStarted = true;
    final shouldSetUp = await UserSettings.shouldShowInitialSetup();
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacementNamed(shouldSetUp ? '/initial_setup' : '/home');
  }

  Future<void> _selectLanguage(String locale) async {
    if (_choosingLanguage || _navigationStarted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _choosingLanguage = true;
      _selectedLocale = locale;
    });

    try {
      await L.setLocale(locale);
      await UserSettings.completeFirstLaunchLanguage();
      if (!mounted) return;
      _navigationStarted = true;
      if (!_reduceMotion) {
        await _exitCtrl.forward(from: 0);
        if (!mounted) return;
      }
      Navigator.of(context).pushReplacementNamed('/initial_setup');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _choosingLanguage = false;
        _selectedLocale = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Could not save the language. Please try again.',
              zhTW: '無法保存語言，請再試一次。',
            ),
          ),
        ),
      );
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

  Widget _buildStarBurst({required Color starColor, required Color glowColor}) {
    return Positioned.fill(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ShaderMask(
            key: const ValueKey('splash-star-feather-mask'),
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const RadialGradient(
              // 中心保持透明，避免星光穿過線稿水獺的腹部；接近水獺
              // 外輪廓時再以柔和羽化帶顯現，最外圈恢復完整亮度。
              center: Alignment.center,
              // RadialGradient 的 radius 以整個繪製範圍為基準；0.5
              // 才約等於從中心到外緣。過大的半徑會讓星點尚未穿過
              // 羽化帶就進入退場淡出，看起來像整段動畫消失。
              radius: 0.5,
              colors: <Color>[
                Colors.transparent,
                Colors.transparent,
                Color(0x88FFFFFF),
                Colors.white,
              ],
              stops: <double>[0, 0.28, 0.50, 0.65],
            ).createShader(bounds),
            child: Stack(
              clipBehavior: Clip.none,
              children: _particles.map((p) {
                final progress = _starCtrl.value;
                final delayed =
                    (progress - p.delay).clamp(0.0, 1.0) / (1.0 - p.delay);
                final ease = Curves.easeOut.transform(delayed.clamp(0.0, 1.0));
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
                        color: starColor,
                        boxShadow: [
                          BoxShadow(
                            color: glowColor,
                            blurRadius: p.size * 5,
                            spreadRadius: p.size * 0.35,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _animationListenable,
        builder: (context, _) {
          // 開屏 Logo、Holt 字樣與散開星光共用同一 accent。
          // 星點是極小面積元素，需要獨立的最低可見 alpha，不能沿用
          // 主題背景粒子的低透明度，否則部分主題下會近乎消失。
          final splashStarColor = YanciTheme.accentLight.withValues(
            alpha: YanciTheme.isDark ? 0.96 : 0.90,
          );
          final splashStarGlow = YanciTheme.accentLight.withValues(
            alpha: YanciTheme.isDark ? 0.52 : 0.40,
          );
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
                            // 星光只在水獺外圍經羽化顯現，Logo 本身不受遮罩。
                            _buildStarBurst(
                              starColor: splashStarColor,
                              glowColor: splashStarGlow,
                            ),
                            // Logo 圖片
                            SlideTransition(
                              position: _logoSlide,
                              child: ScaleTransition(
                                scale: _logoScale,
                                child: FadeTransition(
                                  opacity: _logoOpacity,
                                  child: RepaintBoundary(
                                    child: ColorFiltered(
                                      // 用 PNG alpha 當蒙版填入與 Holt 文字相同的
                                      // accent；透明背景與抗鋸齒邊緣保持原樣。
                                      colorFilter: ColorFilter.mode(
                                        YanciTheme.accent,
                                        BlendMode.srcIn,
                                      ),
                                      child: Image.asset(
                                        'assets/images/holt_logo.png',
                                        semanticLabel: 'Holt',
                                        width: 180,
                                        height: 180,
                                        fit: BoxFit.contain,
                                      ),
                                    ),
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
                      AnimatedSwitcher(
                        duration: _reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SizeTransition(
                            sizeFactor: animation,
                            alignment: Alignment.topCenter,
                            child: child,
                          ),
                        ),
                        child: _showLanguagePicker
                            ? Padding(
                                key: const ValueKey('first-language-picker'),
                                padding: const EdgeInsets.only(top: 30),
                                child: _buildLanguagePicker(),
                              )
                            : const SizedBox.shrink(),
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

  Widget _buildLanguagePicker() {
    return Semantics(
      label: 'Language · 語言',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 310),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _languageButton('zh_TW', '繁體中文'),
            const SizedBox(height: 10),
            _languageButton('zh_CN', '简体中文'),
            const SizedBox(height: 10),
            _languageButton('en', 'English'),
          ],
        ),
      ),
    );
  }

  Widget _languageButton(String locale, String label) {
    final selected = _selectedLocale == locale;
    return Semantics(
      button: true,
      label: '$label，Language',
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: OutlinedButton(
          key: ValueKey('first-language-$locale'),
          onPressed: _choosingLanguage ? null : () => _selectLanguage(locale),
          style: OutlinedButton.styleFrom(
            foregroundColor: YanciTheme.textPrimary,
            backgroundColor: YanciTheme.glassInputBg.withValues(alpha: 0.72),
            disabledForegroundColor: YanciTheme.textSecondary,
            side: BorderSide(
              color: selected
                  ? YanciTheme.accent
                  : YanciTheme.glassBorder.withValues(alpha: 0.8),
              width: selected ? 1.2 : 0.7,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: Text(
                  label,
                  style: YanciTheme.bodyText.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: selected && _choosingLanguage
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: YanciTheme.accent,
                        ),
                      )
                    : Icon(
                        Icons.arrow_forward_rounded,
                        size: 18,
                        color: YanciTheme.textSecondary,
                      ),
              ),
            ],
          ),
        ),
      ),
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
