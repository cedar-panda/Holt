part of 'chat_screen.dart';

extension _ChatReplyVariantMethods on _ChatScreenState {
  Future<void> _resendEditedUserMessage(int index, String text) =>
      _runMessageRetry(() async {
        final source = _messages[index];
        if (!source.isUser || source.id == null) return;
        _invalidateGenerationState();
        final edited = await ReplyVariants.prepareUserResend(source.id!, text);
        if (!mounted || edited == null) return;
        final deletedIds = _messages
            .skip(index + 1)
            .map((message) => message.id)
            .whereType<int>()
            .toSet();
        final anchors = await DatabaseHelper.getSummaryRecordedAnchors(
          widget.conversationId,
        );
        if (!mounted) return;
        _refreshChatState(() {
          _messages.removeRange(index + 1, _messages.length);
          _messages[index] = edited;
          for (final id in deletedIds) {
            _scratchDataMap.remove('msg_$id');
            _transferDataMap.remove('msg_$id');
            _webSearchResultsByMessageId.remove(id);
          }
          _chatDiagnostics.removeWhere(
            (event) =>
                event.sourceMessageId == source.id ||
                deletedIds.contains(event.sourceMessageId) ||
                deletedIds.contains(event.anchorMessageId),
          );
          _summaryRecordedSummaryIds
            ..clear()
            ..addAll(anchors);
          _cacheHitIndices
            ..clear()
            ..addAll([
              for (var i = 0; i < _messages.length; i++)
                if (_messages[i].cacheHit) i,
            ]);
        });
        await _refreshPendingMemoryActionCounts();
        await _restoreTokensSinceSummary();
        // 圖片沿用 retryUserMessage.imagePaths，文字／圖片同一條路徑。
        await _sendMessageLocked(
          edited.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: edited,
        );
      });

  Future<void> _selectReplyVariant(int messageId, int archiveId) =>
      _runMessageRetry(() async {
        final replacement = await ReplyVariants.select(messageId, archiveId);
        if (!mounted || replacement == null) return;
        final index = _messages.indexWhere(
          (message) => message.id == messageId,
        );
        if (index < 0) return;
        // Restore the user prompt alongside the chosen AI version.
        final userIndex = _messages.lastIndexWhere((message) => message.isUser);
        final prompt = userIndex < 0 || _messages[userIndex].id == null
            ? null
            : await DatabaseHelper.getMessageById(_messages[userIndex].id!);
        final anchors = await DatabaseHelper.getSummaryRecordedAnchors(
          widget.conversationId,
        );
        if (!mounted) return;
        _refreshChatState(() {
          _messages[index] = replacement;
          if (prompt != null) _messages[userIndex] = prompt;
          _scratchDataMap.remove('msg_$messageId');
          _transferDataMap.remove('msg_$messageId');
          _webSearchResultsByMessageId.remove(messageId);
          _summaryRecordedSummaryIds
            ..clear()
            ..addAll(anchors);
          _cacheHitIndices
            ..clear()
            ..addAll([
              for (var i = 0; i < _messages.length; i++)
                if (_messages[i].cacheHit) i,
            ]);
        });
        await _refreshPendingMemoryActionCounts();
        await _restoreTokensSinceSummary();
      });
}
