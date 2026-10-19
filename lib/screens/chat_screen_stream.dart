// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatStreamMethods on _ChatScreenState {
  void _setGenerating(bool v) {
    if (_isGenerating == v) return;
    _isGenerating = v;
    if (v) {
      _visibleReplyComplete = false;
      _streamRevealDelayTimer?.cancel();
      _streamRevealTimer?.cancel();
      _streamRevealDelayTimer = null;
      _streamRevealTimer = null;
      _streamFirstChunkAt = null;
      _streamSurfaceDelayTimer?.cancel();
      _streamSurfaceVisible = false;
      // Let the sent user bubble settle before revealing the assistant
      // avatar/bubble. The stream queue keeps incoming chunks meanwhile.
      // Give the outgoing user bubble a little more breathing room before
      // the character/avatar surface appears.
      final delay = 360 + _streamSurfaceRandom.nextInt(260);
      _streamSurfaceDelayTimer = Timer(Duration(milliseconds: delay), () {
        if (!mounted || !_isGenerating) return;
        _streamSurfaceVisible = true;
        _refreshChatState(() {});
        _scrollToBottom();
        _scheduleStreamDrain();
      });
      _generationForegroundEndTimer?.cancel();
      _generationForegroundStartTimer?.cancel();
      // Starting the Android foreground isolate is expensive. Let the IME and
      // outgoing-bubble transition finish before doing that work.
      _generationForegroundStartTimer = Timer(
        const Duration(milliseconds: 600),
        () {
          if (_isGenerating) unawaited(GenerationForegroundGuard.begin());
        },
      );
    } else {
      _streamSurfaceDelayTimer?.cancel();
      _streamSurfaceVisible = false;
      _generationForegroundStartTimer?.cancel();
      _generationForegroundEndTimer?.cancel();
      // Likewise, do not tear down the service in the same frame that inserts
      // the completed assistant bubble.
      _generationForegroundEndTimer = Timer(
        const Duration(milliseconds: 220),
        () => unawaited(GenerationForegroundGuard.end()),
      );
    }
  }

  void _onStreamChunk(String chunk) {
    if (!mounted || chunk.isEmpty) return;
    final visibleChunk = _modelStreamDecoder.add(chunk);
    if (visibleChunk.isEmpty) return;
    _streamFirstChunkAt ??= DateTime.now();
    _streamCharQueue.addAll(visibleChunk.characters);
    _scheduleStreamDrain();
  }

  void _closeModelStreamInput() {
    final visibleTail = _modelStreamDecoder.close();
    if (visibleTail.isNotEmpty) {
      _streamCharQueue.addAll(visibleTail.characters);
      _scheduleStreamDrain();
    }
  }

  void _scheduleStreamDrain() {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) {
      // Receive/persist in background without character animation or scrolling.
      _streamingText += _streamCharQueue.join();
      _streamCharQueue.clear();
      return;
    }
    if (!_streamSurfaceVisible) return;
    if (_streamCharQueue.isEmpty || _streamRevealTimer != null) return;

    // Native providers use half of the relay reading buffer. Both still reveal
    // from a character queue, preventing provider-sized chunks from appearing
    // as visible paragraphs.
    final firstChunkAt = _streamFirstChunkAt ?? DateTime.now();
    final remainingDelay =
        StreamPresentationPolicy.initialDelay(_streamPresentationMode) -
        DateTime.now().difference(firstChunkAt);
    if (remainingDelay > Duration.zero) {
      if (_streamRevealDelayTimer == null ||
          !_streamRevealDelayTimer!.isActive) {
        _streamRevealDelayTimer = Timer(remainingDelay, () {
          _streamRevealDelayTimer = null;
          _scheduleStreamDrain();
        });
      }
      return;
    }
    _streamRevealTimer = Timer.periodic(
      StreamPresentationPolicy.characterInterval(_streamPresentationMode),
      (_) => _revealOneStreamCharacter(),
    );
  }

  void _revealOneStreamCharacter() {
    if (!mounted || !_isGenerating || !_streamSurfaceVisible) {
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
      return;
    }
    if (_streamCharQueue.isEmpty) {
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
      return;
    }

    _streamingText += _streamCharQueue.removeFirst();
    // Keep the same avatar + Thinking surface between search completion and
    // the first streamed response. Remove it with the first visible character
    // so the generic atom loader never flashes over the reply.
    if (_webSearchActivity?.status == WebSearchActivityStatus.completed ||
        _webSearchActivity?.status == WebSearchActivityStatus.failed) {
      _webSearchActivity = null;
    }
    _streamRevision.value++;
    _scheduleStreamScrollFollow();
    if (_streamCharQueue.isEmpty) {
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
    }
  }

  void _clearStreamQueue() {
    _streamRevealDelayTimer?.cancel();
    _streamRevealTimer?.cancel();
    _streamRevealDelayTimer = null;
    _streamRevealTimer = null;
    _streamFirstChunkAt = null;
    _streamCharQueue.clear();
    _modelStreamDecoder.reset();
    _streamingText = '';
    _visibleReplyComplete = false;
  }

  Future<void> _finishStreamPresentation() async {
    if (_streamCharQueue.isEmpty) return;
    _scheduleStreamDrain();
    while (mounted &&
        _isGenerating &&
        !_stopGenerationRequested &&
        _streamCharQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 32));
      _scheduleStreamDrain();
    }
  }

  Future<void> _markVisibleReplyComplete() async {
    _closeModelStreamInput();
    await _finishStreamPresentation();
    if (!mounted || _visibleReplyComplete) return;
    _visibleReplyComplete = true;
    _streamRevision.value++;
  }

  void _configureStreamPresentation(String provider) {
    _streamPresentationMode = StreamPresentationPolicy.forProvider(provider);
  }

  String _computeDisplayStreamingText() {
    return VisibleModelOutput.streaming(
      _streamingText,
      thinkingEnabled:
          _activeRequestThinkingEnabled ?? _generationThinkingEnabled,
    );
  }

  int _beginGeneration() {
    _stopGenerationRequested = false;
    _webSearchActivity = null;
    _pendingWebSearchResult = null;
    _pendingWebSearchFailureContext = '';
    return ++_generationSerial;
  }

  void _releaseSubmissionLockAfterAcceptance() {
    if (!_sendSubmissionInProgress) return;
    if (mounted) {
      _refreshChatState(() => _sendSubmissionInProgress = false);
    } else {
      _sendSubmissionInProgress = false;
    }
  }

  bool _isCurrentGeneration(int serial) => serial == _generationSerial;

  Future<void> _stopKeepAliveBeforeFirstMessage() async {
    try {
      await KeepAliveService.instance.stop().timeout(
        const Duration(seconds: 5),
      );
    } on TimeoutException {
      // stop() clears the in-memory lease before its first await. Platform
      // cleanup may finish in the background, but it must not leave the send
      // button disabled indefinitely.
      debugPrint('Keep-alive cleanup timed out; continuing first send.');
    }
  }

  void _stopActiveGeneration() {
    _stopGenerationRequested = true;
    _dismissWebSearchConfirmation();
    _activeGenerationAdapter?.cancelActive();
    _toolRunner.cancelActive(reason: 'Generation stopped.');
  }

  Future<ApiAdapter?> _prepareAdapterForGeneration({
    required int generationSerial,
    required int sourceMessageId,
  }) async {
    try {
      return await ApiSettings.buildAdapter();
    } on ApiConfigException catch (error) {
      if (!_isCurrentGeneration(generationSerial)) return null;
      _finishFailedGeneration();
      await _persistApiFailure(error, sourceMessageId: sourceMessageId);
      return null;
    } catch (error) {
      if (!_isCurrentGeneration(generationSerial)) return null;
      _finishFailedGeneration();
      await _persistApiFailure(error, sourceMessageId: sourceMessageId);
      return null;
    }
  }

  void _invalidateGenerationState() {
    final adapter = _activeGenerationAdapter;
    _activeGenerationAdapter = null;
    adapter?.cancelActive();
    _dismissWebSearchConfirmation();
    _toolRunner.cancelActive(reason: 'Generation invalidated.');
    MemoryActions.clearSearchQuery(widget.conversationId);
    _clearStreamQueue();
    _stopGenerationRequested = false;
    _generationSerial++;
    _streamingText = '';
    _setGenerating(false);
    _chatSearching = false;
    _chatSearchQuery = '';
    _chatSearchResults = [];
    _webSearchActivity = null;
    _pendingWebSearchResult = null;
    _pendingWebSearchFailureContext = '';
  }
}
