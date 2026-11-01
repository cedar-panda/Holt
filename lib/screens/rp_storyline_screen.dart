import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';
import 'memory_screen.dart';
import 'rp_story_relationship_screen.dart';
import 'rp_storyline_timeline_screen.dart';
import 'rp_worldbook_screen.dart';

const String _manageStorylinesResult = '__manage_storylines__';

String rpStorylineDisplayName(Map<String, Object?> row, int ordinal) {
  final name = row['name']?.toString().trim() ?? '';
  if (name.isNotEmpty) return name;
  return L.pick(
    en: 'Storyline $ordinal',
    zhTW: '故事線 $ordinal',
    zhCN: '故事线 $ordinal',
  );
}

Future<String?> showRpStorylinePicker(
  BuildContext context, {
  required String characterId,
}) async {
  await DatabaseHelper.ensureDefaultRpStoryline(characterId);
  if (!context.mounted) return null;
  final rows = await DatabaseHelper.getRpStorylines(characterId);
  if (!context.mounted || rows.isEmpty) return null;
  if (rows.length == 1) return rows.single['id']?.toString();

  final selected = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: YanciTheme.surfacePanel,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              L.pick(
                en: 'Continue which storyline?',
                zhTW: '要從哪一條故事線開始？',
                zhCN: '要从哪一条故事线开始？',
              ),
              textAlign: TextAlign.center,
              style: YanciTheme.headingMedium,
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < rows.length; index++)
              _StorylineChoice(
                name: rpStorylineDisplayName(rows[index], index + 1),
                isDefault: rows[index]['is_default'] == 1,
                onTap: () =>
                    Navigator.pop(sheetContext, rows[index]['id']?.toString()),
              ),
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('manage-rp-storylines'),
              onPressed: () =>
                  Navigator.pop(sheetContext, _manageStorylinesResult),
              child: Text(
                L.pick(en: 'Manage storylines', zhTW: '管理故事線', zhCN: '管理故事线'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || selected == null) return null;
  if (selected != _manageStorylinesResult) return selected;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RpStorylineScreen(characterId: characterId),
    ),
  );
  if (!context.mounted) return null;
  return showRpStorylinePicker(context, characterId: characterId);
}

class _StorylineChoice extends StatelessWidget {
  const _StorylineChoice({
    required this.name,
    required this.isDefault,
    required this.onTap,
  });

  final String name;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isDefault,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(child: Text(name, style: YanciTheme.bodyText)),
                if (isDefault)
                  Text(
                    L.pick(en: 'Recent', zhTW: '最近使用', zhCN: '最近使用'),
                    style: YanciTheme.bodySmall.copyWith(
                      color: YanciTheme.accent.withValues(alpha: 0.78),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.38),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RpStorylineScreen extends StatefulWidget {
  const RpStorylineScreen({super.key, required this.characterId});

  final String characterId;

  @override
  State<RpStorylineScreen> createState() => _RpStorylineScreenState();
}

class _RpStorylineScreenState extends State<RpStorylineScreen> {
  List<Map<String, Object?>> _rows = const <Map<String, Object?>>[];
  bool _loading = true;

  int get _activeCount =>
      _rows.where((row) => row['status'] == 'active').length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await DatabaseHelper.ensureDefaultRpStoryline(widget.characterId);
    final rows = await DatabaseHelper.getRpStorylines(
      widget.characterId,
      includeArchived: true,
    );
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<String?> _askName({String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        title: Text(
          initial.isEmpty
              ? L.pick(en: 'New storyline', zhTW: '新的故事線', zhCN: '新的故事线')
              : L.pick(en: 'Rename', zhTW: '重新命名', zhCN: '重新命名'),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          textInputAction: TextInputAction.done,
          decoration: YanciTheme.themedInputDecoration(
            hintText: L.pick(
              en: 'Storyline name',
              zhTW: '故事線名稱',
              zhCN: '故事线名称',
            ),
            counterText: '',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _create() async {
    if (_activeCount >= 3) {
      _notice(
        L.pick(
          en: 'Each character can keep up to three active storylines.',
          zhTW: '每個角色最多保留三條進行中的故事線。',
          zhCN: '每个角色最多保留三条进行中的故事线。',
        ),
      );
      return;
    }
    final name = await _askName();
    if (name == null) return;
    await DatabaseHelper.createRpStoryline(
      characterId: widget.characterId,
      name: name,
    );
    await _load();
  }

  Future<void> _rename(Map<String, Object?> row, int index) async {
    final name = await _askName(
      initial: rpStorylineDisplayName(row, index + 1),
    );
    if (name == null) return;
    await DatabaseHelper.renameRpStoryline(
      characterId: widget.characterId,
      storylineId: row['id'].toString(),
      name: name,
    );
    await _load();
  }

  Future<void> _toggleArchive(Map<String, Object?> row) async {
    final archived = row['status'] != 'archived';
    try {
      await DatabaseHelper.setRpStorylineArchived(
        characterId: widget.characterId,
        storylineId: row['id'].toString(),
        archived: archived,
      );
      await _load();
    } on StateError {
      _notice(
        archived
            ? L.pick(
                en: 'Keep at least one active storyline.',
                zhTW: '至少需要保留一條進行中的故事線。',
                zhCN: '至少需要保留一条进行中的故事线。',
              )
            : L.pick(
                en: 'Archive another storyline before restoring this one.',
                zhTW: '請先封存其他故事線，再恢復這一條。',
                zhCN: '请先归档其他故事线，再恢复这一条。',
              ),
      );
    }
  }

  Future<void> _markRecent(Map<String, Object?> row) async {
    await DatabaseHelper.setDefaultRpStoryline(
      characterId: widget.characterId,
      storylineId: row['id'].toString(),
    );
    await _load();
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: Material(
        key: const ValueKey('rp-storyline-add'),
        color: YanciTheme.themedCardBackground(),
        shape: StadiumBorder(
          side: BorderSide(color: YanciTheme.themedCardBorder(), width: 0.7),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(YanciTheme.radiusPill),
          onTap: _activeCount >= 3 ? null : _create,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 19, color: YanciTheme.accent),
                const SizedBox(width: 5),
                Text(
                  L.pick(en: 'New', zhTW: '新建', zhCN: '新建'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 19,
                        ),
                      ),
                    ),
                    Text(
                      L.pick(en: 'Story archive', zhTW: '劇情檔案', zhCN: '剧情档案'),
                      style: YanciTheme.headingMedium,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 2, 24, 14),
                child: Text(
                  L.pick(
                    en: 'Memories, summaries, relationships, states, and worldbook entries stay inside their own storyline.',
                    zhTW: '每條故事線各自保存記憶、摘要、人物關係、劇情狀態與世界書。',
                    zhCN: '每条故事线各自保存记忆、摘要、人物关系、剧情状态与世界书。',
                  ),
                  textAlign: TextAlign.center,
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 2, 20, 88),
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) =>
                            _storylineCard(_rows[index], index),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _storylineCard(Map<String, Object?> row, int index) {
    final archived = row['status'] == 'archived';
    final isDefault = row['is_default'] == 1;
    final id = row['id'].toString();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final resourceFontSize =
        15.0 * YanciTheme.fontScale.clamp(0.8, 1.2).toDouble();
    final resourceTextStyle = YanciTheme.bodyText.copyWith(
      fontSize: resourceFontSize,
      height: 1.2,
    );
    Widget resourceButton({
      required String keySuffix,
      required String label,
      required VoidCallback onTap,
    }) {
      return Material(
        key: ValueKey<String>('rp-storyline-$id-$keySuffix'),
        color: YanciTheme.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  textScaler: const TextScaler.linear(1),
                  maxLines: 1,
                  style: resourceTextStyle,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedOpacity(
      key: ValueKey<String>('storyline-$id'),
      duration: duration,
      curve: Curves.easeOut,
      opacity: archived ? 0.56 : 1,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(14, 13, 8, 10),
        decoration: BoxDecoration(
          color: YanciTheme.themedCardBackground(),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDefault
                ? YanciTheme.accent.withValues(alpha: 0.34)
                : YanciTheme.textSecondary.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    rpStorylineDisplayName(row, index + 1),
                    style: YanciTheme.bodyText.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: isDefault && !archived
                      ? Text(
                          L.pick(en: 'Recent', zhTW: '最近使用', zhCN: '最近使用'),
                          key: const ValueKey<String>('recent'),
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 10,
                            color: YanciTheme.accent.withValues(alpha: 0.76),
                          ),
                        )
                      : const SizedBox.shrink(
                          key: ValueKey<String>('not-recent'),
                        ),
                ),
                PopupMenuButton<String>(
                  tooltip: L.pick(en: 'More', zhTW: '更多', zhCN: '更多'),
                  onSelected: (value) {
                    if (value == 'rename') _rename(row, index);
                    if (value == 'archive') _toggleArchive(row);
                    if (value == 'recent') _markRecent(row);
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    if (!archived && !isDefault)
                      PopupMenuItem<String>(
                        value: 'recent',
                        child: Text(
                          L.pick(
                            en: 'Mark as recent',
                            zhTW: '設為最近使用',
                            zhCN: '设为最近使用',
                          ),
                        ),
                      ),
                    PopupMenuItem<String>(
                      value: 'rename',
                      child: Text(
                        L.pick(en: 'Rename', zhTW: '重新命名', zhCN: '重新命名'),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'archive',
                      child: Text(
                        archived
                            ? L.pick(en: 'Restore', zhTW: '恢復', zhCN: '恢复')
                            : L.pick(en: 'Archive', zhTW: '封存', zhCN: '归档'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (!archived) ...[
              const SizedBox(height: 8),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 3.4,
                children: [
                  resourceButton(
                    keySuffix: 'worldbook',
                    label: L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书'),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => RpWorldbookScreen(
                          characterId: widget.characterId,
                          continuityId: id,
                        ),
                      ),
                    ),
                  ),
                  resourceButton(
                    keySuffix: 'relationships',
                    label: L.pick(
                      en: 'Relationships',
                      zhTW: '人物關係',
                      zhCN: '人物关系',
                    ),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => RpStoryRelationshipScreen(
                          characterId: widget.characterId,
                          continuityId: id,
                        ),
                      ),
                    ),
                  ),
                  resourceButton(
                    keySuffix: 'timeline',
                    label: L.pick(en: 'Timeline', zhTW: '時間線', zhCN: '时间线'),
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => RpStorylineTimelineScreen(
                          characterId: widget.characterId,
                          continuityId: id,
                          storylineLabel: rpStorylineDisplayName(
                            row,
                            index + 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  resourceButton(
                    keySuffix: 'memory',
                    label: L.pick(
                      en: 'Memories & summaries',
                      zhTW: '記憶與摘要',
                      zhCN: '记忆与摘要',
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MemoryScreen(
                          characterId: widget.characterId,
                          contextMode: ContextMode.rp,
                          continuityId: id,
                          scopeLabel: rpStorylineDisplayName(row, index + 1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
