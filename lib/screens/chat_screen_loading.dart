// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatLoadingMethods on _ChatScreenState {
  int get _renderPageSize => _ChatScreenState._renderPageSize;
  int get _ctxAnchorMaxMessages => _ChatScreenState._ctxAnchorMaxMessages;

  Future<void> _initializeChat() async {
    try {
      await ToolFeatureSettings.load();
      var conversation = await DatabaseHelper.getConversation(
        widget.conversationId,
      );
      if (conversation != null) {
        conversation = await UserPersonaService.ensureConversationPersona(
          conversation,
        );
      }
      final identity = ChatSessionIdentity.fromConversation(
        expectedConversationId: widget.conversationId,
        conversation: conversation,
      );
      if (!mounted) return;

      _sessionIdentity = identity;
      _activeCharacterId = identity.characterId;
      if (identity.contextMode == ContextMode.rp) {
        await DatabaseHelper.ensureDefaultRpStoryline(identity.characterId);
      }
      final rpStorylinesFuture = identity.contextMode == ContextMode.rp
          ? DatabaseHelper.getRpStorylines(identity.characterId)
          : Future<List<Map<String, Object?>>>.value(
              const <Map<String, Object?>>[],
            );
      final hasRpWindowFuture = identity.contextMode == ContextMode.rp
          ? DatabaseHelper.hasConversationHistoryForCharacter(
              characterId: identity.characterId,
              contextMode: ContextMode.rp,
            )
          : Future<bool>.value(false);
      unawaited(
        ContextSummaryRepairService.processScope(
          characterId: identity.characterId,
          contextMode: identity.contextMode,
          continuityId: identity.continuityId,
        ),
      );
      final sourcesFuture = DatabaseHelper.getRpChapterContinuationSources(
        currentConversationId: widget.conversationId,
        characterId: identity.characterId,
        continuityId: identity.continuityId,
        contextMode: identity.contextMode,
      );
      _rpChapterContinuationSourcesFuture = sourcesFuture;
      if (identity.contextMode == ContextMode.rp) {
        _previousWindowTurnsFuture = sourcesFuture.then(
          (sources) =>
              sources.isEmpty ? const <Message>[] : sources.first.messages,
        );
      } else {
        _previousWindowTurnsFuture =
            DatabaseHelper.getPreviousConversationTurns(
              currentConversationId: widget.conversationId,
              characterId: identity.characterId,
              contextMode: identity.contextMode,
              continuityId: identity.continuityId,
            );
      }
      _userPersona = await UserPersonaService.personaForConversation(
        conversation!,
      );
      _pendingGift = await ShopService.getPendingGift(
        scopeId: widget.conversationId,
        targetCharacterId: _activeCharacterId,
      );
      await Future.wait<void>([_loadSettings(conversation), _loadMessages()]);
      await _restoreRpContinuationBridge(identity);
      final continuationSources = await sourcesFuture;
      final rpStorylines = await rpStorylinesFuture;
      final hasRpWindow = await hasRpWindowFuture;
      final resolvedConversation = await DatabaseHelper.getConversation(
        widget.conversationId,
      );
      final resolvedIdentity = ChatSessionIdentity.fromConversation(
        expectedConversationId: widget.conversationId,
        conversation: resolvedConversation,
      );
      _sessionIdentity = resolvedIdentity;
      _activeCharacterId = resolvedIdentity.characterId;
      unawaited(_refreshMarriageState());
      if (!mounted) return;

      setState(() {
        _canContinuePreviousRpChapter = continuationSources.isNotEmpty;
        _rpStorylines = rpStorylines;
        _hasAnyRpWindow = hasRpWindow;
        _isChatReady = true;
        _isLoading = false;
        _initializationFailed = false;
      });
      _scheduleHeaderModelDetails(isEmptyWindow: _messages.isEmpty);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isChatReady) return;
        final personaName = _userPersonaName.isEmpty
            ? L.pick(en: 'you', zhTW: '你', zhCN: '你')
            : _userPersonaName;
        final characterName = _characterName.isEmpty
            ? L.pick(en: 'the character', zhTW: '對方', zhCN: '对方')
            : _characterName;
        showThemedPillNotice(
          context,
          L.pick(
            en: 'You are currently $personaName, talking with $characterName',
            zhTW: '當前為$personaName在與$characterName交流中',
            zhCN: '当前为$personaName在与$characterName交流中',
          ),
          anchorLink: _noticeAnchorLink,
        );
      });
      // Let the loading/list transition settle before exposing pagination.
      // This prevents a recycled ListView child from flashing the old control.
      Future.delayed(const Duration(milliseconds: 180), () {
        if (mounted && _isChatReady) {
          setState(() => _olderButtonReady = true);
        }
      });
      _scrollToBottom(force: true);
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _scrollToBottom(force: true);
      });
      // 分支對話：帶進來的編輯文本自動發出（走完整管線）
      final autoSend = widget.initialAutoSendText?.trim();
      if (autoSend != null && autoSend.isNotEmpty && !_autoSendFired) {
        _autoSendFired = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onSendMessage(autoSend);
        });
      }
      unawaited(
        _claimVisibleKeepAliveWindow().catchError((Object error) {
          debugPrint('Unable to claim keep-alive window: $error');
        }),
      );
    } catch (error, stackTrace) {
      debugPrint('Chat initialization failed: $error\n$stackTrace');
      if (KeepAliveService.instance.activeConversationId ==
          widget.conversationId) {
        await KeepAliveService.instance.stop();
      }
      if (!mounted) return;
      setState(() {
        _isChatReady = false;
        _isLoading = false;
        _initializationFailed = true;
        _initializationError = '$error';
      });
    }
  }

  void _retryInitialization() {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _isChatReady = false;
      _olderButtonReady = false;
      _initializationFailed = false;
      _initializationError = '';
      _messages.clear();
      _cacheHitIndices.clear();
      _scratchDataMap.clear();
      _transferDataMap.clear();
      _pendingMemoryActionCounts.clear();
      _pendingMemoryProposals.clear();
      _chatDiagnostics.clear();
      _summaryRecordedSummaryIds.clear();
      _tokensSinceSummary = 0;
      _charAvatarPath = null;
    });
    unawaited(_initializeChat());
  }

  Future<void> _loadSettings(Conversation conversation) async {
    _currentModel = await ApiSettings.getModel();
    _splitReply = await MemorySettings.getSplitReply();
    if (_splitReply && YanciTheme.aiBubbleFlat) {
      YanciTheme.aiBubbleFlat = false;
      await ThemeSettings.saveAiBubbleFlat(false);
    }
    _showChatAvatar = await UserSettings.getShowChatAvatar();
    // 心情流光：載入這個窗口的顏色給角色頭像用（範圍不適用時為 null）。
    unawaited(
      MoodGlowService.bindConversation(
        conversation.id,
        mode: conversation.contextMode,
      ),
    );

    // 用戶頭像
    final uAvatar = _userPersona?.avatarPath ?? '';
    if (uAvatar.isNotEmpty) _userAvatarPath = uAvatar;

    // 角色頭像與蛛網背景引擎
    var char = await DatabaseHelper.getCharacter(_activeCharacterId);
    if (char == null) {
      // 角色 ID 失效（可能是 'default' 或已刪除）→ 嘗試恢復到第一個角色
      debugPrint(
        'Character $_activeCharacterId not found for conversation '
        '${conversation.id}, attempting recovery…',
      );
      final allChars = await DatabaseHelper.getCharacters();
      if (allChars.isEmpty) {
        throw StateError(
          'No characters exist. Character $_activeCharacterId for '
          'conversation ${conversation.id} could not be resolved.',
        );
      }
      final fallbackChar = allChars.first;
      final fallbackId = fallbackChar['id'] as String;
      // 修正對話的角色綁定 + 全域偏好
      await DatabaseHelper.updateConversationCharacter(
        conversation.id,
        fallbackId,
      );
      await UserSettings.saveActiveCharacterId(fallbackId);
      _activeCharacterId = fallbackId;
      char = fallbackChar;
      debugPrint('Recovered to character $fallbackId');
    }
    _characterName = char['name'] as String? ?? '';
    _characterRemark = char['remark'] as String? ?? '';
    _charAvatarPath = char['avatar_path'] as String?;
    _composerHint = CharacterWhisperState.fromCharacter(char).displayText;
    _boundBackgroundPreset =
        await BackgroundPresetService.boundPresetForCharacter(
          _activeCharacterId,
        );
    final chatPath = _boundBackgroundPreset?.chatPath ?? '';
    _boundChatPalette = chatPath.trim().isEmpty
        ? null
        : await BackgroundForegroundService.resolveChatBubblePalette(chatPath);
    _boundChatForeground = chatPath.trim().isEmpty
        ? null
        : await BackgroundForegroundService.resolve(chatPath);

    // 背景執行：蛛網封存引擎 (清理30天未觸發的孤島記憶)
    if (_requiredSessionIdentity.contextMode == ContextMode.daily &&
        (char['is_spider_web_enabled'] as int? ?? 0) == 1) {
      SpiderWebCore.runArchiveEngine(characterId: _activeCharacterId).then((
        archivedCount,
      ) {
        if (archivedCount > 0) {
          debugPrint(
            'SpiderWeb Engine: Archived $archivedCount fading memories.',
          );
        }
      });
    }

    if (!mounted) return;
    if (conversation.title != null && conversation.title!.isNotEmpty) {
      _conversationTitle = conversation.title!;
    }

    // ═══ 本地模型預加載：進聊天頁就開始，不等發送 ═══
    if (LocalModelService.isLocalModelId(_currentModel)) {
      setState(() => _localModelLoading = true);
      try {
        await ApiSettings.buildAdapter();
      } catch (e) {
        debugPrint('Local model pre-load failed: $e');
      }
      if (mounted) setState(() => _localModelLoading = false);
    }
  }

  Future<void> _persistContextAnchor(int messageId) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_ctxAnchorKey, messageId);
    } catch (_) {}
  }

  Future<void> _loadOlderForDisplay() async {
    if (_olderLoading || !_olderHasMore) return;
    _olderLoading = true;
    try {
      final beforeId = _olderMessages.isNotEmpty
          ? _olderMessages.first.id
          : (_messages.isNotEmpty ? _messages.first.id : null);
      if (beforeId == null) {
        _olderHasMore = false;
        return;
      }
      final older = await DatabaseHelper.getMessagesBeforeId(
        widget.conversationId,
        beforeId,
        limit: _renderPageSize,
      );
      // 這批消息的刮卡/轉帳卡數據順帶載入
      for (final m in older) {
        if (m.id != null) {
          final key = 'msg_${m.id}';
          final sd = await ScratchService.getData(key);
          if (sd != null) _scratchDataMap[key] = sd;
          final td = await TransferService.getData(key);
          if (td != null) _transferDataMap[key] = td;
        }
      }
      if (!mounted) return;
      setState(() {
        if (older.isEmpty) {
          _olderHasMore = false;
        } else {
          _olderMessages.insertAll(0, older);
          if (older.length < _renderPageSize) _olderHasMore = false;
        }
      });
    } finally {
      _olderLoading = false;
    }
  }

  Future<void> _loadMessages() async {
    await IosReplyBackgroundTask.recover(widget.conversationId);
    final p = await SharedPreferences.getInstance();
    final anchorId = p.getInt(_ctxAnchorKey);

    List<Message> messages;
    if (anchorId != null) {
      messages = await DatabaseHelper.getMessagesFromId(
        widget.conversationId,
        anchorId,
      );
      if (messages.isEmpty) {
        // 錨點失效（消息被清/導入重建）→ 回退最新 50 並重錨
        messages = await DatabaseHelper.getMessages(
          widget.conversationId,
          limit: 50,
        );
        final firstId = messages.isNotEmpty ? messages.first.id : null;
        if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
      } else if (messages.length > _ctxAnchorMaxMessages) {
        // 窗口太長：推進錨點（此輪炸一次緩存，換 UI/token 不無限膨脹）
        messages = messages.sublist(messages.length - 50);
        final firstId = messages.first.id;
        if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
      }
    } else {
      messages = await DatabaseHelper.getMessages(
        widget.conversationId,
        limit: 50,
      );
      final firstId = messages.isNotEmpty ? messages.first.id : null;
      if (firstId != null) await p.setInt(_ctxAnchorKey, firstId);
    }
    if (!mounted) return;
    // 載入已有的刮刮樂 / 轉帳數據
    for (final msg in messages) {
      if (msg.id != null) {
        final key = 'msg_${msg.id}';
        final sd = await ScratchService.getData(key);
        if (sd != null) _scratchDataMap[key] = sd;
        final td = await TransferService.getData(key);
        if (td != null) _transferDataMap[key] = td;
      }
    }
    // 錨點之前是否還有歷史（決定翻完窗口後「查看更早」是否繼續）
    final windowFirstId = messages.isNotEmpty ? messages.first.id : null;
    final hasBefore = windowFirstId != null
        ? await DatabaseHelper.hasMessagesBefore(
            widget.conversationId,
            windowFirstId,
          )
        : false;
    await MemoryGuardService.suppressReappearingRejectedSuggestions(
      _activeCharacterId,
    );
    final pendingMemoryActions =
        await MemoryGuardService.pendingCountsByMessage(widget.conversationId);
    final pendingMemoryProposals =
        await MemoryGuardService.pendingProposalsByMessage(
          characterId: _activeCharacterId,
          conversationId: widget.conversationId,
        );
    final diagnostics = await DatabaseHelper.getChatDiagnostics(
      widget.conversationId,
    );
    final summaryRecordedSummaryIds =
        await DatabaseHelper.getSummaryRecordedAnchors(widget.conversationId);

    if (!mounted) return;
    setState(() {
      // 清空重建而非 addAll：通話結束等場景會再次調用本方法，
      // 疊加會讓整窗消息雙份（UI 重複 + 發送歷史前綴變 → 炸緩存）
      _messages
        ..clear()
        ..addAll(messages);
      // 渲染窗：只掛最近一頁，更早的點按鈕再掛（發送仍用全窗）
      _renderFrom = (_messages.length - _renderPageSize).clamp(
        0,
        _messages.length,
      );
      _olderMessages.clear();
      _olderHasMore = hasBefore;
      _pendingMemoryActionCounts
        ..clear()
        ..addAll(pendingMemoryActions);
      _pendingMemoryProposals
        ..clear()
        ..addAll(pendingMemoryProposals);
      _chatDiagnostics
        ..clear()
        ..addAll(diagnostics);
      _summaryRecordedSummaryIds
        ..clear()
        ..addAll(summaryRecordedSummaryIds);
      _cacheHitIndices.clear();
      for (int i = 0; i < _messages.length; i++) {
        if (_messages[i].cacheHit) {
          _cacheHitIndices.add(i);
        }
      }
    });

    // 非同步還原 _tokensSinceSummary，防止退出窗口導致 token 重新歸零
    await _restoreTokensSinceSummary();

    // 舊消息可能已經完成摘要但被模型漏掉生理週期候選；開窗時用本地
    // 游標補掃一次，之後只查新增消息，不新增摘要模型請求。
    try {
      await _scanExplicitMenstrualTimeline();
    } catch (error) {
      debugPrint('開窗補記生理期時間線失敗：$error');
    }
  }

  Future<void> _refreshPendingMemoryActionCounts({bool notify = true}) async {
    await MemoryGuardService.suppressReappearingRejectedSuggestions(
      _activeCharacterId,
    );
    final counts = await MemoryGuardService.pendingCountsByMessage(
      widget.conversationId,
    );
    final proposals = await MemoryGuardService.pendingProposalsByMessage(
      characterId: _activeCharacterId,
      conversationId: widget.conversationId,
    );
    if (!mounted) return;
    if (notify) {
      setState(() {
        _pendingMemoryActionCounts
          ..clear()
          ..addAll(counts);
        _pendingMemoryProposals
          ..clear()
          ..addAll(proposals);
      });
    } else {
      _pendingMemoryActionCounts
        ..clear()
        ..addAll(counts);
      _pendingMemoryProposals
        ..clear()
        ..addAll(proposals);
    }
  }

  Future<void> _applyInlineMemoryProposal(
    MemoryActionProposal proposal,
    String decision,
  ) async {
    if (decision == 'reject') {
      await MemoryGuardService.reject(proposal.id, _activeCharacterId);
    } else {
      final result = await MemoryGuardService.execute(
        proposal.id,
        _activeCharacterId,
        createDecision: decision,
      );
      if (result != MemoryActionProposal.statusCompleted) {
        throw StateError('記憶提案未完成：$result');
      }
    }
    await _refreshPendingMemoryActionCounts();
  }

  Future<void> _bindMemoryProposalsToMessage(int messageId) async {
    final proposalIds = MemoryActions.lastProposalIdsFor(widget.conversationId);
    if (proposalIds.isEmpty) return;
    await MemoryGuardService.bindToMessage(
      proposalIds: proposalIds,
      conversationId: widget.conversationId,
      messageId: messageId,
    );
    await _refreshPendingMemoryActionCounts(notify: false);
  }

  Future<void> _openMemoryReview(int sourceMessageId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.86,
        child: Container(
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'Memory proposals from this reply',
                          zhTW: '這則回覆的記憶提案',
                          zhCN: '这则回复的记忆提案',
                        ),
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: MemoryReviewTab(
                  characterId: _activeCharacterId,
                  sourceMessageId: sourceMessageId,
                  onChanged: () => _refreshPendingMemoryActionCounts(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _refreshPendingMemoryActionCounts();
  }

  Future<void> _scanExplicitMenstrualTimeline() async {
    if (!await MemorySettings.getTimelineEnabled()) return;
    if (_requiredSessionIdentity.contextMode == ContextMode.rp) return;
    final prefs = await SharedPreferences.getInstance();
    final cursor = prefs.getInt(_timelineMenstrualScanCursorKey) ?? 0;
    final messages = await DatabaseHelper.getMessagesAfterId(
      widget.conversationId,
      cursor,
    );
    if (messages.isEmpty) return;
    debugPrint(
      '[TimelineDebug] chat rescan: char=$_activeCharacterId '
      'cursor=$cursor messages=${messages.length}',
    );

    final maxId = messages
        .map((message) => message.id ?? 0)
        .fold<int>(cursor, (max, id) => id > max ? id : max);
    final changed =
        await CharacterTimelineService.storeExplicitMenstrualMessages(
          characterId: _activeCharacterId,
          messages: messages,
        );
    debugPrint(
      '[TimelineDebug] chat rescan stored=$changed char=$_activeCharacterId '
      'nextCursor=$maxId',
    );
    await prefs.setInt(_timelineMenstrualScanCursorKey, maxId);
  }

  Future<void> _generateClosingSignatureOnDispose({
    required String conversationId,
    required String characterId,
    required ChatSessionIdentity identity,
    required String model,
    required String provider,
  }) async {
    try {
      final messages = await DatabaseHelper.getMessages(conversationId);
      Message? assistant;
      var assistantIndex = -1;
      for (var i = messages.length - 1; i >= 0; i--) {
        final message = messages[i];
        if (!message.isUser &&
            !message.isIncomplete &&
            message.text.trim().isNotEmpty) {
          assistant = message;
          assistantIndex = i;
          break;
        }
      }
      if (assistant == null) return;

      Message? user;
      for (var i = assistantIndex - 1; i >= 0; i--) {
        if (messages[i].isUser && messages[i].text.trim().isNotEmpty) {
          user = messages[i];
          break;
        }
      }
      await CharacterSignatureService.generateForWindow(
        characterId: characterId,
        conversationId: conversationId,
        phase: CharacterSignatureService.closingPhase,
        contextMode: identity.contextMode,
        continuityId: identity.continuityId,
        latestUserMessage: user?.text ?? '',
        latestAssistantReply: assistant.text,
        model: model,
        provider: provider,
      );
    } catch (error) {
      debugPrint('關閉窗口個性簽名生成失敗：$error');
    }
  }
}
