import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/context_mode.dart';
import '../../services/context_compressor.dart';
import '../../services/locale_strings.dart';
import '../../services/model_cost_policy.dart';
import '../../services/settings_manager.dart';
import '../../services/token_estimator.dart';
import '../../theme/app_theme.dart';
import '../api_advanced_settings.dart' show KeepAliveGuard;
import 'sidebar_accordion.dart';
import 'sidebar_visual_tokens.dart';

class SidebarBehaviorSettings extends StatefulWidget {
  const SidebarBehaviorSettings({super.key});

  @override
  State<SidebarBehaviorSettings> createState() =>
      _SidebarBehaviorSettingsState();
}

class _SidebarBehaviorSettingsState extends State<SidebarBehaviorSettings> {
  final TextEditingController _worldbookIntervalController =
      TextEditingController(text: '4');
  bool? _worldbookEnabled;
  bool? _webSearchEnabled;
  bool? _contextLimitEnabled;
  int _contextMessageLimit = 20;
  bool _contextSummaryEnabled = false;
  int _contextSummaryTrigger = 18;
  bool? _cacheEnabled;
  bool _cacheSummaryEnabled = false;
  int _cacheSummaryTrigger = MemorySettings.defaultCacheSummaryTriggerMessages;
  bool _hasSummaryModel = false;
  KeepAliveGuard? _keepAliveGuard;
  int _keepAliveHours = 2;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final results = await Future.wait<Object>([
      MemorySettings.getRpWorldbookAutoWriteEnabled(),
      MemorySettings.getRpWorldbookSummaryInterval(),
      WebSearchSettings.getEnabled(),
      MemorySettings.getContextLimitEnabled(),
      MemorySettings.getContextMessageLimit(),
      MemorySettings.getContextWindowSummaryEnabled(),
      MemorySettings.getContextSummaryTriggerMessages(),
      MemorySettings.getEnablePromptCaching(),
      MemorySettings.getCacheWindowSummaryEnabled(),
      MemorySettings.getCacheSummaryTriggerMessages(),
      MemorySettings.getSummaryModel(),
      _loadKeepAliveGuard(),
      MemorySettings.getKeepAliveDurationHours(),
    ]);
    if (!mounted) return;
    setState(() {
      _worldbookEnabled = results[0] as bool;
      _worldbookIntervalController.text = '${results[1] as int}';
      _webSearchEnabled = results[2] as bool;
      _contextLimitEnabled = results[3] as bool;
      _contextMessageLimit = results[4] as int;
      _contextSummaryEnabled = results[5] as bool;
      _contextSummaryTrigger = results[6] as int;
      _cacheEnabled = results[7] as bool;
      _cacheSummaryEnabled = results[8] as bool;
      _cacheSummaryTrigger = results[9] as int;
      _hasSummaryModel = (results[10] as String).trim().isNotEmpty;
      _keepAliveGuard = results[11] as KeepAliveGuard;
      _keepAliveHours = results[12] as int;
    });
  }

  Future<void> _refreshKeepAliveGuard() async {
    final guard = await _loadKeepAliveGuard();
    if (!mounted) return;
    setState(() => _keepAliveGuard = guard);
  }

  @override
  void dispose() {
    _worldbookIntervalController.dispose();
    super.dispose();
  }

  Widget _compactSwitch({
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Transform.scale(
      scale: 0.78,
      alignment: Alignment.centerRight,
      child: Switch.adaptive(value: value, onChanged: onChanged),
    );
  }

  Future<void> _showHelp({required String title, required String body}) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(L.pick(en: 'Got it', zhTW: '知道了', zhCN: '知道了')),
          ),
        ],
      ),
    );
  }

  Widget _helpButton({required String title, required String body}) {
    return IconButton(
      tooltip: L.pick(en: 'About $title', zhTW: '關於$title', zhCN: '关于$title'),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      onPressed: () => unawaited(_showHelp(title: title, body: body)),
      icon: Icon(
        Icons.help_outline_rounded,
        size: 17,
        color: SidebarVisualTokens.secondary.withValues(alpha: 0.76),
      ),
    );
  }

  Widget _headerActions({
    required String title,
    required String help,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _helpButton(title: title, body: help),
        _compactSwitch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _inlineSwitchRow({
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Expanded(child: Text(title)),
        trailing ?? const SizedBox.shrink(),
        _compactSwitch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _buildWorldbook() {
    // UI_SLOT: sidebar_worldbook_auto
    final title = L.pick(
      en: 'Automatic worldbook',
      zhTW: '世界書自動整理',
      zhCN: '世界书自动整理',
    );
    return SidebarAccordionSection(
      id: 'worldbook_auto',
      relationGroup: 'memory_behavior',
      title: Text(title),
      initiallyExpanded: _worldbookEnabled ?? false,
      showChevron: false,
      trailing: _headerActions(
        title: title,
        help: L.pick(
          en: 'After the configured number of RP summaries, Holt uses the summary model in a separate pass to maintain durable world settings.',
          zhTW: '累積指定數量的 RP 摘要後，Holt 會以獨立模型請求整理耐久世界設定。',
          zhCN: '累积指定数量的 RP 摘要后，Holt 会以独立模型请求整理耐久世界设定。',
        ),
        value: _worldbookEnabled ?? false,
        onChanged: _worldbookEnabled == null
            ? null
            : (value) {
                setState(() => _worldbookEnabled = value);
                unawaited(
                  MemorySettings.saveRpWorldbookAutoWriteEnabled(value),
                );
              },
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (_worldbookEnabled ?? true)
          _CommittedCountField(
            value: int.tryParse(_worldbookIntervalController.text) ?? 4,
            suffix: '',
            width: double.infinity,
            labelText: L.pick(
              en: 'Process every N RP summaries',
              zhTW: '每累積幾個 RP 摘要整理一次',
              zhCN: '每累积几个 RP 摘要整理一次',
            ),
            onCommit: (value) async {
              await MemorySettings.saveRpWorldbookSummaryInterval(value);
              if (!mounted) return;
              setState(() => _worldbookIntervalController.text = '$value');
            },
          ),
      ],
    );
  }

  Future<KeepAliveGuard> _loadKeepAliveGuard() async {
    final cacheOn = await MemorySettings.getEnablePromptCaching();
    final enabled = await MemorySettings.getKeepAliveEnabled();
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    return KeepAliveGuard(
      cacheOn: cacheOn,
      supports: TokenEstimator.supportsCloseWindowKeepAlive(
        provider: provider,
        model: model,
      ),
      enabled: enabled,
    );
  }

  Future<void> _showCustomSummaryRules() async {
    var selectedMode = ContextMode.daily;
    final dailyController = TextEditingController(
      text: await MemorySettings.getSummaryCustomRules(contextMode: 'daily'),
    );
    final rpController = TextEditingController(
      text: await MemorySettings.getSummaryCustomRules(contextMode: 'rp'),
    );
    if (!mounted) {
      dailyController.dispose();
      rpController.dispose();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final controller = selectedMode == ContextMode.rp
              ? rpController
              : dailyController;
          final baseTokens = TokenEstimator.estimate(
            ContextCompressor.compressionPromptForMode(selectedMode),
          );
          final customTokens = TokenEstimator.estimate(controller.text);
          return AlertDialog(
            title: Text(
              L.pick(
                en: 'Custom summary preferences',
                zhTW: '自定義摘要偏好',
                zhCN: '自定义摘要偏好',
              ),
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<ContextMode>(
                    segments: [
                      ButtonSegment(
                        value: ContextMode.daily,
                        label: Text(
                          L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常'),
                        ),
                      ),
                      const ButtonSegment(
                        value: ContextMode.rp,
                        label: Text('RP'),
                      ),
                    ],
                    selected: {selectedMode},
                    onSelectionChanged: (selection) =>
                        setDialogState(() => selectedMode = selection.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: ValueKey<String>(
                      'sidebar_summary_rules_${selectedMode.storageValue}',
                    ),
                    controller: controller,
                    minLines: 5,
                    maxLines: 10,
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      L.pick(
                        en: 'Built-in prompt ≈ $baseTokens tokens · Custom ≈ $customTokens tokens',
                        zhTW:
                            '內建 Prompt 約 $baseTokens tokens · 自定義約 $customTokens tokens',
                        zhCN:
                            '内置 Prompt 约 $baseTokens tokens · 自定义约 $customTokens tokens',
                      ),
                      style: YanciTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(L.get('cancel')),
              ),
              TextButton(
                onPressed: () async {
                  await MemorySettings.saveSummaryCustomRules(
                    contextMode: 'daily',
                    value: dailyController.text,
                  );
                  await MemorySettings.saveSummaryCustomRules(
                    contextMode: 'rp',
                    value: rpController.text,
                  );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: Text(L.get('save')),
              ),
            ],
          );
        },
      ),
    );
    dailyController.dispose();
    rpController.dispose();
  }

  Widget _countField({
    required int value,
    required String suffix,
    required Future<void> Function(int) onChanged,
  }) {
    return _CommittedCountField(
      value: value,
      suffix: suffix,
      onCommit: onChanged,
    );
  }

  Widget _buildContextLimit() {
    // UI_SLOT: sidebar_context_limit
    final enabled = _contextLimitEnabled ?? false;
    final title = L.pick(
      en: 'Context send limit',
      zhTW: '上下文發送限制',
      zhCN: '上下文发送限制',
    );
    return SidebarAccordionSection(
      id: 'context_limit',
      relationGroup: 'cost_behavior',
      exclusiveWithinGroup: true,
      title: Text(title),
      initiallyExpanded: enabled,
      showChevron: false,
      trailing: _headerActions(
        title: title,
        help: L.pick(
          en: 'Only the latest configured number of messages is sent. It is mutually exclusive with prompt caching.',
          zhTW: '只發送最近指定條數的消息，並與緩存命中互斥。',
          zhCN: '只发送最近指定条数的消息，并与缓存命中互斥。',
        ),
        value: enabled,
        onChanged: _contextLimitEnabled == null
            ? null
            : (value) async {
                setState(() {
                  _contextLimitEnabled = value;
                  _contextSummaryEnabled = value && _hasSummaryModel;
                  if (value) {
                    _cacheEnabled = false;
                    _cacheSummaryEnabled = false;
                  }
                });
                await ModelCostPolicy.setContextLimitEnabled(value);
                await _refreshKeepAliveGuard();
              },
      ),
      children: [
        if (enabled) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Messages sent', zhTW: '上下文發送條數', zhCN: '上下文发送条数'),
                ),
              ),
              _countField(
                value: _contextMessageLimit,
                suffix: L.pick(en: '', zhTW: '條', zhCN: '条'),
                onChanged: (value) async {
                  await MemorySettings.saveContextMessageLimit(value);
                  if (mounted) {
                    setState(() => _contextMessageLimit = value);
                  }
                },
              ),
            ],
          ),
          _inlineSwitchRow(
            title: L.pick(
              en: 'Context summary',
              zhTW: '上下文專用摘要',
              zhCN: '上下文专用摘要',
            ),
            value: _hasSummaryModel && _contextSummaryEnabled,
            onChanged: !_hasSummaryModel
                ? null
                : (value) async {
                    setState(() => _contextSummaryEnabled = value);
                    await MemorySettings.saveContextWindowSummaryEnabled(value);
                  },
          ),
          if (!_hasSummaryModel)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                L.pick(
                  en: 'Choose a summary model first.',
                  zhTW: '請先選擇摘要模型。',
                  zhCN: '请先选择摘要模型。',
                ),
              ),
            ),
          if (_hasSummaryModel && _contextSummaryEnabled) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      en: 'Summary trigger',
                      zhTW: '摘要觸發上限',
                      zhCN: '摘要触发上限',
                    ),
                  ),
                ),
                _countField(
                  value: _contextSummaryTrigger,
                  suffix: L.pick(en: '', zhTW: '條', zhCN: '条'),
                  onChanged: (value) async {
                    await MemorySettings.saveContextSummaryTriggerMessages(
                      value,
                    );
                    if (mounted) {
                      setState(() => _contextSummaryTrigger = value);
                    }
                  },
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _showCustomSummaryRules,
                child: Text(
                  L.pick(
                    en: 'Custom summary preferences',
                    zhTW: '自定義摘要偏好',
                    zhCN: '自定义摘要偏好',
                  ),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildCacheSettings() {
    // UI_SLOT: sidebar_cache_settings
    final enabled = _cacheEnabled ?? false;
    final keepAlive = _keepAliveGuard;
    final title = L.pick(en: 'Cache hit', zhTW: '緩存命中', zhCN: '缓存命中');
    return SidebarAccordionSection(
      id: 'cache_settings',
      relationGroup: 'cost_behavior',
      exclusiveWithinGroup: true,
      title: Text(title),
      initiallyExpanded: enabled,
      showChevron: false,
      trailing: _headerActions(
        title: title,
        help: L.pick(
          en: 'Keeps a stable prompt prefix for supported models. It is mutually exclusive with the context send limit.',
          zhTW: '為支援的模型維持穩定提示詞前綴，並與上下文發送限制互斥。',
          zhCN: '为支持的模型维持稳定提示词前缀，并与上下文发送限制互斥。',
        ),
        value: enabled,
        onChanged: _cacheEnabled == null
            ? null
            : (value) async {
                setState(() {
                  _cacheEnabled = value;
                  _cacheSummaryEnabled = value && _hasSummaryModel;
                  if (value) {
                    _contextLimitEnabled = false;
                    _contextSummaryEnabled = false;
                  }
                });
                await ModelCostPolicy.setPromptCachingEnabled(value);
                await _refreshKeepAliveGuard();
              },
      ),
      children: [
        if (enabled) ...[
          _inlineSwitchRow(
            title: L.pick(en: 'Dedicated summary', zhTW: '專用摘要', zhCN: '专用摘要'),
            value: _hasSummaryModel && _cacheSummaryEnabled,
            onChanged: !_hasSummaryModel
                ? null
                : (value) async {
                    setState(() => _cacheSummaryEnabled = value);
                    await MemorySettings.saveCacheWindowSummaryEnabled(value);
                  },
          ),
          if (!_hasSummaryModel)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                L.pick(
                  en: 'Choose a summary model first.',
                  zhTW: '請先選擇摘要模型。',
                  zhCN: '请先选择摘要模型。',
                ),
              ),
            ),
          if (_hasSummaryModel && _cacheSummaryEnabled) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      en: 'Summary trigger',
                      zhTW: '摘要觸發上限',
                      zhCN: '摘要触发上限',
                    ),
                  ),
                ),
                _countField(
                  value: _cacheSummaryTrigger,
                  suffix: L.pick(en: '', zhTW: '條', zhCN: '条'),
                  onChanged: (value) async {
                    await MemorySettings.saveCacheSummaryTriggerMessages(value);
                    if (mounted) {
                      setState(() => _cacheSummaryTrigger = value);
                    }
                  },
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _showCustomSummaryRules,
                child: Text(
                  L.pick(
                    en: 'Custom summary preferences',
                    zhTW: '自定義摘要偏好',
                    zhCN: '自定义摘要偏好',
                  ),
                ),
              ),
            ),
          ],
          _inlineSwitchRow(
            title: L.pick(en: 'Automatic renewal', zhTW: '自動延續', zhCN: '自动延续'),
            value: keepAlive?.enabled ?? false,
            onChanged: (keepAlive?.canEnable ?? false)
                ? (value) async {
                    await MemorySettings.saveKeepAliveEnabled(value);
                    await _refreshKeepAliveGuard();
                  }
                : null,
            trailing: (keepAlive?.enabled ?? false)
                ? DropdownButton<int>(
                    value: _keepAliveHours.clamp(1, 12),
                    underline: const SizedBox.shrink(),
                    items: const [1, 2, 4, 6, 8, 12]
                        .map(
                          (hours) => DropdownMenuItem<int>(
                            value: hours,
                            child: Text('${hours}h'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (hours) async {
                      if (hours == null) return;
                      setState(() => _keepAliveHours = hours);
                      await MemorySettings.saveKeepAliveDurationHours(hours);
                    },
                  )
                : null,
          ),
          if (!(keepAlive?.canEnable ?? false) && keepAlive != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(keepAlive.hintText()),
            ),
        ],
      ],
    );
  }

  Widget _buildWebSearch() {
    // UI_SLOT: sidebar_web_search
    final title = L.pick(en: 'Web search', zhTW: '網路搜尋', zhCN: '网络搜索');
    return SidebarAccordionSection(
      id: 'web_search',
      relationGroup: 'web_search',
      title: Text(title),
      showChevron: false,
      trailing: _headerActions(
        title: title,
        help: L.pick(
          en: 'Allows supported providers to retrieve current public web information. Configure the search model under Other functional models.',
          zhTW: '允許支援的來源取得即時公開網路資訊；搜尋模型請至「其他功能模型設定」選擇。',
          zhCN: '允许支持的来源取得实时公开网络信息；搜索模型请至“其他功能模型设置”选择。',
        ),
        value: _webSearchEnabled ?? false,
        onChanged: _webSearchEnabled == null || !webSearchLiveFeatureEnabled
            ? null
            : (value) {
                setState(() => _webSearchEnabled = value);
                unawaited(WebSearchSettings.saveEnabled(value));
              },
      ),
      children: const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildContextLimit(),
        _buildCacheSettings(),
        _buildWorldbook(),
        _buildWebSearch(),
      ],
    );
  }
}

/// Commits a numeric setting once when editing ends. Saving every keystroke
/// made values such as "18" race through "1" and "18", so an older async
/// write could win and leave the summary cadence apparently random.
class _CommittedCountField extends StatefulWidget {
  const _CommittedCountField({
    required this.value,
    required this.suffix,
    required this.onCommit,
    this.width = 88,
    this.labelText,
  });

  final int value;
  final String suffix;
  final Future<void> Function(int value) onCommit;
  final double width;
  final String? labelText;

  @override
  State<_CommittedCountField> createState() => _CommittedCountFieldState();
}

class _CommittedCountFieldState extends State<_CommittedCountField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _saving = false;
  int? _lastCommitted;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
    _lastCommitted = widget.value;
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) unawaited(_commit());
  }

  @override
  void didUpdateWidget(covariant _CommittedCountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving && oldWidget.value != widget.value) {
      _controller.text = '${widget.value}';
      _lastCommitted = widget.value;
    }
  }

  Future<void> _commit() async {
    if (_saving) return;
    final value = int.tryParse(_controller.text.trim());
    if (value == null) {
      _controller.text = '${widget.value}';
      return;
    }
    if (value == _lastCommitted) return;
    _saving = true;
    try {
      await widget.onCommit(value);
      _lastCommitted = value;
    } finally {
      if (mounted) _saving = false;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextFormField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        textAlign: TextAlign.center,
        onTapOutside: (_) {
          FocusManager.instance.primaryFocus?.unfocus();
          unawaited(_commit());
        },
        onFieldSubmitted: (_) {
          FocusManager.instance.primaryFocus?.unfocus();
          unawaited(_commit());
        },
        decoration: InputDecoration(
          suffixText: widget.suffix,
          labelText: widget.labelText,
          border: InputBorder.none,
        ),
      ),
    );
  }
}
