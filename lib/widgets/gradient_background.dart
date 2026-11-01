import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter, TileMode;
import 'dart:ui' as ui;

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
  final Duration? customBackgroundTransitionDuration;
  final BackgroundTransitionDirection customBackgroundTransitionDirection;
  final double customBackgroundOpacity;
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
    this.customBackgroundTransitionDuration,
    this.customBackgroundTransitionDirection =
        BackgroundTransitionDirection.rightToLeft,
    this.customBackgroundOpacity = 1,
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
          _AnimatedCustomBackgroundVisibility(
            opacity: customBackgroundOpacity,
            duration: customBackgroundTransitionDuration ?? transitionDuration,
            direction: customBackgroundTransitionDirection,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[customBackground],
            ),
          ),
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

/// 在主題底色與角色綁定背景之間做柔和交接。
///
/// 保持實際背景來源不變，只調整其可見度；因此角色頁可以回到純主題色，
/// 再切回首頁／我的時仍沿用首頁目前交流角色的綁定背景。
class _AnimatedCustomBackgroundVisibility extends StatefulWidget {
  const _AnimatedCustomBackgroundVisibility({
    required this.opacity,
    required this.duration,
    required this.direction,
    required this.child,
  });

  final double opacity;
  final Duration duration;
  final BackgroundTransitionDirection direction;
  final Widget child;

  @override
  State<_AnimatedCustomBackgroundVisibility> createState() =>
      _AnimatedCustomBackgroundVisibilityState();
}

class _AnimatedCustomBackgroundVisibilityState
    extends State<_AnimatedCustomBackgroundVisibility>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late BackgroundTransitionDirection _direction;
  bool _revealing = true;

  @override
  void initState() {
    super.initState();
    _direction = widget.direction;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.opacity.clamp(0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(_AnimatedCustomBackgroundVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    final target = widget.opacity.clamp(0.0, 1.0);
    if ((target - oldWidget.opacity.clamp(0.0, 1.0)).abs() > 0.001) {
      _direction = widget.direction;
      _revealing = target > _controller.value;
      _controller.animateTo(target, curve: Curves.easeInOutCubic);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      return widget.opacity <= 0.001
          ? const SizedBox.shrink()
          : Opacity(opacity: widget.opacity, child: widget.child);
    }
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final value = _controller.value;
        if (value <= 0.001) return const SizedBox.shrink();
        if (value >= 0.999 && !_controller.isAnimating) return child!;
        final transitionProgress = _revealing ? value : 1 - value;
        // Match the home character carousel's visual rhythm: the outgoing
        // background cross-fades as the blur peaks around the hand-off, while
        // the feathered edge preserves the tab's spatial direction.
        final blur = (pow(sin(pi * transitionProgress), 0.75) * 10).toDouble();
        final revealDirection = _revealing ? _direction : _opposite(_direction);
        final translated = Opacity(
          opacity: value,
          child: FractionalTranslation(
            translation: Offset(
              (revealDirection == BackgroundTransitionDirection.rightToLeft
                      ? 1
                      : -1) *
                  .035 *
                  (1 - transitionProgress),
              0,
            ),
            child: _FeatheredReveal(
              progress: value,
              direction: revealDirection,
              child: child!,
            ),
          ),
        );
        return KeyedSubtree(
          key: const ValueKey('custom-background-visibility'),
          child: ClipRect(
            child: blur <= 0.01
                ? translated
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: blur,
                      sigmaY: blur,
                      tileMode: TileMode.clamp,
                    ),
                    child: translated,
                  ),
          ),
        );
      },
    );
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
  if (blur <= 0.01) {
    return RepaintBoundary(child: ClipRect(child: image));
  }
  final live = ImageFiltered(
    imageFilter: ImageFilter.blur(
      sigmaX: blur.clamp(0.0, 20.0).toDouble(),
      sigmaY: blur.clamp(0.0, 20.0).toDouble(),
      tileMode: TileMode.clamp,
    ),
    child: image,
  );
  return RepaintBoundary(
    child: ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) => _BakedBlurBackground(
          file: file,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
          blur: blur,
          size: constraints.biggest,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          live: live,
        ),
      ),
    ),
  );
}

/// 靜態背景圖的模糊預烘焙。
///
/// Impeller 沒有 raster cache：粒子或串流每刷一幀，`ImageFiltered` 的全螢幕
/// 模糊就重算一次。這裡在背景／模糊參數改變時把結果畫成一張圖，之後每幀只
/// 貼圖。烘焙完成前（或拖動滑桿時）先顯示即時模糊，不會閃白。
class _BakedBlurBackground extends StatefulWidget {
  const _BakedBlurBackground({
    required this.file,
    required this.scale,
    required this.offsetX,
    required this.offsetY,
    required this.blur,
    required this.size,
    required this.devicePixelRatio,
    required this.live,
  });

  final File file;
  final double scale;
  final double offsetX;
  final double offsetY;
  final double blur;
  final Size size;
  final double devicePixelRatio;
  final Widget live;

  @override
  State<_BakedBlurBackground> createState() => _BakedBlurBackgroundState();
}

class _BakedBlurBackgroundState extends State<_BakedBlurBackground> {
  /// 參數停止變動多久後才烘焙（拖滑桿時只顯示即時模糊）。
  static const Duration _bakeDebounce = Duration(milliseconds: 250);

  /// sigma ≥ 這個值時用半解析度烘焙：模糊後沒有細節，肉眼看不出差別。
  static const double _halfResolutionMinBlur = 3;

  /// 最多保留幾張烘焙結果（首頁／聊天／切換來回時重用）。
  static const int _cacheLimit = 3;
  static final Map<String, ui.Image> _cache = <String, ui.Image>{};

  ui.Image? _image;
  String? _imageKey;
  String? _pendingKey;
  Timer? _timer;

  String get _key {
    var modified = 0;
    try {
      modified = widget.file.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      // 讀不到修改時間時只用路徑與參數當 key。
    }
    return <Object>[
      widget.file.path,
      modified,
      widget.scale,
      widget.offsetX,
      widget.offsetY,
      widget.blur,
      widget.size.width,
      widget.size.height,
      widget.devicePixelRatio,
    ].join('|');
  }

  @override
  void initState() {
    super.initState();
    _schedule(debounce: false, rebuild: false);
  }

  @override
  void didUpdateWidget(_BakedBlurBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final key = _key;
    if (key != _imageKey && key != _pendingKey) {
      // didUpdateWidget 之後一定會 build，不需要 setState。
      _schedule(debounce: true, rebuild: false);
    }
  }

  void _schedule({required bool debounce, required bool rebuild}) {
    final key = _key;
    _pendingKey = key;
    _timer?.cancel();
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // 移到最新（LRU）
      _pendingKey = null;
      _show(key, cached.clone(), rebuild: rebuild);
      return;
    }
    if (widget.size.isEmpty || !widget.size.isFinite) return;
    _timer = Timer(
      debounce ? _bakeDebounce : Duration.zero,
      () => unawaited(_bake(key)),
    );
  }

  Future<void> _bake(String key) async {
    try {
      final baked = await _render();
      if (!mounted || _pendingKey != key) {
        baked.dispose();
        return;
      }
      _cache[key] = baked;
      while (_cache.length > _cacheLimit) {
        _cache.remove(_cache.keys.first)?.dispose();
      }
      _pendingKey = null;
      _show(key, baked.clone(), rebuild: true);
    } catch (error) {
      // 烘焙失敗就維持即時模糊，畫面不受影響。
      debugPrint('Background blur bake failed: $error');
    }
  }

  void _show(String key, ui.Image image, {required bool rebuild}) {
    final previous = _image;
    _image = image;
    _imageKey = key;
    if (rebuild && mounted) setState(() {});
    previous?.dispose();
  }

  /// 重現 `_backgroundImage` 的版面：cover → 以中心縮放 → 位移 → 模糊。
  /// 全部在物理像素座標下畫，模糊 sigma 同步換算，不依賴畫布矩陣。
  Future<ui.Image> _render() async {
    final w = widget.size.width;
    final h = widget.size.height;
    final dpr = widget.devicePixelRatio;
    final resolution = widget.blur >= _halfResolutionMinBlur ? 0.5 : 1.0;
    final k = dpr * resolution;
    final pixelWidth = max(1, (w * k).round());
    final pixelHeight = max(1, (h * k).round());

    final bytes = await widget.file.readAsBytes();
    final decodeHeight = (h * dpr * widget.scale.clamp(1.0, 2.0)).ceil();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetHeight: decodeHeight,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final source = frame.image;
    try {
      final imageSize = Size(source.width.toDouble(), source.height.toDouble());
      final box = Offset.zero & Size(w, h);
      final fitted = applyBoxFit(BoxFit.cover, imageSize, box.size);
      final sourceRect = Alignment.center.inscribe(
        fitted.source,
        Offset.zero & imageSize,
      );
      final fittedRect = Alignment.center.inscribe(fitted.destination, box);
      final s = widget.scale.clamp(0.8, 2.0).toDouble();
      final c = box.center;
      final shift = Offset(
        widget.offsetX.clamp(-0.5, 0.5).toDouble() * w,
        widget.offsetY.clamp(-0.5, 0.5).toDouble() * h,
      );
      final logicalRect = Rect.fromLTRB(
        c.dx + (fittedRect.left - c.dx) * s,
        c.dy + (fittedRect.top - c.dy) * s,
        c.dx + (fittedRect.right - c.dx) * s,
        c.dy + (fittedRect.bottom - c.dy) * s,
      ).shift(shift);
      final pixelRect = Rect.fromLTRB(
        logicalRect.left * k,
        logicalRect.top * k,
        logicalRect.right * k,
        logicalRect.bottom * k,
      );
      final sigma = widget.blur.clamp(0.0, 20.0).toDouble() * k;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Offset.zero & Size(pixelWidth.toDouble(), pixelHeight.toDouble()),
      );
      canvas.saveLayer(
        null,
        Paint()
          ..imageFilter = ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      );
      canvas.drawImageRect(
        source,
        sourceRect,
        pixelRect,
        Paint()
          ..filterQuality = FilterQuality.high
          ..isAntiAlias = true,
      );
      canvas.restore();
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(pixelWidth, pixelHeight);
      } finally {
        picture.dispose();
      }
    } finally {
      source.dispose();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null || _imageKey != _key) return widget.live;
    // RawImage 不管理 ui.Image 生命週期；State 持有這份 clone，並在替換或
    // dispose 時釋放。不要在 build 裡再次 clone，否則每次重建都會漏掉
    // 一個 GPU image handle。
    return RawImage(
      image: image,
      width: widget.size.width,
      height: widget.size.height,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// 把一張已預烘焙的全螢幕背景，依螢幕座標裁成卡片內的局部模糊。
///
/// 此元件與首頁背景共用 [_BakedBlurBackground] 的 LRU；每幀只移動／裁切
/// 已完成的 ui.Image，不使用 BackdropFilter 或 ImageFiltered 即時模糊。
class BakedCardRegionBlur extends StatelessWidget {
  const BakedCardRegionBlur({
    super.key,
    required this.file,
    required this.scale,
    required this.offsetX,
    required this.offsetY,
    required this.blur,
    required this.viewportSize,
    required this.regionOffset,
    required this.devicePixelRatio,
    required this.overlayColor,
  });

  final File file;
  final double scale;
  final double offsetX;
  final double offsetY;
  final double blur;
  final Size viewportSize;
  final Offset regionOffset;
  final double devicePixelRatio;
  final Color overlayColor;

  @override
  Widget build(BuildContext context) {
    if (viewportSize.isEmpty || !viewportSize.isFinite || !file.existsSync()) {
      return ColoredBox(color: overlayColor);
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: viewportSize.width,
            maxWidth: viewportSize.width,
            minHeight: viewportSize.height,
            maxHeight: viewportSize.height,
            child: Transform.translate(
              offset: -regionOffset,
              child: SizedBox.fromSize(
                size: viewportSize,
                child: _BakedBlurBackground(
                  file: file,
                  scale: scale,
                  offsetX: offsetX,
                  offsetY: offsetY,
                  blur: blur,
                  size: viewportSize,
                  devicePixelRatio: devicePixelRatio,
                  live: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          ColoredBox(color: overlayColor),
        ],
      ),
    );
  }
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

  /// Adaptive foreground and bubble colors belong to the chat image only.
  /// A home-only image in the same preset must not tint a theme-backed chat.
  bool get hasCustomImage {
    final path = preset?.chatPath.trim() ?? '';
    return path.isNotEmpty && File(path).existsSync();
  }

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
