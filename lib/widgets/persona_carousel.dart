import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/locale_strings.dart';
import '../services/user_persona_service.dart';
import '../theme/app_theme.dart';

/// Theme-workshop-style carousel for switching among user-authored roles.
///
/// The search affordance intentionally remains part of this component so the
/// role-management page keeps its existing fast path for larger persona sets.
class PersonaCarousel extends StatefulWidget {
  const PersonaCarousel({
    super.key,
    required this.personas,
    required this.selectedId,
    required this.onSelected,
    this.onCreate,
    this.imageSecondaryForeground,
  });

  final List<UserPersona> personas;
  final String selectedId;
  final ValueChanged<UserPersona> onSelected;
  final VoidCallback? onCreate;
  final Color? imageSecondaryForeground;

  @override
  State<PersonaCarousel> createState() => _PersonaCarouselState();
}

class _PersonaCarouselState extends State<PersonaCarousel> {
  static const double _carouselWidth = 294;
  static const double _carouselHeight = 132;
  // A page must be at least as wide as the 72 px avatar. The previous 0.18
  // made adjacent hit regions overlap, so middle identities were difficult to
  // stop on while the two ends still felt selectable.
  static const double _pageViewportFraction = 0.25;

  late PageController _carouselController;
  int _currentCarouselPage = 0;
  int? _programmaticTargetPage;
  Set<String> _starredPersonaIds = <String>{};
  bool _starredPersonaIdsLoaded = false;

  int get _selectedIndex {
    final index = _orderedPersonas.indexWhere(
      (persona) => persona.id == widget.selectedId,
    );
    if (index >= 0) return index;
    if (_orderedPersonas.isEmpty) return 0;
    return _currentCarouselPage.clamp(0, _orderedPersonas.length - 1);
  }

  @override
  void initState() {
    super.initState();
    _currentCarouselPage = _selectedIndex;
    _carouselController = PageController(
      viewportFraction: _pageViewportFraction,
      initialPage: _currentCarouselPage,
    );
    _loadStarredPersonaIds();
  }

  @override
  void didUpdateWidget(PersonaCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_starredPersonaIdsLoaded) return;
    // A parent reload often replaces the list instance without changing the
    // selected identity. Treating that as a new selection caused a hard jump
    // (usually through page zero) while the carousel was being dragged.
    if (oldWidget.selectedId != widget.selectedId &&
        _orderedPersonas.any((persona) => persona.id == widget.selectedId)) {
      _syncCarouselToSelection(animate: false);
    }
  }

  @override
  void dispose() {
    _carouselController.dispose();
    super.dispose();
  }

  Future<void> _loadStarredPersonaIds() async {
    final ids = await UserPersonaService.getStarredPersonaIds();
    if (!mounted) return;
    _replaceOrderWithoutMotion(ids);
  }

  List<UserPersona> _orderedPersonasFor(Set<String> starredIds) {
    final starred = widget.personas
        .where((persona) => starredIds.contains(persona.id))
        .toList(growable: false);
    final regular = widget.personas
        .where((persona) => !starredIds.contains(persona.id))
        .toList(growable: false);
    return <UserPersona>[...starred, ...regular];
  }

  List<UserPersona> get _orderedPersonas =>
      _orderedPersonasFor(_starredPersonaIds);

  void _replaceOrderWithoutMotion(Set<String> starredIds) {
    final previousOrder = _orderedPersonas;
    final visibleId =
        _currentCarouselPage >= 0 && _currentCarouselPage < previousOrder.length
        ? previousOrder[_currentCarouselPage].id
        : widget.selectedId;
    final ordered = _orderedPersonasFor(starredIds);
    var nextPage = ordered.indexWhere((persona) => persona.id == visibleId);
    if (nextPage < 0) {
      nextPage = ordered.indexWhere(
        (persona) => persona.id == widget.selectedId,
      );
    }
    if (nextPage < 0) {
      nextPage = ordered.isEmpty
          ? 0
          : _currentCarouselPage.clamp(0, ordered.length - 1);
    }
    final previousController = _carouselController;
    final replacementController = PageController(
      viewportFraction: _pageViewportFraction,
      initialPage: nextPage,
    );
    setState(() {
      _starredPersonaIds = starredIds;
      _starredPersonaIdsLoaded = true;
      _currentCarouselPage = nextPage;
      _programmaticTargetPage = null;
      _carouselController = replacementController;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
  }

  void _syncCarouselToSelection({required bool animate}) {
    if (!_carouselController.hasClients || _orderedPersonas.isEmpty) return;
    final index = _selectedIndex;
    final currentShowsSelection =
        _currentCarouselPage >= 0 &&
        _currentCarouselPage < _orderedPersonas.length &&
        _orderedPersonas[_currentCarouselPage].id == widget.selectedId;
    if (currentShowsSelection ||
        (_programmaticTargetPage == index && currentShowsSelection)) {
      return;
    }
    _currentCarouselPage = index;
    _programmaticTargetPage = animate ? index : null;
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      _carouselController.jumpToPage(index);
    } else {
      _carouselController.animateToPage(
        index,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _selectPage(int index) {
    if (index < 0 || index >= _orderedPersonas.length) return;
    final persona = _orderedPersonas[index];
    if (index == _currentCarouselPage) {
      _programmaticTargetPage = null;
      if (persona.id != widget.selectedId) {
        HapticFeedback.selectionClick();
        widget.onSelected(persona);
      }
      return;
    }
    _programmaticTargetPage = index;
    if (persona.id != widget.selectedId) {
      HapticFeedback.selectionClick();
      widget.onSelected(persona);
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _carouselController.jumpToPage(index);
    } else {
      _carouselController.animateToPage(
        index,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onPageChanged(int index) {
    if (index < 0 || index >= _orderedPersonas.length) return;
    _currentCarouselPage = index;
    final target = _programmaticTargetPage;
    if (target != null) {
      if (index == target) _programmaticTargetPage = null;
      if (mounted) setState(() {});
      return;
    }
    final persona = _orderedPersonas[index];
    if (persona.id != widget.selectedId) {
      HapticFeedback.selectionClick();
      widget.onSelected(persona);
    }
    if (mounted) setState(() {});
  }

  Future<void> _setStarred(String personaId, bool starred) async {
    await UserPersonaService.setPersonaStarred(personaId, starred);
    if (!mounted) return;
    final ids = Set<String>.of(_starredPersonaIds);
    if (starred) {
      ids.add(personaId);
    } else {
      ids.remove(personaId);
    }
    _replaceOrderWithoutMotion(ids);
  }

  Future<void> _showAllPersonas() async {
    final selected = await showModalBottomSheet<UserPersona>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .52),
      builder: (sheetContext) => _PersonaAllDrawer(
        personas: _orderedPersonas,
        starredIds: _starredPersonaIds,
        onToggleStar: _setStarred,
        onSelected: (persona) => Navigator.of(sheetContext).pop(persona),
      ),
    );
    if (!mounted || selected == null) return;
    final index = _orderedPersonas.indexWhere(
      (persona) => persona.id == selected.id,
    );
    _selectPage(index);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.personas.isEmpty) {
      return const SizedBox(width: _carouselWidth, height: _carouselHeight);
    }
    if (!_starredPersonaIdsLoaded) {
      final selectedIndex = widget.personas.indexWhere(
        (persona) => persona.id == widget.selectedId,
      );
      final selected = widget.personas[selectedIndex < 0 ? 0 : selectedIndex];
      return Semantics(
        container: true,
        label: L.pick(en: 'Role carousel', zhTW: '角色輪播選擇器', zhCN: '角色轮播选择器'),
        child: SizedBox(
          width: _carouselWidth,
          height: _carouselHeight,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 88,
              child: Center(
                child: _PersonaCarouselAvatar(
                  persona: selected,
                  size: 72,
                  selected: true,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      label: L.pick(en: 'Role carousel', zhTW: '角色輪播選擇器', zhCN: '角色轮播选择器'),
      child: SizedBox(
        width: _carouselWidth,
        height: _carouselHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              width: _carouselWidth,
              height: 88,
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: (notification) {
                  if (notification.dragDetails != null) {
                    _programmaticTargetPage = null;
                  }
                  return false;
                },
                child: PageView.builder(
                  key: const ValueKey('persona-carousel'),
                  clipBehavior: Clip.none,
                  physics: const PageScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  controller: _carouselController,
                  // The create identity slot is always the terminal page, so
                  // one-role accounts use the same discoverable path as
                  // larger role collections.
                  itemCount: _orderedPersonas.length + 1,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final personas = _orderedPersonas;
                    final isCreateSlot = index == personas.length;
                    final persona = isCreateSlot ? null : personas[index];
                    return AnimatedBuilder(
                      animation: _carouselController,
                      builder: (context, child) {
                        double page;
                        try {
                          page =
                              _carouselController.page ??
                              _currentCarouselPage.toDouble();
                        } catch (_) {
                          page = _currentCarouselPage.toDouble();
                        }
                        final diff = (page - index).abs();
                        // Keep every avatar on one continuous scale curve.
                        // The old 72/52 size switch promoted a page while it
                        // was still half a slot away, making the selected
                        // avatar look off-centre during snapping.
                        final scale = (1.0 - diff * 0.46).clamp(0.54, 1.0);
                        final opacity = (1.0 - diff * 0.4).clamp(0.2, 1.0);
                        final isCenter = diff < 0.08;

                        return Center(
                          child: Transform.scale(
                            scale: scale,
                            child: Opacity(
                              opacity: opacity,
                              child: isCreateSlot
                                  ? Semantics(
                                      button: widget.onCreate != null,
                                      label: L.pick(
                                        en: 'Create a new identity',
                                        zhTW: '新增你的身分',
                                        zhCN: '新增你的身份',
                                      ),
                                      child: GestureDetector(
                                        key: const ValueKey(
                                          'persona-create-slot',
                                        ),
                                        onTap: widget.onCreate,
                                        child: _CreatePersonaAvatar(
                                          size: 72,
                                          imageForeground:
                                              widget.imageSecondaryForeground,
                                        ),
                                      ),
                                    )
                                  : Semantics(
                                      button: true,
                                      selected: isCenter,
                                      label: L.pick(
                                        en: '${persona!.displayName} role',
                                        zhTW: '${persona.displayName}角色',
                                        zhCN: '${persona.displayName}角色',
                                      ),
                                      child: GestureDetector(
                                        key: ValueKey(
                                          'persona-carousel-slot-${persona.id}',
                                        ),
                                        onTap: () => _selectPage(index),
                                        child: _PersonaCarouselAvatar(
                                          persona: persona,
                                          size: 72,
                                          selected: isCenter,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _ViewAllButton(
                  onTap: _showAllPersonas,
                  imageForeground: widget.imageSecondaryForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreatePersonaAvatar extends StatelessWidget {
  const _CreatePersonaAvatar({required this.size, this.imageForeground});

  final double size;
  final Color? imageForeground;

  @override
  Widget build(BuildContext context) {
    final color =
        imageForeground ?? YanciTheme.textSecondary.withValues(alpha: .46);
    return CustomPaint(
      size: Size.square(size),
      painter: _DashedCirclePainter(color: color),
      child: Center(
        child: Icon(Icons.add_rounded, size: size * .32, color: color),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - paint.strokeWidth;
    const dashCount = 24;
    const dashSweep = .12;
    const gapSweep = (math.pi * 2 - dashCount * dashSweep) / dashCount;
    for (var i = 0; i < dashCount; i++) {
      final start = -math.pi / 2 + i * (dashSweep + gapSweep);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        dashSweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ViewAllButton extends StatelessWidget {
  const _ViewAllButton({required this.onTap, this.imageForeground});

  final VoidCallback onTap;
  final Color? imageForeground;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: L.pick(en: 'View all roles', zhTW: '查看全部角色', zhCN: '查看全部角色'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('persona-view-all-button'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            constraints: const BoxConstraints(minWidth: 96, minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              L.pick(en: 'View all', zhTW: '查看全部', zhCN: '查看全部'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: YanciTheme.fontFamily,
                fontSize: 12,
                color:
                    imageForeground ??
                    YanciTheme.textSecondary.withValues(alpha: .50),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonaAllDrawer extends StatefulWidget {
  const _PersonaAllDrawer({
    required this.personas,
    required this.starredIds,
    required this.onToggleStar,
    required this.onSelected,
  });

  final List<UserPersona> personas;
  final Set<String> starredIds;
  final Future<void> Function(String personaId, bool starred) onToggleStar;
  final ValueChanged<UserPersona> onSelected;

  @override
  State<_PersonaAllDrawer> createState() => _PersonaAllDrawerState();
}

class _PersonaAllDrawerState extends State<_PersonaAllDrawer> {
  late Set<String> _starredIds;
  late final TextEditingController _searchController;
  bool _searchExpanded = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _starredIds = {...widget.starredIds};
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<UserPersona> get _orderedPersonas {
    final starred = widget.personas
        .where((persona) => _starredIds.contains(persona.id))
        .toList(growable: false);
    final regular = widget.personas
        .where((persona) => !_starredIds.contains(persona.id))
        .toList(growable: false);
    return <UserPersona>[...starred, ...regular];
  }

  List<UserPersona> get _visiblePersonas {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _orderedPersonas;
    return _orderedPersonas
        .where((persona) => persona.displayName.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _toggleStar(String personaId) async {
    final next = !_starredIds.contains(personaId);
    setState(() {
      if (next) {
        _starredIds.add(personaId);
      } else {
        _starredIds.remove(personaId);
      }
    });
    try {
      await widget.onToggleStar(personaId, next);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (next) {
          _starredIds.remove(personaId);
        } else {
          _starredIds.add(personaId);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final personas = _visiblePersonas;
    final drawerSurface = Color.alphaBlend(
      YanciTheme.surfacePanel,
      Theme.of(context).colorScheme.surface,
    ).withValues(alpha: 1);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return FractionallySizedBox(
      heightFactor: .76,
      child: Material(
        key: const ValueKey('persona-all-drawer'),
        color: drawerSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(YanciTheme.radiusLg),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 9),
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: YanciTheme.textSecondary.withValues(alpha: .24),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _searchExpanded
                          ? TextField(
                              key: const ValueKey('persona-all-search-field'),
                              controller: _searchController,
                              autofocus: true,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                hintText: L.pick(
                                  en: 'Search roles',
                                  zhTW: '搜尋角色',
                                  zhCN: '搜索角色',
                                ),
                                hintStyle: TextStyle(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: .52,
                                  ),
                                  fontSize: 13,
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: .20,
                                    ),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: .20,
                                    ),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide(
                                    color: YanciTheme.accent.withValues(
                                      alpha: .52,
                                    ),
                                  ),
                                ),
                              ),
                              style: TextStyle(
                                color: YanciTheme.textPrimary,
                                fontSize: 13,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            )
                          : Align(
                              key: const ValueKey('persona-all-drawer-title'),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                L.pick(
                                  en: 'View all roles',
                                  zhTW: '查看全部角色',
                                  zhCN: '查看全部角色',
                                ),
                                style: YanciTheme.headingMedium,
                              ),
                            ),
                    ),
                  ),
                  if (!_searchExpanded)
                    Semantics(
                      button: true,
                      label: L.pick(
                        en: 'Search roles',
                        zhTW: '搜尋角色',
                        zhCN: '搜索角色',
                      ),
                      child: IconButton(
                        key: const ValueKey('persona-all-search-button'),
                        tooltip: L.pick(
                          en: 'Search roles',
                          zhTW: '搜尋角色',
                          zhCN: '搜索角色',
                        ),
                        onPressed: () => setState(() {
                          _searchExpanded = true;
                        }),
                        icon: const Icon(Icons.search_rounded, size: 19),
                        style: IconButton.styleFrom(
                          foregroundColor: YanciTheme.textSecondary.withValues(
                            alpha: .72,
                          ),
                          side: BorderSide(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: .24,
                            ),
                            width: 1,
                          ),
                          shape: const CircleBorder(),
                          minimumSize: const Size(44, 44),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: _searchExpanded
                        ? L.pick(en: 'Close search', zhTW: '關閉搜尋', zhCN: '关闭搜索')
                        : L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                    onPressed: () {
                      if (_searchExpanded) {
                        setState(() {
                          _searchExpanded = false;
                          _query = '';
                          _searchController.clear();
                        });
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.close_rounded),
                    color: YanciTheme.textSecondary.withValues(
                      alpha: _searchExpanded ? .78 : 1,
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: personas.isEmpty
                  ? Center(
                      child: Text(
                        L.pick(
                          en: 'No matching roles',
                          zhTW: '找不到符合的角色',
                          zhCN: '找不到符合的角色',
                        ),
                        style: TextStyle(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: .62,
                          ),
                          fontSize: 13,
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                      itemCount: personas.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final persona = personas[index];
                        final starred = _starredIds.contains(persona.id);
                        final name = persona.displayName.isEmpty
                            ? L.pick(
                                en: 'Unnamed identity',
                                zhTW: '未命名身分',
                                zhCN: '未命名身份',
                              )
                            : persona.displayName;
                        return Semantics(
                          button: true,
                          label: name,
                          child: ListTile(
                            key: ValueKey('persona-all-item-${persona.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            leading: _PersonaCarouselAvatar(
                              persona: persona,
                              size: 48,
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodyText,
                            ),
                            trailing: IconButton(
                              key: ValueKey('persona-star-${persona.id}'),
                              tooltip: starred
                                  ? L.pick(
                                      en: 'Unstar role',
                                      zhTW: '取消星標角色',
                                      zhCN: '取消星标角色',
                                    )
                                  : L.pick(
                                      en: 'Star role',
                                      zhTW: '星標角色',
                                      zhCN: '星标角色',
                                    ),
                              onPressed: () => _toggleStar(persona.id),
                              icon: Icon(
                                starred
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: starred
                                    ? YanciTheme.accent
                                    : YanciTheme.textSecondary.withValues(
                                        alpha: .42,
                                      ),
                              ),
                            ),
                            onTap: () => widget.onSelected(persona),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonaCarouselAvatar extends StatefulWidget {
  const _PersonaCarouselAvatar({
    required this.persona,
    required this.size,
    this.selected = false,
  });

  final UserPersona persona;
  final double size;
  final bool selected;

  @override
  State<_PersonaCarouselAvatar> createState() => _PersonaCarouselAvatarState();
}

class _PersonaCarouselAvatarState extends State<_PersonaCarouselAvatar> {
  late bool _hasImage;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(_PersonaCarouselAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.persona.avatarPath != widget.persona.avatarPath) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    final path = widget.persona.avatarPath;
    _hasImage = path.isNotEmpty && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.persona.avatarPath;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: YanciTheme.accent.withValues(alpha: widget.selected ? .16 : .10),
        border: Border.all(
          color: widget.selected
              ? YanciTheme.accent
              : YanciTheme.accent.withValues(alpha: .20),
          width: widget.selected ? 2.5 : .5,
        ),
        boxShadow: widget.selected
            ? [
                BoxShadow(
                  color: YanciTheme.accent.withValues(alpha: .34),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ]
            : null,
        image: _hasImage
            ? DecorationImage(
                image: FileImage(File(path)),
                fit: BoxFit.cover,
                alignment: Alignment.center,
              )
            : null,
      ),
      child: _hasImage
          ? null
          : Icon(
              Icons.person_rounded,
              size: widget.size * .46,
              color: YanciTheme.accent.withValues(alpha: .42),
            ),
    );
  }
}
