// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatCompressionMethods on _ChatScreenState {
  Future<int> _triggerContextCompression({
    String? conversationId,
    String? characterId,
    int? triggerTokenLimit,
    int? triggerMessageLimit,
  }) async {
    final running = _compressionInFlight;
    if (running != null) return running;

    final future = _performContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerTokenLimit: triggerTokenLimit,
      triggerMessageLimit: triggerMessageLimit,
    );
    _compressionInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_compressionInFlight, future)) {
        _compressionInFlight = null;
      }
    }
  }

  Future<int> _performContextCompression({
    String? conversationId,
    String? characterId,
    int? triggerTokenLimit,
    int? triggerMessageLimit,
  }) async {
    final convId = conversationId ?? widget.conversationId;
    final charId = characterId ?? _activeCharacterId;
    final cursor = await DatabaseHelper.getConversationSummaryCursor(convId);
    final messages = await DatabaseHelper.getMessagesAfterId(convId, cursor);
    if (messages.isEmpty) return 0;

    final recentMsgs = triggerMessageLimit != null
        ? ContextCompressor.selectWholeMessageBatch(
            messages,
            triggerMessageLimit,
          )
        : ContextCompressor.selectWholeBubbleBatch(
            messages,
            triggerTokenLimit ?? ContextCompressor.triggerTokens,
          );

    if (recentMsgs.isEmpty) return 0;

    final result = await ContextCompressor.compress(
      messages: recentMsgs,
      characterId: charId,
      conversationId: convId,
      contextMode: _requiredSessionIdentity.contextMode,
      continuityId: _requiredSessionIdentity.continuityId,
      minimumSourceTokens: ContextCompressor.minimumSourceTokensForTrigger(
        triggerMessageLimit: triggerMessageLimit,
      ),
    );
    if (result > 0) {
      await _refreshWindowSummaryStateAfterCompression(convId);
      debugPrint('窗口摘要完成：$result tokens');
      if (mounted && convId == widget.conversationId) {
        final summaryAnchors = await DatabaseHelper.getSummaryRecordedAnchors(
          convId,
        );
        if (!mounted || convId != widget.conversationId) return result;
        _refreshChatState(() {
          _summaryRecordedSummaryIds
            ..clear()
            ..addAll(summaryAnchors);
        });
        _scrollToBottom();
      }
    }
    return result;
  }

  Future<void> _refreshWindowSummaryStateAfterCompression(String convId) async {
    // 壓縮後只更新動態路徑用的 window id（excludeWindowId）。
    // 靜態摘要 pin 綁對話 ID、已凍死，絕不在此失效——否則又炸緩存。
    _windowSummaryId = await DatabaseHelper.getConversationWindowSummaryId(
      convId,
    );
  }

  Future<String> _currentWindowSummaryId() async {
    final existing = _windowSummaryId;
    if (existing != null && existing.isNotEmpty) return existing;
    final id = await DatabaseHelper.ensureConversationWindowSummaryId(
      widget.conversationId,
    );
    _windowSummaryId = id;
    return id;
  }

  Future<String> _buildStaticWindowSummaryPrompt(String characterId) async {
    _syncPromptLocaleCaches();
    if (_requiredSessionIdentity.contextMode == ContextMode.rp &&
        _rpContinuationSummaryPrompt.trim().isNotEmpty) {
      return '';
    }
    final costStrategy = await ModelCostPolicy.resolveCurrentStrategy();
    if (!costStrategy.promptCacheEnabled || !costStrategy.cacheSummaryEnabled) {
      _cacheWindowSummaryStaticSnapshot = null;
      return '';
    }

    // 記憶體快照優先：本窗生命週期內只查一次庫。
    if (_cacheWindowSummaryStaticSnapshot != null) {
      return _cacheWindowSummaryStaticSnapshot!;
    }

    final convId = widget.conversationId;
    String? pinned = await DatabaseHelper.getConversationPinnedSummary(convId);

    if (pinned == null) {
      // 首建＝出生：抓「最新一塊」滾動摘要原文釘死（排除本對話自己的窗口）。
      // 可能為空（出生前無前情）——空也釘，之後永不再變。
      final windowId = await _currentWindowSummaryId();
      final rows = await DatabaseHelper.getLatestContextSummaries(
        characterId,
        excludeWindowId: windowId,
        limit: 1,
        contextMode: _requiredSessionIdentity.contextMode,
        continuityId: _requiredSessionIdentity.continuityId,
      );
      final text = rows.isNotEmpty
          ? (rows.first['content'] as String? ?? '')
          : '';
      pinned = await DatabaseHelper.setConversationPinnedSummaryIfAbsent(
        convId,
        text,
      );
    }

    final compactPinned = _requiredSessionIdentity.contextMode == ContextMode.rp
        ? ContextCompressor.fitRpSummaryToCharacterBudget(
            pinned,
            await MemorySettings.getRpDynamicSummaryMaxChars(),
          )
        : pinned;
    final prompt = compactPinned.trim().isEmpty
        ? ''
        : _formatWindowSummaryPrompt(
            summary: compactPinned,
            keywordSummary: '',
            pinned: true,
          );
    _cacheWindowSummaryStaticSnapshot = prompt;
    return prompt;
  }

  Future<String> _buildDynamicWindowSummaryPrompt(
    String characterId, {
    String currentMessage = '',
  }) async {
    final costStrategy = await ModelCostPolicy.resolveCurrentStrategy();
    final useCacheKeywordRecall =
        costStrategy.promptCacheEnabled && costStrategy.cacheSummaryEnabled;
    final useContextDynamic =
        costStrategy.contextLimitEnabled && costStrategy.contextSummaryEnabled;
    if (!useCacheKeywordRecall && !useContextDynamic) return '';

    final windowId = await _currentWindowSummaryId();
    final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
    final hasContinuation =
        isRp && _rpContinuationSummaryPrompt.trim().isNotEmpty;
    final includeKeyword = useCacheKeywordRecall || useContextDynamic;
    if (!isRp) {
      final pack = await ContextCompressor.loadSummaryPack(
        characterId,
        currentMessage: currentMessage,
        excludeWindowId: windowId,
        includeLatestSummaries: useContextDynamic,
        includeKeywordRecall: includeKeyword,
        contextMode: _requiredSessionIdentity.contextMode,
        continuityId: _requiredSessionIdentity.continuityId,
      );
      return _formatWindowSummaryPrompt(
        summary: (pack['summary'] ?? '').trim(),
        keywordSummary: (pack['keywordSummaries'] ?? '').trim(),
      );
    }

    var includeLatest = false;
    if (useContextDynamic && !hasContinuation) {
      final previous =
          await (_previousWindowTurnsFuture ??
              Future<List<Message>>.value(const <Message>[]));
      final limit = await MemorySettings.getContextMessageLimit();
      includeLatest = previous.length + _messages.length + 1 > limit;
    }
    final pinned = hasContinuation
        ? ''
        : await _buildStaticWindowSummaryPrompt(characterId);
    var latest = '';
    if (includeLatest) {
      final pack = await ContextCompressor.loadSummaryPack(
        characterId,
        excludeWindowId: windowId,
        includeLatestSummaries: true,
        latestLimit: 1,
        includeKeywordRecall: false,
        contextMode: ContextMode.rp,
        continuityId: _requiredSessionIdentity.continuityId,
      );
      latest = ContextCompressor.fitRpSummaryToCharacterBudget(
        (pack['summary'] ?? '').trim(),
        1200,
      );
    }

    var keyword = '';
    if (includeKeyword) {
      const rpTotalChars = 2000;
      final budget = hasContinuation
          ? ContextCompressor.rpContinuationRecallReserveChars
          : max(400, rpTotalChars - pinned.length - latest.length);
      final pack = await ContextCompressor.loadSummaryPack(
        characterId,
        currentMessage: currentMessage,
        excludeWindowId: windowId,
        includeLatestSummaries: false,
        includeKeywordRecall: true,
        contextMode: ContextMode.rp,
        continuityId: _requiredSessionIdentity.continuityId,
        rpKeywordMaxChars: budget,
        alreadyInjected: hasContinuation
            ? _rpContinuationSummaryPrompt
            : '$pinned\n$latest',
      );
      keyword = (pack['keywordSummaries'] ?? '').trim();
    }
    return _formatWindowSummaryPrompt(summary: latest, keywordSummary: keyword);
  }

  String _formatWindowSummaryPrompt({
    required String summary,
    required String keywordSummary,
    bool pinned = false,
  }) {
    final trimmedSummary = summary.trim();
    final trimmedKeyword = keywordSummary.trim();
    if (trimmedSummary.isEmpty && trimmedKeyword.isEmpty) return '';
    final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
    final characterName = _characterName.trim().isEmpty
        ? L.pick(en: 'the character', zhTW: '角色', zhCN: '角色')
        : _characterName.trim();
    final userName = _userPersonaName.trim().isEmpty
        ? L.pick(en: 'the other person', zhTW: '對方', zhCN: '对方')
        : _userPersonaName.trim();

    if (L.locale == 'en') {
      final parts = <String>[];
      if (!isRp) {
        parts.add(
          'Identity anchor: "$characterName" in these notes is you; reply as “I”. '
          '"$userName" is the person in front of you; address them naturally as “you”. '
          'Do not imitate the notes’ third-person narration in conversation.',
        );
      }
      if (trimmedSummary.isNotEmpty) {
        final summaryLabel = isRp && pinned
            ? 'Story so far (snapshot taken when this window opened; later events in the chat take precedence)'
            : (isRp ? 'Recent RP summaries' : 'Recent summaries');
        parts.add('$summaryLabel:\n$trimmedSummary');
      }
      if (trimmedKeyword.isNotEmpty) {
        parts.add(
          '${isRp ? 'Keyword-matched old RP summary' : 'Keyword-matched old summary'}:\n$trimmedKeyword',
        );
      }
      return '${isRp ? '【RP Window Summary】' : '【Window Summary】'}\n${parts.join('\n\n')}';
    }

    final parts = <String>[];
    if (!isRp) {
      parts.add(
        L.pick(
          en: '',
          zhTW:
              '手記中記錄的「$characterName」就是你自己（回覆時請用第一人稱「我」）；記錄的「$userName」就是眼前的對方（回覆時請自然稱呼對方或用「你／妳」）。請勿在對話中模仿手記的第三人稱旁白語氣。',
          zhCN:
              '手记中记录的“$characterName”就是你自己（回复时请用第一人称“我”）；记录的“$userName”就是眼前的对方（回复时请自然称呼对方或用“你”）。请勿在对话中模仿手记的第三人称旁白语气。',
        ),
      );
    }
    if (trimmedSummary.isNotEmpty) {
      final summaryLabel = isRp && pinned
          ? L.pick(
              en: '',
              zhTW: '開窗前情（開窗時的快照，之後的發展以正文為準）：',
              zhCN: '开窗前情（开窗时的快照，之后的发展以正文为准）：',
            )
          : L.pick(
              en: '',
              zhTW: isRp ? '最近 RP 窗口摘要：' : '最近窗口摘要：',
              zhCN: isRp ? '最近 RP 窗口摘要：' : '最近窗口摘要：',
            );
      parts.add('$summaryLabel\n$trimmedSummary');
    }
    if (trimmedKeyword.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: isRp ? '命中關鍵詞召回的舊 RP 摘要：' : '命中關鍵詞召回的舊摘要：', zhCN: isRp ? '命中关键词召回的旧 RP 摘要：' : '命中关键词召回的旧摘要：')}\n$trimmedKeyword',
      );
    }
    return '${L.pick(en: '', zhTW: isRp ? '【RP 窗口摘要】' : '【窗口摘要】', zhCN: isRp ? '【RP 窗口摘要】' : '【窗口摘要】')}\n${parts.join('\n\n')}';
  }

  Future<int?> _windowSummaryTriggerMessageLimit() async {
    final costStrategy = await ModelCostPolicy.resolveCurrentStrategy();
    if (costStrategy.promptCacheEnabled && costStrategy.cacheSummaryEnabled) {
      return MemorySettings.getCacheSummaryTriggerMessages();
    }
    if (costStrategy.contextLimitEnabled &&
        costStrategy.contextSummaryEnabled) {
      return MemorySettings.getContextSummaryTriggerMessages();
    }
    return null;
  }

  Future<void> _recordCompletedRound({
    required String conversationId,
    required String userText,
    required String assistantText,
    required List<Map<String, String>> heartbeatHistory,
    required StructuredPrompt structuredPrompt,
    required ApiAdapter adapter,
    required String model,
    required String provider,
  }) async {
    try {
      await ApiSettings.recordStarredModelUsage(model, provider: provider);
    } catch (_) {
      // 常用度只影響排序，不能讓偏好寫入失敗打斷已完成的聊天。
    }
    _tokensSinceSummary +=
        TokenEstimator.estimate(userText) +
        TokenEstimator.estimate(assistantText);
    await _saveTokensSinceSummary();
    final keepAliveMessages = heartbeatHistory
        .where((m) => (m['content'] ?? '').trim().isNotEmpty)
        .map(
          (m) => <String, String>{
            'role': m['role'] ?? 'user',
            'content': m['content'] ?? '',
          },
        )
        .toList();
    if (assistantText.trim().isNotEmpty) {
      keepAliveMessages.add({
        'role': 'assistant',
        'content': assistantText.trim(),
      });
    }
    _lastKeepAliveMessages = keepAliveMessages;
    _lastKeepAliveStructuredPrompt = structuredPrompt;
    _lastKeepAliveAdapter = adapter;
    _lastKeepAliveModel = model;
    _lastKeepAliveProvider = provider;
    await KeepAliveService.instance.rememberActiveWindow(
      sessionIdentity: _requiredSessionIdentity,
      messages: keepAliveMessages,
      structuredPrompt: structuredPrompt,
      adapter: adapter,
      model: model,
      provider: provider,
    );

    // 明確的生理週期語句不必等窗口摘要模型；本地游標只掃新增消息。
    try {
      await _scanExplicitMenstrualTimeline();
    } catch (error) {
      debugPrint('即時生理期時間線記錄失敗：$error');
    }

    // 摘要、人物與關係整理是回覆完成後的背景維護。它不能繼續佔用
    // 發送／重試生命週期，否則畫面看似已完成，編輯重發卻會被靜默擋掉。
    unawaited(
      _maybeRunTokenTriggeredMaintenance(
        conversationId: conversationId,
        characterId: _activeCharacterId,
      ).catchError((Object error, StackTrace stackTrace) {
        debugPrint('背景摘要維護失敗：$error');
      }),
    );

    // ═══ 做夢整理：只整理目前日常/RP、故事線與記憶模式（不阻塞）═══
    unawaited(
      DreamCurationService.maybeTrigger(
        characterId: _activeCharacterId,
        contextMode: _requiredSessionIdentity.contextMode,
        continuityId: _requiredSessionIdentity.continuityId,
        memoryMode: await _memoryBucket(),
      ),
    );

    // 每個窗口只允許一條 opening 簽名；服務會先查本地窗口記錄，
    // 因此後續回合不會再建立額外 provider 請求。
    final signatureCharacterId = _activeCharacterId;
    unawaited(
      CharacterSignatureService.generateForWindow(
        characterId: signatureCharacterId,
        conversationId: widget.conversationId,
        phase: CharacterSignatureService.openingPhase,
        contextMode: _requiredSessionIdentity.contextMode,
        continuityId: _requiredSessionIdentity.continuityId,
        latestUserMessage: userText,
        latestAssistantReply: assistantText,
        model: model,
        provider: provider,
      ).catchError((Object error) {
        debugPrint('個性簽名生成失敗：$error');
        return null;
      }),
    );
  }

  Future<void> _maybeRunTokenTriggeredMaintenance({
    String? conversationId,
    String? characterId,
  }) async {
    final triggerMessageLimit = await _windowSummaryTriggerMessageLimit();
    if (triggerMessageLimit == null) return;
    final convId = conversationId ?? widget.conversationId;
    final pendingMessages = await ContextCompressor.pendingMessageCount(convId);
    if (pendingMessages < triggerMessageLimit) return;
    final failedAt = _lastFailedCompressionPendingMessages;
    if (failedAt != null && pendingMessages < failedAt + 4) {
      // A provider/schema failure must not trigger another paid summary call
      // on every single chat turn. Four new messages supply meaningful new
      // evidence before the automatic path tries again; manual summary remains
      // available immediately.
      return;
    }

    final compressedTokens = await _triggerContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerMessageLimit: triggerMessageLimit,
    );
    if (compressedTokens > 0) {
      _lastFailedCompressionPendingMessages = null;
      _tokensSinceSummary = await ContextCompressor.pendingTokenCount(
        conversationId ?? widget.conversationId,
      );
      await _saveTokensSinceSummary();
    } else {
      _lastFailedCompressionPendingMessages = pendingMessages;
    }
  }
}
