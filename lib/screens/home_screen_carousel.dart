// ignore_for_file: invalid_use_of_protected_member

part of 'home_screen.dart';

extension _HomeCarouselMethods on _HomeScreenState {
  Widget _buildCharacterCarousel() {
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    if (_characters.isEmpty || _carouselController == null) {
      return SizedBox(
        height: 120,
        child: Center(
          child: GestureDetector(
            onTap: () async {
              final newId = await Navigator.of(context).pushNamed('/character');
              if (newId != null && mounted) {
                await _loadCharacters(selectId: newId as String);
                _selectCharacter(newId);
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: YanciTheme.accent.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  L.get('char_create_hint'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final carouselWidth = min(MediaQuery.sizeOf(context).width - 28, 380.0);
    final backgroundPreset = _boundBackgroundPreset;
    final backgroundPath = backgroundPreset?.homePath.trim() ?? '';
    final hasCustomBackground =
        backgroundPreset != null &&
        backgroundPath.isNotEmpty &&
        File(backgroundPath).existsSync();
    final canGoPrevious = _currentCarouselPage > 0;
    final canGoNext = _currentCarouselPage < _characters.length - 1;
    final carouselRevision = _characterCarouselRevision;

    void moveCarouselTo(int index) {
      final controller = _carouselController;
      if (controller == null || !controller.hasClients) return;
      controller.animateToPage(
        index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }

    return SizedBox(
      height: isIos ? 136 : 156,
      child: Stack(
        children: [
          Center(
            child: SizedBox(
              width: carouselWidth,
              child: PageView.builder(
                key: ValueKey('home-character-carousel-$carouselRevision'),
                controller: _carouselController!,
                itemCount: _characters.length,
                onPageChanged: (index) {
                  if (_suspendCharacterCarouselSelection ||
                      carouselRevision != _characterCarouselRevision ||
                      index < 0 ||
                      index >= _characters.length) {
                    return;
                  }
                  _currentCarouselPage = index;
                  final id = _characters[index]['id'] as String;
                  unawaited(_selectCharacter(id));
                },
                itemBuilder: (context, index) {
                  return AnimatedBuilder(
                    animation: _carouselController!,
                    builder: (context, child) {
                      double page;
                      try {
                        page =
                            _carouselController!.page ??
                            _currentCarouselPage.toDouble();
                      } catch (_) {
                        page = _currentCarouselPage.toDouble();
                      }

                      final diff = (page - index).abs();
                      final scale = (1.0 - diff * 0.12).clamp(0.84, 1.0);
                      final isCenter = diff < 0.5;
                      // 靜止時只保留選中的角色可見；拖動開始後再讓鄰近卡片
                      // 依位移漸入，保留原本的輪盤滑動回饋與觸控範圍。
                      final distanceFromRest =
                          (page - _currentCarouselPage.toDouble()).abs();
                      final revealDuringSwipe = (distanceFromRest / 0.25).clamp(
                        0.0,
                        1.0,
                      );
                      final opacity = isCenter
                          ? 1.0
                          : (1.0 - diff * 0.38).clamp(0.0, 1.0) *
                                revealDuringSwipe;
                      final blurOpacity = isCenter
                          ? (1 - revealDuringSwipe).clamp(0.0, 1.0)
                          : 0.0;
                      final character = _characters[index];
                      final id = character['id'] as String;
                      final cardName = characterCardDisplayName(
                        character,
                        fallbackName: '？',
                      );
                      final cardTitle = characterCardTitle(
                        character,
                        fallbackName: '？',
                      );
                      final avatarPath =
                          character['avatar_path'] as String? ?? '';
                      final hasAvatar =
                          avatarPath.isNotEmpty &&
                          File(avatarPath).existsSync();
                      final isOnline =
                          isCenter &&
                          id == _activeCharacterId &&
                          _onlineDwellReady;
                      final isRp =
                          _globalRpEnabled ||
                          ContextModeSettings.preferredModeFromCharacter(
                                character,
                              ) ==
                              ContextMode.rp;
                      final onlineLabel = L.pick(
                        en: 'Online',
                        zhTW: '對方已上線',
                        zhCN: '对方已上线',
                      );
                      final visualOnlineLabel = L.pick(
                        en: 'Online',
                        zhTW: '在線',
                        zhCN: '在线',
                      );
                      final statusLabel = <String>[
                        if (isRp) 'RP',
                        if (isOnline) visualOnlineLabel,
                      ].join(' · ');
                      final semanticsStatusLabel = <String>[
                        if (isRp) 'RP',
                        if (isOnline) onlineLabel,
                      ].join('，');

                      return Center(
                        child: Semantics(
                          button: true,
                          selected: isCenter,
                          label: semanticsStatusLabel.isEmpty
                              ? cardName
                              : '$cardName，$semanticsStatusLabel',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (index == _currentCarouselPage) {
                                unawaited(_selectCharacter(id));
                                return;
                              }
                              moveCarouselTo(index);
                            },
                            child: Transform.scale(
                              scale: scale,
                              child: Opacity(
                                opacity: opacity,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      height: isIos ? 108 : 128,
                                      decoration: BoxDecoration(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color:
                                              (_homeForegroundPalette
                                                          ?.secondary ??
                                                      YanciTheme.accent)
                                                  .withValues(
                                                    alpha: isCenter
                                                        ? (YanciTheme.isDark
                                                              ? 0.20
                                                              : 0.16)
                                                        : 0.10,
                                                  ),
                                          width: 0.6,
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(18),
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            if (hasCustomBackground &&
                                                blurOpacity > 0.001)
                                              _HomeCardRegionBlur(
                                                key: ValueKey(
                                                  'home-card-blur-$id-$backgroundPath',
                                                ),
                                                preset: backgroundPreset,
                                                opacity: blurOpacity,
                                                settled:
                                                    distanceFromRest < 0.01,
                                              ),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    10,
                                                    9,
                                                    10,
                                                    8,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Container(
                                                    width: 50,
                                                    height: 50,
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: YanciTheme.accent
                                                          .withValues(
                                                            alpha: isCenter
                                                                ? 0.14
                                                                : 0.08,
                                                          ),
                                                      border: Border.all(
                                                        color: isCenter
                                                            ? YanciTheme.accent
                                                                  .withValues(
                                                                    alpha: 0.3,
                                                                  )
                                                            : YanciTheme
                                                                  .textSecondary
                                                                  .withValues(
                                                                    alpha: 0.12,
                                                                  ),
                                                      ),
                                                      image: hasAvatar
                                                          ? DecorationImage(
                                                              image: FileImage(
                                                                File(
                                                                  avatarPath,
                                                                ),
                                                              ),
                                                              fit: BoxFit.cover,
                                                            )
                                                          : null,
                                                    ),
                                                    child: hasAvatar
                                                        ? null
                                                        : Icon(
                                                            Icons
                                                                .person_rounded,
                                                            size: 27,
                                                            color: YanciTheme
                                                                .accent
                                                                .withValues(
                                                                  alpha: 0.5,
                                                                ),
                                                          ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Column(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Flexible(
                                                              child: Text(
                                                                cardTitle,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: _withHomeCardHalo(
                                                                  TextStyle(
                                                                    fontSize:
                                                                        isCenter
                                                                        ? 16
                                                                        : 14,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w400,
                                                                    color:
                                                                        isCenter
                                                                        ? (_homeForegroundPalette?.primary ??
                                                                              YanciTheme.accent)
                                                                        : (_homeForegroundPalette?.secondary ??
                                                                              YanciTheme.textPrimary.withValues(
                                                                                alpha: 0.64,
                                                                              )),
                                                                    fontFamily:
                                                                        YanciTheme
                                                                            .fontFamily,
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            if (isRp ||
                                                                isOnline) ...[
                                                              const SizedBox(
                                                                width: 6,
                                                              ),
                                                              Container(
                                                                padding:
                                                                    const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          6,
                                                                      vertical:
                                                                          2,
                                                                    ),
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      (isRp
                                                                              ? contextRpColor
                                                                              : const Color(
                                                                                  0xFF65C98A,
                                                                                ))
                                                                          .withValues(
                                                                            alpha:
                                                                                0.13,
                                                                          ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        YanciTheme
                                                                            .radiusPill,
                                                                      ),
                                                                  border: Border.all(
                                                                    color:
                                                                        (isRp
                                                                                ? contextRpColor
                                                                                : const Color(
                                                                                    0xFF65C98A,
                                                                                  ))
                                                                            .withValues(
                                                                              alpha: 0.32,
                                                                            ),
                                                                    width: 0.5,
                                                                  ),
                                                                ),
                                                                child: Row(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    Container(
                                                                      width: 5,
                                                                      height: 5,
                                                                      decoration: BoxDecoration(
                                                                        shape: BoxShape
                                                                            .circle,
                                                                        color:
                                                                            isRp
                                                                            ? contextRpColor
                                                                            : const Color(
                                                                                0xFF65C98A,
                                                                              ),
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 4,
                                                                    ),
                                                                    Text(
                                                                      statusLabel,
                                                                      maxLines:
                                                                          1,
                                                                      style: _withHomeCardHalo(
                                                                        TextStyle(
                                                                          fontSize:
                                                                              8.5,
                                                                          height:
                                                                              1.05,
                                                                          color:
                                                                              isRp
                                                                              ? contextRpColor
                                                                              : const Color(
                                                                                  0xFF65C98A,
                                                                                ),
                                                                          fontFamily:
                                                                              YanciTheme.fontFamily,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                top: 4,
                                                              ),
                                                          child: CharacterSignaturePanel(
                                                            compact: true,
                                                            foregroundColor:
                                                                _homeForegroundPalette
                                                                    ?.secondary,
                                                            ruleColor:
                                                                _homeForegroundPalette
                                                                    ?.subtle,
                                                            onShowHistory: () =>
                                                                _showSignatureHistoryFor(
                                                                  character['id']
                                                                      as String,
                                                                ),
                                                            signature:
                                                                character['signature']
                                                                    as String?,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
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
          if (canGoPrevious)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IconButton(
                onPressed: () => moveCarouselTo(_currentCarouselPage - 1),
                tooltip: L.pick(
                  en: 'Previous character',
                  zhTW: '上一個角色',
                  zhCN: '上一个角色',
                ),
                padding: EdgeInsets.zero,
                iconSize: 15,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: YanciTheme.textSecondary.withValues(
                    alpha: YanciTheme.isDark ? 0.19 : 0.15,
                  ),
                ),
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
            ),
          if (canGoNext)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: IconButton(
                onPressed: () => moveCarouselTo(_currentCarouselPage + 1),
                tooltip: L.pick(
                  en: 'Next character',
                  zhTW: '下一個角色',
                  zhCN: '下一个角色',
                ),
                padding: EdgeInsets.zero,
                iconSize: 15,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: YanciTheme.textSecondary.withValues(
                    alpha: YanciTheme.isDark ? 0.19 : 0.15,
                  ),
                ),
                icon: const Icon(Icons.arrow_forward_ios_rounded),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeartbeatValue() {
    final bpm = _heartbeat ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.favorite,
            size: 12,
            color: YanciTheme.accent.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 4),
          Text(
            '$bpm',
            style: YanciTheme.bodyText.copyWith(
              fontSize: 13,
              color: YanciTheme.accent.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveConvEntry() {
    final title = _keepAliveConvTitle ?? '';
    final imagePrimary = _homeForegroundPalette?.primary;
    final imageSecondary = _homeForegroundPalette?.secondary;
    final imageSubtle = _homeForegroundPalette?.subtle;
    final homePath = _boundBackgroundPreset?.homePath.trim() ?? '';
    final hasCustomHomeImage =
        homePath.isNotEmpty && File(homePath).existsSync();
    final dominant = _homeForegroundPalette?.dominant;
    final adaptiveSolid = dominant == null
        ? YanciTheme.surfacePanel
        : Color.lerp(
            dominant,
            dominant.computeLuminance() < 0.42 ? Colors.black : Colors.white,
            dominant.computeLuminance() < 0.42 ? 0.48 : 0.72,
          )!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 46), // 對稱佔位 (38 + 8)
          Flexible(
            child: GestureDetector(
              onTap: () async {
                if (_keepAliveConvId == null) return;
                await _pushChatRoute(
                  arguments: _keepAliveConvId!,
                  restoreCharacterId: _activeCharacterId,
                );
                await _refreshAfterChatReturn();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: hasCustomHomeImage
                      ? adaptiveSolid.withValues(alpha: 0.9)
                      : YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.white.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: hasCustomHomeImage
                        ? (imageSecondary ?? YanciTheme.accent).withValues(
                            alpha: 0.22,
                          )
                        : YanciTheme.accent.withValues(alpha: 0.2),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: YanciTheme.accent.withValues(alpha: 0.7),
                        boxShadow: [
                          BoxShadow(
                            color: YanciTheme.accent.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title.isEmpty
                            ? (L.pick(en: 'Continue chat', zhTW: '繼續對話'))
                            : title,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 12,
                          color:
                              imagePrimary ??
                              YanciTheme.textPrimary.withValues(alpha: 0.7),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color:
                          imageSecondary ??
                          YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: L.pick(en: 'Manual summary', zhTW: '手動摘要'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showManualSummaryOptions,
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: Icon(
                    Icons.edit_rounded,
                    size: 19,
                    color:
                        imageSubtle ??
                        YanciTheme.accent.withValues(alpha: 0.65),
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

class _HomeCardRegionBlur extends StatefulWidget {
  const _HomeCardRegionBlur({
    super.key,
    required this.preset,
    required this.opacity,
    required this.settled,
  });

  final BackgroundPreset preset;
  final double opacity;
  final bool settled;

  @override
  State<_HomeCardRegionBlur> createState() => _HomeCardRegionBlurState();
}

class _HomeCardRegionBlurState extends State<_HomeCardRegionBlur> {
  Offset? _regionOffset;
  Size? _viewportSize;
  bool _measureScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _HomeCardRegionBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settled &&
        (!oldWidget.settled || oldWidget.preset != widget.preset)) {
      _scheduleMeasure();
    }
  }

  void _scheduleMeasure() {
    if (!widget.settled || _measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || !widget.settled) return;
      final renderObject = context.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        final nextOffset = renderObject.localToGlobal(Offset.zero);
        final nextViewport = MediaQuery.sizeOf(context);
        if (_regionOffset != nextOffset || _viewportSize != nextViewport) {
          setState(() {
            _regionOffset = nextOffset;
            _viewportSize = nextViewport;
          });
        }
      }
      // 停住後仍持續在每一幀之後核對位置：卡片上方的內容（繼續對話入口、
      // 狀態列、字級）晚一步出現或改變高度時，模糊切片要跟著挪，否則會錯位。
      // 只在真的有畫面更新時才執行，位置沒變就不重建。
      _scheduleMeasure();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.settled) _scheduleMeasure();
    final offset = _regionOffset;
    final viewport = _viewportSize;
    if (offset == null || viewport == null) {
      return const SizedBox.expand();
    }
    return Opacity(
      opacity: widget.opacity,
      child: BakedCardRegionBlur(
        file: File(widget.preset.homePath),
        scale: widget.preset.homeScale,
        offsetX: widget.preset.homeOffsetX,
        offsetY: widget.preset.homeOffsetY,
        // Keep the baked contrast support without making the selected card
        // look detached from its background. This halves the former blur
        // radius while retaining the same zero-per-frame-cost cache path.
        blur: max(widget.preset.homeBlur, 12) * 0.5,
        viewportSize: viewport,
        regionOffset: offset,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        overlayColor: YanciTheme.surfacePanel.withValues(
          alpha: YanciTheme.isDark ? 0.16 : 0.12,
        ),
      ),
    );
  }
}

/// 首頁角色卡上的文字加一圈很細的羽化光暈（約 0.5–1px），
/// 在亮／暗背景圖上都讀得清楚。光暈顏色與字色反差：淺字配深暈、深字配淺暈。
TextStyle _withHomeCardHalo(TextStyle style) {
  final color = style.color ?? YanciTheme.textPrimary;
  final halo = color.computeLuminance() > 0.45
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
  return style.copyWith(
    shadows: <Shadow>[
      Shadow(color: halo.withValues(alpha: 0.42), blurRadius: 0.8),
      Shadow(color: halo.withValues(alpha: 0.22), blurRadius: 2),
    ],
  );
}
