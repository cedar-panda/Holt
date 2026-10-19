import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/locale_strings.dart';
import '../services/rp_worldbook_service.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

class RpWorldbookScreen extends StatefulWidget {
  const RpWorldbookScreen({
    super.key,
    required this.characterId,
    this.continuityId = 'main',
  });

  final String characterId;
  final String continuityId;

  @override
  State<RpWorldbookScreen> createState() => _RpWorldbookScreenState();
}

class _RpWorldbookScreenState extends State<RpWorldbookScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _reviews = const <Map<String, dynamic>>[];
  bool _loading = true;
  bool _showReviews = false;

  @override
  void initState() {
    super.initState();
    RpWorldbookService.revision.addListener(_handleWorldbookRevision);
    _load();
  }

  void _handleWorldbookRevision() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    RpWorldbookService.revision.removeListener(_handleWorldbookRevision);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      RpWorldbookService.listEntries(
        characterId: widget.characterId,
        continuityId: widget.continuityId,
        query: _searchController.text,
      ),
      RpWorldbookService.listPendingReviews(
        characterId: widget.characterId,
        continuityId: widget.continuityId,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _entries = result[0];
      _reviews = result[1];
      _loading = false;
    });
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final name = TextEditingController(text: row?['name']?.toString() ?? '');
    final content = TextEditingController(
      text: row?['content']?.toString() ?? '',
    );
    final category = TextEditingController(
      text: row?['category']?.toString() ?? 'other',
    );
    final scope = TextEditingController(
      text: row?['scope']?.toString() ?? 'global',
    );
    final visibility = TextEditingController(
      text: row?['visibility']?.toString() ?? 'public',
    );
    final triggers = TextEditingController(
      text: _stringList(row?['triggers_json']).join('、'),
    );
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: YanciTheme.surfacePanel,
      builder: (context) {
        final media = MediaQuery.of(context);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              media.viewInsets.bottom + 32,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  row == null
                      ? L.pick(
                          en: 'New worldbook entry',
                          zhTW: '新增世界書條目',
                          zhCN: '新增世界书条目',
                        )
                      : row['name']?.toString() ?? '',
                  style: YanciTheme.headingMedium,
                ),
                const SizedBox(height: 16),
                _field(name, L.pick(en: 'Name', zhTW: '名稱', zhCN: '名称')),
                _field(
                  content,
                  L.pick(en: 'World setting', zhTW: '世界設定', zhCN: '世界设定'),
                  maxLines: 7,
                ),
                _field(
                  category,
                  L.pick(en: 'Category', zhTW: '分類', zhCN: '分类'),
                ),
                _field(scope, L.pick(en: 'Scope', zhTW: '生效範圍', zhCN: '生效范围')),
                _field(
                  visibility,
                  L.pick(en: 'Visibility', zhTW: '知情範圍', zhCN: '知情范围'),
                ),
                _field(
                  triggers,
                  L.pick(
                    en: 'Recall terms',
                    zhTW: '召回詞（以逗號分隔）',
                    zhCN: '召回词（以逗号分隔）',
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    if (name.text.trim().isEmpty ||
                        content.text.trim().isEmpty) {
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (saved == true) {
      final parsedTriggers = triggers.text
          .split(RegExp(r'[,，、]'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (row == null) {
        await RpWorldbookService.createManualEntry(
          characterId: widget.characterId,
          continuityId: widget.continuityId,
          name: name.text,
          content: content.text,
          category: category.text,
          scope: scope.text,
          visibility: visibility.text,
          triggers: parsedTriggers,
        );
      } else {
        await RpWorldbookService.updateManualEntry(
          id: row['id'].toString(),
          characterId: widget.characterId,
          continuityId: widget.continuityId,
          name: name.text,
          content: content.text,
          category: category.text,
          scope: scope.text,
          visibility: visibility.text,
          triggers: parsedTriggers,
        );
      }
      await _load();
    }
    name.dispose();
    content.dispose();
    category.dispose();
    scope.dispose();
    visibility.dispose();
    triggers.dispose();
  }

  Future<void> _toggleArchive(Map<String, dynamic> row) async {
    final archived = row['status'] != 'archived';
    await RpWorldbookService.setArchived(
      id: row['id'].toString(),
      characterId: widget.characterId,
      continuityId: widget.continuityId,
      archived: archived,
      endedReason: archived
          ? L.pick(en: 'Archived by user', zhTW: '由使用者封存', zhCN: '由用户封存')
          : '',
    );
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final controller = TextEditingController();
    final requiredText = L.pick(en: 'DELETE', zhTW: '刪除', zhCN: '删除');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        title: Text(
          L.pick(
            en: 'Delete worldbook entry',
            zhTW: '刪除世界書條目',
            zhCN: '删除世界书条目',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.pick(
                en: 'Type $requiredText to confirm.',
                zhTW: '輸入「$requiredText」以確認。',
                zhCN: '输入“$requiredText”以确认。',
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: controller, autofocus: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim() == requiredText),
            child: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true) return;
    await RpWorldbookService.deleteManualEntry(
      id: row['id'].toString(),
      characterId: widget.characterId,
      continuityId: widget.continuityId,
    );
    await _load();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int maxLines = 3,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      minLines: 1,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _showReviews
          ? null
          : FloatingActionButton.small(
              key: const ValueKey('rp-worldbook-add'),
              onPressed: () => _edit(),
              backgroundColor: YanciTheme.accent,
              child: const Icon(Icons.add_rounded),
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
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 19,
                        ),
                      ),
                    ),
                    Text(
                      L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书'),
                      style: YanciTheme.headingMedium,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: _modeButton(
                        selected: !_showReviews,
                        label: L.pick(
                          en: 'Entries',
                          zhTW: '世界設定',
                          zhCN: '世界设定',
                        ),
                        onTap: () => setState(() => _showReviews = false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _modeButton(
                        selected: _showReviews,
                        label: L.pick(
                          en: 'Review (${_reviews.length})',
                          zhTW: '待審核（${_reviews.length}）',
                          zhCN: '待审核（${_reviews.length}）',
                        ),
                        onTap: () => setState(() => _showReviews = true),
                      ),
                    ),
                  ],
                ),
              ),
              if (!_showReviews)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => _load(),
                    decoration: InputDecoration(
                      hintText: L.pick(
                        en: 'Search worldbook',
                        zhTW: '搜尋世界設定',
                        zhCN: '搜索世界设定',
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    ),
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : _showReviews
                    ? _reviewList()
                    : _entryList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeButton({
    required bool selected,
    required String label,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Container(
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected
              ? YanciTheme.accent.withValues(alpha: 0.65)
              : YanciTheme.textSecondary.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        label,
        style: YanciTheme.bodySmall.copyWith(
          color: selected ? YanciTheme.accent : YanciTheme.textSecondary,
        ),
      ),
    ),
  );

  Widget _entryList() {
    if (_entries.isEmpty) {
      return _empty(
        L.pick(
          en: 'World settings will appear after enough RP summaries, or you can add one manually.',
          zhTW: '累積足夠的 RP 摘要後會在這裡整理世界設定，也可以手動新增。',
          zhCN: '累积足够的 RP 摘要后会在这里整理世界设定，也可以手动新增。',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 88),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final row = _entries[index];
        final archived = row['status'] == 'archived';
        return Opacity(
          opacity: archived ? 0.55 : 1,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: YanciTheme.textSecondary.withValues(alpha: 0.16),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _edit(row),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row['name']?.toString() ?? '',
                          style: YanciTheme.bodyText.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        MarkdownBody(
                          data: row['content']?.toString() ?? '',
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            p: YanciTheme.bodySmall.copyWith(height: 1.45),
                            listBullet: YanciTheme.bodySmall.copyWith(
                              height: 1.45,
                            ),
                            blockSpacing: 7,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${row['category']} · ${row['scope']} · ${row['visibility']}',
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 10,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.62,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') _edit(row);
                    if (value == 'archive') _toggleArchive(row);
                    if (value == 'delete') _delete(row);
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'edit',
                      child: Text(L.pick(en: 'Edit', zhTW: '編輯', zhCN: '编辑')),
                    ),
                    PopupMenuItem<String>(
                      value: 'archive',
                      child: Text(
                        archived
                            ? L.pick(en: 'Restore', zhTW: '恢復', zhCN: '恢复')
                            : L.pick(en: 'Archive', zhTW: '封存', zhCN: '归档'),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editReview(Map<String, dynamic> row) async {
    final payload = _jsonMap(row['payload_json']);
    final suggestedKey = payload['entry_key']?.toString().trim() ?? '';
    Map<String, dynamic>? suggestedTarget;
    for (final entry in _entries) {
      if (entry['entry_key']?.toString() == suggestedKey &&
          entry['status'] != 'archived') {
        suggestedTarget = entry;
        break;
      }
    }
    String valueOr(Object? primary, Object? fallback, String defaultValue) {
      final first = primary?.toString().trim() ?? '';
      if (first.isNotEmpty) return first;
      final second = fallback?.toString().trim() ?? '';
      return second.isEmpty ? defaultValue : second;
    }

    final name = TextEditingController(
      text: valueOr(payload['candidate_name'], suggestedTarget?['name'], ''),
    );
    final content = TextEditingController(
      text: valueOr(
        payload['candidate_content'],
        suggestedTarget?['content'],
        '',
      ),
    );
    final category = TextEditingController(
      text: valueOr(payload['category'], suggestedTarget?['category'], 'other'),
    );
    final scope = TextEditingController(
      text: valueOr(payload['scope'], suggestedTarget?['scope'], 'global'),
    );
    final visibility = TextEditingController(
      text: valueOr(
        payload['visibility'],
        suggestedTarget?['visibility'],
        'public',
      ),
    );
    final payloadTriggers = _valueStringList(payload['triggers']);
    final initialTriggers = payloadTriggers.isNotEmpty
        ? payloadTriggers
        : _stringList(suggestedTarget?['triggers_json']);
    final triggers = TextEditingController(text: initialTriggers.join('、'));
    var targetEntryKey = suggestedTarget?['entry_key']?.toString() ?? '';

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: YanciTheme.surfacePanel,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final media = MediaQuery.of(sheetContext);
          final activeEntries = _entries
              .where((entry) => entry['status'] != 'archived')
              .toList(growable: false);
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                24,
                20,
                24,
                media.viewInsets.bottom + 32,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    L.pick(
                      en: 'Review worldbook change',
                      zhTW: '審核世界書變更',
                      zhCN: '审核世界书变更',
                    ),
                    style: YanciTheme.headingMedium,
                  ),
                  const SizedBox(height: 16),
                  _field(name, L.pick(en: 'Name', zhTW: '名稱', zhCN: '名称')),
                  _field(
                    content,
                    L.pick(
                      en: 'Final world setting',
                      zhTW: '最終世界設定',
                      zhCN: '最终世界设定',
                    ),
                    maxLines: 8,
                  ),
                  _field(
                    category,
                    L.pick(en: 'Category', zhTW: '分類', zhCN: '分类'),
                  ),
                  _field(
                    scope,
                    L.pick(en: 'Scope', zhTW: '生效範圍', zhCN: '生效范围'),
                  ),
                  _field(
                    visibility,
                    L.pick(en: 'Visibility', zhTW: '知情範圍', zhCN: '知情范围'),
                  ),
                  _field(
                    triggers,
                    L.pick(
                      en: 'Recall terms',
                      zhTW: '召回詞（以逗號分隔）',
                      zhCN: '召回词（以逗号分隔）',
                    ),
                  ),
                  const SizedBox(height: 2),
                  DropdownButtonFormField<String>(
                    initialValue: targetEntryKey,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: L.pick(
                        en: 'Resolution',
                        zhTW: '處理方式',
                        zhCN: '处理方式',
                      ),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: '',
                        child: Text(
                          L.pick(
                            en: 'Create a new entry',
                            zhTW: '建立為新條目',
                            zhCN: '建立为新条目',
                          ),
                        ),
                      ),
                      for (final entry in activeEntries)
                        DropdownMenuItem<String>(
                          value: entry['entry_key']?.toString() ?? '',
                          child: Text(
                            L.pick(
                              en: 'Merge into ${entry['name']}',
                              zhTW: '合併至「${entry['name']}」',
                              zhCN: '合并至“${entry['name']}”',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setSheetState(() => targetEntryKey = value ?? ''),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(sheetContext, 'draft'),
                          child: Text(
                            L.pick(
                              en: 'Save draft',
                              zhTW: '儲存草稿',
                              zhCN: '保存草稿',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            if (name.text.trim().isEmpty ||
                                content.text.trim().isEmpty) {
                              return;
                            }
                            Navigator.pop(sheetContext, 'resolve');
                          },
                          child: Text(
                            targetEntryKey.isEmpty
                                ? L.pick(
                                    en: 'Create entry',
                                    zhTW: '建立條目',
                                    zhCN: '建立条目',
                                  )
                                : L.pick(
                                    en: 'Submit merge',
                                    zhTW: '送出合併',
                                    zhCN: '提交合并',
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    final parsedTriggers = triggers.text
        .split(RegExp(r'[,，、]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    try {
      if (result == 'draft') {
        await RpWorldbookService.updatePendingReviewDraft(
          id: row['id'].toString(),
          characterId: widget.characterId,
          continuityId: widget.continuityId,
          name: name.text,
          content: content.text,
          category: category.text,
          scope: scope.text,
          visibility: visibility.text,
          triggers: parsedTriggers,
        );
      } else if (result == 'resolve') {
        await RpWorldbookService.resolvePendingReview(
          id: row['id'].toString(),
          characterId: widget.characterId,
          continuityId: widget.continuityId,
          name: name.text,
          content: content.text,
          category: category.text,
          scope: scope.text,
          visibility: visibility.text,
          triggers: parsedTriggers,
          targetEntryKey: targetEntryKey,
        );
      }
      if (result != null) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(
                en: 'Could not save this worldbook change.',
                zhTW: '這筆世界書變更未能儲存。',
                zhCN: '这条世界书变更未能保存。',
              ),
            ),
          ),
        );
      }
    } finally {
      name.dispose();
      content.dispose();
      category.dispose();
      scope.dispose();
      visibility.dispose();
      triggers.dispose();
    }
  }

  Widget _reviewList() {
    if (_reviews.isEmpty) {
      return _empty(
        L.pick(
          en: 'No worldbook conflicts or possible duplicates need review.',
          zhTW: '目前沒有需要處理的世界書衝突或疑似重複。',
          zhCN: '目前没有需要处理的世界书冲突或疑似重复。',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 36),
      itemCount: _reviews.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final row = _reviews[index];
        final payload = _jsonMap(row['payload_json']);
        final title = row['kind'] == 'conflict'
            ? L.pick(en: 'Conflict', zhTW: '設定衝突', zhCN: '设定冲突')
            : L.pick(en: 'Possible duplicate', zhTW: '疑似重複', zhCN: '疑似重复');
        final content =
            [
                  payload['candidate_name'],
                  payload['candidate_content'],
                  payload['overlap_excerpt'],
                  payload['reason'],
                ]
                .map((item) => item?.toString().trim() ?? '')
                .where((item) => item.isNotEmpty)
                .join('\n');
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: YanciTheme.accent.withValues(alpha: 0.24),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: YanciTheme.bodyText),
              if (content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  content,
                  style: YanciTheme.bodySmall.copyWith(height: 1.4),
                ),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: <Widget>[
                    TextButton(
                      onPressed: () async {
                        await RpWorldbookService.dismissReview(
                          id: row['id'].toString(),
                          characterId: widget.characterId,
                          continuityId: widget.continuityId,
                        );
                        await _load();
                      },
                      child: Text(
                        L.pick(
                          en: 'Keep current settings',
                          zhTW: '保留目前設定',
                          zhCN: '保留当前设定',
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _editReview(row),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: Text(
                        L.pick(
                          en: 'Review and edit',
                          zhTW: '審核並編輯',
                          zhCN: '审核并编辑',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: YanciTheme.bodySmall.copyWith(color: YanciTheme.textSecondary),
      ),
    ),
  );

  static List<String> _stringList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.map((item) => item.toString()).toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  static List<String> _valueStringList(Object? raw) {
    if (raw is List) {
      return raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return _stringList(raw);
  }

  static Map<String, dynamic> _jsonMap(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}
