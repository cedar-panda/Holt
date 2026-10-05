import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// Compact model controls for the primary API settings page.
///
/// The fetched catalogue is shown by the screen in a one-shot dialog, keeping
/// the ordinary settings flow focused on the current model and explicit load.
class ApiModelPicker extends StatelessWidget {
  final TextEditingController searchController;
  final bool isFetchingModels;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onSelectModel;
  final VoidCallback onLoadModels;

  const ApiModelPicker({
    super.key,
    required this.searchController,
    required this.isFetchingModels,
    required this.onFilter,
    required this.onSelectModel,
    required this.onLoadModels,
  });

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim();
    final borderColor = Color.lerp(
      YanciTheme.textSecondary,
      YanciTheme.accent,
      YanciTheme.isDark ? 0.38 : 0.28,
    )!.withValues(alpha: 0.82);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YanciTheme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Semantics(
              textField: true,
              label: L.pick(
                en: 'Search or enter model ID',
                zhTW: '搜尋或輸入模型 ID',
                zhCN: '搜索或输入模型 ID',
              ),
              child: TextField(
                key: const Key('api_settings_model_search_field'),
                controller: searchController,
                style: YanciTheme.bodyText.copyWith(fontSize: 14),
                decoration: InputDecoration(
                  hintText: L.pick(
                    en: 'Search or enter model ID',
                    zhTW: '搜尋或輸入模型 ID',
                    zhCN: '搜索或输入模型 ID',
                  ),
                  hintStyle: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.52),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: YanciTheme.textSecondary,
                  ),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          tooltip: L.pick(
                            en: 'Clear search',
                            zhTW: '清除搜尋',
                            zhCN: '清除搜索',
                          ),
                          onPressed: () {
                            searchController.clear();
                            onFilter('');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    borderSide: BorderSide(color: borderColor, width: 1),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    borderSide: BorderSide(color: borderColor, width: 1),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    borderSide: BorderSide(color: YanciTheme.accent, width: 1),
                  ),
                ),
                onChanged: onFilter,
                onSubmitted: (value) {
                  final model = value.trim();
                  if (model.isNotEmpty) onSelectModel(model);
                },
              ),
            ),
          ),
          const SizedBox(width: YanciTheme.spacingSm),
          OutlinedButton.icon(
            key: const Key('api_settings_model_refresh_button'),
            onPressed: isFetchingModels ? null : onLoadModels,
            icon: isFetchingModels
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded, size: 18),
            label: Text(L.pick(en: 'Load', zhTW: '載入', zhCN: '载入')),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 46),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              foregroundColor: YanciTheme.accent,
              side: BorderSide(color: borderColor, width: 1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
