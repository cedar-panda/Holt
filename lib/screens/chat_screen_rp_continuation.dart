// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatRpContinuationMethods on _ChatScreenState {
  Future<void> _persistUserFirstContinuationAction(String request) async {
    final action = Message(
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: request,
      isUser: true,
    );
    if (!action.isUserFirstContinuation) return;
    final id = await DatabaseHelper.insertMessage(action);
    if (!mounted) return;
    final saved = Message(
      id: id,
      conversationId: action.conversationId,
      characterId: action.characterId,
      text: action.text,
      isUser: true,
      createdAt: action.createdAt,
    );
    _refreshChatState(() {
      _messages.add(saved);
      _rpStartChoiceResolved = true;
    });
    _scrollToBottom(force: true);
  }

  bool _isVisibleRpContinuationSourceMessage(Message message) =>
      message.status == Message.statusComplete &&
      message.text.trim().isNotEmpty &&
      !message.isRpChapterContinuation &&
      !_ChatScreenState._callActionRe.hasMatch(message.text.trim());

  List<Message> _rpContinuationTail(List<Message> messages) {
    final visible = messages
        .where(_isVisibleRpContinuationSourceMessage)
        .toList(growable: false);
    return visible.skip(max(0, visible.length - 2)).toList(growable: false);
  }

  Future<void> _applyRpContinuationSource(
    RpChapterContinuationSource source, {
    required bool notify,
  }) async {
    final continuationBudget =
        await MemorySettings.getRpContinuationSummaryMaxChars();
    final continuationSummary =
        ContextCompressor.fitRpSummariesToCharacterBudget(
          source.summaries.take(1),
          continuationBudget,
        );
    void update() {
      _previousWindowTurnsFuture = Future<List<Message>>.value(source.messages);
      _rpContinuationSummaryPrompt = continuationSummary;
      _rpContinuationSourceConversationId = source.conversation.id;
      _rpContinuationSourceTitle = _rpContinuationWindowTitle(source);
      _rpContinuationDisplayMessages = _rpContinuationTail(source.messages);
      _rpContinuationSourceAnchorMessageId = source.messages.isEmpty
          ? null
          : source.messages.last.id;
      _rpContinuationSourceExpanded = false;
      _rpContinuationSourceLoading = false;
      _rpContinuationSourceHasMore = false;
      _rpContinuationOldestLoadedMessageId = null;
    }

    if (notify && mounted) {
      _refreshChatState(update);
    } else {
      update();
    }
  }

  Future<void> _restoreRpContinuationBridge(
    ChatSessionIdentity identity,
  ) async {
    final action = await DatabaseHelper.getLatestRpChapterContinuationAction(
      widget.conversationId,
    );
    if (action == null) return;

    final sourceId = action.rpChapterContinuationSourceId;
    final anchorMessageId = action.rpChapterContinuationAnchorMessageId;
    RpChapterContinuationSource? source;
    if (sourceId != null) {
      source = await DatabaseHelper.getRpChapterContinuationSource(
        sourceConversationId: sourceId,
        currentConversationId: widget.conversationId,
        characterId: identity.characterId,
        continuityId: identity.continuityId,
        contextMode: identity.contextMode,
        throughMessageId: anchorMessageId,
        summariesThrough: action.createdAt,
      );
      // A persisted exact source must fail closed. Falling back to the latest
      // window here would show and inject the wrong chapter after deletion.
      if (source == null) {
        _previousWindowTurnsFuture = Future<List<Message>>.value(
          const <Message>[],
        );
        return;
      }
    } else {
      // Compatibility for continuation actions created before source IDs were
      // persisted. Their previous behavior was to use the newest eligible RP
      // window, so preserve that only for these legacy rows.
      final sources = await (_rpChapterContinuationSourcesFuture ??=
          DatabaseHelper.getRpChapterContinuationSources(
            currentConversationId: widget.conversationId,
            characterId: identity.characterId,
            continuityId: identity.continuityId,
            contextMode: identity.contextMode,
          ));
      if (sources.isNotEmpty) source = sources.first;
    }
    if (source != null) {
      await _applyRpContinuationSource(source, notify: false);
    }
  }

  Future<void> _toggleRpContinuationSourceHistory() async {
    final sourceId = _rpContinuationSourceConversationId;
    if (sourceId == null || _rpContinuationSourceLoading) return;
    if (_rpContinuationSourceExpanded) {
      final bridge = await DatabaseHelper.getRpChapterContinuationSource(
        sourceConversationId: sourceId,
        currentConversationId: widget.conversationId,
        characterId: _activeCharacterId,
        continuityId: _requiredSessionIdentity.continuityId,
        contextMode: _requiredSessionIdentity.contextMode,
        throughMessageId: _rpContinuationSourceAnchorMessageId,
      );
      if (!mounted || bridge == null) return;
      _refreshChatState(() {
        _rpContinuationDisplayMessages = _rpContinuationTail(bridge.messages);
        _rpContinuationSourceExpanded = false;
        _rpContinuationSourceHasMore = false;
        _rpContinuationOldestLoadedMessageId = null;
      });
      return;
    }

    _refreshChatState(() => _rpContinuationSourceLoading = true);
    try {
      final anchorMessageId = _rpContinuationSourceAnchorMessageId;
      final raw = anchorMessageId == null
          ? await DatabaseHelper.getMessages(sourceId, limit: 50)
          : await DatabaseHelper.getMessagesUpToId(
              sourceId,
              anchorMessageId,
              limit: 50,
            );
      final visible = raw
          .where(_isVisibleRpContinuationSourceMessage)
          .toList(growable: false);
      final oldestId = raw.isEmpty ? null : raw.first.id;
      final hasMore = oldestId == null
          ? false
          : await DatabaseHelper.hasMessagesBefore(sourceId, oldestId);
      if (!mounted) return;
      _refreshChatState(() {
        _rpContinuationDisplayMessages = visible;
        _rpContinuationSourceExpanded = true;
        _rpContinuationSourceHasMore = hasMore;
        _rpContinuationOldestLoadedMessageId = oldestId;
      });
    } finally {
      if (mounted) {
        _refreshChatState(() => _rpContinuationSourceLoading = false);
      }
    }
  }

  Future<void> _loadEarlierRpContinuationSourceHistory() async {
    final sourceId = _rpContinuationSourceConversationId;
    final beforeId = _rpContinuationOldestLoadedMessageId;
    if (sourceId == null ||
        beforeId == null ||
        _rpContinuationSourceLoading ||
        !_rpContinuationSourceHasMore) {
      return;
    }
    final preserveViewport = _scrollController.hasClients;
    final previousPixels = preserveViewport
        ? _scrollController.position.pixels
        : 0.0;
    final previousMaxExtent = preserveViewport
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    _refreshChatState(() => _rpContinuationSourceLoading = true);
    try {
      final raw = await DatabaseHelper.getMessagesBeforeId(
        sourceId,
        beforeId,
        limit: 50,
      );
      final visible = raw
          .where(_isVisibleRpContinuationSourceMessage)
          .toList(growable: false);
      final oldestId = raw.isEmpty ? beforeId : raw.first.id ?? beforeId;
      final hasMore =
          raw.isNotEmpty &&
          await DatabaseHelper.hasMessagesBefore(sourceId, oldestId);
      if (!mounted) return;
      _refreshChatState(() {
        _rpContinuationDisplayMessages.insertAll(0, visible);
        _rpContinuationSourceHasMore = hasMore;
        _rpContinuationOldestLoadedMessageId = oldestId;
      });
      if (visible.isNotEmpty && preserveViewport) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          final addedExtent =
              _scrollController.position.maxScrollExtent - previousMaxExtent;
          final target = (previousPixels + addedExtent).clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          );
          _scrollController.jumpTo(target);
        });
      }
    } finally {
      if (mounted) {
        _refreshChatState(() => _rpContinuationSourceLoading = false);
      }
    }
  }

  Future<bool> _switchEmptyRpStoryline(String storylineId) async {
    if (_messages.isNotEmpty ||
        _requiredSessionIdentity.contextMode != ContextMode.rp) {
      return false;
    }
    final resolvedPersona = await UserPersonaService.resolveForNewWindow(
      characterId: _activeCharacterId,
      contextMode: ContextMode.rp,
      continuityId: storylineId,
    );
    final rebound = await DatabaseHelper.rebindEmptyRpConversation(
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      storylineId: storylineId,
      userPersonaId: resolvedPersona.persona.id,
      userPersonaSnapshot: resolvedPersona.promptSnapshot,
    );
    if (!rebound) return false;

    final conversation = await DatabaseHelper.getConversation(
      widget.conversationId,
    );
    final identity = ChatSessionIdentity.fromConversation(
      expectedConversationId: widget.conversationId,
      conversation: conversation,
    );
    final sourcesFuture = DatabaseHelper.getRpChapterContinuationSources(
      currentConversationId: widget.conversationId,
      characterId: _activeCharacterId,
      continuityId: storylineId,
      contextMode: ContextMode.rp,
    );
    final sources = await sourcesFuture;
    final storylines = await DatabaseHelper.getRpStorylines(_activeCharacterId);
    if (!mounted) return false;

    Retriever.releaseWindowIds(widget.conversationId);
    Retriever.resetWindowIds(widget.conversationId);
    _sessionIdentity = identity;
    _userPersona = resolvedPersona.persona;
    final avatarPath = resolvedPersona.persona.avatarPath.trim();
    _userAvatarPath = avatarPath.isEmpty ? null : avatarPath;
    _userNameCache = resolvedPersona.persona.displayName;
    _rpChapterContinuationSourcesFuture = sourcesFuture;
    _previousWindowTurnsFuture = Future<List<Message>>.value(
      sources.isEmpty ? const <Message>[] : sources.first.messages,
    );
    _cacheWindowSummaryStaticSnapshot = null;
    _rpContinuationSummaryPrompt = '';
    _rpContinuationSourceConversationId = null;
    _rpContinuationSourceTitle = '';
    _rpContinuationDisplayMessages = <Message>[];
    _rpContinuationSourceExpanded = false;
    _rpContinuationSourceHasMore = false;
    _rpContinuationSourceAnchorMessageId = null;
    _rpContinuationOldestLoadedMessageId = null;
    _refreshChatState(() {
      _rpStorylines = storylines;
      _canContinuePreviousRpChapter = sources.isNotEmpty;
    });
    return true;
  }

  Future<void> _selectCurrentRpChapter() async {
    final selected = await showRpStorylinePicker(
      context,
      characterId: _activeCharacterId,
    );
    if (selected == null || !mounted) return;
    final switched = await _switchEmptyRpStoryline(selected);
    if (!switched || !mounted) {
      _showChatNotice(
        L.pick(
          en: 'This empty window could not switch storylines',
          zhTW: '這個空窗口無法切換故事線',
          zhCN: '这个空窗口无法切换故事线',
        ),
      );
      return;
    }
    await _continuePreviousRpChapter();
  }

  Future<String?> _askNewRpChapterName() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        title: Text(
          L.pick(en: 'Open a new chapter', zhTW: '開啟新篇章', zhCN: '开启新篇章'),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: L.pick(en: 'Chapter name', zhTW: '篇章名稱', zhCN: '篇章名称'),
          ),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) Navigator.pop(dialogContext, name);
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(dialogContext, name);
            },
            child: Text(L.pick(en: 'Create', zhTW: '建立', zhCN: '创建')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _openNewRpChapter() async {
    if (_messages.isNotEmpty ||
        _requiredSessionIdentity.contextMode != ContextMode.rp) {
      return;
    }
    if (_rpStorylines.length >= 3) {
      _showChatNotice(
        L.pick(
          en: 'Each character can keep up to three active storylines',
          zhTW: '每個角色最多保留三條進行中的故事線',
          zhCN: '每个角色最多保留三条进行中的故事线',
        ),
      );
      return;
    }
    final name = await _askNewRpChapterName();
    if (name == null || !mounted) return;
    try {
      final storylineId = await DatabaseHelper.createRpStoryline(
        characterId: _activeCharacterId,
        name: name,
      );
      final switched = await _switchEmptyRpStoryline(storylineId);
      if (!switched || !mounted) return;
      _refreshChatState(() => _rpStartChoiceResolved = true);
      _showChatNotice(
        L.pick(en: 'New chapter opened', zhTW: '已開啟新篇章', zhCN: '已开启新篇章'),
      );
    } catch (error) {
      if (!mounted) return;
      _showChatNotice(
        L.pick(
          en: 'Could not open a new chapter',
          zhTW: '無法開啟新篇章',
          zhCN: '无法开启新篇章',
        ),
        tone: ThemedNoticeTone.error,
      );
    }
  }

  Future<void> _continuePreviousRpChapter() async {
    final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
    if (!_canContinuePreviousRpChapter ||
        _messages.isNotEmpty ||
        _isGenerating ||
        _isGeneratingImage ||
        _sendSubmissionInProgress) {
      return;
    }
    final sources = await (_rpChapterContinuationSourcesFuture ??=
        DatabaseHelper.getRpChapterContinuationSources(
          currentConversationId: widget.conversationId,
          characterId: _activeCharacterId,
          continuityId: _requiredSessionIdentity.continuityId,
          contextMode: _requiredSessionIdentity.contextMode,
        ));
    if (!mounted) return;
    if (sources.isEmpty) {
      _showChatNotice(
        L.pick(
          en: isRp
              ? 'No earlier RP window is available to continue'
              : 'No earlier daily window is available to continue',
          zhTW: isRp ? '目前沒有可續接的 RP 窗口' : '目前沒有可續接的日常窗口',
          zhCN: isRp ? '目前没有可续接的 RP 窗口' : '目前没有可续接的日常窗口',
        ),
      );
      return;
    }
    var selected = sources.first;
    final choice = await showModalBottomSheet<_ContinuationChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => FractionallySizedBox(
          heightFactor: 0.82,
          child: Container(
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            L.pick(
                              en: isRp
                                  ? 'Continue this chapter'
                                  : 'Continue this conversation',
                              zhTW: isRp ? '繼續這一篇章' : '繼續這段對話',
                              zhCN: isRp ? '继续这一篇章' : '继续这段对话',
                            ),
                            style: YanciTheme.headingMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            sheetContext,
                          ).closeButtonTooltip,
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(
                            Icons.close_rounded,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: DropdownButtonFormField<String>(
                      initialValue: selected.conversation.id,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: L.pick(
                          en: 'Chapter window',
                          zhTW: '續接窗口',
                          zhCN: '续接窗口',
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      items: sources
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item.conversation.id,
                              child: Text(
                                '${_rpContinuationWindowTitle(item)} · ${_rpContinuationTime(item.lastMessageAt)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (id) {
                        if (id == null) return;
                        setSheetState(() {
                          selected = sources.firstWhere(
                            (item) => item.conversation.id == id,
                          );
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      children: <Widget>[
                        _rpContinuationSectionTitle(
                          L.pick(
                            en: 'Latest two messages',
                            zhTW: '最近兩條原文',
                            zhCN: '最近两条原文',
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final message in selected.messages)
                          _rpContinuationMessagePreview(message),
                        const SizedBox(height: 16),
                        _rpContinuationSectionTitle(
                          L.pick(
                            en: 'Latest two summaries',
                            zhTW: '最後兩條摘要',
                            zhCN: '最后两条摘要',
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (selected.summaries.isEmpty)
                          Text(
                            L.pick(
                              en: 'No summary has been recorded for this window yet',
                              zhTW: '這個窗口尚未記錄摘要',
                              zhCN: '这个窗口尚未记录摘要',
                            ),
                            style: YanciTheme.bodySmall,
                          )
                        else
                          for (var i = 0; i < selected.summaries.length; i++)
                            _rpContinuationSummaryPreview(
                              selected.summaries[i],
                              i + 1,
                            ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey(
                              'continuation-user-first-action',
                            ),
                            onPressed: () => Navigator.pop(
                              sheetContext,
                              _ContinuationChoice(
                                source: selected,
                                mode: _ContinuationStartMode.userFirst,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(62),
                              side: BorderSide(
                                color: YanciTheme.accent.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  L.pick(
                                    en: 'I’ll speak first',
                                    zhTW: '我先開口',
                                    zhCN: '我先开口',
                                  ),
                                  style: YanciTheme.bodyText.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  L.pick(
                                    en: 'Wait for my message',
                                    zhTW: '等我發出第一句',
                                    zhCN: '等我发出第一句',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 10.5,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.58,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey(
                              'continuation-character-first-action',
                            ),
                            onPressed: () => Navigator.pop(
                              sheetContext,
                              _ContinuationChoice(
                                source: selected,
                                mode: _ContinuationStartMode.characterFirst,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(62),
                              foregroundColor: YanciTheme.accent,
                              side: BorderSide(
                                color: YanciTheme.accent.withValues(alpha: 0.5),
                                width: 0.9,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  L.pick(
                                    en: 'Let TA speak first',
                                    zhTW: '讓 TA 先說',
                                    zhCN: '让 TA 先说',
                                  ),
                                  style: YanciTheme.bodyText.copyWith(
                                    color: YanciTheme.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  L.pick(
                                    en: 'Continue from the last scene',
                                    zhTW: '由角色接著上一段開口',
                                    zhCN: '由角色接着上一段开口',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: YanciTheme.bodySmall.copyWith(
                                    fontSize: 10.5,
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.62,
                                    ),
                                  ),
                                ),
                              ],
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
      ),
    );
    if (choice == null || !mounted) return;
    final source = choice.source;
    await _applyRpContinuationSource(source, notify: true);
    // 手動續接舊窗口時，不讓「最近窗口」摘要被釘進靜態 cache。
    // 指定來源的兩條摘要固定走 request-only 動態區。
    await DatabaseHelper.setConversationPinnedSummaryIfAbsent(
      widget.conversationId,
      '',
    );
    _cacheWindowSummaryStaticSnapshot = null;
    final sourceMarker = Message.rpChapterContinuationSourceMarker(
      source.conversation.id,
    );
    final sourceAnchorId = source.messages.isEmpty
        ? null
        : source.messages.last.id;
    final sourceAnchorMarker = sourceAnchorId == null
        ? ''
        : '${Message.rpChapterContinuationAnchorMarker(sourceAnchorId)}\n';
    final modeMarker = Message.continuationStartModeMarker(
      choice.mode == _ContinuationStartMode.userFirst ? 'user' : 'character',
    );
    final characterFirst = choice.mode == _ContinuationStartMode.characterFirst;
    final continuationInstruction = characterFirst
        ? (isRp
              ? L.pick(
                  en: 'Continue naturally from the exact handoff point in the previous window and write first. Respond to any unfinished action or dialogue before advancing the scene. Preserve the established plot, relationships, time, setting, narrative perspective, and tense. Do not restart the scene, repeat the final line, recap, add a chapter heading, force a time jump, or mention this action.',
                  zhTW:
                      '請從上一窗口最後停下的動作或對白精確承接，由你先自然寫下接續內容；若有尚未得到回應的動作或話語，先承接它再推進。沿用既有劇情、人物關係、時間、場景、敘事視角與時態。不要重新開場、重複末句、重述摘要、添加章節標題、擅自跳時，或提及這項操作。',
                  zhCN:
                      '请从上一窗口最后停下的动作或对白精确承接，由你先自然写下接续内容；若有尚未得到回应的动作或话语，先承接它再推进。沿用既有剧情、人物关系、时间、场景、叙事视角与时态。不要重新开场、重复末句、复述摘要、添加章节标题、擅自跳时，或提及这项操作。',
                )
              : L.pick(
                  en: 'Continue naturally from the exact handoff point in the previous conversation and write first. Respond to any unfinished question or topic before moving on. Preserve the established relationship, current subject, emotional tone, and conversational context. Do not greet as if meeting again for the first time, repeat the final line, recap, force a topic change, or mention this action.',
                  zhTW:
                      '請從上一窗口最後停下的對話精確承接，由你先自然回應；若有尚未回答的問題或未完話題，先接住它再往下聊。沿用既有關係、當前話題、情緒語氣與對話脈絡。不要像重新見面般寒暄、重複末句、重述摘要、強行換話題，或提及這項操作。',
                  zhCN:
                      '请从上一窗口最后停下的对话精确承接，由你先自然回应；若有尚未回答的问题或未完话题，先接住它再往下聊。沿用既有关系、当前话题、情绪语气与对话脉络。不要像重新见面般寒暄、重复末句、复述摘要、强行换话题，或提及这项操作。',
                ))
        : L.pick(
            en: 'This window continues from the selected previous window. The user will speak first. Use the handoff messages and summaries as context when responding to the next visible user message. Preserve the established continuity and do not mention this action.',
            zhTW:
                '本窗口承接所選的上一窗口，由使用者先開口。收到下一條可見的使用者訊息時，請結合接續原文與摘要自然回應，維持既有脈絡，不要提及這項操作。',
            zhCN:
                '本窗口承接所选的上一窗口，由用户先开口。收到下一条可见的用户消息时，请结合接续原文与摘要自然回应，维持既有脉络，不要提及这项操作。',
          );
    final request =
        '${Message.rpChapterContinuationPrefix}\n$sourceMarker\n$modeMarker\n'
        '$sourceAnchorMarker$continuationInstruction';
    if (characterFirst) {
      await _onSendMessage(request);
      return;
    }

    // User-first continuation is local setup only. Persist the source/anchor so
    // reopening the empty window restores the bridge, but do not enter the
    // generation path or spend provider tokens before the user actually talks.
    await _persistUserFirstContinuationAction(request);
  }

  String _rpContinuationWindowTitle(RpChapterContinuationSource source) {
    final title = source.conversation.title?.trim() ?? '';
    return title.isEmpty
        ? L.pick(en: 'Untitled window', zhTW: '未命名窗口', zhCN: '未命名窗口')
        : title;
  }

  String _rpContinuationTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}/${two(value.month)}/${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Widget _rpContinuationSectionTitle(String text) => Text(
    text,
    style: YanciTheme.bodyText.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: YanciTheme.textSecondary,
    ),
  );

  Widget _rpContinuationMessagePreview(Message message) {
    final speaker = message.isUser
        ? (_userPersonaName.isEmpty
              ? L.pick(en: 'You', zhTW: '你', zhCN: '你')
              : _userPersonaName)
        : (_characterName.isEmpty
              ? L.pick(en: 'Character', zhTW: '對方', zhCN: '对方')
              : _characterName);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: '$speaker  ',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: message.isUser
                    ? YanciTheme.accent
                    : YanciTheme.textSecondary,
              ),
            ),
            TextSpan(text: message.text),
          ],
        ),
        style: YanciTheme.bodyText.copyWith(fontSize: 13, height: 1.45),
      ),
    );
  }
}
