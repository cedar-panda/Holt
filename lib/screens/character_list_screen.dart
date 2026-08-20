import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/x_post_settings.dart';
import '../widgets/gradient_background.dart';
import '../memory/database.dart';
import '../services/marriage_service.dart';
import '../services/settings_manager.dart';
import 'saved_messages_screen.dart';
import '../widgets/character_timeline_panel.dart';
import '../widgets/character_self_notes_panel.dart';
import '../widgets/character_signature_panel.dart';
import '../widgets/emotion_panel.dart';
import '../widgets/x_post_panel.dart';
import '../utils/latest_request_gate.dart';

/// 角色管理 — 橫向卡片輪盤 + 關聯資源入口
class CharacterListScreen extends StatefulWidget {
  const CharacterListScreen({super.key});

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
  bool _onlineDwellReady = false;
  Timer? _onlineDwellTimer;
  final LatestRequestGate _loadGate = LatestRequestGate();

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(viewportFraction: 0.82);
    _load();
  }

  @override
  void dispose() {
    _loadGate.invalidate();
    _onlineDwellTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _beginOnlineDwell(int index) {
    _onlineDwellTimer?.cancel();
    if (_onlineDwellReady) {
      setState(() => _onlineDwellReady = false);
    }
    _onlineDwellTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || index != _currentPage) return;
      setState(() => _onlineDwellReady = true);
      final character = _characters[index];
      if (character['id'] != _activeId) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'They are online', zhTW: '對方已上線', zhCN: '对方已上线'),
            style: TextStyle(
              color: YanciTheme.accent.computeLuminance() > 0.45
                  ? const Color(0xFF2A2A2A)
                  : Colors.white,
            ),
          ),
          backgroundColor: YanciTheme.isDark
              ? YanciTheme.accent.withValues(alpha: 0.88)
              : YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    });
  }

  Future<void> _load() async {
    final generation = _loadGate.begin();
    final chars = await DatabaseHelper.getCharacters();
    final activeId = await UserSettings.getActiveCharacterId();
    final timelineEnabled = await MemorySettings.getTimelineEnabled();
    final selfNotesEnabled = await MemorySettings.getSelfNotesEnabled();
    final activeIndex = chars.indexWhere((c) => c['id'] == activeId);
    if (!mounted || !_loadGate.isCurrent(generation)) return;
    setState(() {
      _characters = chars;
      _activeId = activeId;
      _isLoading = false;
      _currentPage = activeIndex >= 0 ? activeIndex : 0;
      _timelineEnabled = timelineEnabled;
      _selfNotesEnabled = selfNotesEnabled;
    });
    // 等一幀再跳，確保 PageController 已掛載
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _loadGate.isCurrent(generation) &&
          _pageCtrl.hasClients &&
          activeIndex >= 0) {
        _pageCtrl.jumpToPage(activeIndex);
        _beginOnlineDwell(activeIndex);
      }
    });
  }

  String get _currentCharId {
    if (_characters.isEmpty) return 'default';
    return _characters[_currentPage]['id'] as String? ?? 'default';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 填帳號等彈鍵盤時，底層畫面不縮高 → 不再擠爆這條 Column（Spacer 吸不住 43px）
      resizeToAvoidBottomInset: false,
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ═══ 頂部欄 ═══
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 20,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.download_rounded,
                        size: 20,
                        color: YanciTheme.accent,
                      ),
                      onPressed: _importFromCode,
                    ),
                    IconButton(
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
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : SizedBox(
                              height: 360,
                              child: PageView.builder(
                                controller: _pageCtrl,
                                itemCount: _characters.length,
                                onPageChanged: (i) {
                                  HapticFeedback.selectionClick();
                                  setState(() => _currentPage = i);
                                  _beginOnlineDwell(i);
                                },
                                itemBuilder: (ctx, i) =>
                                    _buildCard(_characters[i], i),
                              ),
                            ),

                      // ═══ 頁面指示器 ═══
                      if (_characters.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(_characters.length, (i) {
                              final isActive = i == _currentPage;
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                width: isActive ? 18 : 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? YanciTheme.accent
                                      : YanciTheme.textSecondary.withValues(
                                          alpha: 0.2,
                                        ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              );
                            }),
                          ),
                        ),

                      const SizedBox(height: 16),

                      const SizedBox(height: 20),

                      // ═══ 時間線 ═══
                      if (_characters.isNotEmpty && _timelineEnabled)
                        CharacterTimelinePanel(
                          key: ValueKey('timeline-$_currentCharId'),
                          characterId: _currentCharId,
                        ),
                      if (_characters.isNotEmpty && _selfNotesEnabled) ...[
                        // 留出一段視線斷點；自我註記要滑過時間線後再進入視野。
                        const SizedBox(height: 96),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                          child: Align(
                            alignment: Alignment.center,
                            child: FractionallySizedBox(
                              widthFactor: 0.88,
                              child: CharacterSelfNotesPanel(
                                key: ValueKey(
                                  'self-notes-timeline-$_currentCharId',
                                ),
                                characterId: _currentCharId,
                                embedded: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (_characters.isNotEmpty && EmotionPanel.kVisible)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                          child: Align(
                            alignment: Alignment.center,
                            child: FractionallySizedBox(
                              widthFactor: 0.88,
                              child: EmotionPanel(
                                key: ValueKey(
                                  'emotion-below-notes-$_currentCharId',
                                ),
                                characterId: _currentCharId,
                              ),
                            ),
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
                              signature: c['signature'] as String?,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isActive && isCurrent && _onlineDwellReady)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: _OnlineStatusPill(animate: true),
                      )
                    else if (!isActive)
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
                              _onlineDwellReady = false;
                            });
                            if (isCurrent) _beginOnlineDwell(index);
                          },
                          child: Container(
                            key: const ValueKey('character-card-talk-button'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: YanciTheme.accent.withValues(alpha: 0.1),
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
                  ],
                ),
              ),
              const SizedBox(height: 64),
              const Spacer(),
              Transform.translate(
                offset: const Offset(0, 6),
                child: _buildResourceTabs(
                  charId: id,
                  charName: name,
                  embedded: true,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Spacer(),
                  if (XPostSettings.showEntry)
                    IconButton(
                      icon: Icon(
                        Icons.alternate_email_rounded,
                        size: 16,
                        color: YanciTheme.accent.withValues(alpha: 0.7),
                      ),
                      tooltip: 'X',
                      onPressed: () => showXPostPanel(context, id),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
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
              child: Container(
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

class _OnlineStatusPill extends StatefulWidget {
  final bool animate;

  const _OnlineStatusPill({required this.animate});

  @override
  State<_OnlineStatusPill> createState() => _OnlineStatusPillState();
}

class _OnlineStatusPillState extends State<_OnlineStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathController;

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
      value: 0.45,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _OnlineStatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncAnimation();
  }

  void _syncAnimation() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (widget.animate && !reduceMotion) {
      if (!_breathController.isAnimating) {
        _breathController.repeat(reverse: true);
      }
      return;
    }
    _breathController
      ..stop()
      ..value = 0.45;
  }

  @override
  void dispose() {
    _breathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onlineColor = YanciTheme.isDark
        ? YanciTheme.accentLight
        : YanciTheme.accent;

    return Semantics(
      container: true,
      label: L.get('char_online'),
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('character-card-online-status'),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _breathController,
                  builder: (context, child) {
                    final breath = Curves.easeInOutSine.transform(
                      _breathController.value,
                    );
                    return SizedBox(
                      width: 16,
                      height: 16,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.scale(
                            scale: 0.9 + (breath * 0.65),
                            child: Opacity(
                              opacity: 0.22 * (1 - breath),
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: onlineColor,
                                ),
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: 0.92 + (breath * 0.08),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: onlineColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              Text(
                L.get('char_online'),
                style: TextStyle(fontSize: 10, color: YanciTheme.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
