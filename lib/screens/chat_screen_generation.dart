part of 'chat_screen.dart';

extension _ChatGenerationMethods on _ChatScreenState {
  Future<String> _processScopedMemoryReply(
    String text, {
    required bool emotionEnabled,
    bool resetState = true,
    String provider = '',
    String modelId = '',
    int? sourceMessageId,
  }) async {
    final identity = _requiredSessionIdentity;
    final bucket = await _memoryBucket();
    if (identity.contextMode == ContextMode.rp) {
      return RpMemoryService.processReply(
        text,
        characterId: _activeCharacterId,
        mode: bucket,
        windowId: widget.conversationId,
        continuityId: identity.continuityId,
        emotionEnabled: emotionEnabled,
        resetState: resetState,
        provider: provider,
        modelId: modelId,
        sourceMessageId: sourceMessageId,
      );
    }
    return MemoryActions.processReply(
      text,
      characterId: _activeCharacterId,
      mode: bucket,
      windowId: widget.conversationId,
      emotionEnabled: emotionEnabled,
      resetState: resetState,
      contextMode: ContextMode.daily,
      continuityId: identity.continuityId,
      provider: provider,
      modelId: modelId,
      sourceMessageId: sourceMessageId,
    );
  }

  /// 生成態統一入口：熄屏/退後台會凍結流式回覆，
  /// 生成期間掛前台服務保護（GenerationForegroundGuard），結束即撤

  /// Closes only the visible reply surface. Memory, timeline, worldbook and
  /// other private actions may continue afterwards without leaving the bubble
  /// in a typing state or moving its avatar a second time.

  /// The submission lock only protects the short interval before a turn has
  /// been accepted and `_isGenerating` takes over. Keeping it for the whole
  /// request makes the send affordance look ready after visible streaming has
  /// ended while taps are still silently discarded by background post-work.

  /// 提取 `<x_post>` 內容並剝離，再走通用殘尾清理。
  /// 必須在 _stripInternalToolCalls 之前提取——_ChatScreenState._openTagRe 已含 x_post，
  /// 先 strip 會把標籤連同後文一起截掉。text/image 雙路徑共用。

  /// 發推流程：限額/連接檢查 → 確認卡（承諾過「先過目」）→ 發送。

  /// 消費本輪 `<buy>` 結果：送 user 成功 → 系統訊息落庫並即時上屏；
  /// 失敗 → SnackBar 提示（模型側回饋走 pendingBuyFailureNote 動態注入）。
  /// text / image 雙路徑共用此消費點。

  /// 每個窗口第一輪的狀態快照（背包星標、日常角色狀態）。
  /// 文字與圖片路徑共用，避免用圖片開窗時漏注入。

  /// 蛛網記憶串聯提示（本輪 runtime context，不追加到用戶原文）。

  /// 情緒座標範圍：RP 每條故事線各一份（平行時空），日常一份。
  String get _emotionScopeId {
    final identity = _sessionIdentity;
    if (identity == null) return _activeCharacterId;
    return EmotionCoordinates.scopeId(
      _activeCharacterId,
      identity.contextMode,
      identity.continuityId,
    );
  }

  /// Language changes are an explicit one-time static-prefix invalidation.
  /// Refresh only language-bearing snapshots; keep data baselines intact so
  /// deltas, summary pins, and append-only history semantics do not change.

  /// 上下文限制與側邊欄一致，以完整消息氣泡數計算。
  /// Cache 與上下文限制互斥，因此這裡不再為舊 Token 滯後邏輯保留
  /// 超額內容；始終只送出最新 N 條，讓 UI 數值與實際請求一致。

  /// 後台畫圖：不阻塞回覆顯示，完成後更新消息的圖與日誌

  /// 窗口摘要壓縮

  /// 靜態摘要 pin：綁對話 ID、出生釘一塊（最新滾動摘要原文）、存庫永凍。
  /// 之後不管壓縮 rotate、重開對話、摘要增刪，都讀這份釘死的複本——
  /// 前綴恆定，緩存不炸。詳見 cache_fix_定案清單.md。

  Future<void> _onSendMessage(
    String text, {
    bool clearComposerOnAccept = false,
  }) async {
    if (!_isChatReady ||
        _sendSubmissionInProgress ||
        _isGenerating ||
        _isGeneratingImage) {
      return;
    }

    final generationSerialBefore = _generationSerial;
    final existingUserMessageIds = _messages
        .where((message) => message.isUser && message.id != null)
        .map((message) => message.id!)
        .toSet();

    if (mounted) {
      _refreshChatState(() => _sendSubmissionInProgress = true);
    } else {
      _sendSubmissionInProgress = true;
    }
    try {
      await _sendMessageLocked(
        text,
        composerDraft: text,
        clearComposerOnAccept: clearComposerOnAccept,
      );
    } catch (error) {
      Message? acceptedUserMessage;
      for (final message in _messages.reversed) {
        if (message.isUser &&
            message.id != null &&
            !existingUserMessageIds.contains(message.id)) {
          acceptedUserMessage = message;
          break;
        }
      }

      await _recoverEscapedGenerationFailure(
        error,
        generationSerialBefore: generationSerialBefore,
        sourceMessageId: acceptedUserMessage?.id,
      );
    } finally {
      if (mounted) {
        _refreshChatState(() => _sendSubmissionInProgress = false);
      } else {
        _sendSubmissionInProgress = false;
      }
    }
  }

  Widget _rpContinuationSummaryPreview(String summary, int index) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      '$index. $summary',
      style: YanciTheme.bodySmall.copyWith(height: 1.5),
    ),
  );

  /// 文字與圖片共用的唯一發送路徑。[sourceImagePaths] 是本輪新選的圖
  /// （首次發送才複製進 app）；重試時沿用 [retryUserMessage] 已入庫的圖。
  Future<void> _sendMessageLocked(
    String text, {
    required String composerDraft,
    required bool clearComposerOnAccept,
    Message? retryUserMessage,
    List<String> sourceImagePaths = const <String>[],
  }) async {
    if (!_isChatReady) return;
    if (retryUserMessage == null && sourceImagePaths.isEmpty) {
      final protocolProbe = Message(
        conversationId: widget.conversationId,
        characterId: _activeCharacterId,
        text: text,
        isUser: true,
      );
      if (protocolProbe.isUserFirstContinuation) {
        await _persistUserFirstContinuationAction(text);
        return;
      }
    }
    final conversationId = widget.conversationId;
    // 新窗口第一句話 → 停止舊窗口保活 + 切換緩存會話
    if (_messages
        .where((m) => m.isUser && !m.isRpChapterContinuation)
        .isEmpty) {
      await _stopKeepAliveBeforeFirstMessage();
      if (!mounted) return;
      CacheSession.bind(_requiredSessionIdentity);
    }
    // 情緒衰減 tick（冪等：未到刷新間隔的點不會被動）
    EmotionCoordinates.tickDecay(_emotionScopeId);
    if (_isGenerating) return;
    if (_isGeneratingImage) return; // 圖片生成中不允許發送
    // 本地模型還在加載中 → 提示用戶稍候
    if (_localModelLoading) {
      _showChatNotice(
        L.pick(
          en: 'Local model is loading, please wait...',
          zhTW: '本地模型加載中，請稍候……',
        ),
        duration: const Duration(milliseconds: 1200),
      );
      return;
    }
    _userScrolledUp = false; // 新消息 → 重新跟隨

    // 有待發圖片 → 圖文一起送
    if (retryUserMessage == null && _pendingImagePaths.isNotEmpty) {
      final imagePaths = List<String>.from(_pendingImagePaths);
      _refreshChatState(() => _pendingImagePaths.clear());
      return _sendMessageLocked(
        text,
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
        sourceImagePaths: imagePaths,
      );
    }

    // 有待發表情包 → 文字 + 表情包一起送
    if (retryUserMessage == null && _pendingSticker != null) {
      final sticker = _pendingSticker!;
      _refreshChatState(() => _pendingSticker = null);
      final stickerTag = '[sticker:${sticker.id}]';
      final combined = text.isNotEmpty ? '$text\n$stickerTag' : stickerTag;
      // 遞迴回 _onSendMessage，此時 _pendingSticker 已清空不會再進來
      return _sendMessageLocked(
        combined,
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
        sourceImagePaths: sourceImagePaths,
      );
    }

    // 有掛起禮物 → 入對方背包 + 消息尾附 [gift:名稱]（氣泡隱藏、模型可見）
    final giftTag = retryUserMessage == null ? await _consumePendingGift() : '';
    if (giftTag.isNotEmpty) {
      return _sendMessageLocked(
        text.isNotEmpty ? '$text$giftTag' : giftTag.trim(),
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
        sourceImagePaths: sourceImagePaths,
      );
    }

    // 有掛起結婚證 → 消息尾附邀請標記＋動態語義說明（偶發事件不進靜態；簡繁英三語）
    if (retryUserMessage == null && _pendingMarriageCert) {
      _refreshChatState(() => _pendingMarriageCert = false);
      final certTag = MarriageService.certTagNote();
      return _sendMessageLocked(
        text.isNotEmpty ? '$text$certTag' : certTag.trim(),
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
        sourceImagePaths: sourceImagePaths,
      );
    }

    final savedImagePaths = retryUserMessage != null
        ? retryUserMessage.imagePaths
        : (await Future.wait(
            sourceImagePaths.map(ImageService.copyToAppDir),
          )).where((value) => value.isNotEmpty).toList(growable: false);
    if (sourceImagePaths.isNotEmpty && savedImagePaths.isEmpty) return;
    final hasImages = savedImagePaths.isNotEmpty;
    final titleSeedText = text.trim().isEmpty && hasImages
        ? L.pick(en: 'Photo', zhTW: '圖片', zhCN: '图片')
        : text;
    final pendingTransfer = retryUserMessage == null
        ? _pendingUserTransfer
        : null;
    final pendingScratchGiftWho = retryUserMessage == null
        ? _pendingScratchGiftWho
        : null;
    final pendingScratchGift = pendingScratchGiftWho == null
        ? null
        : await _createScratchGiftData(pendingScratchGiftWho);
    if (pendingScratchGiftWho != null && pendingScratchGift == null) return;

    var outboundText =
        retryUserMessage?.text ?? _appendTransferTag(text, pendingTransfer);
    if (retryUserMessage == null) {
      outboundText = _appendScratchGiftTag(outboundText, pendingScratchGift);
    }
    if (outboundText.isEmpty && !hasImages) return;
    if (pendingTransfer != null) {
      if (mounted) {
        _refreshChatState(() => _pendingUserTransfer = null);
      } else {
        _pendingUserTransfer = null;
      }
    }
    if (pendingScratchGift != null) {
      if (mounted) {
        _refreshChatState(() => _pendingScratchGiftWho = null);
      } else {
        _pendingScratchGiftWho = null;
      }
    }

    late final Message userMsgWithId;
    if (retryUserMessage != null) {
      if (retryUserMessage.id == null) return;
      userMsgWithId = retryUserMessage;
    } else {
      final userMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: outboundText,
        isUser: true,
        imagePaths: savedImagePaths,
      );
      final userId = await DatabaseHelper.insertMessage(userMsg);
      unawaited(MarriageService.scanMessage(userMsg.text, _activeCharacterId));
      _markMessageSentInSession();
      unawaited(ReplyNotificationService.requestPermissionOnFirstSend());
      if (clearComposerOnAccept) {
        _clearComposerIfUnchanged(composerDraft);
      }

      // 如果有 pending 轉帳，掛到這條消息上
      if (pendingTransfer != null) {
        final msgKey = 'msg_$userId';
        await TransferService.saveData(msgKey, pendingTransfer);
        _transferDataMap[msgKey] = pendingTransfer;
      }
      if (pendingScratchGift != null) {
        final msgKey = 'msg_$userId';
        await ScratchService.saveData(msgKey, pendingScratchGift);
        _scratchDataMap[msgKey] = pendingScratchGift;
      }

      userMsgWithId = Message(
        id: userId,
        conversationId: userMsg.conversationId,
        characterId: userMsg.characterId,
        text: userMsg.text,
        isUser: true,
        imagePaths: userMsg.imagePaths,
        createdAt: userMsg.createdAt,
      );
    }
    final promptVisibleOutboundText = userMsgWithId.promptVisibleText;
    final startsNewCharacterWorkshop = RegExp(
      r'^/newchar(?:\s|$)',
      caseSensitive: false,
    ).hasMatch(promptVisibleOutboundText.trim());
    if (startsNewCharacterWorkshop) {
      _newCharacterWorkshopActive = true;
    }
    final isNewCharacterCommand = _newCharacterWorkshopActive;
    final workingMessages = retryUserMessage == null
        ? <Message>[..._messages, userMsgWithId]
        : <Message>[..._messages];
    final generationSerial = _beginGeneration();
    if (mounted) {
      _refreshChatState(() {
        if (retryUserMessage == null) _messages.add(userMsgWithId);
        _setGenerating(true);
        _streamingText = '';
      });
      _releaseSubmissionLockAfterAcceptance();
      _scrollToBottom();
    } else {
      _setGenerating(true);
      _streamingText = '';
      _releaseSubmissionLockAfterAcceptance();
    }

    final visibleUserMessageCount = workingMessages
        .where((m) => m.isUser && !m.isRpChapterContinuation)
        .length;
    if (retryUserMessage == null &&
        (userMsgWithId.isRpChapterContinuation ||
            visibleUserMessageCount == 1)) {
      // 先用前 20 字佔位
      final titleText = _titleTextForFirstMessage(
        titleSeedText,
        pendingTransfer,
        pendingScratchGift,
      );
      final tempTitle = titleText.length > 20
          ? '${titleText.substring(0, 20)}...'
          : titleText;
      await DatabaseHelper.updateConversation(conversationId, title: tempTitle);
      _shouldAutoName = true; // 等 AI 回覆後自動命名
    }

    final adapter = await _prepareAdapterForGeneration(
      generationSerial: generationSerial,
      sourceMessageId: userMsgWithId.id!,
    );
    if (adapter == null) {
      if (mounted) _scrollToBottom();
      return;
    }
    _activeGenerationAdapter = adapter;

    // ═══ 並行化：一次發射所有獨立的異步調用，大幅減少等待 ═══
    final charId = _activeCharacterId;
    final sessionIdentity = _requiredSessionIdentity;
    final previousWindowTurnsF = _previousWindowTurnsFuture ??=
        DatabaseHelper.getPreviousConversationTurns(
          currentConversationId: widget.conversationId,
          characterId: charId,
          contextMode: sessionIdentity.contextMode,
          continuityId: sessionIdentity.continuityId,
        );
    final previousVisibleMessageAtF =
        sessionIdentity.contextMode == ContextMode.daily &&
            retryUserMessage == null
        ? previousWindowTurnsF.then<DateTime?>((previousWindowTurns) {
            final candidates = <Message>[
              ...previousWindowTurns,
              ...workingMessages,
            ];
            for (final message in candidates.reversed) {
              if (message.id == userMsgWithId.id ||
                  message.isIncomplete ||
                  message.isRpChapterContinuation) {
                continue;
              }
              if (message.promptVisibleText.trim().isNotEmpty ||
                  message.imagePaths.isNotEmpty) {
                return message.createdAt;
              }
            }
            return null;
          })
        : Future<DateTime?>.value(null);
    final systemPromptF = Future<String>.value(
      _userPersona?.promptContent ?? '',
    );
    final modelF = ApiSettings.getModel();
    final bucketF = _memoryBucket();
    final userProfileF = _buildUserProfilePrompt();
    final selfNotesEnabledF = sessionIdentity.contextMode == ContextMode.rp
        ? Future<bool>.value(false)
        : MemorySettings.getSelfNotesEnabled();
    final selfNotesF = selfNotesEnabledF.then<String>((enabled) async {
      if (!enabled) return '';
      return DatabaseHelper.getSelfNotesForPrompt(
        charId,
        limit: await MemorySettings.getSelfNotesInjectionLimit(),
      );
    });
    final userNicknameF = Future<String>.value(_userPersonaName);
    final emotionEnabledF = MemorySettings.isAbilityEnabled('emotion');
    final imagegenEnabledF = MemorySettings.isAbilityEnabled('imagegen');
    final bioclockEnabledF = sessionIdentity.contextMode == ContextMode.daily
        ? MemorySettings.isAbilityEnabled('bioclock')
        : Future<bool>.value(false);
    final timelineEnabledF = MemorySettings.getTimelineEnabled();
    final memoryWriteEnabledF = MemorySettings.getMemoryWriteEnabled();
    final providerNameF = ApiSettings.getApiProviderName();
    final conciseOnF = ApiSettings.getConciseMode();
    final freeformOnF = ApiSettings.getFreeformMode();
    final thinkingEnabledF = ApiSettings.getThinkingChain(
      conversationId: widget.conversationId,
    );
    final webSearchEnabledF = WebSearchSettings.getEnabled();
    final enableVibrationF = UserSettings.getEnableVibration();
    final charDataF = DatabaseHelper.getCharacter(charId);
    final isSpiderWebEnabledF = charDataF.then(
      (c) =>
          sessionIdentity.contextMode == ContextMode.daily &&
          (c?['is_spider_web_enabled'] as int? ?? 0) == 1,
    );
    final staticWindowSummaryF = _buildStaticWindowSummaryPrompt(charId);
    final dynamicWindowSummaryF = _buildDynamicWindowSummaryPrompt(
      charId,
      currentMessage: promptVisibleOutboundText,
    );

    // 記憶注入依賴 bucket，先 await bucket 再發射
    final bucket = await bucketF;
    final memoryPromptF = sessionIdentity.contextMode == ContextMode.rp
        ? Future<DeferredPrompt>.value(DeferredPrompt.empty())
        : emotionEnabledF.then(
            (emotionEnabled) => Retriever.buildMemoryPrompt(
              mode: bucket,
              currentMessage: promptVisibleOutboundText,
              characterId: charId,
              windowId: widget.conversationId,
              emotionEnabled: emotionEnabled,
              contextMode: sessionIdentity.contextMode,
              continuityId: sessionIdentity.continuityId,
            ),
          );

    // 動態部分：也提前發射
    final emoStateF = emotionEnabledF.then(
      (enabled) async =>
          enabled ? await EmotionCoordinates.statePrompt(_emotionScopeId) : '',
    );
    final recallPromptF = timelineEnabledF.then<String>((enabled) async {
      if (!enabled || sessionIdentity.contextMode == ContextMode.rp) return '';
      return CharacterTimelineService.recallPrompt(
        charId,
        promptVisibleOutboundText,
      );
    });
    final rpStoryContextPartsF = sessionIdentity.contextMode == ContextMode.rp
        ? Future.wait<String>(<Future<String>>[
            RpStoryService.recallPrompt(
              charId,
              promptVisibleOutboundText,
              continuityId: sessionIdentity.continuityId,
              recentMessages: _messages,
            ),
            RpStoryStateService.recallPrompt(
              charId,
              continuityId: sessionIdentity.continuityId,
              recentMessages: _messages,
            ),
            RpWorldbookService.recallTriggeredPrompt(
              characterId: charId,
              continuityId: sessionIdentity.continuityId,
              query: promptVisibleOutboundText,
            ),
          ])
        : Future<List<String>>.value(const <String>[]);
    final fatiguePromptF = bioclockEnabledF.then(
      (enabled) async =>
          enabled ? await BioClockService.fatiguePrompt(charId) : '',
    );

    // 收集結果
    final systemPrompt = await systemPromptF;
    final model = await modelF;
    _currentModel = model;
    var memoryPrompt = await memoryPromptF;
    final userProfile = await userProfileF;
    final selfNotes = await selfNotesF;
    final userNicknameStr = await userNicknameF;
    final isSpiderWebEnabled = await isSpiderWebEnabledF;
    final charData = await charDataF;
    final charDesc = charData?['description'] as String? ?? '';
    final charName = charData?['name'] as String? ?? '';
    final emotionEnabled = await emotionEnabledF;
    final imagegenEnabled = await imagegenEnabledF;
    final bioclockEnabled = await bioclockEnabledF;
    final timelineEnabled = await timelineEnabledF;
    final memoryWriteEnabled = await memoryWriteEnabledF;
    final providerName = await providerNameF;
    _configureStreamPresentation(providerName);
    final conciseOn = await conciseOnF;
    final freeformOn = await freeformOnF;
    final thinkingEnabled = await thinkingEnabledF;
    _generationThinkingEnabled = thinkingEnabled;
    final webSearchEnabled = await webSearchEnabledF;
    // RP 平行時空：日常生活類工具依設定過濾（整條文字路徑共用此狀態）
    final toolFeatures = await ToolFeatureSettings.loadForContext(
      sessionIdentity.contextMode,
    );

    final staticWindowSummary = await staticWindowSummaryF;
    final staticBundle = await _buildCommonStaticParts(
      characterId: charId,
      continuityId: sessionIdentity.continuityId,
      systemPrompt: systemPrompt,
      charDesc: charDesc,
      characterName: charName,
      characterRemark: charData?['remark'] as String? ?? '',
      userProfile: userProfile,
      selfNotes: selfNotes,
      userNickname: userNicknameStr,
      isSpiderWebEnabled: isSpiderWebEnabled,
      memoryWriteEnabled: memoryWriteEnabled,
      emotionEnabled: emotionEnabled,
      bioclockEnabled: bioclockEnabled,
      imagegenEnabled: imagegenEnabled,
      webSearchEnabled: webSearchEnabled,
      whisperModelOverrideEnabled:
          (charData?['whisper_model_override'] as int? ?? 1) == 1,
      providerName: providerName,
      staticWindowSummary: staticWindowSummary,
      contextMode: sessionIdentity.contextMode,
      toolFeatures: toolFeatures,
    );

    final dynamicParts = <String>[];
    final controlParts = <String>[];
    if (isNewCharacterCommand) {
      controlParts.add(GuideService.newCharacterPrompt());
    }
    final isRpContext = sessionIdentity.contextMode == ContextMode.rp;
    final turnEffects = DeferredPromptBatch();
    if (!isRpContext) turnEffects.add(memoryPrompt);
    final now = DateTime.now();
    if (isRpContext &&
        memoryWriteEnabled &&
        toolFeatures.toolPromptsEnabled &&
        MemoryActions.isRpCorrectionIntent(promptVisibleOutboundText)) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'RP Correction',
          zhTWTitle: 'RP 修正',
          zhCNTitle: 'RP 修正',
          content: MemoryActions.rpCorrectionRuntimeInstruction(),
        ),
      );
    }
    final diaryPrompt = await CharacterDiaryService.buildNightPrompt(
      characterId: charId,
      conversationId: widget.conversationId,
      sourceMessageId: userMsgWithId.id!,
      userName: userNicknameStr,
      currentUserContent: promptVisibleOutboundText.isEmpty && hasImages
          ? '（用戶發送了一張圖片）'
          : promptVisibleOutboundText,
      contextMode: sessionIdentity.contextMode,
      enabled: toolFeatures.toolPromptsEnabled && toolFeatures.diaryEnabled,
      now: now,
    );
    if (diaryPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Evening Diary',
          zhTWTitle: '晚間日記',
          zhCNTitle: '晚间日记',
          content: diaryPrompt.text,
        ),
      );
      turnEffects.add(diaryPrompt);
    }
    if (!isRpContext && memoryPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Memory',
          zhTWTitle: '記憶',
          zhCNTitle: '记忆',
          content: memoryPrompt.text,
        ),
      );
    }
    final contextSummary = await dynamicWindowSummaryF;
    var recallPrompt = await recallPromptF;
    final continuationBudget = max(
      0,
      ContextCompressor.rpLiveContinuityMaxChars -
          ContextCompressor.rpStoryReferenceReserveChars -
          staticWindowSummary.length -
          contextSummary.length,
    );
    final continuationSummary = isRpContext
        ? ContextCompressor.fitRpSummaryToCharacterBudget(
            _rpContinuationSummaryPrompt,
            continuationBudget,
            preferLatest: true,
          )
        : _rpContinuationSummaryPrompt;
    if (isRpContext) {
      final alreadyInjected = <String>[
        staticWindowSummary,
        contextSummary,
        continuationSummary,
      ].where((part) => part.trim().isNotEmpty).toList(growable: false);
      final rpMemoryPromptF = RpMemoryService.buildPrompt(
        mode: bucket,
        currentMessage: promptVisibleOutboundText,
        characterId: charId,
        windowId: widget.conversationId,
        continuityId: sessionIdentity.continuityId,
        emotionEnabled: emotionEnabled,
        alreadyInjected: alreadyInjected,
      );
      final rpTimelinePromptF = timelineEnabled
          ? RpCharacterTimelineService.recallPrompt(
              charId,
              promptVisibleOutboundText,
              continuityId: sessionIdentity.continuityId,
              alreadyInjected: alreadyInjected,
            )
          : Future<String>.value('');
      memoryPrompt = await rpMemoryPromptF;
      recallPrompt = await rpTimelinePromptF;
      turnEffects.add(memoryPrompt);
    }
    final storyBudget = min(
      ContextCompressor.rpStoryContextMaxChars,
      max(
        0,
        ContextCompressor.rpLiveContinuityMaxChars -
            staticWindowSummary.length -
            contextSummary.length -
            continuationSummary.length,
      ),
    );
    final rpStoryContextParts = await rpStoryContextPartsF;
    final rpStoryContext = isRpContext
        ? ContextCompressor.fitPrioritizedRpReferencePartsToCharacterBudget(
            storyState: rpStoryContextParts.length > 1
                ? rpStoryContextParts[1]
                : '',
            story: rpStoryContextParts.isNotEmpty ? rpStoryContextParts[0] : '',
            worldbook: rpStoryContextParts.length > 2
                ? rpStoryContextParts[2]
                : '',
            memory: memoryPrompt.text.isEmpty
                ? ''
                : SystemContextMarkdown.section(
                    enTitle: 'Memory',
                    zhTWTitle: '記憶',
                    zhCNTitle: '记忆',
                    content: memoryPrompt.text,
                  ),
            timeline: recallPrompt.isEmpty
                ? ''
                : SystemContextMarkdown.section(
                    enTitle: 'Timeline Recall',
                    zhTWTitle: '時間線召回',
                    zhCNTitle: '时间线召回',
                    content: recallPrompt,
                  ),
            maxCharacters: storyBudget,
          )
        : '';
    if (contextSummary.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Conversation Summary',
          zhTWTitle: '對話摘要',
          zhCNTitle: '对话摘要',
          content: contextSummary,
        ),
      );
    }
    if (continuationSummary.isNotEmpty) {
      final isRpContinuation = isRpContext;
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: isRpContinuation
              ? 'Selected Chapter Summary'
              : 'Selected Window Summaries',
          zhTWTitle: isRpContinuation ? '所選篇章摘要' : '所選窗口摘要',
          zhCNTitle: isRpContinuation ? '所选篇章摘要' : '所选窗口摘要',
          content: continuationSummary,
        ),
      );
    }
    if (rpStoryContext.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Story Reference',
          zhTWTitle: '劇情參考',
          zhCNTitle: '剧情参考',
          content: rpStoryContext,
        ),
      );
    }

    if (toolFeatures.toolPromptsEnabled &&
        toolFeatures.shellEconomyEnabled &&
        toolFeatures.coinSnapshotEnabled) {
      final coinDelta = await _coinDeltaPrompt(charId);
      if (coinDelta.isNotEmpty) dynamicParts.add(coinDelta);
    }
    // 背包窗內變動（「杯子+1（昭昭送的）」式增減量）
    if (toolFeatures.toolPromptsEnabled &&
        toolFeatures.shopEnabled &&
        _packQtySnapshot != null) {
      final packDelta = await ShopService.buildPackDelta(
        charId,
        _packQtySnapshot!,
      );
      if (packDelta.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Backpack Changes】', zhTW: '【背包變動】')}$packDelta',
        );
      }
    }
    if (toolFeatures.toolPromptsEnabled && toolFeatures.scratchEnabled) {
      final scratchGiftPrompt = _scratchGiftDynamicPrompt(pendingScratchGift);
      if (scratchGiftPrompt.isNotEmpty) dynamicParts.add(scratchGiftPrompt);
    }

    // 上輪購買失敗回饋（消費即清，防止她以為禮物送出去了）
    final buyFailPrompt =
        toolFeatures.toolPromptsEnabled && toolFeatures.shopEnabled
        ? _pendingBuyFailurePrompt()
        : DeferredPrompt.empty();
    if (buyFailPrompt.isNotEmpty) {
      dynamicParts.add(buyFailPrompt.text);
      turnEffects.add(buyFailPrompt);
    }

    // 同逛商店：邀請後清單跟隨 3 輪（動態注入不入庫）
    final browsePrompt =
        toolFeatures.toolPromptsEnabled && toolFeatures.shopEnabled
        ? await _shopBrowsePrompt()
        : DeferredPrompt.empty();
    if (browsePrompt.isNotEmpty) {
      dynamicParts.add(browsePrompt.text);
      turnEffects.add(browsePrompt);
    }

    // 結婚證：解鎖後她也可主動遞（未簽＋未遞過才注入）
    final dailyLifeTools = toolFeatures.dailyLifeToolsAllowed(
      sessionIdentity.contextMode,
    );
    if (toolFeatures.toolPromptsEnabled && dailyLifeTools) {
      final proposeHint = await MarriageService.proposeHintPrompt(charId);
      if (proposeHint.isNotEmpty) dynamicParts.add(proposeHint);
    }

    // X 發文動態狀態（剩餘條數每日變，不能進靜態）
    if (toolFeatures.toolPromptsEnabled && dailyLifeTools) {
      final xHint = await XPostSettings.promptHint(charId);
      if (xHint.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$xHint',
        );
      }
    }

    // 每輪動態注入，避免改動角色靜態 prompt 與既有 provider cache。
    if (toolFeatures.toolPromptsEnabled && toolFeatures.emailDraftEnabled) {
      dynamicParts.add(EmailDraftTool.runtimeInstruction());
    }
    final whisperState = CharacterWhisperState.fromCharacter(charData);
    if (toolFeatures.toolPromptsEnabled && whisperState.modelOverrideEnabled) {
      dynamicParts.add(
        WhisperService.runtimeInstruction(
          whisperState,
          characterName: charName,
          userName: userNicknameStr,
        ),
      );
    }

    // 情緒狀態（已提前發射）
    final emoState = await emoStateF;
    if (toolFeatures.toolPromptsEnabled && emoState.isNotEmpty) {
      dynamicParts.add(emoState);
    }

    // 生物鐘單一路徑：當前時段提醒 > 去重（帶冷卻） > 校準 > 構建／飯點。
    // 所有帶冷卻或時段消費的提示都在模型成功返回後才提交。
    if (toolFeatures.toolPromptsEnabled && bioclockEnabled) {
      final clockPrompt = await BioClockService.turnPrompt(charId);
      if (clockPrompt.isNotEmpty) {
        dynamicParts.add(
          SystemContextMarkdown.section(
            enTitle: 'Bio Clock',
            zhTWTitle: '生物鐘',
            zhCNTitle: '生物钟',
            content: clockPrompt.text,
          ),
        );
        turnEffects.add(clockPrompt);
      }
    }

    // 本窗口新記的習慣（相對開窗快照的增量，靜態快照不動保緩存）
    if (toolFeatures.toolPromptsEnabled &&
        bioclockEnabled &&
        _habitSnapshotIds != null) {
      final habitDelta = await BioClockService.habitDeltaPrompt(
        charId,
        _habitSnapshotIds!,
      );
      if (habitDelta.isNotEmpty) {
        dynamicParts.add(
          SystemContextMarkdown.section(
            enTitle: 'Bio Clock Changes',
            zhTWTitle: '生物鐘變動',
            zhCNTitle: '生物钟变动',
            content: habitDelta,
          ),
        );
      }
    }

    // 本窗口新記的自我註記（persona_note 增量，同上原理）
    final selfNotesDelta = _selfNotesDeltaPrompt(selfNotes);
    if (selfNotesDelta.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Self Notes',
          zhTWTitle: '自我註記',
          zhCNTitle: '自我注记',
          content: selfNotesDelta,
        ),
      );
    }

    // 角色生活化（每個對話框第一條注入狀態快照；文字／圖片共用）
    dynamicParts.addAll(
      await _firstRoundSnapshotParts(
        characterId: charId,
        toolFeatures: toolFeatures,
        timelineEnabled: timelineEnabled,
        contextMode: sessionIdentity.contextMode,
      ),
    );

    // 回憶觸發（已提前發射）
    if (!isRpContext && recallPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Recall',
          zhTWTitle: '回憶觸發',
          zhCNTitle: '回忆触发',
          content: recallPrompt,
        ),
      );
    }

    // 疲勞提示（已提前發射）
    final fatiguePrompt = await fatiguePromptF;
    if (toolFeatures.toolPromptsEnabled && fatiguePrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Bio Clock',
          zhTWTitle: '生物鐘',
          zhCNTitle: '生物钟',
          content: fatiguePrompt,
        ),
      );
    }

    // 時間變動最頻繁，放在動態區塊後段。
    if (!isRpContext || toolFeatures.rpDailyLifeToolsEnabled) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Current Time',
          zhTWTitle: '當前時間',
          zhCNTitle: '当前时间',
          content: _timePrompt(now),
        ),
      );
    }
    if (!isRpContext) {
      final previousMessageAt = await previousVisibleMessageAtF;
      if (previousMessageAt != null) {
        final gapPrompt = ConversationTimeContext.buildGapPrompt(
          previousMessageAt: previousMessageAt,
          currentMessageAt: userMsgWithId.createdAt,
          locale: L.locale,
        );
        if (gapPrompt.isNotEmpty) {
          dynamicParts.add(
            SystemContextMarkdown.section(
              enTitle: 'Conversation Gap',
              zhTWTitle: '對話間隔',
              zhCNTitle: '对话间隔',
              content: gapPrompt,
            ),
          );
        }
      }
    }

    // Thinking 是本輪展示策略，不得進入可快取 control prefix。Thinking
    // Machines 使用原生 request 參數，其餘 provider 走 request-only sidecar。
    if (providerName != 'thinking_machines') {
      dynamicParts.add(
        ThinkingModePolicy.runtimeInstruction(enabled: thinkingEnabled),
      );
    }

    // 心情流光：規則進 control（只在範圍設定改變時變），冷卻狀態進動態層。
    if (await MoodGlowService.isEnabledFor(sessionIdentity.contextMode)) {
      controlParts.add(MoodGlowService.abilityPrompt());
      dynamicParts.add(
        await MoodGlowService.statusPrompt(widget.conversationId),
      );
    }

    // 拆分回覆模式：放 request-only 動態層，不進可快取的 control 前綴，
    // 開關多氣泡不會讓緩存重建（文字、圖片兩條路徑相同）。
    if (_splitReply) {
      // 子開關「自然發言」：關掉時只交代怎麼拆，不要求模型像聊天軟體打字。
      // 拆法規則兩種模式共用，對應 split_reply_parser 的實際行為。
      final splitNatural = await MemorySettings.getSplitReplyNatural();
      final splitRule = L.pick(
        en: 'How to split: an empty line (two line breaks) starts a new bubble. A single line break stays inside the same bubble. Do not put empty lines inside one bubble.\nExample:\nfirst bubble\n\nsecond bubble, line one\nsecond bubble, line two\n\nthird bubble',
        zhTW:
            '拆法：空一行（連續兩個換行）＝下一顆氣泡；只換一行不空行＝同一顆氣泡裡換行。同一顆氣泡內不要出現空行。\n示例：\n第一顆氣泡\n\n第二顆氣泡的第一行\n第二顆氣泡的第二行\n\n第三顆氣泡',
        zhCN:
            '拆法：空一行（连续两个换行）＝下一颗气泡；只换一行不空行＝同一颗气泡里换行。同一颗气泡内不要出现空行。\n示例：\n第一颗气泡\n\n第二颗气泡的第一行\n第二颗气泡的第二行\n\n第三颗气泡',
      );
      final splitIntro = splitNatural
          ? L.pick(
              en: '【Multi-Bubble Messaging Mode】You are texting in a messaging app, and the system splits your reply by blank lines into separate chat bubbles. Write entirely in the spoken words you actually type and send in the input box, weaving emotion and tone naturally into your word choice, phrasing, and punctuation. Separate bubbles with blank lines and keep each bubble concise and natural.',
              zhTW:
                  '【多氣泡訊息模式】你正在用聊天軟體傳訊息，系統會將你的回覆按空行拆成多顆獨立的聊天氣泡。請全部使用你在輸入框裡實際打字送出的口語文字，把情緒與語氣自然融進用詞、斷句和標點裡。不同氣泡之間用空行隔開，每顆氣泡簡短自然。',
              zhCN:
                  '【多气泡消息模式】你正在用聊天软件发消息，系统会将你的回复按空行拆成多颗独立的聊天气泡。请全部使用你在输入框里实际打字发出的口语文字，把情绪与语气自然融进用词、断句和标点里。不同气泡之间用空行隔开，每颗气泡简短自然。',
            )
          : L.pick(
              en: '【Multi-Bubble Format】The system splits your reply by blank lines into separate chat bubbles.',
              zhTW: '【多氣泡格式】系統會將你的回覆按空行拆成多顆獨立的聊天氣泡。',
              zhCN: '【多气泡格式】系统会将你的回复按空行拆成多颗独立的聊天气泡。',
            );
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Reply Format',
          zhTWTitle: '回覆格式',
          zhCNTitle: '回复格式',
          content: '$splitIntro\n$splitRule',
        ),
      );
    }

    final replyStyle = ToolPrompts.selectedReplyStyle(
      conciseOn: conciseOn,
      freeformOn: freeformOn,
      emotionEnabled: emotionEnabled,
      maxLines: freeformOn ? await ApiSettings.getFreeformMaxLines() : 0,
    );
    if (replyStyle.isNotEmpty) {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Reply Style',
          zhTWTitle: '回覆風格',
          zhCNTitle: '回复风格',
          content: replyStyle,
        ),
      );
    }

    // 系統生成的蛛網通知屬於本輪 runtime context，不能追加到用戶原文。
    final memoLinkNotice = _memoLinkNotice(isSpiderWebEnabled);
    if (memoLinkNotice.isNotEmpty) dynamicParts.add(memoLinkNotice);

    final liveDynamicPart = SystemContextMarkdown.join(dynamicParts);
    var structured = StructuredPrompt(
      sessionIdentity: _requiredSessionIdentity,
      staticPart: staticBundle.staticPart,
      profilePart: staticBundle.profilePart,
      windowPart: staticBundle.windowPart,
      controlPart: SystemContextMarkdown.join(controlParts),
      liveStatePart: liveDynamicPart,
      cacheChannel: PromptCacheChannel.text,
    );

    var preflightSearchExecuted = false;
    var preflightSearchHasNoEvidence = false;
    String? preflightExplicitQuery =
        webSearchEnabled && userMsgWithId.id != null
        ? WebSearchIntentParser.explicitUserQuery(userMsgWithId.text)
        : null;

    // 若當前訊息為短追問（如「有嗎有嗎」「查到了嗎」），從歷史對話向前尋找上一條明確的搜尋請求
    if (webSearchEnabled &&
        preflightExplicitQuery == null &&
        userMsgWithId.id != null) {
      final isShortFollowUp = RegExp(
        r'^(?:有嗎|有吗|查到了嗎|查到了吗|結果呢|结果呢|怎麼樣了|怎么样了|找到了嗎|找到了吗|查出來了嗎|查出来了吗|有沒有|有没有|\?|？)+$',
      ).hasMatch(userMsgWithId.text.trim());
      if (isShortFollowUp) {
        for (final m in workingMessages.reversed.skip(1)) {
          if (m.isUser) {
            preflightExplicitQuery = WebSearchIntentParser.explicitUserQuery(
              m.text,
            );
            if (preflightExplicitQuery != null) break;
          }
        }
      }
    }

    if (preflightExplicitQuery != null) {
      preflightSearchExecuted = true;
      debugPrint(
        '[WebSearch] Executing pre-flight search '
        '(queryChars=${preflightExplicitQuery.runes.length})',
      );
      await _runWebSearchIntent(
        query: preflightExplicitQuery,
        userMessageId: userMsgWithId.id!,
        generationSerial: generationSerial,
      );
      final preSearchResult = _pendingWebSearchResult;
      if (preSearchResult != null) {
        final evidence = WebSearchFollowUp.evidenceFor(preSearchResult);
        if (evidence != null && evidence.isNotEmpty) {
          structured = structured.copyWith(ephemeralEvidencePart: evidence);
        }
      }
      if (_pendingWebSearchFailureContext.isNotEmpty) {
        structured = structured.copyWith(
          liveStatePart: SystemContextMarkdown.join(<String>[
            structured.liveStatePart,
            _pendingWebSearchFailureContext,
          ]),
        );
      }
      preflightSearchHasNoEvidence = WebSearchFollowUp.hasNoVerifiedEvidence(
        result: preSearchResult,
        failureContext: _pendingWebSearchFailureContext,
      );
    }

    // Keep the first pass visible. Search intent is parsed after the stream,
    // while protocol tags are already hidden by the shared display sanitizer.
    // Deferring this pass made every provider look like a static loader.
    final deferInitialStreamForSearchDecision = preflightSearchHasNoEvidence;

    if (mounted) {
      _refreshChatState(() {
        _setGenerating(true);
        _clearStreamQueue();
      });
    } else {
      _setGenerating(true);
      _clearStreamQueue();
    }

    final rawReply = StringBuffer();
    var streamCompleted = false;
    IosReplyBackgroundTask? backgroundReply;
    ReplyNotificationPayload? completionNotification;
    var replyPersisted = false;
    try {
      final enableVibration = await enableVibrationF;

      final nonEmpty = workingMessages
          .where(
            (m) =>
                !m.isUserFirstContinuation &&
                (m.text.isNotEmpty || m.imagePaths.isNotEmpty),
          )
          .toList();
      final previousWindowTurns = await previousWindowTurnsF;
      var history = <Map<String, String>>[
        ...previousWindowTurns.map((m) => m.toPromptHistoryEntry()),
      ];
      for (final m in nonEmpty) {
        history.add(
          await _promptHistoryEntry(m, uploadImages: m.id == userMsgWithId.id),
        );
      }

      // ═══ B4 滯後截斷（保護前綴緩存）═══
      final keepFrom = await _hysteresisKeepFrom(
        history.map((m) => (m['content'] ?? '').toString()).toList(),
      );
      if (keepFrom > 0 && keepFrom < history.length) {
        var start = keepFrom;
        history = history.sublist(keepFrom);
        // 截斷後保證從 user 開頭（部分 provider 嚴格要求交替）
        while (history.length > 1 && history.first['role'] != 'user') {
          history.removeAt(0);
          start++;
        }
        // 砍頭點同步為窗口錨點：重開窗按同一起點載入，
        // 砍頭與重開窗的炸點合併成同一次
        final currentWindowStart = start - previousWindowTurns.length;
        final anchorMsgId =
            currentWindowStart >= 0 && currentWindowStart < nonEmpty.length
            ? nonEmpty[currentWindowStart].id
            : null;
        if (anchorMsgId != null) {
          unawaited(_persistContextAnchor(anchorMsgId));
        }
      }

      var requestUsage = const ApiUsage();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }
      _activeRequestThinkingEnabled = thinkingEnabled;
      _activeRequestThinkingGeneration = generationSerial;
      final costStrategy = await ModelCostPolicy.resolveEffectiveStrategy(
        provider: providerName,
        model: model,
      );
      if (costStrategy.promptCacheEnabled) {
        await ApiSettings.recordSentThinkingState(
          conversationId: widget.conversationId,
          provider: providerName,
          model: model,
          cacheChannel: PromptCacheChannel.text,
          enabled: thinkingEnabled,
        );
      }
      backgroundReply = await IosReplyBackgroundTask.begin(
        source: userMsgWithId,
        onExpire: () {
          if (_isCurrentGeneration(generationSerial)) _stopActiveGeneration();
        },
      );
      if (preflightSearchHasNoEvidence) {
        // The technical reason remains in the Thinking/diagnostic surface.
        // Do not pay for a model pass that could blend stale provider errors
        // from chat history into a false account of the current attempt.
        rawReply.write(
          L.pick(
            en: 'I could not find reliable results just now. Let us try again later.',
            zhTW: '剛才沒有查到可靠的結果，晚一點再試試吧。',
            zhCN: '刚才没有查到可靠的结果，晚一点再试试吧。',
          ),
        );
      } else {
        await for (final chunk in adapter.sendMessageStream(
          messages: history,
          model: model,
          structuredPrompt: structured,
          onUsage: (usage) => requestUsage = usage,
        )) {
          if (!_isCurrentGeneration(generationSerial)) return;
          await turnEffects.commit();
          rawReply.write(chunk);
          if (backgroundReply != null) {
            await backgroundReply.record(
              ThinkingModePolicy.sanitizeVisibleReply(
                ThinkingModePolicy.moveProtocolTagsOutsideThinking(
                  _cleanIncompleteReply(rawReply.toString()),
                ),
                enabled: thinkingEnabled,
              ),
            );
          }
          if (mounted && !deferInitialStreamForSearchDecision) {
            _onStreamChunk(chunk);
          }
        }
        if (mounted && !deferInitialStreamForSearchDecision) {
          _closeModelStreamInput();
        }
      }
      streamCompleted = true;
      if (_stopGenerationRequested) {
        replyPersisted =
            await _persistIncompleteReply(rawReply.toString()) != null;
        _finishFailedGeneration();
        return;
      }
      await turnEffects.commit();
      final replyText = ThinkingModePolicy.sanitizeVisibleReply(
        ThinkingModePolicy.moveProtocolTagsOutsideThinking(rawReply.toString()),
        enabled: thinkingEnabled,
      );
      if (!_isCurrentGeneration(generationSerial)) return;
      final normalizedActionReply =
          ModelActionProtocol.normalizeForLegacyProcessors(replyText);
      final webSearchIntent = WebSearchIntentParser.parse(
        normalizedActionReply,
      );
      var replyTextWithoutWebSearch = webSearchIntent.visibleText;
      GuidePersonaDraft? newCharacterDraft;
      if (isNewCharacterCommand) {
        newCharacterDraft = GuideService.extractPersonaDraft(
          replyTextWithoutWebSearch,
        );
        replyTextWithoutWebSearch = GuideService.stripPersonaDraft(
          replyTextWithoutWebSearch,
        );
      }
      final visibleInitialText = webSearchIntent.query == null
          ? replyTextWithoutWebSearch
          : '';
      // Finish revealing the already accepted visible stream before replacing
      // it with the canonical final text. Otherwise fast relay providers can
      // swap a partially revealed Thinking reply for the whole body in one
      // frame, which looks like the final prose flashes into place.
      if (visibleInitialText.isNotEmpty) {
        await _finishStreamPresentation();
        if (!_isCurrentGeneration(generationSerial) ||
            _stopGenerationRequested) {
          _finishFailedGeneration();
          return;
        }
      }
      if (mounted) {
        _refreshChatState(() {
          _clearStreamQueue();
          _streamingText = visibleInitialText;
        });
      } else {
        _clearStreamQueue();
        _streamingText = visibleInitialText;
      }

      // The provider-visible reply is complete at this point. Do not keep the
      // bubble, avatar, or stop affordance in a streaming state while local
      // memory/emotion/timeline actions finish in the background. Any later
      // provider pass explicitly reopens the stream below.
      await _markVisibleReplyComplete();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }

      // ═══ 記錄真實 API 用量（不再用估算，避免雙重計算）═══
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        usage: requestUsage,
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
        requestKind: ApiRequestKind.chat,
      );

      // 檢查本次是否命中緩存
      final cacheRead = requestUsage.cacheReadTokens;
      if (cacheRead > 0) {
        CacheSession.markCacheHit(widget.conversationId);
      }

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = (memoryWriteEnabled || isSpiderWebEnabled)
          ? await _processScopedMemoryReply(
              replyTextWithoutWebSearch,
              emotionEnabled: emotionEnabled,
              provider: providerName,
              modelId: model,
              sourceMessageId: userMsgWithId.id,
            )
          : MemoryActions.stripReply(
              replyTextWithoutWebSearch,
              windowId: widget.conversationId,
              captureSearchQuery: true,
            );

      // ═══ 蛛網專屬標籤：<memo_link> 與 <force_recall> 處理 ═══
      if (isSpiderWebEnabled) {
        processedText = await SpiderWebCore.processReply(
          processedText,
          characterId: _activeCharacterId,
          windowId: widget.conversationId,
        );
      }

      // ═══ 商店系統：<buy> 處理 ═══
      processedText = await ShopService.processReply(
        processedText,
        characterName: _characterName,
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
      );

      // ═══ 情緒座標：<emo> 打點入庫並剝離 ═══
      // 同輪有 <memo> 時，點綁定那條記憶（同一輪 = 同一情緒時刻），
      // 翻舊帳由此能撈回「點 + 原記憶」
      processedText = emotionEnabled
          ? await EmotionCoordinates.processReply(
              processedText,
              characterId: _emotionScopeId,
              memoryId: MemoryActions.lastInsertedMemoryIdFor(
                widget.conversationId,
              ),
            )
          : EmotionCoordinates.stripReply(processedText);
      // ═══ 心情流光：<mood_color> 計輪、冷卻允許時換色並剝離 ═══
      processedText = await MoodGlowService.processReply(
        processedText,
        conversationId: widget.conversationId,
        mode: sessionIdentity.contextMode,
      );
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      if (sessionIdentity.contextMode == ContextMode.daily &&
          await MemorySettings.isAbilityEnabled('bioclock')) {
        processedText = await BioClockService.processReply(
          processedText,
          characterId: _activeCharacterId,
        );
      }
      // ═══ 角色生活化：只處理明確 <life_fix>；事件由摘要模型候選
      //     經本地驗證後寫入，不再掃回覆關鍵詞。═══
      if (await MemorySettings.getTimelineEnabled()) {
        processedText = sessionIdentity.contextMode == ContextMode.daily
            ? await CharacterTimelineService.processLifeFix(
                _activeCharacterId,
                processedText,
              )
            : CharacterTimelineService.stripLifeFix(processedText);
      }
      if (sessionIdentity.contextMode == ContextMode.daily &&
          await MemorySettings.isAbilityEnabled('bioclock')) {
        await BioClockService.recordLastChatTime(_activeCharacterId);
      }
      _isFirstRoundInWindow = false;
      processedText = await HomeNoteService.processReply(
        processedText,
        characterId: _activeCharacterId,
        enabled: toolFeatures.modelGreetingEnabled,
      );
      // ═══ 悄悄話：關閉覆蓋時仍剝標籤，但不接受模型寫入 ═══
      final whisperResult = await WhisperService.processReply(
        processedText,
        characterId: _activeCharacterId,
      );
      processedText = whisperResult.text;
      if (whisperResult.updated && mounted) {
        _refreshChatState(
          () => _composerHint = whisperResult.state.displayText,
        );
      }
      // ═══ 刮刮樂：<scratch> 標籤處理 ═══
      ScratchData? pendingScratch;
      final scratchMatch = RegExp(
        r'<scratch\s+who="(\w+)"\s*/>',
      ).firstMatch(processedText);
      if (scratchMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<scratch\s+[^>]*/>'), '')
            .trim();
        if (toolFeatures.scratchEnabled) {
          final who = scratchMatch.group(1) ?? 'char';
          // AI 觸發 → 扣角色的幣
          final ok = await ScratchService.spend(
            _activeCharacterId,
            ScratchService.ticketCost,
          );
          if (ok) {
            pendingScratch = ScratchData(
              cost: ScratchService.ticketCost,
              who: who,
              prizes: ScratchService.rollPrizes(),
              scratched: false,
            );
          } else if (mounted) {
            _showChatNotice(
              L.pick(
                en: '$_characterName does not have enough shells to send a scratch card.',
                zhTW: '【$_characterName】貝殼不足，無法送出刮刮樂',
              ),
              duration: const Duration(seconds: 2),
            );
          }
        }
      }
      // ═══ 生成 UI memoryLog 之前清理殘餘標籤 ═══
      String? drawPrompt;
      final drawEventMatch = RegExp(r'<draw\s*/>').firstMatch(processedText);
      if (drawEventMatch != null) {
        if (toolFeatures.imageGenerationEnabled) {
          drawPrompt = L.pick(
            en: '(reference image uploaded manually by the user / or retained by the system)',
            zhTW: '(由用戶手動上傳參考圖 / 或系統保留)',
          );
        }
        processedText = processedText
            .replaceAll(RegExp(r'<draw\s*/>'), '')
            .trim();
      }
      // ═══ 轉帳：<transfer> 標籤處理 ═══
      TransferData? pendingTransfer;
      final transferMatch = RegExp(
        r'<transfer\s+amount="(\d+)"\s*/>',
      ).firstMatch(processedText);
      if (transferMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer\s+[^>]*/>'), '')
            .trim();
        final amount = int.tryParse(transferMatch.group(1) ?? '') ?? 0;
        if (toolFeatures.transferEnabled && amount > 0) {
          pendingTransfer = TransferData(
            amount: amount,
            direction: 'toUser', // AI 觸發 → 角色轉給 user
          );
        }
      }
      // ═══ 轉帳回應：<transfer_accept/> / <transfer_decline/> ═══
      // AI 對用戶發起的 toChar 轉帳做出回應
      final hasAccept = RegExp(
        r'<transfer_accept\s*/>',
      ).hasMatch(processedText);
      final hasDecline = RegExp(
        r'<transfer_decline\s*/>',
      ).hasMatch(processedText);
      if (hasAccept || hasDecline) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer_accept\s*/>'), '')
            .replaceAll(RegExp(r'<transfer_decline\s*/>'), '')
            .trim();
      }
      if (toolFeatures.transferEnabled && (hasAccept || hasDecline)) {
        // 找到最近一條 pending 的 toChar 轉帳
        final pendingKey = _findPendingToCharTransfer();
        if (pendingKey != null) {
          if (hasAccept) {
            final accepted = await TransferService.acceptTransfer(
              pendingKey,
              _activeCharacterId,
            );
            if (accepted) _walletChanged = true;
          } else {
            await TransferService.declineTransfer(pendingKey);
          }
          final updated = await TransferService.getData(pendingKey);
          if (updated != null) _transferDataMap[pendingKey] = updated;
        }
      }
      // ═══ 結婚證簽署：<sign_marriage/>（text/image 雙路徑同款）═══
      if (_ChatScreenState._signMarriageRe.hasMatch(processedText)) {
        processedText = processedText
            .replaceAll(_ChatScreenState._signMarriageRe, '')
            .trim();
        await MarriageService.sign(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 結婚證主動遞出：<propose_marriage/> → 她的消息尾掛可簽證書 ═══
      if (_ChatScreenState._proposeMarriageRe.hasMatch(processedText)) {
        processedText = processedText
            .replaceAll(_ChatScreenState._proposeMarriageRe, '')
            .trim();
        processedText =
            '$processedText\n$_ChatScreenState._marriageCertCharTag';
        await MarriageService.markCharProposed(_activeCharacterId);
        unawaited(_refreshMarriageState());
      }
      // ═══ 模型發起通話：<call>開場白</call> / <call/> ═══
      String? pendingCallOpening;
      final callMatch = RegExp(
        r'<call>([\s\S]*?)</call>|<call\s*/>',
      ).firstMatch(processedText);
      if (callMatch != null) {
        if (sessionIdentity.contextMode == ContextMode.daily) {
          pendingCallOpening = (callMatch.group(1) ?? '').trim();
        }
        processedText = processedText
            .replaceAll(RegExp(r'<call>[\s\S]*?</call>'), '')
            .replaceAll(RegExp(r'<call\s*/>'), '')
            .trim();
      }
      // ═══ 模型畫畫：先出字後出圖（圖在後台生成，好了自己掛上）═══
      final drawMatch = RegExp(
        r'<draw>([\s\S]*?)</draw>',
      ).firstMatch(processedText);
      if (drawMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
            .trim();
        if (toolFeatures.imageGenerationEnabled) {
          drawPrompt = drawMatch.group(1)!.trim();
        }
      }
      // ═══ 歷史搜尋：<search_chat> 觸發可視化搜索 + 自動追加回覆 ═══
      final searchQuery = MemoryActions.lastSearchQueryFor(
        widget.conversationId,
      );
      if (searchQuery != null) {
        final searchScope = MemoryActions.lastSearchScopeFor(
          widget.conversationId,
        );
        if (!_isCurrentGeneration(generationSerial)) return;
        if (_stopGenerationRequested) {
          _finishFailedGeneration();
          return;
        }
        // Phase 1: 顯示搜索中狀態
        if (mounted) {
          _refreshChatState(() {
            _chatSearching = true;
            _chatSearchQuery = searchQuery;
            _chatSearchResults = [];
            _streamingText = processedText;
          });
          _scrollToBottom();
        }
        final searchResult = await _toolRunner.run(
          call: ToolCall.create(
            name: _chatSearchToolName,
            arguments: <String, Object?>{
              'query': searchQuery,
              'scope': searchScope,
            },
          ),
          context: ToolContext(
            conversationId: widget.conversationId,
            characterId: _activeCharacterId,
            mode: ToolRunMode.local,
            metadata: <String, Object?>{
              'generation_serial': generationSerial,
              'current_context_mode': sessionIdentity.contextMode.storageValue,
            },
          ),
        );
        if (!_isCurrentGeneration(generationSerial)) return;
        if (_stopGenerationRequested || searchResult.isCancelled) {
          _finishFailedGeneration();
          return;
        }
        final searchFailed = !searchResult.isSuccess;
        final searchResults = searchFailed
            ? <Map<String, dynamic>>[]
            : searchResult.requireData<List<Map<String, dynamic>>>();
        // Phase 2: 顯示搜索結果
        if (mounted) {
          _refreshChatState(() {
            _chatSearching = false;
            _chatSearchResults = searchResults;
          });
          _scrollToBottom();
        }
        {
          final nick = userNicknameStr.isNotEmpty
              ? userNicknameStr
              : L.pick(en: 'the other person', zhTW: '對方');
          final resultLines = searchResults
              .map((r) {
                final who = (r['is_user'] as int) == 1
                    ? nick
                    : L.pick(en: 'you', zhTW: '你');
                final rawDate = r['created_at']?.toString() ?? '';
                final parsedDate = DateTime.tryParse(rawDate);
                final date = parsedDate == null
                    ? rawDate
                    : ConversationTimeContext.formatAbsoluteTimestamp(
                        parsedDate,
                        locale: L.locale,
                      );
                var t = r['text']?.toString() ?? '';
                if (t.length > 200) t = '${t.substring(0, 200)}…';
                final rowMode = ContextMode.fromStorage(r['context_mode']);
                final modeLabel = rowMode == ContextMode.rp
                    ? 'RP'
                    : L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常');
                return '[$modeLabel][$date] $who${L.pick(en: ': ', zhTW: '：')}$t';
              })
              .toList(growable: false);
          final retrievalContext = ChatSearchFollowUp.context(
            query: searchQuery,
            excerpts: resultLines,
            failed: searchFailed,
            scope: searchScope,
          );
          // Phase 3: 二次流式生成
          final buf = StringBuffer();
          var followUsage = const ApiUsage();
          if (mounted) {
            _refreshChatState(() {
              _clearStreamQueue();
              _streamingText = '';
            });
          }
          if (_stopGenerationRequested) {
            _finishFailedGeneration();
            return;
          }
          await for (final chunk in adapter.sendMessageStream(
            messages: history,
            model: model,
            structuredPrompt: structured.copyWith(
              liveStatePart: SystemContextMarkdown.join(<String>[
                structured.liveStatePart,
                retrievalContext,
              ]),
            ),
            onUsage: (usage) => followUsage = usage,
          )) {
            if (!_isCurrentGeneration(generationSerial)) return;
            buf.write(chunk);
            if (mounted) _onStreamChunk(chunk);
          }
          if (mounted) _closeModelStreamInput();
          await _tokenTracker.recordRealUsage(
            provider: providerName,
            model: model,
            usage: followUsage,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
            requestKind: ApiRequestKind.chat,
          );
          if (followUsage.cacheReadTokens > 0) {
            CacheSession.markCacheHit(widget.conversationId);
          }
          var followUp = memoryWriteEnabled
              ? await _processScopedMemoryReply(
                  buf.toString(),
                  emotionEnabled: emotionEnabled,
                  resetState: false,
                  provider: providerName,
                  modelId: model,
                  sourceMessageId: userMsgWithId.id,
                )
              : MemoryActions.stripReply(
                  buf.toString(),
                  windowId: widget.conversationId,
                  resetState: false,
                );
          // ═══ 蛛網：follow-up 也需要處理 <memo_link>/<force_recall> ═══
          if (isSpiderWebEnabled) {
            followUp = await SpiderWebCore.processReply(
              followUp,
              characterId: _activeCharacterId,
              windowId: widget.conversationId,
            );
          }
          followUp = await ShopService.processReply(
            followUp,
            characterName: _characterName,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
          );
          followUp = emotionEnabled
              ? await EmotionCoordinates.processReply(
                  followUp,
                  characterId: _emotionScopeId,
                  memoryId: MemoryActions.lastInsertedMemoryIdFor(
                    widget.conversationId,
                  ),
                )
              : EmotionCoordinates.stripReply(followUp);
          // 二段回覆不計輪、不換色，只剝標籤。
          followUp = MoodGlowService.strip(followUp);
          followUp = HomeNoteService.strip(
            followUp,
          ).replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '').trim();
          if (followUp.isNotEmpty) {
            processedText = followUp;
          }
        }
        // Phase 4: 清除搜索卡片
        MemoryActions.clearSearchQuery(widget.conversationId);
        if (mounted) {
          _refreshChatState(() {
            _chatSearching = false;
            _chatSearchQuery = '';
            _chatSearchResults = [];
          });
        }
      }

      // ═══ 商店瀏覽：<shop_view/> two-pass（清單只在起念時注入，零緩存污染）═══
      if (_ChatScreenState._shopViewTagRe.hasMatch(processedText)) {
        processedText = processedText
            .replaceAll(_ChatScreenState._shopViewTagRe, '')
            .trim();
        if (await ShopService.isEnabled()) {
          final catalog = await ShopService.buildShopListPromptText();
          final injection =
              '${L.pick(en: '【Hidden Shop Catalog | invisible to user】', zhTW: '【隱藏商店清單｜user 不可見】')}\n$catalog\n---\n${L.pick(en: 'Use the latest shell-balance context. To buy, put <buy item="full-id" target="self or user"/> at the end of the next reply (use user to gift it). Otherwise continue naturally. Do not mention the catalog or system.', zhTW: '餘額以上下文最新的貝殼提示為準。想買就在接下來的回覆末尾用 <buy item="完整id" target="self或user"/>（送對方用 user）；不想買就自然繼續。不要提清單或系統本身。')}';
          final followHistory = [
            ...history,
            if (processedText.trim().isNotEmpty)
              {'role': 'assistant', 'content': processedText},
            {'role': 'user', 'content': injection},
          ];
          final buf = StringBuffer();
          var followUsage = const ApiUsage();
          if (mounted) {
            _visibleReplyComplete = false;
            _streamRevision.value++;
            _onStreamChunk('\n\n');
          }
          if (_stopGenerationRequested) {
            _finishFailedGeneration();
            return;
          }
          await for (final chunk in adapter.sendMessageStream(
            messages: followHistory,
            model: model,
            structuredPrompt: structured,
            onUsage: (usage) => followUsage = usage,
          )) {
            if (!_isCurrentGeneration(generationSerial)) return;
            buf.write(chunk);
            if (mounted) _onStreamChunk(chunk);
          }
          if (mounted) _closeModelStreamInput();
          await _tokenTracker.recordRealUsage(
            provider: providerName,
            model: model,
            usage: followUsage,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
            requestKind: ApiRequestKind.chat,
          );
          if (followUsage.cacheReadTokens > 0) {
            CacheSession.markCacheHit(widget.conversationId);
          }
          var followUp = MemoryActions.stripReply(
            buf.toString(),
            windowId: widget.conversationId,
            resetState: false,
          );
          followUp = await ShopService.processReply(
            followUp,
            characterName: _characterName,
            characterId: _activeCharacterId,
            conversationId: widget.conversationId,
          );
          followUp = emotionEnabled
              ? await EmotionCoordinates.processReply(
                  followUp,
                  characterId: _emotionScopeId,
                  memoryId: null,
                )
              : EmotionCoordinates.stripReply(followUp);
          // 二段回覆不計輪、不換色，只剝標籤。
          followUp = MoodGlowService.strip(followUp);
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .trim();
          if (followUp.isNotEmpty) {
            processedText = '$processedText\n\n$followUp'.trim();
          }
        }
      }

      processedText = await _extractDiaryAndStore(
        processedText,
        sourceMessageId: userMsgWithId.id,
        diaryEnabled: toolFeatures.diaryEnabled,
      );
      var emailDraftExtraction = EmailDraftTool.extract(processedText);
      EmailDraft? pendingEmailDraft = emailDraftExtraction.draft;
      processedText = emailDraftExtraction.visibleText;
      processedText = _extractXPostAndStrip(processedText);

      final webSearchQuery = !preflightSearchExecuted
          ? (webSearchIntent.query ??
                (webSearchEnabled
                    ? WebSearchIntentParser.explicitUserQuery(
                        userMsgWithId.text,
                      )
                    : null))
          : null;
      if (webSearchQuery != null && userMsgWithId.id != null) {
        if (mounted) {
          _refreshChatState(() => _streamingText = processedText);
        } else {
          _streamingText = processedText;
        }
        await _runWebSearchIntent(
          query: webSearchQuery,
          userMessageId: userMsgWithId.id!,
          generationSerial: generationSerial,
        );
        final webSearchResult = _pendingWebSearchResult;
        if (webSearchResult != null ||
            _pendingWebSearchFailureContext.isNotEmpty) {
          final followUp = await _generateWebSearchFollowUp(
            result: webSearchResult,
            failureContext: _pendingWebSearchFailureContext,
            history: history,
            adapter: adapter,
            model: model,
            structuredPrompt: structured,
            providerName: providerName,
            generationSerial: generationSerial,
          );
          if (followUp.isNotEmpty) processedText = followUp;
        }
      }

      final groundedSearchResult = _pendingWebSearchResult;
      if (groundedSearchResult != null &&
          groundedSearchResult.successes.isNotEmpty) {
        processedText = WebSearchFollowUp.ensureGroundedReply(
          reply: processedText,
          batch: groundedSearchResult,
        );
      }

      await _markVisibleReplyComplete();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }

      // 搜尋後的二次回覆也可產生草稿，並保證協議標籤不進聊天文字。
      processedText = await _extractDiaryAndStore(
        processedText,
        sourceMessageId: userMsgWithId.id,
        diaryEnabled: toolFeatures.diaryEnabled,
      );
      emailDraftExtraction = EmailDraftTool.extract(processedText);
      pendingEmailDraft = emailDraftExtraction.draft ?? pendingEmailDraft;
      processedText = emailDraftExtraction.visibleText;

      // ═══ 記憶過程日誌：只記寫入本地的操作 ═══
      // （注入給模型的內容不顯示——那是給她看的，不是給你看的）
      final memLogLines = <String>[
        ...MemoryActions.lastActionLogFor(widget.conversationId),
        ...EmotionCoordinates.lastPointLog,
        ...BioClockService.consumeLastActionLog(),
        if (drawPrompt != null) '🎨 生成中…',
      ];
      final memLog = memLogLines.isEmpty
          ? ''
          : '${memLogLines.join('\n')}\nDone';
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }
      await _finishStreamPresentation();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }
      final completedWebSearchResult = _pendingWebSearchResult;
      final completedWebSearchTrace = completedWebSearchResult
          ?.toDisplayTrace();
      processedText = VisibleModelOutput.reply(
        processedText,
        thinkingEnabled: thinkingEnabled,
      );
      if (processedText.trim().isEmpty && drawPrompt == null) {
        _reportEmptyVisibleReply(
          rawReply: rawReply.toString(),
          provider: providerName,
          model: model,
          usage: requestUsage,
        );
      }
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: cacheRead > 0,
        memoryLog: memLog,
        webSearchTrace: completedWebSearchTrace,
        emailDraft: pendingEmailDraft,
        personaCard: newCharacterDraft == null
            ? null
            : PersonaCardState(draft: newCharacterDraft),
      );
      final insertedId = await DatabaseHelper.insertMessage(aiMsg);
      replyPersisted = true;
      final notificationCharacter =
          await DatabaseHelper.getCharacter(_activeCharacterId) ??
          <String, dynamic>{'id': _activeCharacterId, 'name': _characterName};
      if (streamCompleted && !_stopGenerationRequested) {
        completionNotification =
            await ReplyNotificationService.notifyCompletion(
              character: notificationCharacter,
              reply: aiMsg.text,
              conversationId: conversationId,
            );
      }
      final repairIdentity = _requiredSessionIdentity;
      unawaited(
        ContextSummaryRepairService.processScope(
          characterId: repairIdentity.characterId,
          contextMode: repairIdentity.contextMode,
          continuityId: repairIdentity.continuityId,
        ),
      );
      await _clearChatDiagnosticForSource(userMsgWithId.id!);
      await _bindMemoryProposalsToMessage(insertedId);
      await MemoryActions.bindSelfNotesToMessage(
        widget.conversationId,
        insertedId,
      );
      unawaited(
        MarriageService.scanMessage(
          aiMsg.text,
          _activeCharacterId,
        ).then((_) => _refreshMarriageState()),
      );
      // 用插入後的 id 重建（避免 msg_null 導致收藏串連）
      final aiMsgWithId = Message(
        id: insertedId,
        conversationId: aiMsg.conversationId,
        characterId: aiMsg.characterId,
        text: aiMsg.text,
        isUser: false,
        splitMode: aiMsg.splitMode,
        cacheHit: aiMsg.cacheHit,
        status: aiMsg.status,
        createdAt: aiMsg.createdAt,
        imagePath: aiMsg.imagePath,
        imagePaths: aiMsg.imagePaths,
        memoryLog: aiMsg.memoryLog,
        webSearchTrace: aiMsg.webSearchTrace,
        emailDraft: aiMsg.emailDraft,
        personaCard: aiMsg.personaCard,
      );

      // 記錄命中的 messageId
      if (cacheRead > 0 && mounted) {
        _cacheHitIndices.add(_messages.length);
      }

      if (mounted) {
        _refreshChatState(() {
          _markFreshAssistantContext(insertedId);
          _messages.add(aiMsgWithId);
          if (completedWebSearchResult != null) {
            _webSearchResultsByMessageId[insertedId] = completedWebSearchResult;
          }
          _pendingWebSearchResult = null;
          _pendingWebSearchFailureContext = '';
          _webSearchActivity = null;
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _pendingWebSearchResult = null;
        _pendingWebSearchFailureContext = '';
        _webSearchActivity = null;
        _clearStreamQueue();
        _setGenerating(false);
      }
      if (drawPrompt != null && aiMsgWithId.id != null) {
        _runDrawAsync(aiMsgWithId.id!, drawPrompt, memLog, _activeCharacterId);
      }

      // ═══ 商店：消費本輪 <buy> 結果（送禮系統訊息即時上屏 + 失敗提示）═══
      await _consumeBuyResults(widget.conversationId);

      // ═══ X 發文：確認卡 → 發送 ═══
      await _handleXPost();

      // ═══ 模型來電：停 2.5 秒再響鈴（像她想了想才撥）═══
      if (pendingCallOpening != null) {
        _scheduleIncomingCall(pendingCallOpening);
      }

      // ═══ 刮刮樂：存數據 + 彈出刮卡 ═══
      if (pendingScratch != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await ScratchService.saveData(msgId, pendingScratch);
        _scratchDataMap[msgId] = pendingScratch;
        if (mounted) {
          // 稍等氣泡動畫完成再彈出
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            showScratchDialog(
              context,
              messageId: msgId,
              data: pendingScratch!,
              characterId: _activeCharacterId,
            ).then((_) async {
              // 刮完後更新本地 map + 刷新氣泡
              final updated = await ScratchService.getData(msgId);
              if (updated != null) _scratchDataMap[msgId] = updated;
              if (mounted) _refreshChatState(() {});
            });
          });
        }
      }

      // ═══ 轉帳：存數據 ═══
      if (pendingTransfer != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await TransferService.saveData(msgId, pendingTransfer);
        _transferDataMap[msgId] = pendingTransfer;
        if (mounted) _refreshChatState(() {});
      }

      // ═══ 回覆完成震動 + Cache 命中震動 ═══
      final cacheDisplay = _getCacheDisplay(providerName, requestUsage);
      if (mounted) {
        if (cacheDisplay != null && cacheDisplay.$1.contains('hit')) {
          HapticFeedback.heavyImpact(); // cache 命中用重震動
        } else if (enableVibration) {
          HapticFeedback.mediumImpact(); // 普通回覆用中震動
        }
      }

      await _recordCompletedRound(
        conversationId: conversationId,
        userText: promptVisibleOutboundText.isEmpty && hasImages
            ? '（圖片）'
            : promptVisibleOutboundText,
        assistantText: aiMsgWithId.text,
        heartbeatHistory: history,
        structuredPrompt: structured,
        adapter: adapter,
        model: model,
        provider: providerName,
      );

      // ═══ AI 自動命名 ═══
      if (_shouldAutoName) {
        _shouldAutoName = false;
        _autoNameConversation(
          _titleTextForFirstMessage(
            titleSeedText,
            pendingTransfer,
            pendingScratchGift,
          ),
          aiMsg.text,
          conversationId: conversationId,
        );
      }
    } on ApiConfigException catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      _finishFailedGeneration();
      await _persistApiFailure(
        e,
        sourceMessageId: userMsgWithId.id!,
        provider: providerName,
        model: model,
      );
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final incomplete = streamCompleted
          ? null
          : await _persistIncompleteReply(rawReply.toString());
      replyPersisted = replyPersisted || incomplete != null;
      _finishFailedGeneration();
      if (_stopGenerationRequested) return;
      await _persistApiFailure(
        e,
        sourceMessageId: userMsgWithId.id!,
        anchorMessageId: incomplete?.id,
        provider: providerName,
        model: model,
      );
    } finally {
      await backgroundReply?.finish(
        discard: replyPersisted,
        completed:
            replyPersisted && streamCompleted && !_stopGenerationRequested,
        notificationTitle: completionNotification?.title,
        notificationBody: completionNotification?.body,
        notificationPlaceholder: completionNotification?.placeholder,
        notificationCharacterId: completionNotification?.characterId,
      );
      if (_activeRequestThinkingGeneration == generationSerial) {
        _activeRequestThinkingEnabled = null;
        _activeRequestThinkingGeneration = null;
      }
      if (identical(_activeGenerationAdapter, adapter)) {
        _activeGenerationAdapter = null;
      }
    }
    if (mounted) _scrollToBottom();
  }

  /// 歷史消息轉 API 格式。帶圖消息只有本輪那一則真實上傳 base64，
  /// 更早的圖降級為文字佔位（內容靠記憶系統承接），避免每輪重傳圖片。
  /// 本輪的圖壞掉時 [ImageService.toBase64DataUrl] 的 FormatException
  /// 會往上拋，讓使用者知道；舊圖不上傳，所以不會拖累之後每一輪。
  Future<Map<String, String>> _promptHistoryEntry(
    Message m, {
    required bool uploadImages,
  }) async {
    if (m.imagePaths.isEmpty) return m.toPromptHistoryEntry();
    final text = m.promptVisibleText;
    final count = m.imagePaths.length;
    if (uploadImages && m.isUser) {
      final dataUrls = <String>[];
      for (final path in m.imagePaths) {
        final dataUrl = await ImageService.toBase64DataUrl(path);
        if (dataUrl != null) dataUrls.add(dataUrl);
      }
      if (dataUrls.isNotEmpty) {
        return <String, String>{
          'role': 'user',
          'content': text.isNotEmpty ? text : '（$count張圖片）',
          'image_data_url': dataUrls.first,
          'image_data_urls': jsonEncode(dataUrls),
        };
      }
    }
    return <String, String>{
      'role': m.isUser ? 'user' : 'assistant',
      'content': '（這裡曾發送$count張圖片${text.isNotEmpty ? '：$text' : ''}）',
    };
  }

  /// 構建用戶檔案 prompt
  Future<String> _buildUserProfilePrompt() async {
    final persona = _userPersona;
    return persona == null
        ? ''
        : UserPersonaService.buildIdentityPrompt(persona);
  }

  /// AI 自動命名（異步，不阻塞聊天）
  Future<void> _autoNameConversation(
    String userText,
    String aiText, {
    String? conversationId,
  }) async {
    try {
      final convId = conversationId ?? widget.conversationId;
      final adapter = await ApiSettings.buildAdapter(
        thinkingEnabledOverride: false,
      );
      final model = await ApiSettings.getModel();
      final provider = await ApiSettings.getApiProvider();
      final char = await DatabaseHelper.getCharacter(_activeCharacterId);
      final characterName = (char?['name'] as String? ?? _characterName).trim();
      final relationship = (char?['relationship'] as String? ?? '').trim();
      final characterProfile = truncateGraphemes(
        (char?['description'] as String? ?? '').trim(),
        500,
      );
      final userName = _userPersonaName;
      final cleanUser = VisibleModelOutput.finalOnly(userText);
      final cleanCharacter = VisibleModelOutput.finalOnly(aiText);
      final dialogueUser = truncateGraphemes(cleanUser, 160);
      final dialogueCharacter = truncateGraphemes(cleanCharacter, 160);
      final localFallback = truncateGraphemes(
        cleanUser.isNotEmpty
            ? cleanUser.replaceAll(RegExp(r'\s+'), ' ').trim()
            : L.pick(en: 'New conversation', zhTW: '新的對話', zhCN: '新的对话'),
        20,
      );

      ApiUsage? usage;
      final response = await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content':
                '${L.pick(en: 'Character name: ', zhTW: '角色姓名：')}$characterName\n'
                '${L.pick(en: 'Other person: ', zhTW: '對方姓名：')}$userName\n'
                '${L.pick(en: 'Relationship: ', zhTW: '兩人關係：')}$relationship\n'
                '${L.pick(en: 'Character profile: ', zhTW: '角色設定：')}$characterProfile\n\n'
                '${L.pick(en: 'Other person: ', zhTW: '對方：')}$dialogueUser\n'
                '${L.pick(en: 'Character: ', zhTW: '角色：')}$dialogueCharacter',
          },
        ],
        model: model,
        systemPrompt: L.pick(
          en: 'Name this conversation in the character\'s own voice. Reflect their tone, how they address the other person, and their relationship; make it feel like a title the character would naturally choose, not a neutral category label. Keep it to 2–8 words. Output only the title, without wrapping quotes or explanation.',
          zhTW:
              '用角色本人的語氣替這段對話取名。參照角色的說話方式、對對方的稱呼與兩人關係，像角色自己自然取出的名字，不要寫成中性的分類標籤，也不必每次都硬塞對方姓名。控制在 4～12 字；只輸出標題，不加外層引號或解釋。',
        ),
        onUsage: (value) => usage = value,
      );
      await _tokenTracker.recordRealUsage(
        provider: provider,
        model: model,
        usage: usage ?? const ApiUsage(),
        characterId: _activeCharacterId,
        conversationId: widget.conversationId,
        requestKind: ApiRequestKind.conversationTitle,
      );

      var title = VisibleModelOutput.finalOnly(
        response,
      ).trim().split('\n').first.trim();
      title = title.replaceFirst(
        RegExp(r'^(?:標題|标题|title)\s*[:：]\s*', caseSensitive: false),
        '',
      );
      title = title.replaceAll(RegExp(r'''^[「」『』“”"']+|[「」『』“”"']+$'''), '');
      title = truncateGraphemes(title.trim(), 20);
      if (title.isEmpty || VisibleModelOutput.containsInternalMarkup(title)) {
        title = localFallback;
      }
      if (title.isNotEmpty) {
        await DatabaseHelper.updateConversation(convId, title: title);
        if (!mounted) return;
        _refreshChatState(() => _conversationTitle = title);
      }
    } catch (_) {
      // 命名失敗不影響聊天
    }
  }
}
