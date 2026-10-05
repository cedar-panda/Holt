import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/background_preset.dart';
import '../services/background_foreground_service.dart';
import '../theme/app_theme.dart';

enum YanciBackgroundScope { none, home, chat }

enum BackgroundTransitionDirection { leftToRight, rightToLeft }

class BackgroundSwipeTransition {
  const BackgroundSwipeTransition({
    this.leftPreset,
    this.rightPreset,
    this.progress = 0,
    this.onlineReady = true,
  });

  final BackgroundPreset? leftPreset;
  final BackgroundPreset? rightPreset;
  final double progress;
  final bool onlineReady;
}

/// 全 app 共用的漸變背景（帶 dithering 消除色帶）
class GradientBackground extends StatelessWidget {
  final Widget child;
  final YanciBackgroundScope scope;
  final BackgroundPreset? presetOverride;
  final ChatBubblePalette? chatPaletteOverride;
  final BackgroundForegroundPalette? foregroundOverride;
  final BackgroundTransitionDirection transitionDirection;
  final int transitionRevision;
  final Duration transitionDuration;
  final ValueListenable<BackgroundSwipeTransition>? swipeTransition;

  const GradientBackground({
    super.key,
    required this.child,
    this.scope = YanciBackgroundScope.none,
    this.presetOverride,
    this.chatPaletteOverride,
    this.foregroundOverride,
    this.transitionDirection = BackgroundTransitionDirection.rightToLeft,
    this.transitionRevision = 0,
    this.transitionDuration = const Duration(seconds: 1),
    this.swipeTransition,
  });

  @override
  Widget build(BuildContext context) {
    final base = YanciTheme.backgroundGradient;
    final smoothColors = <Color>[];
    final smoothStops = <double>[];
    final baseStops = [0.0, 0.35, 0.65, 1.0];
    const subdivisions = 4;

    for (int i = 0; i < base.length - 1; i++) {
      for (int j = 0; j < subdivisions; j++) {
        final t = j / subdivisions;
        smoothColors.add(Color.lerp(base[i], base[i + 1], t)!);
        smoothStops.add(baseStops[i] + (baseStops[i + 1] - baseStops[i]) * t);
      }
    }
    smoothColors.add(base.last);
    smoothStops.add(1.0);

    final customBackground = scope == YanciBackgroundScope.home
        ? swipeTransition != null
              ? _SwipeDrivenBackgroundTransition(transition: swipeTransition!)
              : _FeatheredBackgroundTransition(
                  preset: presetOverride,
                  direction: transitionDirection,
                  revision: transitionRevision,
                  duration: transitionDuration,
                )
        : _backgroundImage(scope, presetOverride);

    final surface = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: smoothColors,
          stops: smoothStops,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          customBackground,
          CustomPaint(painter: _DitherPainter(), child: child),
        ],
      ),
    );
    // Keep the inherited scope mounted for the whole chat page, including
    // windows without a bound background. Chat bubbles depend on this scope;
    // conditionally removing the inherited widget while descendants are
    // rebuilding can trigger Flutter's `_dependents.isEmpty` assertion.
    if (scope == YanciBackgroundScope.chat) {
      return ChatBackgroundPresetScope(
        preset: presetOverride,
        palette: chatPaletteOverride,
        foreground: foregroundOverride,
        child: surface,
      );
    }
    return surface;
  }
}

/// 滑動角色卡時的背景過渡：手勢進度直接驅動方向羽化與模糊。
class _SwipeDrivenBackgroundTransition extends StatelessWidget {
  const _SwipeDrivenBackgroundTransition({required this.transition});

  final ValueListenable<BackgroundSwipeTransition> transition;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BackgroundSwipeTransition>(
      valueListenable: transition,
      builder: (context, frame, _) {
        final progress = frame.progress.clamp(0.0, 1.0);
        final settled = progress <= .001 || progress >= .999;
        final settledPreset = progress < .5
            ? frame.leftPreset
            : frame.rightPreset;
        if (MediaQuery.disableAnimationsOf(context)) {
          return _backgroundImage(YanciBackgroundScope.home, settledPreset);
        }
        if (settled && frame.onlineReady) {
          return _backgroundImage(YanciBackgroundScope.home, settledPreset);
        }

        final left = _backgroundImage(
          YanciBackgroundScope.home,
          frame.leftPreset,
        );
        final right = _backgroundImage(
          YanciBackgroundScope.home,
          frame.rightPreset,
        );
        final hasLeftImage = left is! SizedBox;
        final hasRightImage = right is! SizedBox;

        // Full-screen crossfade keeps both backgrounds spatially stable while
        // the user's finger controls the handoff. Blur peaks at mid-swipe.
        final curvedProgress = Curves.easeInOutCubic.transform(progress);
        final swipeBlur = (pow(sin(pi * progress), 0.75) * 10).toDouble();
        // Blur belongs only to the swipe itself. Once the carousel reaches
        // either endpoint it must keep resolving toward zero; reintroducing a
        // dwell blur here causes a clear -> blurred -> clear flash.
        final targetBlur = swipeBlur;

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetBlur),
          duration: settled ? const Duration(milliseconds: 280) : Duration.zero,
          curve: Curves.easeOutCubic,
          builder: (context, blur, child) => Positioned.fill(
            child: ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: blur,
                  sigmaY: blur,
                  tileMode: TileMode.clamp,
                ),
                child: child,
              ),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Keep the outgoing image opaque beneath the incoming one.
              // Fading both layers exposes the theme gradient mid-swipe.
              Opacity(
                opacity: hasLeftImage && hasRightImage ? 1 : 1 - curvedProgress,
                child: left,
              ),
              Opacity(opacity: curvedProgress, child: right),
            ],
          ),
        );
      },
    );
  }
}

Widget _backgroundImage(YanciBackgroundScope scope, BackgroundPreset? preset) {
  final path = switch (scope) {
    // Home and chat images share the same character binding. Without a
    // binding, keep the selected theme gradient instead of leaking the
    // globally active image set into every character.
    YanciBackgroundScope.home => preset?.homePath ?? '',
    YanciBackgroundScope.chat => preset?.chatPath ?? '',
    YanciBackgroundScope.none => '',
  };
  if (path.isEmpty) return const SizedBox.shrink();
  final file = File(path);
  if (!file.existsSync()) return const SizedBox.shrink();

  final scale = switch (scope) {
    YanciBackgroundScope.home =>
      preset?.homeScale ?? YanciTheme.homeBackgroundImageScale,
    YanciBackgroundScope.chat =>
      preset?.chatScale ?? YanciTheme.chatBackgroundImageScale,
    YanciBackgroundScope.none => 1.0,
  };
  final offsetX = switch (scope) {
    YanciBackgroundScope.home =>
      preset?.homeOffsetX ?? YanciTheme.homeBackgroundImageOffsetX,
    YanciBackgroundScope.chat =>
      preset?.chatOffsetX ?? YanciTheme.chatBackgroundImageOffsetX,
    YanciBackgroundScope.none => 0.0,
  };
  final offsetY = switch (scope) {
    YanciBackgroundScope.home =>
      preset?.homeOffsetY ?? YanciTheme.homeBackgroundImageOffsetY,
    YanciBackgroundScope.chat =>
      preset?.chatOffsetY ?? YanciTheme.chatBackgroundImageOffsetY,
    YanciBackgroundScope.none => 0.0,
  };
  final blur = switch (scope) {
    YanciBackgroundScope.home =>
      preset?.homeBlur ?? YanciTheme.homeBackgroundImageBlur,
    YanciBackgroundScope.chat =>
      preset?.chatBlur ?? YanciTheme.chatBackgroundImageBlur,
    YanciBackgroundScope.none => 0.0,
  };

  final image = LayoutBuilder(
    builder: (context, constraints) {
      final physicalHeight =
          constraints.maxHeight * MediaQuery.devicePixelRatioOf(context);
      final decodeHeight = (physicalHeight * scale.clamp(1.0, 2.0)).ceil();
      final provider = ResizeImage(
        FileImage(file),
        height: decodeHeight,
        allowUpscaling: false,
      );
      return Transform.translate(
        offset: Offset(
          offsetX.clamp(-0.5, 0.5).toDouble() * constraints.maxWidth,
          offsetY.clamp(-0.5, 0.5).toDouble() * constraints.maxHeight,
        ),
        child: Transform.scale(
          scale: scale.clamp(0.8, 2.0).toDouble(),
          child: Image(
            image: provider,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
            isAntiAlias: true,
          ),
        ),
      );
    },
  );
  return RepaintBoundary(
    child: ClipRect(
      child: blur <= 0.01
          ? image
          : ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: blur.clamp(0.0, 20.0).toDouble(),
                sigmaY: blur.clamp(0.0, 20.0).toDouble(),
                tileMode: TileMode.clamp,
              ),
              child: image,
            ),
    ),
  );
}

class _FeatheredBackgroundTransition extends StatefulWidget {
  const _FeatheredBackgroundTransition({
    required this.preset,
    required this.direction,
    required this.revision,
    required this.duration,
  });

  final BackgroundPreset? preset;
  final BackgroundTransitionDirection direction;
  final int revision;
  final Duration duration;

  @override
  State<_FeatheredBackgroundTransition> createState() =>
      _FeatheredBackgroundTransitionState();
}

class _FeatheredBackgroundTransitionState
    extends State<_FeatheredBackgroundTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  BackgroundPreset? _previous;
  BackgroundPreset? _current;
  late BackgroundTransitionDirection _direction;

  @override
  void initState() {
    super.initState();
    _current = widget.preset;
    _direction = widget.direction;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(_FeatheredBackgroundTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (oldWidget.revision != widget.revision) {
      _previous = _current;
      _current = widget.preset;
      _direction = widget.direction;
      _controller.forward(from: 0);
      return;
    }
    if (!_samePreset(_current, widget.preset)) {
      // Initial/theme refreshes are not caused by a carousel gesture.
      _previous = null;
      _current = widget.preset;
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return _backgroundImage(YanciBackgroundScope.home, _current);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = Curves.easeInOutCubic.transform(_controller.value);
        if (progress >= .999) {
          return _backgroundImage(YanciBackgroundScope.home, _current);
        }
        if (progress <= .001) {
          return _backgroundImage(YanciBackgroundScope.home, _previous);
        }

        final blur = sin(pi * progress) * 7;
        final previous = _backgroundImage(YanciBackgroundScope.home, _previous);
        final current = _backgroundImage(YanciBackgroundScope.home, _current);
        final currentHasImage = _hasHomeBackground(_current);
        final incomingFromRight =
            _direction == BackgroundTransitionDirection.rightToLeft;
        final incoming = FractionalTranslation(
          translation: Offset(
            (incomingFromRight ? 1 : -1) * .035 * (1 - progress),
            0,
          ),
          child: _FeatheredReveal(
            progress: progress,
            direction: _direction,
            child: current,
          ),
        );
        final outgoing = !currentHasImage
            ? _FeatheredReveal(
                progress: 1 - progress,
                direction: _opposite(_direction),
                child: previous,
              )
            : previous;

        return Positioned.fill(
          child: ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[outgoing, if (currentHasImage) incoming],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FeatheredReveal extends StatelessWidget {
  const _FeatheredReveal({
    required this.progress,
    required this.direction,
    required this.child,
  });

  final double progress;
  final BackgroundTransitionDirection direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    const feather = .14;
    final boundary = direction == BackgroundTransitionDirection.rightToLeft
        ? 1 - value
        : value;
    final low = (boundary - feather / 2).clamp(0.0, 1.0);
    final high = (boundary + feather / 2).clamp(0.0, 1.0);
    final fromRight = direction == BackgroundTransitionDirection.rightToLeft;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: fromRight
            ? const <Color>[
                Colors.transparent,
                Colors.transparent,
                Colors.white,
                Colors.white,
              ]
            : const <Color>[
                Colors.white,
                Colors.white,
                Colors.transparent,
                Colors.transparent,
              ],
        stops: <double>[0, low, high, 1],
      ).createShader(bounds),
      child: child,
    );
  }
}

BackgroundTransitionDirection _opposite(
  BackgroundTransitionDirection direction,
) => direction == BackgroundTransitionDirection.rightToLeft
    ? BackgroundTransitionDirection.leftToRight
    : BackgroundTransitionDirection.rightToLeft;

bool _samePreset(BackgroundPreset? a, BackgroundPreset? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.slot == b.slot &&
      a.homePath == b.homePath &&
      a.homeScale == b.homeScale &&
      a.homeOffsetX == b.homeOffsetX &&
      a.homeOffsetY == b.homeOffsetY &&
      a.homeBlur == b.homeBlur;
}

bool _hasHomeBackground(BackgroundPreset? preset) {
  final path = preset?.homePath.trim() ?? '';
  return path.isNotEmpty && File(path).existsSync();
}

class ChatBackgroundPresetScope extends InheritedWidget {
  final BackgroundPreset? preset;
  final ChatBubblePalette? palette;
  final BackgroundForegroundPalette? foreground;

  const ChatBackgroundPresetScope({
    super.key,
    required this.preset,
    this.palette,
    this.foreground,
    required super.child,
  });

  static ChatBackgroundPresetScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatBackgroundPresetScope>();

  static BackgroundPreset? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ChatBackgroundPresetScope>()
      ?.preset;

  @override
  bool updateShouldNotify(ChatBackgroundPresetScope oldWidget) =>
      oldWidget.preset != preset ||
      oldWidget.palette != palette ||
      oldWidget.foreground != foreground;
}

/// 極輕的噪點層 — 打破色帶的視覺邊界
class _DitherPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(42); // 固定種子，避免每次重繪閃爍
    final paint = Paint();
    const density = 0.12; // 噪點密度
    final total = (size.width * size.height * density / 100).toInt();

    for (int i = 0; i < total; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final bright = random.nextBool();
      paint.color = bright
          ? Colors.white.withValues(alpha: 0.015)
          : Colors.black.withValues(alpha: 0.012);
      canvas.drawCircle(Offset(x, y), 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
