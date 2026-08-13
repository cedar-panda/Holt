part of 'chat_screen.dart';

extension _ChatEmailDraftMethods on _ChatScreenState {
  Future<void> _editEmailDraft(int messageId, EmailDraft current) async {
    final edited = await showEmailDraftEditor(context, current);
    if (edited == null || edited == current) return;
    try {
      await EmailDraftRepository.saveForMessage(messageId, edited);
      if (!mounted) return;
      _replaceEmailDraftInState(messageId, edited);
    } catch (_) {
      if (mounted) _showEmailDraftFailure();
    }
  }

  Future<void> _deleteEmailDraft(int messageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          L.pick(en: 'Delete this draft?', zhTW: '刪除這份草稿？', zhCN: '删除这份草稿？'),
        ),
        content: Text(
          L.pick(
            en: 'The chat reply stays. Only the local email draft is removed.',
            zhTW: '聊天回覆會保留，只移除這份本機郵件草稿。',
            zhCN: '聊天回复会保留，只移除这份本机邮件草稿。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await EmailDraftRepository.saveForMessage(messageId, null);
      if (!mounted) return;
      _replaceEmailDraftInState(messageId, null);
    } catch (_) {
      if (mounted) _showEmailDraftFailure();
    }
  }

  Future<void> _openEmailDraft(EmailDraft draft) async {
    final opened = await EmailDraftLauncher.open(draft);
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'No email app could open this draft.',
            zhTW: '找不到可打開這份草稿的郵件 App。',
            zhCN: '找不到可打开这份草稿的邮件 App。',
          ),
        ),
      ),
    );
  }

  void _replaceEmailDraftInState(int messageId, EmailDraft? draft) {
    _refreshChatState(() {
      for (var index = 0; index < _messages.length; index++) {
        if (_messages[index].id == messageId) {
          _messages[index] = _copyMessageWithEmailDraft(
            _messages[index],
            draft,
          );
        }
      }
      for (var index = 0; index < _olderMessages.length; index++) {
        if (_olderMessages[index].id == messageId) {
          _olderMessages[index] = _copyMessageWithEmailDraft(
            _olderMessages[index],
            draft,
          );
        }
      }
    });
  }

  Message _copyMessageWithEmailDraft(Message message, EmailDraft? draft) {
    return Message(
      id: message.id,
      conversationId: message.conversationId,
      characterId: message.characterId,
      text: message.text,
      isUser: message.isUser,
      imagePath: message.imagePath,
      splitMode: message.splitMode,
      cacheHit: message.cacheHit,
      status: message.status,
      memoryLog: message.memoryLog,
      webSearchTrace: message.webSearchTrace,
      emailDraft: draft,
      createdAt: message.createdAt,
    );
  }

  void _showEmailDraftFailure() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Could not update the local draft.',
            zhTW: '無法更新本機草稿。',
            zhCN: '无法更新本机草稿。',
          ),
        ),
      ),
    );
  }
}
