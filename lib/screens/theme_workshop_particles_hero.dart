// ignore_for_file: invalid_use_of_protected_member

part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopParticleHeroMethods on _ThemeWorkshopScreenState {
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
                Transform.scale(
                  scale: 0.78,
                  alignment: Alignment.centerRight,
                  child: Switch.adaptive(
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
          // 樣式 tabs 與密度 slider（只在啟用時顯示）
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4, top: 2),
              child: Column(
                children: [
                  _buildParticleEffectTabs(preset),
                  const SizedBox(height: 6),
                  Row(
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
                              YanciTheme.setStarDensity(v.round());
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

  Widget _buildParticleEffectTabs(ThemePreset preset) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const effects = <_ParticleEffectOption>[
      _ParticleEffectOption('neural', 'Neural', '神經網路', '神经网络'),
      _ParticleEffectOption('fog', 'Mist', '霧氣', '雾气'),
      _ParticleEffectOption('rain', 'Rain', '雨絲', '雨丝'),
      _ParticleEffectOption('ripple', 'Ripples', '偶發漣漪', '偶发涟漪'),
      _ParticleEffectOption('ember', 'Embers', '逆流餘燼', '逆流余烬'),
      _ParticleEffectOption('dandelion', 'Dandelion', '蒲公英絨', '蒲公英绒'),
    ];

    Widget buildTab(_ParticleEffectOption option) {
      final selected = option.id == _particleEffect;
      final label = L.pick(en: option.en, zhTW: option.zhTW, zhCN: option.zhCN);
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          key: ValueKey('particle-effect-${option.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (selected) return;
            setState(() => _particleEffect = option.id);
            YanciTheme.setParticleEffect(option.id);
            ThemeSettings.saveParticleEffect(option.id);
            _notifyThemeChanged();
          },
          child: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            height: 44,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: selected
                  ? preset.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border(
                bottom: BorderSide(
                  color: selected ? preset.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? preset.accent
                    : preset.textSecondary.withValues(alpha: 0.78),
              ),
            ),
          ),
        ),
      );
    }

    Widget buildRow(Iterable<_ParticleEffectOption> rowEffects) {
      return Row(
        children: rowEffects
            .map(
              (option) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: buildTab(option),
                ),
              ),
            )
            .toList(growable: false),
      );
    }

    return Semantics(
      container: true,
      label: L.pick(en: 'Particle style', zhTW: '粒子特效樣式', zhCN: '粒子特效样式'),
      child: Column(
        key: const ValueKey('particle-effect-tabs'),
        children: [
          buildRow(effects.take(3)),
          const SizedBox(height: 4),
          buildRow(effects.skip(3)),
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
                      borderRadius: BorderRadius.circular(r * 0.5),
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
                borderRadius: BorderRadius.circular(r * 0.5),
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
}
