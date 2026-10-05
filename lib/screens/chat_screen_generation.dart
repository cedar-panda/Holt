part of 'chat_screen.dart';

extension _ChatGenerationMethods on _ChatScreenState {
  Future<String> _processScopedMemoryReply(
    String text, {
    required bool emotionEnabled,
    bool resetState = true,
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
    );
  }

  /// 生成態統一入口：熄屏/退後台會凍結流式回覆，
  /// 生成期間掛前台服務保護（GenerationForegroundGuard），結束即撤
  void _setGenerating(bool v) {
    if (_isGenerating == v) return;
    _isGenerating = v;
    if (v) {
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
    _streamFirstChunkAt ??= DateTime.now();
    _streamCharQueue.addAll(chunk.characters);
    _scheduleStreamDrain();
  }

  void _scheduleStreamDrain() {
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
    _streamingText = '';
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

  void _configureStreamPresentation(String provider) {
    _streamPresentationMode = StreamPresentationPolicy.forProvider(provider);
  }

  String _computeDisplayStreamingText() {
    // 1. 剝離已完成的標籤
    var text = _streamingText
        .replaceAll(_ChatScreenState._completedToolCallsRe, '')
        .replaceAll(_ChatScreenState._completedTagRe, '')
        .replaceAll(_ChatScreenState._scratchTagRe, '')
        .replaceAll(_ChatScreenState._shopViewTagRe, '')
        .replaceAll(_ChatScreenState._transferTagRe, '')
        .replaceAll(_ChatScreenState._transferResponseRe, '')
        .replaceAll(_ChatScreenState._signMarriageRe, '')
        .replaceAll(_ChatScreenState._proposeMarriageRe, '')
        .replaceAll(_ChatScreenState._buyTagRe, '');
    // 2. 截斷未關閉的標籤（正在接收中）
    final toolCallMatch = _ChatScreenState._openToolCallsRe.firstMatch(text);
    if (toolCallMatch != null) {
      text = text.substring(0, toolCallMatch.start);
    }
    final openMatch = _ChatScreenState._openTagRe.firstMatch(text);
    if (openMatch != null) {
      text = text.substring(0, openMatch.start);
    }
    // 3. 截斷剛剛開始輸入的疑似標籤前綴，例如 `<m`, `<emo` 等（不帶空格的純字母組合）
    final partialTagMatch = RegExp(r'<[a-zA-Z_]*$').firstMatch(text);
    if (partialTagMatch != null) {
      text = text.substring(0, partialTagMatch.start);
    }
    return ThinkingModePolicy.sanitizeVisibleReply(
      ThinkingModePolicy.moveProtocolTagsOutsideThinking(text.trim()),
      enabled: _activeRequestThinkingEnabled ?? _generationThinkingEnabled,
    );
  }

  int _beginGeneration() {
    _stopGenerationRequested = false;
    _webSearchActivity = null;
    _pendingWebSearchResult = null;
    _pendingWebSearchFailureContext = '';
    return ++_generationSerial;
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

  /// 提取 `<x_post>` 內容並剝離，再走通用殘尾清理。
  /// 必須在 _stripInternalToolCalls 之前提取——_ChatScreenState._openTagRe 已含 x_post，
  /// 先 strip 會把標籤連同後文一起截掉。text/image 雙路徑共用。
  String _extractXPostAndStrip(String text) {
    _pendingXPost = null;
    final m = RegExp(r'<x_post>([\s\S]*?)</x_post>').firstMatch(text);
    if (m != null) {
      final content = m.group(1)!.trim();
      if (content.isNotEmpty) _pendingXPost = content;
      text = text.replaceAll(RegExp(r'<x_post>[\s\S]*?</x_post>'), '').trim();
    }
    return _stripInternalToolCalls(text);
  }

  Future<String> _extractDiaryAndStore(
    String text, {
    required int? sourceMessageId,
    required bool diaryEnabled,
  }) async {
    final result = await CharacterDiaryService.processReply(
      text: text,
      characterId: _activeCharacterId,
      conversationId: widget.conversationId,
      sourceMessageId: sourceMessageId,
      contextMode: _requiredSessionIdentity.contextMode,
      enabled: diaryEnabled,
    );
    return result.visibleText;
  }

  /// 發推流程：限額/連接檢查 → 確認卡（承諾過「先過目」）→ 發送。
  Future<void> _handleXPost() async {
    final content = _pendingXPost;
    _pendingXPost = null;
    if (content == null) return;
    final charId = _activeCharacterId;
    if (!await XPostSettings.canPost(charId)) return; // 未啟用/超限：靜默
    if (!mounted) return;
    if (!await XPostService.isConnected(charId)) {
      if (!mounted) return; // await 後 context 需重新確認
      _showChatNotice(
        L.pick(
          en: '$_characterName wanted to post, but the X account is not connected.',
          zhTW: '【$_characterName】起念發了條推文，但 X 帳號尚未連接',
        ),
        duration: const Duration(seconds: 2),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(
            en: '$_characterName wants to post',
            zhTW: '$_characterName 想發一則推文',
          ),
          style: YanciTheme.headingMedium,
        ),
        content: Text(content, style: YanciTheme.bodyText),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Not now', zhTW: '先不發')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: YanciTheme.accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Post', zhTW: '發送')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await XPostService.postTweet(charId, content);
    if (err == null) await XPostSettings.incrementToday(charId);
    if (!mounted) return;
    _showChatNotice(
      err ?? L.pick(en: 'Posted to X 🦦', zhTW: '已發布到 X 🦦'),
      tone: err == null ? ThemedNoticeTone.neutral : ThemedNoticeTone.error,
      duration: const Duration(seconds: 3),
    );
  }

  String _stripInternalToolCalls(String text) {
    return text
        .replaceAll(_ChatScreenState._completedToolCallsRe, '')
        .replaceAll(_ChatScreenState._openTagRe, '')
        .trim();
  }

  String _appendTransferTag(String text, TransferData? transfer) {
    final trimmed = text.trim();
    if (transfer == null) return trimmed;
    final tag = '[transfer:${transfer.amount}]';
    return trimmed.isEmpty ? tag : '$trimmed\n$tag';
  }

  String _appendScratchGiftTag(String text, ScratchData? scratch) {
    final trimmed = text.trim();
    if (scratch == null) return trimmed;
    final tag = '[scratch_gift:${scratch.who}]';
    return trimmed.isEmpty ? tag : '$trimmed\n$tag';
  }

  String _titleTextForFirstMessage(
    String text,
    TransferData? transfer,
    ScratchData? scratch,
  ) {
    if (text.trimLeft().startsWith(Message.rpChapterContinuationPrefix)) {
      final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
      return L.pick(
        en: isRp ? 'Continue this chapter' : 'Continue this conversation',
        zhTW: isRp ? '繼續這一篇章' : '繼續這段對話',
        zhCN: isRp ? '继续这一篇章' : '继续这段对话',
      );
    }
    final trimmed = MarriageService.stripHiddenCertMetadata(text);
    if (trimmed.isNotEmpty) return trimmed;
    if (scratch != null) {
      return L.pick(en: 'Scratch card gift', zhTW: '刮刮卡禮物');
    }
    if (transfer == null) return '';
    return L.pick(
      en: 'Transfer ${transfer.amount} shells',
      zhTW: '轉帳 ${transfer.amount} 貝殼',
    );
  }

  String _scratchGiftDynamicPrompt(ScratchData? scratch) {
    if (scratch == null || scratch.who != 'char') return '';
    final resultsZh = scratch.prizes
        .map((p) => p.coins > 0 ? '+${p.coins} 貝殼' : p.label)
        .join(' ➝ ');
    if (L.locale == 'en') {
      final resultsEn = scratch.prizes
          .map((p) => p.coins > 0 ? '+${p.coins} shells' : p.label)
          .join(' ➝ ');
      return '【Scratch Card Gift】The user bought a scratch card and let you scratch it. The app has already scratched it locally. Result: $resultsEn. If shells were won, they have already been added to your current balance. React naturally to being given the card and to the result.';
    }
    return '${L.pick(en: '', zhTW: '【刮刮卡禮物】用戶買了一張刮刮卡讓你刮。App 已在本地完成刮卡，結果：')}$resultsZh${L.pick(en: '', zhTW: '。若中了貝殼，已經加到你目前餘額。請自然回應「對方讓你刮」這件事，以及這次刮出的結果。')}';
  }

  Future<void> _ensureCoinSnapshot(String characterId) async {
    if (_coinSnapshotChar != null && _coinSnapshotUser != null) return;

    var snapshot = await DatabaseHelper.getConversationPinnedCoinSnapshot(
      widget.conversationId,
    );
    if (snapshot == null) {
      final characterCoins = await ScratchService.getCoins(characterId);
      final userCoins = await ScratchService.getUserCoins();
      snapshot = await DatabaseHelper.setConversationPinnedCoinSnapshotIfAbsent(
        widget.conversationId,
        characterCoins: characterCoins,
        userCoins: userCoins,
      );
    }
    _coinSnapshotChar = snapshot.characterCoins;
    _coinSnapshotUser = snapshot.userCoins;
  }

  Future<String> _coinStaticPrompt(String characterId) async {
    await _ensureCoinSnapshot(characterId);

    if (L.locale == 'en') {
      return '【Shell Balance Snapshot】At the start of this chat window: your balance is $_coinSnapshotChar shells; the user balance is $_coinSnapshotUser shells. This static snapshot is kept stable for prompt caching. Later daily grants, transfers, and scratch-card changes are provided as deltas in dynamic context; always follow the latest delta when present.';
    }

    return L.pick(
      en: '',
      zhTW:
          '【貝殼餘額快照】本聊天窗口開篇時：你的餘額 $_coinSnapshotChar 貝殼；用戶餘額 $_coinSnapshotUser 貝殼。此靜態快照為了穩定 prompt cache 不再改動；後續每日發放、轉帳與刮刮卡變動會在動態上下文以增減量補充，有變動時以最新增減量為準。',
      zhCN:
          '【贝壳余额快照】本聊天窗口开篇时：你的余额 $_coinSnapshotChar 贝壳；用户余额 $_coinSnapshotUser 贝壳。此静态快照为了稳定 prompt cache 不再改动；后续每日发放、转账与刮刮卡变动会在动态上下文以增减量补充，有变动时以最新增减量为准。',
    );
  }

  Future<String> _coinDeltaPrompt(String characterId) async {
    await _ensureCoinSnapshot(characterId);

    final currentChar = await ScratchService.getCoins(characterId);
    final currentUser = await ScratchService.getUserCoins();
    final charDelta = currentChar - _coinSnapshotChar!;
    final userDelta = currentUser - _coinSnapshotUser!;
    if (charDelta == 0 && userDelta == 0) return '';

    String signed(int value) => value >= 0 ? '+$value' : '$value';
    if (L.locale == 'en') {
      return '【Shell Balance Delta】Since this window opened: your balance ${signed(charDelta)} → now $currentChar shells; user balance ${signed(userDelta)} → now $currentUser shells. Use these current balances for transfer/scratch decisions.';
    }

    return L.pick(
      en: '',
      zhTW:
          '【貝殼餘額變動】自本窗口開篇後：你的餘額 ${signed(charDelta)}，目前 $currentChar 貝殼；用戶餘額 ${signed(userDelta)}，目前 $currentUser 貝殼。轉帳與刮刮卡判斷請以目前餘額為準。',
      zhCN:
          '【贝壳余额变动】自本窗口开篇后：你的余额 ${signed(charDelta)}，目前 $currentChar 贝壳；用户余额 ${signed(userDelta)}，目前 $currentUser 贝壳。转账与刮刮卡判断请以目前余额为准。',
    );
  }

  String _timePrompt(DateTime now) {
    final offset = now.timeZoneOffset;
    final offsetSign = offset.isNegative ? '-' : '+';
    final offsetMinutes = offset.inMinutes.abs();
    final offsetText =
        'UTC$offsetSign${(offsetMinutes ~/ 60).toString().padLeft(2, '0')}:${(offsetMinutes % 60).toString().padLeft(2, '0')}';
    if (L.locale == 'en') {
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return '【Current Local Time】${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} ($offsetText)';
    }
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return L.pick(
      en: '',
      zhTW:
          '【當前本地時間】${now.year}年${now.month}月${now.day}日 週${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}（$offsetText）',
    );
  }

  /// 消費本輪 `<buy>` 結果：送 user 成功 → 系統訊息落庫並即時上屏；
  /// 失敗 → SnackBar 提示（模型側回饋走 pendingBuyFailureNote 動態注入）。
  /// text / image 雙路徑共用此消費點。
  Future<void> _consumeBuyResults(String conversationId) async {
    if (ShopService.lastBuyResults.isEmpty) return;
    final results = List<Map<String, String>>.from(ShopService.lastBuyResults);
    ShopService.lastBuyResults.clear();
    for (final r in results) {
      if (r['success'] == '1' && r['target'] == 'user') {
        final sysMsg = Message(
          conversationId: conversationId,
          characterId: _activeCharacterId,
          text: '*(TA從商店買了「${r['name']}」送給你，已放入背包)*',
          isUser: false,
          createdAt: DateTime.now(),
        );
        final id = await DatabaseHelper.insertMessage(sysMsg);
        if (mounted) {
          _refreshChatState(() {
            _messages.add(
              Message(
                id: id,
                conversationId: sysMsg.conversationId,
                characterId: sysMsg.characterId,
                text: sysMsg.text,
                isUser: false,
                createdAt: sysMsg.createdAt,
              ),
            );
          });
          _scrollToBottom();
        }
      } else if (r['success'] == '0' && mounted) {
        _showChatNotice(
          '【$_characterName】想買「${r['name']}」沒成功：${r['reason']}',
          tone: ThemedNoticeTone.error,
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  Future<_StaticPromptBundle> _buildCommonStaticParts({
    required String characterId,
    required String systemPrompt,
    required String charDesc,
    required String characterName,
    required String userProfile,
    required String selfNotes,
    required String userNickname,
    required bool isSpiderWebEnabled,
    required bool memoryWriteEnabled,
    required bool emotionEnabled,
    required bool bioclockEnabled,
    required bool imagegenEnabled,
    required bool webSearchEnabled,
    required bool whisperModelOverrideEnabled,
    required String providerName,
    required String staticWindowSummary,
    required ContextMode contextMode,
    required ToolFeatureState toolFeatures,
  }) async {
    final toolPromptsEnabled = toolFeatures.toolPromptsEnabled;
    if (toolPromptsEnabled &&
        bioclockEnabled &&
        (_habitSnapshotIds == null || _habitListSnapshot == null)) {
      _habitSnapshotIds = await BioClockService.habitIds(characterId);
      _habitListSnapshot = await BioClockService.habitListPrompt(characterId);
    }
    final habitList = toolPromptsEnabled && bioclockEnabled
        ? (_habitListSnapshot ?? '')
        : '';

    if (selfNotes.isNotEmpty &&
        (_selfNotesSnapshot == null || _selfNotesSnapshotLines == null)) {
      final convId = widget.conversationId;
      var pinned = await DatabaseHelper.getConversationPinnedSelfNotes(convId);
      pinned ??= await DatabaseHelper.setConversationPinnedSelfNotesIfAbsent(
        convId,
        selfNotes,
      );
      _selfNotesSnapshot = pinned;
      _selfNotesSnapshotLines = pinned.isEmpty
          ? <String>{}
          : pinned.split('\n').toSet();
    }

    if (toolPromptsEnabled) {
      _stickerPromptSnapshot ??= await StickerService.buildStickerPrompt(
        characterId: characterId,
      );
    }
    // 背包窗內快照（delta 基準），與其他快照同點初始化
    if (toolPromptsEnabled && toolFeatures.shopEnabled) {
      _packQtySnapshot ??= await ShopService.packQtySnapshot(characterId);
    }

    final staticParts = <String>[];
    final windowParts = <String>[];
    final normalizedSystemPrompt = systemPrompt.trim();
    final normalizedCharacterDescription = charDesc.trim();
    // Older builds copied the selected character description into the global
    // system prompt. Keep custom global instructions, but do not inject that
    // legacy mirror twice into every request.
    if (normalizedSystemPrompt.isNotEmpty &&
        normalizedSystemPrompt != normalizedCharacterDescription) {
      staticParts.add(normalizedSystemPrompt);
    }
    if (normalizedCharacterDescription.isNotEmpty) {
      staticParts.add(
        '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$normalizedCharacterDescription',
      );
    } else if (normalizedSystemPrompt.isNotEmpty) {
      staticParts.add(normalizedSystemPrompt);
    }
    if (selfNotes.isNotEmpty && _selfNotesSnapshot?.isNotEmpty == true) {
      windowParts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$_selfNotesSnapshot',
      );
    }
    // 已婚狀態（僅已簽角色注入；未簽空串＝前綴逐字節不變。
    // 簽署瞬間變一次＝一次性重建，之後永久命中）
    final marriageNote = await MarriageService.staticPrompt(characterId);
    if (marriageNote.isNotEmpty) windowParts.add(marriageNote);
    if (toolPromptsEnabled &&
        toolFeatures.shellEconomyEnabled &&
        toolFeatures.coinSnapshotEnabled) {
      windowParts.add(await _coinStaticPrompt(characterId));
    }
    if (staticWindowSummary.isNotEmpty) {
      windowParts.add(staticWindowSummary);
    }

    final toolSections = <String>[];
    if (toolPromptsEnabled && isSpiderWebEnabled) {
      toolSections.add(
        await SpiderWebService.abilityPrompt(
          userNickname: userNickname,
          characterId: characterId,
          characterName: characterName,
          emotionEnabled: emotionEnabled,
          bioclockEnabled: bioclockEnabled,
        ),
      );
    } else if (toolPromptsEnabled) {
      if (memoryWriteEnabled) {
        toolSections.add(
          contextMode == ContextMode.rp
              ? RpMemoryService.abilityPrompt(
                  userNickname: userNickname,
                  characterName: characterName,
                )
              : MemoryActions.abilityPrompt(
                  userNickname: userNickname,
                  characterName: characterName,
                ),
        );
      }
      if (emotionEnabled) {
        toolSections.add(EmotionCoordinates.abilityPrompt());
      }
      if (bioclockEnabled) {
        toolSections.add(BioClockService.abilityPrompt());
      }
    }
    if (toolPromptsEnabled &&
        toolFeatures.imageGenerationEnabled &&
        imagegenEnabled &&
        await ImageGenService.isConfigured()) {
      toolSections.add(ImageGenService.abilityPrompt());
    }
    if (toolPromptsEnabled && webSearchEnabled) {
      toolSections.add(ToolPrompts.webSearch());
    }
    // 商店（全語言/全模式；固定文本零緩存污染；清單走 two-pass 按需查詢）
    if (toolPromptsEnabled && toolFeatures.shopEnabled) {
      toolSections.add(ToolPrompts.shop());
    }
    if (toolPromptsEnabled) toolSections.add(ToolPrompts.homeNote());
    if (toolPromptsEnabled && whisperModelOverrideEnabled) {
      toolSections.add(ToolPrompts.whisper());
    }
    if (toolPromptsEnabled && toolFeatures.scratchEnabled) {
      toolSections.add(ToolPrompts.scratchCard());
    }
    if (toolPromptsEnabled && toolFeatures.transferEnabled) {
      toolSections.add(ToolPrompts.transfer());
    }
    if (toolPromptsEnabled && contextMode == ContextMode.daily) {
      toolSections.add(ToolPrompts.voiceCall());
    }
    // X 發文（開關開啟才注入說明；剩餘條數等動態信息走 dynamicParts）
    if (toolPromptsEnabled && await XPostSettings.isEnabled(characterId)) {
      toolSections.add(ToolPrompts.xPost());
    }
    if (toolPromptsEnabled && _stickerPromptSnapshot?.isNotEmpty == true) {
      windowParts.add(_stickerPromptSnapshot!);
    }

    if (toolSections.isNotEmpty) {
      staticParts.add(
        '${ToolPrompts.toolHeader()}\n\n${toolSections.join('\n\n')}',
      );
    }

    if (habitList.isNotEmpty) windowParts.add(habitList);

    return _StaticPromptBundle(
      staticPart: staticParts.join('\n\n'),
      profilePart: userProfile.isNotEmpty ? userProfile : null,
      windowPart: windowParts.join('\n\n'),
    );
  }

  Future<void> _restoreTokensSinceSummary() async {
    try {
      // The DB cursor is authoritative. The old timestamp comparison used the
      // latest summary of the whole character, so one window could make
      // another window appear fully summarized. SharedPreferences remains a
      // quick persisted mirror, never the source of truth.
      final calcCount = await ContextCompressor.pendingTokenCount(
        widget.conversationId,
      );
      if (mounted) {
        _refreshChatState(() {
          _tokensSinceSummary = calcCount;
        });
      }
      await _saveTokensSinceSummary();
    } catch (e) {
      debugPrint('Error restoring tokensSinceSummary: $e');
    }
  }

  Future<void> _saveTokensSinceSummary() async {
    try {
      final p = await SharedPreferences.getInstance();
      final value = _tokensSinceSummary;
      await p.setInt(_tokensSinceSummaryKey, value);
    } catch (e) {
      debugPrint('Error saving tokensSinceSummary: $e');
    }
  }

  Future<void> _claimVisibleKeepAliveWindow() async {
    if (!mounted || !_isChatReady) return;
    final sessionIdentity = _requiredSessionIdentity;
    CacheSession.bind(sessionIdentity);

    final history = _messages
        .where((m) => m.text.trim().isNotEmpty)
        .map((m) => m.toPromptHistoryEntry())
        .toList();

    await KeepAliveService.instance.claimVisibleWindow(
      sessionIdentity: sessionIdentity,
      messages: history,
    );
  }

  Future<String> _memoryBucket() async =>
      (await MemorySettings.getMemoryMode()) == 'story' ? 'story' : 'romance';

  /// Language changes are an explicit one-time static-prefix invalidation.
  /// Refresh only language-bearing snapshots; keep data baselines intact so
  /// deltas, summary pins, and append-only history semantics do not change.
  void _syncPromptLocaleCaches() {
    if (_promptLocaleSnapshot == L.locale) return;
    final hadLocale = _promptLocaleSnapshot != null;
    _promptLocaleSnapshot = L.locale;
    if (!hadLocale) return;
    _stickerPromptSnapshot = null;
    _habitListSnapshot = null;
    _cacheWindowSummaryStaticSnapshot = null;
  }

  String _selfNotesDeltaPrompt(String selfNotes) {
    if (selfNotes.isEmpty || _selfNotesSnapshotLines == null) return '';
    final freshNotes = selfNotes
        .split('\n')
        .where(
          (line) =>
              line.trim().isNotEmpty &&
              !_selfNotesSnapshotLines!.contains(line),
        )
        .toList();
    if (freshNotes.isEmpty) return '';
    return '${L.pick(en: '【Self-notes added or refined this window】', zhTW: '【本窗口你新增或修訂的自我註記】')}\n'
        '${L.pick(en: 'When one resembles an older snapshot note, treat this newer wording as its replacement.', zhTW: '若與窗口快照中的舊註記近似，以這裡的新版本為準。')}\n'
        '${freshNotes.join('\n')}';
  }

  /// 滯後截斷：平時錨點固定（前綴穩定，不打斷緩存）；
  /// 超限時一次砍到限額 60%，然後再次固定，直到下次超限。
  /// 舊版每輪重算截斷點 → 前綴每輪變 → 開上下文限制 = 關緩存。
  Future<int> _hysteresisKeepFrom(List<String> contents) async {
    final enabled = await MemorySettings.getContextLimitEnabled();
    final limit = await MemorySettings.getContextTokenLimit();
    if (!enabled || limit <= 0 || contents.length <= 1) return 0;
    var from = _contextKeepFrom;
    if (from >= contents.length) from = contents.length - 1;
    if (from < 0) from = 0;
    int total = 0;
    for (int i = from; i < contents.length; i++) {
      total += TokenEstimator.estimate(contents[i]);
    }
    if (total <= limit) return from;
    final target = (limit * 0.6).round();
    int acc = 0;
    int keep = contents.length - 1;
    for (int i = contents.length - 1; i >= from; i--) {
      acc += TokenEstimator.estimate(contents[i]);
      if (acc > target) {
        keep = i + 1;
        break;
      }
      keep = i;
    }
    if (keep >= contents.length) keep = contents.length - 1;
    _contextKeepFrom = keep;
    return keep;
  }

  /// 後台畫圖：不阻塞回覆顯示，完成後更新消息的圖與日誌
  Future<void> _runDrawAsync(
    int messageId,
    String prompt,
    String baseLog,
    String characterId,
  ) async {
    if (mounted) {
      _refreshChatState(() {
        _isGeneratingImage = true;
        final idx = _messages.indexWhere((m) => m.id == messageId);
        if (idx >= 0) {
          final m = _messages[idx];
          _messages[idx] = Message(
            id: m.id,
            conversationId: m.conversationId,
            characterId: m.characterId,
            text: m.text,
            isUser: false,
            imagePath: 'generating',
            splitMode: m.splitMode,
            cacheHit: m.cacheHit,
            status: m.status,
            memoryLog: m.memoryLog,
            webSearchTrace: m.webSearchTrace,
            createdAt: m.createdAt,
          );
        }
      });
    }
    String note;
    String? path;
    try {
      // 讀取角色卡綁定的畫畫錨點
      final anchors = await DatabaseHelper.getDrawAnchors(_activeCharacterId);
      path = await ImageGenService.generate(
        prompt,
        userAnchor: anchors.user,
        charAnchor: anchors.char,
        style: anchors.style,
        characterId: characterId,
      );
      note = '🎨 生成圖片 ✓';
    } catch (e) {
      final msg = e.toString();
      note = '🎨 畫圖失敗：${msg.length > 140 ? msg.substring(0, 140) : msg}';
    }
    final newLog = baseLog.contains('🎨 生成中…')
        ? baseLog.replaceFirst('🎨 生成中…', note)
        : baseLog;
    await DatabaseHelper.updateMessageDraw(messageId, path, newLog);
    if (!mounted) return;
    _refreshChatState(() {
      _isGeneratingImage = false;
      final idx = _messages.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        final m = _messages[idx];
        _messages[idx] = Message(
          id: m.id,
          conversationId: m.conversationId,
          characterId: m.characterId,
          text: m.text,
          isUser: false,
          imagePath: path ?? m.imagePath,
          splitMode: m.splitMode,
          cacheHit: m.cacheHit,
          status: m.status,
          memoryLog: newLog,
          webSearchTrace: m.webSearchTrace,
          createdAt: m.createdAt,
        );
      }
    });
  }

  /// 窗口摘要壓縮
  Future<int> _triggerContextCompression({
    String? conversationId,
    String? characterId,
    int? triggerTokenLimit,
  }) async {
    final running = _compressionInFlight;
    if (running != null) return running;

    final future = _performContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerTokenLimit: triggerTokenLimit,
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
  }) async {
    final convId = conversationId ?? widget.conversationId;
    final charId = characterId ?? _activeCharacterId;
    final tokenLimit = triggerTokenLimit ?? ContextCompressor.triggerTokens;
    final cursor = await DatabaseHelper.getConversationSummaryCursor(convId);
    final messages = await DatabaseHelper.getMessagesAfterId(convId, cursor);
    if (messages.isEmpty) return 0;

    final recentMsgs = ContextCompressor.selectWholeBubbleBatch(
      messages,
      tokenLimit,
    );

    if (recentMsgs.isEmpty) return 0;

    final result = await ContextCompressor.compress(
      messages: recentMsgs,
      characterId: charId,
      conversationId: convId,
      contextMode: _requiredSessionIdentity.contextMode,
      continuityId: _requiredSessionIdentity.continuityId,
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

  /// 靜態摘要 pin：綁對話 ID、出生釘一塊（最新滾動摘要原文）、存庫永凍。
  /// 之後不管壓縮 rotate、重開對話、摘要增刪，都讀這份釘死的複本——
  /// 前綴恆定，緩存不炸。詳見 cache_fix_定案清單.md。
  Future<String> _buildStaticWindowSummaryPrompt(String characterId) async {
    _syncPromptLocaleCaches();
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final summaryEnabled = await MemorySettings.getCacheWindowSummaryEnabled();
    if (!cacheEnabled || !summaryEnabled) {
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

    final prompt = pinned.trim().isEmpty
        ? ''
        : _formatWindowSummaryPrompt(summary: pinned, keywordSummary: '');
    _cacheWindowSummaryStaticSnapshot = prompt;
    return prompt;
  }

  Future<String> _buildDynamicWindowSummaryPrompt(
    String characterId, {
    String currentMessage = '',
  }) async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final cacheSummaryEnabled =
        await MemorySettings.getCacheWindowSummaryEnabled();
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final contextSummaryEnabled =
        await MemorySettings.getContextWindowSummaryEnabled();

    final useCacheKeywordRecall = cacheEnabled && cacheSummaryEnabled;
    final useContextDynamic =
        !cacheEnabled && contextLimitEnabled && contextSummaryEnabled;
    if (!useCacheKeywordRecall && !useContextDynamic) return '';

    final windowId = await _currentWindowSummaryId();
    final pack = await ContextCompressor.loadSummaryPack(
      characterId,
      currentMessage: currentMessage,
      excludeWindowId: windowId,
      includeLatestSummaries: useContextDynamic,
      includeKeywordRecall: useCacheKeywordRecall || useContextDynamic,
      contextMode: _requiredSessionIdentity.contextMode,
      continuityId: _requiredSessionIdentity.continuityId,
    );
    final summary = (pack['summary'] ?? '').trim();
    final keywordSummaries = (pack['keywordSummaries'] ?? '').trim();
    return _formatWindowSummaryPrompt(
      summary: summary,
      keywordSummary: keywordSummaries,
    );
  }

  String _formatWindowSummaryPrompt({
    required String summary,
    required String keywordSummary,
  }) {
    final trimmedSummary = summary.trim();
    final trimmedKeyword = keywordSummary.trim();
    if (trimmedSummary.isEmpty && trimmedKeyword.isEmpty) return '';
    final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;

    if (L.locale == 'en') {
      final parts = <String>[];
      if (trimmedSummary.isNotEmpty) {
        parts.add(
          '${isRp ? 'Recent RP summaries' : 'Recent summaries'}:\n$trimmedSummary',
        );
      }
      if (trimmedKeyword.isNotEmpty) {
        parts.add(
          '${isRp ? 'Keyword-matched old RP summary' : 'Keyword-matched old summary'}:\n$trimmedKeyword',
        );
      }
      return '${isRp ? '【RP Window Summary】' : '【Window Summary】'}\n${parts.join('\n\n')}';
    }

    final parts = <String>[];
    if (trimmedSummary.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: isRp ? '最近 RP 窗口摘要：' : '最近窗口摘要：', zhCN: isRp ? '最近 RP 窗口摘要：' : '最近窗口摘要：')}\n$trimmedSummary',
      );
    }
    if (trimmedKeyword.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: isRp ? '命中關鍵詞召回的舊 RP 摘要：' : '命中關鍵詞召回的舊摘要：', zhCN: isRp ? '命中关键词召回的旧 RP 摘要：' : '命中关键词召回的旧摘要：')}\n$trimmedKeyword',
      );
    }
    return '${L.pick(en: '', zhTW: isRp ? '【RP 窗口摘要】' : '【窗口摘要】', zhCN: isRp ? '【RP 窗口摘要】' : '【窗口摘要】')}\n${parts.join('\n\n')}';
  }

  Future<int> _windowSummaryTriggerTokenLimit() async {
    // 摘要門檻是使用者設定，與 cache、上下文限制是否開啟無關。
    return MemorySettings.getWindowSummaryTriggerTokens();
  }

  Future<int> _windowSummaryCloseMinTokenThreshold() async {
    // 退出窗口不清零累積量，也不因 cache 狀態改變門檻；達到使用者
    // 設定值時才摘要，未達時保留計數供下次進入繼續累積。
    return _windowSummaryTriggerTokenLimit();
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

    await _maybeRunTokenTriggeredMaintenance(
      conversationId: conversationId,
      characterId: _activeCharacterId,
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
    final triggerTokenLimit = await _windowSummaryTriggerTokenLimit();
    if (_tokensSinceSummary < triggerTokenLimit) return;

    final enabled = await MemorySettings.getWindowSummaryEnabled();
    if (!enabled) {
      return;
    }

    final compressedTokens = await _triggerContextCompression(
      conversationId: conversationId,
      characterId: characterId,
      triggerTokenLimit: triggerTokenLimit,
    );
    if (compressedTokens > 0) {
      _tokensSinceSummary = await ContextCompressor.pendingTokenCount(
        conversationId ?? widget.conversationId,
      );
      await _saveTokensSinceSummary();
    }
  }

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
    var text = MemoryActions.stripReply(raw, windowId: widget.conversationId)
        .replaceAll(_ChatScreenState._completedToolCallsRe, '')
        .replaceAll(_ChatScreenState._completedTagRe, '')
        .replaceAll(_ChatScreenState._scratchTagRe, '')
        .replaceAll(_ChatScreenState._shopViewTagRe, '')
        .replaceAll(_ChatScreenState._transferTagRe, '')
        .replaceAll(_ChatScreenState._transferResponseRe, '')
        .replaceAll(_ChatScreenState._signMarriageRe, '')
        .replaceAll(_ChatScreenState._proposeMarriageRe, '')
        .replaceAll(_ChatScreenState._buyTagRe, '');
    final toolCall = _ChatScreenState._openToolCallsRe.firstMatch(text);
    if (toolCall != null) text = text.substring(0, toolCall.start);
    final openTag = _ChatScreenState._openTagRe.firstMatch(text);
    if (openTag != null) text = text.substring(0, openTag.start);
    final partialTag = RegExp(r'<[a-zA-Z_]*$').firstMatch(text);
    if (partialTag != null) text = text.substring(0, partialTag.start);
    return text.trim();
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

      await DatabaseHelper.deleteMessageById(incompleteId);
      if (!mounted) return;
      _refreshChatState(() => _messages.removeAt(index));
      if (userMessage.imagePath != null) {
        await _sendImageLocked(
          userMessage.imagePath!,
          caption: userMessage.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: userMessage,
        );
      } else {
        await _sendMessageLocked(
          userMessage.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: userMessage,
        );
      }
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
      if (source.imagePath != null) {
        await _sendImageLocked(
          source.imagePath!,
          caption: source.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: source,
        );
      } else {
        await _sendMessageLocked(
          source.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: source,
        );
      }
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

  String _webSearchProviderLabel(ResolvedWebSearchProvider provider) {
    return switch (provider.id) {
      WebSearchProviderId.gemini => L.pick(
        en: 'Gemini · ${provider.model}',
        zhTW: 'Gemini · ${provider.model}',
        zhCN: 'Gemini · ${provider.model}',
      ),
      WebSearchProviderId.openRouter => L.pick(
        en: 'OpenRouter · ${provider.model} · Exa',
        zhTW: 'OpenRouter · ${provider.model} · Exa',
        zhCN: 'OpenRouter · ${provider.model} · Exa',
      ),
      WebSearchProviderId.xai => L.pick(
        en: 'Grok · ${provider.model} · Web Search',
        zhTW: 'Grok · ${provider.model} · 網路搜尋',
        zhCN: 'Grok · ${provider.model} · 网络搜索',
      ),
      WebSearchProviderId.relay => L.pick(
        en: 'Search relay · ${provider.model}',
        zhTW: '搜尋中轉站 · ${provider.model}',
        zhCN: '搜索中转站 · ${provider.model}',
      ),
    };
  }

  void _dismissWebSearchConfirmation() {
    final dialogContext = _webSearchConfirmationContext;
    _webSearchConfirmationContext = null;
    if (dialogContext == null || !dialogContext.mounted) return;
    final navigator = Navigator.of(dialogContext);
    if (navigator.canPop()) navigator.pop(false);
  }

  Future<bool> _confirmWebSearchPlan({
    required String query,
    required ResolvedWebSearchPlan plan,
    required int generationSerial,
  }) async {
    if (!mounted ||
        !_isCurrentGeneration(generationSerial) ||
        _stopGenerationRequested) {
      return false;
    }
    // 使用者已在設定中啟用網路搜尋，自動同意執行，不阻擋串流
    return true;
  }

  WebSearchTurnPlan _webSearchTurnPlan(ResolvedWebSearchPlan resolved) {
    WebSearchProviderRoute routeFor(ResolvedWebSearchProvider provider) {
      final route = switch (provider.id) {
        WebSearchProviderId.gemini => WebSearchProviderRoute.geminiGoogleSearch(
          provider.model,
        ),
        WebSearchProviderId.openRouter => WebSearchProviderRoute.openRouterExa(
          provider.model,
        ),
        WebSearchProviderId.xai => WebSearchProviderRoute.xaiWebSearch(
          provider.model,
        ),
        WebSearchProviderId.relay => WebSearchProviderRoute.relayOpenAiChat(
          provider.model,
        ),
      };
      if (route.route != provider.route) {
        throw const WebSearchProviderException(
          code: WebSearchFailureCode.notConfigured,
          safeMessage: 'The web-search provider route changed unexpectedly.',
          costCertainty: WebSearchCostCertainty.known,
        );
      }
      return route;
    }

    final routes = resolved.providers.map(routeFor).toList(growable: false);
    return routes.length == 2
        ? WebSearchTurnPlan.dual(routes[0], routes[1])
        : WebSearchTurnPlan.single(routes.single);
  }

  void _setWebSearchFailure({
    required int generationSerial,
    required String query,
    required List<String> providers,
    required String safeMessage,
  }) {
    if (!mounted || !_isCurrentGeneration(generationSerial)) return;
    final activity = _WebSearchActivityState(
      status: WebSearchActivityStatus.failed,
      query: query,
      providers: providers,
      safeMessage: safeMessage,
    );
    _refreshChatState(() {
      _pendingWebSearchFailureContext =
          WebSearchFollowUp.standaloneFailureContext(
            query: query,
            providers: providers,
            safeMessage: safeMessage,
          );
      _webSearchActivity = activity;
    });
    _scrollToBottom();
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (!mounted || !identical(_webSearchActivity, activity)) return;
      _refreshChatState(() => _webSearchActivity = null);
    });
  }

  Future<void> _runWebSearchIntent({
    required String query,
    required int userMessageId,
    required int generationSerial,
  }) async {
    if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
      return;
    }

    // Credential/format detection happens locally before settings, consent,
    // ToolRunner permission, or any provider code sees the query.
    try {
      WebSearchRequest(
        query: query,
        locale: L.locale,
        sensitiveQueryConfirmed: true,
      );
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: error.code == WebSearchFailureCode.secretDetected
            ? L.pick(
                en: 'Blocked sensitive query',
                zhTW: '已攔截敏感查詢',
                zhCN: '已拦截敏感查询',
              )
            : query,
        providers: const <String>[],
        safeMessage: error.safeMessage,
      );
      return;
    }

    ResolvedWebSearchPlan resolvedPlan;
    int dailyProviderLaunchCap;
    int maxResults;
    try {
      final settings = await Future.wait<Object>(<Future<Object>>[
        WebSearchSettings.getEnabled(),
        WebSearchSettings.getMode(),
        WebSearchSettings.getDailyProviderLaunchCap(),
        WebSearchSettings.getMaxResults(),
      ]);
      if (settings[0] != true) {
        _setWebSearchFailure(
          generationSerial: generationSerial,
          query: query,
          providers: const <String>[],
          safeMessage: L.pick(
            en: 'Web search is turned off in API settings.',
            zhTW: '網路搜尋已在 API 設定中關閉。',
            zhCN: '网络搜索已在 API 设置中关闭。',
          ),
        );
        return;
      }
      resolvedPlan = await _webSearchService.resolvePlan(
        settings[1] as WebSearchMode,
      );
      dailyProviderLaunchCap = settings[2] as int;
      maxResults = settings[3] as int;
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: const <String>[],
        safeMessage: error.safeMessage,
      );
      return;
    }

    final providerLabels = resolvedPlan.providers
        .map(_webSearchProviderLabel)
        .toList(growable: false);
    if (resolvedPlan.providers.any(
      (provider) => provider.id == WebSearchProviderId.gemini,
    )) {
      try {
        // Google disallows personal/sensitive data in unpaid API traffic. The
        // App cannot reliably determine the billing state of a BYOK project,
        // so detected PII is blocked for every Gemini grounding request.
        WebSearchRequest(
          query: query,
          locale: L.locale,
          sensitiveQueryConfirmed: false,
        );
      } on WebSearchProviderException catch (error) {
        if (error.code !=
            WebSearchFailureCode.sensitiveQueryConfirmationRequired) {
          rethrow;
        }
        _setWebSearchFailure(
          generationSerial: generationSerial,
          query: L.pick(
            en: 'Blocked personal-data query',
            zhTW: '已攔截個人資料查詢',
            zhCN: '已拦截个人数据查询',
          ),
          providers: providerLabels,
          safeMessage: L.pick(
            en: 'Gemini web search is not allowed to send a query that appears to contain personal data. Edit the request and try again.',
            zhTW: 'Gemini 網路搜尋不會送出疑似包含個人資料的查詢。請修改搜尋請求後再試。',
            zhCN: 'Gemini 网络搜索不会发送疑似包含个人数据的查询。请修改搜索请求后重试。',
          ),
        );
        return;
      }
    }
    final confirmed = await _confirmWebSearchPlan(
      query: query,
      plan: resolvedPlan,
      generationSerial: generationSerial,
    );
    if (!confirmed ||
        !_isCurrentGeneration(generationSerial) ||
        _stopGenerationRequested) {
      return;
    }

    WebSearchTurnGrant? grant;
    var toolStarted = false;
    try {
      final binding = WebSearchTurnBinding(
        conversationId: widget.conversationId,
        characterId: _activeCharacterId,
        turnId: 'message:${userMessageId}_$generationSerial',
        generationSerial: generationSerial,
        query: query,
        locale: L.locale,
        maxResults: maxResults,
        plan: _webSearchTurnPlan(resolvedPlan),
      );
      grant = await _webSearchTurnCoordinator.issueGrant(
        binding: binding,
        dailyProviderLaunchCap: dailyProviderLaunchCap,
      );
      if (!mounted ||
          !_isCurrentGeneration(generationSerial) ||
          _stopGenerationRequested) {
        await _webSearchTurnCoordinator.revokeGrant(grant.id);
        return;
      }
      _refreshChatState(() {
        _webSearchActivity = _WebSearchActivityState(
          status: WebSearchActivityStatus.searching,
          query: binding.query,
          providers: providerLabels,
        );
      });
      _scrollToBottom();

      final call = ToolCall.create(
        name: WebSearchToolBridge.toolName,
        arguments: <String, Object?>{'query': binding.query},
      );
      toolStarted = true;
      final result = await _toolRunner.run(
        call: call,
        context: ToolContext(
          mode: ToolRunMode.live,
          conversationId: widget.conversationId,
          characterId: _activeCharacterId,
          metadata: grant.toContextMetadata(),
        ),
      );
      if (!mounted ||
          !_isCurrentGeneration(generationSerial) ||
          _stopGenerationRequested ||
          result.status == ToolResultStatus.cancelled) {
        return;
      }
      final data = result.data;
      if (result.status == ToolResultStatus.success &&
          data is WebSearchBatchResult) {
        final failureContext = WebSearchFollowUp.failureContextFor(data) ?? '';
        final allFailed = data.allFailed;
        _refreshChatState(() {
          _pendingWebSearchResult = data;
          _pendingWebSearchFailureContext = failureContext;
          // Preserve one visual surface while the model starts composing from
          // the search evidence. It hands off directly to the first streamed
          // response instead of briefly falling back to the generic loader.
          _webSearchActivity = _WebSearchActivityState(
            status: allFailed
                ? WebSearchActivityStatus.failed
                : WebSearchActivityStatus.completed,
            query: binding.query,
            providers: providerLabels,
            safeMessage: allFailed && data.failures.isNotEmpty
                ? data.failures.first.safeMessage
                : '',
          );
        });
        return;
      }
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: binding.query,
        providers: providerLabels,
        safeMessage:
            result.failure?.message ??
            L.pick(
              en: 'Web search was not completed. The normal reply was kept.',
              zhTW: '網路搜尋未完成，已保留原本的回覆。',
              zhCN: '网络搜索未完成，已保留原本的回复。',
            ),
      );
    } on WebSearchTurnCoordinatorException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: error.safeMessage,
      );
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: error.safeMessage,
      );
    } catch (_) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: L.pick(
          en: 'Web search was not completed. The normal reply was kept.',
          zhTW: '網路搜尋未完成，已保留原本的回覆。',
          zhCN: '网络搜索未完成，已保留原本的回复。',
        ),
      );
    } finally {
      if (grant != null && !toolStarted) {
        await _webSearchTurnCoordinator.revokeGrant(grant.id);
      }
    }
  }

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

  void _applyRpContinuationSource(
    RpChapterContinuationSource source, {
    required bool notify,
  }) {
    void update() {
      _previousWindowTurnsFuture = Future<List<Message>>.value(source.messages);
      _rpContinuationSummaryPrompt = source.summaries.join('\n\n---\n\n');
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
      _applyRpContinuationSource(source, notify: false);
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
    final source = await showModalBottomSheet<RpChapterContinuationSource>(
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
                            en: 'Last four messages',
                            zhTW: '最近四條原文',
                            zhCN: '最近四条原文',
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
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, selected),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: YanciTheme.accent,
                      ),
                      child: Text(
                        L.pick(
                          en: 'Let them continue',
                          zhTW: '讓 TA 接續',
                          zhCN: '让 TA 接续',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    _applyRpContinuationSource(source, notify: true);
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
    final continuationInstruction = isRp
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
          );
    final request =
        '${Message.rpChapterContinuationPrefix}\n$sourceMarker\n'
        '$sourceAnchorMarker$continuationInstruction';
    await _onSendMessage(request);
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

  Widget _rpContinuationSummaryPreview(String summary, int index) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      '$index. $summary',
      style: YanciTheme.bodySmall.copyWith(height: 1.5),
    ),
  );

  Future<void> _sendMessageLocked(
    String text, {
    required String composerDraft,
    required bool clearComposerOnAccept,
    Message? retryUserMessage,
  }) async {
    if (!_isChatReady) return;
    final conversationId = widget.conversationId;
    // 新窗口第一句話 → 停止舊窗口保活 + 切換緩存會話
    if (_messages.where((m) => m.isUser).isEmpty) {
      await _stopKeepAliveBeforeFirstMessage();
      if (!mounted) return;
      CacheSession.bind(_requiredSessionIdentity);
    }
    // 情緒衰減 tick（冪等：未到刷新間隔的點不會被動）
    EmotionCoordinates.tickDecay(_activeCharacterId);
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
      final imgPath = imagePaths.first;
      _refreshChatState(() => _pendingImagePaths.clear());
      return _sendImageLocked(
        imgPath,
        imagePaths: imagePaths,
        caption: text,
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
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
      );
    }

    // 有掛起禮物 → 入對方背包 + 消息尾附 [gift:名稱]（氣泡隱藏、模型可見）
    final giftTag = retryUserMessage == null ? await _consumePendingGift() : '';
    if (giftTag.isNotEmpty) {
      return _sendMessageLocked(
        text.isNotEmpty ? '$text$giftTag' : giftTag.trim(),
        composerDraft: composerDraft,
        clearComposerOnAccept: clearComposerOnAccept,
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
      );
    }

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
    if (outboundText.isEmpty) return;
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
      );
      final userId = await DatabaseHelper.insertMessage(userMsg);
      unawaited(MarriageService.scanMessage(userMsg.text, _activeCharacterId));
      _sentMessageInThisSession = true;
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
        createdAt: userMsg.createdAt,
      );
    }
    final promptVisibleOutboundText = userMsgWithId.promptVisibleText;
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
      _scrollToBottom();
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    if (retryUserMessage == null &&
        workingMessages.where((m) => m.isUser).length == 1) {
      // 先用前 20 字佔位
      final titleText = _titleTextForFirstMessage(
        text,
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
    final systemPromptF = Future<String>.value(
      _userPersona?.promptContent ?? '',
    );
    final modelF = ApiSettings.getModel();
    final bucketF = _memoryBucket();
    final userProfileF = _buildUserProfilePrompt();
    final selfNotesEnabledF = sessionIdentity.contextMode == ContextMode.rp
        ? Future<bool>.value(false)
        : MemorySettings.getSelfNotesEnabled();
    final selfNotesF = selfNotesEnabledF.then<String>(
      (enabled) async =>
          enabled ? await DatabaseHelper.getSelfNotes(charId) : '',
    );
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
    final thinkingEnabledF = ApiSettings.getThinkingChain();
    final webSearchEnabledF = WebSearchSettings.getEnabled();
    final toolFeaturesF = ToolFeatureSettings.load();
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
    final memoryPromptF = emotionEnabledF.then((emotionEnabled) {
      if (sessionIdentity.contextMode == ContextMode.rp) {
        return RpMemoryService.buildPrompt(
          mode: bucket,
          currentMessage: promptVisibleOutboundText,
          characterId: charId,
          windowId: widget.conversationId,
          continuityId: sessionIdentity.continuityId,
          emotionEnabled: emotionEnabled,
        );
      }
      return Retriever.buildMemoryPrompt(
        mode: bucket,
        currentMessage: promptVisibleOutboundText,
        characterId: charId,
        windowId: widget.conversationId,
        emotionEnabled: emotionEnabled,
        contextMode: sessionIdentity.contextMode,
        continuityId: sessionIdentity.continuityId,
      );
    });

    // 動態部分：也提前發射
    final emoStateF = emotionEnabledF.then(
      (enabled) async =>
          enabled ? await EmotionCoordinates.statePrompt(charId) : '',
    );
    final recallPromptF = timelineEnabledF.then<String>((enabled) async {
      if (!enabled) return '';
      return sessionIdentity.contextMode == ContextMode.rp
          ? RpCharacterTimelineService.recallPrompt(
              charId,
              promptVisibleOutboundText,
              continuityId: sessionIdentity.continuityId,
            )
          : CharacterTimelineService.recallPrompt(
              charId,
              promptVisibleOutboundText,
            );
    });
    final rpStoryContextF = sessionIdentity.contextMode == ContextMode.rp
        ? Future.wait<String>(<Future<String>>[
            RpStoryService.recallPrompt(
              charId,
              promptVisibleOutboundText,
              continuityId: sessionIdentity.continuityId,
            ),
            RpStoryStateService.recallPrompt(
              charId,
              continuityId: sessionIdentity.continuityId,
            ),
            RpWorldbookService.recallPrompt(
              characterId: charId,
              continuityId: sessionIdentity.continuityId,
              query: promptVisibleOutboundText,
            ),
          ]).then(
            (parts) => parts.where((part) => part.isNotEmpty).join('\n\n'),
          )
        : Future<String>.value('');
    final fatiguePromptF = bioclockEnabledF.then(
      (enabled) async =>
          enabled ? await BioClockService.fatiguePrompt(charId) : '',
    );

    // 收集結果
    final systemPrompt = await systemPromptF;
    final model = await modelF;
    _currentModel = model;
    final memoryPrompt = await memoryPromptF;
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
    final toolFeatures = await toolFeaturesF;

    final staticBundle = await _buildCommonStaticParts(
      characterId: charId,
      systemPrompt: systemPrompt,
      charDesc: charDesc,
      characterName: charName,
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
      staticWindowSummary: await staticWindowSummaryF,
      contextMode: sessionIdentity.contextMode,
      toolFeatures: toolFeatures,
    );

    final dynamicParts = <String>[];
    final controlParts = <String>[];
    final turnEffects = DeferredPromptBatch()..add(memoryPrompt);
    final now = DateTime.now();
    final diaryPrompt = await CharacterDiaryService.buildNightPrompt(
      characterId: charId,
      conversationId: widget.conversationId,
      sourceMessageId: userMsgWithId.id!,
      userName: userNicknameStr,
      currentUserContent: promptVisibleOutboundText,
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
    if (memoryPrompt.isNotEmpty) {
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
    if (_rpContinuationSummaryPrompt.isNotEmpty) {
      final isRpContinuation = sessionIdentity.contextMode == ContextMode.rp;
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: isRpContinuation
              ? 'Selected Chapter Summaries'
              : 'Selected Window Summaries',
          zhTWTitle: isRpContinuation ? '所選篇章摘要' : '所選窗口摘要',
          zhCNTitle: isRpContinuation ? '所选篇章摘要' : '所选窗口摘要',
          content: _rpContinuationSummaryPrompt,
        ),
      );
    }
    final rpStoryContext = await rpStoryContextF;
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
    if (toolFeatures.toolPromptsEnabled) {
      final proposeHint = await MarriageService.proposeHintPrompt(charId);
      if (proposeHint.isNotEmpty) dynamicParts.add(proposeHint);
    }

    // X 發文動態狀態（剩餘條數每日變，不能進靜態）
    if (toolFeatures.toolPromptsEnabled) {
      final xHint = await XPostSettings.promptHint(charId);
      if (xHint.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$xHint',
        );
      }
    }

    // 每輪動態注入，避免改動角色靜態 prompt 與既有 provider cache。
    if (toolFeatures.toolPromptsEnabled) {
      dynamicParts.add(EmailDraftTool.runtimeInstruction());
    }
    final whisperState = CharacterWhisperState.fromCharacter(charData);
    if (toolFeatures.toolPromptsEnabled && whisperState.modelOverrideEnabled) {
      dynamicParts.add(WhisperService.runtimeInstruction(whisperState));
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

    // 角色生活化（每個對話框第一條注入狀態快照）
    if (_isFirstRoundInWindow) {
      // 背包：有新增→全量+請重標星；無新增→只注星標（隨歷史進緩存前綴）
      if (toolFeatures.toolPromptsEnabled && toolFeatures.shopEnabled) {
        final packPrompt = await ShopService.buildPackPrompt(charId);
        if (packPrompt.isNotEmpty) dynamicParts.add(packPrompt);
      }
      if (timelineEnabled && sessionIdentity.contextMode == ContextMode.daily) {
        final snapshot = await CharacterTimelineService.stateSnapshotPrompt(
          charId,
        );
        if (snapshot.isNotEmpty) dynamicParts.add(snapshot);
      }
    }

    // 回憶觸發（已提前發射）
    final recallPrompt = await recallPromptF;
    if (recallPrompt.isNotEmpty) {
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
    dynamicParts.add(
      SystemContextMarkdown.section(
        enTitle: 'Current Time',
        zhTWTitle: '當前時間',
        zhCNTitle: '当前时间',
        content: _timePrompt(now),
      ),
    );

    // Thinking 是本輪展示策略，不得進入可快取 control prefix。Thinking
    // Machines 使用原生 request 參數，其餘 provider 走 request-only sidecar。
    if (providerName != 'thinking_machines') {
      dynamicParts.add(
        ThinkingModePolicy.runtimeInstruction(enabled: thinkingEnabled),
      );
    }

    // 拆分回覆模式
    if (_splitReply) {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Reply Format',
          zhTWTitle: '回覆格式',
          zhCNTitle: '回复格式',
          content: L.pick(
            en: '【Split Reply Mode】Reply using speech only — no action descriptions, no narration, no *asterisk actions*. Use line breaks between separate thoughts. Keep each paragraph concise.',
            zhTW: '【拆分回覆模式】只用說話內容回覆，不要使用動作描述、旁白敘事、*星號動作*。不同的話之間用換行分段。每段簡短自然。',
          ),
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
    if (isSpiderWebEnabled &&
        Retriever.triggeredCountFor(widget.conversationId) >= 3) {
      dynamicParts.add(
        '[系統底層神經元通知：偵測到多重關鍵字碰撞，請評估是否觸發 '
        '<memo_link> 標籤將相關記憶串聯。]',
      );
    }

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
    }

    // Keep the first pass visible. Search intent is parsed after the stream,
    // while protocol tags are already hidden by the shared display sanitizer.
    // Deferring this pass made every provider look like a static loader.
    const deferInitialStreamForSearchDecision = false;

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
    try {
      final enableVibration = await enableVibrationF;

      final nonEmpty = workingMessages.where((m) => m.text.isNotEmpty).toList();
      final previousWindowTurns = await previousWindowTurnsF;
      var history = <Map<String, String>>[
        ...previousWindowTurns.map((m) => m.toPromptHistoryEntry()),
        ...nonEmpty.map((m) => m.toPromptHistoryEntry()),
      ];

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
      final cacheMode = await Future.wait<bool>(<Future<bool>>[
        MemorySettings.getEnablePromptCaching(),
        MemorySettings.getContextLimitEnabled(),
      ]);
      if (cacheMode[0] &&
          !cacheMode[1] &&
          TokenEstimator.cacheThresholdInfoForModel(
                provider: providerName,
                model: model,
              ).kind !=
              CacheThresholdKind.unavailable) {
        await ApiSettings.recordSentThinkingState(
          conversationId: widget.conversationId,
          provider: providerName,
          model: model,
          cacheChannel: PromptCacheChannel.text,
          enabled: thinkingEnabled,
        );
      }
      await for (final chunk in adapter.sendMessageStream(
        messages: history,
        model: model,
        structuredPrompt: structured,
        onUsage: (usage) => requestUsage = usage,
      )) {
        if (!_isCurrentGeneration(generationSerial)) return;
        await turnEffects.commit();
        rawReply.write(chunk);
        if (mounted && !deferInitialStreamForSearchDecision) {
          _onStreamChunk(chunk);
        }
      }
      streamCompleted = true;
      await turnEffects.commit();
      final replyText = ThinkingModePolicy.sanitizeVisibleReply(
        ThinkingModePolicy.moveProtocolTagsOutsideThinking(rawReply.toString()),
        enabled: thinkingEnabled,
      );
      if (!_isCurrentGeneration(generationSerial)) return;
      final webSearchIntent = WebSearchIntentParser.parse(replyText);
      final replyTextWithoutWebSearch = webSearchIntent.visibleText;
      final visibleInitialText = webSearchIntent.query == null
          ? replyTextWithoutWebSearch
          : '';
      if (_streamPresentationMode == StreamPresentationMode.nativeBuffered &&
          visibleInitialText.isNotEmpty) {
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

      // ═══ 記錄真實 API 用量（不再用估算，避免雙重計算）═══
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        usage: requestUsage,
        characterId: _activeCharacterId,
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
              characterId: _activeCharacterId,
              memoryId: MemoryActions.lastInsertedMemoryIdFor(
                widget.conversationId,
              ),
            )
          : EmotionCoordinates.stripReply(processedText);
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
      // ═══ 便箋：<home> 標籤處理（存入 sticky_notes）═══
      final homeMatch = RegExp(
        r'<home>([\s\S]*?)</home>',
      ).firstMatch(processedText);
      if (homeMatch != null) {
        var homeText = homeMatch.group(1)!.trim();
        homeText = truncateGraphemes(homeText, 12);
        await DatabaseHelper.addNote(homeText, characterId: _activeCharacterId);
        processedText = processedText
            .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
            .trim();
      }
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
                final date = rawDate.length >= 10
                    ? rawDate.substring(0, 10)
                    : rawDate;
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
          await _tokenTracker.recordRealUsage(
            provider: providerName,
            model: model,
            usage: followUsage,
            characterId: _activeCharacterId,
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
                  characterId: _activeCharacterId,
                  memoryId: MemoryActions.lastInsertedMemoryIdFor(
                    widget.conversationId,
                  ),
                )
              : EmotionCoordinates.stripReply(followUp);
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
              .trim();
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
          if (mounted) _onStreamChunk('\n\n');
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
          await _tokenTracker.recordRealUsage(
            provider: providerName,
            model: model,
            usage: followUsage,
            characterId: _activeCharacterId,
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
                  characterId: _activeCharacterId,
                  memoryId: null,
                )
              : EmotionCoordinates.stripReply(followUp);
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
      );
      final insertedId = await DatabaseHelper.insertMessage(aiMsg);
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
        memoryLog: aiMsg.memoryLog,
        webSearchTrace: aiMsg.webSearchTrace,
        emailDraft: aiMsg.emailDraft,
      );

      // 記錄命中的 messageId
      if (cacheRead > 0 && mounted) {
        _cacheHitIndices.add(_messages.length);
      }

      if (mounted) {
        _refreshChatState(() {
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
        userText: promptVisibleOutboundText,
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
          _titleTextForFirstMessage(text, pendingTransfer, pendingScratchGift),
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

  /// 發送圖片（相冊 or 表情包）
  Future<void> _sendImageLocked(
    String path, {
    List<String>? imagePaths,
    String caption = '',
    required String composerDraft,
    required bool clearComposerOnAccept,
    Message? retryUserMessage,
  }) async {
    if (!_isChatReady) return;
    final conversationId = widget.conversationId;
    if (_messages.where((m) => m.isUser).isEmpty) {
      await _stopKeepAliveBeforeFirstMessage();
      if (!mounted) return;
      CacheSession.bind(_requiredSessionIdentity);
    }
    if (_isGenerating) return;
    if (_isGeneratingImage) return;
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

    // 首次發送才複製圖片；重試沿用已入庫的原消息與 app 內路徑。
    final sourcePaths = imagePaths ?? <String>[path];
    final savedPaths = retryUserMessage != null
        ? retryUserMessage.imagePaths
        : (await Future.wait(
            sourcePaths.map(ImageService.copyToAppDir),
          )).where((value) => value.isNotEmpty).toList(growable: false);
    if (savedPaths.isEmpty) return;
    final saved = savedPaths.first;
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

    var outboundCaption =
        retryUserMessage?.text ?? _appendTransferTag(caption, pendingTransfer);
    if (retryUserMessage == null) {
      outboundCaption = _appendScratchGiftTag(
        outboundCaption,
        pendingScratchGift,
      );
    }
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
      userMsgWithId = retryUserMessage;
    } else {
      final userMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: outboundCaption,
        isUser: true,
        imagePath: saved,
        imagePaths: savedPaths,
      );
      final imgUserId = await DatabaseHelper.insertMessage(userMsg);
      unawaited(MarriageService.scanMessage(userMsg.text, _activeCharacterId));
      _sentMessageInThisSession = true;
      if (clearComposerOnAccept) {
        _clearComposerIfUnchanged(composerDraft);
      }
      if (pendingTransfer != null) {
        final msgKey = 'msg_$imgUserId';
        await TransferService.saveData(msgKey, pendingTransfer);
        _transferDataMap[msgKey] = pendingTransfer;
      }
      if (pendingScratchGift != null) {
        final msgKey = 'msg_$imgUserId';
        await ScratchService.saveData(msgKey, pendingScratchGift);
        _scratchDataMap[msgKey] = pendingScratchGift;
      }
      userMsgWithId = Message(
        id: imgUserId,
        conversationId: userMsg.conversationId,
        characterId: userMsg.characterId,
        text: userMsg.text,
        isUser: true,
        imagePath: userMsg.imagePath,
        imagePaths: userMsg.imagePaths,
        createdAt: userMsg.createdAt,
      );
    }
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
      _scrollToBottom();
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    final adapter = await _prepareAdapterForGeneration(
      generationSerial: generationSerial,
      sourceMessageId: userMsgWithId.id!,
    );
    if (adapter == null) {
      MemoryActions.clearSearchQuery(widget.conversationId);
      if (mounted) _scrollToBottom();
      return;
    }
    _activeGenerationAdapter = adapter;

    // ── 構建 API 消息 ──
    final sessionIdentity = _requiredSessionIdentity;
    final previousWindowTurnsF = _previousWindowTurnsFuture ??=
        DatabaseHelper.getPreviousConversationTurns(
          currentConversationId: widget.conversationId,
          characterId: _activeCharacterId,
          contextMode: sessionIdentity.contextMode,
          continuityId: sessionIdentity.continuityId,
        );
    final systemPrompt = _userPersona?.promptContent ?? '';
    final model = await ApiSettings.getModel();
    _currentModel = model;
    final imgMemoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();
    final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');

    final imageMemoryMessage = outboundCaption.isNotEmpty
        ? outboundCaption
        : '（用戶發送了一張圖片）';
    final imgTimelineEnabled = await MemorySettings.getTimelineEnabled();
    final imgRecallPrompt = imgTimelineEnabled
        ? sessionIdentity.contextMode == ContextMode.rp
              ? await RpCharacterTimelineService.recallPrompt(
                  _activeCharacterId,
                  imageMemoryMessage,
                  continuityId: sessionIdentity.continuityId,
                )
              : await CharacterTimelineService.recallPrompt(
                  _activeCharacterId,
                  imageMemoryMessage,
                )
        : '';
    final imgRpStoryContext = sessionIdentity.contextMode == ContextMode.rp
        ? (await Future.wait<String>(<Future<String>>[
            RpStoryService.recallPrompt(
              _activeCharacterId,
              imageMemoryMessage,
              continuityId: sessionIdentity.continuityId,
            ),
            RpStoryStateService.recallPrompt(
              _activeCharacterId,
              continuityId: sessionIdentity.continuityId,
            ),
            RpWorldbookService.recallPrompt(
              characterId: _activeCharacterId,
              continuityId: sessionIdentity.continuityId,
              query: imageMemoryMessage,
            ),
          ])).where((part) => part.isNotEmpty).join('\n\n')
        : '';
    final memoryPrompt = sessionIdentity.contextMode == ContextMode.rp
        ? await RpMemoryService.buildPrompt(
            mode: await _memoryBucket(),
            currentMessage: imageMemoryMessage,
            characterId: _activeCharacterId,
            windowId: widget.conversationId,
            continuityId: sessionIdentity.continuityId,
            emotionEnabled: emotionEnabled,
          )
        : await Retriever.buildMemoryPrompt(
            mode: await _memoryBucket(),
            currentMessage: imageMemoryMessage,
            characterId: _activeCharacterId,
            windowId: widget.conversationId,
            emotionEnabled: emotionEnabled,
            contextMode: ContextMode.daily,
            continuityId: sessionIdentity.continuityId,
          );
    final imgUserProfile = await _buildUserProfilePrompt();
    final imgSelfNotesEnabled =
        sessionIdentity.contextMode == ContextMode.daily &&
        await MemorySettings.getSelfNotesEnabled();
    final imgSelfNotes = imgSelfNotesEnabled
        ? await DatabaseHelper.getSelfNotes(_activeCharacterId)
        : '';
    final userNickname = _userPersonaName;
    final charDataImg = await DatabaseHelper.getCharacter(_activeCharacterId);
    final imgCharDesc = charDataImg?['description'] as String? ?? '';
    final imgCharName = charDataImg?['name'] as String? ?? '';
    final isSpiderWebEnabledImg =
        sessionIdentity.contextMode == ContextMode.daily &&
        (charDataImg?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final imgBioclockEnabled =
        sessionIdentity.contextMode == ContextMode.daily &&
        await MemorySettings.isAbilityEnabled('bioclock');
    final imgImagegenEnabled = await MemorySettings.isAbilityEnabled(
      'imagegen',
    );
    final imgToolFeatures = await ToolFeatureSettings.load();
    final imgProviderName = await ApiSettings.getApiProviderName();
    _configureStreamPresentation(imgProviderName);
    // Keep the image path's stable prompt prefix identical to the text path.
    // The image request itself still does not execute web.search here; this
    // flag only keeps the cacheable capability contract from drifting.
    final imgWebSearchEnabled = await WebSearchSettings.getEnabled();
    final staticBundle = await _buildCommonStaticParts(
      characterId: _activeCharacterId,
      systemPrompt: systemPrompt,
      charDesc: imgCharDesc,
      characterName: imgCharName,
      userProfile: imgUserProfile,
      selfNotes: imgSelfNotes,
      userNickname: userNickname,
      isSpiderWebEnabled: isSpiderWebEnabledImg,
      memoryWriteEnabled: imgMemoryWriteEnabled,
      emotionEnabled: emotionEnabled,
      bioclockEnabled: imgBioclockEnabled,
      imagegenEnabled: imgImagegenEnabled,
      webSearchEnabled: imgWebSearchEnabled,
      whisperModelOverrideEnabled:
          (charDataImg?['whisper_model_override'] as int? ?? 1) == 1,
      providerName: imgProviderName,
      staticWindowSummary: await _buildStaticWindowSummaryPrompt(
        _activeCharacterId,
      ),
      contextMode: sessionIdentity.contextMode,
      toolFeatures: imgToolFeatures,
    );

    final now = DateTime.now();
    final dynamicParts = <String>[
      SystemContextMarkdown.section(
        enTitle: 'Current Time',
        zhTWTitle: '當前時間',
        zhCNTitle: '当前时间',
        content: _timePrompt(now),
      ),
    ];
    if (imgToolFeatures.toolPromptsEnabled) {
      dynamicParts.add(EmailDraftTool.runtimeInstruction());
    }
    final imgWhisperState = CharacterWhisperState.fromCharacter(charDataImg);
    if (imgToolFeatures.toolPromptsEnabled &&
        imgWhisperState.modelOverrideEnabled) {
      dynamicParts.add(WhisperService.runtimeInstruction(imgWhisperState));
    }
    final controlParts = <String>[];
    final turnEffects = DeferredPromptBatch()..add(memoryPrompt);
    final imgDiaryPrompt = await CharacterDiaryService.buildNightPrompt(
      characterId: _activeCharacterId,
      conversationId: widget.conversationId,
      sourceMessageId: userMsgWithId.id!,
      userName: userNickname,
      currentUserContent: imageMemoryMessage,
      contextMode: sessionIdentity.contextMode,
      enabled:
          imgToolFeatures.toolPromptsEnabled && imgToolFeatures.diaryEnabled,
      now: now,
    );
    if (imgDiaryPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Evening Diary',
          zhTWTitle: '晚間日記',
          zhCNTitle: '晚间日记',
          content: imgDiaryPrompt.text,
        ),
      );
      turnEffects.add(imgDiaryPrompt);
    }
    if (memoryPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Memory',
          zhTWTitle: '記憶',
          zhCNTitle: '记忆',
          content: memoryPrompt.text,
        ),
      );
    }
    final imgContextSummary = await _buildDynamicWindowSummaryPrompt(
      _activeCharacterId,
      currentMessage: outboundCaption.isNotEmpty
          ? outboundCaption
          : L.pick(en: 'The user sent an image.', zhTW: '用戶發送了一張圖片'),
    );
    if (imgContextSummary.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Conversation Summary',
          zhTWTitle: '對話摘要',
          zhCNTitle: '对话摘要',
          content: imgContextSummary,
        ),
      );
    }
    if (imgRpStoryContext.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Story Reference',
          zhTWTitle: '劇情參考',
          zhCNTitle: '剧情参考',
          content: imgRpStoryContext,
        ),
      );
    }
    if (_rpContinuationSummaryPrompt.isNotEmpty) {
      final isRpContinuation = sessionIdentity.contextMode == ContextMode.rp;
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: isRpContinuation
              ? 'Selected Chapter Summaries'
              : 'Selected Window Summaries',
          zhTWTitle: isRpContinuation ? '所選篇章摘要' : '所選窗口摘要',
          zhCNTitle: isRpContinuation ? '所选篇章摘要' : '所选窗口摘要',
          content: _rpContinuationSummaryPrompt,
        ),
      );
    }
    if (imgRecallPrompt.isNotEmpty) {
      dynamicParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Recall',
          zhTWTitle: '回憶觸發',
          zhCNTitle: '回忆触发',
          content: imgRecallPrompt,
        ),
      );
    }
    if (imgToolFeatures.toolPromptsEnabled &&
        imgToolFeatures.shellEconomyEnabled &&
        imgToolFeatures.coinSnapshotEnabled) {
      final imgCoinDelta = await _coinDeltaPrompt(_activeCharacterId);
      if (imgCoinDelta.isNotEmpty) dynamicParts.add(imgCoinDelta);
    }
    // 背包窗內變動（與 text path 同步）
    if (imgToolFeatures.toolPromptsEnabled &&
        imgToolFeatures.shopEnabled &&
        _packQtySnapshot != null) {
      final imgPackDelta = await ShopService.buildPackDelta(
        _activeCharacterId,
        _packQtySnapshot!,
      );
      if (imgPackDelta.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【Backpack Changes】', zhTW: '【背包變動】')}$imgPackDelta',
        );
      }
    }
    if (imgToolFeatures.toolPromptsEnabled && imgToolFeatures.scratchEnabled) {
      final imgScratchGiftPrompt = _scratchGiftDynamicPrompt(
        pendingScratchGift,
      );
      if (imgScratchGiftPrompt.isNotEmpty) {
        dynamicParts.add(imgScratchGiftPrompt);
      }
    }
    // 上輪購買失敗回饋（與 text path 同步）
    final imgBuyFailPrompt =
        imgToolFeatures.toolPromptsEnabled && imgToolFeatures.shopEnabled
        ? _pendingBuyFailurePrompt()
        : DeferredPrompt.empty();
    if (imgBuyFailPrompt.isNotEmpty) {
      dynamicParts.add(imgBuyFailPrompt.text);
      turnEffects.add(imgBuyFailPrompt);
    }
    // 同逛商店清單跟隨（與 text path 同步）
    final imgBrowsePrompt =
        imgToolFeatures.toolPromptsEnabled && imgToolFeatures.shopEnabled
        ? await _shopBrowsePrompt()
        : DeferredPrompt.empty();
    if (imgBrowsePrompt.isNotEmpty) {
      dynamicParts.add(imgBrowsePrompt.text);
      turnEffects.add(imgBrowsePrompt);
    }
    // 結婚證主動遞提示（與 text path 同步）
    if (imgToolFeatures.toolPromptsEnabled) {
      final imgProposeHint = await MarriageService.proposeHintPrompt(
        _activeCharacterId,
      );
      if (imgProposeHint.isNotEmpty) dynamicParts.add(imgProposeHint);
    }
    // X 發文動態狀態（與 text path 同步）
    if (imgToolFeatures.toolPromptsEnabled) {
      final imgXHint = await XPostSettings.promptHint(_activeCharacterId);
      if (imgXHint.isNotEmpty) {
        dynamicParts.add(
          '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$imgXHint',
        );
      }
    }
    // 情緒狀態回饋（餵狀態不餵機制，空狀態零開銷）
    if (imgToolFeatures.toolPromptsEnabled && emotionEnabled) {
      final emoState = await EmotionCoordinates.statePrompt(_activeCharacterId);
      if (emoState.isNotEmpty) dynamicParts.add(emoState);
    }

    // 生物鐘：與文字路徑使用相同優先級與送達後提交機制。
    if (imgToolFeatures.toolPromptsEnabled && imgBioclockEnabled) {
      final imgClockPrompt = await BioClockService.turnPrompt(
        _activeCharacterId,
      );
      if (imgClockPrompt.isNotEmpty) {
        dynamicParts.add(
          SystemContextMarkdown.section(
            enTitle: 'Bio Clock',
            zhTWTitle: '生物鐘',
            zhCNTitle: '生物钟',
            content: imgClockPrompt.text,
          ),
        );
        turnEffects.add(imgClockPrompt);
      }

      final fatigueP = await BioClockService.fatiguePrompt(_activeCharacterId);
      if (fatigueP.isNotEmpty) {
        dynamicParts.add(
          SystemContextMarkdown.section(
            enTitle: 'Bio Clock',
            zhTWTitle: '生物鐘',
            zhCNTitle: '生物钟',
            content: fatigueP,
          ),
        );
      }

      if (_habitSnapshotIds != null) {
        final habitDelta = await BioClockService.habitDeltaPrompt(
          _activeCharacterId,
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
    }

    final selfNotesDelta = _selfNotesDeltaPrompt(imgSelfNotes);
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

    // Thinking 是 request-only 動態策略，切換時不改可快取前綴。
    final thinkingOn = await ApiSettings.getThinkingChain();
    _generationThinkingEnabled = thinkingOn;
    if (imgProviderName != 'thinking_machines') {
      dynamicParts.add(
        ThinkingModePolicy.runtimeInstruction(enabled: thinkingOn),
      );
    }

    // 拆分回覆模式
    if (_splitReply) {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Reply Format',
          zhTWTitle: '回覆格式',
          zhCNTitle: '回复格式',
          content: L.pick(
            en: '【Split Reply Mode】Reply using speech only — no action descriptions, no narration, no *asterisk actions*. Use line breaks between separate thoughts. Keep each paragraph concise.',
            zhTW: '【拆分回覆模式】只用說話內容回覆，不要使用動作描述、旁白敘事、*星號動作*。不同的話之間用換行分段。每段簡短自然。',
          ),
        ),
      );
    }

    // Keep the same stable control prompt as text messages. If this is
    // omitted, concise/freeform settings change the cacheable prefix only
    // when the user sends an image.
    final imgConciseOn = await ApiSettings.getConciseMode();
    final imgFreeformOn = await ApiSettings.getFreeformMode();
    final imgReplyStyle = ToolPrompts.selectedReplyStyle(
      conciseOn: imgConciseOn,
      freeformOn: imgFreeformOn,
      emotionEnabled: emotionEnabled,
      maxLines: imgFreeformOn ? await ApiSettings.getFreeformMaxLines() : 0,
    );
    if (imgReplyStyle.isNotEmpty) {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Reply Style',
          zhTWTitle: '回覆風格',
          zhCNTitle: '回复风格',
          content: imgReplyStyle,
        ),
      );
    }

    final liveDynamicPart = SystemContextMarkdown.join(dynamicParts);
    final structured = StructuredPrompt(
      sessionIdentity: _requiredSessionIdentity,
      staticPart: staticBundle.staticPart,
      profilePart: staticBundle.profilePart,
      windowPart: staticBundle.windowPart,
      controlPart: SystemContextMarkdown.join(controlParts),
      liveStatePart: liveDynamicPart,
      cacheChannel: PromptCacheChannel.text,
    );

    if (mounted) {
      _refreshChatState(() {
        _setGenerating(true);
        _streamingText = '';
      });
    } else {
      _setGenerating(true);
      _streamingText = '';
    }

    final rawReply = StringBuffer();
    var streamCompleted = false;
    try {
      // 構建歷史消息（文字部分）
      // ═══ 歷史圖片降級：只有最新一則 user 圖片消息真實上傳 ═══
      // 舊版每輪把全部歷史圖片重新 base64 上傳，
      // token 成本隨圖片數量線性暴漲（一張圖 ≈ 上千 tokens × 每輪）。
      // 更早的圖片降級為文字佔位，內容靠記憶系統承接。
      final filtered = workingMessages
          .where((m) => m.text.isNotEmpty || m.imagePaths.isNotEmpty)
          .toList();
      final previousWindowTurns = await previousWindowTurnsF;
      int lastImageIdx = -1;
      for (int i = filtered.length - 1; i >= 0; i--) {
        if (filtered[i].isUser && filtered[i].imagePaths.isNotEmpty) {
          lastImageIdx = i;
          break;
        }
      }
      var history = <Map<String, dynamic>>[
        for (final message in previousWindowTurns)
          <String, dynamic>{
            'role': message.isUser ? 'user' : 'assistant',
            'content': message.text,
          },
      ];
      for (int i = 0; i < filtered.length; i++) {
        final m = filtered[i];
        final degraded = m.imagePaths.isNotEmpty && i != lastImageIdx;
        final imageCount = m.imagePaths.length;
        history.add(<String, dynamic>{
          'role': m.isUser ? 'user' : 'assistant',
          'content': degraded
              ? '（這裡曾發送$imageCount張圖片${m.text.isNotEmpty ? '：${m.text}' : ''}）'
              : (m.text.isNotEmpty ? m.text : '（$imageCount張圖片）'),
          if (m.imagePaths.isNotEmpty && i == lastImageIdx)
            'imagePaths': List<String>.from(m.imagePaths),
        });
      }

      // ═══ B4 滯後截斷（保護前綴緩存）═══
      final keepFrom2 = await _hysteresisKeepFrom(
        history.map((m) => (m['content'] ?? '').toString()).toList(),
      );
      if (keepFrom2 > 0 && keepFrom2 < history.length) {
        var start2 = keepFrom2;
        history = history.sublist(keepFrom2);
        while (history.length > 1 && history.first['role'] != 'user') {
          history.removeAt(0);
          start2++;
        }
        // 砍頭點同步窗口錨點（同 text path）
        final currentWindowStart = start2 - previousWindowTurns.length;
        final anchorMsgId2 =
            currentWindowStart >= 0 && currentWindowStart < filtered.length
            ? filtered[currentWindowStart].id
            : null;
        if (anchorMsgId2 != null) {
          unawaited(_persistContextAnchor(anchorMsgId2));
        }
      }

      // 轉換為 API 格式（含 base64 圖片）
      final apiMessages = <Map<String, String>>[];
      for (final m in history) {
        final role = m['role'] as String;
        final content = m['content'] as String;
        final imagePaths =
            (m['imagePaths'] as List<dynamic>?)?.whereType<String>().toList(
              growable: false,
            ) ??
            const <String>[];

        if (imagePaths.isNotEmpty && role == 'user') {
          final dataUrls = <String>[];
          for (final imagePath in imagePaths) {
            final dataUrl = await ImageService.toBase64DataUrl(imagePath);
            if (dataUrl != null) dataUrls.add(dataUrl);
          }
          if (dataUrls.isNotEmpty) {
            // 用特殊標記讓 adapter 識別多模態
            apiMessages.add({
              'role': role,
              'content': content,
              'image_data_url': dataUrls.first,
              'image_data_urls': jsonEncode(dataUrls),
            });
            continue;
          }
        }
        apiMessages.add({'role': role, 'content': content});
      }

      var requestUsage = const ApiUsage();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }
      _activeRequestThinkingEnabled = thinkingOn;
      _activeRequestThinkingGeneration = generationSerial;
      final imgCacheMode = await Future.wait<bool>(<Future<bool>>[
        MemorySettings.getEnablePromptCaching(),
        MemorySettings.getContextLimitEnabled(),
      ]);
      if (imgCacheMode[0] &&
          !imgCacheMode[1] &&
          TokenEstimator.cacheThresholdInfoForModel(
                provider: imgProviderName,
                model: model,
              ).kind !=
              CacheThresholdKind.unavailable) {
        await ApiSettings.recordSentThinkingState(
          conversationId: widget.conversationId,
          provider: imgProviderName,
          model: model,
          cacheChannel: PromptCacheChannel.text,
          enabled: thinkingOn,
        );
      }
      await for (final chunk in adapter.sendMessageStream(
        messages: apiMessages,
        model: model,
        structuredPrompt: structured,
        onUsage: (usage) => requestUsage = usage,
      )) {
        if (!_isCurrentGeneration(generationSerial)) return;
        await turnEffects.commit();
        rawReply.write(chunk);
        if (mounted) _onStreamChunk(chunk);
      }
      streamCompleted = true;
      await turnEffects.commit();
      final replyText = ThinkingModePolicy.sanitizeVisibleReply(
        ThinkingModePolicy.moveProtocolTagsOutsideThinking(rawReply.toString()),
        enabled: thinkingOn,
      );
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }

      // ═══ 記錄真實 API 用量 ═══
      await _tokenTracker.recordRealUsage(
        provider: imgProviderName,
        model: model,
        usage: requestUsage,
        characterId: _activeCharacterId,
        requestKind: ApiRequestKind.chat,
      );

      final imgCacheRead = requestUsage.cacheReadTokens;
      if (imgCacheRead > 0) {
        CacheSession.markCacheHit(widget.conversationId);
      }

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = (imgMemoryWriteEnabled || isSpiderWebEnabledImg)
          ? await _processScopedMemoryReply(
              replyText,
              emotionEnabled: emotionEnabled,
            )
          : MemoryActions.stripReply(
              replyText,
              windowId: widget.conversationId,
              captureSearchQuery: true,
            );
      // ═══ 蛛網專屬標籤：<memo_link> 與 <force_recall> 處理 ═══
      if (isSpiderWebEnabledImg) {
        processedText = await SpiderWebCore.processReply(
          processedText,
          characterId: _activeCharacterId,
          windowId: widget.conversationId,
        );
      }
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
              characterId: _activeCharacterId,
              memoryId: MemoryActions.lastInsertedMemoryIdFor(
                widget.conversationId,
              ),
            )
          : EmotionCoordinates.stripReply(processedText);
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      if (sessionIdentity.contextMode == ContextMode.daily &&
          await MemorySettings.isAbilityEnabled('bioclock')) {
        processedText = await BioClockService.processReply(
          processedText,
          characterId: _activeCharacterId,
        );
      }
      // ═══ 角色生活化：只處理明確 <life_fix>；時間線事件不掃關鍵詞。═══
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
      // ═══ 便箋：<home> 標籤處理（存入 sticky_notes）═══
      final homeMatch = RegExp(
        r'<home>([\s\S]*?)</home>',
      ).firstMatch(processedText);
      if (homeMatch != null) {
        var homeText = homeMatch.group(1)!.trim();
        homeText = truncateGraphemes(homeText, 12);
        await DatabaseHelper.addNote(homeText, characterId: _activeCharacterId);
        processedText = processedText
            .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
            .trim();
      }
      // ═══ 悄悄話（圖片路徑）═══
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
      // 圖片路徑無 two-pass：<shop_view/> 僅剝離（下條文字消息她可再逛）
      processedText = processedText
          .replaceAll(_ChatScreenState._shopViewTagRe, '')
          .trim();
      // ═══ 刮刮樂：<scratch> 標籤處理（圖片路徑）═══
      ScratchData? pendingScratch;
      final scratchMatch = RegExp(
        r'<scratch\s+who="(\w+)"\s*/>',
      ).firstMatch(processedText);
      if (scratchMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<scratch\s+[^>]*/>'), '')
            .trim();
        if (imgToolFeatures.scratchEnabled) {
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
      // ═══ 轉帳：<transfer> 標籤處理（圖片路徑）═══
      TransferData? pendingTransfer;
      final transferMatch = RegExp(
        r'<transfer\s+amount="(\d+)"\s*/>',
      ).firstMatch(processedText);
      if (transferMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer\s+[^>]*/>'), '')
            .trim();
        final amount = int.tryParse(transferMatch.group(1) ?? '') ?? 0;
        if (imgToolFeatures.transferEnabled && amount > 0) {
          pendingTransfer = TransferData(amount: amount, direction: 'toUser');
        }
      }
      // ═══ 轉帳回應（圖片路徑）═══
      final hasAcceptImg = RegExp(
        r'<transfer_accept\s*/>',
      ).hasMatch(processedText);
      final hasDeclineImg = RegExp(
        r'<transfer_decline\s*/>',
      ).hasMatch(processedText);
      if (hasAcceptImg || hasDeclineImg) {
        processedText = processedText
            .replaceAll(RegExp(r'<transfer_accept\s*/>'), '')
            .replaceAll(RegExp(r'<transfer_decline\s*/>'), '')
            .trim();
      }
      if (imgToolFeatures.transferEnabled && (hasAcceptImg || hasDeclineImg)) {
        final pendingKey = _findPendingToCharTransfer();
        if (pendingKey != null) {
          if (hasAcceptImg) {
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
      String? drawPrompt;
      final drawMatch = RegExp(
        r'<draw>([\s\S]*?)</draw>',
      ).firstMatch(processedText);
      if (drawMatch != null) {
        processedText = processedText
            .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
            .trim();
        if (imgToolFeatures.imageGenerationEnabled) {
          drawPrompt = drawMatch.group(1)!.trim();
        }
      }

      processedText = await _extractDiaryAndStore(
        processedText,
        sourceMessageId: userMsgWithId.id,
        diaryEnabled: imgToolFeatures.diaryEnabled,
      );
      final emailDraftExtraction = EmailDraftTool.extract(processedText);
      final pendingEmailDraft = emailDraftExtraction.draft;
      processedText = emailDraftExtraction.visibleText;
      processedText = _extractXPostAndStrip(processedText);

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
      if (!_isCurrentGeneration(generationSerial)) return;
      if (_streamPresentationMode == StreamPresentationMode.nativeBuffered) {
        await _finishStreamPresentation();
        if (!_isCurrentGeneration(generationSerial) ||
            _stopGenerationRequested) {
          _finishFailedGeneration();
          return;
        }
      }
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: imgCacheRead > 0,
        memoryLog: memLog,
        emailDraft: pendingEmailDraft,
      );
      final imgAiId = await DatabaseHelper.insertMessage(aiMsg);
      await _clearChatDiagnosticForSource(userMsgWithId.id!);
      await _bindMemoryProposalsToMessage(imgAiId);
      unawaited(
        MarriageService.scanMessage(
          aiMsg.text,
          _activeCharacterId,
        ).then((_) => _refreshMarriageState()),
      );
      final aiMsgWithId = Message(
        id: imgAiId,
        conversationId: aiMsg.conversationId,
        characterId: aiMsg.characterId,
        text: aiMsg.text,
        isUser: false,
        splitMode: aiMsg.splitMode,
        cacheHit: aiMsg.cacheHit,
        status: aiMsg.status,
        createdAt: aiMsg.createdAt,
        imagePath: aiMsg.imagePath,
        memoryLog: aiMsg.memoryLog,
        emailDraft: aiMsg.emailDraft,
      );

      if (imgCacheRead > 0 && mounted) {
        _cacheHitIndices.add(_messages.length);
      }

      if (mounted) {
        _refreshChatState(() {
          _messages.add(aiMsgWithId);
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
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

      // ═══ 刮刮樂：存數據 + 彈出刮卡（圖片路徑）═══
      if (pendingScratch != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await ScratchService.saveData(msgId, pendingScratch);
        _scratchDataMap[msgId] = pendingScratch;
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            showScratchDialog(
              context,
              messageId: msgId,
              data: pendingScratch!,
              characterId: _activeCharacterId,
            ).then((_) async {
              final updated = await ScratchService.getData(msgId);
              if (updated != null) _scratchDataMap[msgId] = updated;
              if (mounted) _refreshChatState(() {});
            });
          });
        }
      }

      // ═══ 轉帳：存數據（圖片路徑）═══
      if (pendingTransfer != null && aiMsgWithId.id != null) {
        final msgId = 'msg_${aiMsgWithId.id}';
        await TransferService.saveData(msgId, pendingTransfer);
        _transferDataMap[msgId] = pendingTransfer;
        if (mounted) _refreshChatState(() {});
      }

      await _recordCompletedRound(
        conversationId: conversationId,
        userText: outboundCaption.isNotEmpty ? outboundCaption : '（圖片）',
        assistantText: aiMsgWithId.text,
        heartbeatHistory: apiMessages,
        structuredPrompt: structured,
        adapter: adapter,
        model: model,
        provider: imgProviderName,
      );
    } on ApiConfigException catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      _finishFailedGeneration();
      await _persistApiFailure(
        e,
        sourceMessageId: userMsgWithId.id!,
        provider: imgProviderName,
        model: model,
      );
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final incomplete = streamCompleted
          ? null
          : await _persistIncompleteReply(rawReply.toString());
      _finishFailedGeneration();
      if (_stopGenerationRequested) return;
      await _persistApiFailure(
        e,
        sourceMessageId: userMsgWithId.id!,
        anchorMessageId: incomplete?.id,
        provider: imgProviderName,
        model: model,
      );
    } finally {
      if (_activeRequestThinkingGeneration == generationSerial) {
        _activeRequestThinkingEnabled = null;
        _activeRequestThinkingGeneration = null;
      }
      if (identical(_activeGenerationAdapter, adapter)) {
        _activeGenerationAdapter = null;
      }
      MemoryActions.clearSearchQuery(widget.conversationId);
    }
    if (mounted) _scrollToBottom();
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
      final adapter = await ApiSettings.buildAdapter();
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
      final dialogueUser = truncateGraphemes(userText.trim(), 160);
      final dialogueCharacter = truncateGraphemes(aiText.trim(), 160);

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
        requestKind: ApiRequestKind.conversationTitle,
      );

      var title = response.trim().split('\n').first.trim();
      title = title.replaceFirst(
        RegExp(r'^(?:標題|标题|title)\s*[:：]\s*', caseSensitive: false),
        '',
      );
      title = title.replaceAll(RegExp(r'''^[「」『』“”"']+|[「」『』“”"']+$'''), '');
      title = truncateGraphemes(title.trim(), 20);
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
