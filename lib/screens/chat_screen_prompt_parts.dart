// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatPromptPartMethods on _ChatScreenState {
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
    required String continuityId,
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

    final stickersAllowed =
        contextMode != ContextMode.rp || toolFeatures.rpDailyLifeToolsEnabled;
    if (toolPromptsEnabled && stickersAllowed) {
      _stickerPromptSnapshot ??= await StickerService.buildStickerPrompt(
        characterId: characterId,
        userPersonaId: _userPersona?.id,
        maxEntries: contextMode == ContextMode.rp ? 24 : null,
        maxCharacters: contextMode == ContextMode.rp ? 1600 : null,
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
    if (contextMode == ContextMode.rp) {
      // This must remain the first text in the first stable system block.
      // Character cards, user personas, summaries, memories and live state all
      // follow it, so none of them can blur the RP speaker boundary.
      staticParts.add(
        RpIdentityLockPrompt.build(
          characterName: characterName,
          userName: userNickname,
        ),
      );
    }
    // Older builds copied the selected character description into the global
    // system prompt. Keep custom global instructions, but do not inject that
    // legacy mirror twice into every request.
    if (normalizedSystemPrompt.isNotEmpty &&
        normalizedSystemPrompt != normalizedCharacterDescription) {
      staticParts.add(normalizedSystemPrompt);
    }
    // 角色描述為空時，上面的分支已加入 systemPrompt；不可再加一次。
    if (normalizedCharacterDescription.isNotEmpty) {
      staticParts.add(
        '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$normalizedCharacterDescription',
      );
    }
    if (selfNotes.isNotEmpty && _selfNotesSnapshot?.isNotEmpty == true) {
      windowParts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$_selfNotesSnapshot',
      );
    }
    // 已婚狀態（僅已簽角色注入；未簽空串＝前綴逐字節不變。
    // 簽署瞬間變一次＝一次性重建，之後永久命中）
    final dailyLifeTools = toolFeatures.dailyLifeToolsAllowed(contextMode);
    final marriageNote = dailyLifeTools
        ? await MarriageService.staticPrompt(characterId)
        : '';
    if (marriageNote.isNotEmpty) windowParts.add(marriageNote);
    if (toolPromptsEnabled &&
        toolFeatures.shellEconomyEnabled &&
        toolFeatures.coinSnapshotEnabled) {
      windowParts.add(await _coinStaticPrompt(characterId));
    }
    if (staticWindowSummary.isNotEmpty) {
      windowParts.add(staticWindowSummary);
    }
    if (contextMode == ContextMode.rp) {
      final alwaysOnWorldbook = await RpWorldbookService.recallAlwaysOnPrompt(
        characterId: characterId,
        continuityId: continuityId,
      );
      if (alwaysOnWorldbook.isNotEmpty) {
        windowParts.add(alwaysOnWorldbook);
      }
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
    if (toolFeatures.modelGreetingEnabled) {
      toolSections.add(ToolPrompts.homeNote());
    }
    if (toolPromptsEnabled && whisperModelOverrideEnabled) {
      toolSections.add(
        ToolPrompts.whisper(
          characterName: characterName,
          userNickname: userNickname,
        ),
      );
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
    if (toolPromptsEnabled &&
        dailyLifeTools &&
        await XPostSettings.isEnabled(characterId)) {
      toolSections.add(ToolPrompts.xPost());
    }
    if (toolPromptsEnabled &&
        stickersAllowed &&
        _stickerPromptSnapshot?.isNotEmpty == true) {
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

  Future<List<String>> _firstRoundSnapshotParts({
    required String characterId,
    required ToolFeatureState toolFeatures,
    required bool timelineEnabled,
    required ContextMode contextMode,
  }) async {
    if (!_isFirstRoundInWindow) return const <String>[];
    final parts = <String>[];
    // 背包：有新增→全量+請重標星；無新增→只注星標（隨歷史進緩存前綴）
    if (toolFeatures.toolPromptsEnabled && toolFeatures.shopEnabled) {
      final packPrompt = await ShopService.buildPackPrompt(characterId);
      if (packPrompt.isNotEmpty) parts.add(packPrompt);
    }
    if (timelineEnabled && contextMode == ContextMode.daily) {
      final snapshot = await CharacterTimelineService.stateSnapshotPrompt(
        characterId,
      );
      if (snapshot.isNotEmpty) parts.add(snapshot);
    }
    return parts;
  }

  String _memoLinkNotice(bool spiderWebEnabled) {
    if (!spiderWebEnabled ||
        Retriever.triggeredCountFor(widget.conversationId) < 3) {
      return '';
    }
    return SystemContextMarkdown.section(
      enTitle: 'Memory Links',
      zhTWTitle: '記憶串聯',
      zhCNTitle: '记忆串联',
      content: L.pick(
        en: 'Several memories were triggered this turn. If some of them are clearly related, you may connect them with <memo_link>.',
        zhTW: '本輪觸發的記憶較多。若其中有明確關聯，可以用 <memo_link> 把它們串起來。',
        zhCN: '本轮触发的记忆较多。若其中有明确关联，可以用 <memo_link> 把它们串起来。',
      ),
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

  Future<int> _hysteresisKeepFrom(List<String> contents) async {
    // Cache 模式依賴 append-only 歷史來維持前綴；即使備份還原或
    // 舊版本留下了「Cache／上下文限制同時開啟」的非法組合，
    // 請求端也必須優先保住完整歷史，不能裁掉前文又因 Cache
    // 模式關閉截斷摘要。
    final costStrategy = await ModelCostPolicy.resolveCurrentStrategy();
    if (costStrategy.promptCacheEnabled) {
      _contextKeepFrom = 0;
      return 0;
    }
    final limit = await MemorySettings.getContextMessageLimit();
    if (!costStrategy.contextLimitEnabled ||
        limit <= 0 ||
        contents.length <= 1) {
      return 0;
    }
    final keep = max(0, contents.length - limit);
    _contextKeepFrom = keep;
    return keep;
  }
}
