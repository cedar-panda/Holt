import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/context_mode.dart';
import '../services/context_compressor.dart';
import '../services/locale_strings.dart';
import '../services/model_cost_policy.dart';
import '../services/settings_manager.dart';
import '../services/static_token_estimator.dart';
import '../services/token_estimator.dart';

class KeepAliveGuard {
  final bool cacheOn;
  final bool supports;
  final bool enabled;
  KeepAliveGuard({
    required this.cacheOn,
    required this.supports,
    required this.enabled,
  });
  bool get canEnable => cacheOn && supports;
  String hintText() {
    if (!cacheOn) {
      return L.pick(en: 'Enable prompt caching first', zhTW: '請先開啟上方「提示詞快取」');
    }
    if (!supports) {
      return L.pick(
        en: 'Current model does not support 1h TTL',
        zhTW: '當前模型沒有確認的 1h TTL 支援',
      );
    }
    return '';
  }
}

class _AdvancedCommittedIntField extends StatefulWidget {
  const _AdvancedCommittedIntField({
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onCommit,
  });

  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int> onCommit;

  @override
  State<_AdvancedCommittedIntField> createState() =>
      _AdvancedCommittedIntFieldState();
}

class _AdvancedCommittedIntFieldState
    extends State<_AdvancedCommittedIntField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(covariant _AdvancedCommittedIntField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = '${widget.value}';
      return;
    }
    widget.onCommit(parsed.clamp(widget.min, widget.max).toInt());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      textAlign: TextAlign.center,
      style: YanciTheme.bodyText.copyWith(
        fontSize: 14,
        color: YanciTheme.accent,
      ),
      decoration: InputDecoration(
        isDense: true,
        suffixText: widget.suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
      onTapOutside: (_) {
        _commit();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      onSubmitted: (_) {
        _commit();
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );
  }
}

class ApiAdvancedSettings extends StatefulWidget {
  final bool cacheOnly;
  final bool showCacheSection;
  final bool showKeepAliveSection;
  final bool showContextSection;
  final bool showCacheMasterToggle;

  const ApiAdvancedSettings({
    super.key,
    this.cacheOnly = false,
    this.showCacheSection = true,
    this.showKeepAliveSection = true,
    this.showContextSection = true,
    this.showCacheMasterToggle = true,
  });

  @override
  State<ApiAdvancedSettings> createState() => _ApiAdvancedSettingsState();
}

class _ApiAdvancedSettingsState extends State<ApiAdvancedSettings> {
  bool _showCacheSection = false;
  bool _showKeepAliveSection = false;
  bool _showContextSection = false;

  Future<void> _showCustomSummaryRulesDialog({required String entryKey}) async {
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
          final basePrompt = ContextCompressor.compressionPromptForMode(
            selectedMode,
          );
          final baseTokens = TokenEstimator.estimate(basePrompt);
          final customTokens = TokenEstimator.estimate(controller.text);
          return AlertDialog(
            key: ValueKey('custom_summary_rules_dialog_$entryKey'),
            backgroundColor: YanciTheme.surfacePanel,
            title: Text(
              L.pick(
                en: 'Custom summary preferences',
                zhTW: '自定義摘要偏好',
                zhCN: '自定义摘要偏好',
              ),
              style: YanciTheme.headingMedium.copyWith(fontSize: 16),
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    onSelectionChanged: (value) =>
                        setDialogState(() => selectedMode = value.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: ValueKey(
                      selectedMode == ContextMode.rp
                          ? 'custom_summary_rules_rp_field'
                          : 'custom_summary_rules_daily_field',
                    ),
                    controller: controller,
                    minLines: 5,
                    maxLines: 9,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      hintText: L.pick(
                        en: 'Optional. Describe what the summary should pay more attention to.',
                        zhTW: '選填。描述摘要需要額外關注的內容。',
                        zhCN: '选填。描述摘要需要额外关注的内容。',
                      ),
                      border: _thinInputBorder(),
                      enabledBorder: _thinInputBorder(),
                      focusedBorder: _thinInputBorder(
                        color: YanciTheme.accent,
                        width: 1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    L.pick(
                      en: 'Estimated prompt: ~$baseTokens base + $customTokens custom tokens. Required JSON, source range, storyline isolation and factual rules cannot be overridden.',
                      zhTW:
                          '預估 Prompt：約 $baseTokens 基礎 + $customTokens 自定義 tokens。必要 JSON、來源範圍、故事線隔離與事實規則不可覆蓋。',
                      zhCN:
                          '预估 Prompt：约 $baseTokens 基础 + $customTokens 自定义 tokens。必要 JSON、来源范围、故事线隔离与事实规则不可覆盖。',
                    ),
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: 10,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
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
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
              ),
            ],
          );
        },
      ),
    );
    dailyController.dispose();
    rpController.dispose();
  }

  Widget _buildCustomSummaryRulesEntry(String entryKey) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        key: ValueKey('custom_summary_rules_entry_$entryKey'),
        borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        onTap: () => _showCustomSummaryRulesDialog(entryKey: entryKey),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
          child: Row(
            children: [
              Icon(
                Icons.edit_note_rounded,
                size: 17,
                color: YanciTheme.accent.withValues(alpha: 0.78),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  L.pick(
                    en: 'Custom summary preferences · Daily / RP',
                    zhTW: '自定義摘要偏好 · 日常 / RP',
                    zhCN: '自定义摘要偏好 · 日常 / RP',
                  ),
                  style: YanciTheme.bodySmall.copyWith(fontSize: 12),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 17,
                color: YanciTheme.textSecondary.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<KeepAliveGuard> _loadKeepAliveGuard() async {
    final cacheOn = await MemorySettings.getEnablePromptCaching();
    final enabled = await MemorySettings.getKeepAliveEnabled();
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    final supports = TokenEstimator.supportsCloseWindowKeepAlive(
      provider: provider,
      model: model,
    );
    return KeepAliveGuard(
      cacheOn: cacheOn,
      supports: supports,
      enabled: enabled,
    );
  }

  Future<void> _handlePromptCachingChanged(bool v) async {
    if (v) {
      final provider = await ApiSettings.getApiProvider();
      final inklingKey = provider == 'thinking_machines'
          ? await ApiSettings.getThinkingMachinesApiKey()
          : '';
      if (inklingKey.trim().isNotEmpty) {
        await ModelCostPolicy.applySelection(
          provider: provider,
          model: await ApiSettings.getModelForProvider(provider),
          apiKey: inklingKey,
        );
        // Inkling cannot use prompt cache.  The safe fallback is the
        // mutually-exclusive context limit, so the user's cache tap still
        // leaves them with a usable cost-control mode instead of silently
        // turning every protection off.
        if (!await MemorySettings.getContextLimitEnabled()) {
          await ModelCostPolicy.setContextLimitEnabled(true);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(
                en: 'Inkling does not use prompt cache. Cache and its summary remain off; use context send limit to control costs.',
                zhTW: 'Inkling 不使用提示詞緩存；緩存及其專用摘要已保持關閉，請用上下文發送限制控制費用。',
                zhCN: 'Inkling 不使用提示词缓存；缓存及其专用摘要已保持关闭，请用上下文发送限制控制费用。',
              ),
            ),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
          ),
        );
        setState(() {});
        return;
      }
    }
    await ModelCostPolicy.setPromptCachingEnabled(v);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _handleContextLimitChanged(bool v, int currentLimit) async {
    await ModelCostPolicy.setContextLimitEnabled(v);
    if (!mounted) return;
    setState(() {});
  }

  Widget _buildGlassCard({required Widget child, bool bordered = true}) {
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

  Color get _settingsBorderColor => Color.lerp(
    YanciTheme.textSecondary,
    YanciTheme.accent,
    YanciTheme.isDark ? 0.38 : 0.28,
  )!.withValues(alpha: 0.82);

  Widget _buildFadeDivider() {
    return SizedBox(
      height: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _settingsBorderColor.withValues(alpha: 0),
              _settingsBorderColor.withValues(alpha: 0.72),
              _settingsBorderColor.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }

  OutlineInputBorder _thinInputBorder({Color? color, double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      borderSide: BorderSide.none,
    );
  }

  Widget _buildSummaryTriggerEditor(
    int summaryTrigger, {
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              L.pick(en: 'Trigger after', zhTW: '累積至', zhCN: '累积至'),
              style: YanciTheme.bodySmall.copyWith(fontSize: 12),
            ),
            const Spacer(),
            SizedBox(
              width: 92,
              child: _AdvancedCommittedIntField(
                value: summaryTrigger,
                min: 2,
                max: 200,
                suffix: L.pick(en: '', zhTW: '條', zhCN: '条'),
                onCommit: onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          L.pick(
            en: 'A summary runs after this many complete unsummarized messages.',
            zhTW: '未摘要內容累積到此消息條數後觸發，消息不會被拆開。',
            zhCN: '未摘要内容累积到此消息条数后触发，消息不会被拆开。',
          ),
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10,
            color: YanciTheme.textSecondary.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }

  Widget _buildCollapsibleTitle(
    String title,
    bool isExpanded,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(
              title,
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: YanciTheme.textSecondary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsibleBody({
    required bool expanded,
    required Widget child,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: expanded ? 1 : 0),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, progress, stableChild) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: progress,
          child: ExcludeSemantics(
            excluding: !expanded,
            child: IgnorePointer(
              ignoring: !expanded,
              child: Opacity(opacity: progress, child: stableChild),
            ),
          ),
        ),
      ),
    );
  }

  /// Green remains the semantic "enabled" cue, while the accent tint keeps
  /// the checkbox coherent across the available theme presets.
  Color get _checkColor =>
      Color.lerp(const Color(0xFF4CAF6A), YanciTheme.accent, 0.28)!;

  Widget _buildCheckBox({
    required bool value,
    required ValueChanged<bool?>? onChanged,
  }) {
    return Checkbox(
      value: value,
      onChanged: onChanged,
      activeColor: _checkColor,
      checkColor: Colors.white,
      side: BorderSide(
        color: YanciTheme.textSecondary.withValues(alpha: 0.56),
        width: 1.5,
      ),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildCheckOption({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool?>? onChanged,
    double indent = 0,
    String? leadingMarker,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leadingMarker != null) ...[
            ExcludeSemantics(
              child: SizedBox(
                height: 40,
                child: Center(
                  child: Text(
                    leadingMarker,
                    style: YanciTheme.bodyText.copyWith(fontSize: 13),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          _buildCheckBox(value: value, onChanged: onChanged),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style:
                        (widget.cacheOnly
                                ? YanciTheme.bodySmall
                                : YanciTheme.bodyText)
                            .copyWith(fontSize: widget.cacheOnly ? 11.5 : 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: widget.cacheOnly ? 10.5 : 11,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHourPicker({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 12,
            color: YanciTheme.textSecondary.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => onChanged((value - 1) % 24),
          child: Icon(
            Icons.remove_circle_outline,
            size: 20,
            color: YanciTheme.textSecondary.withValues(alpha: 0.4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${value.toString().padLeft(2, '0')}:00',
            style: TextStyle(
              fontSize: 14,
              fontFamily: YanciTheme.fontFamily,
              fontWeight: FontWeight.w500,
              color: YanciTheme.accent,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => onChanged((value + 1) % 24),
          child: Icon(
            Icons.add_circle_outline,
            size: 20,
            color: YanciTheme.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  Widget _buildCacheCard() {
    return _buildGlassCard(
      bordered: !widget.cacheOnly,
      child: FutureBuilder<bool>(
        future: MemorySettings.getEnablePromptCaching(),
        builder: (ctx, cacheSnap) {
          final cacheOn = cacheSnap.data ?? false;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showCacheMasterToggle)
                _buildCheckOption(
                  title: L.get('settings_cache_on'),
                  description: L.get('settings_cache_hint'),
                  value: cacheOn,
                  onChanged: (value) =>
                      _handlePromptCachingChanged(value ?? false),
                ),
              if (cacheOn) ...[
                if (widget.showCacheMasterToggle) ...[
                  const SizedBox(height: 10),
                  _buildFadeDivider(),
                  const SizedBox(height: 8),
                ],
                FutureBuilder<List<dynamic>>(
                  future: Future.wait(<Future<dynamic>>[
                    MemorySettings.getCacheWindowSummaryEnabled(),
                    MemorySettings.getCacheSummaryTriggerMessages(),
                    MemorySettings.getSummaryModel(),
                  ]),
                  builder: (ctx, summarySnap) {
                    final summaryEnabled =
                        (summarySnap.data?[0] as bool?) ?? false;
                    final summaryTrigger =
                        (summarySnap.data?[1] as int?) ??
                        MemorySettings.defaultCacheSummaryTriggerMessages;
                    final hasSummaryModel =
                        ((summarySnap.data?[2] as String?) ?? '')
                            .trim()
                            .isNotEmpty;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCheckOption(
                          indent: 32,
                          leadingMarker: '—',
                          title: L.pick(
                            en: 'Dedicated window summary',
                            zhTW: '專用窗口摘要',
                            zhCN: '专用窗口摘要',
                          ),
                          description: !hasSummaryModel
                              ? L.pick(
                                  en: 'Choose a summary model first.',
                                  zhTW: '請先選擇摘要模型。',
                                  zhCN: '请先选择摘要模型。',
                                )
                              : L.pick(
                                  en: 'Pins a window summary into the cacheable prompt for new windows.',
                                  zhTW: '新窗口把窗口摘要釘入可緩存提示。',
                                  zhCN: '新窗口把窗口摘要钉入可缓存提示。',
                                ),
                          value: hasSummaryModel && summaryEnabled,
                          onChanged: !hasSummaryModel
                              ? null
                              : (value) {
                                  MemorySettings.saveCacheWindowSummaryEnabled(
                                    value ?? false,
                                  );
                                  setState(() {});
                                  StaticTokenEstimator.showAfterToggle(context);
                                },
                        ),
                        if (hasSummaryModel && summaryEnabled) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.only(left: 40),
                            child: _buildSummaryTriggerEditor(
                              summaryTrigger,
                              onChanged: (value) => unawaited(
                                MemorySettings.saveCacheSummaryTriggerMessages(
                                  value,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 32),
                            child: _buildCustomSummaryRulesEntry('cache'),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cacheOnly) return _buildCacheCard();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showCacheSection) ...[
          _buildCollapsibleTitle(
            L.get('settings_cache_title'),
            _showCacheSection,
            () => setState(() => _showCacheSection = !_showCacheSection),
          ),
          _buildCollapsibleBody(
            expanded: _showCacheSection,
            child: Padding(
              padding: const EdgeInsets.only(top: YanciTheme.spacingSm),
              child: _buildCacheCard(),
            ),
          ),
          const SizedBox(height: YanciTheme.spacingLg),
        ],

        if (widget.showKeepAliveSection) ...[
          _buildCollapsibleTitle(
            L.pick(en: 'Auto Cache Renewal', zhTW: '自動延續命中 (Keep-Alive Guard)'),
            _showKeepAliveSection,
            () =>
                setState(() => _showKeepAliveSection = !_showKeepAliveSection),
          ),
          _buildCollapsibleBody(
            expanded: _showKeepAliveSection,
            child: Padding(
              padding: const EdgeInsets.only(top: YanciTheme.spacingSm),
              child: _buildGlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.pick(
                                  en: 'Enable auto renewal',
                                  zhTW: '啟用自動延續',
                                ),
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                L.pick(
                                  en: 'Keeps cache alive by pinging every ~50 min. Incurs extra API cost.',
                                  zhTW: '開啟後會增加保持窗口緩存命中的費用，每50分鐘自動延續',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        FutureBuilder<KeepAliveGuard>(
                          future: _loadKeepAliveGuard(),
                          builder: (ctx, snap) {
                            final guard = snap.data;
                            final enabled = guard?.enabled ?? false;
                            final canEnable = guard?.canEnable ?? false;
                            return Switch(
                              value: enabled,
                              activeThumbColor: YanciTheme.accent,
                              onChanged: canEnable
                                  ? (v) async {
                                      await MemorySettings.saveKeepAliveEnabled(
                                        v,
                                      );
                                      if (mounted) setState(() {});
                                    }
                                  : null,
                            );
                          },
                        ),
                      ],
                    ),
                    FutureBuilder<KeepAliveGuard>(
                      future: _loadKeepAliveGuard(),
                      builder: (ctx, snap) {
                        final guard = snap.data;
                        final hint = guard == null ? '' : guard.hintText();
                        if (hint.isEmpty) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            hint,
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 11,
                              color: (guard?.canEnable ?? false)
                                  ? YanciTheme.textSecondary.withValues(
                                      alpha: 0.55,
                                    )
                                  : Colors.orange.withValues(alpha: 0.75),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      L.pick(en: 'Renewal duration (hours)', zhTW: '延續時長（小時）'),
                      style: YanciTheme.bodyText.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    FutureBuilder<int>(
                      future: MemorySettings.getKeepAliveDurationHours(),
                      builder: (ctx, snap) {
                        final hours = snap.data ?? 2;
                        return Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value: hours.toDouble(),
                                min: 1,
                                max: 12,
                                divisions: 11,
                                activeColor: YanciTheme.accent,
                                label: '${hours}h',
                                onChanged: (v) {
                                  MemorySettings.saveKeepAliveDurationHours(
                                    v.round(),
                                  );
                                  setState(() {});
                                },
                              ),
                            ),
                            SizedBox(
                              width: 36,
                              child: Text(
                                '${hours}h',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: YanciTheme.fontFamily,
                                  fontWeight: FontWeight.w500,
                                  color: YanciTheme.accent,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    Text(
                      L.pick(
                        en: 'How long to keep the last message\'s cache alive after leaving chat.',
                        zhTW: '離開聊天後，最後一條消息的緩存延續多久。',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 11,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      L.pick(
                        en: 'Quiet hours (no pings)',
                        zhTW: '安靜時段（不發延續請求）',
                      ),
                      style: YanciTheme.bodyText.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    FutureBuilder<List<int>>(
                      future: Future.wait([
                        MemorySettings.getQuietStartHour(),
                        MemorySettings.getQuietEndHour(),
                      ]),
                      builder: (ctx, snap) {
                        final start = snap.data?[0] ?? 23;
                        final end = snap.data?[1] ?? 7;
                        return Row(
                          children: [
                            _buildHourPicker(
                              label: L.pick(en: 'From', zhTW: '從'),
                              value: start,
                              onChanged: (v) {
                                MemorySettings.saveQuietStartHour(v);
                                setState(() {});
                              },
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Text(
                                '→',
                                style: TextStyle(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                              ),
                            ),
                            _buildHourPicker(
                              label: L.pick(en: 'To', zhTW: '至'),
                              value: end,
                              onChanged: (v) {
                                MemorySettings.saveQuietEndHour(v);
                                setState(() {});
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: YanciTheme.spacingLg),
        ],

        if (widget.showContextSection) ...[
          _buildCollapsibleTitle(
            L.get('settings_context_title'),
            _showContextSection,
            () => setState(() => _showContextSection = !_showContextSection),
          ),
          _buildCollapsibleBody(
            expanded: _showContextSection,
            child: Padding(
              padding: const EdgeInsets.only(top: YanciTheme.spacingSm),
              child: _buildGlassCard(
                bordered: false,
                child: FutureBuilder<List<dynamic>>(
                  future: Future.wait([
                    MemorySettings.getContextLimitEnabled(),
                    MemorySettings.getContextMessageLimit(),
                    MemorySettings.getContextWindowSummaryEnabled(),
                    MemorySettings.getContextSummaryTriggerMessages(),
                    MemorySettings.getEnablePromptCaching(),
                  ]),
                  builder: (ctx, snap) {
                    final storedEnabled = (snap.data?[0] as bool?) ?? false;
                    final limit =
                        (snap.data?[1] as int?) ??
                        MemorySettings.defaultContextMessageLimit;
                    final summaryEnabled = (snap.data?[2] as bool?) ?? false;
                    final summaryTrigger =
                        (snap.data?[3] as int?) ??
                        MemorySettings.defaultContextSummaryTriggerMessages;
                    final cacheOn = (snap.data?[4] as bool?) ?? false;
                    final enabled = storedEnabled && !cacheOn;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCheckOption(
                          title: L.get('settings_context_desc'),
                          description: L.get('settings_context_detail'),
                          value: enabled,
                          onChanged: cacheOn
                              ? null
                              : (v) => _handleContextLimitChanged(
                                  v ?? false,
                                  limit,
                                ),
                        ),
                        if (enabled) ...[
                          const SizedBox(height: 10),
                          _buildFadeDivider(),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Text(
                                L.pick(
                                  en: 'Messages sent',
                                  zhTW: '發送消息條數',
                                  zhCN: '发送消息条数',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              SizedBox(
                                width: 80,
                                child: _AdvancedCommittedIntField(
                                  value: limit,
                                  min: MemorySettings.minContextMessageLimit,
                                  max: MemorySettings.maxContextMessageLimit,
                                  suffix: L.pick(en: '', zhTW: '條', zhCN: '条'),
                                  onCommit: (value) => unawaited(
                                    MemorySettings.saveContextMessageLimit(
                                      value,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            L.pick(
                              en: 'The newest complete messages are sent. Turn off the switch to remove the limit.',
                              zhTW: '只送出最新的完整消息；關閉上方開關即可取消限制。',
                              zhCN: '只发送最新的完整消息；关闭上方开关即可取消限制。',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 10,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                        ],
                        if (cacheOn) ...[
                          const SizedBox(height: 4),
                          Text(
                            L.pick(
                              en: 'Turn off cache hits before using context send limit.',
                              zhTW: '已開啟緩存命中；需先關閉緩存命中才能使用上下文發送限制。',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 11,
                              color: Colors.orange.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                        if (enabled) ...[
                          const SizedBox(height: 10),
                          _buildFadeDivider(),
                          const SizedBox(height: 8),
                          _buildCheckOption(
                            indent: 32,
                            title: L.pick(
                              en: '— Dynamic window summary',
                              zhTW: '— 動態窗口摘要',
                            ),
                            description: L.pick(
                              en: 'For non-cache models. Sends recent summaries through dynamic context.',
                              zhTW: '給無緩存模型使用，摘要走動態上下文。',
                            ),
                            value: summaryEnabled,
                            onChanged: (v) {
                              MemorySettings.saveContextWindowSummaryEnabled(
                                v ?? false,
                              );
                              setState(() {});
                            },
                          ),
                        ],
                        if (enabled && summaryEnabled) ...[
                          const SizedBox(height: 10),
                          _buildSummaryTriggerEditor(
                            summaryTrigger,
                            onChanged: (value) => unawaited(
                              MemorySettings.saveContextSummaryTriggerMessages(
                                value,
                              ),
                            ),
                          ),
                          _buildCustomSummaryRulesEntry('context'),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
