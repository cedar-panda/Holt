import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../theme/theme_presets.dart';
import '../services/settings_manager.dart';
import '../services/image_service.dart';
import '../main.dart' show themeNotifier;

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
  String _homeBgPath = '';
  double _homeBgScale = 1.0;
  double _homeBgOffsetX = 0.0;
  double _homeBgOffsetY = 0.0;
  String _chatBgPath = '';
  double _chatBgScale = 1.0;
  double _chatBgOffsetX = 0.0;
  double _chatBgOffsetY = 0.0;
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
    _homeBgPath = YanciTheme.homeBackgroundImagePath;
    _homeBgScale = YanciTheme.homeBackgroundImageScale;
    _homeBgOffsetX = YanciTheme.homeBackgroundImageOffsetX;
    _homeBgOffsetY = YanciTheme.homeBackgroundImageOffsetY;
    _chatBgPath = YanciTheme.chatBackgroundImagePath;
    _chatBgScale = YanciTheme.chatBackgroundImageScale;
    _chatBgOffsetX = YanciTheme.chatBackgroundImageOffsetX;
    _chatBgOffsetY = YanciTheme.chatBackgroundImageOffsetY;
    _currentCarouselPage = presets
        .indexWhere((p) => p.id == _selectedId)
        .clamp(0, presets.length - 1);
    _themeCarouselController = PageController(
      viewportFraction: 0.18,
      initialPage: _currentCarouselPage,
    );
    _loadColorHistory();
    _loadShortcutPresets();
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
    setState(() => _selectedId = id);
    _notifyThemeChanged();
  }

  void _notifyThemeChanged() {
    themeNotifier.value++;
  }

  Future<void> _pickBackgroundImage(
    String scope,
    StateSetter setSheetState,
  ) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;

    final saved = await ImageService.copyBackgroundToAppDir(path, scope);
    await ThemeSettings.saveBackgroundImagePath(scope, saved);
    setSheetState(() {
      if (scope == 'home') {
        _homeBgPath = saved;
        YanciTheme.homeBackgroundImagePath = saved;
      } else {
        _chatBgPath = saved;
        YanciTheme.chatBackgroundImagePath = saved;
      }
    });
    _notifyThemeChanged();
  }

  Future<void> _clearBackgroundImage(
    String scope,
    StateSetter setSheetState,
  ) async {
    // 連文件一起刪，不留磁盤殘餘
    await ImageService.deleteBackgroundImages(scope);
    await ThemeSettings.saveBackgroundImagePath(scope, '');
    setSheetState(() {
      if (scope == 'home') {
        _homeBgPath = '';
        YanciTheme.homeBackgroundImagePath = '';
      } else {
        _chatBgPath = '';
        YanciTheme.chatBackgroundImagePath = '';
      }
    });
    _notifyThemeChanged();
  }

  Future<void> _setBackgroundScale(
    String scope,
    double scale,
    StateSetter setSheetState,
  ) async {
    await ThemeSettings.saveBackgroundImageScale(scope, scale);
    setSheetState(() {
      if (scope == 'home') {
        _homeBgScale = scale;
        YanciTheme.homeBackgroundImageScale = scale;
      } else {
        _chatBgScale = scale;
        YanciTheme.chatBackgroundImageScale = scale;
      }
    });
    _notifyThemeChanged();
  }

  Future<void> _setBackgroundOffset(
    String scope,
    double x,
    double y,
    StateSetter setSheetState,
  ) async {
    final clampedX = x.clamp(-0.5, 0.5).toDouble();
    final clampedY = y.clamp(-0.5, 0.5).toDouble();
    await ThemeSettings.saveBackgroundImageOffset(
      scope,
      x: clampedX,
      y: clampedY,
    );
    setSheetState(() {
      if (scope == 'home') {
        _homeBgOffsetX = clampedX;
        _homeBgOffsetY = clampedY;
        YanciTheme.homeBackgroundImageOffsetX = clampedX;
        YanciTheme.homeBackgroundImageOffsetY = clampedY;
      } else {
        _chatBgOffsetX = clampedX;
        _chatBgOffsetY = clampedY;
        YanciTheme.chatBackgroundImageOffsetX = clampedX;
        YanciTheme.chatBackgroundImageOffsetY = clampedY;
      }
    });
    _notifyThemeChanged();
  }

  void _showBackgroundSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.82,
          maxChildSize: 0.94,
          minChildSize: 0.5,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.isDark
                  ? const Color(0xF0252228)
                  : Colors.white.withValues(alpha: 0.97),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(YanciTheme.radiusLg),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: YanciTheme.spacingMd),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(YanciTheme.spacingMd),
                  child: Row(
                    children: [
                      Text(
                        L.pick(en: 'Image Backgrounds', zhTW: '圖片背景'),
                        style: YanciTheme.headingMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: YanciTheme.textSecondary,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    children: [
                      _backgroundCard(
                        scope: 'home',
                        title: L.pick(en: 'Home', zhTW: '首頁'),
                        path: _homeBgPath,
                        scale: _homeBgScale,
                        offsetX: _homeBgOffsetX,
                        offsetY: _homeBgOffsetY,
                        setSheetState: setSheetState,
                      ),
                      const SizedBox(height: 14),
                      _backgroundCard(
                        scope: 'chat',
                        title: L.pick(en: 'Chat', zhTW: '對話框'),
                        path: _chatBgPath,
                        scale: _chatBgScale,
                        offsetX: _chatBgOffsetX,
                        offsetY: _chatBgOffsetY,
                        setSheetState: setSheetState,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _backgroundCard({
    required String scope,
    required String title,
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    required StateSetter setSheetState,
  }) {
    final fileExists = path.isNotEmpty && File(path).existsSync();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: YanciTheme.glassBorder.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: YanciTheme.bodyText.copyWith(fontSize: 14)),
              const Spacer(),
              IconButton(
                tooltip: L.pick(en: 'Choose image', zhTW: '選擇圖片'),
                icon: Icon(
                  Icons.photo_library_rounded,
                  color: YanciTheme.accent,
                ),
                onPressed: () => _pickBackgroundImage(scope, setSheetState),
              ),
              IconButton(
                tooltip: L.pick(en: 'Clear', zhTW: '清除'),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: YanciTheme.textSecondary,
                ),
                onPressed: fileExists
                    ? () => _clearBackgroundImage(scope, setSheetState)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: SizedBox(
              width: 126,
              child: AspectRatio(
                aspectRatio: 9 / 20,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: YanciTheme.backgroundGradient,
                          ),
                        ),
                      ),
                      if (fileExists)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Transform.translate(
                              offset: Offset(
                                offsetX.clamp(-0.5, 0.5).toDouble() *
                                    constraints.maxWidth,
                                offsetY.clamp(-0.5, 0.5).toDouble() *
                                    constraints.maxHeight,
                              ),
                              child: Transform.scale(
                                scale: scale.clamp(0.8, 2.0).toDouble(),
                                child: Image.file(
                                  File(path),
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            );
                          },
                        ),
                      if (!fileExists)
                        Center(
                          child: Icon(
                            Icons.image_outlined,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        ),
                      Positioned(
                        top: 10,
                        left: 10,
                        right: 10,
                        child: Container(
                          height: 18,
                          decoration: BoxDecoration(
                            color: YanciTheme.glassWhite.withValues(
                              alpha: 0.55,
                            ),
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 28,
                        child: Container(
                          height: 26,
                          decoration: BoxDecoration(
                            color: YanciTheme.aiBubble.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _slider(
            L.pick(en: 'Scale', zhTW: '大小'),
            scale,
            0.8,
            2.0,
            12,
            '${(scale * 100).round()}%',
            (v) => _setBackgroundScale(scope, v, setSheetState),
          ),
          _slider(
            L.pick(en: 'X', zhTW: '左右'),
            offsetX,
            -0.5,
            0.5,
            20,
            _offsetDisplay(offsetX, axis: Axis.horizontal),
            (v) => _setBackgroundOffset(scope, v, offsetY, setSheetState),
          ),
          _slider(
            L.pick(en: 'Y', zhTW: '上下'),
            offsetY,
            -0.5,
            0.5,
            20,
            _offsetDisplay(offsetY, axis: Axis.vertical),
            (v) => _setBackgroundOffset(scope, offsetX, v, setSheetState),
          ),
        ],
      ),
    );
  }

  String _offsetDisplay(double value, {required Axis axis}) {
    final pct = (value * 100).round();
    if (pct == 0) return '0%';
    if (L.locale == 'en') return '${pct > 0 ? '+' : ''}$pct%';
    if (axis == Axis.horizontal) {
      return pct > 0
          ? L.pick(en: 'Right $pct%', zhTW: '右$pct%')
          : L.pick(en: 'Left ${pct.abs()}%', zhTW: '左${pct.abs()}%');
    }
    return pct > 0
        ? L.pick(en: 'Down $pct%', zhTW: '下$pct%')
        : L.pick(en: 'Up ${pct.abs()}%', zhTW: '上${pct.abs()}%');
  }

  bool _tuningExpanded = false;

  @override
  Widget build(BuildContext context) {
    final currentPreset = presets.firstWhere(
      (p) => p.id == _selectedId,
      orElse: () => presets.first,
    );

    return Scaffold(
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
                      tooltip: L.pick(en: 'Image backgrounds', zhTW: '圖片背景'),
                      icon: Icon(
                        Icons.image_rounded,
                        size: 20,
                        color: YanciTheme.accent,
                      ),
                      onPressed: _showBackgroundSettings,
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
                  padding: const EdgeInsets.symmetric(horizontal: 16),
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
                            physics: const BouncingScrollPhysics(),
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

                    // ═══ 氣泡預覽（色卡下方常駐） ═══
                    _buildBubblePreview(),
                    const SizedBox(height: 20),

                    // ═══ 可收起微調區 ═══
                    GestureDetector(
                      onTap: () =>
                          setState(() => _tuningExpanded = !_tuningExpanded),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: YanciTheme.isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.white.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: YanciTheme.isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.white.withValues(alpha: 0.7),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.tune_rounded,
                              size: 18,
                              color: YanciTheme.accent.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              L.pick(en: 'Fine Tuning', zhTW: '微調'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                            const Spacer(),
                            AnimatedRotation(
                              turns: _tuningExpanded ? 0.5 : 0,
                              duration: const Duration(milliseconds: 250),
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 20,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    AnimatedCrossFade(
                      firstChild: const SizedBox.shrink(),
                      secondChild: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── 氣泡微調 ──
                            Row(
                              children: [
                                Text(
                                  L.get('theme_bubble'),
                                  style: YanciTheme.bodySmall.copyWith(
                                    color: YanciTheme.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _bubbleOpacity = 0.85;
                                      _bubbleRadius = 22.0;
                                      _bubbleBrightness = 0.0;
                                    });
                                    YanciTheme.bubbleOpacity = 0.85;
                                    YanciTheme.bubbleRadius = 22.0;
                                    YanciTheme.bubbleBrightness = 0.0;
                                    ThemeSettings.saveBubbleOpacity(0.85);
                                    ThemeSettings.saveBubbleRadius(22.0);
                                    ThemeSettings.saveBubbleBrightness(0.0);
                                    _notifyThemeChanged();
                                  },
                                  behavior: HitTestBehavior.opaque,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 4, horizontal: 8),
                                    child: Text(
                                      L.pick(en: 'Reset', zhTW: '恢復默認值'),
                                      style: YanciTheme.bodySmall.copyWith(
                                        color: YanciTheme.accent,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _slider(
                              L.get('theme_opacity_label'),
                              _bubbleOpacity,
                              0.3,
                              1.0,
                              14,
                              '${(_bubbleOpacity * 100).round()}',
                              (v) {
                                setState(() => _bubbleOpacity = v);
                                YanciTheme.bubbleOpacity = v;
                                ThemeSettings.saveBubbleOpacity(v);
                                _notifyThemeChanged();
                              },
                            ),
                            _slider(
                              L.get('theme_radius_label'),
                              _bubbleRadius,
                              8,
                              32,
                              12,
                              '${_bubbleRadius.round()}',
                              (v) {
                                setState(() => _bubbleRadius = v);
                                YanciTheme.bubbleRadius = v;
                                ThemeSettings.saveBubbleRadius(v);
                                _notifyThemeChanged();
                              },
                            ),
                            _slider(
                              L.pick(en: 'Brightness', zhTW: '亮度'),
                              _bubbleBrightness,
                              -1.0,
                              1.0,
                              20,
                              '${_bubbleBrightness >= 0 ? '+' : ''}${(_bubbleBrightness * 6).round()}',
                              (v) {
                                setState(() => _bubbleBrightness = v);
                                YanciTheme.bubbleBrightness = v;
                                ThemeSettings.saveBubbleBrightness(v);
                                _notifyThemeChanged();
                              },
                            ),
                            const SizedBox(height: 16),

                            // ── 星光 ──
                            Text(
                              L.get('theme_starlight'),
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Text(
                                  L.get('theme_star_particle'),
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 14,
                                  ),
                                ),
                                const Spacer(),
                                SizedBox(
                                  height: 24,
                                  child: Switch(
                                    value: _starEnabled,
                                    onChanged: (v) {
                                      setState(() => _starEnabled = v);
                                      YanciTheme.starEnabled = v;
                                      ThemeSettings.saveStarEnabled(v);
                                      _notifyThemeChanged();
                                    },
                                    activeThumbColor: YanciTheme.accent,
                                  ),
                                ),
                              ],
                            ),
                            if (_starEnabled)
                              _slider(
                                L.get('theme_density_label'),
                                _starDensity.toDouble(),
                                4,
                                30,
                                13,
                                '$_starDensity',
                                (v) {
                                  setState(() => _starDensity = v.round());
                                  YanciTheme.starDensity = v.round();
                                  ThemeSettings.saveStarDensity(v.round());
                                  _notifyThemeChanged();
                                },
                              ),
                          ],
                        ),
                      ),
                      crossFadeState: _tuningExpanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      duration: const Duration(milliseconds: 300),
                    ),
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

  // ═══ 英雄預覽卡 ═══
  Widget _buildShortcutToggle(ThemePreset preset) {
    final isShortcut = preset.isDark
        ? _darkShortcutId == preset.id
        : _lightShortcutId == preset.id;
    final icon = preset.isDark
        ? Icons.nightlight_round
        : Icons.wb_sunny_rounded;
    final label = preset.isDark
        ? (L.pick(en: 'Set as night shortcut', zhTW: '設為夜間快捷'))
        : (L.pick(en: 'Set as day shortcut', zhTW: '設為日間快捷'));
    final color = isShortcut
        ? preset.accent
        : preset.textSecondary.withValues(alpha: 0.42);

    return Tooltip(
      message: label,
      child: InkResponse(
        radius: 18,
        onTap: () => _setShortcutPreset(preset),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: isShortcut
                ? preset.accent.withValues(alpha: 0.16)
                : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: isShortcut
                  ? preset.accent.withValues(alpha: 0.45)
                  : preset.textSecondary.withValues(alpha: 0.18),
              width: 0.8,
            ),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }

  Widget _buildHeroCard(ThemePreset preset) {
    return Container(
      height: 160,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: preset.gradient,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: preset.accent.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: preset.accent.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 裝飾星星
          Positioned(
            top: 16,
            right: 18,
            child: Icon(
              Icons.auto_awesome,
              size: 14,
              color: preset.starColor.withValues(alpha: 0.6),
            ),
          ),
          Positioned(
            top: 32,
            right: 40,
            child: Icon(
              Icons.auto_awesome,
              size: 8,
              color: preset.starColor.withValues(alpha: 0.35),
            ),
          ),
          // 氣泡預覽
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              width: 90,
              height: 22,
              decoration: BoxDecoration(
                color: preset.aiBubble,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: preset.aiBubbleBorder.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          Positioned(
            top: 46,
            right: 20,
            child: Container(
              width: 60,
              height: 22,
              decoration: BoxDecoration(
                color: preset.userBubble,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: preset.userBubbleBorder.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          // 底部文字
          Positioned(
            bottom: 16,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L.get('theme_preset_${preset.id}'),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: preset.textPrimary,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildShortcutToggle(preset),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  preset.subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: preset.textSecondary.withValues(alpha: 0.7),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
          // accent 色點
          Positioned(
            bottom: 18,
            right: 20,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: preset.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: preset.accent.withValues(alpha: 0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══ 氣泡預覽 ═══
  Widget _buildBubblePreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // AI 氣泡
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: YanciTheme.aiBubble,
                borderRadius: BorderRadius.circular(_bubbleRadius),
                border: Border.all(color: YanciTheme.aiBubbleBorder),
              ),
              child: Text(
                L.get('theme_preview_hi'),
                style: YanciTheme.bodyText.copyWith(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 用戶氣泡
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: YanciTheme.userBubble,
                borderRadius: BorderRadius.circular(_bubbleRadius),
                border: Border.all(color: YanciTheme.userBubbleBorder),
              ),
              child: Text(
                L.get('theme_preview_reply'),
                style: YanciTheme.bodyText.copyWith(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══ 通用拉條 ═══
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    String display,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: YanciTheme.bodyText.copyWith(fontSize: 13),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: YanciTheme.accent.withValues(alpha: 0.6),
                inactiveTrackColor: YanciTheme.accent.withValues(alpha: 0.12),
                thumbColor: YanciTheme.accent,
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: YanciTheme.bodySmall.copyWith(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════
  // 進階設定（完全自定義色號）
  // ═══════════════════════════════════

  void _showAdvancedSettings() {
    final p = YanciTheme.preset;

    // 可編輯的顏色清單
    final colorEntries = <_ColorEntry>[
      _ColorEntry(L.get('theme_bg1'), p.bg1, 'bg1'),
      _ColorEntry(L.get('theme_bg2'), p.bg2, 'bg2'),
      _ColorEntry(L.get('theme_bg3'), p.bg3, 'bg3'),
      _ColorEntry(L.get('theme_bg4'), p.bg4, 'bg4'),
      _ColorEntry(L.get('theme_ai_bubble'), p.aiBubble, 'aiBubble'),
      _ColorEntry(L.get('theme_user_bubble'), p.userBubble, 'userBubble'),
      _ColorEntry(L.get('theme_text_primary'), p.textPrimary, 'textPrimary'),
      _ColorEntry(
        L.get('theme_text_secondary'),
        p.textSecondary,
        'textSecondary',
      ),
      _ColorEntry(L.get('theme_accent_color'), p.accent, 'accent'),
      _ColorEntry(L.get('theme_star_color'), p.starColor, 'starColor'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.isDark
                  ? const Color(0xF0252228)
                  : Colors.white.withValues(alpha: 0.97),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(YanciTheme.radiusLg),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: YanciTheme.spacingMd),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(YanciTheme.spacingMd),
                  child: Row(
                    children: [
                      Text(
                        L.get('theme_advanced'),
                        style: YanciTheme.headingMedium,
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          _applyCustomColors(colorEntries);
                          Navigator.pop(ctx);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: YanciTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            L.get('theme_apply'),
                            style: TextStyle(
                              fontSize: 13,
                              color: YanciTheme.accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                      horizontal: YanciTheme.spacingMd,
                    ),
                    children: [
                      Text(
                        L.get('theme_hex'),
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...colorEntries.map(
                        (entry) => _colorRow(
                          entry,
                          setSheetState,
                          allEntries: colorEntries,
                        ),
                      ),
                      const SizedBox(height: YanciTheme.spacingLg),
                      Text(
                        L.get('theme_value'),
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _numberRow(
                        L.get('theme_bubble_radius'),
                        _bubbleRadius,
                        4,
                        40,
                        (v) {
                          setSheetState(() => _bubbleRadius = v);
                        },
                      ),
                      _numberRow(
                        L.get('theme_bubble_opacity'),
                        _bubbleOpacity * 100,
                        20,
                        100,
                        (v) {
                          setSheetState(() => _bubbleOpacity = v / 100);
                        },
                      ),
                      _numberRow(
                        L.get('theme_star_density'),
                        _starDensity.toDouble(),
                        0,
                        40,
                        (v) {
                          setSheetState(() => _starDensity = v.round());
                        },
                      ),
                      const SizedBox(height: YanciTheme.spacingLg),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _colorRow(
    _ColorEntry entry,
    StateSetter setSheetState, {
    List<_ColorEntry>? allEntries,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // 勾選框（多選套用）
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: entry.selected,
              onChanged: (v) =>
                  setSheetState(() => entry.selected = v ?? false),
              activeColor: YanciTheme.accent,
              side: BorderSide(
                color: YanciTheme.textSecondary.withValues(alpha: 0.2),
              ),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          // 色塊（點擊展開色盤）
          GestureDetector(
            onTap: () =>
                _showColorPicker(entry, setSheetState, allEntries: allEntries),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: entry.color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.15),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 標籤
          Expanded(
            child: Text(
              entry.label,
              style: TextStyle(fontSize: 12, color: YanciTheme.textPrimary),
            ),
          ),
          // HEX 顯示（唯讀）
          Text(
            '#${_colorToHex(entry.color)}',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: YanciTheme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 色盤 — HSL 選色器 + 歷史色
  void _showColorPicker(
    _ColorEntry entry,
    StateSetter parentState, {
    List<_ColorEntry>? allEntries,
  }) {
    var hsl = HSLColor.fromColor(entry.color);
    var previewColor = entry.color;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setPickerState) {
          void updateColor() {
            previewColor = hsl.toColor();
            setPickerState(() {});
          }

          return AlertDialog(
            backgroundColor: YanciTheme.isDark
                ? const Color(0xFF252228)
                : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            contentPadding: const EdgeInsets.all(16),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 預覽色塊
                  Container(
                    width: double.infinity,
                    height: 48,
                    decoration: BoxDecoration(
                      color: previewColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // ── 色相 ──
                  _pickerSlider(
                    L.pick(en: 'Hue', zhTW: '色相'),
                    hsl.hue,
                    0,
                    360,
                    activeColor: HSLColor.fromAHSL(
                      1,
                      hsl.hue,
                      0.8,
                      0.5,
                    ).toColor(),
                    onChanged: (v) {
                      hsl = hsl.withHue(v);
                      updateColor();
                    },
                    gradient: LinearGradient(
                      colors: List.generate(
                        7,
                        (i) =>
                            HSLColor.fromAHSL(1, i * 60.0, 0.8, 0.5).toColor(),
                      ),
                    ),
                  ),

                  // ── 飽和 ──
                  _pickerSlider(
                    L.pick(en: 'Saturation', zhTW: '飽和'),
                    hsl.saturation,
                    0,
                    1,
                    activeColor: previewColor,
                    onChanged: (v) {
                      hsl = hsl.withSaturation(v);
                      updateColor();
                    },
                  ),

                  // ── 亮度 ──
                  _pickerSlider(
                    L.pick(en: 'Brightness', zhTW: '亮度'),
                    hsl.lightness,
                    0,
                    1,
                    activeColor: previewColor,
                    onChanged: (v) {
                      hsl = hsl.withLightness(v);
                      updateColor();
                    },
                  ),

                  const SizedBox(height: 10),

                  // ── 歷史選色 ──
                  if (_colorHistory.isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        L.pick(en: 'History', zhTW: '歷史'),
                        style: TextStyle(
                          fontSize: 11,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _colorHistory.map((c) {
                        return GestureDetector(
                          onTap: () {
                            hsl = HSLColor.fromColor(c);
                            updateColor();
                          },
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.1,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  L.get('cancel'),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ),
              // 儲存到歷史 + 套用
              TextButton(
                onPressed: () {
                  final color = previewColor;
                  // 加入歷史（去重，最多 8 個）
                  _colorHistory.removeWhere(
                    (c) => _colorToHex(c) == _colorToHex(color),
                  );
                  _colorHistory.insert(0, color);
                  if (_colorHistory.length > 8) _colorHistory.removeLast();
                  _saveColorHistory();
                  Navigator.pop(ctx);
                  parentState(() {
                    // 套用到當前 + 所有勾選的元素
                    entry.color = color;
                    if (allEntries != null) {
                      for (final e in allEntries) {
                        if (e.selected && e.key != entry.key) {
                          e.color = color;
                        }
                      }
                    }
                  });
                },
                child: Text(
                  '✓ ${L.get('theme_apply')}',
                  style: TextStyle(color: YanciTheme.accent),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pickerSlider(
    String label,
    double value,
    double min,
    double max, {
    required Color activeColor,
    required ValueChanged<double> onChanged,
    Gradient? gradient,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: gradient != null
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          gradient: gradient,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          thumbColor: Colors.white,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                        ),
                        child: Slider(
                          value: value,
                          min: min,
                          max: max,
                          onChanged: onChanged,
                        ),
                      ),
                    ],
                  )
                : SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: activeColor.withValues(alpha: 0.6),
                      inactiveTrackColor: activeColor.withValues(alpha: 0.12),
                      thumbColor: activeColor,
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: value,
                      min: min,
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _numberRow(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: YanciTheme.textPrimary),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: YanciTheme.accent.withValues(alpha: 0.6),
                thumbColor: YanciTheme.accent,
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 35,
            child: Text(
              '${value.round()}',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _applyCustomColors(List<_ColorEntry> entries) {
    // 保存自定義覆蓋到 SharedPreferences
    for (final e in entries) {
      ThemeSettings.saveCustomColor(e.key, _colorToHex(e.color));
    }
    YanciTheme.bubbleOpacity = _bubbleOpacity;
    YanciTheme.bubbleRadius = _bubbleRadius;
    YanciTheme.starDensity = _starDensity;
    ThemeSettings.saveBubbleOpacity(_bubbleOpacity);
    ThemeSettings.saveBubbleRadius(_bubbleRadius);
    ThemeSettings.saveStarDensity(_starDensity);
    _notifyThemeChanged();
  }

  String _colorToHex(Color c) {
    return c
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2)
        .toUpperCase();
  }

  Color? _hexToColor(String hex) {
    hex = hex.replaceAll('#', '').trim();
    if (hex.length == 6) {
      final v = int.tryParse('FF$hex', radix: 16);
      if (v != null) return Color(v);
    } else if (hex.length == 8) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(v);
    }
    return null;
  }
}

class _ColorEntry {
  final String label;
  Color color;
  final String key;
  bool selected;

  _ColorEntry(this.label, this.color, this.key) : selected = false;
}
