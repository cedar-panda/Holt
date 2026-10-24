import 'package:flutter/material.dart';

import '../services/anniversary_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

const kAnniversaryNumberFont = 'Cormorant Garamond';

String anniversaryPlacementLabel(AnniversaryPlacement placement) {
  return switch (placement) {
    AnniversaryPlacement.hidden => L.pick(en: 'Hidden', zhTW: '隱藏', zhCN: '隐藏'),
    AnniversaryPlacement.avatarLine => L.pick(
      en: 'Avatar link',
      zhTW: '頭像連線',
      zhCN: '头像连线',
    ),
    AnniversaryPlacement.belowAvatars => L.pick(
      en: 'Below avatars',
      zhTW: '頭像下方',
      zhCN: '头像下方',
    ),
    AnniversaryPlacement.aboveHeartbeat => L.pick(
      en: 'Above heartbeat',
      zhTW: '心跳上方',
      zhCN: '心跳上方',
    ),
  };
}

String anniversaryDayText(AnniversaryEntry entry, {DateTime? now}) {
  final day = AnniversaryService.naturalDayNumber(entry.startDate, now: now);
  if (day > 0) {
    return L.pick(en: 'Day $day', zhTW: '第 $day 天', zhCN: '第 $day 天');
  }
  final remaining = 1 - day;
  return L.pick(
    en: '$remaining days to go',
    zhTW: '還有 $remaining 天',
    zhCN: '还有 $remaining 天',
  );
}

/// Displays one or more anniversaries with the same title + day-number visual
/// language used below the profile avatars.
class AnniversaryDayCounterGroup extends StatelessWidget {
  const AnniversaryDayCounterGroup({
    super.key,
    required this.entries,
    this.compact = false,
    this.splitAroundLine = false,
  });

  final List<AnniversaryEntry> entries;
  final bool compact;
  final bool splitAroundLine;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    if (compact) {
      return Tooltip(
        message: entries.map((entry) => entry.title).join(' · '),
        child: AnniversaryDayCounter(
          entry: entries.first,
          compact: true,
          splitAroundLine: splitAroundLine,
          additionalCount: entries.length - 1,
        ),
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 5,
      children: entries
          .map((entry) => AnniversaryDayCounter(entry: entry))
          .toList(growable: false),
    );
  }
}

/// A prominent, standalone day counter for anniversary display.
class AnniversaryDayCounter extends StatelessWidget {
  const AnniversaryDayCounter({
    super.key,
    required this.entry,
    this.compact = false,
    this.splitAroundLine = false,
    this.additionalCount = 0,
  });

  final AnniversaryEntry entry;
  final bool compact;
  final bool splitAroundLine;
  final int additionalCount;

  @override
  Widget build(BuildContext context) {
    final day = AnniversaryService.naturalDayNumber(entry.startDate);
    final isCountdown = day <= 0;
    final displayNum = isCountdown ? (1 - day) : day;
    final tint = const Color(0xFFE0525F);

    final title = Text(
      entry.title,
      style: TextStyle(
        fontSize: compact ? (splitAroundLine ? 10.5 : 8.5) : 11,
        fontWeight: FontWeight.w500,
        color: tint.withValues(alpha: .72),
        fontFamily: YanciTheme.fontFamily,
        letterSpacing: compact ? (splitAroundLine ? .8 : .6) : 1.2,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final counter = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          isCountdown
              ? L.pick(en: '', zhTW: '還有 ', zhCN: '还有 ')
              : L.pick(en: 'Day ', zhTW: '第 ', zhCN: '第 '),
          style: TextStyle(
            fontSize: compact ? (splitAroundLine ? 10.5 : 9) : 12,
            fontWeight: FontWeight.w500,
            color: tint.withValues(alpha: .68),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        Text(
          '$displayNum',
          style: TextStyle(
            fontSize: compact ? (splitAroundLine ? 24 : 20) : 28,
            fontWeight: FontWeight.w400,
            color: tint.withValues(alpha: .92),
            fontFamily: kAnniversaryNumberFont,
            height: 1.0,
          ),
        ),
        Text(
          isCountdown
              ? L.pick(en: ' to go', zhTW: ' 天', zhCN: ' 天')
              : L.pick(en: '', zhTW: ' 天', zhCN: ' 天'),
          style: TextStyle(
            fontSize: compact ? (splitAroundLine ? 10.5 : 9) : 12,
            fontWeight: FontWeight.w500,
            color: tint.withValues(alpha: .68),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        if (additionalCount > 0)
          Text(
            ' +$additionalCount',
            style: TextStyle(
              fontSize: compact ? (splitAroundLine ? 9.5 : 8.5) : 10,
              fontWeight: FontWeight.w500,
              color: tint.withValues(alpha: .62),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
      ],
    );

    if (splitAroundLine) {
      return SizedBox(
        height: 76,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Transform.translate(offset: const Offset(0, -12), child: title),
            counter,
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        SizedBox(height: compact ? 0 : 2),
        counter,
      ],
    );
  }
}

Future<bool> showAnniversaryPanel(
  BuildContext context, {
  required String userPersonaId,
  required String characterId,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => _AnniversaryPanel(
          userPersonaId: userPersonaId,
          characterId: characterId,
        ),
      ) ??
      false;
}

class _AnniversaryPanel extends StatefulWidget {
  const _AnniversaryPanel({
    required this.userPersonaId,
    required this.characterId,
  });

  final String userPersonaId;
  final String characterId;

  @override
  State<_AnniversaryPanel> createState() => _AnniversaryPanelState();
}

class _AnniversaryPanelState extends State<_AnniversaryPanel> {
  List<AnniversaryEntry> _entries = const <AnniversaryEntry>[];
  AnniversaryDisplaySettings _settings = const AnniversaryDisplaySettings();
  String? _selectedId;
  bool _loading = true;
  bool _changed = false;

  AnniversaryEntry? get _selected {
    for (final entry in _entries) {
      if (entry.id == _selectedId) return entry;
    }
    return _entries.isEmpty ? null : _entries.first;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload({String? selectId}) async {
    final results = await Future.wait<Object>([
      AnniversaryService.list(
        userPersonaId: widget.userPersonaId,
        characterId: widget.characterId,
      ),
      AnniversaryService.settings(
        userPersonaId: widget.userPersonaId,
        characterId: widget.characterId,
      ),
    ]);
    if (!mounted) return;
    final entries = results[0] as List<AnniversaryEntry>;
    setState(() {
      _entries = entries;
      _settings = results[1] as AnniversaryDisplaySettings;
      _selectedId =
          selectId ??
          (_selectedId != null &&
                  entries.any((entry) => entry.id == _selectedId)
              ? _selectedId
              : (entries.isEmpty ? null : entries.first.id));
      _loading = false;
    });
  }

  Future<void> _add() async {
    final initialDate = await AnniversaryService.defaultStartDate(
      widget.characterId,
    );
    if (!mounted) return;
    final draft = await showDialog<_AnniversaryDraft>(
      context: context,
      builder: (_) => _AnniversaryEditorDialog(initialDate: initialDate),
    );
    if (draft == null) return;
    final entry = await AnniversaryService.create(
      userPersonaId: widget.userPersonaId,
      characterId: widget.characterId,
      title: draft.title,
      startDate: draft.startDate,
    );
    _changed = true;
    await _reload(selectId: entry.id);
  }

  Future<void> _edit(AnniversaryEntry entry) async {
    final draft = await showDialog<_AnniversaryDraft>(
      context: context,
      builder: (_) => _AnniversaryEditorDialog(
        initialTitle: entry.title,
        initialDate: entry.startDate,
      ),
    );
    if (draft == null) return;
    await AnniversaryService.update(
      entry.copyWith(title: draft.title, startDate: draft.startDate),
    );
    _changed = true;
    await _reload(selectId: entry.id);
  }

  Future<void> _delete(AnniversaryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Text(
          L.pick(
            en: 'Delete "${entry.title}"?',
            zhTW: '刪除「${entry.title}」？',
            zhCN: '删除「${entry.title}」？',
          ),
          style: YanciTheme.bodyText,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除'),
              style: const TextStyle(color: Color(0xFFE0525F)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AnniversaryService.delete(entry.id);
    _changed = true;
    await _reload();
  }

  Future<void> _setPlacement(AnniversaryPlacement placement) async {
    final selected = _selected;
    if (selected == null) return;
    await AnniversaryService.update(selected.copyWith(placement: placement));
    _changed = true;
    await _reload(selectId: selected.id);
  }

  Future<void> _setHideUserName(bool value) async {
    setState(() {
      _settings = AnniversaryDisplaySettings(hideUserName: value);
    });
    await AnniversaryService.setHideUserName(
      userPersonaId: widget.userPersonaId,
      characterId: widget.characterId,
      value: value,
    );
    _changed = true;
  }

  void _showPlacementPicker() {
    final selected = _selected;
    if (selected == null) return;
    showModalBottomSheet<AnniversaryPlacement>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlacementPreviewSheet(current: selected.placement),
    ).then((placement) {
      if (placement != null) _setPlacement(placement);
    });
  }

  void _close() => Navigator.pop(context, _changed);

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 610),
          child: Material(
            color: YanciTheme.surfacePanel.withValues(alpha: .96),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
              side: BorderSide(color: YanciTheme.accent.withValues(alpha: .14)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 44,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          L.pick(en: 'Anniversaries', zhTW: '紀念日', zhCN: '纪念日'),
                          style: YanciTheme.headingMedium,
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: L.pick(
                              en: 'Close',
                              zhTW: '關閉',
                              zhCN: '关闭',
                            ),
                            onPressed: _close,
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            key: const ValueKey('anniversary-placement-menu'),
                            tooltip: L.pick(
                              en: 'Display location',
                              zhTW: '顯示位置',
                              zhCN: '显示位置',
                            ),
                            onPressed: selected == null
                                ? null
                                : _showPlacementPicker,
                            icon: Icon(
                              Icons.layers_outlined,
                              size: 20,
                              color: selected == null
                                  ? YanciTheme.textSecondary.withValues(
                                      alpha: .28,
                                    )
                                  : YanciTheme.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                      L.pick(
                        en: 'Hide user name',
                        zhTW: '隱藏 User 名字',
                        zhCN: '隐藏 User 名字',
                      ),
                      style: YanciTheme.bodyText.copyWith(fontSize: 13),
                    ),
                    value: _settings.hideUserName,
                    onChanged: _setHideUserName,
                    activeTrackColor: YanciTheme.accent.withValues(alpha: .46),
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _entries.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 34),
                              child: Text(
                                L.pick(
                                  en: 'No anniversaries yet',
                                  zhTW: '還沒有紀念日',
                                  zhCN: '还没有纪念日',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _entries.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 7),
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              final active = entry.id == selected?.id;
                              return InkWell(
                                onTap: () =>
                                    setState(() => _selectedId = entry.id),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    4,
                                    8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? YanciTheme.accent.withValues(
                                            alpha: .09,
                                          )
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: active
                                          ? YanciTheme.accent.withValues(
                                              alpha: .18,
                                            )
                                          : YanciTheme.glassBorder,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              entry.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: YanciTheme.bodyText
                                                  .copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              '${AnniversaryService.storageDate(entry.startDate)} · '
                                              '${anniversaryDayText(entry)} · '
                                              '${anniversaryPlacementLabel(entry.placement)}',
                                              style: YanciTheme.bodySmall
                                                  .copyWith(
                                                    fontSize: 10,
                                                    color: YanciTheme
                                                        .textSecondary,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: L.pick(
                                          en: 'Edit',
                                          zhTW: '編輯',
                                          zhCN: '编辑',
                                        ),
                                        onPressed: () => _edit(entry),
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: L.pick(
                                          en: 'Delete',
                                          zhTW: '刪除',
                                          zhCN: '删除',
                                        ),
                                        onPressed: () => _delete(entry),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                          color: Color(0xFFE0525F),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  IconButton(
                    key: const ValueKey('add-anniversary'),
                    tooltip: L.pick(
                      en: 'Add anniversary',
                      zhTW: '新增紀念日',
                      zhCN: '新增纪念日',
                    ),
                    onPressed: _add,
                    icon: Icon(
                      Icons.add_rounded,
                      color: YanciTheme.accent,
                      size: 24,
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
}

class _AnniversaryDraft {
  const _AnniversaryDraft({required this.title, required this.startDate});

  final String title;
  final DateTime startDate;
}

class _AnniversaryEditorDialog extends StatefulWidget {
  const _AnniversaryEditorDialog({
    required this.initialDate,
    this.initialTitle = '',
  });

  final String initialTitle;
  final DateTime initialDate;

  @override
  State<_AnniversaryEditorDialog> createState() =>
      _AnniversaryEditorDialogState();
}

class _AnniversaryEditorDialogState extends State<_AnniversaryEditorDialog> {
  late final TextEditingController _titleController;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _date = AnniversaryService.dateOnly(widget.initialDate);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime(DateTime.now().year + 100, 12, 31),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Anniversary name is required.',
              zhTW: '請填寫紀念日名稱。',
              zhCN: '请填写纪念日名称。',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Navigator.pop(context, _AnniversaryDraft(title: title, startDate: _date));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YanciTheme.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        L.pick(
          en: widget.initialTitle.isEmpty
              ? 'Add anniversary'
              : 'Edit anniversary',
          zhTW: widget.initialTitle.isEmpty ? '新增紀念日' : '編輯紀念日',
          zhCN: widget.initialTitle.isEmpty ? '新增纪念日' : '编辑纪念日',
        ),
        style: YanciTheme.headingMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('anniversary-title-field'),
            controller: _titleController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: L.pick(
                en: 'What is this day?',
                zhTW: '這是什麼紀念日',
                zhCN: '这是什么纪念日',
              ),
            ),
          ),
          const SizedBox(height: 14),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.calendar_today_outlined,
              color: YanciTheme.accent,
            ),
            title: Text(AnniversaryService.storageDate(_date)),
            onTap: _pickDate,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L.get('cancel')),
        ),
        TextButton(
          onPressed: _save,
          child: Text(L.pick(en: 'Done', zhTW: '完成', zhCN: '完成')),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Placement preview sheet — visual picker for anniversary display position
// ═══════════════════════════════════════════════════════════════════════════

/// Bottom-sheet with illustrated 2×2 preview tiles for each
/// [AnniversaryPlacement]. Each tile shows a schematic illustration of
/// where the badge appears on the profile page.
///
/// Now a [StatefulWidget] to drive per-tile scale feedback and a subtle
/// pulse on the selected illustration's accent element.
class _PlacementPreviewSheet extends StatefulWidget {
  const _PlacementPreviewSheet({required this.current});

  final AnniversaryPlacement current;

  @override
  State<_PlacementPreviewSheet> createState() => _PlacementPreviewSheetState();
}

class _PlacementPreviewSheetState extends State<_PlacementPreviewSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  /// Track which tile is being pressed for scale feedback.
  AnniversaryPlacement? _pressed;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: YanciTheme.accent.withValues(alpha: .10)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: YanciTheme.isDark ? .40 : .12,
            ),
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
          BoxShadow(
            color: YanciTheme.accent.withValues(alpha: .06),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──
          Container(
            width: 40,
            height: 4.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  YanciTheme.textSecondary.withValues(alpha: .14),
                  YanciTheme.textSecondary.withValues(alpha: .28),
                  YanciTheme.textSecondary.withValues(alpha: .14),
                ],
              ),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            L.pick(en: 'Display location', zhTW: '顯示位置', zhCN: '显示位置'),
            style: YanciTheme.headingMedium,
          ),
          const SizedBox(height: 20),
          // ── 2×2 grid ──
          Row(
            children: [
              Expanded(child: _tile(context, AnniversaryPlacement.hidden)),
              const SizedBox(width: 12),
              Expanded(child: _tile(context, AnniversaryPlacement.avatarLine)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _tile(context, AnniversaryPlacement.belowAvatars),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _tile(context, AnniversaryPlacement.aboveHeartbeat),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, AnniversaryPlacement placement) {
    final active = placement == widget.current;
    final pressed = _pressed == placement;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = placement),
      onTapUp: (_) {
        setState(() => _pressed = null);
        Navigator.pop(context, placement);
      },
      onTapCancel: () => setState(() => _pressed = null),
      child: AnimatedScale(
        scale: pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
          decoration: BoxDecoration(
            color: active
                ? YanciTheme.accent.withValues(alpha: .08)
                : YanciTheme.surfacePanel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: active
                  ? YanciTheme.accent.withValues(alpha: .32)
                  : YanciTheme.glassBorder,
              width: active ? 1.4 : 0.7,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: YanciTheme.accent.withValues(alpha: .10),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 72,
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, child) {
                    return _placementPreview(
                      placement,
                      active ? _pulseAnim.value : 0.0,
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              // ── Label row ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (active)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 13,
                        color: YanciTheme.accent.withValues(alpha: .72),
                      ),
                    ),
                  Flexible(
                    child: Text(
                      anniversaryPlacementLabel(placement),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 11.5,
                        color: active
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        letterSpacing: active ? 0.1 : 0,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

  // ── Placement mini-preview helpers ──────────────────────────────────────

  static const _kTint = Color(0xFFE0525F);

  Widget _placementPreview(AnniversaryPlacement p, double pulse) {
    return switch (p) {
      AnniversaryPlacement.hidden => _previewHidden(pulse),
      AnniversaryPlacement.avatarLine => _previewAvatarLine(pulse),
      AnniversaryPlacement.belowAvatars => _previewBelowAvatars(pulse),
      AnniversaryPlacement.aboveHeartbeat => _previewAboveHeartbeat(pulse),
    };
  }

  Widget _miniAvatar({double size = 20}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.35),
          radius: 1.2,
          colors: [
            YanciTheme.textSecondary.withValues(alpha: .28),
            YanciTheme.textSecondary.withValues(alpha: .10),
          ],
        ),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: .20),
          width: 1.0,
        ),
      ),
    );
  }

  Widget _miniDayBadge(double pulse, {double numSize = 14}) {
    final alpha = (0.80 + (pulse - 0.5) * 0.16).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          L.pick(en: 'Day ', zhTW: '第 ', zhCN: '第 '),
          style: TextStyle(
            fontSize: numSize * 0.55,
            fontWeight: FontWeight.w500,
            color: _kTint.withValues(alpha: alpha * 0.72),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        Text(
          '1',
          style: TextStyle(
            fontSize: numSize,
            fontWeight: FontWeight.w400,
            color: _kTint.withValues(alpha: alpha),
            fontFamily: kAnniversaryNumberFont,
            height: 1.0,
          ),
        ),
        Text(
          L.pick(en: '', zhTW: ' 天', zhCN: ' 天'),
          style: TextStyle(
            fontSize: numSize * 0.55,
            fontWeight: FontWeight.w500,
            color: _kTint.withValues(alpha: alpha * 0.72),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
      ],
    );
  }

  Widget _previewHidden(double pulse) {
    return Opacity(
      opacity: 0.28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _miniAvatar(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: SizedBox(
                  width: 44,
                  height: 20,
                  child: CustomPaint(
                    painter: _MiniRedThreadPainter(
                      tint: _kTint,
                      isDark: YanciTheme.isDark,
                    ),
                  ),
                ),
              ),
              _miniAvatar(),
            ],
          ),
          Icon(
            Icons.visibility_off_rounded,
            size: 24,
            color: YanciTheme.textSecondary.withValues(alpha: .60),
          ),
        ],
      ),
    );
  }

  Widget _previewAvatarLine(double pulse) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _miniAvatar(),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  height: 28,
                  child: CustomPaint(
                    size: const Size(double.infinity, 28),
                    painter: _MiniRedThreadPainter(
                      tint: _kTint,
                      isDark: YanciTheme.isDark,
                      pulseValue: pulse,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.surfacePanel.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _miniDayBadge(pulse, numSize: 13),
                ),
              ],
            ),
          ),
        ),
        _miniAvatar(),
      ],
    );
  }

  Widget _previewBelowAvatars(double pulse) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _miniAvatar(size: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: SizedBox(
                width: 36,
                height: 16,
                child: CustomPaint(
                  painter: _MiniRedThreadPainter(
                    tint: _kTint,
                    isDark: YanciTheme.isDark,
                    pulseValue: pulse,
                  ),
                ),
              ),
            ),
            _miniAvatar(size: 18),
          ],
        ),
        const SizedBox(height: 6),
        _miniDayBadge(pulse, numSize: 13),
      ],
    );
  }

  Widget _previewAboveHeartbeat(double pulse) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _miniDayBadge(pulse, numSize: 13),
        const SizedBox(height: 6),
        SizedBox(
          height: 20,
          child: CustomPaint(
            size: const Size(double.infinity, 20),
            painter: _MiniHeartbeatPainter(
              accent: YanciTheme.accent,
              pulseValue: pulse,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mini painters for placement preview tiles
// ═══════════════════════════════════════════════════════════════════════════

/// Draws a simplified red thread of fate for preview tiles.
class _MiniRedThreadPainter extends CustomPainter {
  const _MiniRedThreadPainter({
    required this.tint,
    required this.isDark,
    this.pulseValue = 0.0,
  });

  final Color tint;
  final bool isDark;
  final double pulseValue;

  @override
  void paint(Canvas canvas, Size size) {
    final baseAlpha = isDark ? .72 : .58;
    final alpha = (baseAlpha + (pulseValue - 0.5) * 0.12).clamp(0.0, 1.0);

    final paint = Paint()
      ..color = tint.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;
    final cy = h * 0.55;

    // Simplified fate thread — gentle wave with mini crossing loop.
    final path = Path()
      ..moveTo(0, cy + 1)
      ..cubicTo(w * 0.22, cy + 1, w * 0.32, cy - 4, w * 0.44, cy - 2)
      ..cubicTo(w * 0.50, cy - 1, w * 0.52, cy + 3, w * 0.56, cy - 2)
      ..cubicTo(w * 0.68, cy - 4, w * 0.78, cy + 1, w, cy + 1);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MiniRedThreadPainter old) =>
      old.tint != tint || old.isDark != isDark || old.pulseValue != pulseValue;
}

/// Draws a simplified ECG heartbeat line for the "above heartbeat" preview.
class _MiniHeartbeatPainter extends CustomPainter {
  const _MiniHeartbeatPainter({required this.accent, this.pulseValue = 0.0});

  final Color accent;
  final double pulseValue;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = (0.30 + (pulseValue - 0.5) * 0.12).clamp(0.0, 1.0);
    final cy = size.height / 2;
    final w = size.width;
    final cx = w / 2;

    final paint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(w * 0.10, cy)
      ..lineTo(cx - 14, cy)
      ..lineTo(cx - 8, cy - 7)
      ..lineTo(cx - 3, cy + 8)
      ..lineTo(cx + 3, cy - 10)
      ..lineTo(cx + 8, cy + 5)
      ..lineTo(cx + 13, cy)
      ..lineTo(w * 0.90, cy);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MiniHeartbeatPainter old) =>
      old.accent != accent || old.pulseValue != pulseValue;
}
