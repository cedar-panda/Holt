part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopColorPickerMethods on _ThemeWorkshopScreenState {
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
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withValues(alpha: 0.26),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel,
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
    YanciTheme.setStarDensity(_starDensity);
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
