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
                      final character = _characters[index];
                      final id = character['id'] as String;
                      final name = character['name'] as String? ?? '？';
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

                      return Center(
                        child: Semantics(
                          button: true,
                          selected: isCenter,
                          label: isRp
                              ? '$name，RP'
                              : isOnline
                              ? '$name，${L.pick(en: 'Online', zhTW: '對方已上線', zhCN: '对方已上线')}'
                              : name,
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
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        9,
                                        10,
                                        8,
                                      ),
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
                                                    : YanciTheme.textSecondary
                                                          .withValues(
                                                            alpha: 0.12,
                                                          ),
                                              ),
                                              image: hasAvatar
                                                  ? DecorationImage(
                                                      image: FileImage(
                                                        File(avatarPath),
                                                      ),
                                                      fit: BoxFit.cover,
                                                    )
                                                  : null,
                                            ),
                                            child: hasAvatar
                                                ? null
                                                : Icon(
                                                    Icons.person_rounded,
                                                    size: 27,
                                                    color: YanciTheme.accent
                                                        .withValues(alpha: 0.5),
                                                  ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: isCenter
                                                              ? 16
                                                              : 14,
                                                          fontWeight:
                                                              FontWeight.w400,
                                                          color: isCenter
                                                              ? (_homeForegroundPalette
                                                                        ?.primary ??
                                                                    YanciTheme
                                                                        .accent)
                                                              : (_homeForegroundPalette
                                                                        ?.secondary ??
                                                                    YanciTheme
                                                                        .textPrimary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.64,
                                                                        )),
                                                          fontFamily: YanciTheme
                                                              .fontFamily,
                                                        ),
                                                      ),
                                                    ),
                                                    if (isRp || isOnline) ...[
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        width: 7,
                                                        height: 7,
                                                        decoration: BoxDecoration(
                                                          color: isRp
                                                              ? contextRpColor
                                                              : Color(
                                                                  0xFF65C98A,
                                                                ),
                                                          shape:
                                                              BoxShape.circle,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Color(
                                                                0x5965C98A,
                                                              ),
                                                              blurRadius: 5,
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
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
                                    if (isRp || isOnline)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          isRp
                                              ? 'RP'
                                              : L.pick(
                                                  en: 'Online',
                                                  zhTW: '對方已上線',
                                                  zhCN: '对方已上线',
                                                ),
                                          style: TextStyle(
                                            fontSize: 9,
                                            height: 1.0,
                                            color: isRp
                                                ? contextRpColor
                                                : const Color(0xFF65C98A),
                                            fontFamily: YanciTheme.fontFamily,
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
