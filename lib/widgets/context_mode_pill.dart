import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/context_mode.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'themed_notice.dart';

export 'themed_notice.dart'
    show
        ThemedNoticeAction,
        ThemedNoticeAnchorScope,
        ThemedNoticeTone,
        showThemedPillNotice;

const Color contextDailyColor = Color(0xFF4E8FD8);
const Color contextRpColor = Color(0xFFE0525F);

void showContextModeNotice(BuildContext context, String message) {
  showThemedPillNotice(context, message);
}

Future<bool> confirmDisableGlobalRp(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: YanciTheme.surfacePanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      ),
      title: Text(
        L.pick(
          en: 'Turn off Global RP mode?',
          zhTW: '關閉全域 RP 模式？',
          zhCN: '关闭全局 RP 模式？',
        ),
      ),
      content: Text(
        L.pick(
          en: 'Global RP mode is on. Turn it off and use Daily mode for this companion’s future windows? Existing RP windows will remain RP.',
          zhTW: '目前開啟了全域 RP 模式。是否關閉全域 RP，並讓該夥伴之後的新窗口使用日常模式？現有 RP 窗口仍會保留為 RP。',
          zhCN: '目前开启了全局 RP 模式。是否关闭全局 RP，并让该伙伴之后的新窗口使用日常模式？现有 RP 窗口仍会保留为 RP。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(L.pick(en: 'Confirm', zhTW: '確定', zhCN: '确定')),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class ContextModeLabel extends StatelessWidget {
  const ContextModeLabel({super.key, required this.mode, this.compact = false});

  final ContextMode mode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rp = mode == ContextMode.rp;
    return Semantics(
      label: rp ? 'RP' : L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常'),
      child: Text(
        rp ? 'RP' : L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常'),
        style: TextStyle(
          fontFamily: YanciTheme.fontFamily,
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: rp ? contextRpColor : contextDailyColor,
        ),
      ),
    );
  }
}

class ContextModePill extends StatelessWidget {
  const ContextModePill({
    super.key,
    required this.mode,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  final ContextMode mode;
  final ValueChanged<ContextMode> onChanged;
  final bool enabled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final selectedIndex = mode == ContextMode.rp ? 1 : 0;
    final surface = Color.lerp(
      YanciTheme.surfacePanel,
      YanciTheme.accentLight,
      YanciTheme.isDark ? .14 : .10,
    )!;
    final width = compact ? 108.0 : 132.0;
    final height = compact ? 36.0 : 44.0;
    final padding = compact ? 4.0 : 5.0;
    return Semantics(
      label: L.pick(en: 'New window mode', zhTW: '新窗口模式', zhCN: '新窗口模式'),
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: YanciTheme.isDark ? .30 : .12,
              ),
              blurRadius: 5,
              offset: const Offset(-1.5, -1.5),
              blurStyle: BlurStyle.inner,
            ),
            BoxShadow(
              color: Colors.white.withValues(
                alpha: YanciTheme.isDark ? .10 : .76,
              ),
              blurRadius: 4,
              offset: const Offset(1.5, 1.5),
              blurStyle: BlurStyle.inner,
            ),
          ],
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 330),
              curve: reduced ? Curves.linear : Curves.easeOutBack,
              alignment: selectedIndex == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: Container(
                width: (width - padding * 2) / 2,
                decoration: BoxDecoration(
                  color: Color.lerp(
                    surface,
                    YanciTheme.accentLight,
                    YanciTheme.isDark ? .18 : .13,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: YanciTheme.accent.withValues(alpha: .11),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                _item(context, ContextMode.daily),
                _item(context, ContextMode.rp),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, ContextMode value) {
    final selected = mode == value;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled
            ? () {
                if (value == mode) return;
                HapticFeedback.selectionClick();
                onChanged(value);
              }
            : null,
        child: Center(
          child: Text(
            value == ContextMode.rp
                ? 'RP'
                : L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常'),
            style: TextStyle(
              fontFamily: YanciTheme.fontFamily,
              fontSize: compact ? 10 : 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? (value == ContextMode.rp
                        ? contextRpColor
                        : contextDailyColor)
                  : YanciTheme.textSecondary.withValues(
                      alpha: enabled ? .55 : .32,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class HistoryModePill extends StatefulWidget {
  const HistoryModePill({
    super.key,
    required this.value,
    required this.onChanged,
    this.backgroundColor,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final Color? backgroundColor;

  @override
  State<HistoryModePill> createState() => _HistoryModePillState();
}

class _HistoryModePillState extends State<HistoryModePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleX;
  late final Animation<double> _scaleY;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    );
    _scaleX = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: .86,
          end: .96,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: .96,
          end: 1.035,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.035,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 10,
      ),
    ]).animate(_controller);
    _scaleY = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: .80,
          end: 1.075,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.075,
          end: .97,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: .97,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 10,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant HistoryModePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = <(String, String)>[
      ('all', L.pick(en: 'All', zhTW: '全部', zhCN: '全部')),
      ('daily', L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常')),
      ('rp', 'RP'),
    ];
    final background = widget.backgroundColor ?? YanciTheme.surfacePanel;
    final base = Color.lerp(background, Colors.black, .10)!;
    final trough = Color.lerp(base, YanciTheme.accentLight, .06)!;
    final selectedSurface = Color.lerp(
      background,
      YanciTheme.accentLight,
      YanciTheme.isDark ? .20 : .13,
    )!;
    final selectedIndex = items.indexWhere((item) => item.$1 == widget.value);
    final alignment = switch (selectedIndex) {
      1 => Alignment.center,
      2 => Alignment.centerRight,
      _ => Alignment.centerLeft,
    };

    return SizedBox(
      width: 126,
      height: 30,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: trough,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: YanciTheme.accent.withValues(alpha: .08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedAlign(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: alignment,
                child: FractionallySizedBox(
                  widthFactor: 1 / 3,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) => Transform.scale(
                      scaleX: _scaleX.value,
                      scaleY: _scaleY.value,
                      child: child,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: selectedSurface,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: YanciTheme.accent.withValues(alpha: .12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: items.map((item) {
                  final selected = item.$1 == widget.value;
                  final color = item.$1 == 'rp'
                      ? contextRpColor
                      : item.$1 == 'daily'
                      ? contextDailyColor
                      : YanciTheme.textPrimary;
                  return Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () {
                        if (selected) return;
                        HapticFeedback.selectionClick();
                        widget.onChanged(item.$1);
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          style: TextStyle(
                            fontFamily: YanciTheme.fontFamily,
                            fontSize: 10,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? color
                                : YanciTheme.textSecondary.withValues(
                                    alpha: .50,
                                  ),
                          ),
                          child: Text(item.$2),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
