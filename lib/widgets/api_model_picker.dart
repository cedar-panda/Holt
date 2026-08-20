import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/model_info.dart';
import '../theme/app_theme.dart';

class ApiModelPicker extends StatelessWidget {
  final String selectedModel;
  final List<ModelInfo> models;
  final List<ModelInfo> filteredModels;
  final TextEditingController searchController;
  final bool isFetchingModels;
  final bool showModelList;
  final Set<String> starredModels;
  final Color selectionSuccessColor;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onSelectModel;
  final VoidCallback onFetchModels;
  final VoidCallback onToggleModelList;
  final Future<void> Function(String modelId) onToggleStar;

  const ApiModelPicker({
    super.key,
    required this.selectedModel,
    required this.models,
    required this.filteredModels,
    required this.searchController,
    required this.isFetchingModels,
    required this.showModelList,
    required this.starredModels,
    required this.selectionSuccessColor,
    required this.onFilter,
    required this.onSelectModel,
    required this.onFetchModels,
    required this.onToggleModelList,
    required this.onToggleStar,
  });

  @override
  Widget build(BuildContext context) {
    final hasModels = models.isNotEmpty;
    final hasSearchResults = filteredModels.isNotEmpty;
    final query = searchController.text.trim();
    final modelCountText = hasModels
        ? L.pick(
            en: '${models.length} models available',
            zhTW: '已載入 ${models.length} 個模型',
            zhCN: '已加载 ${models.length} 个模型',
          )
        : L.pick(
            en: 'Enter a model ID or fetch the list',
            zhTW: '可直接填入模型 ID，或拉取列表',
            zhCN: '可直接填入模型 ID，或拉取列表',
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YanciTheme.spacingXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectedModel.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: YanciTheme.spacingSm,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: YanciTheme.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                border: Border.all(
                  color: selectionSuccessColor.withValues(alpha: 0.72),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: selectionSuccessColor,
                  ),
                  const SizedBox(width: YanciTheme.spacingSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.pick(
                            en: 'Current model',
                            zhTW: '目前模型',
                            zhCN: '当前模型',
                          ),
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 11,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 22),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: Text(
                              selectedModel,
                              maxLines: 1,
                              softWrap: false,
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 13,
                                color: YanciTheme.textPrimary,
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
            const SizedBox(height: YanciTheme.spacingSm),
          ],
          Semantics(
            textField: true,
            label: L.pick(en: 'Search models', zhTW: '搜尋模型', zhCN: '搜索模型'),
            child: TextField(
              key: const Key('api_settings_model_search_field'),
              controller: searchController,
              style: YanciTheme.bodyText.copyWith(fontSize: 14),
              decoration: InputDecoration(
                hintText: models.isEmpty
                    ? L.get('settings_model_hint_empty')
                    : L.get('settings_model_hint_search'),
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.52),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: YanciTheme.textSecondary,
                ),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        tooltip: L.pick(en: 'Clear search', zhTW: '清除搜尋'),
                        onPressed: () {
                          searchController.clear();
                          onFilter('');
                        },
                      )
                    : null,
              ),
              onChanged: onFilter,
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  onSelectModel(value.trim());
                }
              },
            ),
          ),
          const SizedBox(height: YanciTheme.spacingXs),
          Row(
            children: [
              Expanded(
                child: Text(
                  modelCountText,
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (hasModels)
                TextButton.icon(
                  key: const Key('api_settings_model_list_toggle'),
                  onPressed: onToggleModelList,
                  icon: Icon(
                    showModelList
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                  ),
                  label: Text(
                    L.pick(
                      en: showModelList ? 'Collapse' : 'Show list',
                      zhTW: showModelList ? '收起' : '展開列表',
                      zhCN: showModelList ? '收起' : '展开列表',
                    ),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: YanciTheme.textSecondary,
                  ),
                ),
              Tooltip(
                message: L.get('settings_model_refresh'),
                child: TextButton.icon(
                  key: const Key('api_settings_model_refresh_button'),
                  onPressed: isFetchingModels ? null : onFetchModels,
                  icon: isFetchingModels
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded, size: 17),
                  label: Text(
                    L.pick(en: 'Fetch list', zhTW: '拉取列表', zhCN: '拉取列表'),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: YanciTheme.accent,
                  ),
                ),
              ),
            ],
          ),
          if (hasModels && showModelList) ...[
            const SizedBox(height: YanciTheme.spacingXs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 172),
              child: hasSearchResults
                  ? ListView.separated(
                      shrinkWrap: true,
                      itemCount: filteredModels.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: YanciTheme.spacingSm,
                        endIndent: YanciTheme.spacingSm,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.10),
                      ),
                      itemBuilder: (context, index) {
                        final model = filteredModels[index];
                        final isSelected = model.id == selectedModel;
                        final isStarred = starredModels.contains(model.id);
                        return InkWell(
                          onTap: () => onSelectModel(model.id),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: YanciTheme.spacingSm,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    model.id,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: YanciTheme.bodyText.copyWith(
                                      fontSize: 13,
                                      color: isSelected
                                          ? YanciTheme.accent
                                          : YanciTheme.textPrimary,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: YanciTheme.accent,
                                    ),
                                  ),
                                IconButton(
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  padding: EdgeInsets.zero,
                                  onPressed: () => onToggleStar(model.id),
                                  icon: Icon(
                                    isStarred
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    size: 20,
                                    color: isStarred
                                        ? YanciTheme.accent
                                        : YanciTheme.textSecondary.withValues(
                                            alpha: 0.42,
                                          ),
                                  ),
                                  tooltip: isStarred
                                      ? L.pick(
                                          en: 'Remove from favorites',
                                          zhTW: '取消收藏',
                                        )
                                      : L.pick(
                                          en: 'Add to favorites',
                                          zhTW: '加入收藏',
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.all(YanciTheme.spacingMd),
                      child: Text(
                        L.pick(
                          en: 'No matching models',
                          zhTW: '沒有符合的模型',
                          zhCN: '没有符合的模型',
                        ),
                        style: YanciTheme.bodySmall,
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
