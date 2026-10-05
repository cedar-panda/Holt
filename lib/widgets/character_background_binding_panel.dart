import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/background_preset.dart';
import '../services/background_preset_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class CharacterBackgroundBindingPanel extends StatefulWidget {
  final String characterId;

  const CharacterBackgroundBindingPanel({super.key, required this.characterId});

  @override
  State<CharacterBackgroundBindingPanel> createState() =>
      _CharacterBackgroundBindingPanelState();
}

class _CharacterBackgroundBindingPanelState
    extends State<CharacterBackgroundBindingPanel> {
  bool _expanded = false;
  bool _loading = true;
  int? _selectedSlot;
  List<BackgroundPreset> _presets = const <BackgroundPreset>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CharacterBackgroundBindingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId) {
      _expanded = false;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      BackgroundPresetService.loadAll(),
      BackgroundPresetService.getCharacterBinding(widget.characterId),
    ]);
    if (!mounted) return;
    setState(() {
      _presets = results[0] as List<BackgroundPreset>;
      _selectedSlot = results[1] as int?;
      _loading = false;
    });
  }

  Future<void> _bind(int? slot) async {
    HapticFeedback.selectionClick();
    await BackgroundPresetService.setCharacterBinding(widget.characterId, slot);
    if (!mounted) return;
    setState(() => _selectedSlot = slot);
  }

  @override
  Widget build(BuildContext context) {
    final selectedLabel = _selectedSlot == null
        ? L.pick(
            en: 'Follows the active Theme Studio set',
            zhTW: '跟隨主題工坊目前套組',
            zhCN: '跟随主题工坊目前套组',
          )
        : L.pick(
            en: 'Set $_selectedSlot',
            zhTW: '已綁定第 $_selectedSlot 套',
            zhCN: '已绑定第 $_selectedSlot 套',
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: YanciTheme.textSecondary.withValues(alpha: 0.18),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Semantics(
              button: true,
              expanded: _expanded,
              label: L.pick(
                en: 'Default chat background binding',
                zhTW: '窗口背景預設綁定',
                zhCN: '窗口背景预设绑定',
              ),
              child: InkWell(
                key: const ValueKey('character-background-binding-toggle'),
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 58),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                L.pick(
                                  en: 'Default chat background binding',
                                  zhTW: '窗口背景預設綁定',
                                  zhCN: '窗口背景预设绑定',
                                ),
                                style: TextStyle(
                                  color: YanciTheme.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                selectedLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.72,
                                  ),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.58,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
                child: _loading
                    ? const SizedBox(
                        height: 104,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final preset in _presets)
                                  _presetPreview(preset),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: const ValueKey(
                                'character-background-follow-active',
                              ),
                              onPressed: _selectedSlot == null
                                  ? null
                                  : () => _bind(null),
                              child: Text(
                                L.pick(
                                  en: 'Follow Theme Studio',
                                  zhTW: '跟隨主題工坊',
                                  zhCN: '跟随主题工坊',
                                ),
                                style: TextStyle(
                                  color: _selectedSlot == null
                                      ? YanciTheme.textSecondary.withValues(
                                          alpha: 0.35,
                                        )
                                      : YanciTheme.accent,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _presetPreview(BackgroundPreset preset) {
    final selected = _selectedSlot == preset.slot;
    final path = preset.chatPath.isNotEmpty ? preset.chatPath : preset.homePath;
    final file = path.isEmpty ? null : File(path);
    final exists = file?.existsSync() ?? false;
    final label = L.pick(
      en: 'Bind background set ${preset.slot}',
      zhTW: '綁定背景套組 ${preset.slot}',
      zhCN: '绑定背景套组 ${preset.slot}',
    );

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        key: ValueKey('character-background-slot-${preset.slot}'),
        onTap: () => _bind(preset.slot),
        child: Container(
          width: 68,
          height: 104,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? YanciTheme.accent
                  : YanciTheme.textSecondary.withValues(alpha: 0.24),
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (exists)
                Transform.translate(
                  offset: Offset(
                    preset.chatOffsetX * 68,
                    preset.chatOffsetY * 104,
                  ),
                  child: Transform.scale(
                    scale: preset.chatScale,
                    child: Image.file(
                      file!,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: YanciTheme.backgroundGradient,
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 26,
                  alignment: Alignment.center,
                  color: YanciTheme.isDark
                      ? Colors.black.withValues(alpha: 0.46)
                      : Colors.white.withValues(alpha: 0.72),
                  child: Text(
                    '${preset.slot}',
                    style: TextStyle(
                      color: selected
                          ? YanciTheme.accent
                          : YanciTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: YanciTheme.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
