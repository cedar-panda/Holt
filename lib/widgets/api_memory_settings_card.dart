import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../theme/app_theme.dart';

typedef SummarySelectionChanged = void Function(String provider, String model);
typedef EmbeddingSelectionChanged =
    void Function(String provider, String model);

class ApiMemorySettingsCard extends StatefulWidget {
  final String summaryProvider;
  final String summaryModel;
  final String embeddingProvider;
  final String embeddingModel;
  final List<StarredModelEntry> embeddingModelEntries;
  final List<StarredModelEntry> starredModelEntries;
  final List<StarredModelEntry> availableModelEntries;
  final bool dreamCurationEnabled;
  final int dreamCurationThreshold;
  final bool showDreamCuration;
  final bool showSummarySelection;
  final bool showAdvancedMemoryOptions;
  final bool showRpSummaryOptions;
  final Color borderColor;
  final SummarySelectionChanged onSummarySelectionChanged;
  final EmbeddingSelectionChanged onEmbeddingSelectionChanged;
  final ValueChanged<bool> onDreamCurationChanged;
  final ValueChanged<int> onDreamCurationThresholdChanged;

  const ApiMemorySettingsCard({
    super.key,
    required this.summaryProvider,
    required this.summaryModel,
    required this.embeddingProvider,
    required this.embeddingModel,
    required this.embeddingModelEntries,
    required this.starredModelEntries,
    this.availableModelEntries = const <StarredModelEntry>[],
    required this.dreamCurationEnabled,
    required this.dreamCurationThreshold,
    this.showDreamCuration = false,
    this.showSummarySelection = true,
    this.showAdvancedMemoryOptions = true,
    this.showRpSummaryOptions = false,
    required this.borderColor,
    required this.onSummarySelectionChanged,
    required this.onEmbeddingSelectionChanged,
    required this.onDreamCurationChanged,
    required this.onDreamCurationThresholdChanged,
  });

  @override
  State<ApiMemorySettingsCard> createState() => _ApiMemorySettingsCardState();
}

class _ApiMemorySettingsCardState extends State<ApiMemorySettingsCard> {
  static const String _summarySelectionSeparator = '\u0000';
  late final TextEditingController _dreamThresholdController;
  late final TextEditingController _worldbookIntervalController;
  bool? _worldbookAutoWrite;
  bool? _rpSummaryAutoMaxChars;
  int? _rpDynamicSummarySegments;

  @override
  void initState() {
    super.initState();
    _dreamThresholdController = TextEditingController(
      text: '${widget.dreamCurationThreshold}',
    );
    _worldbookIntervalController = TextEditingController(text: '4');
    _loadWorldbookSettings();
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
    _worldbookIntervalController.dispose();
    super.dispose();
  }

  Future<void> _loadWorldbookSettings() async {
    final enabled = await MemorySettings.getRpWorldbookAutoWriteEnabled();
    final interval = await MemorySettings.getRpWorldbookSummaryInterval();
    final autoMax = await MemorySettings.getRpSummaryAutoMaxCharsEnabled();
    final dynamicSegments = await MemorySettings.getRpDynamicSummarySegments();
    if (!mounted) return;
    setState(() {
      _worldbookAutoWrite = enabled;
      _rpSummaryAutoMaxChars = autoMax;
      _rpDynamicSummarySegments = dynamicSegments;
      _worldbookIntervalController.text = '$interval';
    });
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

    final starred = List<StarredModelEntry>.from(widget.starredModelEntries)
      ..sort((a, b) {
        final providerOrder = a.provider.compareTo(b.provider);
        return providerOrder != 0
            ? providerOrder
            : a.modelId.compareTo(b.modelId);
      });
    for (final entry in starred) {
      add(entry.provider, entry.modelId);
    }
    for (final entry in widget.availableModelEntries) {
      add(entry.provider, entry.modelId);
    }
    return options;
  }

  List<({String provider, String model})> _embeddingModelOptions() {
    final options = <({String provider, String model})>[
      (provider: '', model: ''),
    ];
    final seen = <String>{''};

    void add(String provider, String model) {
      final normalizedModel = model.trim();
      if (normalizedModel.isEmpty) return;
      final normalizedProvider = provider.trim();
      final value = _summarySelectionValue(normalizedProvider, normalizedModel);
      if (seen.add(value)) {
        options.add((provider: normalizedProvider, model: normalizedModel));
      }
    }

    add(widget.embeddingProvider, widget.embeddingModel);
    final discovered =
        List<StarredModelEntry>.from(widget.embeddingModelEntries)
          ..sort((a, b) {
            final providerOrder = a.provider.compareTo(b.provider);
            return providerOrder != 0
                ? providerOrder
                : a.modelId.compareTo(b.modelId);
          });
    for (final entry in discovered) {
      if (entry.provider == 'deepinfra' ||
          entry.modelId.toLowerCase().contains('embedding')) {
        add(entry.provider, entry.modelId);
      }
    }
    return options;
  }

  String _providerLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'xai' => 'xAI (Grok)',
    'gemini' => 'Gemini',
    'deepseek' => 'DeepSeek',
    'deepinfra' => 'DeepInfra',
    'qwen' => 'Qwen',
    'bedrock' => 'AWS Bedrock',
    'thinking_machines' => 'Inkling',
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
      ),
      child: child,
    );
  }

  OutlineInputBorder _thinInputBorder({Color? color, double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      borderSide: BorderSide.none,
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
          if (widget.showSummarySelection) ...[
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
          ],
          if (widget.showAdvancedMemoryOptions ||
              widget.showRpSummaryOptions) ...[
            if (widget.showSummarySelection) ...[
              const SizedBox(height: 10),
              Divider(
                height: 1,
                color: YanciTheme.textSecondary.withValues(alpha: 0.12),
              ),
              const SizedBox(height: 8),
            ],
            if (widget.showAdvancedMemoryOptions) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      L.pick(
                        en: 'Automatic worldbook',
                        zhTW: '自動整理世界書',
                        zhCN: '自动整理世界书',
                      ),
                      style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                    ),
                  ),
                  SizedBox(
                    height: 24,
                    child: Switch.adaptive(
                      value: _worldbookAutoWrite ?? true,
                      activeThumbColor: YanciTheme.accent,
                      activeTrackColor: YanciTheme.accent.withValues(
                        alpha: 0.3,
                      ),
                      onChanged: _worldbookAutoWrite == null
                          ? null
                          : (value) {
                              setState(() => _worldbookAutoWrite = value);
                              MemorySettings.saveRpWorldbookAutoWriteEnabled(
                                value,
                              );
                            },
                    ),
                  ),
                ],
              ),
              if (_worldbookAutoWrite ?? true) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'Process after this many RP summaries',
                          zhTW: '累積摘要後整理世界書',
                          zhCN: '累积摘要后整理世界书',
                        ),
                        style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                      ),
                    ),
                    SizedBox(
                      width: 72,
                      child: TextField(
                        controller: _worldbookIntervalController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 12,
                          color: YanciTheme.accent,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          suffixText: L.pick(en: 'items', zhTW: '份', zhCN: '份'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 5,
                            horizontal: 6,
                          ),
                          border: _thinInputBorder(),
                          enabledBorder: _thinInputBorder(),
                          focusedBorder: _thinInputBorder(
                            color: YanciTheme.accent.withValues(alpha: 0.85),
                            width: 1,
                          ),
                        ),
                        onChanged: (text) {
                          final value = int.tryParse(text);
                          if (value != null && value >= 1 && value <= 20) {
                            MemorySettings.saveRpWorldbookSummaryInterval(
                              value,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  L.pick(
                    en: 'Default 4. Uses a separate model call and the selected summary model.',
                    zhTW: '預設 4 份。世界書會獨立呼叫目前選中的摘要模型。',
                    zhCN: '默认 4 份。世界书会独立调用当前选中的摘要模型。',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 10,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.65),
                  ),
                ),
              ],
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      en: 'Scale RP ceiling with storyline size',
                      zhTW: '依故事線總量自動調整摘要上限',
                      zhCN: '按故事线总量自动调整摘要上限',
                    ),
                    style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                  ),
                ),
                SizedBox(
                  height: 24,
                  child: Switch.adaptive(
                    value: _rpSummaryAutoMaxChars ?? true,
                    activeThumbColor: YanciTheme.accent,
                    activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                    onChanged: _rpSummaryAutoMaxChars == null
                        ? null
                        : (value) {
                            setState(() => _rpSummaryAutoMaxChars = value);
                            MemorySettings.saveRpSummaryAutoMaxCharsEnabled(
                              value,
                            );
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              L.pick(
                en: 'May choose a shorter target from storyline size, but never exceeds the hard limit below.',
                zhTW: '可依故事線原文總量自動縮短，但永遠不超過下方硬上限。',
                zhCN: '可按故事线原文总量自动缩短，但永远不超过下方硬上限。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: MemorySettings.getRpSummaryMaxChars(),
              builder: (context, snapshot) {
                final value = snapshot.data ?? 1600;
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'RP dossier hard limit',
                          zhTW: 'RP 摘要硬上限',
                          zhCN: 'RP 摘要硬上限',
                        ),
                        style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                      ),
                    ),
                    SizedBox(
                      width: 92,
                      child: TextFormField(
                        key: ValueKey<int>(value),
                        initialValue: '$value',
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 12,
                          color: YanciTheme.accent,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          suffixText: L.pick(en: 'chars', zhTW: '字', zhCN: '字'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 5,
                            horizontal: 6,
                          ),
                          border: _thinInputBorder(),
                          enabledBorder: _thinInputBorder(),
                          focusedBorder: _thinInputBorder(
                            color: YanciTheme.accent.withValues(alpha: 0.85),
                            width: 1,
                          ),
                        ),
                        onChanged: (text) {
                          final parsed = int.tryParse(text);
                          if (parsed != null &&
                              parsed >= 800 &&
                              parsed <= 4000) {
                            MemorySettings.saveRpSummaryMaxChars(parsed);
                          }
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              L.pick(
                en: 'Default 1600. This is a ceiling, not a target; supported range 800-4000.',
                zhTW: '預設 1600。這是天花板，不是要求寫滿；可設定 800～4000 字。',
                zhCN: '默认 1600。这是上限，不是要求写满；可设置 800～4000 字。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      en: 'RP live summary recall',
                      zhTW: 'RP 動態摘要注入段數',
                      zhCN: 'RP 动态摘要注入段数',
                    ),
                    style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                  ),
                ),
                DropdownButton<int>(
                  value: _rpDynamicSummarySegments,
                  underline: const SizedBox(),
                  dropdownColor: YanciTheme.isDark
                      ? const Color(0xF0302830)
                      : Colors.white,
                  style: YanciTheme.bodyText.copyWith(
                    fontSize: 12,
                    color: YanciTheme.accent,
                  ),
                  items: List<DropdownMenuItem<int>>.generate(
                    4,
                    (index) => DropdownMenuItem<int>(
                      value: index + 1,
                      child: Text('${index + 1}'),
                    ),
                  ),
                  onChanged: _rpDynamicSummarySegments == null
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _rpDynamicSummarySegments = value);
                          MemorySettings.saveRpDynamicSummarySegments(value);
                        },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              L.pick(
                en: 'Default 1. Only event-matched summary segments are injected; chapter continuation is unaffected.',
                zhTW: '預設 1 段。只注入命中事件的摘要段落，不影響續寫篇章的完整摘要銜接。',
                zhCN: '默认 1 段。只注入命中事件的摘要段落，不影响续写篇章的完整摘要衔接。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 10),
            _buildCharacterBudgetField(
              label: L.pick(
                en: 'Live RP summary budget',
                zhTW: 'RP 動態摘要總注入上限',
                zhCN: 'RP 动态摘要总注入上限',
              ),
              future: MemorySettings.getRpDynamicSummaryMaxChars(),
              defaultValue: 1400,
              min: 600,
              max: 4000,
              onChanged: MemorySettings.saveRpDynamicSummaryMaxChars,
            ),
            const SizedBox(height: 8),
            _buildCharacterBudgetField(
              label: L.pick(
                en: 'Chapter handoff summary budget',
                zhTW: '續接篇章摘要總注入上限',
                zhCN: '续接篇章摘要总注入上限',
              ),
              future: MemorySettings.getRpContinuationSummaryMaxChars(),
              defaultValue: 2400,
              min: 1000,
              max: 6000,
              onChanged: MemorySettings.saveRpContinuationSummaryMaxChars,
            ),
            const SizedBox(height: 10),
            if (widget.showAdvancedMemoryOptions) ...[
              Divider(
                height: 1,
                color: YanciTheme.textSecondary.withValues(alpha: 0.12),
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'Vector recall model',
                  zhTW: '向量召回模型',
                  zhCN: '向量召回模型',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 11,
                  color: YanciTheme.textSecondary,
                ),
              ),
              _buildEmbeddingModelPicker(),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCharacterBudgetField({
    required String label,
    required Future<int> future,
    required int defaultValue,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return FutureBuilder<int>(
      future: future,
      builder: (context, snapshot) {
        final value = snapshot.data ?? defaultValue;
        return Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: YanciTheme.bodySmall.copyWith(fontSize: 11),
              ),
            ),
            SizedBox(
              width: 92,
              child: TextFormField(
                key: ValueKey<String>('summary-budget-$label-$value'),
                initialValue: '$value',
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: YanciTheme.bodyText.copyWith(
                  fontSize: 12,
                  color: YanciTheme.accent,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  suffixText: L.pick(en: 'chars', zhTW: '字', zhCN: '字'),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 5,
                    horizontal: 6,
                  ),
                  border: _thinInputBorder(),
                  enabledBorder: _thinInputBorder(),
                  focusedBorder: _thinInputBorder(
                    color: YanciTheme.accent.withValues(alpha: 0.85),
                    width: 1,
                  ),
                ),
                onChanged: (text) {
                  final parsed = int.tryParse(text);
                  if (parsed != null && parsed >= min && parsed <= max) {
                    onChanged(parsed);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmbeddingModelPicker() {
    final options = _embeddingModelOptions();
    final selected = _summarySelectionValue(
      widget.embeddingProvider,
      widget.embeddingModel,
    );
    final selectedValue =
        options.any(
          (option) =>
              _summarySelectionValue(option.provider, option.model) == selected,
        )
        ? selected
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<String>(
          value: selectedValue,
          isExpanded: true,
          underline: const SizedBox(),
          dropdownColor: YanciTheme.isDark
              ? const Color(0xF0302830)
              : Colors.white,
          style: YanciTheme.bodyText.copyWith(fontSize: 12),
          items: options
              .map((option) {
                final value = _summarySelectionValue(
                  option.provider,
                  option.model,
                );
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(
                    option.model.isEmpty
                        ? L.pick(
                            en: 'Off · trigram only',
                            zhTW: '關閉 · 僅使用 trigram',
                            zhCN: '关闭 · 仅使用 trigram',
                          )
                        : '${_providerLabel(option.provider)} · ${option.model}',
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
              })
              .toList(growable: false),
          onChanged: (value) {
            if (value == null || value.isEmpty) {
              widget.onEmbeddingSelectionChanged('', '');
              return;
            }
            final separator = value.indexOf(_summarySelectionSeparator);
            if (separator < 1) return;
            widget.onEmbeddingSelectionChanged(
              value.substring(0, separator),
              value.substring(separator + 1),
            );
          },
        ),
        Text(
          L.pick(
            en: 'Only models containing "embedding" are listed. Enabling this adds embedding API usage; vector results are merged with trigram recall.',
            zhTW:
                '僅顯示名稱含 embedding 的模型。啟用後會增加 embedding API 用量，向量結果會與 trigram 召回合併。',
            zhCN:
                '仅显示名称含 embedding 的模型。启用后会增加 embedding API 用量，向量结果会与 trigram 召回合并。',
          ),
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10,
            color: YanciTheme.textSecondary.withValues(alpha: 0.65),
          ),
        ),
      ],
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
        if (widget.showDreamCuration) ...[
          const SizedBox(height: YanciTheme.spacingSm),
          _buildDreamCurationCard(),
        ],
      ],
    );
  }
}
