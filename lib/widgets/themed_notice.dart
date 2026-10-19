import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum ThemedNoticeTone { neutral, error }

class ThemedNoticeAction {
  const ThemedNoticeAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

class ThemedNoticeAnchorScope extends InheritedWidget {
  const ThemedNoticeAnchorScope({
    super.key,
    required this.link,
    required super.child,
  });

  final LayerLink link;

  static LayerLink? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemedNoticeAnchorScope>()
      ?.link;

  @override
  bool updateShouldNotify(ThemedNoticeAnchorScope oldWidget) =>
      oldWidget.link != link;
}

class _ThemedNoticeHandle {
  _ThemedNoticeHandle({
    required this.entry,
    required this.stateKey,
    required this.timer,
  });

  final OverlayEntry entry;
  final GlobalKey<_ThemedNoticeOverlayState> stateKey;
  final Timer timer;
}

final Map<OverlayState, _ThemedNoticeHandle> _activeNotices =
    Map<OverlayState, _ThemedNoticeHandle>.identity();

void showThemedPillNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2600),
  ThemedNoticeTone tone = ThemedNoticeTone.neutral,
  ThemedNoticeAction? action,
  LayerLink? anchorLink,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final resolvedAnchor = anchorLink ?? ThemedNoticeAnchorScope.maybeOf(context);
  final previous = _activeNotices.remove(overlay);
  if (previous != null) {
    previous.timer.cancel();
    if (previous.entry.mounted) previous.entry.remove();
  }

  final stateKey = GlobalKey<_ThemedNoticeOverlayState>();
  late final OverlayEntry entry;

  void removeEntry() {
    final current = _activeNotices[overlay];
    if (current?.entry != entry) return;
    current?.timer.cancel();
    _activeNotices.remove(overlay);
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (overlayContext) => _ThemedNoticeOverlay(
      key: stateKey,
      message: message,
      tone: tone,
      action: action,
      anchorLink: resolvedAnchor,
      onDismissed: removeEntry,
    ),
  );
  overlay.insert(entry);
  final timer = Timer(duration, () {
    final state = stateKey.currentState;
    if (state == null) {
      removeEntry();
    } else {
      state.dismiss();
    }
  });
  _activeNotices[overlay] = _ThemedNoticeHandle(
    entry: entry,
    stateKey: stateKey,
    timer: timer,
  );
}

class _ThemedNoticeOverlay extends StatefulWidget {
  const _ThemedNoticeOverlay({
    super.key,
    required this.message,
    required this.tone,
    required this.action,
    required this.anchorLink,
    required this.onDismissed,
  });

  final String message;
  final ThemedNoticeTone tone;
  final ThemedNoticeAction? action;
  final LayerLink? anchorLink;
  final VoidCallback onDismissed;

  @override
  State<_ThemedNoticeOverlay> createState() => _ThemedNoticeOverlayState();
}

class _ThemedNoticeOverlayState extends State<_ThemedNoticeOverlay>
    with SingleTickerProviderStateMixin {
  static const double _anchoredBottomGap = 13;
  late final AnimationController _controller;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
      reverseDuration: const Duration(milliseconds: 120),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  Future<void> dismiss() async {
    if (_dismissed) return;
    _dismissed = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _controller.reverse();
    }
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations;
    final notice = Align(
      widthFactor: 1,
      heightFactor: 1,
      child: IgnorePointer(
        ignoring: widget.action == null,
        child: Semantics(
          container: true,
          liveRegion: true,
          label: widget.message,
          child: FadeTransition(
            opacity: _controller,
            child: SlideTransition(
              position: reduceMotion
                  ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
                  : _controller.drive(
                      Tween<Offset>(
                        begin: const Offset(0, 0.12),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeOutCubic)),
                    ),
              child: _ThemedNoticeSurface(
                message: widget.message,
                tone: widget.tone,
                action: widget.action == null
                    ? null
                    : ThemedNoticeAction(
                        label: widget.action!.label,
                        onPressed: () {
                          final callback = widget.action!.onPressed;
                          dismiss();
                          callback();
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    final anchor = widget.anchorLink;
    if (anchor != null) {
      return CompositedTransformFollower(
        link: anchor,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -_anchoredBottomGap),
        // Give the follower a compact, deterministic footprint. Letting the
        // overlay's loose full-screen constraints reach the follower makes its
        // bottom-center alignment resolve against the whole screen, which can
        // visually strand the pill in the middle of the chat.
        child: SizedBox(
          width: media.size.width,
          height: 64,
          child: Align(alignment: Alignment.bottomCenter, child: notice),
        ),
      );
    }

    return Positioned(
      left: 16,
      right: 16,
      bottom: media.padding.bottom + 18,
      child: Center(child: notice),
    );
  }
}

class _ThemedNoticeSurface extends StatelessWidget {
  const _ThemedNoticeSurface({
    required this.message,
    required this.tone,
    required this.action,
  });

  final String message;
  final ThemedNoticeTone tone;
  final ThemedNoticeAction? action;

  @override
  Widget build(BuildContext context) {
    final accent = tone == ThemedNoticeTone.error
        ? const Color(0xFFE0525F)
        : YanciTheme.accent;
    final surface = Color.lerp(
      YanciTheme.surfacePanel,
      tone == ThemedNoticeTone.error
          ? const Color(0xFFFFD9DD)
          : YanciTheme.accentLight,
      YanciTheme.isDark ? .22 : .14,
    )!;
    final isError = tone == ThemedNoticeTone.error;

    return Material(
      key: const ValueKey('themed-pill-notice'),
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(0, 420),
        ),
        padding: EdgeInsets.fromLTRB(
          18,
          action == null ? 12 : 6,
          action == null ? 18 : 8,
          action == null ? 12 : 6,
        ),
        decoration: BoxDecoration(
          color: surface,
          // Errors carry more text and need a readable card shape; ordinary
          // notices retain the compact pill treatment.
          borderRadius: BorderRadius.circular(isError ? 16 : 999),
          border: Border.all(
            color: accent.withValues(alpha: YanciTheme.isDark ? .28 : .18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ExcludeSemantics(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 6),
              TextButton(
                onPressed: action!.onPressed,
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  minimumSize: const Size(48, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                child: Text(action!.label),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
