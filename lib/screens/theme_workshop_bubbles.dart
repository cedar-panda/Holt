// ignore_for_file: invalid_use_of_protected_member

part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopBubbleMethods on _ThemeWorkshopScreenState {
  Widget _buildBackgroundMenuButton() {
    final label = L.pick(en: 'Custom Background', zhTW: '自訂背景', zhCN: '自定义背景');
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          key: const ValueKey('theme-image-background-entry'),
          behavior: HitTestBehavior.opaque,
          onTap: _openBackgroundPage,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Icon(Icons.image_outlined, size: 18, color: YanciTheme.accent),
                const SizedBox(width: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: YanciTheme.accent,
                  ),
                ),
                const Spacer(),
                if (_homeBgPath.isNotEmpty || _chatBgPath.isNotEmpty) ...[
                  Text(
                    L.pick(en: 'Set', zhTW: '已設定', zhCN: '已设置'),
                    style: TextStyle(
                      fontSize: 10.5,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.52),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
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
    );
  }

  Widget _buildBackgroundEntryCard(ThemePreset preset) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusCard),
        border: Border.all(
          color: preset.accent.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: _buildBackgroundMenuButton(),
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
                    onTap: () => unawaited(_setAiBubbleFlat(false)),
                  ),
                  _aiBubbleStyleItem(
                    preset: preset,
                    label: L.pick(en: 'Flat', zhTW: '平鋪'),
                    selected: _aiBubbleFlat,
                    onTap: () => unawaited(_setAiBubbleFlat(true)),
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

  Future<void> _setAiBubbleFlat(bool flat) async {
    setState(() => _aiBubbleFlat = flat);
    YanciTheme.aiBubbleFlat = flat;
    await ThemeSettings.saveAiBubbleFlat(flat);
    if (flat && await MemorySettings.getSplitReply()) {
      await MemorySettings.saveSplitReply(false);
      if (mounted) {
        showThemedPillNotice(
          context,
          L.pick(
            en: 'Multi-bubble reply turned off in flat mode',
            zhTW: '平鋪模式下已自動關閉多氣泡回覆',
            zhCN: '平铺模式下已自动关闭多气泡回复',
          ),
        );
      }
    }
    _notifyThemeChanged();
  }

  Future<void> _selectSendButtonStyle(SendButtonStyle style) async {
    if (style == SendButtonStyle.custom) {
      await _pickCustomSendButton();
      return;
    }
    final oldCustomPath = _sendButtonCustomPath;
    setState(() {
      _sendButtonStyle = style;
      _sendButtonCustomPath = '';
    });
    YanciTheme.sendButtonStyle = style.name;
    YanciTheme.sendButtonCustomPath = '';
    await ThemeSettings.saveSendButtonStyle(style.name);
    await ThemeSettings.saveSendButtonCustomPath('');
    _notifyThemeChanged();
    await ImageService.deleteSendButtonFile(oldCustomPath);
  }

  Future<void> _pickCustomSendButton() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final validation = await ImageService.validateSendButtonPng(picked.path);
    if (validation != SendButtonImageValidation.valid) {
      if (!mounted) return;
      final message = switch (validation) {
        SendButtonImageValidation.notSquare => L.get(
          'theme_send_button_square_error',
        ),
        SendButtonImageValidation.noTransparentBackground => L.get(
          'theme_send_button_transparent_error',
        ),
        SendButtonImageValidation.notWhiteLineArt => L.get(
          'theme_send_button_white_line_error',
        ),
        _ => L.get('theme_send_button_png_error'),
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    final oldCustomPath = _sendButtonCustomPath;
    try {
      final saved = await ImageService.copySendButtonToAppDir(picked.path);
      if (!mounted) {
        await ImageService.deleteSendButtonFile(saved);
        return;
      }
      setState(() {
        _sendButtonStyle = SendButtonStyle.custom;
        _sendButtonCustomPath = saved;
      });
      YanciTheme.sendButtonStyle = SendButtonStyle.custom.name;
      YanciTheme.sendButtonCustomPath = saved;
      await ThemeSettings.saveSendButtonCustomPath(saved);
      await ThemeSettings.saveSendButtonStyle(SendButtonStyle.custom.name);
      _notifyThemeChanged();
      if (oldCustomPath != saved) {
        await ImageService.deleteSendButtonFile(oldCustomPath);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.get('theme_send_button_import_error'))),
      );
    }
  }

  Widget _sendButtonPreview(SendButtonStyle style, ThemePreset preset) {
    Widget image;
    switch (style) {
      case SendButtonStyle.leaf:
        image = ColorFiltered(
          colorFilter: ColorFilter.mode(preset.accent, BlendMode.modulate),
          child: Image.asset(
            'assets/images/send_maple_leaf.png',
            width: 26,
            height: 26,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
          ),
        );
        break;
      case SendButtonStyle.paw:
        image = ColorFiltered(
          colorFilter: ColorFilter.mode(preset.accent, BlendMode.modulate),
          child: Image.asset(
            'assets/images/send_paw.png',
            width: 26,
            height: 26,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
          ),
        );
        break;
      case SendButtonStyle.shell:
        image = ColorFiltered(
          colorFilter: ColorFilter.mode(preset.accent, BlendMode.modulate),
          child: Image.asset(
            'assets/images/send_paper_boat.png',
            width: 26,
            height: 26,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
          ),
        );
        break;
      case SendButtonStyle.custom:
        final custom = File(_sendButtonCustomPath);
        image = _sendButtonCustomPath.isNotEmpty && custom.existsSync()
            ? ColorFiltered(
                colorFilter: ColorFilter.mode(
                  preset.accent,
                  BlendMode.modulate,
                ),
                child: Image.file(
                  custom,
                  width: 26,
                  height: 26,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 24,
                    color: preset.accent,
                  ),
                ),
              )
            : Icon(
                Icons.add_photo_alternate_outlined,
                size: 24,
                color: preset.accent,
              );
        break;
    }
    return image;
  }

  Widget _buildSendButtonStyleRow(ThemePreset preset) {
    final labels = <SendButtonStyle, String>{
      SendButtonStyle.leaf: L.get('theme_send_button_leaf'),
      SendButtonStyle.paw: L.get('theme_send_button_paw'),
      SendButtonStyle.shell: L.get('theme_send_button_shell'),
      SendButtonStyle.custom: L.get('theme_send_button_custom'),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.send_rounded,
                size: 18,
                color: preset.textSecondary.withValues(alpha: 0.70),
              ),
              const SizedBox(width: 8),
              Text(
                L.get('theme_send_button'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: preset.textPrimary,
                ),
              ),
              const Spacer(),
              for (final style in SendButtonStyle.values) ...[
                Tooltip(
                  message: labels[style]!,
                  child: Semantics(
                    button: true,
                    selected: _sendButtonStyle == style,
                    label: labels[style],
                    child: GestureDetector(
                      key: ValueKey('theme-send-button-${style.name}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _selectSendButtonStyle(style),
                      onLongPress: style == SendButtonStyle.custom
                          ? _pickCustomSendButton
                          : null,
                      // The visible tile is 38×38, while the transparent outer
                      // box keeps a platform-safe 44×44 touch target.
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: _sendButtonStyle == style
                                  ? preset.accent.withValues(alpha: 0.10)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _sendButtonStyle == style
                                    ? preset.accent.withValues(alpha: 0.76)
                                    : preset.textSecondary.withValues(
                                        alpha: 0.16,
                                      ),
                                width: _sendButtonStyle == style ? 1.2 : 0.7,
                              ),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                _sendButtonPreview(style, preset),
                                if (style == SendButtonStyle.custom &&
                                    _sendButtonCustomPath.isNotEmpty)
                                  Positioned(
                                    right: 1,
                                    bottom: 1,
                                    child: Icon(
                                      Icons.refresh_rounded,
                                      size: 10,
                                      color: preset.accent,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_sendButtonStyle == SendButtonStyle.custom) ...[
            const SizedBox(height: 5),
            Align(
              alignment: Alignment.centerRight,
              child: Tooltip(
                message: L.get('theme_send_button_custom_hint'),
                triggerMode: TooltipTriggerMode.tap,
                child: Semantics(
                  button: true,
                  label: L.get('theme_send_button_custom_hint'),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.help_outline_rounded,
                      size: 17,
                      color: preset.textSecondary.withValues(alpha: .72),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ═══ 氣泡設定區 ═══
  Widget _buildBubbleSection(ThemePreset preset) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusCard),
        border: Border.all(
          color: preset.accent.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
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

          _buildSendButtonStyleRow(preset),

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
                  Row(
                    children: [
                      Expanded(
                        child: _bubbleColorRow(
                          label: L.pick(en: 'AI', zhTW: 'AI 氣泡', zhCN: 'AI 气泡'),
                          color: YanciTheme.aiBubble,
                          role: ThemeBubbleColorRole.aiBubble,
                          preset: preset,
                          isTextColor: false,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _bubbleColorRow(
                          label: L.pick(en: 'Mine', zhTW: '我的氣泡', zhCN: '我的气泡'),
                          color: YanciTheme.userBubble,
                          role: ThemeBubbleColorRole.userBubble,
                          preset: preset,
                          isTextColor: false,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _bubbleColorRow(
                          label: L.pick(en: 'Text', zhTW: '字體', zhCN: '字体'),
                          color: YanciTheme.textOnBubble,
                          role: ThemeBubbleColorRole.textOnBubble,
                          preset: preset,
                          isTextColor: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _bubbleSlider(
                    label: L.pick(en: 'Opacity', zhTW: '透明度', zhCN: '透明度'),
                    value: _bubbleOpacity,
                    min: 0.1,
                    max: 1.0,
                    displayValue: '${(_bubbleOpacity * 100).round()}',
                    preset: preset,
                    onChanged: (v) {
                      setState(() => _bubbleOpacity = v);
                      YanciTheme.bubbleOpacity = v;
                      ThemeSettings.saveBubbleOpacity(v);
                      _notifyThemeChanged();
                    },
                  ),
                  _bubbleSlider(
                    label: L.pick(en: 'Radius', zhTW: '圓角', zhCN: '圆角'),
                    value: _bubbleRadius,
                    min: 2,
                    max: 32,
                    displayValue: '${_bubbleRadius.round()}',
                    preset: preset,
                    onChanged: (v) {
                      setState(() => _bubbleRadius = v);
                      YanciTheme.bubbleRadius = v;
                      ThemeSettings.saveBubbleRadius(v);
                      _notifyThemeChanged();
                    },
                  ),
                  _bubbleSlider(
                    label: L.pick(en: 'Bright', zhTW: '亮度', zhCN: '亮度'),
                    value: _bubbleBrightness,
                    min: -0.3,
                    max: 0.3,
                    displayValue: '${(_bubbleBrightness * 100).round()}',
                    preset: preset,
                    onChanged: (v) {
                      setState(() => _bubbleBrightness = v);
                      YanciTheme.bubbleBrightness = v;
                      ThemeSettings.saveBubbleBrightness(v);
                      _notifyThemeChanged();
                    },
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

  Widget _bubbleSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ThemePreset preset,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
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
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: preset.accent,
              inactiveTrackColor: preset.textSecondary.withValues(alpha: 0.15),
              thumbColor: preset.accent,
              overlayColor: preset.accent.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            displayValue,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 10,
              color: preset.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
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
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.only(left: 7, right: 3),
        decoration: BoxDecoration(
          color: preset.accent.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: preset.textSecondary.withValues(alpha: 0.12),
            width: 0.6,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: isTextColor ? 22 : 19,
              height: 16,
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
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: preset.textSecondary.withValues(alpha: 0.8),
                ),
              ),
            ),
            if (hasOverride)
              IconButton(
                key: ValueKey('theme-bubble-${role.name}-reset'),
                tooltip: L.pick(
                  en: 'Reset to theme default',
                  zhTW: '重置為目前主題預設',
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 44),
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
                  size: 15,
                  color: preset.textSecondary.withValues(alpha: 0.55),
                ),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: preset.textSecondary.withValues(alpha: 0.3),
              ),
          ],
        ),
      ),
    );
  }
}
