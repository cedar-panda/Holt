import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/user_persona_service.dart';
import '../theme/app_theme.dart';
import 'persona_carousel.dart';

/// Name-level selector for the user-authored roles shown on the Me page.
///
/// The page owns persistence and companion synchronization. This widget owns
/// only selection gestures and presentation, keeping carousel motion out of the
/// already large home screen.
class UserPersonaSwitcher extends StatefulWidget {
  const UserPersonaSwitcher({
    super.key,
    required this.personas,
    required this.selectedId,
    required this.onSelected,
    required this.onOpenProfile,
    this.onCreate,
    this.createSlotSelected = false,
    this.onCreateSlotChanged,
    this.hideName = false,
    this.imagePrimaryForeground,
    this.imageSecondaryForeground,
  });

  final List<UserPersona> personas;
  final String selectedId;
  final ValueChanged<UserPersona> onSelected;
  final VoidCallback onOpenProfile;
  final VoidCallback? onCreate;
  final bool createSlotSelected;
  final ValueChanged<bool>? onCreateSlotChanged;
  final bool hideName;
  final Color? imagePrimaryForeground;
  final Color? imageSecondaryForeground;

  @override
  State<UserPersonaSwitcher> createState() => _UserPersonaSwitcherState();
}

class _UserPersonaSwitcherState extends State<UserPersonaSwitcher> {
  bool _carouselExpanded = false;

  int get _selectedIndex {
    final index = widget.personas.indexWhere(
      (persona) => persona.id == widget.selectedId,
    );
    return index < 0 ? 0 : index;
  }

  void _selectExisting(UserPersona persona) {
    widget.onCreateSlotChanged?.call(false);
    widget.onSelected(persona);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.personas.isEmpty) return const SizedBox.shrink();
    final selected = widget.createSlotSelected
        ? null
        : widget.personas[_selectedIndex];
    final showCarousel =
        widget.personas.isNotEmpty && !widget.createSlotSelected;
    final reduced = MediaQuery.disableAnimationsOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 294,
          height: 48,
          child: selected == null
              ? const SizedBox.shrink()
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!widget.hideName)
                      Center(
                        child: Semantics(
                          button: true,
                          label: L.pick(
                            en: 'Open ${selected.displayName} profile',
                            zhTW: '開啟${selected.displayName}的檔案',
                            zhCN: '打开${selected.displayName}的档案',
                          ),
                          child: InkWell(
                            key: const ValueKey('persona-open-profile'),
                            onTap: widget.onOpenProfile,
                            borderRadius: BorderRadius.circular(20),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 144),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  selected.displayName.isEmpty
                                      ? L.pick(
                                          en: 'Unnamed identity',
                                          zhTW: '未命名身分',
                                          zhCN: '未命名身份',
                                        )
                                      : selected.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w400,
                                    color:
                                        widget.imagePrimaryForeground ??
                                        YanciTheme.textPrimary,
                                    fontFamily: YanciTheme.fontFamily,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (showCarousel)
                      Positioned(
                        right: 34,
                        child: Semantics(
                          button: true,
                          expanded: _carouselExpanded,
                          label: L.pick(
                            en: _carouselExpanded
                                ? 'Close role carousel'
                                : 'Open role carousel',
                            zhTW: _carouselExpanded ? '收起角色輪播' : '展開角色輪播',
                            zhCN: _carouselExpanded ? '收起角色轮播' : '展开角色轮播',
                          ),
                          child: InkResponse(
                            key: const ValueKey('persona-carousel-toggle'),
                            onTap: () => setState(
                              () => _carouselExpanded = !_carouselExpanded,
                            ),
                            radius: 22,
                            child: SizedBox(
                              width: 40,
                              height: 44,
                              child: Center(
                                child: AnimatedSlide(
                                  duration: reduced
                                      ? Duration.zero
                                      : const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  offset: _carouselExpanded
                                      ? const Offset(0, -0.08)
                                      : Offset.zero,
                                  child: AnimatedScale(
                                    duration: reduced
                                        ? Duration.zero
                                        : const Duration(milliseconds: 220),
                                    curve: Curves.easeOutCubic,
                                    scale: _carouselExpanded ? 1.08 : 1,
                                    child: AnimatedRotation(
                                      key: const ValueKey(
                                        'persona-carousel-chevron',
                                      ),
                                      turns: _carouselExpanded ? 0.5 : 0,
                                      duration: reduced
                                          ? Duration.zero
                                          : const Duration(milliseconds: 220),
                                      curve: Curves.easeOutCubic,
                                      child: CustomPaint(
                                        size: const Size(13, 9),
                                        painter: _InvertedTrianglePainter(
                                          color:
                                              widget.imageSecondaryForeground ??
                                              YanciTheme.textSecondary
                                                  .withValues(alpha: .62),
                                        ),
                                      ),
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
        ),
        if (showCarousel)
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _carouselExpanded ? 1 : 0),
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PersonaCarousel(
                personas: widget.personas,
                selectedId: widget.selectedId,
                onSelected: _selectExisting,
                onCreate: widget.onCreate,
                imageSecondaryForeground: widget.imageSecondaryForeground,
              ),
            ),
            builder: (context, value, child) => ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: value,
                child: Opacity(
                  opacity: value,
                  child: IgnorePointer(
                    ignoring: !_carouselExpanded,
                    child: TickerMode(
                      enabled: _carouselExpanded,
                      child: child!,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InvertedTrianglePainter extends CustomPainter {
  const _InvertedTrianglePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outlineColor = color.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.2);
    final outlinePaint = Paint()
      ..color = outlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .08, size.height * .18)
      ..lineTo(size.width * .50, size.height * .88)
      ..lineTo(size.width * .92, size.height * .18);
    canvas.drawPath(path, outlinePaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _InvertedTrianglePainter oldDelegate) =>
      oldDelegate.color != color;
}
