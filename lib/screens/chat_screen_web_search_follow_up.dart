part of 'chat_screen.dart';

extension _ChatScreenWebSearchFollowUp on _ChatScreenState {
  Future<String> _generateWebSearchFollowUp({
    required WebSearchBatchResult result,
    required List<Map<String, String>> history,
    required ApiAdapter adapter,
    required String model,
    required StructuredPrompt structuredPrompt,
    required String providerName,
    required int generationSerial,
  }) async {
    final evidence = WebSearchFollowUp.evidenceFor(result);
    if (evidence == null || evidence.isEmpty) return '';
    final fallback = WebSearchFollowUp.fallbackReply(result);
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
          ephemeralEvidencePart: evidence,
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
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        usage: usage,
        characterId: _activeCharacterId,
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
