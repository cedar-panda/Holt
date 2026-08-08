import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../utils/latest_request_gate.dart';

/// A quiet, read-only window into the character's self notes.
/// The authoritative text remains on the character row; this widget never
/// edits, clears, or duplicates it.
class CharacterSelfNotesPanel extends StatefulWidget {
  final String characterId;

  const CharacterSelfNotesPanel({super.key, required this.characterId});

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
                    itemBuilder: (context, index) => Text(
                      '　　${_notes[index]}',
                      style: YanciTheme.bodyText.copyWith(height: 1.65),
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
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
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
                Row(
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
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.38,
                          ),
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: CustomPaint(
                    painter: _HandRuledNotePainter(
                      color: YanciTheme.accent.withValues(alpha: 0.14),
                      lineCount: 2,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 3, 4, 5),
                      child: _loading
                          ? Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                '　　……',
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.85,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.3,
                                  ),
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
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.85,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: hasNotes ? 0.64 : 0.34,
                                  ),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
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
