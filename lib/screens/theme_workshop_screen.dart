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

  Future<void> _loadBackgroundSlot() async {
    final slot = await BackgroundPresetService.getActiveSlot();
    final preset = await BackgroundPresetService.loadSlot(slot);
    final bindings = await BackgroundPresetService.getCharacterBindings();
    if (!mounted) return;
    setState(() {
      _backgroundSlot = slot;
      _backgroundBindings = bindings;
      _applyBackgroundPresetFields(preset);
    });
  }

  void _applyBackgroundPresetFields(BackgroundPreset preset) {
    _homeBgPath = preset.homePath;
    _homeBgScale = preset.homeScale;
    _homeBgOffsetX = preset.homeOffsetX;
    _homeBgOffsetY = preset.homeOffsetY;
    _homeBgBlur = preset.homeBlur;
    _chatBgPath = preset.chatPath;
    _chatBgScale = preset.chatScale;
    _chatBgOffsetX = preset.chatOffsetX;
    _chatBgOffsetY = preset.chatOffsetY;
    _chatBgBlur = preset.chatBlur;
    _chatBgAiBubbleColor = preset.chatAiBubbleColor == null
        ? null
        : Color(preset.chatAiBubbleColor!);
    _chatBgUserBubbleColor = preset.chatUserBubbleColor == null
        ? null
        : Color(preset.chatUserBubbleColor!);
    _chatBgBubbleTextColor = preset.chatBubbleTextColor == null
        ? null
        : Color(preset.chatBubbleTextColor!);
    _chatBgThinkingTextColor = preset.chatThinkingTextColor == null
        ? null
        : Color(preset.chatThinkingTextColor!);
    _chatBgBubbleOpacity = preset.chatBubbleOpacity;
  }

  BackgroundPreset _currentBackgroundPreset() => BackgroundPreset(
    slot: _backgroundSlot,
    homePath: _homeBgPath,
    homeScale: _homeBgScale,
    homeOffsetX: _homeBgOffsetX,
    homeOffsetY: _homeBgOffsetY,
    homeBlur: _homeBgBlur,
    chatPath: _chatBgPath,
    chatScale: _chatBgScale,
    chatOffsetX: _chatBgOffsetX,
    chatOffsetY: _chatBgOffsetY,
    chatBlur: _chatBgBlur,
    chatAiBubbleColor: _chatBgAiBubbleColor?.toARGB32(),
    chatUserBubbleColor: _chatBgUserBubbleColor?.toARGB32(),
    chatBubbleTextColor: _chatBgBubbleTextColor?.toARGB32(),
    chatThinkingTextColor: _chatBgThinkingTextColor?.toARGB32(),
    chatBubbleOpacity: _chatBgBubbleOpacity,
  );

  Future<void> _persistCurrentBackgroundPreset() async {
    await BackgroundPresetService.saveAndActivate(_currentBackgroundPreset());
  }

  Future<void> _selectBackgroundSlot(int slot, StateSetter setPageState) async {
    if (slot == _backgroundSlot) return;
    final preset = await BackgroundPresetService.activateSlot(slot);
    if (!mounted) return;
    setPageState(() {
      _backgroundSlot = slot;
      _applyBackgroundPresetFields(preset);
    });
    _notifyThemeChanged();
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
    ThemeSettings.restoreThemeBubbleColors(id).then((_) {
      if (!mounted || _selectedId != id) return;
      setState(() {});
      _notifyThemeChanged();
    });
  }

  void _notifyThemeChanged() {
    themeNotifier.value++;
  }

  Future<void> _pickBackgroundImage(
    String scope,
    StateSetter setSheetState,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowCompression: false,
      withData: false,
      withReadStream: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;

    final storageScope = 'slot_${_backgroundSlot}_$scope';
    final saved = await ImageService.copyBackgroundToAppDir(path, storageScope);
    setSheetState(() {
      if (scope == 'home') {
        _homeBgPath = saved;
        YanciTheme.homeBackgroundImagePath = saved;
      } else {
        _chatBgPath = saved;
        YanciTheme.chatBackgroundImagePath = saved;
      }
    });
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  Future<void> _clearBackgroundImage(
    String scope,
    StateSetter setSheetState,
  ) async {
    // 只刪當前槽位，不碰另外五套背景。
    final previousPath = scope == 'home' ? _homeBgPath : _chatBgPath;
    await ImageService.deleteBackgroundImages('slot_${_backgroundSlot}_$scope');
    await ImageService.deleteBackgroundFile(previousPath);
    setSheetState(() {
      if (scope == 'home') {
        _homeBgPath = '';
        YanciTheme.homeBackgroundImagePath = '';
      } else {
        _chatBgPath = '';
        YanciTheme.chatBackgroundImagePath = '';
      }
    });
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  Future<void> _setBackgroundScale(
    String scope,
    double scale,
    StateSetter setSheetState,
  ) async {
    setSheetState(() {
      if (scope == 'home') {
        _homeBgScale = scale;
        YanciTheme.homeBackgroundImageScale = scale;
      } else {
        _chatBgScale = scale;
        YanciTheme.chatBackgroundImageScale = scale;
      }
    });
    await _persistCurrentBackgroundPreset();
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
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  Future<void> _setBackgroundBlur(
    String scope,
    double blur,
    StateSetter setPageState,
  ) async {
    final value = blur.clamp(0.0, 20.0).toDouble();
    setPageState(() {
      if (scope == 'home') {
        _homeBgBlur = value;
        YanciTheme.homeBackgroundImageBlur = value;
      } else {
        _chatBgBlur = value;
        YanciTheme.chatBackgroundImageBlur = value;
      }
    });
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  Color? _chatBackgroundColorOverride(_ChatBackgroundColorRole role) =>
      switch (role) {
        _ChatBackgroundColorRole.aiBubble => _chatBgAiBubbleColor,
        _ChatBackgroundColorRole.userBubble => _chatBgUserBubbleColor,
        _ChatBackgroundColorRole.bubbleText => _chatBgBubbleTextColor,
        _ChatBackgroundColorRole.thinkingText => _chatBgThinkingTextColor,
      };

  Color _chatBackgroundColor(_ChatBackgroundColorRole role) => switch (role) {
    _ChatBackgroundColorRole.aiBubble =>
      (_chatBgAiBubbleColor ??
              YanciTheme.bubbleColorOverride(
                YanciTheme.presetId,
                ThemeBubbleColorRole.aiBubble,
              ) ??
              BackgroundForegroundService.cachedChatBubblePalette(
                _chatBgPath,
              )?.aiBubble ??
              YanciTheme.aiBubble)
          .withValues(alpha: _chatBackgroundBubbleOpacity),
    _ChatBackgroundColorRole.userBubble =>
      (_chatBgUserBubbleColor ??
              YanciTheme.bubbleColorOverride(
                YanciTheme.presetId,
                ThemeBubbleColorRole.userBubble,
              ) ??
              BackgroundForegroundService.cachedChatBubblePalette(
                _chatBgPath,
              )?.userBubble ??
              YanciTheme.userBubble)
          .withValues(alpha: _chatBackgroundBubbleOpacity),
    _ChatBackgroundColorRole.bubbleText =>
      _chatBgBubbleTextColor ??
          YanciTheme.bubbleColorOverride(
            YanciTheme.presetId,
            ThemeBubbleColorRole.textOnBubble,
          ) ??
          BackgroundForegroundService.cachedChatBubblePalette(
            _chatBgPath,
          )?.bubbleText ??
          YanciTheme.textOnBubble,
    _ChatBackgroundColorRole.thinkingText =>
      _chatBgThinkingTextColor ??
          BackgroundForegroundService.cachedChatBubblePalette(
            _chatBgPath,
          )?.thinkingText ??
          Color.lerp(YanciTheme.textSecondary, YanciTheme.textPrimary, 0.34)!,
  };

  double get _chatBackgroundBubbleOpacity =>
      _chatBgBubbleOpacity ??
      BackgroundForegroundService.cachedChatBubblePalette(
        _chatBgPath,
      )?.bubbleOpacity ??
      YanciTheme.bubbleOpacity;

  Future<void> _saveChatBackgroundColor(
    _ChatBackgroundColorRole role,
    Color? color,
  ) async {
    final argb = color?.toARGB32();
    switch (role) {
      case _ChatBackgroundColorRole.aiBubble:
        _chatBgAiBubbleColor = color;
        YanciTheme.chatBackgroundAiBubbleOverride = color;
        await ThemeSettings.saveChatBackgroundAiBubbleColor(argb);
      case _ChatBackgroundColorRole.userBubble:
        _chatBgUserBubbleColor = color;
        YanciTheme.chatBackgroundUserBubbleOverride = color;
        await ThemeSettings.saveChatBackgroundUserBubbleColor(argb);
      case _ChatBackgroundColorRole.bubbleText:
        _chatBgBubbleTextColor = color;
        YanciTheme.chatBackgroundBubbleTextOverride = color;
        await ThemeSettings.saveChatBackgroundBubbleTextColor(argb);
      case _ChatBackgroundColorRole.thinkingText:
        _chatBgThinkingTextColor = color;
        YanciTheme.chatBackgroundThinkingTextOverride = color;
        await ThemeSettings.saveChatBackgroundThinkingTextColor(argb);
    }
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  Future<void> _saveChatBackgroundBubbleOpacity(double? opacity) async {
    _chatBgBubbleOpacity = opacity;
    YanciTheme.chatBackgroundBubbleOpacityOverride = opacity;
    await ThemeSettings.saveChatBackgroundBubbleOpacity(opacity);
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

  void _pickChatBackgroundColor(
    _ChatBackgroundColorRole role,
    String label,
    StateSetter setSheetState,
  ) {
    final entry = _ColorEntry(
      label,
      _chatBackgroundColor(role),
      'chatBackground-${role.name}',
    );
    _showColorPicker(
      entry,
      setSheetState,
      onApplied: (color) async {
        await _saveChatBackgroundColor(role, color);
        if (mounted) setSheetState(() {});
      },
      presetColors: role == _ChatBackgroundColorRole.bubbleText
          ? const [
              Color(0xFF343840),
              Color(0xFF242126),
              Color(0xFFFFFFFF),
              Color(0xFF654F45),
              Color(0xFF384C68),
            ]
          : null,
    );
  }

  Future<void> _openBackgroundPage() async {
    var selectedScope = 'home'; // 'home' or 'chat'
    var homePositionExpanded = false;
    var chatPositionExpanded = false;
    var chatColorsExpanded = false;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setPageState) {
            final isHome = selectedScope == 'home';
            final activePath = isHome ? _homeBgPath : _chatBgPath;
            final activeScale = isHome ? _homeBgScale : _chatBgScale;
            final activeOffsetX = isHome ? _homeBgOffsetX : _chatBgOffsetX;
            final activeOffsetY = isHome ? _homeBgOffsetY : _chatBgOffsetY;
            final activeBlur = isHome ? _homeBgBlur : _chatBgBlur;
            final activeFileExists =
                activePath.isNotEmpty && File(activePath).existsSync();
            final positionExpanded = isHome
                ? homePositionExpanded
                : chatPositionExpanded;

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
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: L.pick(en: 'Back', zhTW: '返回'),
                                  icon: Icon(
                                    Icons.arrow_back_ios_rounded,
                                    size: 20,
                                    color: YanciTheme.textPrimary,
                                  ),
                                  onPressed: () => Navigator.pop(ctx),
                                ),
                                Expanded(
                                  child: Text(
                                    L.pick(
                                      en: 'Background',
                                      zhTW: '背景',
                                      zhCN: '背景',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: YanciTheme.headingMedium,
                                  ),
                                ),
                                const SizedBox(width: 48),
                              ],
                            ),
                          ),

                          _buildBackgroundSlotSelector(setPageState),
                          _buildBackgroundCharacterBindingEntry(setPageState),

                          // 上方雙預覽；選中項決定下方正在編輯的背景。
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                              child: LayoutBuilder(
                                builder: (ctx, constraints) {
                                  final previewW =
                                      (constraints.maxWidth - 12) / 2;
                                  final previewH = constraints.maxHeight;
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _bgDialogPreview(
                                        scope: 'home',
                                        label: L.pick(en: 'Home', zhTW: '首頁'),
                                        path: _homeBgPath,
                                        scale: _homeBgScale,
                                        offsetX: _homeBgOffsetX,
                                        offsetY: _homeBgOffsetY,
                                        blur: _homeBgBlur,
                                        selected: isHome,
                                        width: previewW,
                                        height: previewH,
                                        onTap: () => setPageState(
                                          () => selectedScope = 'home',
                                        ),
                                        onAdd: () => _pickBackgroundImage(
                                          'home',
                                          setPageState,
                                        ),
                                        overlay: _buildPortraitHomePreview(),
                                      ),
                                      const SizedBox(width: 12),
                                      _bgDialogPreview(
                                        scope: 'chat',
                                        label: L.pick(en: 'Chat', zhTW: '對話框'),
                                        path: _chatBgPath,
                                        scale: _chatBgScale,
                                        offsetX: _chatBgOffsetX,
                                        offsetY: _chatBgOffsetY,
                                        blur: _chatBgBlur,
                                        selected: !isHome,
                                        width: previewW,
                                        height: previewH,
                                        onTap: () => setPageState(
                                          () => selectedScope = 'chat',
                                        ),
                                        onAdd: () => _pickBackgroundImage(
                                          'chat',
                                          setPageState,
                                        ),
                                        overlay: _buildPortraitChatPreview(),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),

                          Expanded(
                            flex: 2,
                            child: Stack(
                              children: [
                                ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    4,
                                    24,
                                    24,
                                  ),
                                  children: [
                                    _bgDialogCollapsible(
                                      key: ValueKey(
                                        'background-$selectedScope-position-section',
                                      ),
                                      title: L.pick(
                                        en: 'Image position',
                                        zhTW: '圖片位置微調',
                                      ),
                                      expanded: positionExpanded,
                                      onToggle: () => setPageState(() {
                                        if (isHome) {
                                          homePositionExpanded =
                                              !homePositionExpanded;
                                        } else {
                                          chatPositionExpanded =
                                              !chatPositionExpanded;
                                        }
                                      }),
                                      child: Column(
                                        children: [
                                          _slider(
                                            L.pick(en: 'Scale', zhTW: '大小'),
                                            activeScale,
                                            0.8,
                                            2.0,
                                            12,
                                            '${(activeScale * 100).round()}%',
                                            (v) => _setBackgroundScale(
                                              selectedScope,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(en: 'X', zhTW: '左右'),
                                            activeOffsetX,
                                            -0.5,
                                            0.5,
                                            20,
                                            _offsetDisplay(
                                              activeOffsetX,
                                              axis: Axis.horizontal,
                                            ),
                                            (v) => _setBackgroundOffset(
                                              selectedScope,
                                              v,
                                              activeOffsetY,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(en: 'Y', zhTW: '上下'),
                                            activeOffsetY,
                                            -0.5,
                                            0.5,
                                            20,
                                            _offsetDisplay(
                                              activeOffsetY,
                                              axis: Axis.vertical,
                                            ),
                                            (v) => _setBackgroundOffset(
                                              selectedScope,
                                              activeOffsetX,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(
                                              en: 'Blur',
                                              zhTW: '模糊度',
                                              zhCN: '模糊度',
                                            ),
                                            activeBlur,
                                            0.0,
                                            20.0,
                                            20,
                                            activeBlur == 0
                                                ? L.pick(
                                                    en: 'Off',
                                                    zhTW: '關閉',
                                                    zhCN: '关闭',
                                                  )
                                                : activeBlur.round().toString(),
                                            (v) => _setBackgroundBlur(
                                              selectedScope,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    if (!isHome)
                                      _bgDialogCollapsible(
                                        key: const ValueKey(
                                          'background-chat-colors-section',
                                        ),
                                        title: L.pick(
                                          en: 'Text & bubble colors',
                                          zhTW: '字體氣泡顏色',
                                        ),
                                        expanded: chatColorsExpanded,
                                        onToggle: () => setPageState(
                                          () => chatColorsExpanded =
                                              !chatColorsExpanded,
                                        ),
                                        child: Column(
                                          children: [
                                            _buildChatBackgroundColorPreview(
                                              path: _chatBgPath,
                                              scale: _chatBgScale,
                                              offsetX: _chatBgOffsetX,
                                              offsetY: _chatBgOffsetY,
                                              fileExists:
                                                  _chatBgPath.isNotEmpty &&
                                                  File(
                                                    _chatBgPath,
                                                  ).existsSync(),
                                            ),
                                            const SizedBox(height: 10),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .aiBubble,
                                              label: L.pick(
                                                en: 'Character bubble',
                                                zhTW: '角色氣泡',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .userBubble,
                                              label: L.pick(
                                                en: 'User bubble',
                                                zhTW: '用戶氣泡',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .bubbleText,
                                              label: L.pick(
                                                en: 'Bubble text',
                                                zhTW: '氣泡內字體顏色',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .thinkingText,
                                              label: L.pick(
                                                en: 'Thinking text',
                                                zhTW: 'Thinking 字體顏色',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundOpacityControl(
                                              setPageState,
                                            ),
                                          ],
                                        ),
                                      ),

                                    if (activeFileExists)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: TextButton.icon(
                                          onPressed: () =>
                                              _clearBackgroundImage(
                                                selectedScope,
                                                setPageState,
                                              ),
                                          icon: Icon(
                                            Icons.delete_outline_rounded,
                                            size: 16,
                                            color: YanciTheme.textSecondary
                                                .withValues(alpha: 0.7),
                                          ),
                                          label: Text(
                                            L.pick(
                                              en: 'Remove image',
                                              zhTW: '刪除圖片',
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.7),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (!isHome && chatColorsExpanded)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 4,
                                    child: Center(
                                      child: _AlternatingDoubleChevronHint(
                                        color: YanciTheme.textSecondary,
                                      ),
                                    ),
                                  ),
                              ],
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
        ),
      ),
    );

    if (mounted) setState(() {});
  }

  Widget _buildBackgroundSlotSelector(StateSetter setPageState) {
    return SizedBox(
      height: 48,
      child: Row(
        key: const ValueKey('background-preset-slots'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(BackgroundPresetService.slotCount, (
          index,
        ) {
          final slot = index + 1;
          final selected = slot == _backgroundSlot;
          final label = L.pick(
            en: 'Background set $slot',
            zhTW: '背景套組 $slot',
            zhCN: '背景套组 $slot',
          );
          return Semantics(
            button: true,
            selected: selected,
            label: label,
            child: Tooltip(
              message: label,
              child: InkResponse(
                key: ValueKey('background-preset-slot-$slot'),
                radius: 22,
                onTap: () => _selectBackgroundSlot(slot, setPageState),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.34,
                                ),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '$slot',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.72,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBackgroundCharacterBindingEntry(StateSetter setPageState) {
    final count = _backgroundBindings.values
        .where((slot) => slot == _backgroundSlot)
        .length;
    final detail = count == 0
        ? L.pick(
            en: 'No characters use set $_backgroundSlot',
            zhTW: '第 $_backgroundSlot 套尚未綁定角色',
            zhCN: '第 $_backgroundSlot 套尚未绑定角色',
          )
        : L.pick(
            en: '$count characters use set $_backgroundSlot',
            zhTW: '第 $_backgroundSlot 套 · 已綁定 $count 位角色',
            zhCN: '第 $_backgroundSlot 套 · 已绑定 $count 位角色',
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: Semantics(
        button: true,
        label: L.pick(
          en: 'Bind characters to background set $_backgroundSlot',
          zhTW: '為背景套組 $_backgroundSlot 綁定角色',
          zhCN: '为背景套组 $_backgroundSlot 绑定角色',
        ),
        child: InkWell(
          key: const ValueKey('background-preset-character-binding'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openBackgroundCharacterBindings(setPageState),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.pick(
                            en: 'Bind characters',
                            zhTW: '綁定角色',
                            zhCN: '绑定角色',
                          ),
                          style: TextStyle(
                            color: YanciTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.66,
                            ),
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.42),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBackgroundCharacterBindings(
    StateSetter setPageState,
  ) async {
    final characters = await DatabaseHelper.getCharacters();
    final bindings = Map<String, int>.from(
      await BackgroundPresetService.getCharacterBindings(),
    );
    if (!mounted) return;
    final slot = _backgroundSlot;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return SafeArea(
            top: false,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
              ),
              decoration: BoxDecoration(
                color: YanciTheme.backgroundGradient.last,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border(
                  top: BorderSide(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.16),
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 34,
                    height: 3,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            L.pick(
                              en: 'Set $slot · Bind characters',
                              zhTW: '第 $slot 套 · 綁定角色',
                              zhCN: '第 $slot 套 · 绑定角色',
                            ),
                            style: YanciTheme.headingMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(
                            Icons.close_rounded,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        L.pick(
                          en: 'Selected characters use this set on Home and in chat.',
                          zhTW: '選中的角色會在首頁與對話框使用這套背景。',
                          zhCN: '选中的角色会在首页与对话框使用这套背景。',
                        ),
                        style: TextStyle(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.72,
                          ),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  Flexible(
                    child: characters.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                L.pick(
                                  en: 'No characters yet',
                                  zhTW: '目前還沒有角色',
                                  zhCN: '目前还没有角色',
                                ),
                                style: YanciTheme.bodySmall,
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                            itemCount: characters.length,
                            itemBuilder: (context, index) {
                              final character = characters[index];
                              final id = (character['id'] as String?) ?? '';
                              final name = (character['name'] as String?)
                                  ?.trim();
                              final avatarPath =
                                  (character['avatar_path'] as String?) ?? '';
                              final avatarFile = avatarPath.isEmpty
                                  ? null
                                  : File(avatarPath);
                              final selected = bindings[id] == slot;
                              final otherSlot = bindings[id];
                              final subtitle = !selected && otherSlot != null
                                  ? L.pick(
                                      en: 'Currently uses set $otherSlot',
                                      zhTW: '目前使用第 $otherSlot 套',
                                      zhCN: '目前使用第 $otherSlot 套',
                                    )
                                  : null;
                              return CheckboxListTile(
                                key: ValueKey(
                                  'background-binding-character-$id',
                                ),
                                value: selected,
                                controlAffinity:
                                    ListTileControlAffinity.trailing,
                                activeColor: YanciTheme.accent,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                secondary: CircleAvatar(
                                  radius: 19,
                                  backgroundColor: YanciTheme.accent.withValues(
                                    alpha: 0.1,
                                  ),
                                  foregroundImage:
                                      avatarFile?.existsSync() ?? false
                                      ? FileImage(avatarFile!)
                                      : null,
                                  child: avatarFile?.existsSync() ?? false
                                      ? null
                                      : Icon(
                                          Icons.person_outline_rounded,
                                          size: 18,
                                          color: YanciTheme.textSecondary,
                                        ),
                                ),
                                title: Text(
                                  name?.isNotEmpty == true
                                      ? name!
                                      : L.pick(
                                          en: 'Unnamed character',
                                          zhTW: '未命名角色',
                                          zhCN: '未命名角色',
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: YanciTheme.textPrimary,
                                    fontSize: 13,
                                  ),
                                ),
                                subtitle: subtitle == null
                                    ? null
                                    : Text(
                                        subtitle,
                                        style: TextStyle(
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.62),
                                          fontSize: 10.5,
                                        ),
                                      ),
                                onChanged: (_) async {
                                  HapticFeedback.selectionClick();
                                  await BackgroundPresetService.setCharacterBinding(
                                    id,
                                    selected ? null : slot,
                                  );
                                  if (!mounted || !sheetContext.mounted) {
                                    return;
                                  }
                                  if (selected) {
                                    bindings.remove(id);
                                  } else {
                                    bindings[id] = slot;
                                  }
                                  _backgroundBindings = Map<String, int>.from(
                                    bindings,
                                  );
                                  setSheetState(() {});
                                  setPageState(() {});
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Pixel 風格的單張預覽卡片（用在彈窗上部 2/3）
  Widget _bgDialogPreview({
    required String scope,
    required String label,
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    required double blur,
    required bool selected,
    required double width,
    required double height,
    required VoidCallback onTap,
    required VoidCallback onAdd,
    required Widget overlay,
  }) {
    final fileExists = path.isNotEmpty && File(path).existsSync();
    return GestureDetector(
      key: ValueKey('background-$scope-preview'),
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: selected ? 1.0 : 0.5,
        duration: const Duration(milliseconds: 200),
        child: AnimatedScale(
          scale: selected ? 1.0 : 0.92,
          duration: const Duration(milliseconds: 200),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                // 標籤
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? YanciTheme.accent
                          : YanciTheme.textSecondary,
                    ),
                  ),
                ),
                // 手機預覽框
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _backgroundPreviewCanvas(
                          path: path,
                          scale: scale,
                          offsetX: offsetX,
                          offsetY: offsetY,
                          blur: blur,
                          fileExists: fileExists,
                          overlay: overlay,
                        ),
                        // 選中邊框
                        if (selected)
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: YanciTheme.accent.withValues(alpha: 0.6),
                                width: 2,
                              ),
                            ),
                          ),
                        // 中心 + 按鈕（加圖片）
                        if (!fileExists)
                          Center(
                            child: GestureDetector(
                              onTap: onAdd,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.15,
                                  ),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.4,
                                    ),
                                    width: 1,
                                  ),
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 20,
                                  color: YanciTheme.accent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 無邊框無底色的可收起區塊（用在彈窗下部 1/3）
  Widget _bgDialogCollapsible({
    Key? key,
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Column(
      key: key,
      children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: child,
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  Widget _backgroundPreviewCanvas({
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    double blur = 0,
    required bool fileExists,
    required Widget overlay,
  }) {
    return ClipRRect(
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
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: blur.clamp(0.0, 20.0).toDouble(),
                sigmaY: blur.clamp(0.0, 20.0).toDouble(),
                tileMode: TileMode.clamp,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Transform.translate(
                  offset: Offset(
                    offsetX.clamp(-0.5, 0.5).toDouble() * constraints.maxWidth,
                    offsetY.clamp(-0.5, 0.5).toDouble() * constraints.maxHeight,
                  ),
                  child: Transform.scale(
                    scale: scale.clamp(0.8, 2.0).toDouble(),
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                      gaplessPlayback: true,
                      isAntiAlias: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          if (!fileExists)
            Center(
              child: Icon(
                Icons.image_outlined,
                color: YanciTheme.textSecondary.withValues(alpha: 0.35),
              ),
            ),
          overlay,
        ],
      ),
    );
  }

  Widget _buildPortraitHomePreview() {
    return Stack(
      children: [
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Container(
            height: 18,
            decoration: BoxDecoration(
              color: YanciTheme.glassWhite.withValues(alpha: 0.55),
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
    );
  }

  Widget _buildPortraitChatPreview() {
    final thinkingColor = _chatBackgroundColor(
      _ChatBackgroundColorRole.thinkingText,
    );
    final r = _bubbleRadius * 0.42; // 按比例縮放圓角
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 3),
          // Thinking 提示
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              'Thinking  ›',
              style: TextStyle(fontSize: 6.5, color: thinkingColor),
            ),
          ),
          // AI 氣泡（左對齊，左下角小圓角）
          Align(
            alignment: Alignment.centerLeft,
            child: _miniPreviewBubble(
              color: _chatBackgroundColor(_ChatBackgroundColorRole.aiBubble),
              textColor: _chatBackgroundColor(
                _ChatBackgroundColorRole.bubbleText,
              ),
              borderColor: YanciTheme.aiBubbleBorder,
              text: L.get('theme_preview_hi'),
              radius: r,
              isUser: false,
            ),
          ),
          const SizedBox(height: 8),
          // 用戶氣泡（右對齊，右下角小圓角）
          Align(
            alignment: Alignment.centerRight,
            child: _miniPreviewBubble(
              color: _chatBackgroundColor(_ChatBackgroundColorRole.userBubble),
              textColor: _chatBackgroundColor(
                _ChatBackgroundColorRole.bubbleText,
              ),
              borderColor: YanciTheme.userBubbleBorder,
              text: L.get('theme_preview_reply'),
              radius: r,
              isUser: true,
            ),
          ),
          const Spacer(flex: 5),
        ],
      ),
    );
  }

  Widget _miniPreviewBubble({
    required Color color,
    required Color textColor,
    required Color borderColor,
    required String text,
    required double radius,
    required bool isUser,
  }) {
    final r = radius.clamp(3.0, 14.0);
    final flat = !isUser && _aiBubbleFlat;
    return Container(
      constraints: BoxConstraints(maxWidth: flat ? 120 : 84),
      padding: EdgeInsets.symmetric(
        horizontal: flat ? 2 : 7,
        vertical: flat ? 3 : 5,
      ),
      decoration: flat
          ? null
          : BoxDecoration(
              color: color,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(r),
                topRight: Radius.circular(r),
                bottomLeft: Radius.circular(isUser ? r : 2),
                bottomRight: Radius.circular(isUser ? 2 : r),
              ),
              border: Border.all(
                color: borderColor.withValues(alpha: 0.5),
                width: 0.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.16 : 0.04,
                  ),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
      child: Text(
        text,
        key: ValueKey(
          isUser
              ? 'chat-portrait-preview-user-text'
              : 'chat-portrait-preview-ai-text',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 6.5,
          color: textColor,
          fontFamily: YanciTheme.fontFamily,
        ),
      ),
    );
  }

  Widget _buildChatBackgroundColorPreview({
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    required bool fileExists,
  }) {
    final thinkingColor = _chatBackgroundColor(
      _ChatBackgroundColorRole.thinkingText,
    );
    final r = _bubbleRadius.clamp(6.0, 32.0);
    return SizedBox(
      key: const ValueKey('chat-background-color-preview'),
      height: 178,
      width: double.infinity,
      child: _backgroundPreviewCanvas(
        path: path,
        scale: scale,
        offsetX: offsetX,
        offsetY: offsetY,
        fileExists: fileExists,
        overlay: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thinking 提示行
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 10,
                    color: thinkingColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Thinking  ›  Memory · Mood',
                    style: TextStyle(
                      fontSize: 11,
                      color: thinkingColor,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // AI 氣泡（左對齊，左下角尖）
              Align(
                alignment: Alignment.centerLeft,
                child: _colorPreviewBubble(
                  color: _chatBackgroundColor(
                    _ChatBackgroundColorRole.aiBubble,
                  ),
                  textColor: _chatBackgroundColor(
                    _ChatBackgroundColorRole.bubbleText,
                  ),
                  borderColor: YanciTheme.aiBubbleBorder,
                  text: L.get('theme_preview_hi'),
                  radius: r,
                  isUser: false,
                ),
              ),
              const Spacer(),
              // 用戶氣泡（右對齊，右下角尖）
              Align(
                alignment: Alignment.centerRight,
                child: _colorPreviewBubble(
                  color: _chatBackgroundColor(
                    _ChatBackgroundColorRole.userBubble,
                  ),
                  textColor: _chatBackgroundColor(
                    _ChatBackgroundColorRole.bubbleText,
                  ),
                  borderColor: YanciTheme.userBubbleBorder,
                  text: L.get('theme_preview_reply'),
                  radius: r,
                  isUser: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorPreviewBubble({
    required Color color,
    required Color textColor,
    required Color borderColor,
    required String text,
    required double radius,
    required bool isUser,
  }) {
    final flat = !isUser && _aiBubbleFlat;
    return Container(
      constraints: BoxConstraints(maxWidth: flat ? 260 : 200),
      padding: EdgeInsets.symmetric(
        horizontal: flat ? 4 : 12,
        vertical: flat ? 4 : 8,
      ),
      decoration: flat
          ? null
          : BoxDecoration(
              color: color,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(radius),
                topRight: Radius.circular(radius),
                bottomLeft: Radius.circular(isUser ? radius : 4),
                bottomRight: Radius.circular(isUser ? 4 : radius),
              ),
              border: Border.all(
                color: borderColor.withValues(alpha: 0.5),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.18 : 0.05,
                  ),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
      child: Text(
        text,
        key: ValueKey(
          isUser
              ? 'chat-color-preview-user-text'
              : 'chat-color-preview-ai-text',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: YanciTheme.bodyText.copyWith(fontSize: 12, color: textColor),
      ),
    );
  }

  Widget _chatBackgroundColorRow({
    required _ChatBackgroundColorRole role,
    required String label,
    required StateSetter setSheetState,
  }) {
    final color = _chatBackgroundColor(role);
    final hasOverride = _chatBackgroundColorOverride(role) != null;
    final isText =
        role == _ChatBackgroundColorRole.thinkingText ||
        role == _ChatBackgroundColorRole.bubbleText;
    final isUser = role == _ChatBackgroundColorRole.userBubble;
    final r = _bubbleRadius.clamp(6.0, 32.0) * 0.6;

    // 氣泡型色塊 / 文字色條
    Widget colorChip;
    if (isText) {
      // Thinking 顏色 → 用文字預覽取代色塊
      colorChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              role == _ChatBackgroundColorRole.thinkingText
                  ? Icons.auto_awesome
                  : Icons.text_fields_rounded,
              size: 11,
              color: color.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
            Text(
              role == _ChatBackgroundColorRole.thinkingText ? 'Thinking' : 'Aa',
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontFamily: YanciTheme.fontFamily,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    } else {
      // 氣泡顏色 → 用 mini bubble 形狀預覽
      colorChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(r),
            topRight: Radius.circular(r),
            bottomLeft: Radius.circular(isUser ? r : 3),
            bottomRight: Radius.circular(isUser ? 3 : r),
          ),
          border: Border.all(
            color:
                (isUser
                        ? YanciTheme.userBubbleBorder
                        : YanciTheme.aiBubbleBorder)
                    .withValues(alpha: 0.5),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: YanciTheme.isDark ? 0.12 : 0.04,
              ),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          isUser ? 'Hi' : 'Hello',
          style: TextStyle(
            fontSize: 10,
            color: YanciTheme.textOnBubble,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: label,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pickChatBackgroundColor(role, label, setSheetState),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    colorChip,
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: YanciTheme.textPrimary,
                          ),
                        ),
                        Text(
                          '#${_colorToHex(color)}',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          if (hasOverride)
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                key: ValueKey('chat-background-${role.name}-reset'),
                tooltip: L.pick(en: 'Use theme default', zhTW: '恢復主題預設'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await _saveChatBackgroundColor(role, null);
                  setSheetState(() {});
                },
                icon: Icon(
                  Icons.restart_alt_rounded,
                  size: 16,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatBackgroundOpacityControl(StateSetter setSheetState) {
    final opacity = _chatBackgroundBubbleOpacity;
    final hasOverride = _chatBgBubbleOpacity != null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(en: 'Bubble opacity', zhTW: '氣泡透明度', zhCN: '气泡透明度'),
            style: YanciTheme.bodyText.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Slider(
                  key: const ValueKey('chat-background-bubble-opacity'),
                  value: opacity.clamp(0.0, 1.0),
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  onChanged: (value) {
                    setSheetState(() => _chatBgBubbleOpacity = value);
                    YanciTheme.chatBackgroundBubbleOpacityOverride = value;
                    _notifyThemeChanged();
                  },
                  onChangeEnd: (value) =>
                      _saveChatBackgroundBubbleOpacity(value),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${(opacity * 100).round()}%',
                  key: const ValueKey('chat-background-bubble-opacity-value'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.accent,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('chat-background-bubble-opacity-reset'),
                tooltip: L.pick(en: 'Use theme default', zhTW: '恢復主題預設'),
                visualDensity: VisualDensity.compact,
                onPressed: hasOverride
                    ? () async {
                        await _saveChatBackgroundBubbleOpacity(null);
                        setSheetState(() {});
                      }
                    : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
              ),
            ],
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

  Widget _buildBackgroundMenuButton() {
    final label = L.pick(en: 'Background', zhTW: '背景', zhCN: '背景');
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('theme-image-background-entry'),
            onTap: _openBackgroundPage,
            customBorder: const CircleBorder(),
            child: Container(
              width: 84,
              height: 84,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: YanciTheme.accent.withValues(alpha: 0.52),
                  width: 1.2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 24,
                    color: YanciTheme.accent,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.fade,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: L.locale == 'en' ? 10 : 12,
                      height: 1.05,
                      fontWeight: FontWeight.w500,
                      color: YanciTheme.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ═══ AI 輸出樣式藥丸 ═══
  Widget _buildAiBubbleStylePill(ThemePreset preset) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final selectedIndex = _aiBubbleFlat ? 1 : 0;
    final surface = Color.lerp(
      YanciTheme.surfacePanel,
      preset.accent,
      YanciTheme.isDark ? .14 : .10,
    )!;
    const width = 132.0;
    const height = 36.0;
    const padding = 4.0;
    return Row(
      children: [
        Icon(
          Icons.notes_rounded,
          size: 18,
          color: preset.textSecondary.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 8),
        Text(
          L.pick(en: 'Reply Style', zhTW: '回應方式', zhCN: '回应方式'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: preset.textPrimary,
          ),
        ),
        const Spacer(),
        Container(
          width: width,
          height: height,
          padding: const EdgeInsets.all(padding),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: YanciTheme.isDark ? .30 : .12,
                ),
                blurRadius: 5,
                offset: const Offset(-1.5, -1.5),
                blurStyle: BlurStyle.inner,
              ),
              BoxShadow(
                color: Colors.white.withValues(
                  alpha: YanciTheme.isDark ? .10 : .76,
                ),
                blurRadius: 4,
                offset: const Offset(1.5, 1.5),
                blurStyle: BlurStyle.inner,
              ),
            ],
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 330),
                curve: reduced ? Curves.linear : Curves.easeOutBack,
                alignment: selectedIndex == 0
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: Container(
                  width: (width - padding * 2) / 2,
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      surface,
                      preset.accent,
                      YanciTheme.isDark ? .18 : .13,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: preset.accent.withValues(alpha: .11),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  _aiBubbleStyleItem(
                    preset: preset,
                    label: L.pick(en: 'Bubble', zhTW: '氣泡'),
                    selected: !_aiBubbleFlat,
                    onTap: () => _setAiBubbleFlat(false),
                  ),
                  _aiBubbleStyleItem(
                    preset: preset,
                    label: L.pick(en: 'Flat', zhTW: '平鋪'),
                    selected: _aiBubbleFlat,
                    onTap: () => _setAiBubbleFlat(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _aiBubbleStyleItem({
    required ThemePreset preset,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (selected) return;
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: YanciTheme.fontFamily,
              fontSize: 10,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? preset.accent
                  : preset.textSecondary.withValues(alpha: .55),
            ),
          ),
        ),
      ),
    );
  }

  void _setAiBubbleFlat(bool flat) {
    setState(() => _aiBubbleFlat = flat);
    YanciTheme.aiBubbleFlat = flat;
    ThemeSettings.saveAiBubbleFlat(flat);
    _notifyThemeChanged();
  }

  // ═══ 氣泡設定區 ═══
  Widget _buildBubbleSection(ThemePreset preset) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          // ── 回應方式（氣泡 / 平鋪）：決定是否有氣泡，故置於氣泡設定之上 ──
          Padding(
            padding: const EdgeInsets.only(
              left: 4,
              right: 4,
              top: 2,
              bottom: 8,
            ),
            child: _buildAiBubbleStylePill(preset),
          ),

          // ── 標題列：氣泡 icon + 文字 + 展開箭頭 ──
          GestureDetector(
            key: const ValueKey('theme-bubble-section-toggle'),
            onTap: () => setState(() => _tuningExpanded = !_tuningExpanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: preset.textSecondary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    L.pick(en: 'Bubble', zhTW: '氣泡'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: preset.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _tuningExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: preset.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 展開內容 ──
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4, bottom: 8),
              child: Column(
                children: [
                  // AI 氣泡顏色
                  _bubbleColorRow(
                    label: L.pick(en: 'AI Bubble', zhTW: 'AI 氣泡'),
                    color: YanciTheme.aiBubble,
                    role: ThemeBubbleColorRole.aiBubble,
                    preset: preset,
                    isTextColor: false,
                  ),
                  const SizedBox(height: 6),
                  // 使用者氣泡顏色
                  _bubbleColorRow(
                    label: L.pick(en: 'My Bubble', zhTW: '我的氣泡'),
                    color: YanciTheme.userBubble,
                    role: ThemeBubbleColorRole.userBubble,
                    preset: preset,
                    isTextColor: false,
                  ),
                  const SizedBox(height: 6),
                  // 字體顏色
                  _bubbleColorRow(
                    label: L.pick(en: 'Text', zhTW: '字體'),
                    color: YanciTheme.textOnBubble,
                    role: ThemeBubbleColorRole.textOnBubble,
                    preset: preset,
                    isTextColor: true,
                  ),
                  const SizedBox(height: 10),
                  // 透明度
                  Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text(
                          L.pick(en: 'Opacity', zhTW: '透明度'),
                          style: TextStyle(
                            fontSize: 11,
                            color: preset.textSecondary.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            activeTrackColor: preset.accent,
                            inactiveTrackColor: preset.textSecondary.withValues(
                              alpha: 0.15,
                            ),
                            thumbColor: preset.accent,
                            overlayColor: preset.accent.withValues(alpha: 0.12),
                          ),
                          child: Slider(
                            value: _bubbleOpacity,
                            min: 0.1,
                            max: 1.0,
                            onChanged: (v) {
                              setState(() => _bubbleOpacity = v);
                              YanciTheme.bubbleOpacity = v;
                              ThemeSettings.saveBubbleOpacity(v);
                              _notifyThemeChanged();
                            },
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '${(_bubbleOpacity * 100).round()}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 10,
                            color: preset.textSecondary.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // ── 更多設置 ──
                  GestureDetector(
                    onTap: () => setState(
                      () => _bubbleMoreExpanded = !_bubbleMoreExpanded,
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            L.pick(en: 'More', zhTW: '更多設置'),
                            style: TextStyle(
                              fontSize: 11,
                              color: preset.textSecondary.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _bubbleMoreExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 16,
                              color: preset.textSecondary.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedCrossFade(
                    firstChild: const SizedBox.shrink(),
                    secondChild: Column(
                      children: [
                        // 圓角
                        Row(
                          children: [
                            SizedBox(
                              width: 56,
                              child: Text(
                                L.pick(en: 'Radius', zhTW: '圓角'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: preset.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  activeTrackColor: preset.accent,
                                  inactiveTrackColor: preset.textSecondary
                                      .withValues(alpha: 0.15),
                                  thumbColor: preset.accent,
                                  overlayColor: preset.accent.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                                child: Slider(
                                  value: _bubbleRadius,
                                  min: 2,
                                  max: 32,
                                  onChanged: (v) {
                                    setState(() => _bubbleRadius = v);
                                    YanciTheme.bubbleRadius = v;
                                    ThemeSettings.saveBubbleRadius(v);
                                    _notifyThemeChanged();
                                  },
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${_bubbleRadius.round()}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: preset.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // 亮度
                        Row(
                          children: [
                            SizedBox(
                              width: 56,
                              child: Text(
                                L.pick(en: 'Bright', zhTW: '亮度'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: preset.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  activeTrackColor: preset.accent,
                                  inactiveTrackColor: preset.textSecondary
                                      .withValues(alpha: 0.15),
                                  thumbColor: preset.accent,
                                  overlayColor: preset.accent.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                                child: Slider(
                                  value: _bubbleBrightness,
                                  min: -0.3,
                                  max: 0.3,
                                  onChanged: (v) {
                                    setState(() => _bubbleBrightness = v);
                                    YanciTheme.bubbleBrightness = v;
                                    ThemeSettings.saveBubbleBrightness(v);
                                    _notifyThemeChanged();
                                  },
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${(_bubbleBrightness * 100).round()}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: preset.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    crossFadeState: _bubbleMoreExpanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 200),
                  ),
                ],
              ),
            ),
            crossFadeState: _tuningExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _bubbleColorRow({
    required String label,
    required Color color,
    required ThemeBubbleColorRole role,
    required ThemePreset preset,
    bool isTextColor = false,
  }) {
    final hasOverride =
        YanciTheme.bubbleColorOverride(_selectedId, role) != null;
    return GestureDetector(
      key: ValueKey('theme-bubble-${role.name}-row'),
      onTap: () {
        final entry = _ColorEntry(label, color, role.name);
        _showColorPicker(
          entry,
          setState,
          onApplied: (c) async {
            await ThemeSettings.saveThemeBubbleColor(_selectedId, role, c);
            if (!mounted) return;
            setState(() {});
            _notifyThemeChanged();
          },
          presetColors: [
            switch (role) {
              ThemeBubbleColorRole.aiBubble => preset.aiBubble,
              ThemeBubbleColorRole.userBubble => preset.userBubble,
              ThemeBubbleColorRole.textOnBubble => preset.textOnBubble,
            },
            preset.accent,
            Colors.white,
            Colors.black,
          ],
        );
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            // 色塊 chip
            Container(
              width: isTextColor ? 28 : 24,
              height: isTextColor ? 18 : 18,
              decoration: BoxDecoration(
                color: isTextColor
                    ? Colors.transparent
                    : color.withValues(alpha: _bubbleOpacity),
                borderRadius: BorderRadius.circular(
                  isTextColor ? 4 : _bubbleRadius.clamp(4.0, 9.0),
                ),
                border: Border.all(
                  color: isTextColor
                      ? color.withValues(alpha: 0.5)
                      : color.withValues(alpha: 0.3),
                  width: 0.8,
                ),
              ),
              alignment: Alignment.center,
              child: isTextColor
                  ? Text(
                      'Aa',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: preset.textSecondary.withValues(alpha: 0.8),
              ),
            ),
            const Spacer(),
            if (hasOverride)
              IconButton(
                key: ValueKey('theme-bubble-${role.name}-reset'),
                tooltip: L.pick(
                  en: 'Reset to theme default',
                  zhTW: '重置為目前主題預設',
                ),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: () async {
                  await ThemeSettings.saveThemeBubbleColor(
                    _selectedId,
                    role,
                    null,
                  );
                  if (!mounted) return;
                  setState(() {});
                  _notifyThemeChanged();
                },
                icon: Icon(
                  Icons.restart_alt_rounded,
                  size: 17,
                  color: preset.textSecondary.withValues(alpha: 0.55),
                ),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: preset.textSecondary.withValues(alpha: 0.3),
              ),
          ],
        ),
      ),
    );
  }

  // ═══ 粒子特效區 ═══
  Widget _buildParticleSection() {
    final preset = presets.firstWhere(
      (p) => p.id == _selectedId,
      orElse: () => presets.first,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 18,
                  color: preset.textSecondary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 8),
                Text(
                  L.pick(en: 'Particles', zhTW: '粒子特效'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: preset.textPrimary,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 24,
                  child: Switch(
                    value: _starEnabled,
                    activeThumbColor: preset.accent,
                    onChanged: (v) {
                      setState(() => _starEnabled = v);
                      YanciTheme.starEnabled = v;
                      ThemeSettings.saveStarEnabled(v);
                      _notifyThemeChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
          // 密度 slider (只在啟用時顯示)
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      L.pick(en: 'Density', zhTW: '密度'),
                      style: TextStyle(
                        fontSize: 11,
                        color: preset.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        activeTrackColor: preset.accent,
                        inactiveTrackColor: preset.textSecondary.withValues(
                          alpha: 0.15,
                        ),
                        thumbColor: preset.accent,
                        overlayColor: preset.accent.withValues(alpha: 0.12),
                      ),
                      child: Slider(
                        value: _starDensity.toDouble(),
                        min: 1,
                        max: 50,
                        divisions: 49,
                        onChanged: (v) {
                          setState(() => _starDensity = v.round());
                          YanciTheme.starDensity = v.round();
                          ThemeSettings.saveStarDensity(v.round());
                          _notifyThemeChanged();
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '$_starDensity',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 10,
                        color: preset.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            crossFadeState: _starEnabled
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
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
    final r = _bubbleRadius.clamp(6.0, 32.0);
    return Container(
      height: 200,
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
          // AI 氣泡（左上）+ 顏表情預覽字體色
          Positioned(
            top: 24,
            left: 20,
            child: Container(
              key: const ValueKey('theme-hero-ai-bubble'),
              padding: EdgeInsets.symmetric(
                horizontal: _aiBubbleFlat ? 4 : 14,
                vertical: _aiBubbleFlat ? 4 : 6,
              ),
              constraints: const BoxConstraints(minWidth: 80),
              decoration: _aiBubbleFlat
                  ? null
                  : BoxDecoration(
                      color: YanciTheme.aiBubble,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(r * 0.5),
                        topRight: Radius.circular(r * 0.5),
                        bottomLeft: const Radius.circular(4),
                        bottomRight: Radius.circular(r * 0.5),
                      ),
                      border: Border.all(
                        color: preset.aiBubbleBorder.withValues(alpha: 0.5),
                        width: 0.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
              child: Text(
                '(\u00b4\u30fb\u1d17\u30fb\uff40)',
                key: const ValueKey('theme-hero-ai-text'),
                style: TextStyle(
                  fontSize: 11,
                  color: YanciTheme.textOnBubble,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ),
          ),
          // 用戶氣泡（右下）+ 顏表情預覽字體色
          Positioned(
            top: 72,
            right: 20,
            child: Container(
              key: const ValueKey('theme-hero-user-bubble'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              constraints: const BoxConstraints(minWidth: 64),
              decoration: BoxDecoration(
                color: YanciTheme.userBubble,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(r * 0.5),
                  topRight: Radius.circular(r * 0.5),
                  bottomLeft: Radius.circular(r * 0.5),
                  bottomRight: const Radius.circular(4),
                ),
                border: Border.all(
                  color: preset.userBubbleBorder.withValues(alpha: 0.5),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                '( ˘ᵕ˘ )',
                key: const ValueKey('theme-hero-user-text'),
                style: TextStyle(
                  fontSize: 11,
                  color: YanciTheme.textOnBubble,
                  fontFamily: YanciTheme.fontFamily,
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
                  L.get('theme_subtitle_${preset.id}'),
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
    ValueChanged<Color>? onApplied,
    List<Color>? presetColors,
  }) {
    var hsl = HSLColor.fromColor(entry.color);
    var previewColor = entry.color;
    var hexValid = true;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setPickerState) {
          void updateColor() {
            previewColor = hsl.toColor();
            hexValid = true;
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

                  if (presetColors != null) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: presetColors
                          .map(
                            (color) => InkWell(
                              onTap: () {
                                hsl = HSLColor.fromColor(color);
                                updateColor();
                              },
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.25,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                  ],

                  _HexColorInput(
                    color: previewColor,
                    valid: hexValid,
                    onChanged: (value) {
                      final normalized = value.replaceAll('#', '').trim();
                      final parsed = normalized.length == 6
                          ? int.tryParse(normalized, radix: 16)
                          : null;
                      setPickerState(() {
                        hexValid = parsed != null;
                        if (parsed != null) {
                          previewColor = Color(0xFF000000 | parsed);
                          hsl = HSLColor.fromColor(previewColor);
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),

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
                key: const ValueKey('theme-color-apply'),
                onPressed: hexValid
                    ? () {
                        final color = previewColor;
                        // 加入歷史（去重，最多 8 個）
                        _colorHistory.removeWhere(
                          (c) => _colorToHex(c) == _colorToHex(color),
                        );
                        _colorHistory.insert(0, color);
                        if (_colorHistory.length > 8) {
                          _colorHistory.removeLast();
                        }
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
                        onApplied?.call(color);
                      }
                    : null,
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

enum _ChatBackgroundColorRole { aiBubble, userBubble, bubbleText, thinkingText }

class _AlternatingDoubleChevronHint extends StatefulWidget {
  const _AlternatingDoubleChevronHint({required this.color});

  final Color color;

  @override
  State<_AlternatingDoubleChevronHint> createState() =>
      _AlternatingDoubleChevronHintState();
}

class _AlternatingDoubleChevronHintState
    extends State<_AlternatingDoubleChevronHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _controller.stop();
    } else if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          key: const ValueKey('chat-background-more-content-hint'),
          child: SizedBox(
            width: 24,
            height: 25,
            child: reduceMotion
                ? _buildChevrons(topOpacity: 0.5, bottomOpacity: 0.5)
                : AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      if (_controller.isCompleted) {
                        return _buildChevrons(
                          topOpacity: 0.5,
                          bottomOpacity: 0.5,
                        );
                      }
                      final position = _controller.value;
                      final pulse = position <= 0.5
                          ? position * 2
                          : (1 - position) * 2;
                      return _buildChevrons(
                        topOpacity: 0.22 + pulse * 0.58,
                        bottomOpacity: 0.8 - pulse * 0.58,
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildChevrons({
    required double topOpacity,
    required double bottomOpacity,
  }) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Opacity(
          opacity: topOpacity,
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 19,
            color: widget.color,
          ),
        ),
        Positioned(
          top: 8,
          child: Opacity(
            opacity: bottomOpacity,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 19,
              color: widget.color,
            ),
          ),
        ),
      ],
    );
  }
}

class _HexColorInput extends StatefulWidget {
  const _HexColorInput({
    required this.color,
    required this.valid,
    required this.onChanged,
  });

  final Color color;
  final bool valid;
  final ValueChanged<String> onChanged;

  @override
  State<_HexColorInput> createState() => _HexColorInputState();
}

class _HexColorInputState extends State<_HexColorInput> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _textFor(widget.color));
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _HexColorInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color && !_focusNode.hasFocus) {
      final text = _textFor(widget.color);
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _textFor(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('theme-color-hex-input'),
      controller: _controller,
      focusNode: _focusNode,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: 'HEX',
        hintText: '#RRGGBB',
        errorText: widget.valid
            ? null
            : L.pick(
                en: 'Enter a 6-digit HEX color',
                zhTW: '請輸入 6 位 HEX 色碼',
                zhCN: '请输入 6 位 HEX 色码',
              ),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ColorEntry {
  final String label;
  Color color;
  final String key;
  bool selected;

  _ColorEntry(this.label, this.color, this.key) : selected = false;
}
