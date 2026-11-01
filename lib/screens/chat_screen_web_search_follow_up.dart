part of 'chat_screen.dart';

extension _ChatScreenWebSearchFollowUp on _ChatScreenState {
  Future<String> _generateWebSearchFollowUp({
    required WebSearchBatchResult? result,
    String failureContext = '',
    required List<Map<String, String>> history,
    required ApiAdapter adapter,
    required String model,
    required StructuredPrompt structuredPrompt,
    required String providerName,
    required int generationSerial,
  }) async {
    final evidence = result == null
        ? null
        : WebSearchFollowUp.evidenceFor(result);
    final resolvedFailureContext = failureContext.isNotEmpty
        ? failureContext
        : result == null
        ? ''
        : WebSearchFollowUp.failureContextFor(result) ?? '';
    if ((evidence == null || evidence.isEmpty) &&
        resolvedFailureContext.isEmpty) {
      return '';
    }
    if (WebSearchFollowUp.hasNoVerifiedEvidence(
      result: result,
      failureContext: resolvedFailureContext,
    )) {
      return L.pick(
        en: 'I could not find reliable results just now. Let us try again later.',
        zhTW: '剛才沒有查到可靠的結果，晚一點再試試吧。',
        zhCN: '刚才没有查到可靠的结果，晚一点再试试吧。',
      );
    }
    final fallback = result == null
        ? ''
        : WebSearchFollowUp.fallbackReply(result);
    if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
      return '';
    }

    if (mounted) {
      _refreshChatState(() {
        _clearStreamQueue();
        _streamingText = '';
      });
    } else {
      _clearStreamQueue();
      _streamingText = '';
    }

    final buffer = StringBuffer();
    var usage = const ApiUsage();
    try {
      await for (final chunk in adapter.sendMessageStream(
        messages: history,
        model: model,
        structuredPrompt: structuredPrompt.copyWith(
          liveStatePart: SystemContextMarkdown.join(<String>[
            structuredPrompt.liveStatePart,
            resolvedFailureContext,
          ]),
          ephemeralEvidencePart: evidence ?? '',
        ),
        onUsage: (value) => usage = value,
      )) {
        if (!_isCurrentGeneration(generationSerial) ||
            _stopGenerationRequested) {
          return '';
        }
        buffer.write(chunk);
        if (mounted) _onStreamChunk(chunk);
      }
      if (mounted) _closeModelStreamInput();
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        usage: usage,
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
        requestKind: ApiRequestKind.chat,
      );
      final reply = WebSearchFollowUp.sanitizeReply(buffer.toString());
      return reply.isEmpty ? fallback : reply;
    } catch (_) {
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        return '';
      }
      return fallback;
    }
  }
}
