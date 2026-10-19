import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════
// HoltSidebarShell — Claude-mobile-style sidebar
//
// Layer stack (bottom → top):
//   0  Background    — fixed while app chrome moves with the drawer gesture
//   1  Sidebar       — translucent blurred panel; warmed before first drag
//   2  Content       — shifts right to reveal sidebar; rounded corners appear
//   3  Scrim         — darkened overlay on content; tap / drag to close
//   4  Edge strip    — invisible 36 px left-edge area to swipe-open
//
// Performance notes:
//   · PopScope.canPop driven by AnimationStatus, not per-frame value
//   · Sidebar uses Offstage (stays in tree; no construction spike on open)
//   · Content child cached via AnimatedBuilder.child parameter
//   · Edge strip always present; opacity-gated, not conditionally built
// ═══════════════════════════════════════════════════════════════════

class HoltSidebarShell extends StatefulWidget {
  /// Main screen content (Scaffold etc.) — shifts right when sidebar opens.
  final Widget child;

  /// Sidebar content widget (accordion settings etc.).
  final Widget sidebar;

  /// Theme/background layer. It stays fixed while [child] moves.
  final Widget background;

  const HoltSidebarShell({
    required this.child,
    required this.sidebar,
    required this.background,
    super.key,
  });

  // ── ancestor access ──

  static HoltSidebarShellState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<HoltSidebarShellState>();

  static HoltSidebarShellState of(BuildContext context) => maybeOf(context)!;

  @override
  HoltSidebarShellState createState() => HoltSidebarShellState();
}

class HoltSidebarShellState extends State<HoltSidebarShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _isDragging = false;
  bool _reduceMotion = false;
  double _dragStartValue = 0;

  /// Tracks whether the sidebar panel is visible.
  /// Updated only on AnimationStatus change — not per-frame.
  bool _sidebarVisible = false;

  /// Sidebar width = 78 % of screen width.
  static const double _widthRatio = 0.78;

  /// Persistent left-edge gesture target. It stays mounted while a drag opens
  /// the sidebar, otherwise rebuilding it away on drag start cancels the
  /// gesture arena and makes the panel feel stuck.
  static const double _edgeSwipeWidth = 44.0;

  /// Corner radius on sidebar panel (right side) and content when shifted.
  static const double _radius = 30.0;

  /// Open / close animation duration.
  static const Duration _dur = Duration(milliseconds: 280);

  bool get isOpen => _ctrl.isCompleted;
  bool get isClosed => _ctrl.isDismissed;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _dur);
    _ctrl.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _ctrl.removeStatusListener(_onStatus);
    _ctrl.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    final visible = status != AnimationStatus.dismissed;
    if (_sidebarVisible != visible) {
      setState(() => _sidebarVisible = visible);
    }
  }

  // ── public API ──

  void _ensureSidebarVisible() {
    if (_sidebarVisible) return;
    setState(() => _sidebarVisible = true);
  }

  void open() {
    _ensureSidebarVisible();
    if (_reduceMotion) {
      _ctrl.value = 1;
      return;
    }
    _ctrl.animateTo(1.0, curve: Curves.easeOutCubic);
  }

  void close() {
    _dismissKeyboard();
    if (_reduceMotion) {
      _ctrl.value = 0;
      return;
    }
    // animateTo(0) finishes with AnimationStatus.completed, which leaves the
    // sidebar marked visible even though its value is zero. animateBack ends
    // in dismissed so Offstage and PopScope both return to the closed state.
    _ctrl.animateBack(0.0, curve: Curves.easeOutCubic);
  }

  void toggle() => isOpen ? close() : open();

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  // ── drag handling ──

  void _onDragStart(DragStartDetails _) {
    // A numeric field in the drawer uses the iOS number pad, which has no
    // built-in Done key. Release its focus as soon as either the drawer or the
    // main page starts moving so viewInsets cannot leak into the next page.
    _dismissKeyboard();
    _isDragging = true;
    _dragStartValue = _ctrl.value;
    _ctrl.stop();
    _ensureSidebarVisible();
  }

  void _onDragUpdate(DragUpdateDetails d, double sidebarW) {
    if (!_isDragging) _onDragStart(DragStartDetails());
    _ctrl.value += (d.primaryDelta ?? 0) / sidebarW;
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_isDragging) return;
    _isDragging = false;
    final v = d.primaryVelocity ?? 0;
    if (v > 280) {
      open();
    } else if (v < -280) {
      close();
    } else if (_dragStartValue >= 0.5) {
      _ctrl.value < _dragStartValue - 0.12 ? close() : open();
    } else {
      _ctrl.value > _dragStartValue + 0.12 ? open() : close();
    }
  }

  void _onDragCancel() {
    if (!_isDragging) return;
    _isDragging = false;
    _dragStartValue >= 0.5 ? open() : close();
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final sidebarW = screenW * _widthRatio;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);

    return PopScope(
      // Only re-evaluated on setState (status change), not per-frame.
      canPop: !_sidebarVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: Stack(
        children: [
          // ── Layer 0: fixed theme/background image ──
          Positioned.fill(child: RepaintBoundary(child: widget.background)),

          // ── Layer 1: Sidebar panel ──
          // Stays in widget tree (Offstage); avoids construction jank on open.
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) {
              // Controller animation already applies the easing curve. Keep
              // this value linear so a live drag tracks the finger 1:1 and
              // the sidebar/content layers never drift apart.
              final t = _ctrl.value;
              return Positioned(
                left: -sidebarW * (1 - t),
                top: 0,
                bottom: 0,
                width: sidebarW,
                child: child!,
              );
            },
            child: Offstage(
              offstage: !_sidebarVisible,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: _onDragStart,
                onHorizontalDragUpdate: (d) => _onDragUpdate(d, sidebarW),
                onHorizontalDragEnd: _onDragEnd,
                onHorizontalDragCancel: _onDragCancel,
                child: _buildSidebarPanel(),
              ),
            ),
          ),

          // ── Layer 2 + 3: Content (shifts right) + scrim ──
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) {
              final t = _ctrl.value;
              final shift = sidebarW * t;
              final cornerR = _radius * t;

              return Transform.translate(
                offset: Offset(shift, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(cornerR),
                  child: Stack(
                    children: [
                      child!,
                      // scrim — always in tree; alpha drives visibility
                      if (t > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.35 * t),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
            child: RepaintBoundary(child: widget.child),
          ),

          // ── Layer 3: exposed-content dismiss surface ──
          // Keep hit testing outside the translated content tree. Otherwise a
          // reverse drag can lose its recognizer while the content itself is
          // moving, leaving the drawer visually stuck open.
          if (_sidebarVisible)
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                return Positioned(
                  left: sidebarW * _ctrl.value,
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    key: const ValueKey<String>('sidebar-dismiss-surface'),
                    behavior: HitTestBehavior.opaque,
                    onTap: close,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: (d) => _onDragUpdate(d, sidebarW),
                    onHorizontalDragEnd: _onDragEnd,
                    onHorizontalDragCancel: _onDragCancel,
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                );
              },
            ),

          // ── Layer 4: Left-edge swipe strip ──
          // Keep the recognizer mounted for the whole gesture. IgnorePointer
          // only prevents it from covering sidebar controls after opening.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _edgeSwipeWidth,
            child: IgnorePointer(
              ignoring: _sidebarVisible,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragStart: _onDragStart,
                onHorizontalDragUpdate: (d) => _onDragUpdate(d, sidebarW),
                onHorizontalDragEnd: _onDragEnd,
                onHorizontalDragCancel: _onDragCancel,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── sidebar panel: fixed-background blur with a restrained tint ──

  Widget _buildSidebarPanel() {
    const radius = BorderRadius.only(
      topRight: Radius.circular(_radius),
      bottomRight: Radius.circular(_radius),
    );
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              color: YanciTheme.isDark
                  ? const Color(0xCC101010)
                  : const Color(0xCCF5F5F5),
            ),
            // The sidebar is a sibling of the main Scaffold. Give it its own
            // Material text environment so Text widgets never inherit the
            // WidgetsApp debug style (yellow double underline / wrong glyph
            // font) when a local style leaves a field unspecified.
            child: Material(
              type: MaterialType.transparency,
              textStyle: YanciTheme.bodyText.copyWith(
                color: YanciTheme.textPrimary,
                decoration: TextDecoration.none,
              ),
              child: widget.sidebar,
            ),
          ),
        ),
      ),
    );
  }
}
