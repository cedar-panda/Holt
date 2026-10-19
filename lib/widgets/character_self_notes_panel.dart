import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../models/character_self_note.dart';
import '../services/locale_strings.dart';
import '../services/settings/memory_settings.dart';
import '../theme/app_theme.dart';
import '../utils/latest_request_gate.dart';

/// A quiet window into the character's self notes.
/// The authoritative text remains on the character row. Deletion only updates
/// that local row; conversation-level static snapshots remain untouched.
class CharacterSelfNotesPanel extends StatefulWidget {
  final String characterId;
  final bool embedded;
  final bool initiallyCollapsed;

  const CharacterSelfNotesPanel({
    super.key,
    required this.characterId,
    this.embedded = false,
    this.initiallyCollapsed = false,
  });

  @override
  State<CharacterSelfNotesPanel> createState() =>
      _CharacterSelfNotesPanelState();
}

class _CharacterSelfNotesPanelState extends State<CharacterSelfNotesPanel> {
  final LatestRequestGate _loadGate = LatestRequestGate();
  List<String> _notes = const [];
  List<CharacterSelfNote> _records = const [];
  bool _loading = true;
  bool _longTermEnabled = false;
  int _injectionLimit = 12;
  late bool _collapsed;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.initiallyCollapsed;
    _load();
  }

  @override
  void didUpdateWidget(covariant CharacterSelfNotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId) _load();
  }

  @override
  void dispose() {
    _loadGate.invalidate();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = _loadGate.begin();
    final characterId = widget.characterId;
    if (mounted) setState(() => _loading = true);
    final results = await Future.wait<Object>(<Future<Object>>[
      DatabaseHelper.getSelfNoteRecords(characterId),
      MemorySettings.getSelfNotesLongTermEnabled(),
      MemorySettings.getSelfNotesInjectionLimit(),
    ]);
    if (!mounted ||
        characterId != widget.characterId ||
        !_loadGate.isCurrent(generation)) {
      return;
    }
    setState(() {
      _records = results[0] as List<CharacterSelfNote>;
      _notes = _records.map((item) => item.content).toList(growable: false);
      _longTermEnabled = results[1] as bool;
      _injectionLimit = results[2] as int;
      _loading = false;
    });
  }

  String get _title =>
      L.pick(en: 'Secretly remembering you', zhTW: '偷偷記住你', zhCN: '偷偷记住你');

  Future<void> _deleteNoteAt(
    int index,
    BuildContext sheetContext,
    StateSetter setSheetState,
  ) async {
    if (index < 0 || index >= _notes.length) return;
    final note = _notes[index];
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          L.pick(
            en: 'Delete this self-note?',
            zhTW: '刪除這條自我註記？',
            zhCN: '删除这条自我注记？',
          ),
        ),
        content: Text(
          L.pick(
            en: 'This cannot be undone. It will stop being injected into new prompts; the current static cache will not be changed.',
            zhTW: '刪除後不可復原。它會從之後的新注入內容中移除，但不會改寫目前的靜態 cache。',
            zhCN: '删除后不可恢复。它会从之后的新注入内容中移除，但不会改写当前的静态 cache。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final deleted = await DatabaseHelper.deleteSelfNote(
      widget.characterId,
      note,
    );
    if (!mounted || !deleted) return;
    await _load();
    if (_notes.isEmpty && sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    } else if (sheetContext.mounted) {
      // The sheet lives on its own route. Rebuilding only the page behind it
      // leaves stale rows/icons visible and makes lock/delete look broken.
      setSheetState(() {});
    }
  }

  Future<void> _toggleLock(
    int index,
    BuildContext sheetContext,
    StateSetter setSheetState,
  ) async {
    if (index < 0 || index >= _records.length) return;
    final note = _records[index];
    final updated = await DatabaseHelper.setSelfNoteLocked(
      note.id,
      !note.locked,
    );
    if (!mounted || !sheetContext.mounted) return;
    if (!updated) {
      ScaffoldMessenger.of(sheetContext).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Up to 10 self-notes can be locked.',
              zhTW: '最多可鎖定 10 條自我註記。',
              zhCN: '最多可锁定 10 条自我注记。',
            ),
          ),
        ),
      );
      return;
    }
    if (!mounted || !sheetContext.mounted) return;
    setState(() {
      final next = List<CharacterSelfNote>.of(_records);
      next[index] = note.copyWith(locked: !note.locked);
      _records = next;
    });
    setSheetState(() {});
  }

  Future<void> _showSource(
    CharacterSelfNote note,
    BuildContext sheetContext,
  ) async {
    final messages = <String>[];
    for (final id in note.sourceMessageIds) {
      final message = await DatabaseHelper.getMessageById(id);
      if (message == null || message.text.trim().isEmpty) continue;
      messages.add(
        '${message.isUser ? 'User' : 'Char'} · ${message.createdAt.toLocal()}\n${message.text.trim()}',
      );
    }
    if (!sheetContext.mounted) return;
    await showDialog<void>(
      context: sheetContext,
      builder: (context) => AlertDialog(
        title: Text(
          L.pick(en: 'Source conversation', zhTW: '來源對話', zhCN: '来源对话'),
        ),
        content: SingleChildScrollView(
          child: Text(
            <String>[
              if (note.modelId.isNotEmpty)
                '${note.provider.isEmpty ? '' : '${note.provider} · '}${note.modelId}',
              if (messages.isNotEmpty) ...messages,
              if (messages.isEmpty)
                L.pick(
                  en: 'The original message is unavailable for this legacy note.',
                  zhTW: '這是舊版註記，沒有可追溯的原始消息。',
                  zhCN: '这是旧版注记，没有可追溯的原始消息。',
                ),
            ].join('\n\n'),
            style: YanciTheme.bodyText.copyWith(height: 1.55),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭')),
          ),
        ],
      ),
    );
  }

  Color get _notePaperColor => Color.alphaBlend(
    YanciTheme.accentLight.withValues(alpha: YanciTheme.isDark ? 0.10 : 0.07),
    YanciTheme.surfacePanel,
  );

  Color get _notePaperBorder =>
      (YanciTheme.isDark ? YanciTheme.accentLight : YanciTheme.accent)
          .withValues(alpha: YanciTheme.isDark ? 0.28 : 0.20);

  Widget _buildTitleRow(bool hasNotes, {bool showChevron = false}) {
    return Row(
      children: [
        Text(
          _title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: YanciTheme.textPrimary.withValues(alpha: 0.7),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        const Spacer(),
        if (hasNotes)
          Text(
            '${_notes.length}',
            style: TextStyle(
              fontSize: 10,
              color: YanciTheme.textSecondary.withValues(alpha: 0.38),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        if (showChevron) ...[
          const SizedBox(width: 5),
          AnimatedRotation(
            turns: _collapsed ? 0 : .5,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: YanciTheme.accent.withValues(alpha: .55),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showAll() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.52,
          minChildSize: 0.32,
          maxChildSize: 0.82,
          builder: (context, controller) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 3,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_title, style: YanciTheme.headingMedium),
                        ),
                        IconButton(
                          tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                L.pick(
                                  en: 'Keep long-term history',
                                  zhTW: '長期保存自我註記',
                                  zhCN: '长期保存自我注记',
                                ),
                                style: YanciTheme.bodySmall,
                              ),
                            ),
                            Switch.adaptive(
                              value: _longTermEnabled,
                              onChanged: (value) async {
                                await MemorySettings.saveSelfNotesLongTermEnabled(
                                  value,
                                );
                                if (!mounted) return;
                                setState(() => _longTermEnabled = value);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                L.pick(
                                  en: 'Static injection count',
                                  zhTW: '靜態注入條數',
                                  zhCN: '静态注入条数',
                                ),
                                style: YanciTheme.bodySmall,
                              ),
                            ),
                            DropdownButton<int>(
                              value: _injectionLimit,
                              underline: const SizedBox(),
                              items: List<DropdownMenuItem<int>>.generate(
                                12,
                                (index) => DropdownMenuItem<int>(
                                  value: index + 1,
                                  child: Text('${index + 1}'),
                                ),
                              ),
                              onChanged: (value) async {
                                if (value == null) return;
                                await MemorySettings.saveSelfNotesInjectionLimit(
                                  value,
                                );
                                if (!mounted) return;
                                setState(() => _injectionLimit = value);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
                      itemCount: _notes.length,
                      separatorBuilder: (_, _) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          height: 1,
                          child: CustomPaint(
                            painter: _HandRuledNotePainter(
                              color: YanciTheme.accent.withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                      ),
                      itemBuilder: (context, index) => Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              '　　${_notes[index]}',
                              style: YanciTheme.bodyText.copyWith(
                                height: 1.65,
                                color: YanciTheme.characterResourceLabel,
                              ),
                            ),
                          ),
                          if (_records[index].sourceMessageIds.isNotEmpty ||
                              _records[index].modelId.isNotEmpty)
                            IconButton(
                              tooltip: L.pick(
                                en: 'View source',
                                zhTW: '查看來源',
                                zhCN: '查看来源',
                              ),
                              onPressed: () =>
                                  _showSource(_records[index], context),
                              icon: const Icon(Icons.history_rounded),
                              iconSize: 18,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.48,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 44,
                              ),
                            ),
                          IconButton(
                            key: ValueKey(
                              'character-self-note-lock-${_records[index].id}',
                            ),
                            tooltip: _records[index].locked
                                ? L.pick(
                                    en: 'Unlock self-note',
                                    zhTW: '取消鎖定',
                                    zhCN: '取消锁定',
                                  )
                                : L.pick(
                                    en: 'Lock self-note',
                                    zhTW: '鎖定註記',
                                    zhCN: '锁定注记',
                                  ),
                            onPressed: () =>
                                _toggleLock(index, context, setSheetState),
                            icon: Icon(
                              _records[index].locked
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                            ),
                            iconSize: 17,
                            color: _records[index].locked
                                ? YanciTheme.accent
                                : YanciTheme.textSecondary.withValues(
                                    alpha: 0.42,
                                  ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 44,
                            ),
                          ),
                          IconButton(
                            tooltip: L.pick(
                              en: 'Delete self-note',
                              zhTW: '刪除自我註記',
                              zhCN: '删除自我注记',
                            ),
                            onPressed: () =>
                                _deleteNoteAt(index, context, setSheetState),
                            icon: const Icon(Icons.delete_outline_rounded),
                            iconSize: 18,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.48,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
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
  }

  @override
  Widget build(BuildContext context) {
    final hasNotes = _notes.isNotEmpty;
    final preview = hasNotes
        ? _notes.last
        : L.pick(
            en: 'Nothing has been quietly noted yet',
            zhTW: '還沒有偷偷記下的事',
            zhCN: '还没有偷偷记下的事',
          );
    return Padding(
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Semantics(
        container: true,
        button: true,
        label: '$_title，$preview',
        child: GestureDetector(
          key: const ValueKey('character-self-notes-panel'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.initiallyCollapsed
              ? () => setState(() => _collapsed = !_collapsed)
              : _showAll,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.embedded)
                  _buildTitleRow(
                    hasNotes,
                    showChevron: widget.initiallyCollapsed,
                  ),
                if (!widget.embedded) const SizedBox(height: 4),
                if (widget.embedded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 5, 0, 2),
                    child: _buildTitleRow(
                      hasNotes,
                      showChevron: widget.initiallyCollapsed,
                    ),
                  ),
                if (!_collapsed)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showAll,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: widget.embedded ? 58 : 36,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.embedded
                              ? Colors.transparent
                              : _notePaperColor,
                          border: widget.embedded
                              ? null
                              : Border.all(color: _notePaperBorder, width: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CustomPaint(
                              painter: _HandRuledNotePainter(
                                color: YanciTheme.accent.withValues(
                                  alpha: YanciTheme.isDark ? 0.14 : 0.10,
                                ),
                                lineCount: 2,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(0, 2, 4, 3),
                                child: _loading
                                    ? Align(
                                        alignment: Alignment.topLeft,
                                        child: Text(
                                          '　　……',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            height: 1.55,
                                            color: YanciTheme
                                                .characterResourceLabel
                                                .withValues(alpha: 0.72),
                                            fontFamily: YanciTheme.fontFamily,
                                          ),
                                        ),
                                      )
                                    : Align(
                                        alignment: Alignment.topLeft,
                                        child: Text(
                                          '　　$preview',
                                          key: const ValueKey(
                                            'character-self-notes-preview',
                                          ),
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            height: 1.55,
                                            color: YanciTheme
                                                .characterResourceLabel
                                                .withValues(
                                                  alpha: hasNotes ? 1.0 : 0.58,
                                                ),
                                            fontFamily: YanciTheme.fontFamily,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
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

class _HandRuledNotePainter extends CustomPainter {
  final Color color;
  final int lineCount;

  const _HandRuledNotePainter({required this.color, this.lineCount = 1});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.75
      ..strokeCap = StrokeCap.round;
    final spacing = size.height / lineCount;
    for (var line = 0; line < lineCount; line++) {
      final baseline = lineCount == 1
          ? size.height / 2
          : spacing * (line + 1) - 2;
      var x = 0.0;
      var dash = 0;
      while (x < size.width) {
        final length = switch (dash % 3) {
          0 => 8.0,
          1 => 11.0,
          _ => 6.0,
        };
        final wobble = switch (dash % 4) {
          0 => -0.25,
          1 => 0.15,
          2 => 0.3,
          _ => -0.1,
        };
        final end = (x + length).clamp(0.0, size.width);
        canvas.drawLine(
          Offset(x, baseline + wobble),
          Offset(end, baseline - wobble),
          paint,
        );
        x = end + 4.5;
        dash++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandRuledNotePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.lineCount != lineCount;
}
