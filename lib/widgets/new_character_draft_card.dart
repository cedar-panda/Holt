import 'dart:async';

import 'package:flutter/material.dart';

import '../models/guide_persona_draft.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class NewCharacterDraftCard extends StatefulWidget {
  const NewCharacterDraftCard({
    super.key,
    required this.state,
    required this.showAvatar,
    required this.onDraftChanged,
    required this.onAdd,
    required this.onOpenCharacter,
  });

  final PersonaCardState state;
  final bool showAvatar;
  final Future<void> Function(GuidePersonaDraft draft) onDraftChanged;
  final Future<bool> Function(GuidePersonaDraft draft) onAdd;
  final VoidCallback onOpenCharacter;

  @override
  State<NewCharacterDraftCard> createState() => _NewCharacterDraftCardState();
}

class _NewCharacterDraftCardState extends State<NewCharacterDraftCard> {
  static const List<String> _fieldKeys = <String>[
    'name',
    'gender',
    'relationship',
    'description',
    'race',
    'skill',
    'age',
    'height',
  ];

  late Map<String, TextEditingController> _controllers;
  Timer? _saveTimer;
  bool _expanded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controllers = _makeControllers(widget.state.draft);
  }

  @override
  void didUpdateWidget(covariant NewCharacterDraftCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.draft.encode() != widget.state.draft.encode()) {
      // Keep active edits/cursor; synchronize only when an external update arrived.
      for (final key in _fieldKeys) {
        final next = _fieldValue(widget.state.draft, key);
        final controller = _controllers[key]!;
        if (controller.text != next) {
          controller.text = next;
        }
      }
    }
  }

  Map<String, TextEditingController> _makeControllers(
    GuidePersonaDraft draft,
  ) => <String, TextEditingController>{
    for (final key in _fieldKeys)
      key: TextEditingController(text: _fieldValue(draft, key)),
  };

  String _fieldValue(GuidePersonaDraft draft, String key) => switch (key) {
    'name' => draft.name,
    'gender' => draft.gender,
    'relationship' => draft.relationship,
    'description' => draft.description,
    'race' => draft.race,
    'skill' => draft.skill,
    'age' => draft.age,
    _ => draft.height,
  };

  GuidePersonaDraft _currentDraft() => GuidePersonaDraft(
    name: _controllers['name']!.text.trim(),
    gender: _controllers['gender']!.text.trim(),
    relationship: _controllers['relationship']!.text.trim(),
    description: _controllers['description']!.text.trim(),
    race: _controllers['race']!.text.trim(),
    skill: _controllers['skill']!.text.trim(),
    age: _controllers['age']!.text.trim(),
    height: _controllers['height']!.text.trim(),
  );

  void _onFieldChanged(String _) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(widget.onDraftChanged(_currentDraft()));
    });
    setState(() {});
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.state.draft;
    final isAdded = widget.state.isAdded;
    final surface = Color.alphaBlend(
      YanciTheme.accent.withValues(alpha: YanciTheme.isDark ? 0.11 : 0.07),
      YanciTheme.surfacePanel,
    );
    final identity = <String>[
      if (draft.gender.trim().isNotEmpty) draft.gender.trim(),
      if (draft.relationship.trim().isNotEmpty) draft.relationship.trim(),
    ].join(' · ');
    final secondaryLine = identity.isNotEmpty
        ? identity
        : (draft.description.trim().isNotEmpty
              ? draft.description.trim()
              : L.pick(
                  en: 'Identity / relationship not set',
                  zhTW: '身分／關係尚未填寫',
                  zhCN: '身份／关系尚未填写',
                ));

    return Padding(
      padding: EdgeInsets.only(
        left: widget.showAvatar ? 60 : YanciTheme.spacingMd,
        right: MediaQuery.sizeOf(context).width * 0.12,
        top: YanciTheme.spacingXs,
        bottom: YanciTheme.spacingXs,
      ),
      child: Semantics(
        container: true,
        label: L.pick(
          en: 'New character ${draft.name}, ${isAdded ? 'added' : 'awaiting confirmation'}',
          zhTW: '新人設 ${draft.name}，${isAdded ? '已加入角色' : '待確認'}',
          zhCN: '新角色 ${draft.name}，${isAdded ? '已加入角色' : '待确认'}',
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: YanciTheme.accent.withValues(
                alpha: YanciTheme.isDark ? 0.26 : 0.19,
              ),
              width: 0.8,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              InkWell(
                borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                onTap: isAdded
                    ? widget.onOpenCharacter
                    : () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 10, 11),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 19,
                        color: YanciTheme.accent,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${L.pick(en: 'New character', zhTW: '新人設', zhCN: '新角色')} · ${draft.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodyText.copyWith(
                                fontWeight: FontWeight.w700,
                                color: YanciTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              secondaryLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusLabel(isAdded: isAdded),
                      const SizedBox(width: 3),
                      Icon(
                        isAdded
                            ? Icons.open_in_new_rounded
                            : (_expanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded),
                        color: YanciTheme.accent,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded && !isAdded) ...<Widget>[
                Divider(
                  height: 1,
                  indent: 13,
                  endIndent: 13,
                  color: YanciTheme.accent.withValues(alpha: 0.18),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final key in _fieldKeys) ...<Widget>[
                        TextField(
                          controller: _controllers[key],
                          onChanged: _onFieldChanged,
                          maxLines: key == 'description' ? 4 : 1,
                          minLines: 1,
                          textInputAction: key == 'description'
                              ? TextInputAction.newline
                              : TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: _labelFor(key),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 11,
                            ),
                          ),
                        ),
                        const SizedBox(height: 9),
                      ],
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => setState(() => _expanded = false),
                              child: Text(
                                L.pick(
                                  en: 'Keep chatting',
                                  zhTW: '繼續聊聊',
                                  zhCN: '继续聊聊',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: _saving ? null : _addCharacter,
                              child: _saving
                                  ? const SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      L.pick(
                                        en: 'Add character',
                                        zhTW: '加入角色',
                                        zhCN: '加入角色',
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _labelFor(String key) => switch (key) {
    'name' => L.pick(en: 'Name', zhTW: '名字', zhCN: '名字'),
    'gender' => L.pick(en: 'Gender', zhTW: '性別', zhCN: '性别'),
    'relationship' => L.pick(
      en: 'Relationship to user',
      zhTW: '與 user 的關係',
      zhCN: '与 user 的关系',
    ),
    'description' => L.pick(en: 'Description', zhTW: '簡介', zhCN: '简介'),
    'race' => L.pick(en: 'Species', zhTW: '種族', zhCN: '种族'),
    'skill' => L.pick(en: 'Skills', zhTW: '特長', zhCN: '特长'),
    'age' => L.pick(en: 'Age', zhTW: '年齡', zhCN: '年龄'),
    _ => L.pick(en: 'Height', zhTW: '身高', zhCN: '身高'),
  };

  Future<void> _addCharacter() async {
    final draft = _currentDraft();
    if (draft.name.isEmpty) return;
    setState(() => _saving = true);
    _saveTimer?.cancel();
    try {
      final added = await widget.onAdd(draft);
      if (mounted && added) setState(() => _expanded = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.isAdded});

  final bool isAdded;

  @override
  Widget build(BuildContext context) {
    return Text(
      isAdded
          ? L.pick(en: 'Added', zhTW: '已加入角色', zhCN: '已加入角色')
          : L.pick(en: 'Review', zhTW: '待確認', zhCN: '待确认'),
      maxLines: 1,
      style: YanciTheme.bodySmall.copyWith(
        fontSize: 10,
        color: isAdded ? YanciTheme.accent : YanciTheme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
