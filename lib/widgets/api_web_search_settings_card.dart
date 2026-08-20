import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/web_search_service.dart';
import '../theme/app_theme.dart';

class ApiWebSearchViewState {
  final TextEditingController openRouterKeyController;
  final TextEditingController geminiKeyController;
  final TextEditingController xaiKeyController;
  final TextEditingController relayEndpointController;
  final TextEditingController relayKeyController;
  final TextEditingController relayModelController;
  final bool enabled;
  final WebSearchMode mode;
  final int dailyProviderLaunchCap;
  final int maxResults;
  final String geminiModel;
  final String xaiModel;
  final String openRouterModelOverride;
  final String geminiModelOverride;
  final String xaiModelOverride;
  final String currentProvider;
  final Set<String> starredModels;
  final Map<String, String> starredModelProviders;
  final bool obscureProviderKeys;
  final bool enabledToggleActive;
  final Color borderColor;

  const ApiWebSearchViewState({
    required this.openRouterKeyController,
    required this.geminiKeyController,
    required this.xaiKeyController,
    required this.relayEndpointController,
    required this.relayKeyController,
    required this.relayModelController,
    required this.enabled,
    required this.mode,
    required this.dailyProviderLaunchCap,
    required this.maxResults,
    required this.geminiModel,
    required this.xaiModel,
    required this.openRouterModelOverride,
    required this.geminiModelOverride,
    required this.xaiModelOverride,
    required this.currentProvider,
    required this.starredModels,
    required this.starredModelProviders,
    required this.obscureProviderKeys,
    required this.enabledToggleActive,
    required this.borderColor,
  });
}

class ApiWebSearchViewActions {
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<WebSearchMode> onModeChanged;
  final ValueChanged<int> onDailyProviderLaunchCapChanged;
  final ValueChanged<int> onMaxResultsChanged;
  final ValueChanged<String> onOpenRouterModelChanged;
  final ValueChanged<String> onGeminiModelChanged;
  final ValueChanged<String> onXaiModelChanged;
  final ValueChanged<String> onRelayModelChanged;
  final VoidCallback onToggleObscureProviderKeys;
  final ValueChanged<String> onRelayEndpointChanged;
  final ValueChanged<String> onRelayKeyChanged;

  const ApiWebSearchViewActions({
    required this.onEnabledChanged,
    required this.onModeChanged,
    required this.onDailyProviderLaunchCapChanged,
    required this.onMaxResultsChanged,
    required this.onOpenRouterModelChanged,
    required this.onGeminiModelChanged,
    required this.onXaiModelChanged,
    required this.onRelayModelChanged,
    required this.onToggleObscureProviderKeys,
    required this.onRelayEndpointChanged,
    required this.onRelayKeyChanged,
  });
}

class ApiWebSearchSettingsCard extends StatelessWidget {
  final ApiWebSearchViewState viewState;
  final ApiWebSearchViewActions actions;

  const ApiWebSearchSettingsCard({
    super.key,
    required this.viewState,
    required this.actions,
  });

  TextEditingController get openRouterKeyController =>
      viewState.openRouterKeyController;
  TextEditingController get geminiKeyController =>
      viewState.geminiKeyController;
  TextEditingController get xaiKeyController => viewState.xaiKeyController;
  TextEditingController get relayEndpointController =>
      viewState.relayEndpointController;
  TextEditingController get relayKeyController => viewState.relayKeyController;
  TextEditingController get relayModelController =>
      viewState.relayModelController;
  bool get enabled => viewState.enabled;
  WebSearchMode get mode => viewState.mode;
  int get dailyProviderLaunchCap => viewState.dailyProviderLaunchCap;
  int get maxResults => viewState.maxResults;
  String get geminiModel => viewState.geminiModel;
  String get xaiModel => viewState.xaiModel;
  String get openRouterModelOverride => viewState.openRouterModelOverride;
  String get geminiModelOverride => viewState.geminiModelOverride;
  String get xaiModelOverride => viewState.xaiModelOverride;
  String get currentProvider => viewState.currentProvider;
  Set<String> get starredModels => viewState.starredModels;
  Map<String, String> get starredModelProviders =>
      viewState.starredModelProviders;
  bool get obscureProviderKeys => viewState.obscureProviderKeys;
  bool get enabledToggleActive => viewState.enabledToggleActive;
  Color get borderColor => viewState.borderColor;
  ValueChanged<bool> get onEnabledChanged => actions.onEnabledChanged;
  ValueChanged<WebSearchMode> get onModeChanged => actions.onModeChanged;
  ValueChanged<int> get onDailyProviderLaunchCapChanged =>
      actions.onDailyProviderLaunchCapChanged;
  ValueChanged<int> get onMaxResultsChanged => actions.onMaxResultsChanged;
  ValueChanged<String> get onOpenRouterModelChanged =>
      actions.onOpenRouterModelChanged;
  ValueChanged<String> get onGeminiModelChanged => actions.onGeminiModelChanged;
  ValueChanged<String> get onXaiModelChanged => actions.onXaiModelChanged;
  ValueChanged<String> get onRelayModelChanged => actions.onRelayModelChanged;
  VoidCallback get onToggleObscureProviderKeys =>
      actions.onToggleObscureProviderKeys;
  ValueChanged<String> get onRelayEndpointChanged =>
      actions.onRelayEndpointChanged;
  ValueChanged<String> get onRelayKeyChanged => actions.onRelayKeyChanged;

  String _modeLabel(WebSearchMode value) => switch (value) {
    WebSearchMode.auto => L.pick(en: 'Auto', zhTW: '自動選擇', zhCN: '自动选择'),
    WebSearchMode.gemini => 'Gemini',
    WebSearchMode.openRouter => 'OpenRouter',
    WebSearchMode.xai => 'Grok / xAI',
    WebSearchMode.relay => L.pick(
      en: 'Search relay',
      zhTW: '搜尋中轉站',
      zhCN: '搜索中转站',
    ),
    // Retained only to migrate old stored values; it is no longer shown.
    WebSearchMode.dual => L.pick(en: 'Auto', zhTW: '自動選擇', zhCN: '自动选择'),
  };

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingMd,
        vertical: YanciTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: borderColor, width: 0.75),
      ),
      child: child,
    );
  }

  WebSearchMode _resolvedAutomaticMode() {
    final openRouterModel = openRouterModelOverride.isNotEmpty
        ? openRouterModelOverride
        : openRouterWebSearchPreviewModel;
    final resolvedGeminiModel = geminiModelOverride.isNotEmpty
        ? geminiModelOverride
        : geminiModel;
    final resolvedXaiModel = xaiModelOverride.isNotEmpty
        ? xaiModelOverride
        : xaiModel;
    final relayEndpoint = Uri.tryParse(relayEndpointController.text.trim());

    final ready = <WebSearchMode, bool>{
      WebSearchMode.openRouter:
          openRouterKeyController.text.trim().isNotEmpty &&
          isExplicitOpenRouterWebSearchModel(openRouterModel),
      WebSearchMode.gemini:
          geminiKeyController.text.trim().isNotEmpty &&
          isSupportedGeminiWebSearchModel(resolvedGeminiModel),
      WebSearchMode.xai:
          xaiKeyController.text.trim().isNotEmpty &&
          resolvedXaiModel.trim().isNotEmpty,
      WebSearchMode.relay:
          relayEndpointController.text.trim().isNotEmpty &&
          relayKeyController.text.trim().isNotEmpty &&
          relayModelController.text.trim().isNotEmpty &&
          relayEndpoint != null &&
          relayEndpoint.scheme == 'https' &&
          relayEndpoint.host.isNotEmpty &&
          relayEndpoint.userInfo.isEmpty &&
          relayEndpoint.fragment.isEmpty,
    };
    final current = switch (currentProvider) {
      'gemini' => WebSearchMode.gemini,
      'openrouter' => WebSearchMode.openRouter,
      'xai' => WebSearchMode.xai,
      _ => null,
    };
    if (current != null && ready[current] == true) return current;
    for (final candidate in const <WebSearchMode>[
      WebSearchMode.gemini,
      WebSearchMode.openRouter,
      WebSearchMode.xai,
      WebSearchMode.relay,
    ]) {
      if (ready[candidate] == true) return candidate;
    }

    // Nothing is configured yet: expose the most relevant picker so setup can
    // continue without silently changing the runtime auto-selection order.
    return switch (currentProvider) {
      'openrouter' => WebSearchMode.openRouter,
      'xai' => WebSearchMode.xai,
      'openai_compatible' => WebSearchMode.relay,
      _ => WebSearchMode.gemini,
    };
  }

  Widget _buildSearchModelPicker({
    required String providerLabel,
    required String filterProvider,
    required String currentOverride,
    required String fallbackModel,
    required bool hasApiKey,
    required ValueChanged<String> onChanged,
    String? emptySelectionLabel,
  }) {
    final candidates = <String>[];
    for (final modelId in starredModels) {
      final provider = starredModelProviders[modelId] ?? '';
      if (provider == filterProvider &&
          !modelId.toLowerCase().contains(':batch')) {
        candidates.add(modelId);
      }
    }
    candidates.sort();

    final effectiveModel = currentOverride.isNotEmpty
        ? currentOverride
        : fallbackModel;
    if (currentOverride.isNotEmpty && !candidates.contains(currentOverride)) {
      candidates.insert(0, currentOverride);
    }

    final ready = hasApiKey && effectiveModel.isNotEmpty;
    final statusText = !hasApiKey
        ? L.pick(en: 'No API key', zhTW: '尚未輸入 API 金鑰', zhCN: '尚未输入 API 密钥')
        : ready
        ? L.pick(en: 'Ready', zhTW: '已就緒', zhCN: '已就绪')
        : L.pick(en: 'No model selected', zhTW: '尚未選擇模型', zhCN: '尚未选择模型');

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                ready ? Icons.check_circle_outline_rounded : Icons.info_outline,
                size: 18,
                color: ready ? YanciTheme.accent : YanciTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                '$providerLabel · $statusText',
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Semantics(
            label: L.pick(
              en: '$providerLabel search model',
              zhTW: '$providerLabel 搜尋模型',
              zhCN: '$providerLabel 搜索模型',
            ),
            value: effectiveModel,
            child: DropdownButton<String>(
              value: currentOverride,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              style: YanciTheme.bodyText.copyWith(
                fontSize: 12,
                color: YanciTheme.textPrimary,
              ),
              items: [
                DropdownMenuItem<String>(
                  value: '',
                  child: Text(
                    L.pick(
                      en:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? 'Choose a starred model'
                              : 'Auto · $fallbackModel'),
                      zhTW:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? '選擇已星標模型'
                              : '自動 · $fallbackModel'),
                      zhCN:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? '选择已星标模型'
                              : '自动 · $fallbackModel'),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 12,
                      color: YanciTheme.textSecondary,
                    ),
                  ),
                ),
                for (final modelId in candidates)
                  DropdownMenuItem<String>(
                    value: modelId,
                    child: Text(
                      modelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodyText.copyWith(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                onChanged(value);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              L.pick(
                en: 'Star models for this source above, then choose one here.',
                zhTW: '請先在上方替此來源的模型加上星標，再於此選擇。',
                zhCN: '请先在上方为此来源的模型加上星标，再在此选择。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSelectedSourceOptions() {
    final selectedMode = mode == WebSearchMode.auto
        ? _resolvedAutomaticMode()
        : mode;
    final sections = <Widget>[];

    void addSection(Widget child) {
      if (sections.isNotEmpty) {
        sections.add(
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.12),
            height: 1,
          ),
        );
      }
      sections.add(child);
    }

    if (selectedMode == WebSearchMode.openRouter) {
      addSection(
        _buildSearchModelPicker(
          providerLabel: 'OpenRouter',
          filterProvider: 'openrouter',
          currentOverride: openRouterModelOverride,
          fallbackModel: openRouterWebSearchPreviewModel,
          hasApiKey: openRouterKeyController.text.trim().isNotEmpty,
          onChanged: onOpenRouterModelChanged,
        ),
      );
    }
    if (selectedMode == WebSearchMode.gemini) {
      addSection(
        _buildSearchModelPicker(
          providerLabel: 'Gemini',
          filterProvider: 'gemini',
          currentOverride: geminiModelOverride,
          fallbackModel: geminiModel,
          hasApiKey: geminiKeyController.text.trim().isNotEmpty,
          onChanged: onGeminiModelChanged,
        ),
      );
    }
    if (selectedMode == WebSearchMode.xai) {
      addSection(
        _buildSearchModelPicker(
          providerLabel: 'Grok / xAI',
          filterProvider: 'xai',
          currentOverride: xaiModelOverride,
          fallbackModel: xaiModel,
          hasApiKey: xaiKeyController.text.trim().isNotEmpty,
          onChanged: onXaiModelChanged,
        ),
      );
    }
    if (selectedMode == WebSearchMode.relay) {
      addSection(_buildRelayOptions());
    }
    return sections;
  }

  Widget _buildRelayOptions() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            L.pick(
              en: 'Search relay (OpenAI-compatible)',
              zhTW: '搜尋中轉站（OpenAI 相容）',
              zhCN: '搜索中转站（OpenAI 兼容）',
            ),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: relayEndpointController,
            keyboardType: TextInputType.url,
            onChanged: onRelayEndpointChanged,
            decoration: InputDecoration(
              hintText: L.pick(
                en: 'https://relay.example/v1/chat/completions',
                zhTW: 'https://relay.example/v1/chat/completions',
                zhCN: 'https://relay.example/v1/chat/completions',
              ),
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: relayKeyController,
            obscureText: obscureProviderKeys,
            onChanged: onRelayKeyChanged,
            decoration: InputDecoration(
              hintText: L.pick(
                en: 'Relay API Key',
                zhTW: '中轉站 API 金鑰',
                zhCN: '中转站 API 密钥',
              ),
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(
                  obscureProviderKeys
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                tooltip: L.pick(
                  en: obscureProviderKeys ? 'Show API Key' : 'Hide API Key',
                  zhTW: obscureProviderKeys ? '顯示 API Key' : '隱藏 API Key',
                ),
                onPressed: onToggleObscureProviderKeys,
              ),
            ),
          ),
          const SizedBox(height: 6),
          _buildSearchModelPicker(
            providerLabel: L.pick(
              en: 'Search relay',
              zhTW: '搜尋中轉站',
              zhCN: '搜索中转站',
            ),
            filterProvider: 'openai_compatible',
            currentOverride: relayModelController.text.trim(),
            fallbackModel: '',
            hasApiKey:
                relayEndpointController.text.trim().isNotEmpty &&
                relayKeyController.text.trim().isNotEmpty,
            onChanged: onRelayModelChanged,
          ),
          const SizedBox(height: 6),
          Text(
            L.pick(
              en: 'Only HTTPS OpenAI Chat Completions relays are accepted; the relay must return url_citation annotations.',
              zhTW:
                  '只接受 HTTPS OpenAI Chat Completions 中轉站；中轉站必須回傳 url_citation 引用。',
              zhCN:
                  '只接受 HTTPS OpenAI Chat Completions 中转站；中转站必须返回 url_citation 引用。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 11,
              height: 1.4,
              color: YanciTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        openRouterKeyController,
        geminiKeyController,
        xaiKeyController,
        relayEndpointController,
        relayKeyController,
        relayModelController,
      ]),
      builder: (context, _) {
        final selectedModeLabel = _modeLabel(mode);
        return _buildGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: Colors.transparent,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    L.pick(
                      en: 'Native web search',
                      zhTW: '原生網路搜尋',
                      zhCN: '原生网络搜索',
                    ),
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                  value: enabled,
                  activeThumbColor: YanciTheme.accent,
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                  onChanged: enabledToggleActive ? onEnabledChanged : null,
                ),
              ),
              if (enabled) ...[
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                const SizedBox(height: 12),
                Text(
                  L.pick(en: 'Source', zhTW: '來源', zhCN: '来源'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Semantics(
                  label: L.pick(
                    en: 'Search source',
                    zhTW: '搜尋來源',
                    zhCN: '搜索来源',
                  ),
                  value: selectedModeLabel,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                      border: Border.all(color: borderColor, width: 0.75),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButton<WebSearchMode>(
                      value: mode,
                      isExpanded: true,
                      underline: const SizedBox(),
                      dropdownColor: YanciTheme.isDark
                          ? const Color(0xF0302830)
                          : Colors.white,
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 13,
                        color: YanciTheme.textPrimary,
                      ),
                      items: [
                        for (final candidate in WebSearchMode.values)
                          if (candidate != WebSearchMode.dual)
                            DropdownMenuItem<WebSearchMode>(
                              value: candidate,
                              child: Text(
                                _modeLabel(candidate),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                      ],
                      onChanged: (value) {
                        if (value != null) onModeChanged(value);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ..._buildSelectedSourceOptions(),
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                const SizedBox(height: 12),
                _buildSliderSetting(
                  title: L.pick(
                    en: 'Web pages per search',
                    zhTW: '每次搜尋網頁數',
                    zhCN: '每次搜索网页数',
                  ),
                  valueLabel: L.pick(
                    en: '$maxResults pages',
                    zhTW: '$maxResults 頁',
                    zhCN: '$maxResults 页',
                  ),
                  semanticLabel: L.pick(
                    en: 'Web pages per search',
                    zhTW: '每次搜尋網頁數',
                    zhCN: '每次搜索网页数',
                  ),
                  value: maxResults.toDouble(),
                  min: WebSearchSettings.minMaxResults.toDouble(),
                  max: WebSearchSettings.maxMaxResults.toDouble(),
                  divisions:
                      WebSearchSettings.maxMaxResults -
                      WebSearchSettings.minMaxResults,
                  onChanged: (value) => onMaxResultsChanged(value.round()),
                  semanticFormatter: (value) => L.pick(
                    en: '${value.round()} web pages per search',
                    zhTW: '每次搜尋 ${value.round()} 個網頁',
                    zhCN: '每次搜索 ${value.round()} 个网页',
                  ),
                ),
                const SizedBox(height: 8),
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                const SizedBox(height: 12),
                _buildSliderSetting(
                  title: L.pick(
                    en: 'Daily provider-launch cap',
                    zhTW: '每日供應商啟動上限',
                    zhCN: '每日供应商启动上限',
                  ),
                  valueLabel: L.pick(
                    en: '$dailyProviderLaunchCap / day',
                    zhTW: '$dailyProviderLaunchCap 次／日',
                    zhCN: '$dailyProviderLaunchCap 次／日',
                  ),
                  semanticLabel: L.pick(
                    en: 'Daily provider-launch cap',
                    zhTW: '每日供應商啟動上限',
                    zhCN: '每日供应商启动上限',
                  ),
                  value: dailyProviderLaunchCap.toDouble(),
                  min: WebSearchSettings.minDailyProviderLaunchCap.toDouble(),
                  max: WebSearchSettings.maxDailyProviderLaunchCap.toDouble(),
                  divisions:
                      WebSearchSettings.maxDailyProviderLaunchCap -
                      WebSearchSettings.minDailyProviderLaunchCap,
                  onChanged: (value) =>
                      onDailyProviderLaunchCapChanged(value.round()),
                  semanticFormatter: (value) => L.pick(
                    en: '${value.round()} provider launches per day',
                    zhTW: '每日 ${value.round()} 次供應商啟動',
                    zhCN: '每日 ${value.round()} 次供应商启动',
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSliderSetting({
    required String title,
    required String valueLabel,
    required String semanticLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required SemanticFormatterCallback semanticFormatter,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Semantics(
          label: semanticLabel,
          value: value.toInt().toString(),
          child: Slider.adaptive(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: value.toInt().toString(),
            activeColor: YanciTheme.accent,
            onChanged: onChanged,
            semanticFormatterCallback: semanticFormatter,
          ),
        ),
      ],
    );
  }
}
