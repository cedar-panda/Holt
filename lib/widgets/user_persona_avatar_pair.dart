import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/user_persona_service.dart';
import '../theme/app_theme.dart';

/// User-role avatar plus its mode-scoped companion binding.
///
/// Stateful to manage the red-thread unbind reverse animation: when a companion
/// is removed the thread retracts before the companion avatar disappears.
class UserPersonaAvatarPair extends StatefulWidget {
  const UserPersonaAvatarPair({
    super.key,
    required this.persona,
    this.companion,
    this.onUserAvatarTap,
    this.onBindingTap,
    this.showAddWhenUnbound = true,
    this.connectionLabel,
    this.size = 88,
  });

  final UserPersona persona;
  final Map<String, dynamic>? companion;
  final VoidCallback? onUserAvatarTap;
  final VoidCallback? onBindingTap;
  final bool showAddWhenUnbound;
  final Widget? connectionLabel;
  final double size;

  @override
  State<UserPersonaAvatarPair> createState() => _UserPersonaAvatarPairState();
}

class _UserPersonaAvatarPairState extends State<UserPersonaAvatarPair> {
  /// Kept non-null during the reverse retraction so the companion avatar
  /// remains visible while the thread rewinds.
  Map<String, dynamic>? _outgoingCompanion;

  @override
  void didUpdateWidget(UserPersonaAvatarPair old) {
    super.didUpdateWidget(old);
    if (old.persona.id != widget.persona.id) {
      _outgoingCompanion = null;
      return;
    }
    if (old.companion != null && widget.companion == null) {
      // Companion just unbound — start retraction.
      _outgoingCompanion = old.companion;
    }
  }

  void _onRetractComplete() {
    if (mounted) setState(() => _outgoingCompanion = null);
  }

  @override
  Widget build(BuildContext context) {
    final bound = widget.companion != null;
    final retracting = !bound && _outgoingCompanion != null;
    final showPair = bound || retracting;
    final companionData = widget.companion ?? _outgoingCompanion;

    return Semantics(
      container: true,
      label: bound
          ? L.pick(
              en: '${widget.persona.displayName} is bound to ${widget.companion!['name'] ?? ''}',
              zhTW:
                  '${widget.persona.displayName}已綁定${widget.companion!['name'] ?? ''}',
              zhCN:
                  '${widget.persona.displayName}已绑定${widget.companion!['name'] ?? ''}',
            )
          : L.pick(
              en: '${widget.persona.displayName} has no bound character',
              zhTW: '${widget.persona.displayName}尚未綁定角色',
              zhCN: '${widget.persona.displayName}尚未绑定角色',
            ),
      child: Row(
        key: ValueKey(
          'persona-avatar-pair-${widget.persona.id}-${companionData?['id']}',
        ),
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: _BrushRevealAvatar(
              enabled: !showPair,
              size: widget.size,
              child: _RoundAvatar(
                key: ValueKey('persona-avatar-${widget.persona.id}'),
                path: widget.persona.avatarPath,
                size: widget.size,
                fallbackIcon: Icons.person_rounded,
                onTap: widget.onUserAvatarTap,
                tooltip: L.pick(
                  en: 'Change ${widget.persona.displayName} avatar',
                  zhTW: '更換${widget.persona.displayName}的頭像',
                  zhCN: '更换${widget.persona.displayName}的头像',
                ),
              ),
            ),
          ),
          if (showPair) ...[
            RepaintBoundary(
              child: _AvatarConnection(
                size: widget.size,
                label: widget.connectionLabel,
                reverse: retracting,
                onRetractComplete: _onRetractComplete,
              ),
            ),
            RepaintBoundary(
              child: _RoundAvatar(
                key: ValueKey('bound-character-avatar-${companionData!['id']}'),
                path: companionData['avatar_path']?.toString() ?? '',
                size: widget.size,
                fallbackIcon: Icons.favorite_outline_rounded,
                onTap: retracting ? null : widget.onBindingTap,
                tooltip: L.pick(
                  en: 'Change bound character',
                  zhTW: '更改綁定角色',
                  zhCN: '更改绑定角色',
                ),
              ),
            ),
          ] else if (widget.showAddWhenUnbound) ...[
            SizedBox(width: math.max(12, widget.size * .18)),
            _DashedAddAvatar(size: widget.size, onTap: widget.onBindingTap),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Animated red thread connecting bound avatars
// ---------------------------------------------------------------------------

class _AvatarConnection extends StatefulWidget {
  const _AvatarConnection({
    required this.size,
    required this.label,
    this.reverse = false,
    this.onRetractComplete,
  });

  final double size;
  final Widget? label;
  final bool reverse;
  final VoidCallback? onRetractComplete;

  @override
  State<_AvatarConnection> createState() => _AvatarConnectionState();
}

class _AvatarConnectionState extends State<_AvatarConnection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
  }

  @override
  void didUpdateWidget(_AvatarConnection old) {
    super.didUpdateWidget(old);
    if (widget.reverse && !old.reverse) {
      _ctrl.reverse().whenComplete(() {
        widget.onRetractComplete?.call();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = math.max(
      widget.size * 1.5,
      widget.label == null ? 22.0 : 76.0,
    );
    final height = math.max(
      28.0,
      widget.size * (widget.label == null ? .52 : 1.0),
    );

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) => CustomPaint(
                  painter: _RedThreadPainter(
                    progress: Curves.easeInOutSine.transform(_ctrl.value),
                    color: _adaptiveThreadColor(),
                  ),
                ),
              ),
            ),
          ),
          if (widget.label != null) widget.label!,
        ],
      ),
    );
  }

  /// The red thread adapts to theme brightness so it's visible without
  /// overwhelming the composition.
  Color _adaptiveThreadColor() {
    const base = Color(0xFFE0525F);
    return base.withValues(alpha: YanciTheme.isDark ? .72 : .58);
  }
}

/// Draws the artistic red thread path — a line from left to right with
/// a small decorative loop/curl in the centre.
class _RedThreadPainter extends CustomPainter {
  const _RedThreadPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = _threadPath(size);
    final drawnPath = Path();
    final normalizedProgress = progress.clamp(0.0, 1.0);

    // Trace the actual curve by length. Using a rectangular reveal here would
    // expose already-drawn segments instead of making the red thread itself
    // travel along the knot. As the controller reverses, the same extracted
    // path naturally retracts from the companion back to the user avatar.
    for (final metric in path.computeMetrics()) {
      drawnPath.addPath(
        metric.extractPath(0, metric.length * normalizedProgress),
        Offset.zero,
      );
    }
    canvas.drawPath(drawnPath, paint);
  }

  /// Builds a single-stroke fate thread: a quiet horizontal lead, one narrow
  /// upright loop, then a shallow falling-and-rising tail.
  static Path _threadPath(Size size) {
    final w = size.width;
    final h = size.height;
    final constrainedByLabel = h > 56;
    final baseY = h * (constrainedByLabel ? .53 : .70);
    final loopTopY = h * (constrainedByLabel ? .22 : .10);
    final crossY = baseY - h * (constrainedByLabel ? .10 : .18);
    final exitDipY = h * (constrainedByLabel ? .58 : .78);
    final endY = h * (constrainedByLabel ? .48 : .58);

    // Tangent vectors for seamless C1 continuous transitions between segments.
    // tan1 defines the soft upward-right angle where the lead-in smoothly merges
    // into the ascending sweep of the loop without any hard kink.
    // Keep the curl visually centred between the two avatars. The crossing
    // sits just left of centre and the apex mirrors it on the right.
    final loopCenterX = w * .50;
    final cross1X = loopCenterX - w * .035;
    final cross2X = loopCenterX - w * .035;
    final tan1Dx = w * .065;
    final tan1Dy = (crossY - baseY) * .65;

    final apexX = loopCenterX + w * .035;
    final apexY = loopTopY;

    // exitTan defines the downward exit tangent through the crossing into the basin.
    final exitDx = w * .08;
    final exitDy = (exitDipY - crossY) * .55;

    final troughX = w * .74;
    final troughY = exitDipY;

    return Path()
      // 1. Calm horizontal lead-in from the left, smoothly curling into the ascent.
      ..moveTo(0, baseY)
      ..cubicTo(
        w * .14,
        baseY,
        cross1X - tan1Dx * .90,
        crossY - tan1Dy * .90,
        cross1X,
        crossY,
      )
      // 2. Rounded diagonal ascent along the right flank into the apex (↗, ↺).
      // Keep the controls close to an oval instead of pulling the upper half
      // into a narrow teardrop.
      ..cubicTo(
        cross1X + w * .105,
        crossY - h * .055,
        apexX + w * .105,
        apexY,
        apexX,
        apexY,
      )
      // 3. Match the opposite flank so the loop reads as one soft, round curl.
      ..cubicTo(
        apexX - w * .105,
        apexY,
        cross2X - w * .105,
        crossY - h * .055,
        cross2X,
        crossY,
      )
      // 4. Smooth exit through crossing into the shallow basin (→).
      ..cubicTo(
        cross2X + exitDx * 1.2,
        crossY + exitDy * 1.2,
        troughX - w * .15,
        troughY,
        troughX,
        troughY,
      )
      // 5. Rise smoothly with a gentle upward flick connecting to the companion.
      ..cubicTo(
        troughX + w * .12,
        troughY,
        w * .94,
        endY + (exitDipY - endY) * .25,
        w,
        endY,
      );
  }

  @override
  bool shouldRepaint(covariant _RedThreadPainter old) =>
      old.progress != progress || old.color != color;
}

// ---------------------------------------------------------------------------
// Public helper — create-identity slot
// ---------------------------------------------------------------------------

/// UI-only terminal slot used to create another user identity.
class UserPersonaCreateAvatar extends StatelessWidget {
  const UserPersonaCreateAvatar({
    super.key,
    required this.onTap,
    this.size = 88,
  });

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _DashedAddAvatar(
      size: size,
      onTap: onTap,
      controlKey: const ValueKey('persona-create-avatar-button'),
      semanticLabel: L.pick(en: 'Add identity', zhTW: '新增身分', zhCN: '新增身份'),
    );
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Brush-stroke reveal for single-avatar mode (3 strokes: left→right→left)
// ---------------------------------------------------------------------------

class _BrushRevealAvatar extends StatefulWidget {
  const _BrushRevealAvatar({
    required this.enabled,
    required this.size,
    required this.child,
  });

  /// When false the child is shown normally without any mask.
  final bool enabled;
  final double size;
  final Widget child;

  @override
  State<_BrushRevealAvatar> createState() => _BrushRevealAvatarState();
}

class _BrushRevealAvatarState extends State<_BrushRevealAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    if (widget.enabled) _ctrl.forward();
  }

  @override
  void didUpdateWidget(_BrushRevealAvatar old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) {
      _ctrl
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    // Keep the layout footprint at the avatar size, but let the hand-drawn
    // reveal run on a larger canvas. The extra vertical room is intentional:
    // the tilted stroke edges otherwise repeatedly meet the circle at y=0/h
    // and can look like a top/bottom hitch on real devices.
    final horizontalOverscan = math.max(10.0, widget.size * .14);
    final verticalOverscan = math.max(14.0, widget.size * .20);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -horizontalOverscan,
            right: -horizontalOverscan,
            top: -verticalOverscan,
            bottom: -verticalOverscan,
            child: SizedBox(
              key: const ValueKey('persona-brush-overscan-canvas'),
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, child) {
                  if (_ctrl.isCompleted) return child!;
                  return ClipPath(
                    clipper: _BrushStrokeClipper(progress: _ctrl.value),
                    child: child,
                  );
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalOverscan,
                    vertical: verticalOverscan,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Container(
                  key: const ValueKey('persona-brush-frame'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: .20),
                      width: 1.5,
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

/// Clips to three progressively revealed brush strokes — left→right,
/// right→left, left→right — giving a hand-painted reveal effect.
class _BrushStrokeClipper extends CustomClipper<Path> {
  _BrushStrokeClipper({required this.progress});

  final double progress;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final clip = Path();

    // Each stroke covers ~42 % of the width; overlaps guarantee full coverage.
    const sw = 0.42; // stroke-width ratio
    const tilt = 0.06; // subtle slant for hand-drawn feel

    // Stroke 1 (0.00 → 0.34): left → right.
    if (progress > 0) {
      final p = (progress / 0.34).clamp(0.0, 1.0);
      final r = w * sw * p;
      clip.addPolygon([
        Offset(0, h * tilt),
        Offset(r, 0),
        Offset(r, h),
        Offset(0, h * (1 - tilt)),
      ], true);
    }

    // Stroke 2 (0.33 → 0.67): right → left.
    if (progress > 0.33) {
      final p = ((progress - 0.33) / 0.34).clamp(0.0, 1.0);
      final r = w * 0.72;
      final l = r - w * sw * p;
      clip.addPolygon([
        Offset(l, 0),
        Offset(r, h * tilt * .6),
        Offset(r, h * (1 - tilt * .6)),
        Offset(l, h),
      ], true);
    }

    // Stroke 3 (0.66 → 1.00): left → right.
    if (progress > 0.66) {
      final p = ((progress - 0.66) / 0.34).clamp(0.0, 1.0);
      final l = w * 0.58;
      final r = l + (w - l) * p;
      clip.addPolygon([
        Offset(l, h * tilt * .5),
        Offset(r, 0),
        Offset(r, h),
        Offset(l, h * (1 - tilt * .5)),
      ], true);
    }

    return clip;
  }

  @override
  bool shouldReclip(covariant _BrushStrokeClipper old) =>
      old.progress != progress;
}

class _RoundAvatar extends StatelessWidget {
  const _RoundAvatar({
    super.key,
    required this.path,
    required this.size,
    required this.fallbackIcon,
    required this.onTap,
    required this.tooltip,
  });

  final String path;
  final double size;
  final IconData fallbackIcon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final hasImage = path.isNotEmpty && File(path).existsSync();
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: YanciTheme.accent.withValues(alpha: .08),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: .20),
          width: 1.5,
        ),
        image: hasImage
            ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover)
            : null,
      ),
      child: hasImage
          ? null
          : Icon(
              fallbackIcon,
              size: size * .44,
              color: YanciTheme.accent.withValues(alpha: .42),
            ),
    );
    if (onTap == null) return avatar;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: size * .56,
        customBorder: const CircleBorder(),
        child: avatar,
      ),
    );
  }
}

class _DashedAddAvatar extends StatelessWidget {
  const _DashedAddAvatar({
    required this.size,
    required this.onTap,
    this.controlKey,
    this.semanticLabel,
  });

  final double size;
  final VoidCallback? onTap;
  final Key? controlKey;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          semanticLabel ??
          L.pick(
            en: 'Bind an existing character',
            zhTW: '綁定現有角色',
            zhCN: '绑定现有角色',
          ),
      child: InkResponse(
        key: controlKey ?? const ValueKey('persona-bind-character-button'),
        onTap: onTap,
        radius: size * .56,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _HandDashedCirclePainter(
              color: YanciTheme.accent.withValues(alpha: .34),
            ),
            child: Icon(
              Icons.add_rounded,
              size: size * .34,
              color: YanciTheme.accent.withValues(alpha: .58),
            ),
          ),
        ),
      ),
    );
  }
}

class _HandDashedCirclePainter extends CustomPainter {
  const _HandDashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    const dashCount = 18;
    for (var i = 0; i < dashCount; i++) {
      final wobble = (i.isEven ? .012 : -.009);
      final start = i * math.pi * 2 / dashCount + wobble;
      final sweep = math.pi * 2 / dashCount * (i % 3 == 0 ? .53 : .42);
      canvas.drawArc(rect, start, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HandDashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}
