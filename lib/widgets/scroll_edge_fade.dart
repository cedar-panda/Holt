import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// Softens the point where a scrolling conversation enters and leaves view.
///
/// The alpha mask fades the message content itself. A caller can optionally
/// add a very small amount of edge blur; pass a non-positive [blurSigma] for a
/// clean alpha-only fade over image backgrounds.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    required this.controller,
    required this.child,
    this.topExtent = 28,
    this.bottomExtent = 34,
    this.topInset = 0,
    this.blurSigma = 2.4,
    this.topBlurSigma,
    this.bottomBlurSigma,
    this.alwaysFadeTop = false,
    this.alwaysFadeBottom = false,
  });

  final ScrollController controller;
  final Widget child;
  final double topExtent;
  final double bottomExtent;

  /// Height at the top that stays fully transparent (e.g. hidden under a
  /// header); the fade ramp runs from here to [topExtent].
  final double topInset;

  /// Backwards-compatible default for both edges. Prefer the edge-specific
  /// values when only one side should receive a real blur.
  final double blurSigma;
  final double? topBlurSigma;
  final double? bottomBlurSigma;
  final bool alwaysFadeTop;
  final bool alwaysFadeBottom;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _showTop = false;
  bool _showBottom = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
  }

  @override
  void didUpdateWidget(covariant ScrollEdgeFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncEdges);
      widget.controller.addListener(_syncEdges);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncEdges);
    super.dispose();
  }

  void _syncEdges() {
    if (!mounted || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final nextTop = position.pixels > position.minScrollExtent + 1;
    final nextBottom = position.pixels < position.maxScrollExtent - 1;
    if (nextTop == _showTop && nextBottom == _showBottom) return;
    setState(() {
      _showTop = nextTop;
      _showBottom = nextBottom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final showTop = _showTop || widget.alwaysFadeTop;
    final showBottom = _showBottom || widget.alwaysFadeBottom;
    final topBlurSigma = widget.topBlurSigma ?? widget.blurSigma;
    final bottomBlurSigma = widget.bottomBlurSigma ?? widget.blurSigma;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final height = bounds.height <= 0 ? 1.0 : bounds.height;
            final topStop = (widget.topExtent / height).clamp(0.0, .30);
            final bottomStop = (1 - widget.bottomExtent / height).clamp(
              .70,
              1.0,
            );
            // Fully transparent through [topInset] (e.g. under the header),
            // then a long, gently eased 0 -> 100% ramp, like a Photoshop
            // gradient fill: no knee, no visible band edge.
            const steps = 32;
            final insetStop = (widget.topInset / height).clamp(0.0, topStop);
            final colors = <Color>[];
            final stops = <double>[];
            if (showTop && insetStop > 0) {
              colors.add(Colors.white.withValues(alpha: 0));
              stops.add(0);
            }
            for (var i = 0; i <= steps; i++) {
              final t = i / steps;
              final eased = 0.5 - 0.5 * math.cos(math.pi * t);
              colors.add(Colors.white.withValues(alpha: showTop ? eased : 1.0));
              stops.add(insetStop + (topStop - insetStop) * t);
            }
            for (var i = 0; i <= steps; i++) {
              final t = i / steps;
              final eased = 0.5 - 0.5 * math.cos(math.pi * t);
              colors.add(
                Colors.white.withValues(alpha: showBottom ? 1 - eased : 1.0),
              );
              stops.add(bottomStop + (1 - bottomStop) * t);
            }
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors,
              stops: stops,
            ).createShader(bounds);
          },
          child: widget.child,
        ),
        if (topBlurSigma > 0) ...[
          _EdgeBlur(
            alignment: Alignment.topCenter,
            extent: widget.topExtent,
            sigma: topBlurSigma,
            visible: showTop,
            reduceMotion: reduceMotion,
          ),
        ],
        if (bottomBlurSigma > 0) ...[
          _EdgeBlur(
            alignment: Alignment.bottomCenter,
            extent: widget.bottomExtent,
            sigma: bottomBlurSigma,
            visible: showBottom,
            reduceMotion: reduceMotion,
          ),
        ],
      ],
    );
  }
}

class _EdgeBlur extends StatelessWidget {
  const _EdgeBlur({
    required this.alignment,
    required this.extent,
    required this.sigma,
    required this.visible,
    required this.reduceMotion,
  });

  final Alignment alignment;
  final double extent;
  final double sigma;
  final bool visible;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          child: ClipRect(
            child: SizedBox(
              width: double.infinity,
              height: extent,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
