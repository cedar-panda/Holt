// ignore_for_file: invalid_use_of_protected_member

part of 'theme_workshop_screen.dart';

const _particleEffectOptions = <_ParticleEffectOption>[
  _ParticleEffectOption('neural', 'Neural', '神經網路', '神经网络'),
  _ParticleEffectOption('rain', 'Rain', '雨絲', '雨丝'),
  _ParticleEffectOption('ripple', 'Ripples', '偶發漣漪', '偶发涟漪'),
  _ParticleEffectOption('ember', 'Embers', '逆流餘燼', '逆流余烬'),
  _ParticleEffectOption('dandelion', 'Petals', '飛花', '飞花'),
  _ParticleEffectOption('gold', 'Gold', '金粉', '金粉'),
  _ParticleEffectOption('spark', 'Sparks', '電火花', '电火花'),
  _ParticleEffectOption('sky', 'Sky', '雲朵日月', '云朵日月'),
  _ParticleEffectOption('firework', 'Fireworks', '煙花', '烟花'),
  _ParticleEffectOption('emoji', 'Emoji', 'emoji 雨', 'emoji 雨'),
];

/// 一排三個，照 [_particleEffectOptions] 的順序排，名字才不會擠在一起。
const _particleEffectsPerRow = 3;

/// 粒子樣式按鍵的選中動畫時長；換粒子排在它跑完之後。
const _particleTabAnimation = Duration(milliseconds: 180);

extension _ThemeWorkshopParticleHeroMethods on _ThemeWorkshopScreenState {
  // ═══ 粒子特效區 ═══
  Widget _buildParticleSection() {
    final preset = presets.firstWhere(
      (p) => p.id == _selectedId,
      orElse: () => presets.first,
    );
    final selectedEffect = _particleEffectOptions.firstWhere(
      (option) => option.id == _particleEffect,
      orElse: () => _particleEffectOptions.first,
    );
    final selectedEffectLabel = L.pick(
      en: selectedEffect.en,
      zhTW: selectedEffect.zhTW,
      zhCN: selectedEffect.zhCN,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusCard),
        border: Border.all(
          color: preset.accent.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  expanded: _particleExpanded,
                  label: L.pick(en: 'Particles', zhTW: '粒子特效'),
                  child: InkWell(
                    key: const ValueKey('theme-particle-section-toggle'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () =>
                        setState(() => _particleExpanded = !_particleExpanded),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
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
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              selectedEffectLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: preset.textSecondary.withValues(
                                  alpha: 0.58,
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          AnimatedRotation(
                            turns: _particleExpanded ? 0.5 : 0,
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 20,
                              color: preset.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.78,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: _starEnabled,
                  activeThumbColor: preset.accent,
                  onChanged: (v) {
                    setState(() {
                      _starEnabled = v;
                      if (v) _particleExpanded = true;
                    });
                    YanciTheme.starEnabled = v;
                    ThemeSettings.saveStarEnabled(v);
                    _notifyThemeChanged();
                  },
                ),
              ),
            ],
          ),
          // 樣式 tabs 與密度 slider（只在啟用時顯示）
          AnimatedCrossFade(
            key: const ValueKey('theme-particle-section-content'),
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 8, right: 4, top: 2),
              child: Column(
                children: [
                  _buildParticleEffectTabs(preset),
                  if (_particleEffect == 'emoji') _buildParticleEmojiField(preset),
                  if (_particleEffect == 'sky') _buildCloudStyleField(preset),
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
                            // 拖動時只動數字；放手才重建粒子層，
                            // 不然每一格都重建粒子＋整個 App，拖起來會卡。
                            onChanged: (v) =>
                                setState(() => _starDensity = v.round()),
                            onChangeEnd: (v) {
                              YanciTheme.setStarDensity(v.round());
                              ThemeSettings.saveStarDensity(v.round());
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
            crossFadeState: _starEnabled && _particleExpanded
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
            ThemeSettings.saveParticleEffect(option.id);
            // 換粒子要重建粒子層、烘圖（雲、emoji），跟按鍵動畫擠在同一幀
            // 就會卡。先讓按鍵動畫跑完，再換粒子。粒子層只聽
            // particleRevision，不需要重建整個 App 的主題。
            _particleSwapTimer?.cancel();
            _particleSwapTimer = Timer(
              reduceMotion ? Duration.zero : _particleTabAnimation,
              () {
                if (!mounted) return;
                YanciTheme.setParticleEffect(option.id);
              },
            );
          },
          child: AnimatedContainer(
            duration: reduceMotion ? Duration.zero : _particleTabAnimation,
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
                fontSize: 12.5,
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

    Widget buildRow(List<_ParticleEffectOption> rowEffects) {
      return Row(
        children: [
          for (var i = 0; i < _particleEffectsPerRow; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                // 最後一排不滿三個時留空位，寬度與上面對齊。
                child: i < rowEffects.length
                    ? buildTab(rowEffects[i])
                    : const SizedBox.shrink(),
              ),
            ),
        ],
      );
    }

    final rows = <List<_ParticleEffectOption>>[
      for (
        var start = 0;
        start < _particleEffectOptions.length;
        start += _particleEffectsPerRow
      )
        _particleEffectOptions.sublist(
          start,
          start + _particleEffectsPerRow < _particleEffectOptions.length
              ? start + _particleEffectsPerRow
              : _particleEffectOptions.length,
        ),
    ];

    return Semantics(
      container: true,
      label: L.pick(en: 'Particle style', zhTW: '粒子特效樣式', zhCN: '粒子特效样式'),
      child: Column(
        key: const ValueKey('particle-effect-tabs'),
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) const SizedBox(height: 4),
            buildRow(row),
          ],
        ],
      ),
    );
  }

  /// 雲朵日月專屬：柔邊漸層雲 / 硬邊卡通雲。只動粒子層，不重建整個 App。
  Widget _buildCloudStyleField(ThemePreset preset) {
    Widget option(String id, String label) {
      final selected = _cloudStyle == id;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Semantics(
            button: true,
            selected: selected,
            label: label,
            child: InkWell(
              key: ValueKey('cloud-style-$id'),
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                if (selected) return;
                setState(() => _cloudStyle = id);
                YanciTheme.setCloudStyle(id);
                ThemeSettings.saveCloudStyle(id);
              },
              child: Container(
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? preset.accent.withValues(alpha: 0.10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? preset.accent
                        : preset.accent.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? preset.accent
                        : preset.textSecondary.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              L.pick(en: 'Clouds', zhTW: '雲朵', zhCN: '云朵'),
              style: TextStyle(
                fontSize: 11,
                color: preset.textSecondary.withValues(alpha: 0.7),
              ),
            ),
          ),
          option('soft', L.pick(en: 'Soft', zhTW: '柔邊', zhCN: '柔边')),
          option('hard', L.pick(en: 'Crisp', zhTW: '硬邊', zhCN: '硬边')),
        ],
      ),
    );
  }

  /// emoji 雨：自選最多 5 種，打字即時套用並保存。
  Widget _buildParticleEmojiField(ThemePreset preset) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              L.pick(en: 'Emoji', zhTW: 'emoji', zhCN: 'emoji'),
              style: TextStyle(
                fontSize: 11,
                color: preset.textSecondary.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              key: const ValueKey('particle-emoji-field'),
              controller: _particleEmojiController,
              style: TextStyle(fontSize: 18, color: preset.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: L.pick(
                  en: 'Up to 5',
                  zhTW: '最多 5 種',
                  zhCN: '最多 5 种',
                ),
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: preset.textSecondary.withValues(alpha: 0.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: preset.accent.withValues(alpha: 0.25),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: preset.accent.withValues(alpha: 0.25),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: preset.accent),
                ),
              ),
              onChanged: (value) {
                final emojis = YanciTheme.normalizeParticleEmojis(value);
                if (emojis.isEmpty) return; // 清空時先不動，保留上一組
                // 只動粒子層（particleRevision），不觸發整個 App 的主題重建。
                YanciTheme.setParticleEmojis(emojis);
                ThemeSettings.saveParticleEmojis(emojis);
              },
              onSubmitted: (_) {
                // 送出時把輸入框整理成實際生效的那幾個（去重、最多 5 個）。
                final text = YanciTheme.particleEmojis.join();
                _particleEmojiController.value = TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length),
                );
              },
            ),
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
                      gradient: YanciTheme.bubbleGlazeGradient(
                        YanciTheme.aiBubble,
                        isDark: preset.isDark,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: YanciTheme.bubbleGlazeBorderColor(
                          preset.aiBubbleBorder,
                          isDark: preset.isDark,
                        ),
                        width: 0.65,
                      ),
                      boxShadow: YanciTheme.bubbleGlazeShadows(
                        isDark: preset.isDark,
                      ),
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
                gradient: YanciTheme.bubbleGlazeGradient(
                  YanciTheme.userBubble,
                  isDark: preset.isDark,
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: YanciTheme.bubbleGlazeBorderColor(
                    preset.userBubbleBorder,
                    isDark: preset.isDark,
                  ),
                  width: 0.65,
                ),
                boxShadow: YanciTheme.bubbleGlazeShadows(isDark: preset.isDark),
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
