import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/message.dart';
import '../services/guide_manual.dart';
import '../services/guide_service.dart';
import '../services/app_error_log_service.dart';
import '../services/locale_strings.dart';
import '../services/rp_worldbook_service.dart';
import '../services/settings/guide_settings.dart';
import '../services/settings/api_settings.dart';
import '../services/settings/user_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/gradient_background.dart';
import '../widgets/scroll_edge_fade.dart';

enum _GuideReplyMode { system, api }

class GuideChatScreen extends StatefulWidget {
  const GuideChatScreen({super.key});

  @override
  State<GuideChatScreen> createState() => _GuideChatScreenState();
}

class _GuideChatScreenState extends State<GuideChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  List<Message> _messages = const <Message>[];
  List<String> _followUps = const <String>[];
  List<StarredModelEntry> _starredModels = const <StarredModelEntry>[];
  GuidePersonaDraft? _pendingDraft;
  StarredModelEntry? _selectedModel;
  String? _conversationId;
  String _streamingText = '';
  String _localGreeting = '';
  bool _loading = true;
  bool _sending = false;
  bool _personaWorkshopActive = false;
  _GuideReplyMode _replyMode = _GuideReplyMode.system;
  bool _hasRecentError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await GuideManual.ensureSnapshotPersisted();
    final name = await UserSettings.getUserName();
    final greeting = GuideService.localGreeting(userName: name);
    final hasRecentError = await AppErrorLogService.hasEntries();
    final savedModels = await ApiSettings.getRankedStarredModelEntries();
    final usableModels = <StarredModelEntry>[];
    for (final entry in savedModels) {
      if (await ApiSettings.hasUsableProviderConfiguration(entry.provider)) {
        usableModels.add(entry);
      }
    }
    final encodedDraft = await GuideSettings.pendingDraft();
    GuidePersonaDraft? draft;
    if (encodedDraft.isNotEmpty) {
      try {
        draft = GuidePersonaDraft.fromJson(jsonDecode(encodedDraft));
      } catch (_) {
        draft = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _localGreeting = greeting;
      _messages = <Message>[
        Message(
          conversationId: '',
          characterId: GuideService.characterId,
          text: greeting,
          isUser: false,
        ),
      ];
      _starredModels = usableModels;
      _selectedModel = usableModels.isEmpty ? null : usableModels.first;
      _pendingDraft = draft;
      _hasRecentError = hasRecentError;
      _loading = false;
    });
    _scrollToBottom();
  }

  Future<String> _ensureConversation(String firstQuestion) async {
    final existing = _conversationId;
    if (existing != null) return existing;
    final id = 'holt-guide-${const Uuid().v4()}';
    final title = firstQuestion.characters.length > 32
        ? '${firstQuestion.characters.take(32)}…'
        : firstQuestion;
    await GuideService.createSessionConversation(
      conversationId: id,
      title: title,
    );
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: id,
        characterId: GuideService.characterId,
        text: _localGreeting,
        isUser: false,
      ),
    );
    _conversationId = id;
    return id;
  }

  Future<void> _send([String? suggestedQuestion]) async {
    final text = (suggestedQuestion ?? _controller.text).trim();
    if (text.isEmpty || _sending) return;
    if (_replyMode == _GuideReplyMode.api && _selectedModel == null) {
      _showNeedFavoriteModel();
      return;
    }
    _focusNode.unfocus();
    _controller.clear();
    final conversationId = await _ensureConversation(text);
    final userMessage = Message(
      conversationId: conversationId,
      characterId: GuideService.characterId,
      text: text,
      isUser: true,
    );
    await DatabaseHelper.insertMessage(userMessage);
    final messagesAfterUser = await GuideService.loadConversationMessages(
      conversationId,
    );
    if (!mounted) return;
    setState(() {
      _messages = messagesAfterUser;
      _followUps = const <String>[];
      _streamingText = '';
      _sending = true;
    });
    _scrollToBottom();

    try {
      final answer = _replyMode == _GuideReplyMode.system
          ? await GuideService.systemAnswer(text)
          : await GuideService.answer(
              text,
              conversationId: conversationId,
              providerOverride: _selectedModel!.provider,
              modelOverride: _selectedModel!.modelId,
              onProgress: (value) {
                if (!mounted) return;
                setState(() => _streamingText = value);
                _scrollToBottom();
              },
            );
      final visible = answer.visibleText.trim();
      if (visible.isNotEmpty) {
        final assistantMessage = Message(
          conversationId: conversationId,
          characterId: GuideService.characterId,
          text: visible,
          isUser: false,
        );
        await DatabaseHelper.insertMessage(assistantMessage);
        final messagesAfterReply = await GuideService.loadConversationMessages(
          conversationId,
        );
        if (!mounted) return;
        setState(() => _messages = messagesAfterReply);
      }
      if (answer.personaDraft != null) {
        await GuideSettings.savePendingDraft(
          jsonEncode(answer.personaDraft!.toJson()),
        );
      }
      if (!mounted) return;
      setState(() {
        _followUps = answer.followUps;
        _pendingDraft = answer.personaDraft ?? _pendingDraft;
        _streamingText = '';
      });
    } catch (error) {
      await AppErrorLogService.record(
        error: error,
        trigger: 'guide_api_request',
        source: 'guide',
        provider: _selectedModel?.provider ?? '',
        model: _selectedModel?.modelId ?? '',
      );
      if (!mounted) return;
      setState(() => _streamingText = '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            L.pick(
              en: 'The Guide could not reply: $error',
              zhTW: '嚮導暫時無法回覆：$error',
              zhCN: '向导暂时无法回复：$error',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  void _showNeedFavoriteModel() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          L.pick(
            en: 'Favorite a model in API settings first.',
            zhTW: '先去收藏喜歡的模型喔～',
            zhCN: '先去收藏喜欢的模型哦～',
          ),
        ),
        action: SnackBarAction(
          label: L.pick(en: 'Open', zhTW: '前往', zhCN: '前往'),
          onPressed: () => Navigator.of(context).pushNamed('/api_settings'),
        ),
      ),
    );
  }

  Future<void> _beginPersonaWorkshop() async {
    if (_sending) return;
    if (_selectedModel == null) {
      _showNeedFavoriteModel();
      return;
    }
    final options = await _loadReferenceOptions();
    if (!mounted) return;
    final selected = await _showReferencePicker(options);
    if (selected == null || !mounted) return;
    setState(() {
      _personaWorkshopActive = true;
      _replyMode = _GuideReplyMode.api;
    });
    final message = await _buildReferenceMessage(selected);
    if (!mounted) return;
    await _send(message);
  }

  Future<void> _requestPersonaDraft() async {
    if (_sending) return;
    if (_selectedModel == null) {
      _showNeedFavoriteModel();
      return;
    }
    setState(() => _replyMode = _GuideReplyMode.api);
    await _send(
      L.pick(
        en: 'Please organize what we have discussed into a complete character card now. Show it here for me to review and edit before creating the character.',
        zhTW: '幫我寫好人設卡。請根據我們目前聊過的內容整理完整人設，在這裡給我預覽與編輯，確認後再建立角色。',
        zhCN: '帮我写好人设卡。请根据我们目前聊过的内容整理完整人设，在这里给我预览与编辑，确认后再建立角色。',
      ),
    );
  }

  Future<void> _showErrorEmailDraft() async {
    final body = await AppErrorLogService.composeEmailBody();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          L.pick(
            en: 'Draft an error report',
            zhTW: '擬一封 Holt 錯誤回報郵件',
            zhCN: '拟一封 Holt 错误回报邮件',
          ),
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(body, style: YanciTheme.bodySmall),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: body));
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: Text(L.pick(en: 'Copy', zhTW: '複製', zhCN: '复制')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(L.get('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _exportErrorLog() async {
    try {
      final file = await AppErrorLogService.exportLogFile();
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: 'text/plain')],
          fileNameOverrides: <String>[
            file.uri.pathSegments.isEmpty
                ? 'holt-error-log.txt'
                : file.uri.pathSegments.last,
          ],
          title: L.pick(
            en: 'Share Holt error log',
            zhTW: '分享 Holt 報錯日誌',
            zhCN: '分享 Holt 报错日志',
          ),
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Could not export the error log: $error',
              zhTW: '無法匯出報錯日誌：$error',
              zhCN: '无法导出报错日志：$error',
            ),
          ),
        ),
      );
    }
  }

  Future<List<_GuideReferenceOption>> _loadReferenceOptions() async {
    final characters = await DatabaseHelper.getCharacters();
    final options = <_GuideReferenceOption>[];
    for (final character in characters) {
      final characterId = '${character['id'] ?? ''}'.trim();
      if (characterId.isEmpty || characterId == GuideService.characterId) {
        continue;
      }
      final name = '${character['name'] ?? ''}'.trim();
      options.add(
        _GuideReferenceOption.character(
          characterId: characterId,
          title: name.isEmpty
              ? L.pick(en: 'Unnamed character', zhTW: '未命名角色', zhCN: '未命名角色')
              : name,
          character: character,
        ),
      );
      final storylines = await DatabaseHelper.getRpStorylines(characterId);
      for (final storyline in storylines) {
        final storylineId = '${storyline['id'] ?? ''}'.trim();
        if (storylineId.isEmpty) continue;
        final storylineName = '${storyline['name'] ?? ''}'.trim();
        options.add(
          _GuideReferenceOption.storyline(
            characterId: characterId,
            storylineId: storylineId,
            title: storylineName.isEmpty
                ? L.pick(en: 'Main story', zhTW: '主要故事線', zhCN: '主要故事线')
                : storylineName,
            subtitle: name,
          ),
        );
      }
    }
    return options;
  }

  Future<List<_GuideReferenceOption>?> _showReferencePicker(
    List<_GuideReferenceOption> options,
  ) {
    return showModalBottomSheet<List<_GuideReferenceOption>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final selectedKeys = <String>{};
        return StatefulBuilder(
          builder: (context, setSheetState) => FractionallySizedBox(
            heightFactor: .78,
            child: Material(
              color: YanciTheme.surfacePanel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                      child: Column(
                        children: <Widget>[
                          Text(
                            L.pick(
                              en: 'What should inspire this new RP?',
                              zhTW: '這次想參考哪些 RP 內容？',
                              zhCN: '这次想参考哪些 RP 内容？',
                            ),
                            style: YanciTheme.headingMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            L.pick(
                              en: 'Selected character details, summaries, and worldbook excerpts will be sent as a visible message. They are references, not content to copy.',
                              zhTW: '選中的角色資料、摘要與世界書節錄會作為可見訊息送出；它們只供參考，不代表直接複製。',
                              zhCN: '选中的角色资料、摘要与世界书节录会作为可见消息送出；它们只供参考，不代表直接复制。',
                            ),
                            textAlign: TextAlign.center,
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: options.isEmpty
                          ? Center(
                              child: Text(
                                L.pick(
                                  en: 'No existing character or RP story yet',
                                  zhTW: '目前還沒有可參考的角色或故事線',
                                  zhCN: '目前还没有可参考的角色或故事线',
                                ),
                                style: YanciTheme.bodyText.copyWith(
                                  color: YanciTheme.textSecondary,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final option = options[index];
                                final selected = selectedKeys.contains(
                                  option.key,
                                );
                                return CheckboxListTile(
                                  value: selected,
                                  activeColor: YanciTheme.accent,
                                  controlAffinity:
                                      ListTileControlAffinity.trailing,
                                  onChanged: (value) => setSheetState(() {
                                    if (value == true) {
                                      selectedKeys.add(option.key);
                                    } else {
                                      selectedKeys.remove(option.key);
                                    }
                                  }),
                                  title: Text(option.title),
                                  subtitle: Text(
                                    option.kind == _GuideReferenceKind.character
                                        ? L.pick(
                                            en: 'Character card',
                                            zhTW: '角色人設',
                                            zhCN: '角色人设',
                                          )
                                        : L.pick(
                                            en: '${option.subtitle} · RP storyline',
                                            zhTW: '${option.subtitle} · RP 故事線',
                                            zhCN: '${option.subtitle} · RP 故事线',
                                          ),
                                    style: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.of(
                                sheetContext,
                              ).pop(const <_GuideReferenceOption>[]),
                              child: Text(
                                L.pick(
                                  en: 'I am not sure yet — let us talk',
                                  zhTW: '我還沒想好，先聊聊',
                                  zhCN: '我还没想好，先聊聊',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: selectedKeys.isEmpty
                                  ? null
                                  : () => Navigator.of(sheetContext).pop(
                                      options
                                          .where(
                                            (option) => selectedKeys.contains(
                                              option.key,
                                            ),
                                          )
                                          .toList(growable: false),
                                    ),
                              child: Text(
                                L.pick(
                                  en: 'Discuss references',
                                  zhTW: '帶著參考聊聊',
                                  zhCN: '带着参考聊聊',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String> _buildReferenceMessage(
    List<_GuideReferenceOption> selected,
  ) async {
    if (selected.isEmpty) {
      return L.pick(
        en: 'I have not decided on the new RP setting or character yet. Please talk it through with me one question at a time.',
        zhTW: '我還沒想好新的 RP 劇本與人設，先一次問我一個問題，陪我慢慢聊出來。',
        zhCN: '我还没想好新的 RP 剧本与人设，先一次问我一个问题，陪我慢慢聊出来。',
      );
    }
    final buffer = StringBuffer(
      L.pick(
        en: 'I want to discuss a new RP story and character. The following are references I selected. Learn my preferences from them, but do not copy their names, identities, or events directly.',
        zhTW: '我想聊聊新的 RP 劇本與人設。以下是我選擇的參考內容；請從中理解我的偏好，但不要直接複製名字、身分或既有事件。',
        zhCN: '我想聊聊新的 RP 剧本与人设。以下是我选择的参考内容；请从中理解我的偏好，但不要直接复制名字、身份或既有事件。',
      ),
    );
    for (final option in selected) {
      if (option.kind == _GuideReferenceKind.character) {
        final character = option.character!;
        final facts = <String>[
          '${character['gender'] ?? ''}'.trim(),
          '${character['relationship'] ?? ''}'.trim(),
          '${character['race'] ?? ''}'.trim(),
          '${character['age'] ?? ''}'.trim(),
        ].where((value) => value.isNotEmpty).join(' · ');
        final description = _clipVisible(
          '${character['description'] ?? ''}'.trim(),
          600,
        );
        buffer
          ..write('\n\n【')
          ..write(L.pick(en: 'Character reference', zhTW: '角色參考', zhCN: '角色参考'))
          ..write('｜${option.title}】');
        if (facts.isNotEmpty) buffer.write('\n$facts');
        if (description.isNotEmpty) buffer.write('\n$description');
        continue;
      }
      final summaries = await DatabaseHelper.getLatestContextSummaries(
        option.characterId,
        limit: 2,
        contextMode: ContextMode.rp,
        continuityId: option.storylineId!,
      );
      final worldbook = await RpWorldbookService.listEntries(
        characterId: option.characterId,
        continuityId: option.storylineId!,
        includeArchived: false,
      );
      buffer
        ..write('\n\n【')
        ..write(L.pick(en: 'Story reference', zhTW: '故事線參考', zhCN: '故事线参考'))
        ..write('｜${option.subtitle} · ${option.title}】');
      if (summaries.isNotEmpty) {
        final content = summaries.reversed
            .map((row) => '${row['content'] ?? ''}'.trim())
            .where((value) => value.isNotEmpty)
            .join('\n');
        buffer
          ..write('\n')
          ..write(L.pick(en: 'Summary:', zhTW: '摘要：', zhCN: '摘要：'))
          ..write(_clipVisible(content, 1400));
      }
      if (worldbook.isNotEmpty) {
        final entries = worldbook
            .take(8)
            .map(
              (row) =>
                  '- ${row['name'] ?? ''}：${_clipVisible('${row['content'] ?? ''}'.trim(), 220)}',
            )
            .join('\n');
        if (entries.trim().isNotEmpty) {
          buffer
            ..write('\n')
            ..write(L.pick(en: 'Worldbook:', zhTW: '世界書：', zhCN: '世界书：'))
            ..write('\n$entries');
        }
      }
    }
    return buffer.toString();
  }

  String _clipVisible(String value, int limit) {
    if (value.characters.length <= limit) return value;
    return '${value.characters.take(limit)}…';
  }

  Future<void> _showHistory() async {
    final conversations = await GuideService.listHistory();
    final records = <({Conversation conversation, List<Message> messages})>[];
    for (final conversation in conversations) {
      records.add((
        conversation: conversation,
        messages: await GuideService.loadConversationMessages(conversation.id),
      ));
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .78,
        child: Material(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: SafeArea(
            top: false,
            child: records.isEmpty
                ? Center(
                    child: Text(
                      L.pick(
                        en: 'No Guide history yet',
                        zhTW: '還沒有嚮導歷史紀錄',
                        zhCN: '还没有向导历史记录',
                      ),
                      style: YanciTheme.bodyText.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                    itemCount: records.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            L.pick(
                              en: 'Guide history',
                              zhTW: '嚮導歷史紀錄',
                              zhCN: '向导历史记录',
                            ),
                            textAlign: TextAlign.center,
                            style: YanciTheme.headingMedium,
                          ),
                        );
                      }
                      final record = records[index - 1];
                      final date = record.conversation.updatedAt;
                      final dateLabel =
                          '${date.year}/${date.month.toString().padLeft(2, '0')}/'
                          '${date.day.toString().padLeft(2, '0')} '
                          '${date.hour.toString().padLeft(2, '0')}:'
                          '${date.minute.toString().padLeft(2, '0')}';
                      return ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                        title: Text(
                          record.conversation.title ??
                              L.pick(en: 'Guide', zhTW: '嚮導', zhCN: '向导'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: YanciTheme.bodyText.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          dateLabel,
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        children: <Widget>[
                          for (final message in record.messages)
                            Align(
                              alignment: message.isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.sizeOf(sheetContext).width *
                                        .82,
                                  ),
                                  child: message.isUser
                                      ? Text(message.text)
                                      : _buildMarkdown(message.text),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _showModelPicker() async {
    if (_starredModels.isEmpty) {
      _showNeedFavoriteModel();
      return;
    }
    final selected = await showModalBottomSheet<StarredModelEntry>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Material(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: SafeArea(
          top: false,
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
            itemCount: _starredModels.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final entry = _starredModels[index];
              final isSelected = entry.identity == _selectedModel?.identity;
              return ListTile(
                onTap: () => Navigator.of(context).pop(entry),
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                title: Text(
                  entry.modelId,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _providerLabel(entry.provider),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                trailing: isSelected
                    ? Icon(Icons.check_rounded, color: YanciTheme.accent)
                    : null,
              );
            },
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _selectedModel = selected);
    }
  }

  String _providerLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'openai_compatible' => L.pick(
      en: 'Custom Relay',
      zhTW: '自訂中轉站',
      zhCN: '自定义中转站',
    ),
    'thinking_machines' => 'Inkling',
    'gemini' => 'Gemini',
    'deepinfra' => 'DeepInfra',
    'xai' => 'xAI',
    'bedrock' => 'AWS Bedrock',
    _ => provider,
  };

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _hideGuide() async {
    await GuideSettings.setEnabled(false);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _reviewDraft(GuidePersonaDraft draft) async {
    final result = await showModalBottomSheet<GuidePersonaDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _GuideDraftEditor(draft: draft),
    );
    if (result == null || !mounted) return;
    await _createCharacter(result);
  }

  Future<void> _createCharacter(GuidePersonaDraft draft) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    await DatabaseHelper.insertCharacter(<String, Object?>{
      'id': id,
      ...draft.toJson(),
      'avatar_path': '',
      'tts_voice_id': null,
      'draw_anchor_user': '',
      'draw_anchor_char': '',
      'draw_style': '',
      'whisper_model_override': 0,
      'created_at': now,
      'updated_at': now,
    });
    await GuideSettings.clearPendingDraft();
    if (!mounted) return;
    setState(() {
      _pendingDraft = null;
      _personaWorkshopActive = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          L.pick(
            en: '${draft.name} was added to Characters.',
            zhTW: '已將「${draft.name}」加入角色。',
            zhCN: '已将“${draft.name}”加入角色。',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasUserMessage = _messages.any((message) => message.isUser);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GradientBackground(
        scope: YanciBackgroundScope.chat,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: _loading
                          ? Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: YanciTheme.accent,
                              ),
                            )
                          : ScrollEdgeFade(
                              controller: _scrollController,
                              topInset: 44,
                              topExtent: 122,
                              bottomExtent: 28,
                              blurSigma: 0,
                              alwaysFadeTop: true,
                              child: ListView(
                                controller: _scrollController,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  56 + 20,
                                  20,
                                  32,
                                ),
                                children: <Widget>[
                                  for (
                                    var index = 0;
                                    index < _messages.length;
                                    index++
                                  )
                                    _buildMessage(
                                      _messages[index],
                                      first: index == 0,
                                    ),
                                  if (!hasUserMessage) ...<Widget>[
                                    const SizedBox(height: 4),
                                    if (_replyMode ==
                                        _GuideReplyMode.api) ...<Widget>[
                                      _buildApiNotice(),
                                      const SizedBox(height: 12),
                                    ],
                                    _buildSuggestions(
                                      GuideManual.popularQuestions,
                                    ),
                                  ],
                                  if (_streamingText.isNotEmpty)
                                    _buildStreamingMessage(_streamingText),
                                  if (_pendingDraft != null) ...<Widget>[
                                    const SizedBox(height: 10),
                                    _buildDraftCard(_pendingDraft!),
                                  ],
                                  if (_followUps.isNotEmpty &&
                                      !_sending) ...<Widget>[
                                    const SizedBox(height: 10),
                                    _buildSuggestions(_followUps),
                                  ],
                                ],
                              ),
                            ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildHeader(),
                    ),
                  ],
                ),
              ),
              _buildInput(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Text(
            L.pick(en: 'Guide', zhTW: '嚮導', zhCN: '向导'),
            style: YanciTheme.headingMedium,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 20,
                color: YanciTheme.textPrimary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: L.pick(
                    en: 'Guide history',
                    zhTW: '嚮導歷史紀錄',
                    zhCN: '向导历史记录',
                  ),
                  onPressed: _showHistory,
                  icon: Icon(
                    Icons.history_rounded,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: L.pick(
                    en: 'Guide options',
                    zhTW: '嚮導選項',
                    zhCN: '向导选项',
                  ),
                  color: YanciTheme.surfacePanel,
                  onSelected: (value) {
                    if (value == 'hide') unawaited(_hideGuide());
                    if (value == 'errors') {
                      Navigator.of(context).pushNamed('/error_diagnostics');
                    }
                    if (value == 'export_errors') {
                      unawaited(_exportErrorLog());
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'errors',
                      child: Text(
                        L.pick(en: 'Error records', zhTW: '報錯記錄', zhCN: '报错记录'),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'export_errors',
                      child: Text(
                        L.pick(
                          en: 'Export error log',
                          zhTW: '匯出報錯日誌',
                          zhCN: '导出报错日志',
                        ),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'hide',
                      child: Text(
                        L.pick(en: 'Hide Guide', zhTW: '隱藏嚮導', zhCN: '隐藏向导'),
                      ),
                    ),
                  ],
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: YanciTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(Message message, {required bool first}) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 10),
      child: ChatBubble(
        key: ValueKey<String>('guide_${message.id ?? message.createdAt}'),
        text: message.text,
        isUser: message.isUser,
        timestamp: message.createdAt,
        messageId: message.id == null ? null : 'msg_${message.id}',
        conversationId: message.conversationId.isEmpty
            ? null
            : message.conversationId,
        conversationTitle: L.pick(en: 'Guide', zhTW: '嚮導', zhCN: '向导'),
        characterId: GuideService.characterId,
        showAvatar: false,
        showToolbar: !first || message.conversationId.isNotEmpty,
        includeThinkingDetails: false,
        includeMemoryDetails: false,
        includeEmotionDetails: false,
      ),
    );
  }

  Widget _buildMarkdown(String text) {
    final body = YanciTheme.bodyText.copyWith(height: 1.45);
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: body,
        strong: body.copyWith(fontWeight: FontWeight.w700),
        em: body.copyWith(fontStyle: FontStyle.italic),
        listBullet: body,
        blockSpacing: 8,
        listIndent: 18,
      ),
    );
  }

  Widget _buildStreamingMessage(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ChatBubble(
        text: text,
        isUser: false,
        isStreaming: true,
        conversationId: _conversationId,
        conversationTitle: L.pick(en: 'Guide', zhTW: '嚮導', zhCN: '向导'),
        characterId: GuideService.characterId,
        showAvatar: false,
        showToolbar: false,
        includeThinkingDetails: false,
        includeMemoryDetails: false,
        includeEmotionDetails: false,
      ),
    );
  }

  Widget _buildApiNotice() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.info_outline_rounded,
          size: 14,
          color: YanciTheme.textSecondary.withValues(alpha: .58),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            L.pick(
              en: 'This conversation may use API credit after you send.',
              zhTW: '送出訊息後，該對話可能會使用 API 額度',
              zhCN: '送出消息后，该对话可能会使用 API 额度',
            ),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: .58),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestions(List<String> suggestions) {
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: <Widget>[
        for (final suggestion in suggestions)
          Semantics(
            button: true,
            label: suggestion,
            child: InkWell(
              borderRadius: BorderRadius.circular(
                suggestion.runes.length > 18 ? 16 : YanciTheme.radiusPill,
              ),
              onTap: _sending ? null : () => unawaited(_send(suggestion)),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: YanciTheme.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(
                    suggestion.runes.length > 18 ? 16 : YanciTheme.radiusPill,
                  ),
                  border: Border.all(
                    color: YanciTheme.accent.withValues(alpha: 0.20),
                    width: 0.6,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  suggestion,
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.accent,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDraftCard(GuidePersonaDraft draft) {
    final metadata = <String>[
      draft.gender,
      draft.race,
      draft.age,
      draft.relationship,
    ].where((value) => value.trim().isNotEmpty).join(' · ');
    return Semantics(
      button: true,
      label: L.pick(
        en: 'Review character proposal',
        zhTW: '審核人設卡提案',
        zhCN: '审核人设卡提案',
      ),
      child: InkWell(
        onTap: () => _reviewDraft(draft),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: YanciTheme.accent.withValues(alpha: .22)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.auto_awesome_outlined, color: YanciTheme.accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      L.pick(
                        en: 'This is who I am now:',
                        zhTW: '現在的我是這樣：',
                        zhCN: '现在的我是这样：',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      draft.name,
                      style: YanciTheme.bodyText.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (metadata.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        metadata,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                    ],
                    if (draft.description.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        draft.description.trim(),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall.copyWith(height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 7),
                    Text(
                      L.pick(
                        en: 'Tap to edit and confirm',
                        zhTW: '點擊編輯與確認',
                        zhCN: '点击编辑与确认',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: YanciTheme.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        max(10, MediaQuery.paddingOf(context).bottom),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _sending
                        ? null
                        : _personaWorkshopActive
                        ? _requestPersonaDraft
                        : _beginPersonaWorkshop,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: YanciTheme.accent,
                    ),
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: Text(
                        _personaWorkshopActive
                            ? L.pick(
                                en: 'Write my character card',
                                zhTW: '幫我寫好人設卡',
                                zhCN: '帮我写好人设卡',
                              )
                            : L.pick(
                                en: 'Plan a new RP character',
                                zhTW: '聊聊新 RP 劇本人設',
                                zhCN: '聊聊新 RP 剧本人设',
                              ),
                        key: ValueKey<bool>(_personaWorkshopActive),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _GuideModePill(
                value: _replyMode,
                onChanged: (value) {
                  setState(() => _replyMode = value);
                  if (value == _GuideReplyMode.api && _selectedModel == null) {
                    _showNeedFavoriteModel();
                  }
                },
              ),
            ],
          ),
          if (_hasRecentError) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 4,
                runSpacing: 0,
                children: [
                  TextButton.icon(
                    onPressed: _showErrorEmailDraft,
                    icon: const Icon(Icons.mail_outline_rounded, size: 16),
                    label: Text(
                      L.pick(
                        en: 'Draft error report',
                        zhTW: '幫我擬錯誤郵件',
                        zhCN: '帮我拟错误邮件',
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: YanciTheme.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _exportErrorLog,
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: Text(
                      L.pick(en: 'Export log', zhTW: '匯出日誌', zhCN: '导出日志'),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: YanciTheme.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: YanciTheme.glassInputBg.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: YanciTheme.glassBorder, width: .5),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          enabled: !_sending,
                          minLines: 1,
                          maxLines: 4,
                          textAlignVertical: TextAlignVertical.center,
                          textInputAction: TextInputAction.newline,
                          style: YanciTheme.bodyText,
                          decoration: InputDecoration(
                            hintText: L.pick(
                              en: 'Ask or brainstorm anything…',
                              zhTW: '問問題，或一起聊聊想法…',
                              zhCN: '问问题，或一起聊聊想法…',
                            ),
                            hintStyle: YanciTheme.bodyText.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: .46,
                              ),
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.fromLTRB(
                              12,
                              8,
                              8,
                              8,
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Semantics(
                          button: true,
                          label: L.pick(en: 'Send', zhTW: '發送', zhCN: '发送'),
                          child: IconButton(
                            onPressed: _sending ? null : _send,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 48,
                              height: 48,
                            ),
                            icon: _sending
                                ? SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: YanciTheme.accent,
                                    ),
                                  )
                                : Icon(
                                    Icons.arrow_upward_rounded,
                                    color: YanciTheme.accent,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_replyMode == _GuideReplyMode.api) ...<Widget>[
            const SizedBox(height: 5),
            Row(
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _showModelPicker,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        foregroundColor: YanciTheme.accent,
                      ),
                      icon: const Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 17,
                      ),
                      label: Text(
                        _selectedModel == null
                            ? L.pick(
                                en: 'Favorite a model first',
                                zhTW: '先去收藏喜歡的模型喔～',
                                zhCN: '先去收藏喜欢的模型哦～',
                              )
                            : '${_providerLabel(_selectedModel!.provider)} · '
                                  '${_selectedModel!.modelId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  L.pick(
                    en: 'Uses API credit',
                    zhTW: '將產生 API 費用',
                    zhCN: '将产生 API 费用',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 10.5,
                    color: YanciTheme.textSecondary.withValues(alpha: .58),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

enum _GuideReferenceKind { character, storyline }

class _GuideReferenceOption {
  const _GuideReferenceOption._({
    required this.kind,
    required this.characterId,
    required this.title,
    this.subtitle = '',
    this.storylineId,
    this.character,
  });

  factory _GuideReferenceOption.character({
    required String characterId,
    required String title,
    required Map<String, dynamic> character,
  }) => _GuideReferenceOption._(
    kind: _GuideReferenceKind.character,
    characterId: characterId,
    title: title,
    character: character,
  );

  factory _GuideReferenceOption.storyline({
    required String characterId,
    required String storylineId,
    required String title,
    required String subtitle,
  }) => _GuideReferenceOption._(
    kind: _GuideReferenceKind.storyline,
    characterId: characterId,
    storylineId: storylineId,
    title: title,
    subtitle: subtitle,
  );

  final _GuideReferenceKind kind;
  final String characterId;
  final String title;
  final String subtitle;
  final String? storylineId;
  final Map<String, dynamic>? character;

  String get key => kind == _GuideReferenceKind.character
      ? 'character:$characterId'
      : 'storyline:$characterId:${storylineId ?? ''}';
}

class _GuideModePill extends StatelessWidget {
  const _GuideModePill({required this.value, required this.onChanged});

  final _GuideReplyMode value;
  final ValueChanged<_GuideReplyMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: 150,
      height: 30,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: YanciTheme.glassInputBg.withValues(alpha: .74),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: YanciTheme.glassBorder.withValues(alpha: .72),
            width: .5,
          ),
        ),
        child: Stack(
          children: <Widget>[
            AnimatedAlign(
              alignment: value == _GuideReplyMode.system
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              child: FractionallySizedBox(
                widthFactor: .5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                for (final mode in _GuideReplyMode.values)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => onChanged(mode),
                      child: Center(
                        child: Text(
                          mode == _GuideReplyMode.system
                              ? L.pick(en: 'System', zhTW: '系統回覆', zhCN: '系统回复')
                              : L.pick(
                                  en: 'API',
                                  zhTW: '調用 API',
                                  zhCN: '调用 API',
                                ),
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 11,
                            fontWeight: mode == value
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: mode == value
                                ? YanciTheme.accent
                                : YanciTheme.textSecondary,
                          ),
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
  }
}

class _GuideDraftEditor extends StatefulWidget {
  const _GuideDraftEditor({required this.draft});

  final GuidePersonaDraft draft;

  @override
  State<_GuideDraftEditor> createState() => _GuideDraftEditorState();
}

class _GuideDraftEditorState extends State<_GuideDraftEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.draft.name,
  );
  late final TextEditingController _gender = TextEditingController(
    text: widget.draft.gender,
  );
  late final TextEditingController _relationship = TextEditingController(
    text: widget.draft.relationship,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.draft.description,
  );
  late final TextEditingController _race = TextEditingController(
    text: widget.draft.race,
  );
  late final TextEditingController _skill = TextEditingController(
    text: widget.draft.skill,
  );
  late final TextEditingController _age = TextEditingController(
    text: widget.draft.age,
  );
  late final TextEditingController _height = TextEditingController(
    text: widget.draft.height,
  );

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _gender,
      _relationship,
      _description,
      _race,
      _skill,
      _age,
      _height,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        minLines: lines,
        maxLines: lines == 1 ? 1 : 6,
        style: YanciTheme.bodyText,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Material(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L.pick(
                    en: 'This is who I am now',
                    zhTW: '現在的我是這樣',
                    zhCN: '现在的我是这样',
                  ),
                  style: YanciTheme.headingMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  L.pick(
                    en: 'Review and edit it. Nothing is created until you confirm.',
                    zhTW: '先檢查、修改；確認後才會正式建立角色。',
                    zhCN: '先检查、修改；确认后才会正式建立角色。',
                  ),
                  textAlign: TextAlign.center,
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                _field(L.pick(en: 'Name', zhTW: '名字', zhCN: '名字'), _name),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _field(
                        L.pick(en: 'Gender', zhTW: '性別', zhCN: '性别'),
                        _gender,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        L.pick(en: 'Relationship', zhTW: '關係', zhCN: '关系'),
                        _relationship,
                      ),
                    ),
                  ],
                ),
                _field(
                  L.pick(
                    en: 'Character description',
                    zhTW: '角色描述',
                    zhCN: '角色描述',
                  ),
                  _description,
                  lines: 4,
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _field(
                        L.pick(en: 'Race', zhTW: '種族', zhCN: '种族'),
                        _race,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        L.pick(en: 'Age', zhTW: '年齡', zhCN: '年龄'),
                        _age,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _field(
                        L.pick(en: 'Skills', zhTW: '技能', zhCN: '技能'),
                        _skill,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        L.pick(en: 'Height', zhTW: '身高', zhCN: '身高'),
                        _height,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: YanciTheme.accent,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () {
                    if (_name.text.trim().isEmpty) return;
                    Navigator.of(context).pop(
                      GuidePersonaDraft(
                        name: _name.text.trim(),
                        gender: _gender.text.trim(),
                        relationship: _relationship.text.trim(),
                        description: _description.text.trim(),
                        race: _race.text.trim(),
                        skill: _skill.text.trim(),
                        age: _age.text.trim(),
                        height: _height.text.trim(),
                      ),
                    );
                  },
                  child: Text(
                    L.pick(en: 'Create character', zhTW: '建立角色', zhCN: '建立角色'),
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
