import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../widgets/character_quick_picker.dart';
import '../memory/database.dart';
import '../services/marriage_service.dart';
import '../services/settings_manager.dart';
import 'saved_messages_screen.dart';
import '../widgets/character_timeline_panel.dart';
import '../widgets/character_diary_entry.dart';
import '../widgets/character_self_notes_panel.dart';
import '../widgets/character_signature_panel.dart';
import '../widgets/character_signature_history_sheet.dart';
import '../widgets/rp_storyline_entry.dart';
import '../widgets/context_mode_pill.dart';
import '../models/context_mode.dart';
import '../services/settings/context_mode_settings.dart';
import '../utils/latest_request_gate.dart';

/// 角色管理 — 橫向卡片輪盤 + 關聯資源入口
class CharacterListScreen extends StatefulWidget {
  const CharacterListScreen({
    super.key,
    this.embedded = false,
    this.activeCharacterId,
    this.onActiveCharacterChanged,
  });

  final bool embedded;

  /// The character selected by the parent surface. Browsing this carousel does
  /// not write back; only the explicit "交流" action commits a new selection.
  final String? activeCharacterId;
  final ValueChanged<String>? onActiveCharacterChanged;

  @override
  State<CharacterListScreen> createState() => _CharacterListScreenState();
}

class _CharacterListScreenState extends State<CharacterListScreen> {
  List<Map<String, dynamic>> _characters = [];
  String _activeId = 'default';
  bool _isLoading = true;
  late PageController _pageCtrl;
  int _currentPage = 0;
  bool _isImporting = false;
  bool _timelineEnabled = true;
  bool _selfNotesEnabled = true;
  bool _globalRpEnabled = false;
  final LatestRequestGate _loadGate = LatestRequestGate();

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(viewportFraction: 0.82);
    ContextModeSettings.revision.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(covariant CharacterListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeCharacterId != widget.activeCharacterId) {
      _syncToExternalActive(widget.activeCharacterId);
    }
  }

  @override
  void dispose() {
    _loadGate.invalidate();
    ContextModeSettings.revision.removeListener(_load);
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = _loadGate.begin();
    final previousVisibleId =
        _characters.isNotEmpty &&
            _currentPage >= 0 &&
            _currentPage < _characters.length
        ? _characters[_currentPage]['id']?.toString()
        : null;
    final chars = await DatabaseHelper.getCharacters();
    final savedActiveId = await UserSettings.getActiveCharacterId();
    final externalActiveId = widget.activeCharacterId?.trim();
    final activeId = externalActiveId != null && externalActiveId.isNotEmpty
        ? externalActiveId
        : savedActiveId;
    final timelineEnabled = await MemorySettings.getTimelineEnabled();
    final selfNotesEnabled = await MemorySettings.getSelfNotesEnabled();
    final globalRpEnabled = await ContextModeSettings.getGlobalRpEnabled();
    final previousVisibleIndex = previousVisibleId == null
        ? -1
        : chars.indexWhere((c) => c['id'] == previousVisibleId);
    final activeIndex = chars.indexWhere((c) => c['id'] == activeId);
    final externalSelectionChanged =
        externalActiveId != null &&
        externalActiveId.isNotEmpty &&
        externalActiveId != previousVisibleId;
    final targetIndex = externalSelectionChanged
        ? (activeIndex >= 0 ? activeIndex : 0)
        : previousVisibleIndex >= 0
        ? previousVisibleIndex
        : (activeIndex >= 0 ? activeIndex : 0);
    if (!mounted || !_loadGate.isCurrent(generation)) return;
    setState(() {
      _characters = chars;
      _activeId = activeId;
      _isLoading = false;
      _currentPage = targetIndex;
      _timelineEnabled = timelineEnabled;
      _selfNotesEnabled = selfNotesEnabled;
      _globalRpEnabled = globalRpEnabled;
    });
    // 等一幀再跳，確保 PageController 已掛載
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _loadGate.isCurrent(generation) &&
          _pageCtrl.hasClients &&
          chars.isNotEmpty &&
          _pageCtrl.page?.round() != targetIndex) {
        _pageCtrl.jumpToPage(targetIndex);
      }
    });
  }

  void _syncToExternalActive(String? characterId) {
    final id = characterId?.trim();
    if (id == null || id.isEmpty || _characters.isEmpty) return;
    final targetIndex = _characters.indexWhere(
      (character) => character['id']?.toString() == id,
    );
    if (targetIndex < 0) return;

    if (_activeId != id || _currentPage != targetIndex) {
      setState(() {
        _activeId = id;
        _currentPage = targetIndex;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageCtrl.hasClients) return;
      if (_pageCtrl.page?.round() != targetIndex) {
        // The tab can be offstage while Home changes character. Jumping keeps
        // the next reveal deterministic without animating an invisible page.
        _pageCtrl.jumpToPage(targetIndex);
      }
    });
  }

  Future<void> _setCurrentMode(ContextMode mode) async {
    if (_characters.isEmpty) return;
    if (_globalRpEnabled) {
      showContextModeNotice(
        context,
        L.pick(
          en: 'Global RP mode currently controls this character.',
          zhTW: '目前由全域 RP 模式控制該夥伴。',
          zhCN: '目前由全局 RP 模式控制该伙伴。',
        ),
      );
      return;
    }
    final characterId = _currentCharId;
    await ContextModeSettings.setCharacterPreferredMode(characterId, mode);
    final differs = await ContextModeSettings.latestWindowDiffers(
      characterId,
      mode,
    );
    if (!mounted) return;
    final base = mode == ContextMode.rp
        ? L.pick(
            en: 'This companion is now in RP mode.',
            zhTW: '該夥伴已打開 RP 模式。',
            zhCN: '该伙伴已打开 RP 模式。',
          )
        : L.pick(
            en: 'This companion has returned to daily mode.',
            zhTW: '該夥伴已回歸日常。',
            zhCN: '该伙伴已回归日常。',
          );
    final next = !differs
        ? ''
        : mode == ContextMode.rp
        ? L.pick(
            en: ' Open a new window to begin RP.',
            zhTW: ' 請開啟新窗口進行 RP。',
            zhCN: ' 请开启新窗口进行 RP。',
          )
        : L.pick(
            en: ' Open a new window to begin your daily life.',
            zhTW: ' 請開啟新窗口開始你們的日常。',
            zhCN: ' 请开启新窗口开始你们的日常。',
          );
    showContextModeNotice(context, '$base$next');
  }

  Future<void> _showSignatureHistoryFor(String characterId) async {
    final selected = await showCharacterSignatureHistory(context, characterId);
    if (!mounted || selected == null) return;
    final index = _characters.indexWhere((row) => row['id'] == characterId);
    if (index < 0) return;
    setState(() {
      _characters[index] = <String, dynamic>{
        ..._characters[index],
        'signature': selected,
      };
    });
  }

  String get _currentCharId {
    if (_characters.isEmpty) return 'default';
    return _characters[_currentPage]['id'] as String? ?? 'default';
  }

  bool get _currentCharacterIsRp {
    if (_characters.isEmpty || _currentPage >= _characters.length) return false;
    if (_globalRpEnabled) return true;
    return ContextMode.fromStorage(
          _characters[_currentPage]['preferred_context_mode'],
        ) ==
        ContextMode.rp;
  }

  Future<void> _showAllCharacters() async {
    if (_characters.isEmpty) return;
    final selectedIndex = await showCharacterQuickPicker(
      context,
      characters: _characters,
      selectedIndex: _currentPage,
    );
    if (!mounted || selectedIndex == null || selectedIndex == _currentPage) {
      return;
    }
    setState(() => _currentPage = selectedIndex);
    if (!_pageCtrl.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageCtrl.jumpToPage(selectedIndex);
      return;
    }
    await _pageCtrl.animateToPage(
      selectedIndex,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildPageIndicator() {
    final count = _characters.length;
    if (count <= 1) return const SizedBox.shrink();
    final visibleCount = count.clamp(1, 5);
    final maxStart = count - visibleCount;
    final start = (_currentPage - visibleCount ~/ 2).clamp(0, maxStart);
    final indices = List<int>.generate(
      visibleCount,
      (offset) => start + offset,
    );
    final label = L.pick(
      en: 'Character ${_currentPage + 1} of $count',
      zhTW: '第 ${_currentPage + 1} 個角色，共 $count 個',
      zhCN: '第 ${_currentPage + 1} 个角色，共 $count 个',
    );
    return Semantics(
      label: label,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ...indices.map((index) {
            final isActive = index == _currentPage;
            return AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: isActive ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: isActive
                    ? YanciTheme.accent
                    : YanciTheme.textSecondary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
          if (count > visibleCount) ...[
            const SizedBox(width: 8),
            Text(
              '${_currentPage + 1}/$count',
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.72),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        // ═══ 頂部欄 ═══
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: YanciTheme.spacingSm,
            vertical: YanciTheme.spacingXs,
          ),
          child: SizedBox(
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.embedded)
                        IconButton(
                          tooltip: L.pick(en: 'Back', zhTW: '返回', zhCN: '返回'),
                          icon: Icon(
                            Icons.arrow_back_ios_rounded,
                            size: 20,
                            color: YanciTheme.textPrimary,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      TextButton.icon(
                        key: const ValueKey('show-all-characters'),
                        onPressed: _characters.isEmpty
                            ? null
                            : _showAllCharacters,
                        icon: Icon(
                          Icons.person_outline_rounded,
                          size: 18,
                          color: YanciTheme.accent,
                        ),
                        label: Text(
                          L.pick(en: 'All', zhTW: '全部', zhCN: '全部'),
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.accent,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_characters.isNotEmpty)
                  ContextModePill(
                    key: ValueKey('character-mode-$_currentCharId'),
                    mode: _currentCharacterIsRp
                        ? ContextMode.rp
                        : ContextMode.daily,
                    enabled: !_globalRpEnabled,
                    compact: true,
                    onChanged: (mode) => unawaited(_setCurrentMode(mode)),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: L.pick(
                          en: 'Import character',
                          zhTW: '匯入角色',
                          zhCN: '导入角色',
                        ),
                        icon: Icon(
                          Icons.download_rounded,
                          size: 20,
                          color: YanciTheme.accent,
                        ),
                        onPressed: _importFromCode,
                      ),
                      IconButton(
                        tooltip: L.pick(
                          en: 'Create character',
                          zhTW: '新增角色',
                          zhCN: '新增角色',
                        ),
                        icon: Icon(
                          Icons.add_rounded,
                          size: 22,
                          color: YanciTheme.accent,
                        ),
                        onPressed: () async {
                          await Navigator.of(context).pushNamed('/character');
                          if (!mounted) return;
                          _load();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [
                const SizedBox(height: 12),

                // ═══ 橫向卡片輪盤 ═══
                _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      )
                    : _characters.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(
                          children: [
                            Icon(
                              Icons.person_add_outlined,
                              size: 48,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.3,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              L.get('char_empty_hint'),
                              textAlign: TextAlign.center,
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : SizedBox(
                        height:
                            (Theme.of(context).platform == TargetPlatform.iOS
                                ? 310
                                : 400) +
                            ((YanciTheme.fontScale *
                                            MediaQuery.textScalerOf(
                                              context,
                                            ).scale(1) -
                                        1)
                                    .clamp(0.0, 1.0) *
                                72),
                        child: PageView.builder(
                          controller: _pageCtrl,
                          itemCount: _characters.length,
                          onPageChanged: (i) {
                            HapticFeedback.selectionClick();
                            setState(() => _currentPage = i);
                          },
                          itemBuilder: (ctx, i) =>
                              _buildCard(_characters[i], i),
                        ),
                      ),

                // ═══ 頁面指示器 ═══
                if (_characters.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _buildPageIndicator(),
                  ),

                const SizedBox(height: 16),

                const SizedBox(height: 20),

                // ═══ 時間線 ═══
                if (_characters.isNotEmpty &&
                    _timelineEnabled &&
                    !_currentCharacterIsRp)
                  CharacterTimelinePanel(
                    key: ValueKey('timeline-$_currentCharId'),
                    characterId: _currentCharId,
                    modeOverride: ContextMode.daily,
                    showContextModeControl: false,
                    initiallyCollapsed: true,
                  ),
                // The diary archive is a stable Daily-mode destination.
                // Its feature switch controls model writing only; it
                // must not make previously written entries or the empty
                // archive affordance disappear.
                if (_characters.isNotEmpty && !_currentCharacterIsRp)
                  CharacterDiaryReader(
                    key: ValueKey('daily-diary-$_currentCharId'),
                    characterId: _currentCharId,
                  ),
                if (_characters.isNotEmpty && _currentCharacterIsRp)
                  RpStorylineEntry(
                    key: ValueKey('rp-storylines-$_currentCharId'),
                    characterId: _currentCharId,
                  ),
                if (_characters.isNotEmpty &&
                    _selfNotesEnabled &&
                    !_currentCharacterIsRp) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                    child: CharacterSelfNotesPanel(
                      key: ValueKey('self-notes-timeline-$_currentCharId'),
                      characterId: _currentCharId,
                      embedded: true,
                      initiallyCollapsed: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) return content;
    return Scaffold(
      // 填帳號等彈鍵盤時，底層畫面不縮高 → 不再擠爆這條 Column（Spacer 吸不住 43px）
      resizeToAvoidBottomInset: false,
      body: GradientBackground(child: SafeArea(child: content)),
    );
  }

  Widget _buildCard(Map<String, dynamic> c, int index) {
    final id = c['id'] as String;
    final name = c['name'] as String? ?? '未命名';
    final avatarPath = c['avatar_path'] as String? ?? '';
    final isActive = id == _activeId;
    final isCurrent = index == _currentPage;

    return AnimatedScale(
      scale: isCurrent ? 1.0 : 0.92,
      duration: const Duration(milliseconds: 200),
      child: GestureDetector(
        onTap: () async {
          await Navigator.of(context).pushNamed('/character', arguments: id);
          if (!mounted) return;
          _load();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? Color.lerp(
                    Colors.white,
                    YanciTheme.accent,
                    0.15,
                  )!.withValues(alpha: isActive ? 0.08 : 0.04)
                : Color.lerp(
                    Colors.white,
                    YanciTheme.accent,
                    isActive ? 0.08 : 0.05,
                  )!.withValues(alpha: isActive ? 0.72 : 0.50),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isActive
                  ? YanciTheme.accent.withValues(alpha: 0.18)
                  : YanciTheme.isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.5),
              width: isActive ? 1.0 : 0.5,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: YanciTheme.accent.withValues(alpha: 0.05),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: YanciTheme.accent.withValues(alpha: 0.06),
                        border: Border.all(
                          color: isActive
                              ? YanciTheme.accent.withValues(alpha: 0.15)
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.08,
                                ),
                          width: 0.5,
                        ),
                        image:
                            avatarPath.isNotEmpty &&
                                File(avatarPath).existsSync()
                            ? DecorationImage(
                                image: FileImage(File(avatarPath)),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child:
                          avatarPath.isEmpty || !File(avatarPath).existsSync()
                          ? Icon(
                              Icons.person_rounded,
                              size: 36,
                              color: YanciTheme.accent.withValues(alpha: 0.4),
                            )
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4, top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: YanciTheme.headingMedium.copyWith(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            FutureBuilder<bool>(
                              future: MarriageService.isMarried(id),
                              builder: (context, snap) {
                                if (snap.data != true) {
                                  return const SizedBox.shrink();
                                }
                                final gold = YanciTheme.characterMarriageGold;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '❦',
                                        style: TextStyle(
                                          fontSize: 9,
                                          color: gold,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        L.pick(
                                          en: 'Married',
                                          zhTW: '已婚',
                                          zhCN: '已婚',
                                        ),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: gold,
                                          letterSpacing: 1,
                                          fontFamily: YanciTheme.fontFamily,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            CharacterSignaturePanel(
                              key: ValueKey('character-signature-card-$id'),
                              compact: true,
                              onShowHistory: () => _showSignatureHistoryFor(id),
                              signature: c['signature'] as String?,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!isActive)
                      Semantics(
                        button: true,
                        label: L.get('char_use'),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () async {
                            HapticFeedback.mediumImpact();
                            await UserSettings.saveActiveCharacterId(id);
                            await UserSettings.saveCharacterName(name);
                            if (!mounted) return;
                            setState(() {
                              _activeId = id;
                            });
                            widget.onActiveCharacterChanged?.call(id);
                          },
                          child: SizedBox(
                            key: const ValueKey('character-card-talk-button'),
                            width: 64,
                            height: 44,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  L.get('char_use'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: YanciTheme.accent,
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
              SizedBox(
                height: Theme.of(context).platform == TargetPlatform.iOS
                    ? 12
                    : 64,
              ),
              const Spacer(),
              Transform.translate(
                offset: Offset.zero,
                child: _buildResourceTabs(
                  charId: id,
                  charName: name,
                  embedded: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResourceTabs({
    required String charId,
    required String charName,
    bool embedded = false,
  }) {
    final tabs = [
      _ResourceTab(Icons.graphic_eq_rounded, L.get('char_tab_voice'), () {
        Navigator.of(context).pushNamed('/voice_library', arguments: charId);
      }),
      _ResourceTab(
        Icons.emoji_emotions_outlined,
        L.get('char_tab_sticker'),
        () {
          Navigator.of(context).pushNamed('/sticker', arguments: charId);
        },
      ),
      _ResourceTab(Icons.bubble_chart_outlined, L.get('char_tab_memory'), () {
        Navigator.of(context).pushNamed('/memory', arguments: charId);
      }),
      _ResourceTab(Icons.bookmark_border_rounded, L.get('char_tab_saved'), () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SavedMessagesScreen(
              characterId: charId,
              characterName: charName,
            ),
          ),
        );
      }),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: embedded ? 0 : 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((tab) {
          return Semantics(
            button: true,
            label: tab.label,
            child: GestureDetector(
              onTap: tab.onTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: embedded ? 44 : 48,
                    height: embedded ? 44 : 48,
                    decoration: BoxDecoration(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.white.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: YanciTheme.isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.white.withValues(alpha: 0.7),
                        width: 0.5,
                      ),
                    ),
                    child: Icon(
                      tab.icon,
                      size: tab.icon == Icons.star_outline_rounded ? 20 : 22,
                      color: YanciTheme.accent.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 極淡小字標籤：平常不搶眼，需要時找得到。
                  ExcludeSemantics(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.0,
                        letterSpacing: 1,
                        color: YanciTheme.accent.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ═══════════════════════════════════
  // JSON 導入
  // ═══════════════════════════════════

  void _importFromCode() {
    final ctrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(L.get('char_import_code'), style: YanciTheme.headingMedium),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: L.pick(en: 'Paste share code…', zhTW: '貼上分享碼……'),
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              if (_isImporting) return;
              _isImporting = true;
              try {
                final decoded = utf8.decode(base64Decode(ctrl.text.trim()));
                final json = jsonDecode(decoded) as Map<String, dynamic>;
                if (json['yanci_character'] != 1) throw '格式錯誤';

                final now = DateTime.now().toIso8601String();
                final id = const Uuid().v4();

                await DatabaseHelper.insertCharacter({
                  'id': id,
                  'name': json['name'] ?? '匯入角色',
                  'gender': json['gender'] ?? '',
                  'relationship': json['relationship'] ?? '',
                  'description': json['description'] ?? '',
                  'race': json['race'] ?? '',
                  'skill': json['skill'] ?? '',
                  'age': json['age'] ?? '',
                  'height': json['height'] ?? '',
                  'signature': json['signature'] ?? '',
                  'created_at': now,
                  'updated_at': now,
                });

                await UserSettings.saveActiveCharacterId(id);

                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _load();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(L.fmt('char_imported', [json['name']])),
                    backgroundColor: YanciTheme.accent,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(milliseconds: 1200),
                    margin: const EdgeInsets.only(
                      bottom: 80,
                      left: 16,
                      right: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(L.get('char_code_error')),
                    backgroundColor: Colors.red.withValues(alpha: 0.7),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(milliseconds: 1200),
                    margin: const EdgeInsets.only(
                      bottom: 80,
                      left: 16,
                      right: 16,
                    ),
                  ),
                );
              } finally {
                _isImporting = false;
              }
            },
            child: Text(
              L.get('char_import_btn'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceTab {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  _ResourceTab(this.icon, this.label, this.onTap);
}
