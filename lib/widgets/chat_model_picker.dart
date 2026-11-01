import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/background_foreground_service.dart';
import '../services/reasoning_effort.dart';
import '../theme/app_theme.dart';

class ChatModelPickerEntry {
  final String id;
  final String label;
  final String provider;
  final String providerLabel;
  final bool isLocal;
  final bool isProviderConfigured;

  const ChatModelPickerEntry({
    required this.id,
    required this.label,
    required this.provider,
    required this.providerLabel,
    required this.isLocal,
    required this.isProviderConfigured,
  });
}

/// 模型選擇框的路由進出場。
///
/// 面板從頂部模型名稱的位置沿單一曲線向下展開，不超調、不回彈；關閉時
/// 由下往上裁切，同時向錨點收窄並輕微後仰。全程不依賴透明度。
class ChatModelPickerRouteTransition extends StatelessWidget {
  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  const ChatModelPickerRouteTransition({
    super.key,
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  // 路由仍以 220ms 完成生命週期，但收回的可見形變在前 58% 完成，
  // 約 128ms 後面板已完全收束，避免關閉拖沓。
  static const double _exitVisualFraction = 0.58;

  static final Animatable<double> _enterReveal = Tween<double>(
    begin: 0,
    end: 1,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _enterScaleX = Tween<double>(
    begin: 0.92,
    end: 1,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _enterOffsetY = Tween<double>(
    begin: -6,
    end: 0,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _enterAngle = Tween<double>(
    begin: -4,
    end: 0,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  static final Animatable<double> _exitReveal = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0.88,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.88,
        end: 0.50,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.50,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
  ]);

  static final Animatable<double> _exitScaleX = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0.97,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.97,
        end: 0.72,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0.72,
        end: 0.44,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
  ]);

  static final Animatable<double> _exitOffsetY = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: -2,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -2,
        end: -8,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -8,
        end: -18,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
  ]);

  static final Animatable<double> _exitAngle = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: -3,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -3,
        end: -10,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: -10,
        end: -19,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 35,
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) return child;

    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final isClosing = animation.status == AnimationStatus.reverse;
        final progress = isClosing
            ? ((1 - animation.value) / _exitVisualFraction).clamp(0.0, 1.0)
            : animation.value.clamp(0.0, 1.0);
        final reveal = isClosing
            ? _exitReveal.transform(progress)
            : _enterReveal.transform(progress);
        final scaleX = isClosing
            ? _exitScaleX.transform(progress)
            : _enterScaleX.transform(progress);
        final offsetY = isClosing
            ? _exitOffsetY.transform(progress)
            : _enterOffsetY.transform(progress);
        final angleDegrees = isClosing
            ? _exitAngle.transform(progress)
            : _enterAngle.transform(progress);
        final perspective = Matrix4.identity()
          ..setEntry(3, 2, 0.0011)
          ..rotateX(angleDegrees * math.pi / 180);
        final isInteractive = animation.status == AnimationStatus.completed;

        return IgnorePointer(
          ignoring: !isInteractive,
          child: ExcludeSemantics(
            excluding: !isInteractive,
            child: Transform.translate(
              offset: Offset(0, offsetY),
              child: Transform(
                alignment: Alignment.topCenter,
                transform: perspective,
                child: Transform(
                  alignment: Alignment.topCenter,
                  transform: Matrix4.diagonal3Values(scaleX, 1, 1),
                  child: ClipRect(
                    key: const ValueKey('chat-model-picker-transition-clip'),
                    child: Align(
                      alignment: Alignment.topCenter,
                      heightFactor: reveal,
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ChatModelPickerPanel extends StatefulWidget {
  final List<ChatModelPickerEntry> entries;
  final String currentModelId;
  final String currentProvider;
  final String initialReasoningEffort;
  final bool initialThinkingEnabled;
  final Color accentColor;
  final BackgroundForegroundPalette? backgroundPalette;
  final Future<void> Function(String effort) onReasoningEffortChanged;
  final Future<void> Function(bool enabled) onThinkingEnabledChanged;
  final Future<void> Function(ChatModelPickerEntry entry) onModelSelected;
  final ValueChanged<ChatModelPickerEntry> onUnavailableProviderSelected;
  final bool embedded;

  const ChatModelPickerPanel({
    super.key,
    required this.entries,
    required this.currentModelId,
    required this.currentProvider,
    required this.initialReasoningEffort,
    this.initialThinkingEnabled = true,
    required this.accentColor,
    this.backgroundPalette,
    required this.onReasoningEffortChanged,
    this.onThinkingEnabledChanged = _noopThinkingChange,
    required this.onModelSelected,
    required this.onUnavailableProviderSelected,
    this.embedded = false,
  });

  static Future<void> _noopThinkingChange(bool _) async {}

  @override
  State<ChatModelPickerPanel> createState() => _ChatModelPickerPanelState();
}

class _ChatModelPickerPanelState extends State<ChatModelPickerPanel> {
  late String _reasoningEffort;
  late bool _thinkingEnabled;
  final ScrollController _modelScrollController = ScrollController();
  bool _savingReasoningEffort = false;
  bool _savingThinkingEnabled = false;

  Color get _panelColor {
    final dominant = widget.backgroundPalette?.dominant;
    if (dominant == null) {
      return YanciTheme.isDark
          ? const Color(0xF0252228)
          : Colors.white.withValues(alpha: 0.97);
    }
    final dark = dominant.computeLuminance() < 0.4;
    return Color.lerp(
      dark ? const Color(0xFF252228) : Colors.white,
      dominant,
      0.12,
    )!;
  }

  BackgroundForegroundPalette? get _panelForeground =>
      widget.backgroundPalette == null
      ? null
      : BackgroundForegroundService.forColor(_panelColor);

  @override
  void initState() {
    super.initState();
    _reasoningEffort = ReasoningEffort.normalize(widget.initialReasoningEffort);
    _thinkingEnabled = widget.initialThinkingEnabled;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrentModel());
  }

  @override
  void didUpdateWidget(covariant ChatModelPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_savingReasoningEffort &&
        oldWidget.initialReasoningEffort != widget.initialReasoningEffort) {
      _reasoningEffort = ReasoningEffort.normalize(
        widget.initialReasoningEffort,
      );
    }
    if (!_savingThinkingEnabled &&
        oldWidget.initialThinkingEnabled != widget.initialThinkingEnabled) {
      _thinkingEnabled = widget.initialThinkingEnabled;
    }
    if (oldWidget.currentModelId != widget.currentModelId ||
        oldWidget.currentProvider != widget.currentProvider ||
        oldWidget.entries.length != widget.entries.length) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealCurrentModel(),
      );
    }
  }

  void _revealCurrentModel() {
    if (!mounted || !_modelScrollController.hasClients) return;
    final cloud = widget.entries.where((entry) => !entry.isLocal).toList();
    final local = widget.entries.where((entry) => entry.isLocal).toList();
    final ordered = <ChatModelPickerEntry>[...cloud, ...local];
    final index = ordered.indexWhere(
      (entry) =>
          entry.id == widget.currentModelId &&
          entry.provider == widget.currentProvider,
    );
    if (index < 0) return;
    var target = index * 68.0;
    if (index >= cloud.length && cloud.isNotEmpty && local.isNotEmpty) {
      target += 38;
    }
    final position = _modelScrollController.position;
    final centered = target - position.viewportDimension * 0.35;
    _modelScrollController.jumpTo(
      centered.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  void dispose() {
    _modelScrollController.dispose();
    super.dispose();
  }

  Future<void> _setReasoningEffort(String value) async {
    final normalized = ReasoningEffort.normalize(value);
    if (_savingReasoningEffort || normalized == _reasoningEffort) return;
    final previous = _reasoningEffort;
    setState(() {
      _reasoningEffort = normalized;
      _savingReasoningEffort = true;
    });
    try {
      await widget.onReasoningEffortChanged(normalized);
    } catch (_) {
      if (mounted) setState(() => _reasoningEffort = previous);
    } finally {
      if (mounted) setState(() => _savingReasoningEffort = false);
    }
  }

  Future<void> _setThinkingEnabled(bool value) async {
    if (_savingThinkingEnabled || value == _thinkingEnabled) return;
    final previous = _thinkingEnabled;
    setState(() {
      _thinkingEnabled = value;
      _savingThinkingEnabled = true;
    });
    try {
      await widget.onThinkingEnabledChanged(value);
    } catch (_) {
      if (mounted) setState(() => _thinkingEnabled = previous);
    } finally {
      if (mounted) setState(() => _savingThinkingEnabled = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloudEntries = widget.entries
        .where((entry) => !entry.isLocal)
        .toList(growable: false);
    final localEntries = widget.entries
        .where((entry) => entry.isLocal)
        .toList(growable: false);
    final desiredListHeight =
        widget.entries.length * 70.0 + (localEntries.isEmpty ? 0 : 38);
    final panelColor = _panelColor;
    final textColor = _panelForeground;

    return Container(
      key: const ValueKey('chat-model-picker-panel'),
      decoration: BoxDecoration(
        color: widget.embedded ? Colors.transparent : panelColor,
        borderRadius: BorderRadius.circular(YanciTheme.radiusLg),
        border: widget.embedded
            ? null
            : Border.all(
                color:
                    textColor?.secondary.withValues(alpha: 0.16) ??
                    YanciTheme.textSecondary.withValues(alpha: 0.1),
              ),
        boxShadow: widget.embedded
            ? const <BoxShadow>[]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
      ),
      child: Padding(
        padding: widget.embedded
            ? const EdgeInsets.fromLTRB(0, 6, 0, 0)
            : const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  L.pick(en: 'Thinking', zhTW: '思考鏈', zhCN: '思考链'),
                  style: TextStyle(
                    color: textColor?.primary ?? YanciTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                Switch.adaptive(
                  key: const ValueKey('chat-model-thinking-switch'),
                  value: _thinkingEnabled,
                  onChanged: _savingThinkingEnabled
                      ? null
                      : _setThinkingEnabled,
                  activeTrackColor: widget.accentColor,
                ),
              ],
            ),
            ModelStrengthFateSelector(
              value: _reasoningEffort,
              enabled: !_savingReasoningEffort && _thinkingEnabled,
              accentColor: widget.accentColor,
              foregroundColor: textColor?.primary,
              onChanged: _setReasoningEffort,
            ),
            const SizedBox(height: 4),
            Divider(
              color:
                  textColor?.secondary.withValues(alpha: 0.16) ??
                  YanciTheme.textSecondary.withValues(alpha: 0.16),
              height: 1,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: desiredListHeight),
                child: ListView(
                  controller: _modelScrollController,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    ...cloudEntries.map(_buildModelRow),
                    if (localEntries.isNotEmpty) ...[
                      Padding(
                        key: const ValueKey('chat-model-local-header'),
                        padding: EdgeInsets.fromLTRB(
                          12,
                          cloudEntries.isEmpty ? 2 : 10,
                          12,
                          7,
                        ),
                        child: Semantics(
                          header: true,
                          child: Text(
                            L.pick(en: 'Local', zhTW: '本地'),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 11,
                              color:
                                  textColor?.secondary ??
                                  YanciTheme.textSecondary.withValues(
                                    alpha: 0.72,
                                  ),
                            ),
                          ),
                        ),
                      ),
                      ...localEntries.map(_buildModelRow),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelRow(ChatModelPickerEntry entry) {
    final isActive =
        entry.id == widget.currentModelId &&
        entry.provider == widget.currentProvider;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final panelColor = _panelColor;
    final textColor = _panelForeground;
    // 10% 主題色混入面板底色：比舊的 12% accent 選中底更輕。
    final selectedFill = Color.lerp(panelColor, widget.accentColor, 0.10)!;

    return Semantics(
      button: true,
      selected: isActive,
      label: [
        entry.label,
        entry.providerLabel,
        if (!entry.isProviderConfigured)
          L.pick(en: 'Not configured', zhTW: '尚未設定', zhCN: '尚未设置'),
      ].join(', '),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey<String>(
                'chat-model-row-${entry.provider}-${entry.id}',
              ),
              onTap: () => entry.isProviderConfigured
                  ? widget.onModelSelected(entry)
                  : widget.onUnavailableProviderSelected(entry),
              child: AnimatedContainer(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(minHeight: 62),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: isActive ? selectedFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _MarqueeLabel(
                            text: entry.label,
                            style: YanciTheme.bodyText.copyWith(
                              fontSize: 13,
                              color: entry.isProviderConfigured
                                  ? (textColor?.primary ??
                                        YanciTheme.textPrimary)
                                  : (textColor?.secondary ??
                                        YanciTheme.textSecondary),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _ModelProviderLabel(
                                key: ValueKey<String>(
                                  'chat-model-source-${entry.provider}-${entry.id}',
                                ),
                                label: entry.providerLabel,
                                color: textColor?.secondary,
                              ),
                              if (!entry.isProviderConfigured)
                                _ModelProviderStatus(
                                  label: L.pick(
                                    en: 'Not configured',
                                    zhTW: '尚未設定',
                                    zhCN: '尚未设置',
                                  ),
                                  color: textColor?.secondary,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 10),
                      _ModelBreathingDot(
                        key: ValueKey('chat-model-active-dot'),
                        color: widget.accentColor,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelProviderLabel extends StatelessWidget {
  final String label;
  final Color? color;

  const _ModelProviderLabel({super.key, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final foreground =
        color ?? YanciTheme.textSecondary.withValues(alpha: 0.78);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '—',
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10.5,
            height: 1.1,
            fontWeight: FontWeight.w500,
            color: foreground,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10.5,
            height: 1.1,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
            color: foreground,
          ),
        ),
      ],
    );
  }
}

class _ModelProviderStatus extends StatelessWidget {
  final String label;
  final Color? color;

  const _ModelProviderStatus({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.key_off_outlined,
          size: 12,
          color: color ?? YanciTheme.textSecondary.withValues(alpha: 0.82),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10.5,
            height: 1.1,
            fontWeight: FontWeight.w600,
            color: color ?? YanciTheme.textSecondary.withValues(alpha: 0.88),
          ),
        ),
      ],
    );
  }
}

class ModelStrengthFateSelector extends StatefulWidget {
  final String value;
  final bool enabled;
  final Color accentColor;
  final Color? foregroundColor;
  final ValueChanged<String> onChanged;

  const ModelStrengthFateSelector({
    super.key,
    required this.value,
    required this.enabled,
    required this.accentColor,
    this.foregroundColor,
    required this.onChanged,
  });

  @override
  State<ModelStrengthFateSelector> createState() =>
      _ModelStrengthFateSelectorState();
}

class _ModelStrengthFateSelectorState extends State<ModelStrengthFateSelector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ambientController;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ModelStrengthFateSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.value != ReasoningEffort.auto &&
        !_reduceMotion &&
        TickerMode.valuesOf(context).enabled) {
      if (!_ambientController.isAnimating) _ambientController.repeat();
    } else {
      _ambientController.stop();
      _ambientController.value = 0;
    }
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
  }

  String _shortLabel(String effort) => switch (effort) {
    ReasoningEffort.low => L.pick(en: 'Low', zhTW: '低', zhCN: '低'),
    ReasoningEffort.medium => L.pick(en: 'Medium', zhTW: '中', zhCN: '中'),
    ReasoningEffort.high => L.pick(en: 'High', zhTW: '高', zhCN: '高'),
    _ => L.pick(en: 'Auto', zhTW: '自動', zhCN: '自动'),
  };

  @override
  Widget build(BuildContext context) {
    final normalized = ReasoningEffort.normalize(widget.value);
    final foreground = widget.foregroundColor ?? YanciTheme.textPrimary;
    final options = const <String>[
      ReasoningEffort.auto,
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
    ];
    return Container(
      key: const ValueKey('chat-model-thinking-toggle'),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(en: 'Reasoning strength', zhTW: '思考強度', zhCN: '思考强度'),
            style: YanciTheme.bodyText.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: YanciTheme.glassInputBg.withValues(alpha: 0.66),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: YanciTheme.glassBorder.withValues(alpha: 0.48),
                  width: 0.6,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _ambientController,
                        builder: (context, _) => CustomPaint(
                          painter: _FateStrengthPainter(
                            effort: normalized,
                            accent: widget.accentColor,
                            progress: _reduceMotion
                                ? 0.18
                                : _ambientController.value,
                            staticOnly: _reduceMotion,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (final effort in options)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: effort == normalized,
                            enabled: widget.enabled,
                            label:
                                '${L.pick(en: 'Reasoning strength', zhTW: '思考強度', zhCN: '思考强度')} ${_shortLabel(effort)}',
                            child: InkWell(
                              key: ValueKey<String>(
                                'chat-model-reasoning-$effort',
                              ),
                              borderRadius: BorderRadius.circular(999),
                              onTap: widget.enabled
                                  ? () => widget.onChanged(effort)
                                  : null,
                              child: Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: _reduceMotion
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),
                                  curve: Curves.easeOutCubic,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 12,
                                    fontWeight: effort == normalized
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: effort == normalized
                                        ? foreground
                                        : foreground.withValues(alpha: 0.48),
                                  ),
                                  child: Text(_shortLabel(effort)),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FateStrengthPainter extends CustomPainter {
  const _FateStrengthPainter({
    required this.effort,
    required this.accent,
    required this.progress,
    required this.staticOnly,
  });

  final String effort;
  final Color accent;
  final double progress;
  final bool staticOnly;

  @override
  void paint(Canvas canvas, Size size) {
    if (effort == ReasoningEffort.auto || size.isEmpty) return;
    final index = switch (effort) {
      ReasoningEffort.low => 1,
      ReasoningEffort.medium => 2,
      _ => 3,
    };
    final segmentWidth = size.width / 4;
    final rect = Rect.fromLTWH(
      index * segmentWidth,
      0,
      segmentWidth,
      size.height,
    );
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(999)));
    final center = rect.center;
    final warm = Color.lerp(accent, const Color(0xFFFFD99A), 0.52)!;
    final pink = Color.lerp(accent, const Color(0xFFFFA8C4), 0.55)!;

    void glowDot(Offset point, Color color, double radius) {
      canvas.drawCircle(
        point,
        radius * 2.6,
        Paint()
          ..color = color.withValues(alpha: 0.18)
          ..blendMode = BlendMode.plus
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = color.withValues(alpha: 0.9)
          ..blendMode = BlendMode.plus,
      );
      canvas.drawCircle(
        point,
        1,
        Paint()
          ..color = const Color(0xFFFFFDF9)
          ..blendMode = BlendMode.plus,
      );
    }

    if (effort == ReasoningEffort.low) {
      final angle = staticOnly ? -0.4 : progress * math.pi * 2;
      final point = center + Offset(math.cos(angle) * 16, math.sin(angle) * 6);
      final tail = Path()
        ..moveTo(point.dx, point.dy)
        ..quadraticBezierTo(
          center.dx,
          center.dy + 5,
          point.dx - math.cos(angle) * 18,
          point.dy - math.sin(angle) * 7,
        );
      canvas.drawPath(
        tail,
        Paint()
          ..color = warm.withValues(alpha: 0.20)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.plus,
      );
      glowDot(point, warm, 2.1);
    } else if (effort == ReasoningEffort.medium) {
      final angle = staticOnly ? 0.55 : progress * math.pi * 2;
      final first = center + Offset(math.cos(angle) * 17, math.sin(angle) * 7);
      final second =
          center +
          Offset(math.cos(angle + math.pi) * 17, math.sin(angle + math.pi) * 7);
      final orbitPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..blendMode = BlendMode.plus;
      canvas.drawOval(
        Rect.fromCenter(center: center, width: 38, height: 13),
        orbitPaint..color = warm.withValues(alpha: 0.13),
      );
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(-0.36);
      canvas.translate(-center.dx, -center.dy);
      canvas.drawOval(
        Rect.fromCenter(center: center, width: 38, height: 13),
        orbitPaint..color = pink.withValues(alpha: 0.13),
      );
      canvas.restore();
      glowDot(first, warm, 1.9);
      glowDot(second, pink, 1.9);
    } else {
      // 高：與低（一顆）、中（兩顆）同一套軌道語言，三顆光點等距繞行。
      final angle = staticOnly ? 0.55 : progress * math.pi * 2;
      final light = Color.lerp(warm, const Color(0xFFFFFDF9), 0.35)!;
      canvas.drawOval(
        Rect.fromCenter(center: center, width: 38, height: 13),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..blendMode = BlendMode.plus
          ..color = warm.withValues(alpha: 0.13),
      );
      final colors = <Color>[warm, pink, light];
      for (var i = 0; i < colors.length; i++) {
        final a = angle + i * math.pi * 2 / colors.length;
        glowDot(
          center + Offset(math.cos(a) * 17, math.sin(a) * 7),
          colors[i],
          1.9,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FateStrengthPainter oldDelegate) =>
      effort != oldDelegate.effort ||
      accent != oldDelegate.accent ||
      progress != oldDelegate.progress ||
      staticOnly != oldDelegate.staticOnly;
}

class _ModelBreathingDot extends StatefulWidget {
  final Color color;

  const _ModelBreathingDot({super.key, required this.color});

  @override
  State<_ModelBreathingDot> createState() => _ModelBreathingDotState();
}

class _ModelBreathingDotState extends State<_ModelBreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion || !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: 22,
        height: 22,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = _reduceMotion ? 0.0 : _controller.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 8 + 12 * progress,
                  height: 8 + 12 * progress,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withValues(
                        alpha: 0.32 * (1 - progress),
                      ),
                    ),
                  ),
                ),
                child!,
              ],
            );
          },
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.40),
                  blurRadius: 7,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarqueeLabel extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeLabel({required this.text, required this.style});

  @override
  State<_MarqueeLabel> createState() => _MarqueeLabelState();
}

class _MarqueeLabelState extends State<_MarqueeLabel>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollController;
  AnimationController? _animationController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  void _checkOverflow() {
    if (!mounted ||
        !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent <= 0) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) return;
    final extent = _scrollController.position.maxScrollExtent;
    final durationMs = (extent / 20 * 1000).round().clamp(2000, 15000);
    _animationController?.dispose();
    _animationController =
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: durationMs),
        )..addListener(() {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _animationController!.value *
                  _scrollController.position.maxScrollExtent,
            );
          }
        });
    _animationController!.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _MarqueeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _animationController?.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void dispose() {
    _animationController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
