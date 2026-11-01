// ignore_for_file: invalid_use_of_protected_member

part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopBackgroundLogic on _ThemeWorkshopScreenState {
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
    _callBackgroundScope = preset.callBackgroundScope;
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
    callBackgroundScope: _callBackgroundScope,
  );

  Future<void> _setCallBackgroundScope(
    String scope,
    StateSetter setPageState,
  ) async {
    final next = _callBackgroundScope == scope ? 'none' : scope;
    setPageState(() => _callBackgroundScope = next);
    await _persistCurrentBackgroundPreset();
    _notifyThemeChanged();
  }

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
    _ChatBackgroundColorRole.aiBubble => _resolvedChatBackgroundBubbleColor(
      manual: _chatBgAiBubbleColor,
      themeOverride: YanciTheme.bubbleColorOverride(
        YanciTheme.presetId,
        ThemeBubbleColorRole.aiBubble,
      ),
      automatic: BackgroundForegroundService.cachedChatBubblePalette(
        _chatBgPath,
      )?.aiBubble,
      fallback: YanciTheme.aiBubble,
    ),
    _ChatBackgroundColorRole.userBubble => _resolvedChatBackgroundBubbleColor(
      manual: _chatBgUserBubbleColor,
      themeOverride: YanciTheme.bubbleColorOverride(
        YanciTheme.presetId,
        ThemeBubbleColorRole.userBubble,
      ),
      automatic: BackgroundForegroundService.cachedChatBubblePalette(
        _chatBgPath,
      )?.userBubble,
      fallback: YanciTheme.userBubble,
    ),
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

  Color _resolvedChatBackgroundBubbleColor({
    required Color? manual,
    required Color? themeOverride,
    required Color? automatic,
    required Color fallback,
  }) {
    final custom = manual ?? themeOverride ?? automatic;
    return (custom == null
            ? fallback
            : YanciTheme.applyBubbleBrightness(custom))
        .withValues(alpha: _chatBackgroundBubbleOpacity);
  }

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
}
