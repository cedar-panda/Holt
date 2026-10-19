import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class ApiProviderOption {
  final String id;
  final String label;

  const ApiProviderOption({required this.id, required this.label});
}

/// A compact source selector that keeps the full provider list out of the
/// ordinary settings flow until the user explicitly opens it.
class ApiProviderPicker extends StatelessWidget {
  final List<ApiProviderOption> options;
  final String selectedId;
  final bool showOtherProviders;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool>? onExpandedChanged;

  const ApiProviderPicker({
    super.key,
    required this.options,
    required this.selectedId,
    required this.showOtherProviders,
    required this.onChanged,
    this.onExpandedChanged,
  });

  ApiProviderOption? get _selected {
    for (final option in options) {
      if (option.id == selectedId) return option;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final borderColor = Color.lerp(
      YanciTheme.textSecondary,
      YanciTheme.accent,
      YanciTheme.isDark ? 0.38 : 0.28,
    )!.withValues(alpha: 0.41);

    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: showOtherProviders,
            label: L.pick(
              en: 'Choose API source',
              zhTW: '選擇 API 來源',
              zhCN: '选择 API 来源',
            ),
            child: InkWell(
              key: const ValueKey('api_settings_provider_selector'),
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
              onTap: onExpandedChanged == null
                  ? null
                  : () => onExpandedChanged!(!showOtherProviders),
              child: Container(
                constraints: const BoxConstraints(minHeight: 50),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                  border: Border.all(color: borderColor, width: 1),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        selected?.label ??
                            L.pick(
                              en: 'Choose an API source',
                              zhTW: '請選擇 API 來源',
                              zhCN: '请选择 API 来源',
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 13.5,
                          color: selected == null
                              ? YanciTheme.textSecondary.withValues(alpha: 0.56)
                              : YanciTheme.textPrimary,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: showOtherProviders ? 0.5 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 21,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.62),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showOtherProviders) ...[
            const SizedBox(height: 6),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: YanciTheme.surfacePanel.withValues(
                  alpha: YanciTheme.isDark ? 0.76 : 0.86,
                ),
                borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                border: Border.all(color: borderColor, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var index = 0; index < options.length; index++) ...[
                    _ProviderOption(
                      id: options[index].id,
                      label: options[index].label,
                      selected: selectedId == options[index].id,
                      onTap: () {
                        onChanged(options[index].id);
                        onExpandedChanged?.call(false);
                      },
                    ),
                    if (index != options.length - 1)
                      Divider(
                        height: 1,
                        indent: 14,
                        endIndent: 14,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.08),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderOption extends StatelessWidget {
  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ProviderOption({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: ValueKey<String>('api_settings_provider_$id'),
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 13.5,
                      color: selected
                          ? YanciTheme.accent
                          : YanciTheme.textSecondary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 18, color: YanciTheme.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
