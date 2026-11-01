// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatFailureRetryMethods on _ChatScreenState {
  void _clearComposerIfUnchanged(String submittedDraft) {
    if (_inputController.text.trim() == submittedDraft.trim()) {
      _inputController.clear();
    }
  }

  void _finishFailedGeneration() {
    final adapter = _activeGenerationAdapter;
    _activeGenerationAdapter = null;
    adapter?.cancelActive();
    _toolRunner.cancelActive(reason: 'Generation failed.');
    MemoryActions.clearSearchQuery(widget.conversationId);
    if (mounted) {
      _refreshChatState(() {
        _clearStreamQueue();
        _setGenerating(false);
        _chatSearching = false;
        _chatSearchQuery = '';
        _chatSearchResults = [];
        _webSearchActivity = null;
        _pendingWebSearchResult = null;
        _pendingWebSearchFailureContext = '';
      });
    } else {
      _clearStreamQueue();
      _setGenerating(false);
      _chatSearching = false;
      _chatSearchQuery = '';
      _chatSearchResults = [];
      _webSearchActivity = null;
      _pendingWebSearchResult = null;
      _pendingWebSearchFailureContext = '';
    }
  }

  String _cleanIncompleteReply(String raw) {
    return VisibleModelOutput.streaming(
      MemoryActions.stripReply(raw, windowId: widget.conversationId),
      thinkingEnabled:
          _activeRequestThinkingEnabled ?? _generationThinkingEnabled,
    );
  }

  Future<Message?> _persistIncompleteReply(String raw) async {
    final text = _cleanIncompleteReply(raw);
    if (text.isEmpty) return null;
    final pending = Message(
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: text,
      isUser: false,
      splitMode: _splitReply,
      status: Message.statusIncomplete,
    );
    final id = await DatabaseHelper.insertMessage(pending);
    final saved = Message(
      id: id,
      conversationId: pending.conversationId,
      characterId: pending.characterId,
      text: pending.text,
      isUser: false,
      splitMode: pending.splitMode,
      status: pending.status,
      createdAt: pending.createdAt,
    );
    if (mounted) _refreshChatState(() => _messages.add(saved));
    return saved;
  }

  Future<void> _retryIncompleteMessage(int incompleteId) {
    return _runMessageRetry(() async {
      final index = _messages.indexWhere((m) => m.id == incompleteId);
      // 只重試最末一條半段回覆；若後面已有新對話，保留它作正常歷史，
      // 避免從中段抽走消息造成前綴突變。
      if (index < 1 || index != _messages.length - 1) return;
      final incomplete = _messages[index];
      if (!incomplete.isIncomplete) return;
      Message? userMessage;
      for (var i = index - 1; i >= 0; i--) {
        if (_messages[i].isUser) {
          userMessage = _messages[i];
          break;
        }
      }
      if (userMessage == null) return;

      await DatabaseHelper.deleteMessageById(
        incompleteId,
        reason: 'retry_incomplete',
      );
      if (!mounted) return;
      _refreshChatState(() => _messages.removeAt(index));
      _scratchDataMap.remove('msg_$incompleteId');
      _transferDataMap.remove('msg_$incompleteId');
      _webSearchResultsByMessageId.remove(incompleteId);
      await _refreshPendingMemoryActionCounts();
      // 圖片沿用 retryUserMessage.imagePaths，文字／圖片同一條路徑。
      await _sendMessageLocked(
        userMessage.text,
        composerDraft: '',
        clearComposerOnAccept: false,
        retryUserMessage: userMessage,
      );
    });
  }

  Future<void> _persistApiFailure(
    Object error, {
    required int sourceMessageId,
    int? anchorMessageId,
    String? provider,
    String? model,
  }) async {
    debugPrint('[API request failed] $error');
    final diagnosis = ApiErrorLocalizer.diagnose(error);
    final resolvedProvider = provider ?? await ApiSettings.getApiProvider();
    final resolvedModel = model ?? await ApiSettings.getModel();
    await AppErrorLogService.recordDiagnosis(
      diagnosis: diagnosis,
      trigger: 'chat_api_request',
      source: 'chat',
      provider: _chatModelProviderLabel(resolvedProvider),
      model: resolvedModel,
    );
    final saved = await DatabaseHelper.upsertChatDiagnostic(
      ChatDiagnosticEvent(
        conversationId: widget.conversationId,
        sourceMessageId: sourceMessageId,
        anchorMessageId: anchorMessageId ?? sourceMessageId,
        category: diagnosis.category,
        statusCode: diagnosis.statusCode,
        provider:
            diagnosis.provider ?? _chatModelProviderLabel(resolvedProvider),
        model: resolvedModel,
        rawLog: diagnosis.rawLog,
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    _refreshChatState(() {
      _chatDiagnostics.removeWhere(
        (event) => event.sourceMessageId == sourceMessageId,
      );
      _chatDiagnostics.add(saved);
    });
    _scrollToBottom();
  }

  Future<void> _clearChatDiagnosticForSource(int sourceMessageId) async {
    await DatabaseHelper.deleteChatDiagnosticsForMessages(<int>[
      sourceMessageId,
    ]);
    if (!mounted) return;
    _refreshChatState(
      () => _chatDiagnostics.removeWhere(
        (event) => event.sourceMessageId == sourceMessageId,
      ),
    );
  }

  Future<void> _retryChatDiagnostic(ChatDiagnosticEvent event) async {
    final id = event.id;
    if (id != null) await DatabaseHelper.deleteChatDiagnostic(id);
    if (mounted) {
      _refreshChatState(
        () => _chatDiagnostics.removeWhere((item) => item.id == id),
      );
    }

    if (event.anchorMessageId != event.sourceMessageId) {
      final anchor = await DatabaseHelper.getMessageById(event.anchorMessageId);
      if (anchor?.isIncomplete == true && anchor!.id != null) {
        await _retryIncompleteMessage(anchor.id!);
        return;
      }
    }

    final source = await DatabaseHelper.getMessageById(event.sourceMessageId);
    if (source == null || !source.isUser) return;
    await _runMessageRetry(() async {
      // 圖片沿用 retryUserMessage.imagePaths，文字／圖片同一條路徑。
      await _sendMessageLocked(
        source.text,
        composerDraft: '',
        clearComposerOnAccept: false,
        retryUserMessage: source,
      );
    }, sourceMessageId: source.id);
  }

  Future<void> _runMessageRetry(
    Future<void> Function() retry, {
    int? sourceMessageId,
  }) async {
    if (!_isChatReady ||
        _sendSubmissionInProgress ||
        _isGenerating ||
        _isGeneratingImage) {
      if (mounted) {
        _showChatNotice(
          L.pick(
            en: 'The current reply is still finishing. Please try again in a moment.',
            zhTW: '目前回覆仍在收尾，請稍候再重新發送。',
            zhCN: '当前回复仍在收尾，请稍候再重新发送。',
          ),
        );
      }
      return;
    }
    if (mounted) {
      _refreshChatState(() => _sendSubmissionInProgress = true);
    } else {
      _sendSubmissionInProgress = true;
    }
    final generationSerialBefore = _generationSerial;
    try {
      await retry();
    } catch (error) {
      await _recoverEscapedGenerationFailure(
        error,
        generationSerialBefore: generationSerialBefore,
        sourceMessageId: sourceMessageId,
      );
    } finally {
      if (mounted) {
        _refreshChatState(() => _sendSubmissionInProgress = false);
      } else {
        _sendSubmissionInProgress = false;
      }
    }
  }

  Future<void> _recoverEscapedGenerationFailure(
    Object error, {
    required int generationSerialBefore,
    int? sourceMessageId,
  }) async {
    // A send either fails before _beginGeneration or during that one new
    // generation. If the serial moved further, edit/stop/dispose already
    // invalidated this work and it must not reset a newer turn.
    final serialDelta = _generationSerial - generationSerialBefore;
    if (serialDelta < 0 || serialDelta > 1) return;
    final wasStopped = _stopGenerationRequested;
    _finishFailedGeneration();
    if (!wasStopped && sourceMessageId != null) {
      await _persistApiFailure(error, sourceMessageId: sourceMessageId);
    }
  }
}
