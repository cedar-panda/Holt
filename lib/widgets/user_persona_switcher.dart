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
                                    fontWeight: FontWeight.w600,
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
                            en: 'Open role carousel',
                            zhTW: '展開角色輪播',
                            zhCN: '展开角色轮播',
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
                                child: CustomPaint(
                                  size: const Size(11, 8),
                                  painter: _InvertedTrianglePainter(
                                    color:
                                        widget.imageSecondaryForeground ??
                                        YanciTheme.textSecondary.withValues(
                                          alpha: .48,
                                        ),
                                    expanded: _carouselExpanded,
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
        AnimatedSize(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_carouselExpanded || !showCarousel
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: PersonaCarousel(
                    personas: widget.personas,
                    selectedId: widget.selectedId,
                    onSelected: _selectExisting,
                    onCreate: widget.onCreate,
                    imageSecondaryForeground: widget.imageSecondaryForeground,
                  ),
                ),
        ),
      ],
    );
  }
}

class _InvertedTrianglePainter extends CustomPainter {
  const _InvertedTrianglePainter({required this.color, this.expanded = false});

  final Color color;
  final bool expanded;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .08, size.height * .18)
      ..lineTo(size.width * .50, size.height * .88)
      ..lineTo(size.width * .92, size.height * .18);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _InvertedTrianglePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.expanded != expanded;
}
