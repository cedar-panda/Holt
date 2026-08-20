import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../utils/latest_request_gate.dart';

/// A quiet window into the character's self notes.
/// The authoritative text remains on the character row. Deletion only updates
/// that local row; conversation-level static snapshots remain untouched.
class CharacterSelfNotesPanel extends StatefulWidget {
  final String characterId;
  final bool embedded;

  const CharacterSelfNotesPanel({
    super.key,
    required this.characterId,
    this.embedded = false,
  });

  @override
  State<CharacterSelfNotesPanel> createState() =>
      _CharacterSelfNotesPanelState();
}

class _CharacterSelfNotesPanelState extends State<CharacterSelfNotesPanel> {
  final LatestRequestGate _loadGate = LatestRequestGate();
  List<String> _notes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
    final stored = await DatabaseHelper.getSelfNotes(characterId);
    if (!mounted ||
        characterId != widget.characterId ||
        !_loadGate.isCurrent(generation)) {
      return;
    }
    setState(() {
      _notes = _parse(stored);
      _loading = false;
    });
  }

  static List<String> _parse(String value) => value
      .split('\n')
      .map((line) => line.trim().replaceFirst(RegExp(r'^[·•*\-]+\s*'), ''))
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  String get _title =>
      L.pick(en: 'Secretly remembering you', zhTW: '偷偷記住你', zhCN: '偷偷记住你');

  Future<void> _deleteNoteAt(int index, BuildContext sheetContext) async {
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
    setState(() {
      _notes = List<String>.of(_notes)..removeAt(index);
    });
    if (_notes.isEmpty && sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
  }

  Color get _notePaperColor => Color.alphaBlend(
    YanciTheme.accentLight.withValues(alpha: YanciTheme.isDark ? 0.10 : 0.07),
    YanciTheme.surfacePanel,
  );

  Color get _notePaperBorder =>
      (YanciTheme.isDark ? YanciTheme.accentLight : YanciTheme.accent)
          .withValues(alpha: YanciTheme.isDark ? 0.28 : 0.20);

  Widget _buildTitleRow(bool hasNotes) {
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
      ],
    );
  }

  Future<void> _showAll() async {
    if (_notes.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.52,
        minChildSize: 0.32,
        maxChildSize: 0.82,
        builder: (context, controller) => Container(
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
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
                        IconButton(
                          tooltip: L.pick(
                            en: 'Delete self-note',
                            zhTW: '刪除自我註記',
                            zhCN: '删除自我注记',
                          ),
                          onPressed: () => _deleteNoteAt(index, context),
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
        button: hasNotes,
        label: '$_title，$preview',
        child: GestureDetector(
          key: const ValueKey('character-self-notes-panel'),
          behavior: HitTestBehavior.opaque,
          onTap: hasNotes ? _showAll : null,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.embedded) _buildTitleRow(hasNotes),
                if (!widget.embedded) const SizedBox(height: 4),
                ConstrainedBox(
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
                        if (widget.embedded)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 5, 8, 0),
                            child: _buildTitleRow(hasNotes),
                          ),
                        if (widget.embedded) const SizedBox(height: 2),
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
                                        color: YanciTheme.characterResourceLabel
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
                                        color: YanciTheme.characterResourceLabel
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
