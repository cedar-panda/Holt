import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../services/external_chat_import_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/context_mode_pill.dart';

class ExternalChatImportScreen extends StatefulWidget {
  const ExternalChatImportScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<ExternalChatImportScreen> createState() =>
      _ExternalChatImportScreenState();
}

class _ExternalChatImportScreenState extends State<ExternalChatImportScreen> {
  ExternalImportPreview? _preview;
  List<Map<String, dynamic>> _characters = const <Map<String, dynamic>>[];
  List<Map<String, Object?>> _storylines = const <Map<String, Object?>>[];
  String? _characterId;
  String _storylineId = 'main';
  ContextMode _mode = ContextMode.daily;
  Object? _error;
  bool _loading = true;
  bool _importing = false;
  bool _loadingStorylines = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        ExternalChatImportService.parseFile(widget.filePath),
        DatabaseHelper.getCharacters(),
      ]);
      if (!mounted) return;
      final characters = results[1] as List<Map<String, dynamic>>;
      setState(() {
        _preview = results[0] as ExternalImportPreview;
        _characters = characters;
        _characterId = characters.isEmpty
            ? null
            : characters.first['id']?.toString();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _setMode(ContextMode mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (mode == ContextMode.rp) await _loadStorylines();
  }

  Future<void> _setCharacter(String? characterId) async {
    if (characterId == null || characterId == _characterId) return;
    setState(() => _characterId = characterId);
    if (_mode == ContextMode.rp) await _loadStorylines();
  }

  Future<void> _loadStorylines() async {
    final characterId = _characterId;
    if (characterId == null) return;
    setState(() => _loadingStorylines = true);
    await DatabaseHelper.ensureDefaultRpStoryline(characterId);
    final rows = await DatabaseHelper.getRpStorylines(characterId);
    final active = rows.where((row) => row['status'] == 'active').toList();
    if (!mounted) return;
    setState(() {
      _storylines = active;
      _loadingStorylines = false;
      if (!active.any((row) => row['id']?.toString() == _storylineId)) {
        final defaultRow = active.cast<Map<String, Object?>>().where(
          (row) => row['is_default'] == 1,
        );
        _storylineId = defaultRow.isNotEmpty
            ? defaultRow.first['id'].toString()
            : active.isEmpty
            ? 'main'
            : active.first['id'].toString();
      }
    });
  }

  Future<void> _import() async {
    final preview = _preview;
    final characterId = _characterId;
    if (preview == null || characterId == null || !preview.canImport) return;
    final character = _characters.cast<Map<String, dynamic>>().where(
      (row) => row['id']?.toString() == characterId,
    );
    final characterName = character.isEmpty
        ? ''
        : character.first['name']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          L.pick(
            en: 'Import external conversations?',
            zhTW: '匯入外部對話？',
            zhCN: '导入外部对话？',
          ),
        ),
        content: Text(
          L.pick(
            en: '${preview.conversations.length} window(s) will be added to $characterName. Existing Holt data will not be replaced. Memories and summaries will not be generated automatically.',
            zhTW:
                '將新增 ${preview.conversations.length} 個窗口至 $characterName。現有 Holt 資料不會被覆蓋，也不會自動生成記憶或摘要。',
            zhCN:
                '将新增 ${preview.conversations.length} 个窗口至 $characterName。现有 Holt 数据不会被覆盖，也不会自动生成记忆或摘要。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              L.pick(en: 'Import', zhTW: '匯入', zhCN: '导入'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _importing = true);
    try {
      final result = await ExternalChatImportService.importPreview(
        preview: preview,
        characterId: characterId,
        contextMode: _mode,
        continuityId: _mode == ContextMode.rp ? _storylineId : 'main',
      );
      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(
          en: '${result.importedConversations} window(s) added, ${result.updatedConversations} updated${result.skippedDuplicates == 0 ? '' : ', ${result.skippedDuplicates} duplicate(s) skipped'}',
          zhTW:
              '已新增 ${result.importedConversations} 個窗口、更新 ${result.updatedConversations} 個窗口${result.skippedDuplicates == 0 ? '' : '，略過 ${result.skippedDuplicates} 個重複窗口'}',
          zhCN:
              '已新增 ${result.importedConversations} 个窗口、更新 ${result.updatedConversations} 个窗口${result.skippedDuplicates == 0 ? '' : '，跳过 ${result.skippedDuplicates} 个重复窗口'}',
        ),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Import failed: $error',
          zhTW: '匯入失敗：$error',
          zhCN: '导入失败：$error',
        ),
      );
      setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YanciTheme.backgroundGradient.first,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          L.pick(en: 'Import external chats', zhTW: '匯入外部對話', zhCN: '导入外部对话'),
        ),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: YanciTheme.accent))
          : _error != null
          ? _errorView()
          : _content(),
    );
  }

  Widget _errorView() => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: Text(
        L.pick(
          en: 'This file could not be read.\n$_error',
          zhTW: '無法讀取這個檔案。\n$_error',
          zhCN: '无法读取这个文件。\n$_error',
        ),
        textAlign: TextAlign.center,
        style: TextStyle(color: YanciTheme.textSecondary, height: 1.5),
      ),
    ),
  );

  Widget _content() {
    final preview = _preview!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      children: <Widget>[
        _summaryCard(preview),
        const SizedBox(height: 18),
        if (_characters.isEmpty)
          _notice(
            L.pick(
              en: 'Create a character before importing conversations.',
              zhTW: '請先建立角色，再匯入對話。',
              zhCN: '请先建立角色，再导入对话。',
            ),
          )
        else if (!preview.canImport)
          _referenceOnly(preview)
        else ...<Widget>[
          Text(
            L.pick(en: 'Import into', zhTW: '匯入至', zhCN: '导入至'),
            style: TextStyle(
              color: YanciTheme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _characterId,
            dropdownColor: YanciTheme.surfacePanel,
            decoration: _inputDecoration(
              L.pick(en: 'Character', zhTW: '角色', zhCN: '角色'),
            ),
            items: _characters
                .map(
                  (row) => DropdownMenuItem<String>(
                    value: row['id']?.toString(),
                    child: Text(row['name']?.toString() ?? ''),
                  ),
                )
                .toList(growable: false),
            onChanged: _importing ? null : _setCharacter,
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: ContextModePill(
              mode: _mode,
              onChanged: _importing ? (_) {} : _setMode,
            ),
          ),
          if (_mode == ContextMode.rp) ...<Widget>[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _storylineId,
              dropdownColor: YanciTheme.surfacePanel,
              decoration: _inputDecoration(
                L.pick(en: 'Storyline', zhTW: '故事線', zhCN: '故事线'),
              ),
              items: _storylines
                  .map(
                    (row) => DropdownMenuItem<String>(
                      value: row['id']?.toString(),
                      child: Text(
                        (row['name']?.toString().trim().isNotEmpty ?? false)
                            ? row['name'].toString()
                            : L.pick(
                                en: 'Main storyline',
                                zhTW: '主要故事線',
                                zhCN: '主要故事线',
                              ),
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _importing
                  ? null
                  : (value) {
                      if (value != null) setState(() => _storylineId = value);
                    },
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _importing || _loadingStorylines ? null : _import,
            style: FilledButton.styleFrom(
              backgroundColor: YanciTheme.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
              ),
            ),
            child: _importing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(L.pick(en: 'Import', zhTW: '匯入', zhCN: '导入')),
          ),
        ],
      ],
    );
  }

  Widget _summaryCard(ExternalImportPreview preview) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: YanciTheme.accent.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            preview.source.displayName,
            style: TextStyle(
              color: YanciTheme.accent,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            L.pick(
              en: '${preview.conversations.length} windows · ${preview.messageCount} messages',
              zhTW:
                  '${preview.conversations.length} 個窗口 · ${preview.messageCount} 則消息',
              zhCN:
                  '${preview.conversations.length} 个窗口 · ${preview.messageCount} 条消息',
            ),
            style: TextStyle(color: YanciTheme.textSecondary),
          ),
          if (preview.warnings.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            for (final warning in preview.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  warning,
                  style: TextStyle(
                    color: YanciTheme.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
          ],
          if (preview.conversations.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            ...preview.conversations
                .take(8)
                .map(
                  (conversation) => Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: YanciTheme.textPrimary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${conversation.messages.length}',
                          style: TextStyle(
                            color: YanciTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            if (preview.conversations.length > 8)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '+ ${preview.conversations.length - 8}',
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _referenceOnly(ExternalImportPreview preview) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _notice(
        L.pick(
          en: 'This Markdown file has no reliable speaker boundaries. Holt will not invent a chat history from it.',
          zhTW: '這份 Markdown 沒有可靠的發言者邊界，Holt 不會把它虛構成聊天紀錄。',
          zhCN: '这份 Markdown 没有可靠的发言者边界，Holt 不会把它虚构成聊天记录。',
        ),
      ),
      if (preview.referenceDocument != null) ...<Widget>[
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
          ),
          child: SingleChildScrollView(
            child: Text(
              preview.referenceDocument!,
              style: TextStyle(
                color: YanciTheme.textSecondary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ),
      ],
    ],
  );

  Widget _notice(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: YanciTheme.accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
    ),
    child: Text(
      text,
      style: TextStyle(color: YanciTheme.textSecondary, height: 1.45),
    ),
  );

  InputDecoration _inputDecoration(String label) => InputDecoration(
    labelText: label,
    labelStyle: TextStyle(color: YanciTheme.textSecondary),
    filled: true,
    fillColor: YanciTheme.surfacePanel.withValues(alpha: 0.56),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      borderSide: BorderSide(
        color: YanciTheme.textSecondary.withValues(alpha: 0.16),
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      borderSide: BorderSide(color: YanciTheme.accent),
    ),
  );
}
