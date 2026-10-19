import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'sidebar_visual_tokens.dart';

// ─────────────────────────────────────────────────────────────
//  SidebarAccordionCoordinator
//  Tracks the active relationGroup. Sections in the same group
//  can stay open simultaneously; opening a section from a
//  *different* group auto-collapses the old group.
// ─────────────────────────────────────────────────────────────

class SidebarAccordionCoordinator extends ValueNotifier<String?> {
  SidebarAccordionCoordinator() : super(null);

  String? _activeId;
  String? _activeGroup;
  bool _exclusive = false;

  void activate(String group, {required String id, bool exclusive = false}) {
    _activeId = id;
    _activeGroup = group;
    _exclusive = exclusive;
    if (value != group) {
      value = group;
    } else {
      notifyListeners();
    }
  }

  bool shouldCollapse({required String id, required String group}) {
    if (_activeGroup != group) return true;
    return _exclusive && _activeId != id;
  }
}

// ─────────────────────────────────────────────────────────────
//  SidebarAccordionScope  (InheritedNotifier)
// ─────────────────────────────────────────────────────────────

class SidebarAccordionScope
    extends InheritedNotifier<SidebarAccordionCoordinator> {
  const SidebarAccordionScope({
    super.key,
    required SidebarAccordionCoordinator coordinator,
    required super.child,
  }) : super(notifier: coordinator);

  static SidebarAccordionCoordinator? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SidebarAccordionScope>()
        ?.notifier;
  }
}

// ─────────────────────────────────────────────────────────────
//  SidebarAccordionSection
//  Custom expandable replacing ExpansionTile.
//  Keeps the same constructor API for drop-in compatibility.
// ─────────────────────────────────────────────────────────────

class SidebarAccordionSection extends StatefulWidget {
  const SidebarAccordionSection({
    super.key,
    required this.id,
    required this.relationGroup,
    required this.title,
    this.subtitle,
    required this.children,
    this.childrenPadding,
    this.initiallyExpanded = false,
    this.trailing,
    this.showChevron = true,
    this.exclusiveWithinGroup = false,
  });

  final String id;
  final String relationGroup;
  final Widget title;
  final Widget? subtitle;
  final List<Widget> children;
  final EdgeInsetsGeometry? childrenPadding;
  final bool initiallyExpanded;
  final Widget? trailing;
  final bool showChevron;
  final bool exclusiveWithinGroup;

  @override
  State<SidebarAccordionSection> createState() =>
      _SidebarAccordionSectionState();
}

class _SidebarAccordionSectionState extends State<SidebarAccordionSection>
    with SingleTickerProviderStateMixin {
  // ── animation ──
  late final AnimationController _animCtrl;
  late final CurvedAnimation _expandCurve;
  late final CurvedAnimation _fadeCurve;
  late final Animation<double> _chevronTurns;

  // ── state ──
  bool _expanded = false;
  SidebarAccordionCoordinator? _coordinator;

  // ── lifecycle ──

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;

    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 260),
      vsync: this,
      value: _expanded ? 1.0 : 0.0,
    );

    _expandCurve = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _fadeCurve = CurvedAnimation(
      parent: _animCtrl,
      curve: const Interval(0.15, 1.0, curve: Curves.easeOut),
      reverseCurve: const Interval(0.0, 0.85, curve: Curves.easeIn),
    );

    _chevronTurns = Tween<double>(begin: 0.0, end: 0.5).animate(_expandCurve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newCoordinator = SidebarAccordionScope.of(context);
    if (_coordinator != newCoordinator) {
      _coordinator?.removeListener(_syncGroup);
      _coordinator = newCoordinator;
      _coordinator?.addListener(_syncGroup);
    }
  }

  @override
  void dispose() {
    _coordinator?.removeListener(_syncGroup);
    _fadeCurve.dispose();
    _expandCurve.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  // ── coordinator sync ──

  void _syncGroup() {
    if (!_expanded ||
        _coordinator == null ||
        !_coordinator!.shouldCollapse(
          id: widget.id,
          group: widget.relationGroup,
        )) {
      return;
    }
    _collapse();
  }

  @override
  void didUpdateWidget(covariant SidebarAccordionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded == widget.initiallyExpanded) {
      return;
    }
    if (widget.initiallyExpanded) {
      _expand();
    } else {
      _collapse();
    }
  }

  // ── expand / collapse ──

  void _toggle() {
    if (_expanded) {
      _collapse();
    } else {
      _expand();
    }
  }

  void _expand() {
    setState(() => _expanded = true);
    _animCtrl.forward();
    _coordinator?.activate(
      widget.relationGroup,
      id: widget.id,
      exclusive: widget.exclusiveWithinGroup,
    );
  }

  void _collapse() {
    // Collapsed children remain mounted during the reverse animation. Explicit
    // unfocus prevents a hidden numeric field from keeping the iOS keyboard
    // and global viewInsets alive after another section is opened.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _expanded = false);
    _animCtrl.reverse();
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final accent = SidebarVisualTokens.accent;
    final textPrimary = SidebarVisualTokens.primary;
    final textSecondary = SidebarVisualTokens.secondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── header ──
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              splashColor: accent.withValues(alpha: 0.06),
              highlightColor: accent.withValues(alpha: 0.04),
              // A toggle-only row has no accordion body. Disabling the header
              // tap prevents an invisible expand state from being activated.
              onTap: widget.children.isEmpty ? null : _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    // accent dot
                    AnimatedBuilder(
                      animation: _expandCurve,
                      builder: (context, child) {
                        final t = _expandCurve.value;
                        final dotOpacity = 0.2 + 0.65 * t;
                        return Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent.withValues(alpha: dotOpacity),
                            boxShadow: t > 0.3
                                ? [
                                    BoxShadow(
                                      color: accent.withValues(alpha: 0.25 * t),
                                      blurRadius: 6 * t,
                                      spreadRadius: 1 * t,
                                    ),
                                  ]
                                : null,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 10),

                    // title + subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: _expandCurve,
                            builder: (context, _) {
                              final t = _expandCurve.value;
                              final color = Color.lerp(
                                textSecondary,
                                textPrimary,
                                t,
                              )!;
                              return DefaultTextStyle.merge(
                                style: YanciTheme.bodyText.copyWith(
                                  color: color,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  height: 1.3,
                                ),
                                child: widget.title,
                              );
                            },
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 2),
                            DefaultTextStyle.merge(
                              style: YanciTheme.bodySmall.copyWith(
                                color: textSecondary.withValues(alpha: 0.55),
                                fontSize: 11,
                                height: 1.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              child: widget.subtitle!,
                            ),
                          ],
                        ],
                      ),
                    ),

                    if (widget.trailing != null) widget.trailing!,
                    if (widget.showChevron)
                      RotationTransition(
                        turns: _chevronTurns,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: textSecondary.withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ── body ──
          SizeTransition(
            sizeFactor: _expandCurve,
            alignment: AlignmentDirectional.topStart,
            child: FadeTransition(
              opacity: _fadeCurve,
              child: ExcludeSemantics(
                excluding: !_expanded,
                child: IgnorePointer(
                  ignoring: !_expanded,
                  child: Padding(
                    padding:
                        widget.childrenPadding ??
                        const EdgeInsets.only(left: 16, top: 2, bottom: 6),
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        listTileTheme: Theme.of(context).listTileTheme.copyWith(
                          titleTextStyle: YanciTheme.bodySmall.copyWith(
                            color: textSecondary.withValues(alpha: 0.78),
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                          subtitleTextStyle: YanciTheme.bodySmall.copyWith(
                            color: textSecondary.withValues(alpha: 0.52),
                            fontSize: 10.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                      child: DefaultTextStyle.merge(
                        // Expanded controls belong to the subtitle hierarchy,
                        // not the main settings-row/body hierarchy.
                        style: YanciTheme.bodySmall.copyWith(
                          color: textSecondary.withValues(alpha: 0.78),
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: widget.children,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
