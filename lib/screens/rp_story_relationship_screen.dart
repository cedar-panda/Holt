import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/locale_strings.dart';
import '../services/rp_story_service.dart';
import '../services/rp_story_state_service.dart';
import '../theme/app_theme.dart';
import '../widgets/context_mode_pill.dart';
import '../widgets/gradient_background.dart';

class RpStoryRelationshipScreen extends StatefulWidget {
  const RpStoryRelationshipScreen({
    super.key,
    required this.characterId,
    this.continuityId = 'main',
  });

  final String characterId;
  final String continuityId;

  @override
  State<RpStoryRelationshipScreen> createState() =>
      _RpStoryRelationshipScreenState();
}

class _RpStoryRelationshipScreenState extends State<RpStoryRelationshipScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _characters = const [];
  List<Map<String, dynamic>> _relationships = const [];
  List<Map<String, dynamic>> _states = const [];
  bool _loading = true;
  bool _showStates = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      RpStoryService.listCharacters(
        widget.characterId,
        continuityId: widget.continuityId,
        query: _searchController.text,
      ),
      RpStoryService.listRelationships(
        widget.characterId,
        continuityId: widget.continuityId,
      ),
      RpStoryStateService.listStates(
        widget.characterId,
        continuityId: widget.continuityId,
        includeNonMain: true,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _characters = results[0];
      _relationships = results[1];
      _states = results[2];
      _loading = false;
    });
  }

  Future<void> _toggleImportant(Map<String, dynamic> row) async {
    final important = row['is_important'] != 1;
    final count = await RpStoryService.setImportant(
      row['id'].toString(),
      important,
    );
    if (!mounted) return;
    showThemedPillNotice(
      context,
      important
          ? L.pick(
              en: 'Marked important. Recall priority is higher and may use more tokens; the character will only load when relevant.',
              zhTW:
                  '已標記為重要角色。系統會提高其資料的召回優先級，可能增加 Token 消耗；角色僅在與當前劇情相關時載入，不會因此自動登場。',
              zhCN:
                  '已标记为重要角色。系统会提高其资料的召回优先级，可能增加 Token 消耗；角色仅在与当前剧情相关时载入，不会因此自动登场。',
            )
          : L.pick(
              en: 'Important mark removed',
              zhTW: '已取消重要角色標記',
              zhCN: '已取消重要角色标记',
            ),
    );
    if (important && count > 8 && mounted) {
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Too many important characters will increase token usage.',
          zhTW: '重要角色過多，這會增加 Token 消耗。',
          zhCN: '重要角色过多，这会增加 Token 消耗。',
        ),
      );
    }
    await _load();
  }

  Future<void> _editCharacter(Map<String, dynamic> row) async {
    final identity = TextEditingController(text: '${row['identity'] ?? ''}');
    final relation = TextEditingController(
      text: '${row['relation_to_leads'] ?? ''}',
    );
    final personality = TextEditingController(
      text: '${row['personality'] ?? ''}',
    );
    final appearance = TextEditingController(
      text: '${row['appearance'] ?? ''}',
    );
    final faction = TextEditingController(text: '${row['faction'] ?? ''}');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: YanciTheme.surfacePanel,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${row['name']}', style: YanciTheme.headingMedium),
              const SizedBox(height: 16),
              _field(identity, L.pick(en: 'Identity', zhTW: '身份', zhCN: '身份')),
              _field(
                relation,
                L.pick(en: 'Relation to leads', zhTW: '與主角團關係', zhCN: '与主角团关系'),
              ),
              _field(
                personality,
                L.pick(en: 'Personality', zhTW: '性格', zhCN: '性格'),
              ),
              _field(
                appearance,
                L.pick(en: 'Appearance', zhTW: '外貌', zhCN: '外貌'),
              ),
              _field(faction, L.pick(en: 'Faction', zhTW: '陣營', zhCN: '阵营')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      await RpStoryService.updateCharacter(
        row['id'].toString(),
        identity: identity.text,
        relationToLeads: relation.text,
        personality: personality.text,
        appearance: appearance.text,
        faction: faction.text,
      );
      await _load();
    }
    identity.dispose();
    relation.dispose();
    personality.dispose();
    appearance.dispose();
    faction.dispose();
  }

  Future<void> _editRelationship(Map<String, dynamic> row) async {
    final relation = TextEditingController(
      text: '${row['current_relation'] ?? ''}',
    );
    final origin = TextEditingController(text: '${row['origin'] ?? ''}');
    final visibility = TextEditingController(
      text: '${row['visibility'] ?? ''}',
    );
    final events = await RpStoryService.relationshipEvents(
      row['id'].toString(),
    );
    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: YanciTheme.surfacePanel,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${row['from_name']} → ${row['to_name']}',
                style: YanciTheme.headingMedium,
              ),
              const SizedBox(height: 16),
              _field(
                relation,
                L.pick(en: 'Current relation', zhTW: '目前關係', zhCN: '目前关系'),
              ),
              _field(
                origin,
                L.pick(en: 'How it formed', zhTW: '形成經過', zhCN: '形成经过'),
              ),
              _field(
                visibility,
                L.pick(en: 'Visibility', zhTW: '公開狀態', zhCN: '公开状态'),
              ),
              if (events.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  L.pick(en: 'History', zhTW: '關係變化', zhCN: '关系变化'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                  ),
                ),
                ...events.map(
                  (event) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${event['story_time'] ?? ''}  ${event['change_text'] ?? ''}',
                      style: YanciTheme.bodySmall,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      await RpStoryService.updateRelationship(
        row['id'].toString(),
        currentRelation: relation.text,
        origin: origin.text,
        visibility: visibility.text,
      );
      await _load();
    }
    relation.dispose();
    origin.dispose();
    visibility.dispose();
  }

  Future<void> _editState(Map<String, dynamic> row) async {
    final value = TextEditingController(text: '${row['value'] ?? ''}');
    final type = row['state_type']?.toString() ?? '';
    final statuses = RpStoryStateService.validStatuses(type);
    var status = row['status']?.toString() ?? '';
    if (!statuses.contains(status)) {
      status = statuses.isEmpty ? '' : statuses.first;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: YanciTheme.surfacePanel,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            20,
            24,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_stateTypeLabel(type), style: YanciTheme.headingMedium),
                const SizedBox(height: 16),
                _field(
                  value,
                  L.pick(en: 'Current state', zhTW: '目前狀態', zhCN: '当前状态'),
                ),
                if (statuses.isNotEmpty && type != 'scene')
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: InputDecoration(
                      labelText: L.pick(en: 'Progress', zhTW: '進度', zhCN: '进度'),
                    ),
                    items: statuses
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item,
                            child: Text(_statusLabel(item)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value != null) setSheetState(() => status = value);
                    },
                  ),
                const SizedBox(height: 10),
                Text(
                  L.pick(
                    en: 'A manual correction stays fixed and will not be overwritten by automatic extraction.',
                    zhTW: '手動修正後會固定保留，不再被自動擷取覆蓋。',
                    zhCN: '手动修正后会固定保留，不再被自动提取覆盖。',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    if (value.text.trim().isNotEmpty) {
                      Navigator.pop(sheetContext, true);
                    }
                  },
                  child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      await RpStoryStateService.updateState(
        row['id'].toString(),
        value: value.text,
        status: type == 'scene' ? '' : status,
      );
      await _load();
    }
    value.dispose();
  }

  Widget _field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      minLines: 1,
      maxLines: 3,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                      L.pick(en: 'Relationships', zhTW: '人物關係', zhCN: '人物关系'),
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
                        selected: !_showStates,
                        label: L.pick(
                          en: 'Characters & relationships',
                          zhTW: '人物與關係',
                          zhCN: '人物与关系',
                        ),
                        onTap: () => setState(() => _showStates = false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _modeButton(
                        selected: _showStates,
                        label: L.pick(
                          en: 'Story states',
                          zhTW: '劇情狀態',
                          zhCN: '剧情状态',
                        ),
                        onTap: () => setState(() => _showStates = true),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => _showStates ? setState(() {}) : _load(),
                  decoration: InputDecoration(
                    hintText: _showStates
                        ? L.pick(
                            en: 'Search story states',
                            zhTW: '搜尋劇情狀態',
                            zhCN: '搜索剧情状态',
                          )
                        : L.pick(
                            en: 'Search names, identities, or factions',
                            zhTW: '搜尋名字、身份或陣營',
                            zhCN: '搜索名字、身份或阵营',
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
                    : _showStates
                    ? _buildStateList()
                    : _buildRelationshipList(),
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
      constraints: const BoxConstraints(minHeight: 36),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected
              ? YanciTheme.accent.withValues(alpha: 0.62)
              : YanciTheme.textSecondary.withValues(alpha: 0.16),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: YanciTheme.bodySmall.copyWith(
          color: selected ? YanciTheme.accent : YanciTheme.textSecondary,
        ),
      ),
    ),
  );

  Widget _buildRelationshipList() {
    if (_characters.isEmpty && _relationships.isEmpty) {
      return _empty(
        L.pick(
          en: 'Characters and relationships will appear after an RP summary records them.',
          zhTW: 'RP 摘要記錄到人物與關係後，會顯示在這裡。',
          zhCN: 'RP 摘要记录到人物与关系后，会显示在这里。',
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 36),
      children: [
        for (final tier in const <String>['active', 'common', 'backstage'])
          ..._characterGroup(tier),
        if (_relationships.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionTitle(
            L.pick(en: 'Relationships', zhTW: '人物關係', zhCN: '人物关系'),
          ),
          ..._relationships.map(_relationshipTile),
        ],
      ],
    );
  }

  Widget _buildStateList() {
    final query = _searchController.text.trim().toLowerCase();
    final names = <String, String>{
      for (final row in _characters)
        if ((row['entity_key']?.toString() ?? '').isNotEmpty)
          row['entity_key'].toString(): row['name']?.toString() ?? '',
    };
    final rows = _states
        .where((row) {
          if (query.isEmpty) return true;
          final subject = names[row['subject_entity_key']] ?? '';
          final object = names[row['object_entity_key']] ?? '';
          final haystack = <Object?>[
            row['state_type'],
            row['state_key'],
            row['value'],
            row['status'],
            row['story_time'],
            subject,
            object,
          ].join(' ').toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);
    if (rows.isEmpty) {
      return _empty(
        query.isEmpty
            ? L.pick(
                en: 'Current scenes, promises, identities, knowledge, injuries, items, and plot states will appear here.',
                zhTW: '目前場景、承諾、身份、知情邊界、傷勢、物品與劇情進度會顯示在這裡。',
                zhCN: '当前场景、承诺、身份、知情边界、伤势、物品与剧情进度会显示在这里。',
              )
            : L.pick(
                en: 'No matching story state',
                zhTW: '沒有符合的劇情狀態',
                zhCN: '没有符合的剧情状态',
              ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 36),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) => _stateTile(rows[index], names),
    );
  }

  Widget _stateTile(Map<String, dynamic> row, Map<String, String> names) {
    final type = row['state_type']?.toString() ?? '';
    final subject = names[row['subject_entity_key']] ?? '';
    final object = names[row['object_entity_key']] ?? '';
    final people = <String>[
      subject,
      object,
    ].where((item) => item.isNotEmpty).join(' → ');
    final layer = row['narrative_layer']?.toString() ?? 'main';
    final status = row['status']?.toString() ?? '';
    final storyTime = row['story_time']?.toString().trim() ?? '';
    return InkWell(
      onTap: () => _editState(row),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _stateTypeLabel(type),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.accent.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (people.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      people,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (layer != 'main')
                  Text(
                    _layerLabel(layer),
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: 10,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            _markdown(
              row['value']?.toString() ?? '',
              style: YanciTheme.bodyText.copyWith(height: 1.4),
            ),
            if (status.isNotEmpty || storyTime.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                <String>[
                  if (status.isNotEmpty) _statusLabel(status),
                  if (storyTime.isNotEmpty) storyTime,
                ].join(' · '),
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 10.5,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.64),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _empty(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary,
          height: 1.45,
        ),
      ),
    ),
  );

  String _stateTypeLabel(String type) => switch (type) {
    'scene' => L.pick(en: 'Scene', zhTW: '當前場景', zhCN: '当前场景'),
    'promise' => L.pick(en: 'Promise', zhTW: '承諾', zhCN: '承诺'),
    'body' => L.pick(en: 'Body', zhTW: '身體狀態', zhCN: '身体状态'),
    'identity' => L.pick(en: 'Identity', zhTW: '身份', zhCN: '身份'),
    'knowledge' => L.pick(en: 'Knowledge', zhTW: '知情邊界', zhCN: '知情边界'),
    'plot' => L.pick(en: 'Plot', zhTW: '劇情進度', zhCN: '剧情进度'),
    'item' => L.pick(en: 'Item', zhTW: '物品', zhCN: '物品'),
    _ => type,
  };

  String _statusLabel(String status) => switch (status) {
    'pending' => L.pick(en: 'Pending', zhTW: '待兌現', zhCN: '待兑现'),
    'fulfilled' => L.pick(en: 'Fulfilled', zhTW: '已兌現', zhCN: '已兑现'),
    'broken' => L.pick(en: 'Broken', zhTW: '已違背', zhCN: '已违背'),
    'cancelled' => L.pick(en: 'Cancelled', zhTW: '已取消', zhCN: '已取消'),
    'permanent' => L.pick(en: 'Permanent', zhTW: '永久', zhCN: '永久'),
    'recovering' => L.pick(en: 'Recovering', zhTW: '恢復中', zhCN: '恢复中'),
    'healed' => L.pick(en: 'Healed', zhTW: '已痊癒', zhCN: '已痊愈'),
    'active' => L.pick(en: 'Active', zhTW: '生效中', zhCN: '生效中'),
    'suspended' => L.pick(en: 'Suspended', zhTW: '暫停', zhCN: '暂停'),
    'revoked' => L.pick(en: 'Revoked', zhTW: '已撤銷', zhCN: '已撤销'),
    'unaware' => L.pick(en: 'Unaware', zhTW: '不知情', zhCN: '不知情'),
    'suspicious' => L.pick(en: 'Suspicious', zhTW: '懷疑', zhCN: '怀疑'),
    'heard' => L.pick(en: 'Heard', zhTW: '聽說', zhCN: '听说'),
    'investigating' => L.pick(en: 'Investigating', zhTW: '調查中', zhCN: '调查中'),
    'believed' => L.pick(en: 'Believed', zhTW: '相信', zhCN: '相信'),
    'confirmed' => L.pick(en: 'Confirmed', zhTW: '已證實', zhCN: '已证实'),
    'resolved' => L.pick(en: 'Resolved', zhTW: '已解決', zhCN: '已解决'),
    'stalled' => L.pick(en: 'Stalled', zhTW: '停滯', zhCN: '停滞'),
    'held' => L.pick(en: 'Held', zhTW: '持有', zhCN: '持有'),
    'lost' => L.pick(en: 'Lost', zhTW: '遺失', zhCN: '遗失'),
    'destroyed' => L.pick(en: 'Destroyed', zhTW: '已毀損', zhCN: '已毁损'),
    'transferred' => L.pick(en: 'Transferred', zhTW: '已轉移', zhCN: '已转移'),
    'unknown' => L.pick(en: 'Unknown', zhTW: '未知', zhCN: '未知'),
    _ => status,
  };

  String _layerLabel(String layer) => switch (layer) {
    'memory' => L.pick(en: 'Flashback', zhTW: '回憶', zhCN: '回忆'),
    'dream' => L.pick(en: 'Dream', zhTW: '夢境', zhCN: '梦境'),
    'hypothetical' => L.pick(en: 'Hypothetical', zhTW: '假設', zhCN: '假设'),
    'au' => 'AU',
    'ooc' => 'OOC',
    _ => layer,
  };

  List<Widget> _characterGroup(String tier) {
    final rows = _characters.where((row) => row['tier'] == tier).toList();
    if (rows.isEmpty) return const <Widget>[];
    final title = switch (tier) {
      'active' => L.pick(en: 'Active', zhTW: '活躍角色', zhCN: '活跃角色'),
      'common' => L.pick(en: 'Recurring', zhTW: '常見角色', zhCN: '常见角色'),
      _ => L.pick(en: 'Backstage', zhTW: '候場角色', zhCN: '候场角色'),
    };
    return <Widget>[
      _sectionTitle(title),
      ...rows.map(_characterTile),
      const SizedBox(height: 12),
    ];
  }

  Widget _sectionTitle(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      value,
      style: YanciTheme.bodySmall.copyWith(
        color: YanciTheme.accent.withValues(alpha: 0.72),
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _markdown(String value, {TextStyle? style}) => MarkdownBody(
    data: value,
    selectable: true,
    styleSheet: MarkdownStyleSheet(
      p: style ?? YanciTheme.bodySmall,
      listBullet: style ?? YanciTheme.bodySmall,
      blockSpacing: 6,
    ),
  );

  Widget _characterTile(Map<String, dynamic> row) => InkWell(
    onTap: () => _editCharacter(row),
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${row['name']}', style: YanciTheme.bodyText),
                const SizedBox(height: 4),
                _markdown(
                  <Object?>[
                        row['gender'],
                        row['identity'],
                        row['relation_to_leads'],
                      ]
                      .map((v) => v?.toString().trim() ?? '')
                      .where((v) => v.isNotEmpty)
                      .join(' · '),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                  ),
                ),
                if ('${row['evidence'] ?? ''}'.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      '「${row['evidence']}」 · #${row['source_conversation_id']} · msg ${row['source_message_ids']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.58),
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: L.pick(
              en: 'Important character',
              zhTW: '重要角色',
              zhCN: '重要角色',
            ),
            onPressed: () => _toggleImportant(row),
            icon: Icon(
              row['is_important'] == 1
                  ? Icons.star_rounded
                  : Icons.star_border_rounded,
              color: YanciTheme.accent.withValues(
                alpha: row['is_important'] == 1 ? 0.9 : 0.36,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _relationshipTile(Map<String, dynamic> row) => InkWell(
    onTap: () => _editRelationship(row),
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row['from_name']} → ${row['to_name']}',
            style: YanciTheme.bodyText,
          ),
          const SizedBox(height: 4),
          _markdown(
            '${row['current_relation'] ?? ''}',
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
            ),
          ),
          if ('${row['origin'] ?? ''}'.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: _markdown(
                '${L.pick(en: 'Origin', zhTW: '形成經過', zhCN: '形成经过')}：${row['origin']}',
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                ),
              ),
            ),
          if ('${row['evidence'] ?? ''}'.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '「${row['evidence']}」 · #${row['source_conversation_id']} · msg ${row['source_message_ids']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.52),
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
