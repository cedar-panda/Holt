import 'dart:io';
import 'dart:ui' show ImageFilter, TileMode;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../theme/theme_presets.dart';
import '../services/settings_manager.dart';
import '../services/image_service.dart';
import '../services/background_preset_service.dart';
import '../services/background_foreground_service.dart';
import '../models/background_preset.dart';
import '../memory/database.dart';
import '../main.dart' show themeNotifier;

part 'theme_workshop_background_logic.dart';
part 'theme_workshop_background_page.dart';
part 'theme_workshop_background_preview.dart';
part 'theme_workshop_bubbles.dart';
part 'theme_workshop_color_picker.dart';
part 'theme_workshop_particles_hero.dart';
part 'theme_workshop_widgets.dart';

/// 主題工坊 — 選預設 + 微調氣泡/星光
class ThemeWorkshopScreen extends StatefulWidget {
  const ThemeWorkshopScreen({super.key});

  @override
  State<ThemeWorkshopScreen> createState() => _ThemeWorkshopScreenState();
}

class _ThemeWorkshopScreenState extends State<ThemeWorkshopScreen> {
  late String _selectedId;
  late double _bubbleOpacity;
  late double _bubbleBrightness;
  late double _bubbleRadius;
  late bool _starEnabled;
  late int _starDensity;
  late String _particleEffect;
  late bool _aiBubbleFlat;
  String _homeBgPath = '';
  double _homeBgScale = 1.0;
  double _homeBgOffsetX = 0.0;
  double _homeBgOffsetY = 0.0;
  double _homeBgBlur = 0.0;
  String _chatBgPath = '';
  double _chatBgScale = 1.0;
  double _chatBgOffsetX = 0.0;
  double _chatBgOffsetY = 0.0;
  double _chatBgBlur = 0.0;
  Color? _chatBgAiBubbleColor;
  Color? _chatBgUserBubbleColor;
  Color? _chatBgBubbleTextColor;
  Color? _chatBgThinkingTextColor;
  double? _chatBgBubbleOpacity;
  int _backgroundSlot = 1;
  Map<String, int> _backgroundBindings = <String, int>{};
  List<Color> _colorHistory = [];
  String _lightShortcutId = 'ivory';
  String _darkShortcutId = 'nightlamp';
  late PageController _themeCarouselController;
  int _currentCarouselPage = 0;

  @override
  void initState() {
    super.initState();
    _selectedId = YanciTheme.presetId;
    _bubbleOpacity = YanciTheme.bubbleOpacity;
    _bubbleBrightness = YanciTheme.bubbleBrightness;
    _bubbleRadius = YanciTheme.bubbleRadius;
    _starEnabled = YanciTheme.starEnabled;
    _starDensity = YanciTheme.starDensity;
    _particleEffect = YanciTheme.particleEffect;
    _aiBubbleFlat = YanciTheme.aiBubbleFlat;
    _homeBgPath = YanciTheme.homeBackgroundImagePath;
    _homeBgScale = YanciTheme.homeBackgroundImageScale;
    _homeBgOffsetX = YanciTheme.homeBackgroundImageOffsetX;
    _homeBgOffsetY = YanciTheme.homeBackgroundImageOffsetY;
    _homeBgBlur = YanciTheme.homeBackgroundImageBlur;
    _chatBgPath = YanciTheme.chatBackgroundImagePath;
    _chatBgScale = YanciTheme.chatBackgroundImageScale;
    _chatBgOffsetX = YanciTheme.chatBackgroundImageOffsetX;
    _chatBgOffsetY = YanciTheme.chatBackgroundImageOffsetY;
    _chatBgBlur = YanciTheme.chatBackgroundImageBlur;
    _chatBgAiBubbleColor = YanciTheme.chatBackgroundAiBubbleOverride;
    _chatBgUserBubbleColor = YanciTheme.chatBackgroundUserBubbleOverride;
    _chatBgBubbleTextColor = YanciTheme.chatBackgroundBubbleTextOverride;
    _chatBgThinkingTextColor = YanciTheme.chatBackgroundThinkingTextOverride;
    _chatBgBubbleOpacity = YanciTheme.chatBackgroundBubbleOpacityOverride;
    _currentCarouselPage = presets
        .indexWhere((p) => p.id == _selectedId)
        .clamp(0, presets.length - 1);
    _themeCarouselController = PageController(
      viewportFraction: 0.18,
      initialPage: _currentCarouselPage,
    );
    _loadColorHistory();
    _loadShortcutPresets();
    _loadBackgroundSlot();
    ThemeSettings.restoreThemeBubbleColors(_selectedId).then((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _themeCarouselController.dispose();
    super.dispose();
  }

  Future<void> _loadColorHistory() async {
    final saved = await ThemeSettings.getColorHistory();
    if (saved.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _colorHistory = saved
            .map((hex) => _hexToColor(hex))
            .whereType<Color>()
            .toList();
      });
    }
  }

  Future<void> _saveColorHistory() async {
    final hexList = _colorHistory.map((c) => _colorToHex(c)).toList();
    await ThemeSettings.saveColorHistory(hexList);
  }

  Future<void> _loadShortcutPresets() async {
    final light = await ThemeSettings.getLastLightPreset();
    final dark = await ThemeSettings.getLastDarkPreset();
    if (!mounted) return;
    setState(() {
      _lightShortcutId = light;
      _darkShortcutId = dark;
    });
  }

  Future<void> _setShortcutPreset(ThemePreset preset) async {
    if (preset.isDark) {
      await ThemeSettings.saveDarkShortcutPreset(preset.id);
      if (!mounted) return;
      setState(() => _darkShortcutId = preset.id);
    } else {
      await ThemeSettings.saveLightShortcutPreset(preset.id);
      if (!mounted) return;
      setState(() => _lightShortcutId = preset.id);
    }
  }

  void _applyPreset(String id) {
    YanciTheme.setPreset(id);
    ThemeSettings.saveThemePreset(id);
    setState(() {
      _selectedId = id;
      if (YanciTheme.particleEffectOverride == null) {
        _particleEffect = YanciTheme.particleEffect;
      }
    });
    _notifyThemeChanged();
    ThemeSettings.restoreThemeBubbleColors(id).then((_) {
      if (!mounted || _selectedId != id) return;
      setState(() {});
      _notifyThemeChanged();
    });
  }

  void _notifyThemeChanged() {
    themeNotifier.value++;
  }

  double get _chatBackgroundBubbleOpacity =>
      _chatBgBubbleOpacity ??
      BackgroundForegroundService.cachedChatBubblePalette(
        _chatBgPath,
      )?.bubbleOpacity ??
      YanciTheme.bubbleOpacity;

  bool _tuningExpanded = false;
  bool _bubbleMoreExpanded = false;

  @override
  Widget build(BuildContext context) {
    final currentPreset = presets.firstWhere(
      (p) => p.id == _selectedId,
      orElse: () => presets.first,
    );

    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _buildBackgroundMenuButton(),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: YanciTheme.backgroundGradient,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // 頂部導航
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 20,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        L.get('theme_title'),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.tune_rounded,
                        size: 20,
                        color: YanciTheme.accent,
                      ),
                      onPressed: () => _showAdvancedSettings(),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                  children: [
                    const SizedBox(height: 8),

                    // ═══ 英雄預覽卡 ═══
                    _buildHeroCard(currentPreset),
                    const SizedBox(height: 16),

                    // ═══ 圓形色卡輪盤 ═══
                    SizedBox(
                      height: 118,
                      child: Center(
                        child: SizedBox(
                          height: 104,
                          child: PageView.builder(
                            clipBehavior: Clip.none,
                            physics: const PageScrollPhysics(
                              parent: ClampingScrollPhysics(),
                            ),
                            controller: _themeCarouselController,
                            itemCount: presets.length,
                            onPageChanged: (index) {
                              _currentCarouselPage = index;
                              _applyPreset(presets[index].id);
                            },
                            itemBuilder: (context, index) {
                              final p = presets[index];
                              return AnimatedBuilder(
                                animation: _themeCarouselController,
                                builder: (context, child) {
                                  double page;
                                  try {
                                    page =
                                        _themeCarouselController.page ??
                                        _currentCarouselPage.toDouble();
                                  } catch (_) {
                                    page = _currentCarouselPage.toDouble();
                                  }
                                  final diff = (page - index).abs();
                                  final scale = (1.0 - diff * 0.25).clamp(
                                    0.6,
                                    1.0,
                                  );
                                  final opacity = (1.0 - diff * 0.4).clamp(
                                    0.2,
                                    1.0,
                                  );
                                  final isCenter = diff < 0.5;

                                  return Center(
                                    child: Transform.scale(
                                      scale: scale,
                                      child: Opacity(
                                        opacity: opacity,
                                        child: GestureDetector(
                                          onTap: () {
                                            _themeCarouselController
                                                .animateToPage(
                                                  index,
                                                  duration: const Duration(
                                                    milliseconds: 350,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                );
                                          },
                                          child: Container(
                                            width: isCenter ? 72 : 52,
                                            height: isCenter ? 72 : 52,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    isCenter ? 20 : 14,
                                                  ),
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: p.gradient,
                                              ),
                                              border: Border.all(
                                                color: isCenter
                                                    ? p.accent
                                                    : Colors.white.withValues(
                                                        alpha: 0.2,
                                                      ),
                                                width: isCenter ? 2.5 : 0.5,
                                              ),
                                              boxShadow: isCenter
                                                  ? [
                                                      BoxShadow(
                                                        color: p.accent
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                        blurRadius: 20,
                                                        spreadRadius: 3,
                                                      ),
                                                      BoxShadow(
                                                        color: p.accent
                                                            .withValues(
                                                              alpha: 0.25,
                                                            ),
                                                        blurRadius: 40,
                                                        spreadRadius: 6,
                                                      ),
                                                    ]
                                                  : null,
                                            ),
                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                Positioned(
                                                  top: 14,
                                                  left: 8,
                                                  child: Container(
                                                    width: isCenter ? 22 : 16,
                                                    height: 8,
                                                    decoration: BoxDecoration(
                                                      color: p.aiBubble
                                                          .withValues(
                                                            alpha: 0.85,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            4,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  top: 14,
                                                  right: 8,
                                                  child: Container(
                                                    width: isCenter ? 16 : 12,
                                                    height: 8,
                                                    decoration: BoxDecoration(
                                                      color: p.userBubble
                                                          .withValues(
                                                            alpha: 0.85,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            4,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                                if (isCenter)
                                                  Positioned(
                                                    bottom: 8,
                                                    child: Icon(
                                                      Icons
                                                          .check_circle_rounded,
                                                      size: 14,
                                                      color: p.accent,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ═══ 氣泡設定 ═══
                    _buildBubbleSection(currentPreset),
                    const SizedBox(height: 8),

                    // ═══ 粒子特效 ═══
                    _buildParticleSection(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
