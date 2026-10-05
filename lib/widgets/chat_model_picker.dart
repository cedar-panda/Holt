import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/background_foreground_service.dart';
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
  final bool initialThinking;
  final Color accentColor;
  final BackgroundForegroundPalette? backgroundPalette;
  final Future<void> Function(bool value) onThinkingChanged;
  final Future<void> Function(ChatModelPickerEntry entry) onModelSelected;
  final ValueChanged<ChatModelPickerEntry> onUnavailableProviderSelected;

  const ChatModelPickerPanel({
    super.key,
    required this.entries,
    required this.currentModelId,
    required this.currentProvider,
    required this.initialThinking,
    required this.accentColor,
    this.backgroundPalette,
    required this.onThinkingChanged,
    required this.onModelSelected,
    required this.onUnavailableProviderSelected,
  });

  @override
  State<ChatModelPickerPanel> createState() => _ChatModelPickerPanelState();
}

class _ChatModelPickerPanelState extends State<ChatModelPickerPanel> {
  late bool _thinking;
  bool _savingThinking = false;

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
    _thinking = widget.initialThinking;
  }

  Future<void> _setThinking(bool value) async {
    if (_savingThinking || value == _thinking) return;
    final previous = _thinking;
    setState(() {
      _thinking = value;
      _savingThinking = true;
    });
    try {
      await widget.onThinkingChanged(value);
    } catch (_) {
      if (mounted) setState(() => _thinking = previous);
    } finally {
      if (mounted) setState(() => _savingThinking = false);
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
        color: panelColor,
        borderRadius: BorderRadius.circular(YanciTheme.radiusLg),
        border: Border.all(
          color:
              textColor?.secondary.withValues(alpha: 0.16) ??
              YanciTheme.textSecondary.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ThinkingRippleToggle(
              value: _thinking,
              enabled: !_savingThinking,
              accentColor: widget.accentColor,
              foregroundColor: textColor?.primary,
              onChanged: _setThinking,
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

class _ThinkingRippleToggle extends StatefulWidget {
  final bool value;
  final bool enabled;
  final Color accentColor;
  final Color? foregroundColor;
  final ValueChanged<bool> onChanged;

  const _ThinkingRippleToggle({
    required this.value,
    required this.enabled,
    required this.accentColor,
    this.foregroundColor,
    required this.onChanged,
  });

  @override
  State<_ThinkingRippleToggle> createState() => _ThinkingRippleToggleState();
}

class _ThinkingRippleToggleState extends State<_ThinkingRippleToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _ThinkingRippleToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.value &&
        !_reduceMotion &&
        TickerMode.valuesOf(context).enabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transitionDuration = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Semantics(
      key: const ValueKey('chat-model-thinking-toggle'),
      button: true,
      toggled: widget.value,
      enabled: widget.enabled,
      label: L.get('chat_thinking_toggle'),
      onTap: widget.enabled ? () => widget.onChanged(!widget.value) : null,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.enabled
                ? () => widget.onChanged(!widget.value)
                : null,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.get('chat_thinking_toggle'),
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: widget.foregroundColor ?? YanciTheme.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    height: 44,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: transitionDuration,
                          curve: Curves.easeOutCubic,
                          width: 66,
                          height: 34,
                          decoration: BoxDecoration(
                            color: widget.value
                                ? widget.accentColor.withValues(alpha: 0.22)
                                : YanciTheme.glassInputBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        Positioned.fill(
                          left: 9,
                          right: 9,
                          child: AnimatedAlign(
                            duration: transitionDuration,
                            curve: Curves.easeOutCubic,
                            alignment: widget.value
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: SizedBox(
                              width: 34,
                              height: 44,
                              child: AnimatedBuilder(
                                animation: _controller,
                                builder: (context, child) {
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      if (widget.value && !_reduceMotion) ...[
                                        _RippleRing(
                                          progress: _controller.value,
                                          color: widget.accentColor,
                                        ),
                                        _RippleRing(
                                          progress:
                                              (_controller.value + 0.5) % 1,
                                          color: widget.accentColor,
                                        ),
                                      ],
                                      child!,
                                    ],
                                  );
                                },
                                child: AnimatedContainer(
                                  duration: transitionDuration,
                                  curve: Curves.easeOutCubic,
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: widget.value
                                        ? widget.accentColor
                                        : YanciTheme.textSecondary.withValues(
                                            alpha: 0.50,
                                          ),
                                    shape: BoxShape.circle,
                                    boxShadow: widget.value
                                        ? [
                                            BoxShadow(
                                              color: widget.accentColor
                                                  .withValues(alpha: 0.32),
                                              blurRadius: 8,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
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
          ),
        ),
      ),
    );
  }
}

class _RippleRing extends StatelessWidget {
  final double progress;
  final Color color;

  const _RippleRing({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    final diameter = 20 + 16 * progress;
    return ExcludeSemantics(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.24 * (1 - progress)),
          ),
        ),
      ),
    );
  }
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
