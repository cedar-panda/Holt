import 'dart:io';

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../theme/app_theme.dart';

Future<int?> showCharacterQuickPicker(
  BuildContext context, {
  required List<Map<String, dynamic>> characters,
  required int selectedIndex,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CharacterQuickPicker(
      characters: characters,
      selectedIndex: selectedIndex,
    ),
  );
}

class _CharacterQuickPicker extends StatefulWidget {
  const _CharacterQuickPicker({
    required this.characters,
    required this.selectedIndex,
  });

  final List<Map<String, dynamic>> characters;
  final int selectedIndex;

  @override
  State<_CharacterQuickPicker> createState() => _CharacterQuickPickerState();
}

class _CharacterQuickPickerState extends State<_CharacterQuickPicker> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  Set<String> _starredIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadStars();
  }

  Future<void> _loadStars() async {
    final ids = await UserSettings.getStarredCharacterIds();
    if (mounted) setState(() => _starredIds = ids);
  }

  Future<void> _toggleStar(String id) async {
    final next = !_starredIds.contains(id);
    await UserSettings.setCharacterStarred(id, next);
    if (!mounted) return;
    setState(() {
      if (next) {
        _starredIds.add(id);
      } else {
        _starredIds.remove(id);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final indexed = widget.characters.indexed
        .where((entry) {
          if (normalizedQuery.isEmpty) return true;
          final name = entry.$2['name']?.toString().toLowerCase() ?? '';
          return name.contains(normalizedQuery);
        })
        .toList(growable: false);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return FractionallySizedBox(
      heightFactor: 0.78,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 14 + bottomInset),
            child: Column(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  L.pick(en: 'All characters', zhTW: '全部角色', zhCN: '全部角色'),
                  style: YanciTheme.headingMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: L.pick(
                      en: 'Search characters',
                      zhTW: '搜尋角色',
                      zhCN: '搜索角色',
                    ),
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: L.pick(
                              en: 'Clear search',
                              zhTW: '清除搜尋',
                              zhCN: '清除搜索',
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                    filled: true,
                    fillColor: YanciTheme.textPrimary.withValues(alpha: 0.035),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(
                        color: YanciTheme.accent.withValues(alpha: 0.32),
                        width: 0.8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: indexed.isEmpty
                      ? Center(
                          child: Text(
                            L.pick(
                              en: 'No matching character',
                              zhTW: '沒有符合的角色',
                              zhCN: '没有符合的角色',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.58,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: indexed.length,
                          itemBuilder: (context, visibleIndex) {
                            final entry = indexed[visibleIndex];
                            final index = entry.$1;
                            final character = entry.$2;
                            return _CharacterChoice(
                              character: character,
                              selected: index == widget.selectedIndex,
                              starred: _starredIds.contains(
                                character['id']?.toString(),
                              ),
                              onToggleStar: () => _toggleStar(
                                character['id']?.toString() ?? '',
                              ),
                              onTap: () => Navigator.pop(context, index),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CharacterChoice extends StatelessWidget {
  const _CharacterChoice({
    required this.character,
    required this.selected,
    required this.starred,
    required this.onToggleStar,
    required this.onTap,
  });

  final Map<String, dynamic> character;
  final bool selected;
  final bool starred;
  final VoidCallback onToggleStar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = character['name']?.toString().trim() ?? '';
    final avatarPath = character['avatar_path']?.toString() ?? '';
    final avatarExists = avatarPath.isNotEmpty && File(avatarPath).existsSync();
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: YanciTheme.accent.withValues(alpha: 0.08),
                  backgroundImage: avatarExists
                      ? FileImage(File(avatarPath))
                      : null,
                  child: avatarExists
                      ? null
                      : Icon(
                          Icons.person_rounded,
                          size: 22,
                          color: YanciTheme.accent.withValues(alpha: 0.48),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name.isEmpty
                        ? L.pick(
                            en: 'Untitled character',
                            zhTW: '未命名角色',
                            zhCN: '未命名角色',
                          )
                        : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      color: selected
                          ? YanciTheme.accent
                          : YanciTheme.textPrimary,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 18, color: YanciTheme.accent),
                IconButton(
                  tooltip: starred
                      ? L.pick(en: 'Unstar', zhTW: '取消星標', zhCN: '取消星标')
                      : L.pick(en: 'Star', zhTW: '設為星標', zhCN: '设为星标'),
                  onPressed: onToggleStar,
                  icon: Icon(
                    starred ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 20,
                    color: starred
                        ? YanciTheme.accent
                        : YanciTheme.textSecondary.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
