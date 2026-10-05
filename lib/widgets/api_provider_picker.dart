import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class ApiProviderOption {
  final String id;
  final String label;

  const ApiProviderOption({required this.id, required this.label});
}

class ApiProviderPicker extends StatelessWidget {
  final List<ApiProviderOption> options;
  final String selectedId;
  final bool showOtherProviders;
  final ValueChanged<String> onChanged;

  const ApiProviderPicker({
    super.key,
    required this.options,
    required this.selectedId,
    required this.showOtherProviders,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final visibleOptions = showOtherProviders
        ? options
        : options.where((option) => option.id == selectedId).toList();

    return Semantics(
      container: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (var index = 0; index < visibleOptions.length; index++) ...[
              SizedBox(
                width: 118,
                child: _ProviderOption(
                  id: visibleOptions[index].id,
                  label: visibleOptions[index].label,
                  selected: selectedId == visibleOptions[index].id,
                  onTap: () => onChanged(visibleOptions[index].id),
                ),
              ),
              if (index != visibleOptions.length - 1)
                const SizedBox(width: YanciTheme.spacingSm),
            ],
          ],
        ),
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
    final selectedColor = YanciTheme.accent;

    return Semantics(
      key: ValueKey<String>('api_settings_provider_$id'),
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        onTap: selected ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            boxShadow: [
              if (!selected)
                BoxShadow(
                  color: YanciTheme.textSecondary.withValues(
                    alpha: YanciTheme.isDark ? 0.18 : 0.11,
                  ),
                  blurRadius: 2,
                  spreadRadius: -1,
                  offset: const Offset(2, 2),
                ),
            ],
          ),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              style: YanciTheme.bodyText.copyWith(
                fontSize: 13.5,
                color: selected ? selectedColor : YanciTheme.textSecondary,
                shadows: selected
                    ? [
                        Shadow(
                          color: selectedColor.withValues(alpha: 0.22),
                          blurRadius: 3,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
