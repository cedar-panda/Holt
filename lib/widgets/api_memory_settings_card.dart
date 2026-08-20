import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../theme/app_theme.dart';

typedef SummarySelectionChanged = void Function(String provider, String model);

class ApiMemorySettingsCard extends StatefulWidget {
  final String summaryProvider;
  final String summaryModel;
  final Set<String> starredModels;
  final Map<String, String> starredModelProviders;
  final bool dreamCurationEnabled;
  final int dreamCurationThreshold;
  final Color borderColor;
  final SummarySelectionChanged onSummarySelectionChanged;
  final ValueChanged<bool> onDreamCurationChanged;
  final ValueChanged<int> onDreamCurationThresholdChanged;

  const ApiMemorySettingsCard({
    super.key,
    required this.summaryProvider,
    required this.summaryModel,
    required this.starredModels,
    required this.starredModelProviders,
    required this.dreamCurationEnabled,
    required this.dreamCurationThreshold,
    required this.borderColor,
    required this.onSummarySelectionChanged,
    required this.onDreamCurationChanged,
    required this.onDreamCurationThresholdChanged,
  });

  @override
  State<ApiMemorySettingsCard> createState() => _ApiMemorySettingsCardState();
}

class _ApiMemorySettingsCardState extends State<ApiMemorySettingsCard> {
  static const String _summarySelectionSeparator = '\u0000';
  late final TextEditingController _dreamThresholdController;

  @override
  void initState() {
    super.initState();
    _dreamThresholdController = TextEditingController(
      text: '${widget.dreamCurationThreshold}',
    );
  }

  @override
  void didUpdateWidget(covariant ApiMemorySettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dreamCurationThreshold != widget.dreamCurationThreshold &&
        _dreamThresholdController.text != '${widget.dreamCurationThreshold}') {
      _dreamThresholdController.text = '${widget.dreamCurationThreshold}';
    }
  }

  @override
  void dispose() {
    _dreamThresholdController.dispose();
    super.dispose();
  }

  String _summarySelectionValue(String provider, String model) {
    if (model.isEmpty) return '';
    return '$provider$_summarySelectionSeparator$model';
  }

  List<({String provider, String model})> _summaryModelOptions() {
    final options = <({String provider, String model})>[];
    final seen = <String>{};

    void add(String provider, String model) {
      final normalizedModel = model.trim();
      final normalizedProvider = normalizedModel.isEmpty ? '' : provider.trim();
      final value = _summarySelectionValue(normalizedProvider, normalizedModel);
      if (seen.add(value)) {
        options.add((provider: normalizedProvider, model: normalizedModel));
      }
    }

    add('', '');
    add(
      MemorySettings.defaultSummaryProvider,
      MemorySettings.defaultSummaryModel,
    );
    add(widget.summaryProvider, widget.summaryModel);

    final starred = widget.starredModels.toList()..sort();
    for (final model in starred) {
      final provider = widget.starredModelProviders[model] ?? '';
      if (provider.isNotEmpty) add(provider, model);
    }
    return options;
  }

  String _providerLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'xai' => 'xAI (Grok)',
    'gemini' => 'Google Gemini',
    'deepseek' => 'DeepSeek',
    'qwen' => 'Qwen',
    'bedrock' => 'AWS Bedrock',
    'thinking_machines' => 'Thinking Machines',
    'openai_compatible' => L.pick(
      en: 'Custom Relay',
      zhTW: '自訂中轉站',
      zhCN: '自定义中转站',
    ),
    'local' => L.pick(en: 'Local Model', zhTW: '本地模型'),
    'local_api' => 'Local API',
    _ => provider,
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
        border: Border.all(color: widget.borderColor, width: 0.75),
      ),
      child: child,
    );
  }

  OutlineInputBorder _thinInputBorder({Color? color, double width = 0.75}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      borderSide: BorderSide(color: color ?? widget.borderColor, width: width),
    );
  }

  Widget _buildSummaryModelCard() {
    final options = _summaryModelOptions();
    final selected = _summarySelectionValue(
      widget.summaryProvider,
      widget.summaryModel,
    );
    final selectedValue =
        options.any(
          (option) =>
              _summarySelectionValue(option.provider, option.model) == selected,
        )
        ? selected
        : '';

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: L.get('settings_summary_model'),
            child: DropdownButton<String>(
              value: selectedValue,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              style: YanciTheme.bodyText.copyWith(fontSize: 12),
              items: options.map((option) {
                final value = _summarySelectionValue(
                  option.provider,
                  option.model,
                );
                final label = option.model.isEmpty
                    ? L.pick(
                        en: 'Follow chat model',
                        zhTW: '跟隨聊天模型',
                        zhCN: '跟随聊天模型',
                      )
                    : '${_providerLabel(option.provider)} · ${option.model}';
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 12,
                      color: option.model.isEmpty
                          ? YanciTheme.textSecondary
                          : YanciTheme.textPrimary,
                    ),
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value == null) return;
                if (value.isEmpty) {
                  widget.onSummarySelectionChanged('', '');
                  return;
                }
                final separator = value.indexOf(_summarySelectionSeparator);
                if (separator < 1) return;
                widget.onSummarySelectionChanged(
                  value.substring(0, separator),
                  value.substring(separator + 1),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L.pick(
              en: 'Window summaries and automatic memory use this API pair. Star another model above to add it here.',
              zhTW: '窗口摘要與自動記憶使用這組來源和模型；在上方替其他模型加星即可加入選單。',
              zhCN: '窗口摘要与自动记忆使用这组来源和模型；在上方为其他模型加星即可加入选单。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 10,
              color: YanciTheme.textSecondary.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDreamCurationCard() {
    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Dream Curation', zhTW: '做夢整理', zhCN: '做梦整理'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
              ),
              SizedBox(
                height: 24,
                child: Switch.adaptive(
                  value: widget.dreamCurationEnabled,
                  activeThumbColor: YanciTheme.accent,
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                  onChanged: widget.onDreamCurationChanged,
                ),
              ),
            ],
          ),
          if (widget.dreamCurationEnabled) ...[
            const SizedBox(height: 6),
            Text(
              L.pick(
                en: 'Automatically organizes memories after conversations accumulate. Uses the summary model. Consumes a small amount of tokens.',
                zhTW: '對話累積後自動梳理記憶，使用摘要模型，需消耗少量 tokens。',
                zhCN: '对话累积后自动梳理记忆，使用摘要模型，需消耗少量 tokens。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  L.pick(en: 'Trigger after', zhTW: '累積', zhCN: '累积'),
                  style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: TextField(
                    controller: _dreamThresholdController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodyText.copyWith(fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 4,
                      ),
                      border: _thinInputBorder(),
                      enabledBorder: _thinInputBorder(),
                      focusedBorder: _thinInputBorder(
                        color: YanciTheme.accent.withValues(alpha: 0.85),
                        width: 1,
                      ),
                    ),
                    onChanged: (value) {
                      final threshold = int.tryParse(value);
                      if (threshold == null) return;
                      widget.onDreamCurationThresholdChanged(
                        threshold.clamp(
                          MemorySettings.minDreamThreshold,
                          MemorySettings.maxDreamThreshold,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  L.pick(en: 'new memories', zhTW: '條新記憶後觸發', zhCN: '条新记忆后触发'),
                  style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildSummaryModelCard(),
        const SizedBox(height: YanciTheme.spacingSm),
        _buildDreamCurationCard(),
      ],
    );
  }
}
