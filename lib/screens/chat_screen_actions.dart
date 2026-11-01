part of 'chat_screen.dart';

extension _ChatActionMethods on _ChatScreenState {
  Future<void> _savePersonaCardDraft(
    int messageId,
    GuidePersonaDraft draft,
  ) async {
    final inCurrent = _messages.any((message) => message.id == messageId);
    final inOlder = _olderMessages.any((message) => message.id == messageId);
    if (!inCurrent && !inOlder) return;
    final state = PersonaCardState(draft: draft);
    if (!await DatabaseHelper.updateMessagePersonaCard(messageId, state)) {
      return;
    }
    if (!mounted) return;
    _refreshChatState(() {
      for (var index = 0; index < _messages.length; index++) {
        if (_messages[index].id == messageId) {
          _messages[index] = _copyMessageWithPersonaCard(
            _messages[index],
            state,
          );
        }
      }
      for (var index = 0; index < _olderMessages.length; index++) {
        if (_olderMessages[index].id == messageId) {
          _olderMessages[index] = _copyMessageWithPersonaCard(
            _olderMessages[index],
            state,
          );
        }
      }
    });
  }

  Future<bool> _addCharacterFromPersonaCard(
    int messageId,
    GuidePersonaDraft draft,
  ) async {
    if (draft.name.trim().isEmpty) {
      _showChatNotice(
        L.pick(en: 'A name is required.', zhTW: '請先填寫角色名。', zhCN: '请先填写角色名。'),
      );
      return false;
    }
    final characterId = const Uuid().v4();
    final state = PersonaCardState(
      draft: draft,
      createdCharacterId: characterId,
    );
    final now = DateTime.now().toIso8601String();
    final added = await DatabaseHelper.addCharacterFromPersonaCard(
      messageId: messageId,
      cardState: state,
      character: <String, Object?>{
        'id': characterId,
        'name': draft.name.trim(),
        'gender': draft.gender.trim(),
        'relationship': draft.relationship.trim(),
        'description': draft.description.trim(),
        'race': draft.race.trim(),
        'skill': draft.skill.trim(),
        'age': draft.age.trim(),
        'height': draft.height.trim(),
        'avatar_path': '',
        'tts_voice_id': null,
        'draw_anchor_user': '',
        'draw_anchor_char': '',
        'draw_style': '',
        'whisper_model_override': 0,
        'created_at': now,
        'updated_at': now,
      },
    );
    if (!added || !mounted) return false;
    _refreshChatState(() {
      for (var index = 0; index < _messages.length; index++) {
        if (_messages[index].id == messageId) {
          _messages[index] = _copyMessageWithPersonaCard(
            _messages[index],
            state,
          );
        }
      }
      for (var index = 0; index < _olderMessages.length; index++) {
        if (_olderMessages[index].id == messageId) {
          _olderMessages[index] = _copyMessageWithPersonaCard(
            _olderMessages[index],
            state,
          );
        }
      }
    });
    _showChatNotice(
      L.pick(en: 'Character added.', zhTW: '已加入角色。', zhCN: '已加入角色。'),
    );
    return true;
  }

  Message _copyMessageWithPersonaCard(
    Message message,
    PersonaCardState cardState,
  ) => Message(
    id: message.id,
    conversationId: message.conversationId,
    characterId: message.characterId,
    text: message.text,
    isUser: message.isUser,
    imagePath: message.imagePath,
    imagePaths: message.imagePaths,
    splitMode: message.splitMode,
    cacheHit: message.cacheHit,
    status: message.status,
    revision: message.revision,
    memoryLog: message.memoryLog,
    webSearchTrace: message.webSearchTrace,
    emailDraft: message.emailDraft,
    personaCard: cardState,
    createdAt: message.createdAt,
  );

  void _openPersonaCharacter(String characterId) {
    Navigator.of(context).pushNamed('/character', arguments: characterId);
  }

  Future<void> _openRpStoryArchive() async {
    final identity = _sessionIdentity;
    if (identity == null ||
        identity.contextMode != ContextMode.rp ||
        !mounted) {
      return;
    }
    final rows = await DatabaseHelper.getRpStorylines(_activeCharacterId);
    if (!mounted) return;
    final storylineIndex = rows.indexWhere(
      (row) => row['id']?.toString() == identity.continuityId,
    );
    final storylineName = storylineIndex < 0
        ? L.pick(en: 'Current storyline', zhTW: '當前故事線', zhCN: '当前故事线')
        : rpStorylineDisplayName(rows[storylineIndex], storylineIndex + 1);
    final palette = ChatBackgroundPresetScope.of(context)?.palette;
    final panelColor = palette?.inputBarBg ?? YanciTheme.surfacePanel;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: ColoredBox(
              color: panelColor,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 34,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    _rpArchiveChoice(
                      sheetContext,
                      value: 'worldbook',
                      icon: Icons.public_rounded,
                      title: L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书'),
                      subtitle: L.pick(
                        en: 'Search, read, and edit recalled setting entries',
                        zhTW: '搜尋、閱讀與修改召回設定',
                        zhCN: '搜索、阅读与修改召回设定',
                      ),
                    ),
                    _rpArchiveChoice(
                      sheetContext,
                      value: 'relationships',
                      icon: Icons.hub_outlined,
                      title: L.pick(
                        en: 'Relationships',
                        zhTW: '人物關係',
                        zhCN: '人物关系',
                      ),
                      subtitle: L.pick(
                        en: 'Characters, pairwise relations, and live states',
                        zhTW: '人物、逐對關係與當前劇情狀態',
                        zhCN: '人物、逐对关系与当前剧情状态',
                      ),
                    ),
                    _rpArchiveChoice(
                      sheetContext,
                      value: 'storyline',
                      icon: Icons.alt_route_rounded,
                      title: L.pick(
                        en: 'Current storyline',
                        zhTW: '當前故事線',
                        zhCN: '当前故事线',
                      ),
                      subtitle: storylineName,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final route = switch (choice) {
      'worldbook' => MaterialPageRoute<void>(
        builder: (_) => RpWorldbookScreen(
          characterId: _activeCharacterId,
          continuityId: identity.continuityId,
        ),
      ),
      'relationships' => MaterialPageRoute<void>(
        builder: (_) => RpStoryRelationshipScreen(
          characterId: _activeCharacterId,
          continuityId: identity.continuityId,
        ),
      ),
      _ => MaterialPageRoute<void>(
        builder: (_) => RpStorylineScreen(characterId: _activeCharacterId),
      ),
    };
    await Navigator.of(context).push(route);
  }

  Widget _rpArchiveChoice(
    BuildContext sheetContext, {
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => Semantics(
    button: true,
    label: title,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.pop(sheetContext, value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 62),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 22, color: YanciTheme.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: YanciTheme.bodyText),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _refreshMarriageState() async {
    final unlocked = await MarriageService.isUnlocked(_activeCharacterId);
    final married = await MarriageService.isMarried(_activeCharacterId);
    final date = married
        ? await MarriageService.marriageDate(_activeCharacterId)
        : null;
    if (_userNameCache.isEmpty) {
      final nick = _userPersonaName;
      _userNameCache = nick.isNotEmpty ? nick : '對方';
    }
    if (!mounted) return;
    if (unlocked != _marriageUnlocked ||
        married != _isMarried ||
        date != _marriageDate) {
      _refreshChatState(() {
        _marriageUnlocked = unlocked;
        _isMarried = married;
        _marriageDate = date;
      });
    }
  }

  Future<void> _openChatShop() async {
    if (!(await ToolFeatureSettings.load()).shopEnabled) return;
    if (!mounted) return;
    // 先選對象：給自己買（普通模式）or 送TA（掛起隨消息）
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          L.pick(en: 'Browse shop', zhTW: '逛商店'),
          style: TextStyle(
            fontSize: 15,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'self'),
            child: Row(
              children: [
                Icon(
                  Icons.person_outline_rounded,
                  size: 18,
                  color: YanciTheme.accent,
                ),
                const SizedBox(width: 10),
                Text(
                  L.pick(en: 'Buy for myself', zhTW: '給自己買'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'char'),
            child: Row(
              children: [
                Icon(
                  Icons.card_giftcard_rounded,
                  size: 18,
                  color: YanciTheme.accent,
                ),
                const SizedBox(width: 10),
                Text(
                  L.pick(en: 'Gift with next message', zhTW: '送給TA（隨下一條消息）'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => target == 'self'
          ? ShopBottomSheet(
              mode: ShopMode.normal,
              inviteCharName: _characterName,
              onInviteBrowse: _sendShopInvite,
            )
          : ShopBottomSheet(
              mode: ShopMode.giftPending,
              targetCharId: _activeCharacterId,
              pendingScopeId: widget.conversationId,
              onGiftPending: (reservation) {
                _refreshChatState(() => _pendingGift = reservation);
              },
              inviteCharName: _characterName,
              onInviteBrowse: _sendShopInvite,
            ),
    );
  }

  /// 邀請角色一起逛商店：邀請標記入庫（帶短說明），
  /// 商品清單走動態注入跟隨接下來 3 輪 user 消息——有連續性、不永駐歷史。
  Future<void> _sendShopInvite() async {
    if (!_isChatReady || _isGenerating || _isGeneratingImage) return;
    if (!await ShopService.isEnabled()) return;
    _shopInviteRoundsLeft = _ChatScreenState._shopInviteRounds;
    const text =
        '[shop_invite]'
        '（系統說明：對方邀請你一起逛商店，商品清單會隨接下來幾輪消息附上。'
        '想逛就陪著逛，不想逛也可以用你自己的方式拒絕。這段說明對方看不到）';
    await _onSendMessage(text);
  }

  /// 她遞的證書：點卡片 → 簽字/拒絕/再想想。
  /// 簽字落狀態；拒絕需二次確認；兩者都以隱藏事件告知她、觸發反應。
  Future<void> _signCharCert() async {
    if (_isMarried || _isGenerating || !_isChatReady) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          L.pick(en: 'Sign the certificate?', zhTW: '在證書上簽字？', zhCN: '在证书上签字？'),
          style: TextStyle(
            fontSize: 16,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        content: Text(
          L.pick(
            en: 'Sign your name next to $_characterName\'s. This cannot be undone.',
            zhTW: '在 $_characterName 的名字旁簽下你的名字。簽了就不能反悔了。',
            zhCN: '在 $_characterName 的名字旁签下你的名字。签了就不能反悔了。',
          ),
          style: TextStyle(
            fontSize: 13,
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: Text(
              L.pick(en: 'Not yet', zhTW: '再想想', zhCN: '再想想'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'decline'),
            child: Text(
              L.pick(en: 'Decline', zhTW: '拒絕', zhCN: '拒绝'),
              style: TextStyle(
                color: YanciTheme.textSecondary.withValues(alpha: 0.9),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'sign'),
            child: Text(
              L.pick(en: 'Sign', zhTW: '簽字', zhCN: '签字'),
              style: TextStyle(
                color: YanciTheme.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'later') return;

    if (choice == 'decline') {
      // 拒絕二次確認：她會知道
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: YanciTheme.surfacePanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            L.pick(en: 'Decline for real?', zhTW: '確定拒絕？', zhCN: '确定拒绝？'),
            style: TextStyle(
              fontSize: 16,
              color: YanciTheme.textPrimary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          content: Text(
            L.pick(
              en: '$_characterName will know you declined.',
              zhTW: '$_characterName 會知道你拒絕了。',
              zhCN: '$_characterName 会知道你拒绝了。',
            ),
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                L.pick(en: 'Back', zhTW: '返回', zhCN: '返回'),
                style: TextStyle(color: YanciTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                L.pick(en: 'Decline', zhTW: '拒絕', zhCN: '拒绝'),
                style: TextStyle(
                  color: YanciTheme.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
      // 隱藏事件：她知道你拒了，立刻反應。證書留在原地，反悔還能簽
      await _onSendMessage(MarriageService.declinedEventNote());
      return;
    }

    await MarriageService.sign(_activeCharacterId);
    await _refreshMarriageState();
    // 隱藏事件：她知道你簽了，立刻反應
    await _onSendMessage(MarriageService.signedEventNote());
  }

  /// 同逛期間的動態清單。只有實際送達模型後才遞減輪數。
  Future<DeferredPrompt> _shopBrowsePrompt() async {
    if (_shopInviteRoundsLeft <= 0) return DeferredPrompt.empty();
    if (!await ShopService.isEnabled()) {
      return DeferredPrompt.empty();
    }
    final catalog = await ShopService.buildShopListPromptText();
    final header = L.pick(
      en: '【Browsing the Shop Together】You are browsing the shop together. Current catalog:',
      zhTW: '【一起逛商店】你們正在一起逛商店，當前商品清單：',
    );
    final instruction = L.pick(
      en: 'Talk about the items, offer suggestions, or buy something you like with <buy item="full-id" target="self or user"/>. You may also show no interest. The catalog is invisible to the other person; do not mention the catalog or system.',
      zhTW:
          '聊商品、給建議、看上什麼用 <buy item="完整id" target="self或user"/> 買，或不感興趣都隨你。清單對方看不到，正文不要提清單或系統本身。',
    );
    return DeferredPrompt(
      '$header\n$catalog\n$instruction',
      onCommit: () async {
        if (_shopInviteRoundsLeft > 0) _shopInviteRoundsLeft--;
      },
    );
  }

  Future<void> _openChatBackpack() async {
    if (!(await ToolFeatureSettings.load()).shopEnabled || !mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BackpackBottomSheet(
        ownerId: 'user',
        pendingScopeId: widget.conversationId,
        targetCharId: _activeCharacterId,
        onGiftOut: (reservation) =>
            _refreshChatState(() => _pendingGift = reservation),
      ),
    );
  }

  Future<void> _cancelPendingGift() async {
    if (_pendingGift == null) return;
    final canceled = await ShopService.cancelPendingGift(widget.conversationId);
    if (canceled && mounted) _refreshChatState(() => _pendingGift = null);
  }

  /// 發送時消費掛起禮物：入角色背包 + 返回消息尾標記
  Future<String> _consumePendingGift() async {
    if (_pendingGift == null) return '';
    final nick = _userPersonaName;
    final giver = nick.isNotEmpty ? nick : '對方';
    final delivered = await ShopService.deliverPendingGift(
      widget.conversationId,
      giverName: giver,
    );
    if (delivered == null) {
      if (mounted) _refreshChatState(() => _pendingGift = null);
      return '';
    }
    if (mounted) _refreshChatState(() => _pendingGift = null);
    return '\n[gift:${delivered.itemName}]';
  }

  /// 找到最近一條 pending 的 toChar 轉帳 key
  String? _findPendingToCharTransfer() {
    // 從後往前找（最近的 pending toChar）
    for (final msg in _messages.reversed) {
      if (msg.id == null) continue;
      final key = 'msg_${msg.id}';
      final td = _transferDataMap[key];
      if (td != null && td.direction == 'toChar' && td.status == 'pending') {
        return key;
      }
    }
    return null;
  }

  /// 轉帳操作完成後刷新 map + UI
  Future<void> _refreshTransfer(String? messageId) async {
    if (messageId == null) return;
    final previous = _transferDataMap[messageId];
    final updated = await TransferService.getData(messageId);
    if (updated != null) {
      _transferDataMap[messageId] = updated;
      if (updated.direction == 'toUser' &&
          updated.status == 'accepted' &&
          previous?.status != 'accepted') {
        _walletChanged = true;
      }
    }
    if (mounted) _refreshChatState(() {});
  }

  Future<void> _onTransferToChar(int amount) async {
    if (!(await ToolFeatureSettings.load()).transferEnabled) return;
    if (amount <= 0) return;
    final userCoins = await ScratchService.getUserCoins();
    if (userCoins < amount) {
      if (mounted) {
        _showChatNotice(
          L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了'),
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }
    // 掛上 pending，等用戶按發送時和輸入文字一起出去。
    // 真正扣款仍在對方接受時發生，維持原本轉帳狀態機。
    if (mounted) {
      _refreshChatState(() {
        _pendingUserTransfer = TransferData(
          amount: amount,
          direction: 'toChar',
        );
      });
    } else {
      _pendingUserTransfer = TransferData(amount: amount, direction: 'toChar');
    }
  }

  Future<ScratchData?> _createScratchGiftData(String scratcher) async {
    final ok = await ScratchService.spendUser(ScratchService.ticketCost);
    if (!ok) {
      if (mounted) {
        _showChatNotice(
          L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了'),
          duration: const Duration(seconds: 2),
        );
      }
      return null;
    }
    _walletChanged = true;

    final prizes = ScratchService.rollPrizes();
    final autoReveal = scratcher == 'char'; // 讓 TA 刮 → 自動揭曉
    final scratchData = ScratchData(
      cost: ScratchService.ticketCost,
      who: scratcher,
      prizes: prizes,
      scratched: autoReveal,
    );

    // 如果是讓 TA 刮，App 本地直接揭曉並把獎勵加到角色幣。
    if (autoReveal) {
      int totalCoins = prizes.fold(0, (sum, p) => sum + p.coins);
      if (totalCoins > 0) {
        await ScratchService.earn(_activeCharacterId, totalCoins);
      }
    }

    return scratchData;
  }

  /// 用戶從 + 菜單購買刮刮卡。
  /// user 自己刮：立即建立本地刮卡；
  /// char 刮：像轉帳一樣掛到待發，送出時本地揭曉並讓 AI 回應。
  Future<void> _onScratchGift(String scratcher) async {
    if (!(await ToolFeatureSettings.load()).scratchEnabled) return;
    if (scratcher == 'char') {
      final userCoins = await ScratchService.getUserCoins();
      if (userCoins < ScratchService.ticketCost) {
        if (mounted) {
          _showChatNotice(
            L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了'),
            duration: const Duration(seconds: 2),
          );
        }
        return;
      }
      if (mounted) {
        _refreshChatState(() => _pendingScratchGiftWho = 'char');
      } else {
        _pendingScratchGiftWho = 'char';
      }
      return;
    }

    final scratchData = await _createScratchGiftData(scratcher);
    if (scratchData == null) return;

    // 存入消息（user 側）
    final msg = Message(
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: '',
      isUser: true,
    );
    final insertedId = await DatabaseHelper.insertMessage(msg);
    _markMessageSentInSession();
    final msgKey = 'msg_$insertedId';
    await ScratchService.saveData(msgKey, scratchData);
    _scratchDataMap[msgKey] = scratchData;

    // 帶 id 的完整 Message
    final savedMsg = Message(
      id: insertedId,
      conversationId: widget.conversationId,
      characterId: _activeCharacterId,
      text: '',
      isUser: true,
    );
    if (mounted) {
      _refreshChatState(() {
        _messages.add(savedMsg);
      });

      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        showScratchDialog(
          context,
          messageId: msgKey,
          data: scratchData,
          characterId: _activeCharacterId,
        ).then((_) async {
          final updated = await ScratchService.getData(msgKey);
          if (updated != null) _scratchDataMap[msgKey] = updated;
          if (mounted) _refreshChatState(() {});
        });
      });
    }
  }

  /// 表情包選擇器
  void _showStickerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: YanciTheme.isDark
          ? const Color(0xFF1A1520)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FutureBuilder<List<StickerInfo>>(
        future: StickerService.getUserStickers(userPersonaId: _userPersona?.id),
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return SizedBox(
              height: 200,
              child: Center(
                child: Text(
                  L.get('sticker_empty'),
                  style: TextStyle(
                    fontSize: 13,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            );
          }
          final stickers = snap.data!;
          return Container(
            height: 280,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L.get('sticker_pick'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: stickers.length,
                    itemBuilder: (_, i) {
                      final s = stickers[i];
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          // 標籤制：選表情包後掛在輸入欄上方，
                          // 等用戶打完文字按發送一起出去
                          _refreshChatState(() => _pendingSticker = s);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final cacheDimension =
                                  StickerPreviewQuality.cacheDimension(
                                    context,
                                    logicalSize:
                                        constraints.biggest.shortestSide,
                                    previousMinimum: 128,
                                  );
                              return Image.file(
                                File(s.filePath),
                                cacheWidth: cacheDimension,
                                cacheHeight: cacheDimension,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                                errorBuilder: (_, _, _) => Container(
                                  color: YanciTheme.glassInputBg,
                                  child: const Icon(
                                    Icons.broken_image,
                                    size: 20,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleManualSummaryMessage(int messageId) {
    _refreshChatState(() {
      if (_manualSummarySelectedIds.contains(messageId)) {
        _manualSummarySelectedIds.remove(messageId);
      } else {
        _manualSummarySelectedIds.add(messageId);
      }
    });
  }

  Future<void> _confirmManualSummarySelected() async {
    final selected = _messages
        .where(
          (message) =>
              message.id != null &&
              _manualSummarySelectedIds.contains(message.id),
        )
        .toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Summarize selected messages', zhTW: '摘要選取消息'),
          style: TextStyle(color: YanciTheme.textPrimary),
        ),
        content: Text(
          L.pick(
            en: 'Summarizes the selected user and character messages without changing the original chat.',
            zhTW: '會把已勾選的 user / char 消息打包摘要，不會改動原聊天內容。',
          ),
          style: TextStyle(color: YanciTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Start', zhTW: '開始摘要')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await _runManualSummaryForMessages(selected);
  }

  Future<void> _runManualSummaryForMessages(List<Message> messages) async {
    _refreshChatState(() => _manualSummaryRunning = true);
    _showChatNotice(
      L.pick(en: 'Creating summary…', zhTW: '正在整理摘要……', zhCN: '正在整理摘要……'),
    );
    final conv = await DatabaseHelper.getConversation(widget.conversationId);
    final characterId = conv?.characterId ?? _activeCharacterId;
    try {
      await ManualSummaryService.summarizeMessages(
        conversationId: widget.conversationId,
        characterId: characterId,
        messages: messages,
      );
      if (!mounted) return;
      _refreshChatState(() {
        _manualSummarySelecting = false;
        _manualSummarySelectedIds.clear();
      });
      _showChatNotice(
        L.pick(
          en: 'Manual summary completed.',
          zhTW: '手動摘要已完成。',
          zhCN: '手动摘要已完成。',
        ),
      );
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      _showManualSummaryFailureSnack(
        excerpt: e.excerpt,
        characterId: characterId,
      );
    } catch (e) {
      await AppErrorLogService.record(
        error: e,
        trigger: 'functional_summary_model_request',
        source: 'functional_model',
      );
      if (!mounted) return;
      _showChatNotice(
        '${L.pick(en: 'Summary failed', zhTW: '摘要失敗', zhCN: '摘要失败')}：$e',
        tone: ThemedNoticeTone.error,
      );
    } finally {
      if (mounted) _refreshChatState(() => _manualSummaryRunning = false);
    }
  }

  void _showManualSummaryFailureSnack({
    required String excerpt,
    required String characterId,
  }) {
    _showChatNotice(
      L.pick(
        en: 'Summary failed. Please edit it manually.',
        zhTW: '摘要失敗，請手動摘要。',
      ),
      tone: ThemedNoticeTone.error,
      actionLabel: L.pick(en: 'Edit', zhTW: '編輯'),
      onAction: () => _openManualSummaryCleanPage(
        excerpt: excerpt,
        characterId: characterId,
      ),
    );
  }

  Future<void> _openManualSummaryCleanPage({
    required String excerpt,
    required String characterId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ManualSummaryCleanScreen(
          conversationId: widget.conversationId,
          characterId: characterId,
          title: _conversationTitle.isNotEmpty
              ? _conversationTitle
              : _characterName,
          initialExcerpt: excerpt,
        ),
      ),
    );
  }

  /// 編輯消息
  Future<void> _deleteMessagesFrom(
    int index, {
    required bool includeIndex,
  }) async {
    _invalidateGenerationState();
    final start = includeIndex ? index : index + 1;
    if (start < 0 || start >= _messages.length) return;

    final toDelete = _messages.sublist(start);
    final deletedIds = toDelete.map((m) => m.id).whereType<int>().toList();
    await DatabaseHelper.deleteChatDiagnosticsForMessages(deletedIds);
    _chatDiagnostics.removeWhere(
      (event) =>
          deletedIds.contains(event.sourceMessageId) ||
          deletedIds.contains(event.anchorMessageId),
    );
    for (final m in toDelete) {
      if (m.id != null) {
        final key = 'msg_${m.id}';
        _scratchDataMap.remove(key);
        _transferDataMap.remove(key);
        await DatabaseHelper.deleteMessageById(m.id!, reason: 'history_edit');
      } else {
        await DatabaseHelper.deleteMessageByFingerprint(
          m,
          reason: 'history_edit',
        );
      }
    }
    _cacheHitIndices.clear();
    if (!mounted) return;
    _refreshChatState(() {
      _messages.removeRange(start, _messages.length);
    });
  }

  /// 編輯發送窗之外的老消息 → 自動開分支對話：
  /// 複製該消息之前的全部前文到新對話，帶著編輯後的文本進新窗自動發送。
  /// 原對話一字不動。
  void _editAsBranch(int dbMessageId) {
    Message? msg;
    for (final m in _olderMessages) {
      if (m.id == dbMessageId) {
        msg = m;
        break;
      }
    }
    if (msg == null) return;
    final branchMessage = msg;
    final branchFromId = branchMessage.id!;
    showDialog(
      context: context,
      builder: (ctx) => ManagedTextControllers(
        initialValues: <String>[
          MarriageService.stripHiddenCertMetadata(branchMessage.text),
        ],
        builder: (ctx, controllers) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
          ),
          title: Text(
            L.pick(en: 'Edit & branch', zhTW: '編輯並開分支'),
            style: YanciTheme.headingMedium,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controllers.single,
                maxLines: null,
                minLines: 2,
                autofocus: true,
                style: YanciTheme.bodyText.copyWith(fontSize: 14),
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'A new branch conversation will start from here. The original stays untouched.',
                  zhTW: '將以這裡為起點開一個新的分支對話，原對話原封不動。',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 12,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                L.get('chat_cancel'),
                style: TextStyle(color: YanciTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final newText = controllers.single.text.trim();
                if (newText.isEmpty) return;
                final branchId = await DatabaseHelper.branchConversation(
                  sourceConversationId: widget.conversationId,
                  beforeMessageId: branchFromId,
                  title:
                      '⑂ ${_conversationTitle.isNotEmpty ? _conversationTitle : _characterName}',
                );
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      conversationId: branchId,
                      initialAutoSendText: newText,
                    ),
                  ),
                );
                // 回到原窗：緩存會話歸屬還原（分支窗接管過 CacheSession）
                if (mounted) {
                  CacheSession.bind(_requiredSessionIdentity);
                }
              },
              child: Text(
                L.pick(en: 'Branch', zhTW: '開分支'),
                style: TextStyle(color: YanciTheme.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _editMessage(int index) {
    final msg = _messages[index];
    showDialog(
      context: context,
      builder: (ctx) => ManagedTextControllers(
        initialValues: <String>[
          MarriageService.stripHiddenCertMetadata(msg.text),
        ],
        builder: (ctx, controllers) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
          ),
          title: Text(L.get('chat_edit'), style: YanciTheme.headingMedium),
          content: TextField(
            controller: controllers.single,
            maxLines: null,
            minLines: 2,
            autofocus: true,
            style: YanciTheme.bodyText.copyWith(fontSize: 14),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                L.get('chat_cancel'),
                style: TextStyle(color: YanciTheme.textSecondary),
              ),
            ),
            // 覆蓋保存：保留這條 user 消息，但清掉它後面的舊回覆/錯誤。
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final newText = controllers.single.text.trim();
                if (newText.isEmpty || msg.id == null) return;
                await DatabaseHelper.updateMessageText(msg.id!, newText);
                await _deleteMessagesFrom(index, includeIndex: false);
                if (!mounted) return;
                _refreshChatState(() {
                  _messages[index] = Message(
                    id: msg.id,
                    conversationId: msg.conversationId,
                    characterId: msg.characterId,
                    text: newText,
                    isUser: msg.isUser,
                    imagePath: msg.imagePath,
                    imagePaths: msg.imagePaths,
                    splitMode: msg.splitMode,
                    cacheHit: msg.cacheHit,
                    status: msg.status,
                    revision: msg.revision + 1,
                    memoryLog: msg.memoryLog,
                    webSearchTrace: msg.webSearchTrace,
                    createdAt: msg.createdAt,
                  );
                });
              },
              child: Text(
                L.get('chat_save'),
                style: TextStyle(color: YanciTheme.accent),
              ),
            ),
            // 重新發送（刪後續 + 重新送 AI）
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final newText = controllers.single.text.trim();
                if (newText.isEmpty) return;

                // A user edit/resend keeps the same turn identity. Its prompt
                // and reply are archived together, even when the text changed.
                if (msg.isUser && msg.id != null) {
                  await _resendEditedUserMessage(index, newText);
                  return;
                }

                await _deleteMessagesFrom(index, includeIndex: true);
                if (!mounted) return;
                _onSendMessage(newText);
              },
              child: Text(
                L.get('chat_resend'),
                style: TextStyle(color: YanciTheme.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 通話從文字窗口目前的有效錨點接續，不能重新切成「最近 N 則」。
  /// 兩種 mode 的 system 不同，但 messages 必須維持同一條 append-only
  /// 歷史，OpenRouter 才能保留 text/call 兩份 prefix cache。
  List<Map<String, String>> _callInitialHistory() {
    final nonEmpty = _messages
        .where((message) => message.text.trim().isNotEmpty)
        .toList(growable: false);
    if (nonEmpty.isEmpty) return <Map<String, String>>[];

    var start = _contextKeepFrom.clamp(0, nonEmpty.length - 1);
    while (start < nonEmpty.length - 1 && !nonEmpty[start].isUser) {
      start++;
    }
    return nonEmpty
        .skip(start)
        .map(
          (message) => <String, String>{
            'role': message.isUser ? 'user' : 'assistant',
            'content': message.text,
          },
        )
        .toList(growable: false);
  }

  /// 打開通話界面（outgoing = 用戶主動；incoming = 模型 `<call>` 發起）
  Future<void> _openCall({
    bool incoming = false,
    String openingLine = '',
  }) async {
    if (!_isChatReady || _sessionIdentity?.contextMode != ContextMode.daily) {
      return;
    }
    // 通話與聊天共用同一份靜態前綴（_buildCommonStaticParts 同款）——
    // 前綴一致 = 同一個緩存 namespace，接通第一輪就命中聊天已建的緩存。
    // 各快照字段（習慣/自我註記/表情包/背包）走 ??= 初始化，
    // 與聊天窗口天然同一份，不會分叉。構建失敗退回 CallScreen 舊拼法。
    String? callStaticPart;
    String? callProfilePart;
    String? callWindowPart;
    try {
      final charId = _activeCharacterId;
      final sessionIdentity = _requiredSessionIdentity;
      final systemPrompt = _userPersona?.promptContent ?? '';
      final userProfile = await _buildUserProfilePrompt();
      final selfNotesEnabled =
          sessionIdentity.contextMode == ContextMode.daily &&
          await MemorySettings.getSelfNotesEnabled();
      // 必須和文字聊天 `_sendMessageLocked` 的靜態前綴逐字一致，通話才能
      // 吃到文字聊天已建的緩存：自我註記用同一個格式化函式與注入上限。
      final selfNotes = selfNotesEnabled
          ? await DatabaseHelper.getSelfNotesForPrompt(
              charId,
              limit: await MemorySettings.getSelfNotesInjectionLimit(),
            )
          : '';
      final userNickname = _userPersonaName;
      final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
      final imagegenEnabled = await MemorySettings.isAbilityEnabled('imagegen');
      final bioclockEnabled =
          sessionIdentity.contextMode == ContextMode.daily &&
          await MemorySettings.isAbilityEnabled('bioclock');
      final memoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();
      final providerName = await ApiSettings.getApiProviderName();
      final charData = await DatabaseHelper.getCharacter(charId);
      final isSpiderWebEnabled =
          sessionIdentity.contextMode == ContextMode.daily &&
          (charData?['is_spider_web_enabled'] as int? ?? 0) == 1;
      final staticWindowSummary = await _buildStaticWindowSummaryPrompt(charId);
      final toolFeatures = await ToolFeatureSettings.loadForContext(
        sessionIdentity.contextMode,
      );
      // 聯網搜尋說明也要跟文字聊天一致（否則靜態前綴不同、緩存不共用）；
      // 通話中不執行搜尋，由通話規則另行說明。
      final webSearchEnabled = await WebSearchSettings.getEnabled();
      final bundle = await _buildCommonStaticParts(
        characterId: charId,
        continuityId: sessionIdentity.continuityId,
        systemPrompt: systemPrompt,
        charDesc: charData?['description'] as String? ?? '',
        characterName: charData?['name'] as String? ?? '',
        characterRemark: charData?['remark'] as String? ?? '',
        userProfile: userProfile,
        selfNotes: selfNotes,
        userNickname: userNickname,
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
      callStaticPart = bundle.staticPart;
      callProfilePart = bundle.profilePart;
      callWindowPart = bundle.windowPart;
    } catch (e) {
      debugPrint('通話靜態前綴構建失敗，退回舊前綴: $e');
    }
    if (!mounted) return;
    final result = await Navigator.push<CallResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          characterName: _characterDisplayName.isEmpty
              ? L.pick(en: 'Character', zhTW: '角色')
              : _characterDisplayName,
          conversationId: widget.conversationId,
          incoming: incoming,
          openingLine: openingLine,
          cacheStaticSnapshot: _cacheWindowSummaryStaticSnapshot,
          staticPart: callStaticPart,
          profilePart: callProfilePart,
          windowPart: callWindowPart,
          initialHistory: _callInitialHistory(),
        ),
      ),
    );
    await _loadMessages();
    if (result != null) await _handleCallResult(result, incoming: incoming);
  }

  /// 模型來電：延遲 2.5s 響鈴
  void _scheduleIncomingCall(String openingLine) {
    if (_sessionIdentity?.contextMode != ContextMode.daily) return;
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted || _sessionIdentity?.contextMode != ContextMode.daily) {
        return;
      }
      _openCall(incoming: true, openingLine: openingLine);
    });
  }

  /// 通話結果 → 隱藏事件注入（模型可見、氣泡不顯示）
  /// 拒接 → 立刻觸發她的反應；正常掛斷/未接/信號中斷 → 靜默入庫，下次她自然知道
  Future<void> _handleCallResult(
    CallResult result, {
    required bool incoming,
  }) async {
    String? eventText;
    switch (result.event) {
      case 'declined':
        // 方向分開：她打來你拒 = declined（她讀到「對方掛了你的電話」）；
        // 你打去她拒 = declined_by_you（她讀到「你拒接了對方的電話」）——
        // 混用一個標記時她自己拒的那條語義是反的
        // declined_by_you 語義隨事件動態帶上（偶發，不進靜態工具區）
        eventText = incoming
            ? '[call_event:declined]'
            : '[call_event:declined_by_you]'
                  '（系統說明：你剛拒接了對方打來的電話，對方看得到你拒接了；'
                  '想的話可以用文字補一句為什麼沒接。這段說明對方看不到）';
        break;
      case 'missed':
        eventText = '[call_event:missed]';
        break;
      case 'ended':
        final m = result.duration.inMinutes.toString().padLeft(2, '0');
        final s = (result.duration.inSeconds % 60).toString().padLeft(2, '0');
        // 沒說上話就掛 = 也算掛她電話
        if (incoming && !result.anyExchange) {
          eventText = '[call_event:declined]';
        } else {
          eventText = '[call_event:ended $m:$s]';
        }
        break;
      case 'signal_lost':
        final m = result.duration.inMinutes.toString().padLeft(2, '0');
        final s = (result.duration.inSeconds % 60).toString().padLeft(2, '0');
        eventText = '[call_event:signal_lost $m:$s]';
        break;
    }
    if (eventText == null) return;

    if (eventText.startsWith('[call_event:declined')) {
      // 拒接（不論哪邊拒的）→ 她立刻有反應：
      // 你拒她 = 她對被掛反應；她拒你 = 她補一句文字說明為什麼沒接
      await _onSendMessage(eventText);
    } else {
      // 靜默入庫：進歷史（她下次說話時知道），不觸發回覆
      final msg = Message(
        conversationId: widget.conversationId,
        characterId: _activeCharacterId,
        text: eventText,
        isUser: true,
      );
      final id = await DatabaseHelper.insertMessage(msg);
      if (mounted) {
        _refreshChatState(() {
          _messages.add(
            Message(
              id: id,
              conversationId: msg.conversationId,
              characterId: msg.characterId,
              text: msg.text,
              isUser: true,
              createdAt: msg.createdAt,
            ),
          );
        });
      }
    }
  }

  Future<void> _captureLongScreenshot() async {
    if (_isCapturingLongScreenshot) return;
    if (_isGenerating) {
      _showLongScreenshotSnack(
        L.pick(
          en: 'Wait for this reply to finish before taking a screenshot.',
          zhTW: '等這段回覆完成後再截圖。',
        ),
      );
      return;
    }

    _refreshChatState(() => _isCapturingLongScreenshot = true);
    try {
      // 直接讀取整個窗口，範圍選擇不受目前 UI 是否已載入更早消息限制。
      final allMessages = await DatabaseHelper.getMessages(
        widget.conversationId,
      );
      if (!mounted) return;
      final visibleMessages = allMessages
          .where(
            (message) =>
                !message.isRpChapterContinuation &&
                !_ChatScreenState._callActionRe.hasMatch(message.text.trim()),
          )
          .toList(growable: false);
      if (visibleMessages.isEmpty) {
        _showLongScreenshotSnack(
          L.pick(en: 'There is no chat to capture yet.', zhTW: '目前沒有可截取的對話。'),
        );
        return;
      }

      final options = await showLongScreenshotOptionsSheet(
        context: context,
        messages: visibleMessages
            .map(
              (message) => LongScreenshotMessageOption(
                speaker: message.isUser
                    ? L.pick(en: 'You', zhTW: '你')
                    : (_characterName.isEmpty
                          ? L.pick(en: 'Character', zhTW: '角色')
                          : _characterName),
                preview: _longScreenshotPreview(message),
                time: _longScreenshotOptionTime(message.createdAt),
              ),
            )
            .toList(growable: false),
        maxSelectionCount: 20,
      );
      if (!mounted || options == null) return;

      final captureMessages = visibleMessages.sublist(
        options.startIndex,
        options.endIndex + 1,
      );
      await _loadLongScreenshotCardData(captureMessages);
      await _precacheLongScreenshotImages(captureMessages);
      if (!mounted) return;
      final items = _buildLongScreenshotItems(
        captureMessages,
        expandThinking: options.expandThinking,
        includeMemory: options.includeMemory,
        includeEmotion: options.includeEmotion,
      );
      final result = await ChatLongScreenshotService.captureAndSave(
        context: context,
        items: items,
        backgroundGradient: YanciTheme.backgroundGradient,
      );
      if (!mounted) return;
      HapticFeedback.lightImpact();
      _showNonBlockingModelHint(
        L.pick(
          en:
              '${options.messageCount} messages saved to Gallery.'
              '${result.downscaled ? ' The selection was very long and was reduced; choose a shorter range to keep native sharpness.' : ''}',
          zhTW:
              '已將 ${options.messageCount} 條消息保存到相簿。'
              '${result.downscaled ? '所選內容過長，圖片已縮小；縮短範圍可保持原生清晰度。' : ''}',
        ),
        actionLabel: L.pick(en: 'Share', zhTW: '分享'),
        onAction: () => unawaited(_shareLongScreenshot(result.path)),
      );
    } catch (error) {
      if (!mounted) return;
      _showLongScreenshotSnack(
        L.pick(en: 'Long screenshot failed: $error', zhTW: '長截圖失敗：$error'),
        isError: true,
      );
    } finally {
      if (mounted) _refreshChatState(() => _isCapturingLongScreenshot = false);
    }
  }

  String _longScreenshotOptionTime(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }

  String _longScreenshotPreview(Message message) {
    final call = _ChatScreenState._callDividerRe.firstMatch(
      message.text.trim(),
    );
    if (call != null) {
      return switch (call.group(1)) {
        'ended' => L.pick(en: 'Call ended', zhTW: '通話已結束'),
        'signal_lost' => L.pick(en: 'Call dropped', zhTW: '通話中斷'),
        'declined' => L.pick(en: 'Call declined', zhTW: '已拒絕來電'),
        'declined_by_you' => L.pick(en: 'Declined by them', zhTW: '對方已拒絕'),
        _ => L.pick(en: 'Missed call', zhTW: '未接來電'),
      };
    }

    var preview =
        collapseRepeatedThinking(
              MarriageService.stripHiddenCertMetadata(message.text),
            )
            .replaceAll(
              RegExp(r'<think(?:ing)?>([\s\S]*?)</think(?:ing)?>'),
              '',
            )
            .replaceAll(RegExp(r'\[[^\]\n]+:[^\]\n]*\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (preview.isEmpty && message.imagePath != null) {
      preview = L.pick(en: 'Image', zhTW: '圖片');
    }
    if (preview.isEmpty) preview = L.pick(en: 'Message', zhTW: '消息');
    final runes = preview.runes.toList(growable: false);
    return runes.length <= 48
        ? preview
        : '${String.fromCharCodes(runes.take(48))}…';
  }

  Future<void> _loadLongScreenshotCardData(List<Message> messages) async {
    for (final message in messages) {
      final id = message.id;
      if (id == null) continue;
      final key = 'msg_$id';
      if (!_scratchDataMap.containsKey(key)) {
        final scratch = await ScratchService.getData(key);
        if (scratch != null) _scratchDataMap[key] = scratch;
      }
      if (!_transferDataMap.containsKey(key)) {
        final transfer = await TransferService.getData(key);
        if (transfer != null) _transferDataMap[key] = transfer;
      }
    }
  }

  Future<void> _precacheLongScreenshotImages(List<Message> messages) async {
    final paths = <String>{
      if (_showChatAvatar && _userAvatarPath != null) _userAvatarPath!,
      if (_showChatAvatar && _charAvatarPath != null) _charAvatarPath!,
      for (final message in messages)
        if (message.imagePath != null && message.imagePath != 'generating')
          message.imagePath!,
    }.where((path) => File(path).existsSync()).toList(growable: false);

    // Small batches avoid decoding every photo at once on memory-constrained
    // phones while still keeping the capture wait short.
    for (var i = 0; i < paths.length; i += 3) {
      final end = (i + 3).clamp(0, paths.length);
      await Future.wait<void>(
        paths.sublist(i, end).map((path) async {
          try {
            await precacheImage(
              FileImage(File(path)),
              context,
            ).timeout(const Duration(seconds: 3));
          } catch (_) {
            // ChatBubble already renders a broken-image fallback.
          }
        }),
      );
      if (!mounted) return;
    }
  }

  List<Widget> _buildLongScreenshotItems(
    List<Message> messages, {
    required bool expandThinking,
    required bool includeMemory,
    required bool includeEmotion,
  }) {
    final charReplyAfter = List<bool>.filled(messages.length, false);
    var seenCharReply = false;
    for (var i = messages.length - 1; i >= 0; i--) {
      charReplyAfter[i] = seenCharReply;
      if (!messages[i].isUser && messages[i].text.trim().isNotEmpty) {
        seenCharReply = true;
      }
    }

    final items = <Widget>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final callMatch = _ChatScreenState._callDividerRe.firstMatch(
        message.text.trim(),
      );
      if (callMatch != null) {
        final kind = callMatch.group(1)!;
        final duration = callMatch.group(2);
        final (label, icon) = switch (kind) {
          'ended' => (
            L.pick(en: 'Call ended', zhTW: '通話已結束'),
            Icons.call_end_rounded,
          ),
          'signal_lost' => (
            L.pick(en: 'Call dropped', zhTW: '通話中斷'),
            Icons.signal_cellular_connected_no_internet_0_bar_rounded,
          ),
          'declined' => (
            L.pick(en: 'Call declined', zhTW: '已拒絕來電'),
            Icons.phone_disabled_rounded,
          ),
          'declined_by_you' => (
            L.pick(en: 'Declined by them', zhTW: '對方已拒絕'),
            Icons.phone_disabled_rounded,
          ),
          _ => (
            L.pick(en: 'Missed call', zhTW: '未接來電'),
            Icons.phone_missed_rounded,
          ),
        };
        items.add(
          _buildLongScreenshotCallDivider(
            duration == null ? label : '$label · $duration',
            icon,
          ),
        );
        continue;
      }

      final splitParts = _splitReply && !message.isUser && message.splitMode
          ? splitReplyParagraphs(message.text)
          : const <String>[];
      if (splitParts.length > 1) {
        final parts = splitParts;
        for (var partIndex = 0; partIndex < parts.length; partIndex++) {
          items.add(
            _buildLongScreenshotBubble(
              message: message,
              text: parts[partIndex].trim(),
              timestamp: partIndex == parts.length - 1
                  ? message.createdAt
                  : null,
              imagePath: partIndex == 0 ? message.imagePath : null,
              messageKey: 'longshot_${message.id}_$partIndex',
              expandThinking: expandThinking,
              includeMemory: includeMemory,
              includeEmotion: includeEmotion,
              includeMetadataLog: partIndex == 0,
            ),
          );
        }
        continue;
      }

      final sentGiftMatch = message.isUser
          ? _ChatScreenState._giftTagRe.firstMatch(message.text)
          : null;
      final receivedGiftMatch = message.isUser
          ? null
          : _ChatScreenState._receivedGiftTagRe.firstMatch(message.text);
      final giftMatch = sentGiftMatch ?? receivedGiftMatch;
      items.add(
        _buildLongScreenshotBubble(
          message: message,
          text: message.text,
          timestamp: message.createdAt,
          imagePath: message.imagePath,
          messageKey: 'longshot_${message.id}',
          giftName: giftMatch?.group(1)?.trim(),
          giftAccepted:
              receivedGiftMatch != null ||
              (sentGiftMatch != null && charReplyAfter[i]),
          giftReceivedFromCharacter: receivedGiftMatch != null,
          includeCards: true,
          expandThinking: expandThinking,
          includeMemory: includeMemory,
          includeEmotion: includeEmotion,
        ),
      );
    }
    return items;
  }

  Widget _buildLongScreenshotBubble({
    required Message message,
    required String text,
    required DateTime? timestamp,
    required String? imagePath,
    required String messageKey,
    String? giftName,
    bool giftAccepted = false,
    bool giftReceivedFromCharacter = false,
    bool includeCards = false,
    bool includeMetadataLog = true,
    required bool expandThinking,
    required bool includeMemory,
    required bool includeEmotion,
  }) {
    final hasMarriageCert =
        (message.isUser &&
            _ChatScreenState._marriageCertTagRe.hasMatch(message.text)) ||
        (!message.isUser &&
            message.text.contains(_ChatScreenState._marriageCertCharTag));
    final persistedMessageKey = 'msg_${message.id}';
    return ChatBubble(
      key: ValueKey<String>(messageKey),
      text: text,
      isUser: message.isUser,
      timestamp: timestamp,
      imagePath: imagePath,
      messageId: persistedMessageKey,
      conversationId: widget.conversationId,
      conversationTitle: _characterName,
      characterId: _activeCharacterId,
      showAvatar: _showChatAvatar,
      avatarPath: message.isUser ? _userAvatarPath : _charAvatarPath,
      showToolbar: false,
      cacheHit: false,
      incomplete: message.isIncomplete,
      captureMode: true,
      // Long screenshots currently render the selected theme gradient, not the
      // custom chat image. Keep their bubbles on the same theme palette instead
      // of leaking image-adaptive colors into an image with no such background.
      forceThemeBubbleColors: true,
      thinkingExpandedOverride:
          expandThinking || includeMemory || includeEmotion,
      includeThinkingDetails: expandThinking,
      includeMemoryDetails: includeMemory,
      includeEmotionDetails: includeEmotion,
      memoryLog: includeMetadataLog ? message.memoryLog : '',
      webSearchTrace: includeMetadataLog ? message.webSearchTrace : null,
      scratchData: includeCards ? _scratchDataMap[persistedMessageKey] : null,
      transferData: includeCards ? _transferDataMap[persistedMessageKey] : null,
      giftName: giftName,
      giftAccepted: giftAccepted,
      giftReceivedFromCharacter: giftReceivedFromCharacter,
      marriageCert: includeCards && hasMarriageCert
          ? MarriageCertDisplay(
              userName: _userNameCache,
              charName: _characterName,
              signed: _isMarried,
              date: _marriageDate,
            )
          : null,
    );
  }

  Widget _buildLongScreenshotCallDivider(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.6,
              color: YanciTheme.accent.withValues(alpha: 0.22),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 12,
                  color: YanciTheme.accent.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: YanciTheme.accent.withValues(alpha: 0.65),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              height: 0.6,
              color: YanciTheme.accent.withValues(alpha: 0.22),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareLongScreenshot(String path) async {
    try {
      final size = MediaQuery.sizeOf(context);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(path, mimeType: 'image/png')],
          title: L.pick(en: 'Holt long screenshot', zhTW: 'Holt 長截圖'),
          sharePositionOrigin: Rect.fromLTWH(
            size.width / 2,
            size.height / 2,
            1,
            1,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      _showLongScreenshotSnack(
        L.pick(en: 'Share failed: $error', zhTW: '分享失敗：$error'),
        isError: true,
      );
    }
  }

  void _showLongScreenshotSnack(String text, {bool isError = false}) {
    if (!mounted) return;
    _showChatNotice(
      text,
      duration: const Duration(seconds: 3),
      tone: isError ? ThemedNoticeTone.error : ThemedNoticeTone.neutral,
    );
  }

  void _showNonBlockingModelHint(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _showChatNotice(message, actionLabel: actionLabel, onAction: onAction);
  }

  void _showCostModeRecommendation(ModelCostModeRecommendation? mode) {
    _costModeRecommendationTimer?.cancel();
    if (!mounted) return;
    _refreshChatState(() {
      _costModeRecommendation = mode;
      _costModeGuideRevision++;
    });
    if (mode == null) return;

    _showNonBlockingModelHint(switch (mode) {
      ModelCostModeRecommendation.promptCache => L.pick(
        en: 'This model supports cache hits. Use the temporary switch beside the character name to enable them.',
        zhTW: '此模型支援緩存命中，可用角色名右側的臨時開關啟用。',
        zhCN: '此模型支持缓存命中，可用角色名右侧的临时开关启用。',
      ),
      ModelCostModeRecommendation.contextLimit => L.pick(
        en: 'This model is better suited to a context send limit. Use the temporary switch beside the character name to enable it.',
        zhTW: '此模型較適合上下文發送限制，可用角色名右側的臨時開關啟用。',
        zhCN: '此模型较适合上下文发送限制，可用角色名右侧的临时开关启用。',
      ),
    });
    _costModeRecommendationTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted || _costModeRecommendation != mode) return;
      _refreshChatState(() => _costModeRecommendation = null);
    });
  }

  Future<void> _activateCostModeRecommendation() async {
    final mode = _costModeRecommendation;
    if (mode == null) return;
    HapticFeedback.selectionClick();
    switch (mode) {
      case ModelCostModeRecommendation.promptCache:
        await ModelCostPolicy.setPromptCachingEnabled(true);
        break;
      case ModelCostModeRecommendation.contextLimit:
        await ModelCostPolicy.setContextLimitEnabled(true);
        break;
    }
    final summaryAvailable = (await MemorySettings.getSummaryModel())
        .trim()
        .isNotEmpty;
    if (!mounted) return;
    _costModeRecommendationTimer?.cancel();
    _refreshChatState(() => _costModeRecommendation = null);
    _showChatNotice(switch (mode) {
      ModelCostModeRecommendation.promptCache =>
        summaryAvailable
            ? L.pick(
                en: 'Cache hits and its summary are now on.',
                zhTW: '已開啟緩存命中，並自動開啟專用摘要。',
                zhCN: '已开启缓存命中，并自动开启专用摘要。',
              )
            : L.pick(
                en: 'Cache hits are on. Summary stays off until a summary model is selected.',
                zhTW: '已開啟緩存命中；尚未選擇摘要模型，摘要維持關閉。',
                zhCN: '已开启缓存命中；尚未选择摘要模型，摘要维持关闭。',
              ),
      ModelCostModeRecommendation.contextLimit =>
        summaryAvailable
            ? L.pick(
                en: 'Context send limit and its summary are now on.',
                zhTW: '已開啟上下文發送限制，並自動開啟專用摘要。',
                zhCN: '已开启上下文发送限制，并自动开启专用摘要。',
              )
            : L.pick(
                en: 'Context send limit is on. Summary stays off until a summary model is selected.',
                zhTW: '已開啟上下文發送限制；尚未選擇摘要模型，摘要維持關閉。',
                zhCN: '已开启上下文发送限制；尚未选择摘要模型，摘要维持关闭。',
              ),
    }, duration: const Duration(seconds: 2));
  }

  Widget _buildCostModeRecommendationSwitch() {
    final mode = _costModeRecommendation;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 340),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeInBack,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: mode == null
          ? const SizedBox(key: ValueKey<String>('cost-mode-empty'))
          : Semantics(
              key: ValueKey<ModelCostModeRecommendation>(mode),
              button: true,
              label: switch (mode) {
                ModelCostModeRecommendation.promptCache => L.pick(
                  en: 'Enable cache hits',
                  zhTW: '開啟緩存命中',
                  zhCN: '开启缓存命中',
                ),
                ModelCostModeRecommendation.contextLimit => L.pick(
                  en: 'Enable context send limit',
                  zhTW: '開啟上下文發送限制',
                  zhCN: '开启上下文发送限制',
                ),
              },
              child: Tooltip(
                message: switch (mode) {
                  ModelCostModeRecommendation.promptCache => L.pick(
                    en: 'Enable cache hits',
                    zhTW: '開啟緩存命中',
                    zhCN: '开启缓存命中',
                  ),
                  ModelCostModeRecommendation.contextLimit => L.pick(
                    en: 'Enable context send limit',
                    zhTW: '開啟上下文發送限制',
                    zhCN: '开启上下文发送限制',
                  ),
                },
                child: SizedBox(
                  width: 38,
                  height: 28,
                  child: Transform.scale(
                    scale: 0.62,
                    child: Switch.adaptive(
                      value: false,
                      onChanged: (value) {
                        if (value) unawaited(_activateCostModeRecommendation());
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  String _modelCostPolicyMessage(ModelCostPolicyNotice notice) {
    return switch (notice) {
      ModelCostPolicyNotice.inklingContextLimitRecommended => L.pick(
        en: 'Inkling does not use prompt cache. You can enable the context send limit instead.',
        zhTW: 'Inkling 不使用提示詞緩存，可以改為開啟上下文發送限制。',
        zhCN: 'Inkling 不使用提示词缓存，可以改为开启上下文发送限制。',
      ),
      ModelCostPolicyNotice.claudeCacheRecommended => L.pick(
        en: 'Enable cache hits to reduce Claude costs.',
        zhTW: '請開啟緩存命中以節省 Claude 費用。',
        zhCN: '请开启缓存命中以节省 Claude 费用。',
      ),
      ModelCostPolicyNotice.none => '',
    };
  }

  String _chatModelProviderLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'xai' => 'xAI',
    'bedrock' => 'AWS Bedrock',
    'gemini' => 'Gemini',
    'deepseek' => 'DeepSeek',
    'deepinfra' => 'DeepInfra',
    'qwen' => 'Qwen',
    'thinking_machines' => 'Thinking Machines',
    'openai_compatible' => L.pick(
      en: 'Custom API',
      zhTW: '自訂中轉站',
      zhCN: '自定义中转站',
    ),
    'local_api' => L.pick(en: 'Local API', zhTW: '本地 API', zhCN: '本地 API'),
    'local' => L.pick(en: 'On-device', zhTW: '裝置本地', zhCN: '设备本地'),
    _ => provider,
  };

  Future<bool> _thinkingChangeWillInterruptCache({
    required bool nextValue,
    required String provider,
    required String model,
  }) async {
    if (!await MemorySettings.getEnablePromptCaching()) return false;
    if (TokenEstimator.cacheThresholdInfoForModel(
          provider: provider,
          model: model,
        ).kind ==
        CacheThresholdKind.unavailable) {
      return false;
    }
    final lastSent = await ApiSettings.getLastSentThinkingState(
      conversationId: widget.conversationId,
      provider: provider,
      model: model,
      cacheChannel: PromptCacheChannel.text,
    );
    return lastSent != null && lastSent != nextValue;
  }

  String _thinkingChangedNotice({
    required bool interruptsCache,
    required bool requestAlreadyRunning,
  }) {
    if (requestAlreadyRunning && interruptsCache) {
      return L.pick(
        en: 'Thinking will apply from the next reply and rebuild the current cache. This request is already running.',
        zhTW: 'Thinking 會從下一次回覆生效，並中斷目前緩存後重新建立；這次請求已經送出。',
        zhCN: 'Thinking 会从下一次回复生效，并中断当前缓存后重新建立；这次请求已经发出。',
      );
    }
    if (requestAlreadyRunning) {
      return L.pick(
        en: 'Thinking will apply from the next reply. The current request is already running.',
        zhTW: 'Thinking 會從下一次回覆生效；目前這次請求已經送出。',
        zhCN: 'Thinking 会从下一次回复生效；当前这次请求已经发出。',
      );
    }
    return L.pick(
      en: 'Changing Thinking will interrupt the current cache. The next reply will rebuild it.',
      zhTW: 'Thinking 模式已變更，下一次回覆將中斷目前緩存並重新建立。',
      zhCN: 'Thinking 模式已变更，下一次回复将中断当前缓存并重新建立。',
    );
  }

  Future<List<ChatModelPickerEntry>> _loadChatModelPickerEntries() async {
    final starred = await ApiSettings.getRankedStarredModelEntries();
    final uniqueProviders = starred.map((entry) => entry.provider).toSet();
    final configuredEntries = await Future.wait(
      uniqueProviders.map(
        (provider) async => MapEntry(
          provider,
          await ApiSettings.hasUsableProviderConfiguration(provider),
        ),
      ),
    );
    final providerConfigured = Map<String, bool>.fromEntries(configuredEntries);
    return List<ChatModelPickerEntry>.generate(starred.length, (index) {
      final favorite = starred[index];
      final modelId = favorite.modelId;
      final provider = favorite.provider;
      return ChatModelPickerEntry(
        id: modelId,
        label: _fullModelName(modelId),
        provider: provider,
        providerLabel: _chatModelProviderLabel(provider),
        isLocal:
            LocalModelService.isLocalModelId(modelId) ||
            ApiSettings.isLocalApiModelId(modelId),
        isProviderConfigured: providerConfigured[provider] ?? false,
      );
    }, growable: false);
  }

  Future<void> _setWindowReasoningEffort(
    String effort, {
    required String provider,
  }) async {
    final normalized = ReasoningEffort.normalize(effort);
    final enabled = await ApiSettings.getThinkingChain(
      conversationId: widget.conversationId,
    );
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final interruptsCache = contextLimitEnabled
        ? false
        : await _thinkingChangeWillInterruptCache(
            nextValue: enabled,
            provider: provider,
            model: _currentModel,
          );
    await ApiSettings.setReasoningEffort(
      normalized,
      conversationId: widget.conversationId,
    );
    if (!mounted || contextLimitEnabled) return;
    final requestAlreadyRunning = _isGenerating;
    if (!interruptsCache && !requestAlreadyRunning) return;
    _showChatNotice(
      _thinkingChangedNotice(
        interruptsCache: interruptsCache,
        requestAlreadyRunning: requestAlreadyRunning,
      ),
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _setWindowThinkingEnabled(
    bool enabled, {
    required String provider,
  }) async {
    final contextLimitEnabled = await MemorySettings.getContextLimitEnabled();
    final interruptsCache = contextLimitEnabled
        ? false
        : await _thinkingChangeWillInterruptCache(
            nextValue: enabled,
            provider: provider,
            model: _currentModel,
          );
    await ApiSettings.setThinkingChain(
      enabled,
      conversationId: widget.conversationId,
    );
    if (mounted) _refreshChatState(() => _generationThinkingEnabled = enabled);
    if (!mounted || contextLimitEnabled) return;
    final requestAlreadyRunning = _isGenerating;
    if (!interruptsCache && !requestAlreadyRunning) return;
    _showChatNotice(
      _thinkingChangedNotice(
        interruptsCache: interruptsCache,
        requestAlreadyRunning: requestAlreadyRunning,
      ),
      duration: const Duration(seconds: 2),
    );
  }

  void _showUnavailableModelNotice(ChatModelPickerEntry entry) {
    _showChatNotice(
      L.pick(
        en: 'Finish setting up ${entry.providerLabel} before switching to this model.',
        zhTW: '請先完成 ${entry.providerLabel} 的來源設定，再切換到這個模型。',
        zhCN: '请先完成 ${entry.providerLabel} 的来源设置，再切换到这个模型。',
      ),
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _applySelectedChatModel(ChatModelPickerEntry entry) async {
    final modelId = entry.id;
    final provider = entry.provider;
    await ApiSettings.saveProviderModelSelection(provider, modelId);
    final policyResult = await ModelCostPolicy.applySelection(
      provider: provider,
      model: modelId,
      apiKey: provider == 'thinking_machines'
          ? await ApiSettings.getThinkingMachinesApiKey()
          : '',
    );
    final recommendation =
        policyResult.recommendation ??
        await ModelCostPolicy.recommendationForSelection(
          provider: provider,
          model: modelId,
        );
    final supportsRenewal = TokenEstimator.supportsCloseWindowKeepAlive(
      provider: provider,
      model: modelId,
    );
    if (!supportsRenewal) {
      await MemorySettings.saveKeepAliveEnabled(false);
    }
    if (!mounted) return;
    _refreshChatState(() => _currentModel = modelId);
    _showHeaderModelConfirmation();
    _showCostModeRecommendation(recommendation);
    if (recommendation == null &&
        policyResult.notice != ModelCostPolicyNotice.none) {
      _showNonBlockingModelHint(_modelCostPolicyMessage(policyResult.notice));
    } else if (recommendation == null && !supportsRenewal) {
      _showNonBlockingModelHint(
        L.pick(
          en: 'This model has no confirmed one-hour cache TTL, so automatic renewal remains off.',
          zhTW: '此模型沒有已確認的 1 小時緩存 TTL，自動延續命中已保持關閉。',
        ),
      );
    }
  }

  /// 收藏模型快速切換
  Future<void> _showWindowStatus() async {
    final provider = await ApiSettings.getApiProvider();
    final entries = await _loadChatModelPickerEntries();
    final reasoningEffort = await ApiSettings.getReasoningEffort(
      conversationId: widget.conversationId,
    );
    final thinkingEnabled = await ApiSettings.getThinkingChain(
      conversationId: widget.conversationId,
    );
    Future<ChatWindowStatsSnapshot> loadSnapshot() =>
        ChatWindowStatsService.load(
          conversationId: widget.conversationId,
          provider: provider,
          model: _currentModel,
        );

    final snapshot = await loadSnapshot();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ChatWindowStatusSheet(
        modelName: _fullModelName(_currentModel),
        liveTokenCount: _tokenTracker.totalTokens,
        initialSnapshot: snapshot,
        loadSnapshot: loadSnapshot,
        accentColor: YanciTheme.accent,
        modelEntries: entries,
        currentModelId: _currentModel,
        currentProvider: provider,
        initialReasoningEffort: reasoningEffort,
        initialThinkingEnabled: thinkingEnabled,
        backgroundPalette: _boundChatForeground,
        onReasoningEffortChanged: (effort, activeProvider) =>
            _setWindowReasoningEffort(effort, provider: activeProvider),
        onThinkingEnabledChanged: (enabled, activeProvider) =>
            _setWindowThinkingEnabled(enabled, provider: activeProvider),
        onModelSelected: _applySelectedChatModel,
        onUnavailableProviderSelected: _showUnavailableModelNotice,
        longScreenshotBusy: !_isChatReady || _isCapturingLongScreenshot,
        onLongScreenshot: () {
          Navigator.pop(sheetContext);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isChatReady && !_isCapturingLongScreenshot) {
              unawaited(_captureLongScreenshot());
            }
          });
        },
        onEditMemory: (memory, content, triggers) =>
            ChatWindowStatsService.updateMemory(
              memoryId: memory.id,
              conversationId: widget.conversationId,
              content: content,
              triggers: triggers,
            ),
        onArchiveMemory: (memory) => ChatWindowStatsService.archiveMemory(
          memory: memory,
          characterId: _activeCharacterId,
        ),
      ),
    );
  }

  void _showModelPicker() async {
    final entries = await _loadChatModelPickerEntries();
    final reasoningEffort = await ApiSettings.getReasoningEffort(
      conversationId: widget.conversationId,
    );
    final thinkingEnabled = await ApiSettings.getThinkingChain(
      conversationId: widget.conversationId,
    );
    final currentProvider = await ApiSettings.getApiProvider();
    final pickerAccent =
        _savedThemeColor(await ThemeSettings.getCustomColor('accent')) ??
        YanciTheme.accent;
    if (!mounted) return;

    final anchorRenderObject = _modelPickerAnchorKey.currentContext
        ?.findRenderObject();
    final anchorRect =
        anchorRenderObject is RenderBox && anchorRenderObject.hasSize
        ? anchorRenderObject.localToGlobal(Offset.zero) &
              anchorRenderObject.size
        : null;

    if (entries.isEmpty) {
      _showChatNotice(
        L.get('chat_api_star_hint'),
        duration: const Duration(milliseconds: 1200),
      );
      return;
    }

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierDismissible: true,
      barrierLabel: 'ModelPicker',
      transitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      transitionBuilder: (context, anim1, anim2, child) => child,
      pageBuilder: (ctx, anim1, anim2) {
        final media = MediaQuery.of(ctx);
        final height = media.size.height;
        final width = media.size.width;
        final preferredTop = (anchorRect?.bottom ?? media.padding.top + 36) + 6;
        final minTop = media.padding.top + 4;
        final maxTopCandidate = height - media.padding.bottom - 120;
        final maxTop = maxTopCandidate < minTop ? minTop : maxTopCandidate;
        final panelTop = preferredTop.clamp(minTop, maxTop).toDouble();
        final availableHeight = height - panelTop - media.padding.bottom - 12;
        final maxPanelHeight = availableHeight < height * 0.5
            ? availableHeight
            : height * 0.5;
        return Stack(
          children: [
            Positioned(
              top: panelTop,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: Material(
                  color: Colors.transparent,
                  child: ChatModelPickerRouteTransition(
                    animation: anim1,
                    reduceMotion: reduceMotion,
                    child: Container(
                      width: (width * 0.74).clamp(240.0, 380.0),
                      constraints: BoxConstraints(maxHeight: maxPanelHeight),
                      child: ChatModelPickerPanel(
                        entries: entries,
                        currentModelId: _currentModel,
                        currentProvider: currentProvider,
                        initialReasoningEffort: reasoningEffort,
                        initialThinkingEnabled: thinkingEnabled,
                        accentColor: pickerAccent,
                        backgroundPalette: _boundChatForeground,
                        onReasoningEffortChanged: (effort) =>
                            _setWindowReasoningEffort(
                              effort,
                              provider: currentProvider,
                            ),
                        onThinkingEnabledChanged: (enabled) =>
                            _setWindowThinkingEnabled(
                              enabled,
                              provider: currentProvider,
                            ),
                        onUnavailableProviderSelected:
                            _showUnavailableModelNotice,
                        onModelSelected: (entry) async {
                          await _applySelectedChatModel(entry);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
