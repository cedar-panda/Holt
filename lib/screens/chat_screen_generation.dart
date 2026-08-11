part of 'chat_screen.dart';

extension _ChatGenerationMethods on _ChatScreenState {
  /// 生成態統一入口：熄屏/退後台會凍結流式回覆，
  /// 生成期間掛前台服務保護（GenerationForegroundGuard），結束即撤
  void _setGenerating(bool v) {
    if (_isGenerating == v) return;
    _isGenerating = v;
    if (v) {
      unawaited(GenerationForegroundGuard.begin());
    } else {
      unawaited(GenerationForegroundGuard.end());
    }
  }

  void _onStreamChunk(String chunk) {
    if (!mounted) return;
    for (int i = 0; i < chunk.length; i++) {
      _streamCharQueue.add(chunk[i]);
    }
    _startStreamPopTimer();
  }

  void _startStreamPopTimer() {
    if (_streamPopTimer?.isActive == true) return;
    _streamPopTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted || _streamCharQueue.isEmpty) {
        timer.cancel();
        return;
      }
      int popCount = 1;
      if (_streamCharQueue.length > 20) popCount = 2;
      if (_streamCharQueue.length > 50) popCount = 4;
      if (_streamCharQueue.length > 100) popCount = 8;

      final buf = StringBuffer();
      for (int i = 0; i < popCount && _streamCharQueue.isNotEmpty; i++) {
        buf.write(_streamCharQueue.removeAt(0));
      }
      _streamingText += buf.toString();
      _refreshChatState(() {});
      _scrollToBottom();
    });
  }

  void _clearStreamQueue() {
    _streamCharQueue.clear();
    _streamPopTimer?.cancel();
    _streamingText = '';
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
    return text.trim();
  }

  int _beginGeneration() {
    _stopGenerationRequested = false;
    _webSearchActivity = null;
    _pendingWebSearchResult = null;
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
    required Future<void> Function() retry,
  }) async {
    try {
      return await ApiSettings.buildAdapter();
    } on ApiConfigException catch (error) {
      if (!_isCurrentGeneration(generationSerial)) return null;
      _finishFailedGeneration();
      _showApiConfigFailure(error);
      return null;
    } catch (error) {
      if (!_isCurrentGeneration(generationSerial)) return null;
      _finishFailedGeneration();
      _showRetryableFailure(error, () => _runMessageRetry(retry));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: '$_characterName wanted to post, but the X account is not connected.',
              zhTW: '【$_characterName】起念發了條推文，但 X 帳號尚未連接',
            ),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? L.pick(en: 'Posted to X 🦦', zhTW: '已發布到 X 🦦')),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
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

  Future<String> _coinStaticPrompt(String characterId) async {
    _coinSnapshotChar ??= await ScratchService.getCoins(characterId);
    _coinSnapshotUser ??= await ScratchService.getUserCoins();

    if (L.locale == 'en') {
      return '【Shell Balance Snapshot】At the start of this chat window: your balance is $_coinSnapshotChar shells; the user balance is $_coinSnapshotUser shells. This static snapshot is kept stable for prompt caching. Later transfer/scratch changes are provided as deltas in dynamic context; always follow the latest delta when present.';
    }

    return L.pick(
      en: '',
      zhTW:
          '【貝殼餘額快照】本聊天窗口開篇時：你的餘額 $_coinSnapshotChar 貝殼；用戶餘額 $_coinSnapshotUser 貝殼。此靜態快照為了穩定 prompt cache 不再改動；後續轉帳/刮刮卡變動會在動態上下文以增減量補充，有變動時以最新增減量為準。',
    );
  }

  Future<String> _coinDeltaPrompt(String characterId) async {
    _coinSnapshotChar ??= await ScratchService.getCoins(characterId);
    _coinSnapshotUser ??= await ScratchService.getUserCoins();

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '【$_characterName】想買「${r['name']}」沒成功：${r['reason']}',
            ),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
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
  }) async {
    if (bioclockEnabled &&
        (_habitSnapshotIds == null || _habitListSnapshot == null)) {
      _habitSnapshotIds = await BioClockService.habitIds(characterId);
      _habitListSnapshot = await BioClockService.habitListPrompt(characterId);
    }
    final habitList = bioclockEnabled ? (_habitListSnapshot ?? '') : '';

    if (_selfNotesSnapshot == null || _selfNotesSnapshotLines == null) {
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

    _stickerPromptSnapshot ??= await StickerService.buildStickerPrompt(
      characterId: characterId,
    );
    // 背包窗內快照（delta 基準），與其他快照同點初始化
    _packQtySnapshot ??= await ShopService.packQtySnapshot(characterId);

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
    if (_selfNotesSnapshot!.isNotEmpty) {
      windowParts.add(
        '${L.pick(en: '【Self-notes (previously written by you)】', zhTW: '【自我註記（你過去為自己記下的）】')}\n$_selfNotesSnapshot',
      );
    }
    // 已婚狀態（僅已簽角色注入；未簽空串＝前綴逐字節不變。
    // 簽署瞬間變一次＝一次性重建，之後永久命中）
    final marriageNote = await MarriageService.staticPrompt(characterId);
    if (marriageNote.isNotEmpty) windowParts.add(marriageNote);
    windowParts.add(await _coinStaticPrompt(characterId));
    if (staticWindowSummary.isNotEmpty) {
      windowParts.add(staticWindowSummary);
    }

    final toolSections = <String>[];
    if (isSpiderWebEnabled) {
      toolSections.add(
        await SpiderWebService.abilityPrompt(
          userNickname: userNickname,
          characterId: characterId,
          characterName: characterName,
        ),
      );
    } else {
      if (memoryWriteEnabled) {
        toolSections.add(
          MemoryActions.abilityPrompt(
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
    if (providerName == 'openrouter' && imagegenEnabled) {
      toolSections.add(ImageGenService.abilityPrompt());
    }
    if (webSearchEnabled) {
      toolSections.add(ToolPrompts.webSearch());
    }
    // 商店（全語言/全模式；固定文本零緩存污染；清單走 two-pass 按需查詢）
    if (await ShopService.isEnabled()) {
      toolSections.add(ToolPrompts.shop());
    }
    toolSections.add(ToolPrompts.homeNote());
    if (whisperModelOverrideEnabled) {
      toolSections.add(ToolPrompts.whisper());
    }
    toolSections.add(ToolPrompts.scratchCard());
    toolSections.add(ToolPrompts.transfer());
    toolSections.add(ToolPrompts.voiceCall());
    // X 發文（開關開啟才注入說明；剩餘條數等動態信息走 dynamicParts）
    if (await XPostSettings.isEnabled(characterId)) {
      toolSections.add(ToolPrompts.xPost());
    }
    if (_stickerPromptSnapshot!.isNotEmpty) {
      windowParts.add(_stickerPromptSnapshot!);
    }

    staticParts.add(
      '${ToolPrompts.toolHeader()}\n\n${toolSections.join('\n\n')}',
    );

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
    final convId = widget.conversationId;
    CacheSession.conversationId = convId;

    final charId = _activeCharacterId;
    final history = _messages
        .where((m) => m.text.trim().isNotEmpty)
        .map(
          (m) => <String, String>{
            'role': m.isUser ? 'user' : 'assistant',
            'content': m.text,
          },
        )
        .toList();

    await KeepAliveService.instance.claimVisibleWindow(
      conversationId: convId,
      characterId: charId,
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
    );
    if (result > 0) {
      await _refreshWindowSummaryStateAfterCompression(convId);
      debugPrint('窗口摘要完成：$result tokens');
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

    if (L.locale == 'en') {
      final parts = <String>[];
      if (trimmedSummary.isNotEmpty) {
        parts.add('Recent summaries:\n$trimmedSummary');
      }
      if (trimmedKeyword.isNotEmpty) {
        parts.add('Keyword-matched old summary:\n$trimmedKeyword');
      }
      return '【Window Summary】\n${parts.join('\n\n')}';
    }

    final parts = <String>[];
    if (trimmedSummary.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '最近窗口摘要：')}\n$trimmedSummary');
    }
    if (trimmedKeyword.isNotEmpty) {
      parts.add('${L.pick(en: '', zhTW: '命中關鍵詞召回的舊摘要：')}\n$trimmedKeyword');
    }
    return '${L.pick(en: '', zhTW: '【窗口摘要】')}\n${parts.join('\n\n')}';
  }

  Future<int> _windowSummaryTriggerTokenLimit() async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final contextSummaryEnabled =
        await MemorySettings.getContextWindowSummaryEnabled();
    if (!cacheEnabled && contextLimitEnabled && contextSummaryEnabled) {
      return MemorySettings.getContextWindowSummaryTriggerTokens();
    }
    return ContextCompressor.triggerTokens;
  }

  Future<int> _windowSummaryCloseMinTokenThreshold() async {
    final cacheEnabled = await MemorySettings.getEnablePromptCaching();
    final cacheSummaryEnabled =
        await MemorySettings.getCacheWindowSummaryEnabled();
    if (cacheEnabled && cacheSummaryEnabled) {
      return ContextCompressor.minCompressTokens;
    }
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
      await ApiSettings.recordStarredModelUsage(model);
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
      conversationId: conversationId,
      characterId: _activeCharacterId,
      messages: keepAliveMessages,
      structuredPrompt: structuredPrompt,
      adapter: adapter,
      model: model,
      provider: provider,
    );

    await _maybeRunTokenTriggeredMaintenance(
      conversationId: conversationId,
      characterId: _activeCharacterId,
    );

    // ═══ 做夢整理：對話累積後自動梳理記憶（不阻塞主流程）═══
    unawaited(
      DreamCurationService.maybeTrigger(characterId: _activeCharacterId),
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
      });
    } else {
      _clearStreamQueue();
      _setGenerating(false);
      _chatSearching = false;
      _chatSearchQuery = '';
      _chatSearchResults = [];
      _webSearchActivity = null;
      _pendingWebSearchResult = null;
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

  String _apiErrorSummary(Object error) {
    var message = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    message = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (message.length > 180) message = '${message.substring(0, 180)}…';
    return message.isEmpty
        ? L.pick(en: 'The request failed', zhTW: '請求失敗')
        : message;
  }

  void _showApiConfigFailure(ApiConfigException error) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(error.message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: L.pick(en: 'Settings', zhTW: '去設定'),
          onPressed: () {
            if (mounted) Navigator.of(context).pushNamed('/api_settings');
          },
        ),
      ),
    );
  }

  void _showRetryableFailure(Object error, Future<void> Function() retry) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(_apiErrorSummary(error)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: L.pick(en: 'Retry', zhTW: '重試'),
          onPressed: () => unawaited(retry()),
        ),
      ),
    );
  }

  Future<void> _runMessageRetry(Future<void> Function() retry) async {
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
      _recoverEscapedGenerationFailure(
        error,
        generationSerialBefore: generationSerialBefore,
        retry: retry,
      );
    } finally {
      if (mounted) {
        _refreshChatState(() => _sendSubmissionInProgress = false);
      } else {
        _sendSubmissionInProgress = false;
      }
    }
  }

  void _recoverEscapedGenerationFailure(
    Object error, {
    required int generationSerialBefore,
    required Future<void> Function() retry,
  }) {
    // A send either fails before _beginGeneration or during that one new
    // generation. If the serial moved further, edit/stop/dispose already
    // invalidated this work and it must not reset a newer turn.
    final serialDelta = _generationSerial - generationSerialBefore;
    if (serialDelta < 0 || serialDelta > 1) return;
    final wasStopped = _stopGenerationRequested;
    _finishFailedGeneration();
    if (!wasStopped) {
      _showRetryableFailure(error, () => _runMessageRetry(retry));
    }
  }

  String _webSearchProviderLabel(ResolvedWebSearchProvider provider) {
    return switch (provider.id) {
      WebSearchProviderId.gemini => 'Gemini · ${provider.model}',
      WebSearchProviderId.openRouter => 'OpenRouter · ${provider.model} · Exa',
    };
  }

  void _dismissWebSearchConfirmation() {
    final dialogContext = _webSearchConfirmationContext;
    _webSearchConfirmationContext = null;
    if (dialogContext == null || !dialogContext.mounted) return;
    final navigator = Navigator.of(dialogContext);
    if (navigator.canPop()) navigator.pop(false);
  }

  Future<void> _showWebSearchPrivacyNote(BuildContext dialogContext) async {
    final text = await rootBundle.loadString('PRIVACY.md');
    if (!dialogContext.mounted) return;
    await showDialog<void>(
      context: dialogContext,
      builder: (privacyContext) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        title: Text(
          L.pick(en: 'Web-search privacy', zhTW: '網路搜尋隱私說明', zhCN: '网络搜索隐私说明'),
          style: YanciTheme.headingMedium,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text, style: YanciTheme.bodySmall),
          ),
        ),
        actions: <Widget>[
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.of(privacyContext).pop(),
            child: Text(L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭')),
          ),
        ],
      ),
    );
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
    final providerLabels = plan.providers
        .map(_webSearchProviderLabel)
        .toList(growable: false);
    _refreshChatState(() {
      _webSearchActivity = _WebSearchActivityState(
        status: WebSearchActivityStatus.awaitingConfirmation,
        query: query,
        providers: providerLabels,
      );
    });
    _scrollToBottom();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        _webSearchConfirmationContext = dialogContext;
        final hasGemini = plan.providers.any(
          (provider) => provider.id == WebSearchProviderId.gemini,
        );
        final hasOpenRouter = plan.providers.any(
          (provider) => provider.id == WebSearchProviderId.openRouter,
        );
        return AlertDialog(
          title: Text(
            L.pick(en: 'Confirm web search', zhTW: '確認網路搜尋', zhCN: '确认网络搜索'),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    L.pick(
                      en: 'This exact request will leave your device. Each provider may rewrite it into one or more search queries.',
                      zhTW: '下列這段請求會離開裝置；供應商可能各自改寫成一個或多個搜尋詞。',
                      zhCN: '下列这段请求会离开设备；供应商可能各自改写成一个或多个搜索词。',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: YanciTheme.accent.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                      border: Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.16),
                      ),
                    ),
                    child: SelectableText(
                      query,
                      style: YanciTheme.bodyText.copyWith(
                        color: YanciTheme.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final label in providerLabels)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.public_rounded, size: 17),
                          const SizedBox(width: 8),
                          Expanded(child: Text(label)),
                        ],
                      ),
                    ),
                  if (hasGemini) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      L.pick(
                        en: 'Gemini Developer API is intended for professional or business use and for clients not accessible to under-18s. If your API project uses unpaid quota, Google may use inputs and outputs to improve products and human reviewers may process them. Do not continue with personal, sensitive, or confidential data. Grounding data may be retained for 30 days; its result and Search Suggestions are shown together unchanged and are not sent to another model.',
                        zhTW:
                            'Gemini Developer API 僅供專業或商業用途，且 Client 不得供未滿 18 歲者使用。若 API 專案使用免費額度，Google 可能使用輸入與輸出改善產品，並可能由人工審查；請勿繼續傳送個人、敏感或機密資料。Grounding 資料可留存 30 天；結果會連同 Search Suggestions 原樣獨立顯示，不再送給其他模型。',
                        zhCN:
                            'Gemini Developer API 仅供专业或商业用途，且 Client 不得供未满 18 岁者使用。若 API 项目使用免费额度，Google 可能使用输入与输出改进产品，并可能由人工审查；请勿继续发送个人、敏感或机密数据。Grounding 数据可保留 30 天；结果会连同 Search Suggestions 原样独立显示，不再发送给其他模型。',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ],
                  if (hasOpenRouter) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      L.pick(
                        en: 'OpenRouter sends the request to OpenRouter, one dynamically selected ZDR inference endpoint for the explicit model, and Exa. Endpoint fallback is disabled. The App asks to disable the legacy web plugin, but an organization can prevent that override; do not continue unless you verified that your OpenRouter account enforces no default web plugin, or an extra search route may run. Exa still has separate retention terms.',
                        zhTW:
                            'OpenRouter 會把請求交給 OpenRouter、該明確模型下動態選出的一個 ZDR 推理端點，以及 Exa；端點備援已停用。App 會要求停用舊 Web Plugin，但組織可禁止覆寫；除非你已確認 OpenRouter 帳戶沒有強制預設 Web Plugin，否則請勿繼續，因為它可能再跑一條搜尋路線。Exa 仍有獨立留存規則。',
                        zhCN:
                            'OpenRouter 会把请求交给 OpenRouter、该明确模型下动态选出的一个 ZDR 推理端点，以及 Exa；端点回退已停用。App 会要求停用旧 Web Plugin，但组织可禁止覆盖；除非你已确认 OpenRouter 账户没有强制默认 Web Plugin，否则请勿继续，因为它可能再运行一条搜索路线。Exa 仍有独立保留规则。',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ],
                  if (plan.providers.length == 2) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      L.pick(
                        en: 'Dual mode launches both providers, counts as two provider launches, and displays the results separately.',
                        zhTW: '雙供應商模式會同時啟動兩家、計為兩次供應商發送，結果分開顯示。',
                        zhCN: '双供应商模式会同时启动两家、计为两次供应商发送，结果分开显示。',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () =>
                          unawaited(_showWebSearchPrivacyNote(dialogContext)),
                      icon: const Icon(Icons.privacy_tip_outlined, size: 17),
                      label: Text(
                        L.pick(
                          en: 'Read privacy details',
                          zhTW: '閱讀隱私細節',
                          zhCN: '阅读隐私细节',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.public_rounded, size: 18),
              label: Text(L.pick(en: 'Search', zhTW: '搜尋', zhCN: '搜索')),
            ),
          ],
        );
      },
    );
    _webSearchConfirmationContext = null;
    if (!mounted ||
        !_isCurrentGeneration(generationSerial) ||
        _stopGenerationRequested) {
      return false;
    }
    if (confirmed != true) {
      _refreshChatState(() => _webSearchActivity = null);
      return false;
    }
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
    _refreshChatState(() => _webSearchActivity = activity);
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
    try {
      final settings = await Future.wait<Object>(<Future<Object>>[
        WebSearchSettings.getEnabled(),
        WebSearchSettings.getMode(),
        WebSearchSettings.getDailyProviderLaunchCap(),
      ]);
      if (settings[0] != true) return;
      resolvedPlan = await _webSearchService.resolvePlan(
        settings[1] as WebSearchMode,
      );
      dailyProviderLaunchCap = settings[2] as int;
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
        turnId: 'message:$userMessageId',
        generationSerial: generationSerial,
        query: query,
        locale: L.locale,
        maxResults: 5,
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
        _refreshChatState(() {
          _pendingWebSearchResult = data;
          _webSearchActivity = null;
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

      final Future<void> Function() retry;
      if (acceptedUserMessage?.imagePath != null) {
        final accepted = acceptedUserMessage!;
        retry = () => _sendImageLocked(
          accepted.imagePath!,
          caption: accepted.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: accepted,
        );
      } else if (acceptedUserMessage != null) {
        final accepted = acceptedUserMessage;
        retry = () => _sendMessageLocked(
          accepted.text,
          composerDraft: '',
          clearComposerOnAccept: false,
          retryUserMessage: accepted,
        );
      } else {
        retry = () => _sendMessageLocked(
          text,
          composerDraft: text,
          clearComposerOnAccept: clearComposerOnAccept,
        );
      }
      _recoverEscapedGenerationFailure(
        error,
        generationSerialBefore: generationSerialBefore,
        retry: retry,
      );
    } finally {
      if (mounted) {
        _refreshChatState(() => _sendSubmissionInProgress = false);
      } else {
        _sendSubmissionInProgress = false;
      }
    }
  }

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
      CacheSession.conversationId = conversationId;
    }
    // 情緒衰減 tick（冪等：未到刷新間隔的點不會被動）
    EmotionCoordinates.tickDecay(_activeCharacterId);
    if (_isGenerating) return;
    if (_isGeneratingImage) return; // 圖片生成中不允許發送
    // 本地模型還在加載中 → 提示用戶稍候
    if (_localModelLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local model is loading, please wait...',
              zhTW: '本地模型加載中，請稍候……',
            ),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
      return;
    }
    _userScrolledUp = false; // 新消息 → 重新跟隨

    // 有待發圖片 → 圖文一起送
    if (retryUserMessage == null && _pendingImagePath != null) {
      final imgPath = _pendingImagePath!;
      _refreshChatState(() => _pendingImagePath = null);
      return _sendImageLocked(
        imgPath,
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
      retry: () => _sendMessageLocked(
        userMsgWithId.text,
        composerDraft: '',
        clearComposerOnAccept: false,
        retryUserMessage: userMsgWithId,
      ),
    );
    if (adapter == null) {
      if (mounted) _scrollToBottom();
      return;
    }
    _activeGenerationAdapter = adapter;

    // ═══ 並行化：一次發射所有獨立的異步調用，大幅減少等待 ═══
    final charId = _activeCharacterId;
    final systemPromptF = ApiSettings.getSystemPrompt();
    final modelF = ApiSettings.getModel();
    final bucketF = _memoryBucket();
    final userProfileF = _buildUserProfilePrompt();
    final selfNotesF = DatabaseHelper.getSelfNotes(charId);
    final userNicknameF = UserSettings.getUserName();
    final emotionEnabledF = MemorySettings.isAbilityEnabled('emotion');
    final imagegenEnabledF = MemorySettings.isAbilityEnabled('imagegen');
    final bioclockEnabledF = MemorySettings.isAbilityEnabled('bioclock');
    final memoryWriteEnabledF = MemorySettings.getMemoryWriteEnabled();
    final providerNameF = ApiSettings.getApiProviderName();
    final conciseOnF = ApiSettings.getConciseMode();
    final freeformOnF = ApiSettings.getFreeformMode();
    final thinkingEnabledF = ApiSettings.getThinkingChain();
    final webSearchEnabledF = WebSearchSettings.getEnabled();
    final enableVibrationF = UserSettings.getEnableVibration();
    final charDataF = DatabaseHelper.getCharacter(charId);
    final isSpiderWebEnabledF = charDataF.then(
      (c) => (c?['is_spider_web_enabled'] as int? ?? 0) == 1,
    );
    final staticWindowSummaryF = _buildStaticWindowSummaryPrompt(charId);
    final dynamicWindowSummaryF = _buildDynamicWindowSummaryPrompt(
      charId,
      currentMessage: outboundText,
    );

    // 記憶注入依賴 bucket，先 await bucket 再發射
    final bucket = await bucketF;
    final memoryPromptF = Retriever.buildMemoryPrompt(
      mode: bucket,
      currentMessage: outboundText,
      characterId: charId,
      windowId: widget.conversationId,
    );

    // 動態部分：也提前發射
    final emoStateF = emotionEnabledF.then(
      (enabled) async =>
          enabled ? await EmotionCoordinates.statePrompt(charId) : '',
    );
    final recallPromptF = CharacterTimelineService.recallPrompt(charId, text);
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
    final memoryWriteEnabled = await memoryWriteEnabledF;
    final providerName = await providerNameF;
    final conciseOn = await conciseOnF;
    final freeformOn = await freeformOnF;
    final thinkingEnabled = await thinkingEnabledF;
    final webSearchEnabled = await webSearchEnabledF;

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
    );

    final dynamicParts = <String>[];
    final controlParts = <String>[];
    final turnEffects = DeferredPromptBatch()..add(memoryPrompt);
    final now = DateTime.now();
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

    final coinDelta = await _coinDeltaPrompt(charId);
    if (coinDelta.isNotEmpty) dynamicParts.add(coinDelta);
    // 背包窗內變動（「杯子+1（昭昭送的）」式增減量）
    if (_packQtySnapshot != null) {
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
    final scratchGiftPrompt = _scratchGiftDynamicPrompt(pendingScratchGift);
    if (scratchGiftPrompt.isNotEmpty) dynamicParts.add(scratchGiftPrompt);

    // 上輪購買失敗回饋（消費即清，防止她以為禮物送出去了）
    final buyFailPrompt = _pendingBuyFailurePrompt();
    if (buyFailPrompt.isNotEmpty) {
      dynamicParts.add(buyFailPrompt.text);
      turnEffects.add(buyFailPrompt);
    }

    // 同逛商店：邀請後清單跟隨 3 輪（動態注入不入庫）
    final browsePrompt = await _shopBrowsePrompt();
    if (browsePrompt.isNotEmpty) {
      dynamicParts.add(browsePrompt.text);
      turnEffects.add(browsePrompt);
    }

    // 結婚證：解鎖後她也可主動遞（未簽＋未遞過才注入）
    final proposeHint = await MarriageService.proposeHintPrompt(charId);
    if (proposeHint.isNotEmpty) dynamicParts.add(proposeHint);

    // X 發文動態狀態（剩餘條數每日變，不能進靜態）
    final xHint = await XPostSettings.promptHint(charId);
    if (xHint.isNotEmpty) {
      dynamicParts.add(
        '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$xHint',
      );
    }

    // 情緒狀態（已提前發射）
    final emoState = await emoStateF;
    if (emoState.isNotEmpty) dynamicParts.add(emoState);

    // 生物鐘單一路徑：當前時段提醒 > 去重（帶冷卻） > 校準 > 構建／飯點。
    // 所有帶冷卻或時段消費的提示都在模型成功返回後才提交。
    if (bioclockEnabled) {
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
    if (bioclockEnabled && _habitSnapshotIds != null) {
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
      if (await ShopService.isEnabled()) {
        final packPrompt = await ShopService.buildPackPrompt(charId);
        if (packPrompt.isNotEmpty) dynamicParts.add(packPrompt);
      }
      final snapshot = await CharacterTimelineService.stateSnapshotPrompt(
        charId,
      );
      if (snapshot.isNotEmpty) dynamicParts.add(snapshot);
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
    if (fatiguePrompt.isNotEmpty) {
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

    // 思考鏈
    if (thinkingEnabled && providerName != 'thinking_machines') {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Thinking',
          zhTWTitle: 'Thinking',
          content: L.pick(
            en: '【Thinking Mode】Before replying, show your inner thought process in <think>...</think> tags (first person). Use the same language as the normal reply for the thought process, then reply normally.',
            zhTW:
                '【思考模式】在回覆前，用 <think>...</think> 標籤展示你的內心思考過程（第一人稱），思考內容必須與正常回覆使用相同語言，思考完再正常回覆。',
          ),
        ),
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
    final structured = StructuredPrompt(
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
      var history = nonEmpty
          .map(
            (m) => {'role': m.isUser ? 'user' : 'assistant', 'content': m.text},
          )
          .toList();

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
        final anchorMsgId = start < nonEmpty.length ? nonEmpty[start].id : null;
        if (anchorMsgId != null) {
          unawaited(_persistContextAnchor(anchorMsgId));
        }
      }

      var requestUsage = const ApiUsage();
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
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
        if (mounted) _onStreamChunk(chunk);
      }
      streamCompleted = true;
      await turnEffects.commit();
      final replyText = rawReply.toString();
      if (!_isCurrentGeneration(generationSerial)) return;
      final webSearchIntent = WebSearchIntentParser.parse(replyText);
      final replyTextWithoutWebSearch = webSearchIntent.visibleText;
      if (mounted) {
        _refreshChatState(() {
          _clearStreamQueue();
          _streamingText = replyTextWithoutWebSearch;
        });
      } else {
        _clearStreamQueue();
        _streamingText = replyTextWithoutWebSearch;
      }

      // ═══ 記錄真實 API 用量（不再用估算，避免雙重計算）═══
      await _tokenTracker.recordRealUsage(
        provider: providerName,
        model: model,
        usage: requestUsage,
        characterId: _activeCharacterId,
      );

      // 檢查本次是否命中緩存
      final cacheRead = requestUsage.cacheReadTokens;

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = (memoryWriteEnabled || isSpiderWebEnabled)
          ? await MemoryActions.processReply(
              replyTextWithoutWebSearch,
              characterId: _activeCharacterId,
              mode: await _memoryBucket(),
              windowId: widget.conversationId,
            )
          : MemoryActions.stripReply(
              replyTextWithoutWebSearch,
              windowId: widget.conversationId,
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
      processedText = await EmotionCoordinates.processReply(
        processedText,
        characterId: _activeCharacterId,
        memoryId: MemoryActions.lastInsertedMemoryIdFor(widget.conversationId),
      );
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      processedText = await BioClockService.processReply(
        processedText,
        characterId: _activeCharacterId,
      );
      // ═══ 角色生活化：只處理明確 <life_fix>；事件由摘要模型候選
      //     經本地驗證後寫入，不再掃回覆關鍵詞。═══
      processedText = await CharacterTimelineService.processLifeFix(
        _activeCharacterId,
        processedText,
      );
      await BioClockService.recordLastChatTime(_activeCharacterId);
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
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(
                    en: '$_characterName does not have enough shells to send a scratch card.',
                    zhTW: '【$_characterName】貝殼不足，無法送出刮刮樂',
                  ),
                ),
                backgroundColor: YanciTheme.accent,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
      // ═══ 生成 UI memoryLog 之前清理殘餘標籤 ═══
      String? drawPrompt;
      final drawEventMatch = RegExp(r'<draw\s*/>').firstMatch(processedText);
      if (drawEventMatch != null) {
        drawPrompt = L.pick(
          en: '(reference image uploaded manually by the user / or retained by the system)',
          zhTW: '(由用戶手動上傳參考圖 / 或系統保留)',
        );
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
        if (amount > 0) {
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
        pendingCallOpening = (callMatch.group(1) ?? '').trim();
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
        drawPrompt = drawMatch.group(1)!.trim();
      }
      // ═══ 歷史搜尋：<search_chat> 觸發可視化搜索 + 自動追加回覆 ═══
      final searchQuery = MemoryActions.lastSearchQueryFor(
        widget.conversationId,
      );
      if (searchQuery != null) {
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
            arguments: <String, Object?>{'query': searchQuery},
          ),
          context: ToolContext(
            conversationId: widget.conversationId,
            characterId: _activeCharacterId,
            mode: ToolRunMode.local,
            metadata: <String, Object?>{'generation_serial': generationSerial},
          ),
        );
        if (!_isCurrentGeneration(generationSerial)) return;
        if (_stopGenerationRequested || searchResult.isCancelled) {
          _finishFailedGeneration();
          return;
        }
        final searchResults = searchResult
            .requireData<List<Map<String, dynamic>>>();
        // Phase 2: 顯示搜索結果
        if (mounted) {
          _refreshChatState(() {
            _chatSearching = false;
            _chatSearchResults = searchResults;
          });
          _scrollToBottom();
        }
        if (searchResults.isNotEmpty) {
          final nick = userNicknameStr.isNotEmpty
              ? userNicknameStr
              : L.pick(en: 'the other person', zhTW: '對方');
          final resultLines = searchResults.map((r) {
            final who = (r['is_user'] as int) == 1
                ? nick
                : L.pick(en: 'you', zhTW: '你');
            final date = (r['created_at'] as String).substring(0, 10);
            var t = r['text'] as String;
            if (t.length > 200) t = '${t.substring(0, 200)}…';
            return '[$date] $who${L.pick(en: ': ', zhTW: '：')}$t';
          }).toList();
          final searchHeader = L.pick(
            en: '【Hidden Chat Retrieval Results | invisible to user】\nQuery: ',
            zhTW: '【隱藏歷史檢索結果｜user 不可見】\n查詢詞：',
          );
          final searchRules = L.pick(
            en: 'Rules: This is internal reference material only. Do not say “I searched”, mention chat records, keywords, browsers, or reveal the retrieval process; do not output a list. Weave useful information naturally into the next visible reply while continuing the prior tone and relationship state.',
            zhTW:
                '規則：這些內容只是系統給你的內部參考。不要說「我搜尋到了」「聊天記錄」「關鍵詞」「瀏覽器」或展示檢索過程；不要列清單。請把有用資訊自然融入下一句正式回覆，延續先前語氣與關係狀態。',
          );
          final injection =
              '$searchHeader「$searchQuery」\n${resultLines.join('\n')}\n---\n$searchRules';
          // TODO(tool-result-transport): ApiAdapter 目前只接受字串 role；待所有
          // provider 有統一 typed event 後，改用真正 tool_result／request-only
          // sidecar，不能長期把 App 產生的檢索資料借作 user role。
          final followHistory = [
            ...history,
            if (processedText.trim().isNotEmpty)
              {'role': 'assistant', 'content': processedText},
            {'role': 'user', 'content': injection},
          ];
          // Phase 3: 二次流式生成
          final buf = StringBuffer();
          var followUsage = const ApiUsage();
          if (mounted) {
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
          await _tokenTracker.recordRealUsage(
            provider: providerName,
            model: model,
            usage: followUsage,
            characterId: _activeCharacterId,
          );
          var followUp = memoryWriteEnabled
              ? await MemoryActions.processReply(
                  buf.toString(),
                  characterId: _activeCharacterId,
                  mode: await _memoryBucket(),
                  windowId: widget.conversationId,
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
          followUp = await EmotionCoordinates.processReply(
            followUp,
            characterId: _activeCharacterId,
            memoryId: MemoryActions.lastInsertedMemoryIdFor(
              widget.conversationId,
            ),
          );
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .replaceAll(RegExp(r'<draw>[\s\S]*?</draw>'), '')
              .trim();
          if (followUp.isNotEmpty) {
            processedText = '$processedText\n\n$followUp'.trim();
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
          );
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
          followUp = await EmotionCoordinates.processReply(
            followUp,
            characterId: _activeCharacterId,
            memoryId: null,
          );
          followUp = followUp
              .replaceAll(RegExp(r'<home>[\s\S]*?</home>'), '')
              .trim();
          if (followUp.isNotEmpty) {
            processedText = '$processedText\n\n$followUp'.trim();
          }
        }
      }

      processedText = _extractXPostAndStrip(processedText);

      final webSearchQuery = webSearchIntent.query;
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
      }

      // ═══ 記憶過程日誌：只記寫入本地的操作 ═══
      // （注入給模型的內容不顯示——那是給她看的，不是給你看的）
      final memLogLines = <String>[
        ...MemoryActions.lastActionLogFor(widget.conversationId),
        ...EmotionCoordinates.lastPointLog,
        ...BioClockService.lastActionLog,
        if (drawPrompt != null) '🎨 生成中…',
      ];
      final memLog = memLogLines.isEmpty
          ? ''
          : '${memLogLines.join('\n')}\nDone';
      if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
        _finishFailedGeneration();
        return;
      }
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: cacheRead > 0,
        memoryLog: memLog,
      );
      final insertedId = await DatabaseHelper.insertMessage(aiMsg);
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
      );
      final completedWebSearchResult = _pendingWebSearchResult;

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
          _clearStreamQueue();
          _setGenerating(false);
        });
      } else {
        _pendingWebSearchResult = null;
        _clearStreamQueue();
        _setGenerating(false);
      }
      if (drawPrompt != null && aiMsgWithId.id != null) {
        _runDrawAsync(aiMsgWithId.id!, drawPrompt, memLog);
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
        userText: outboundText,
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
      _showApiConfigFailure(e);
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final incomplete = streamCompleted
          ? null
          : await _persistIncompleteReply(rawReply.toString());
      _finishFailedGeneration();
      if (_stopGenerationRequested) return;
      _showRetryableFailure(
        e,
        incomplete?.id != null
            ? () => _retryIncompleteMessage(incomplete!.id!)
            : () => _runMessageRetry(
                () => _sendMessageLocked(
                  userMsgWithId.text,
                  composerDraft: '',
                  clearComposerOnAccept: false,
                  retryUserMessage: userMsgWithId,
                ),
              ),
      );
    } finally {
      if (identical(_activeGenerationAdapter, adapter)) {
        _activeGenerationAdapter = null;
      }
    }
    if (mounted) _scrollToBottom();
  }

  /// 發送圖片（相冊 or 表情包）
  Future<void> _sendImageLocked(
    String path, {
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
      CacheSession.conversationId = conversationId;
    }
    if (_isGenerating) return;
    if (_isGeneratingImage) return;
    if (_localModelLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local model is loading, please wait...',
              zhTW: '本地模型加載中，請稍候……',
            ),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
      return;
    }

    // 首次發送才複製圖片；重試沿用已入庫的原消息與 app 內路徑。
    final saved =
        retryUserMessage?.imagePath ?? await ImageService.copyToAppDir(path);
    if (saved.isEmpty) return;
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
      retry: () => _sendImageLocked(
        userMsgWithId.imagePath ?? path,
        caption: userMsgWithId.text,
        composerDraft: '',
        clearComposerOnAccept: false,
        retryUserMessage: userMsgWithId,
      ),
    );
    if (adapter == null) {
      MemoryActions.clearSearchQuery(widget.conversationId);
      if (mounted) _scrollToBottom();
      return;
    }
    _activeGenerationAdapter = adapter;

    // ── 構建 API 消息 ──
    final systemPrompt = await ApiSettings.getSystemPrompt();
    final model = await ApiSettings.getModel();
    _currentModel = model;
    final imgMemoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();

    final memoryPrompt = await Retriever.buildMemoryPrompt(
      mode: await _memoryBucket(),
      currentMessage: outboundCaption.isNotEmpty
          ? outboundCaption
          : '（用戶發送了一張圖片）',
      characterId: _activeCharacterId,
      windowId: widget.conversationId,
    );
    final imgUserProfile = await _buildUserProfilePrompt();
    final imgSelfNotes = await DatabaseHelper.getSelfNotes(_activeCharacterId);
    final userNickname = await UserSettings.getUserName();
    final charDataImg = await DatabaseHelper.getCharacter(_activeCharacterId);
    final imgCharDesc = charDataImg?['description'] as String? ?? '';
    final imgCharName = charDataImg?['name'] as String? ?? '';
    final isSpiderWebEnabledImg =
        (charDataImg?['is_spider_web_enabled'] as int? ?? 0) == 1;
    final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
    final imgBioclockEnabled = await MemorySettings.isAbilityEnabled(
      'bioclock',
    );
    final imgImagegenEnabled = await MemorySettings.isAbilityEnabled(
      'imagegen',
    );
    final imgProviderName = await ApiSettings.getApiProviderName();
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
      // Image/call paths do not execute web.search in v1. Keep the capability
      // out of their static prompt so a tag is never silently ignored.
      webSearchEnabled: false,
      whisperModelOverrideEnabled:
          (charDataImg?['whisper_model_override'] as int? ?? 1) == 1,
      providerName: imgProviderName,
      staticWindowSummary: await _buildStaticWindowSummaryPrompt(
        _activeCharacterId,
      ),
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
    final controlParts = <String>[];
    final turnEffects = DeferredPromptBatch()..add(memoryPrompt);
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
    final imgCoinDelta = await _coinDeltaPrompt(_activeCharacterId);
    if (imgCoinDelta.isNotEmpty) dynamicParts.add(imgCoinDelta);
    // 背包窗內變動（與 text path 同步）
    if (_packQtySnapshot != null) {
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
    final imgScratchGiftPrompt = _scratchGiftDynamicPrompt(pendingScratchGift);
    if (imgScratchGiftPrompt.isNotEmpty) {
      dynamicParts.add(imgScratchGiftPrompt);
    }
    // 上輪購買失敗回饋（與 text path 同步）
    final imgBuyFailPrompt = _pendingBuyFailurePrompt();
    if (imgBuyFailPrompt.isNotEmpty) {
      dynamicParts.add(imgBuyFailPrompt.text);
      turnEffects.add(imgBuyFailPrompt);
    }
    // 同逛商店清單跟隨（與 text path 同步）
    final imgBrowsePrompt = await _shopBrowsePrompt();
    if (imgBrowsePrompt.isNotEmpty) {
      dynamicParts.add(imgBrowsePrompt.text);
      turnEffects.add(imgBrowsePrompt);
    }
    // 結婚證主動遞提示（與 text path 同步）
    final imgProposeHint = await MarriageService.proposeHintPrompt(
      _activeCharacterId,
    );
    if (imgProposeHint.isNotEmpty) dynamicParts.add(imgProposeHint);
    // X 發文動態狀態（與 text path 同步）
    final imgXHint = await XPostSettings.promptHint(_activeCharacterId);
    if (imgXHint.isNotEmpty) {
      dynamicParts.add(
        '${L.pick(en: '【X Posting Status】', zhTW: '【X 發文狀態】')}$imgXHint',
      );
    }
    // 情緒狀態回饋（餵狀態不餵機制，空狀態零開銷）
    if (emotionEnabled) {
      final emoState = await EmotionCoordinates.statePrompt(_activeCharacterId);
      if (emoState.isNotEmpty) dynamicParts.add(emoState);
    }

    // 生物鐘：與文字路徑使用相同優先級與送達後提交機制。
    if (imgBioclockEnabled) {
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

    // 思考鏈
    final thinkingOn = await ApiSettings.getThinkingChain();
    if (thinkingOn && imgProviderName != 'thinking_machines') {
      controlParts.add(
        SystemContextMarkdown.section(
          enTitle: 'Thinking',
          zhTWTitle: 'Thinking',
          content: L.pick(
            en: '【Thinking Mode】Before replying, show your inner thought process in <think>...</think> tags (first person). Use the same language as the normal reply for the thought process, then reply normally.',
            zhTW:
                '【思考模式】在回覆前，用 <think>...</think> 標籤展示你的內心思考過程（第一人稱），思考內容必須與正常回覆使用相同語言，思考完再正常回覆。',
          ),
        ),
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

    final liveDynamicPart = SystemContextMarkdown.join(dynamicParts);
    final structured = StructuredPrompt(
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
      // ═══ 歷史圖片降級：只有最新一張真實上傳 ═══
      // 舊版每輪把全部歷史圖片重新 base64 上傳，
      // token 成本隨圖片數量線性暴漲（一張圖 ≈ 上千 tokens × 每輪）。
      // 更早的圖片降級為文字佔位，內容靠記憶系統承接。
      final filtered = workingMessages
          .where((m) => m.text.isNotEmpty || m.imagePath != null)
          .toList();
      int lastImageIdx = -1;
      for (int i = filtered.length - 1; i >= 0; i--) {
        if (filtered[i].imagePath != null) {
          lastImageIdx = i;
          break;
        }
      }
      var history = <Map<String, dynamic>>[];
      for (int i = 0; i < filtered.length; i++) {
        final m = filtered[i];
        final degraded = m.imagePath != null && i != lastImageIdx;
        history.add(<String, dynamic>{
          'role': m.isUser ? 'user' : 'assistant',
          'content': degraded
              ? '（這裡曾發送一張圖片${m.text.isNotEmpty ? '：${m.text}' : ''}）'
              : (m.text.isNotEmpty ? m.text : '（圖片）'),
          if (m.imagePath != null && i == lastImageIdx)
            'imagePath': m.imagePath,
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
        final anchorMsgId2 = start2 < filtered.length
            ? filtered[start2].id
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
        final imgPath = m['imagePath'] as String?;

        if (imgPath != null && role == 'user') {
          final dataUrl = await ImageService.toBase64DataUrl(imgPath);
          if (dataUrl != null) {
            // 用特殊標記讓 adapter 識別多模態
            apiMessages.add({
              'role': role,
              'content': content,
              'image_data_url': dataUrl,
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
      final replyText = rawReply.toString();
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
      );

      final imgCacheRead = requestUsage.cacheReadTokens;

      // ═══ 模型自主記憶：開啟時才執行 <memo>/<persona_note> 落庫 ═══
      var processedText = imgMemoryWriteEnabled
          ? await MemoryActions.processReply(
              replyText,
              characterId: _activeCharacterId,
              mode: await _memoryBucket(),
              windowId: widget.conversationId,
            )
          : MemoryActions.stripReply(
              replyText,
              windowId: widget.conversationId,
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
      processedText = await EmotionCoordinates.processReply(
        processedText,
        characterId: _activeCharacterId,
        memoryId: MemoryActions.lastInsertedMemoryIdFor(widget.conversationId),
      );
      // ═══ 生物鐘：<clock> 標籤入庫並剝離 ═══
      processedText = await BioClockService.processReply(
        processedText,
        characterId: _activeCharacterId,
      );
      // ═══ 角色生活化：只處理明確 <life_fix>；時間線事件不掃關鍵詞。═══
      processedText = await CharacterTimelineService.processLifeFix(
        _activeCharacterId,
        processedText,
      );
      await BioClockService.recordLastChatTime(_activeCharacterId);
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
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(
                    en: '$_characterName does not have enough shells to send a scratch card.',
                    zhTW: '【$_characterName】貝殼不足，無法送出刮刮樂',
                  ),
                ),
                backgroundColor: YanciTheme.accent,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
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
        if (amount > 0) {
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
        pendingCallOpening = (callMatch.group(1) ?? '').trim();
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
        drawPrompt = drawMatch.group(1)!.trim();
      }

      processedText = _extractXPostAndStrip(processedText);

      // ═══ 記憶過程日誌：只記寫入本地的操作 ═══
      // （注入給模型的內容不顯示——那是給她看的，不是給你看的）
      final memLogLines = <String>[
        ...MemoryActions.lastActionLogFor(widget.conversationId),
        ...EmotionCoordinates.lastPointLog,
        ...BioClockService.lastActionLog,
        if (drawPrompt != null) '🎨 生成中…',
      ];
      final memLog = memLogLines.isEmpty
          ? ''
          : '${memLogLines.join('\n')}\nDone';
      if (!_isCurrentGeneration(generationSerial)) return;
      final aiMsg = Message(
        conversationId: conversationId,
        characterId: _activeCharacterId,
        text: processedText,
        isUser: false,
        splitMode: _splitReply,
        cacheHit: imgCacheRead > 0,
        memoryLog: memLog,
      );
      final imgAiId = await DatabaseHelper.insertMessage(aiMsg);
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
        _runDrawAsync(aiMsgWithId.id!, drawPrompt, memLog);
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
      _showApiConfigFailure(e);
    } catch (e) {
      if (!_isCurrentGeneration(generationSerial)) return;
      final incomplete = streamCompleted
          ? null
          : await _persistIncompleteReply(rawReply.toString());
      _finishFailedGeneration();
      if (_stopGenerationRequested) return;
      _showRetryableFailure(
        e,
        incomplete?.id != null
            ? () => _retryIncompleteMessage(incomplete!.id!)
            : () => _runMessageRetry(
                () => _sendImageLocked(
                  userMsgWithId.imagePath ?? path,
                  caption: userMsgWithId.text,
                  composerDraft: '',
                  clearComposerOnAccept: false,
                  retryUserMessage: userMsgWithId,
                ),
              ),
      );
    } finally {
      if (identical(_activeGenerationAdapter, adapter)) {
        _activeGenerationAdapter = null;
      }
      MemoryActions.clearSearchQuery(widget.conversationId);
    }
    if (mounted) _scrollToBottom();
  }

  /// 構建用戶檔案 prompt
  Future<String> _buildUserProfilePrompt() async {
    final nickname = await UserSettings.getUserName();
    final pronouns = await UserSettings.getUserPronouns();
    final bio = await UserSettings.getUserBio();
    if (nickname.isEmpty && pronouns.isEmpty && bio.isEmpty) return '';
    final parts = <String>[];
    if (L.locale == 'en') {
      if (nickname.isNotEmpty) parts.add('Name: $nickname');
      if (pronouns.isNotEmpty) parts.add('Pronouns: $pronouns');
      if (bio.isNotEmpty) parts.add('About: $bio');
      return '【User Profile】${parts.join(', ')}';
    } else {
      if (nickname.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '暱稱：')}$nickname');
      }
      if (pronouns.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '稱謂：')}$pronouns');
      }
      if (bio.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '自我介紹：')}$bio');
      }
      return '${L.pick(en: '', zhTW: '【用戶檔案】')}${parts.join(L.pick(en: '', zhTW: '，'))}';
    }
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
      final char = await DatabaseHelper.getCharacter(_activeCharacterId);
      final characterName = (char?['name'] as String? ?? _characterName).trim();
      final relationship = (char?['relationship'] as String? ?? '').trim();
      final characterProfile = truncateGraphemes(
        (char?['description'] as String? ?? '').trim(),
        500,
      );
      final userName = (await UserSettings.getUserName()).trim();
      final dialogueUser = truncateGraphemes(userText.trim(), 160);
      final dialogueCharacter = truncateGraphemes(aiText.trim(), 160);

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
