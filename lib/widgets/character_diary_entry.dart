import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character_diary_entry.dart';
import '../services/character_diary_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'gradient_background.dart';

/// Daily-mode diary entry point used on the character tab.
///
/// The character page only shows the newest title. The full archive remains a
/// separate chronological reading surface so old entries do not turn the
/// character page into a second feed.
class CharacterDiaryReader extends StatefulWidget {
  const CharacterDiaryReader({super.key, required this.characterId});

  final String characterId;

  @override
  State<CharacterDiaryReader> createState() => _CharacterDiaryReaderState();
}

class _CharacterDiaryReaderState extends State<CharacterDiaryReader> {
  List<CharacterDiaryEntry>? _entries;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    CharacterDiaryService.revision.addListener(_reload);
    _load();
  }

  @override
  void didUpdateWidget(covariant CharacterDiaryReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId) _load();
  }

  @override
  void dispose() {
    CharacterDiaryService.revision.removeListener(_reload);
    super.dispose();
  }

  void _reload() => _load();

  Future<void> _load() async {
    final characterId = widget.characterId;
    final entries = await CharacterDiaryService.listEntries(
      characterId,
      limit: 60,
    );
    if (!mounted || characterId != widget.characterId) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _formatDate(String diaryDate) {
    final parts = diaryDate.split('-');
    if (parts.length != 3) return diaryDate;
    final month = int.tryParse(parts[1]) ?? 0;
    final day = int.tryParse(parts[2]) ?? 0;
    if (L.locale == 'zh_TW' || L.locale == 'zh_CN') {
      return '$month 月 $day 日';
    }
    const months = <String>[
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (month >= 1 && month <= 12) return '${months[month]} $day';
    return diaryDate;
  }

  String _titleFor(CharacterDiaryEntry entry) => entry.title.trim().isEmpty
      ? L.pick(en: 'Untitled diary', zhTW: '未命名日記', zhCN: '未命名日记')
      : entry.title.trim();

  void _openArchive() {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CharacterDiaryArchivePage(
          entries: entries,
          formatDate: _formatDate,
          titleFor: _titleFor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox(height: 72);
    final entries = _entries ?? const <CharacterDiaryEntry>[];
    final latest = entries.isEmpty ? null : entries.first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                L.pick(en: 'Diary', zhTW: '日記', zhCN: '日记'),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.accent.withValues(alpha: .7),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: .6,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        YanciTheme.accent.withValues(alpha: .18),
                        YanciTheme.accent.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('character-diary-open-archive'),
                tooltip: L.pick(
                  en: 'View all diaries',
                  zhTW: '查看全部日記',
                  zhCN: '查看全部日记',
                ),
                onPressed: entries.isEmpty ? null : _openArchive,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: YanciTheme.accent.withValues(
                    alpha: entries.isEmpty ? .22 : .55,
                  ),
                ),
              ),
            ],
          ),
          if (latest == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
              child: Text(
                L.pick(
                  en: 'No diary entries yet',
                  zhTW: '還沒有日記',
                  zhCN: '还没有日记',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: .4),
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            Semantics(
              button: true,
              label: '${_titleFor(latest)}，${_formatDate(latest.diaryDate)}',
              child: InkWell(
                key: const ValueKey('character-diary-latest'),
                onTap: () => _showDiaryEntry(context, latest),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 2,
                        height: 34,
                        decoration: BoxDecoration(
                          color: YanciTheme.accent.withValues(alpha: .42),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _titleFor(latest),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: YanciTheme.bodyText.copyWith(
                            color: YanciTheme.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
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
    );
  }
}

class _CharacterDiaryArchivePage extends StatelessWidget {
  const _CharacterDiaryArchivePage({
    required this.entries,
    required this.formatDate,
    required this.titleFor,
  });

  final List<CharacterDiaryEntry> entries;
  final String Function(String) formatDate;
  final String Function(CharacterDiaryEntry) titleFor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 20, 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: YanciTheme.textPrimary,
                      iconSize: 19,
                    ),
                    Text(
                      L.pick(en: 'Diary', zhTW: '日記', zhCN: '日记'),
                      style: YanciTheme.headingMedium,
                    ),
                    const Spacer(),
                    Text(
                      '${entries.length}',
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: .5),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final isLast = index == entries.length - 1;
                    return InkWell(
                      onTap: () => _showDiaryEntry(context, entry),
                      borderRadius: BorderRadius.circular(10),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 18,
                              child: Column(
                                children: [
                                  const SizedBox(height: 5),
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: YanciTheme.accent.withValues(
                                        alpha: .72,
                                      ),
                                    ),
                                  ),
                                  if (!isLast)
                                    Expanded(
                                      child: Container(
                                        width: 1,
                                        margin: const EdgeInsets.only(top: 5),
                                        color: YanciTheme.accent.withValues(
                                          alpha: .18,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 22),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      formatDate(entry.diaryDate),
                                      style: YanciTheme.bodySmall.copyWith(
                                        color: YanciTheme.accent.withValues(
                                          alpha: .62,
                                        ),
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      titleFor(entry),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: YanciTheme.bodyText.copyWith(
                                        color: YanciTheme.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showDiaryEntry(BuildContext context, CharacterDiaryEntry entry) {
  HapticFeedback.mediumImpact();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => DraggableScrollableSheet(
      // Without this, the draggable sheet expands to the whole modal route.
      // The visually blank area above the card then intercepts taps instead
      // of letting the modal barrier dismiss back to the diary list.
      expand: false,
      initialChildSize: .75,
      minChildSize: .4,
      maxChildSize: .92,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                entry.title.trim().isEmpty
                    ? L.pick(en: 'Untitled diary', zhTW: '未命名日記', zhCN: '未命名日记')
                    : entry.title.trim(),
                style: YanciTheme.headingMedium.copyWith(height: 1.35),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 48,
                  height: .6,
                  color: YanciTheme.accent.withValues(alpha: .35),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                entry.body,
                style: YanciTheme.bodyText.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: .92),
                  fontSize: 15,
                  height: 1.85,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
