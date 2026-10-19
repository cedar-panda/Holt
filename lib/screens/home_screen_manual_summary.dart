// ignore_for_file: invalid_use_of_protected_member

part of 'home_screen.dart';

extension _HomeManualSummaryMethods on _HomeScreenState {
  Future<void> _showManualSummaryOptions() async {
    final convId = _keepAliveConvId;
    if (convId == null) return;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: YanciTheme.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.subject_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Summarize all messages', zhTW: '摘要全部聊天'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Summarize every message in this window',
                    zhTW: '摘要目前窗口的全部消息',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('all'),
              ),
              ListTile(
                leading: Icon(
                  Icons.checklist_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Select messages', zhTW: '選擇消息摘要'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Select user and character bubbles in the chat',
                    zhTW: '進聊天窗口勾選 user / char 氣泡',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('selected'),
              ),
              ListTile(
                leading: Icon(
                  Icons.library_books_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Character memory summaries', zhTW: '角色記憶摘要'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Open summaries for the current character',
                    zhTW: '打開目前角色的記憶摘要頁',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('memory_summary'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;

    if (choice == 'all') {
      await _confirmManualSummaryAll(convId);
    } else if (choice == 'selected') {
      await _pushChatRoute(
        arguments: {'conversationId': convId, 'manualSummarySelection': true},
        restoreCharacterId: _activeCharacterId,
      );
      await _refreshAfterChatReturn();
    } else if (choice == 'memory_summary') {
      await _openMemorySummaryShortcut(convId);
    }
  }

  Future<void> _openMemorySummaryShortcut(String convId) async {
    final conv = await DatabaseHelper.getConversation(convId);
    if (!mounted) return;
    await Navigator.pushNamed(
      context,
      '/memory',
      arguments: {
        'characterId': conv?.characterId ?? _activeCharacterId,
        'initialTab': 2,
      },
    );
  }

  Future<void> _confirmManualSummaryAll(String convId) async {
    final messages = await DatabaseHelper.getMessages(convId);
    final estimatedTokens = messages.fold<int>(
      0,
      (total, message) => total + TokenEstimator.estimate(message.text),
    );
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Summarize all messages', zhTW: '摘要全部聊天'),
          style: TextStyle(color: YanciTheme.textPrimary),
        ),
        content: Text(
          L.pick(
            en:
                'This window contains approximately $estimatedTokens message tokens. '
                'Summarize every message without changing chat content or automatic summaries.',
            zhTW:
                '目前窗口約有 $estimatedTokens tokens。會摘要全部消息，'
                '不會改動聊天內容，也不影響自動摘要。',
            zhCN:
                '当前窗口约有 $estimatedTokens tokens。将摘要全部消息，'
                '不会改动聊天内容，也不影响自动摘要。',
          ),
          style: TextStyle(color: YanciTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Start', zhTW: '開始摘要')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runManualSummaryAll(convId, messages: messages);
  }

  Future<void> _runManualSummaryAll(
    String convId, {
    List<Message>? messages,
  }) async {
    final conv = await DatabaseHelper.getConversation(convId);
    final characterId = conv?.characterId ?? _activeCharacterId;
    final title = conv?.title ?? _keepAliveConvTitle ?? '';
    final sourceMessages = messages ?? await DatabaseHelper.getMessages(convId);
    if (!mounted) return;
    if (sourceMessages.isEmpty) {
      _showSnack(
        L.pick(en: 'There is no chat content to summarize', zhTW: '沒有可摘要的聊天內容'),
      );
      return;
    }

    showThemedPillNotice(
      context,
      L.pick(en: 'Creating summary…', zhTW: '正在整理摘要……', zhCN: '正在整理摘要……'),
    );

    try {
      await ManualSummaryService.summarizeMessages(
        conversationId: convId,
        characterId: characterId,
        messages: sourceMessages,
      );
      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Manual summary completed.',
          zhTW: '手動摘要已完成',
          zhCN: '手动摘要已完成',
        ),
      );
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      _showManualSummaryFailureSnack(
        convId: convId,
        characterId: characterId,
        title: title,
        excerpt: e.excerpt,
      );
    } catch (e) {
      await AppErrorLogService.record(
        error: e,
        trigger: 'functional_summary_model_request',
        source: 'functional_model',
      );
      if (!mounted) return;
      showThemedPillNotice(
        context,
        '${L.pick(en: 'Summary failed', zhTW: '摘要失敗', zhCN: '摘要失败')}：$e',
        tone: ThemedNoticeTone.error,
      );
    }
  }

  void _showManualSummaryFailureSnack({
    required String convId,
    required String characterId,
    required String title,
    required String excerpt,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Summary failed. Please edit it manually.',
            zhTW: '摘要失敗，請手動摘要。',
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
        action: SnackBarAction(
          label: L.pick(en: 'Edit', zhTW: '編輯'),
          textColor: Colors.white,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ManualSummaryCleanScreen(
                  conversationId: convId,
                  characterId: characterId,
                  title: title,
                  initialExcerpt: excerpt,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
      ),
    );
  }

  Widget _buildHeartbeatLine() {
    return AnimatedBuilder(
      animation: _ecgController,
      builder: (context, _) {
        return CustomPaint(
          painter: _EcgPainter(
            progress: _ecgController.value,
            color: YanciTheme.ecgGlow,
            glowColor: YanciTheme.accentGlow,
            lineColor: YanciTheme.ecgLine,
            headColor: YanciTheme.ecgHead,
          ),
          size: Size.infinite,
        );
      },
    );
  }

  Widget _buildPulsingDot() {
    return AnimatedBuilder(
      animation: _ecgController,
      builder: (context, _) {
        final beat = sin(_ecgController.value * 2 * 3.14159 * 2);
        final scale = 1.0 + beat.abs() * 0.4;
        final opacity = 0.35 + beat.abs() * 0.35;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  YanciTheme.accent.withValues(alpha: opacity * 0.7),
                  YanciTheme.accent.withValues(alpha: opacity * 0.25),
                  YanciTheme.accent.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: YanciTheme.accent.withValues(alpha: opacity * 0.5),
                  blurRadius: 25,
                  spreadRadius: 6,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
