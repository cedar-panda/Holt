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
  final Set<String> primaryIds;
  final Color borderColor;
  final ValueChanged<String> onChanged;

  const ApiProviderPicker({
    super.key,
    required this.options,
    required this.selectedId,
    required this.showOtherProviders,
    required this.primaryIds,
    required this.borderColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 3 : 2;
        const gap = YanciTheme.spacingSm;
        final cardWidth =
            (constraints.maxWidth - (columns - 1) * gap) / columns;
        final visibleOptions = showOtherProviders
            ? options
            : options
                  .where(
                    (option) =>
                        primaryIds.contains(option.id) ||
                        option.id == selectedId,
                  )
                  .toList();

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final option in visibleOptions)
              SizedBox(
                width: cardWidth,
                child: _ProviderOption(
                  id: option.id,
                  label: option.label,
                  selected: selectedId == option.id,
                  borderColor: borderColor,
                  onTap: () => onChanged(option.id),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ProviderOption extends StatelessWidget {
  final String id;
  final String label;
  final bool selected;
  final Color borderColor;
  final VoidCallback onTap;

  const _ProviderOption({
    required this.id,
    required this.label,
    required this.selected,
    required this.borderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedColor = Color.lerp(
      const Color(0xFF4CAF6A),
      YanciTheme.accent,
      0.28,
    )!;

    return Semantics(
      key: ValueKey<String>('api_settings_provider_$id'),
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        onTap: selected ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: selected ? selectedColor : borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? selectedColor : Colors.transparent,
                  border: Border.all(
                    color: selected
                        ? selectedColor
                        : YanciTheme.textSecondary.withValues(alpha: 0.72),
                    width: selected ? 1 : 1.5,
                  ),
                ),
                child: selected
                    ? Center(
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: YanciTheme.spacingSm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: YanciTheme.bodyText.copyWith(
                    fontSize: 13.5,
                    color: selected
                        ? YanciTheme.textPrimary
                        : YanciTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
