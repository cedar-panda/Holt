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
import '../widgets/x_post_panel.dart';

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

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(viewportFraction: 0.82);
    _load();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final chars = await DatabaseHelper.getCharacters();
    final activeId = await UserSettings.getActiveCharacterId();
    final activeIndex = chars.indexWhere((c) => c['id'] == activeId);
    if (!mounted) return;
    setState(() {
      _characters = chars;
      _activeId = activeId;
      _isLoading = false;
      _currentPage = activeIndex >= 0 ? activeIndex : 0;
    });
    // 等一幀再跳，確保 PageController 已掛載
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageCtrl.hasClients && activeIndex >= 0) {
        _pageCtrl.jumpToPage(activeIndex);
      }
    });
  }

  String get _currentCharId {
    if (_characters.isEmpty) return 'default';
    return _characters[_currentPage]['id'] as String? ?? 'default';
  }

  String get _currentCharName {
    if (_characters.isEmpty) return '';
    return _characters[_currentPage]['name'] as String? ?? '';
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
                    const SizedBox(width: 48),
                    Expanded(
                      child: Text(
                        L.get('nav_character'),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
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
                      height: 260,
                      child: PageView.builder(
                        controller: _pageCtrl,
                        itemCount: _characters.length,
                        onPageChanged: (i) {
                          HapticFeedback.selectionClick();
                          setState(() => _currentPage = i);
                        },
                        itemBuilder: (ctx, i) => _buildCard(_characters[i], i),
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
                  ),
                ),

              const SizedBox(height: 16),

              // ═══ 時間線 ═══
              if (_characters.isNotEmpty)
                CharacterTimelinePanel(characterId: _currentCharId),

              const Spacer(),

              // ═══ 關聯資源入口（語音 / 表情庫 / 記憶 / 收藏）═══
              if (_characters.isNotEmpty) _buildResourceTabs(),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> c, int index) {
    final id = c['id'] as String;
    final name = c['name'] as String? ?? '未命名';
    final gender = c['gender'] as String? ?? '';
    final relationship = c['relationship'] as String? ?? '';
    final desc = c['description'] as String? ?? '';
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
                ? Colors.white.withValues(alpha: isActive ? 0.08 : 0.04)
                : Colors.white.withValues(alpha: isActive ? 0.8 : 0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isActive
                  ? YanciTheme.accent.withValues(alpha: 0.4)
                  : YanciTheme.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.6),
              width: isActive ? 1.5 : 0.5,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: YanciTheme.accent.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // ═══ 圓形頭像 ═══
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: YanciTheme.accent.withValues(alpha: 0.1),
                      border: Border.all(
                        color: isActive
                            ? YanciTheme.accent.withValues(alpha: 0.3)
                            : YanciTheme.textSecondary.withValues(alpha: 0.1),
                        width: 1,
                      ),
                      image:
                          avatarPath.isNotEmpty && File(avatarPath).existsSync()
                          ? DecorationImage(
                              image: FileImage(File(avatarPath)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: avatarPath.isEmpty || !File(avatarPath).existsSync()
                        ? Icon(
                            Icons.person_rounded,
                            size: 22,
                            color: YanciTheme.accent.withValues(alpha: 0.4),
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: YanciTheme.headingMedium.copyWith(
                            fontSize: 16,
                          ),
                        ),
                        // ═══ 已婚標籤（結婚證彩蛋，簽署後常駐每個窗口）═══
                        FutureBuilder<bool>(
                          future: MarriageService.isMarried(id),
                          builder: (context, snap) {
                            if (snap.data != true) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.35,
                                    ),
                                    width: 0.6,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '❦',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: YanciTheme.accent,
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
                                        color: YanciTheme.accent,
                                        letterSpacing: 1,
                                        fontFamily: YanciTheme.fontFamily,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        if (gender.isNotEmpty || relationship.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              [
                                gender,
                                relationship,
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: YanciTheme.bodySmall.copyWith(
                                fontSize: 11,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: YanciTheme.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        L.get('char_in_use'),
                        style: TextStyle(
                          fontSize: 10,
                          color: YanciTheme.accent,
                        ),
                      ),
                    ),
                ],
              ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 10),
                Expanded(
                  child: Text(
                    desc,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 13,
                      color: YanciTheme.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              // ═══ 底部操作 ═══
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!isActive)
                    GestureDetector(
                      onTap: () async {
                        HapticFeedback.mediumImpact();
                        await UserSettings.saveActiveCharacterId(id);
                        await UserSettings.saveCharacterName(name);
                        if (!mounted) return;
                        setState(() => _activeId = id);
                      },
                      child: Container(
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
                  const Spacer(),
                  if (XPostSettings.showEntry)
                    // X 社群發文入口（暫時隱藏；功能碼保留）
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

  Widget _buildResourceTabs() {
    final charId = _currentCharId;
    final charName = _currentCharName;

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
      _ResourceTab(Icons.star_outline_rounded, L.get('char_tab_saved'), () {
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
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((tab) {
          return GestureDetector(
            onTap: tab.onTap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
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
                const SizedBox(height: 6),
                Text(
                  tab.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: YanciTheme.textSecondary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
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
