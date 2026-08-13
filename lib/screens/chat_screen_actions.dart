part of 'chat_screen.dart';

extension _ChatActionMethods on _ChatScreenState {
  Future<void> _refreshMarriageState() async {
    final unlocked = await MarriageService.isUnlocked(_activeCharacterId);
    final married = await MarriageService.isMarried(_activeCharacterId);
    final date = married
        ? await MarriageService.marriageDate(_activeCharacterId)
        : null;
    if (_userNameCache.isEmpty) {
      final nick = await UserSettings.getUserName();
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

  void _openChatBackpack() {
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
    final nick = await UserSettings.getUserName();
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
    if (amount <= 0) return;
    final userCoins = await ScratchService.getUserCoins();
    if (userCoins < amount) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
            backgroundColor: YanciTheme.accent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
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
    if (scratcher == 'char') {
      final userCoins = await ScratchService.getUserCoins();
      if (userCoins < ScratchService.ticketCost) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L.pick(en: 'Not enough coins', zhTW: '貝殼不夠了')),
              backgroundColor: YanciTheme.accent,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
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
    _sentMessageInThisSession = true;
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
        future: StickerService.getUserStickers(),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'Manual summary completed.', zhTW: '手動摘要已完成。'),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: YanciTheme.accent,
        ),
      );
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      _showManualSummaryFailureSnack(
        excerpt: e.excerpt,
        characterId: characterId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${L.pick(en: 'Summary failed', zhTW: '摘要失敗')}：$e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: YanciTheme.accent,
        ),
      );
    } finally {
      if (mounted) _refreshChatState(() => _manualSummaryRunning = false);
    }
  }

  void _showManualSummaryFailureSnack({
    required String excerpt,
    required String characterId,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Summary failed. Please edit it manually.',
            zhTW: '摘要失敗，請手動摘要。',
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
        action: SnackBarAction(
          label: L.pick(en: 'Edit', zhTW: '編輯'),
          textColor: Colors.white,
          onPressed: () => _openManualSummaryCleanPage(
            excerpt: excerpt,
            characterId: characterId,
          ),
        ),
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
    for (final m in toDelete) {
      if (m.id != null) {
        final key = 'msg_${m.id}';
        _scratchDataMap.remove(key);
        _transferDataMap.remove(key);
        await DatabaseHelper.deleteMessageById(m.id!);
      } else {
        await DatabaseHelper.deleteMessageByFingerprint(m);
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
    final branchFromId = msg.id!;
    final ctrl = TextEditingController(
      text: MarriageService.stripHiddenCertMetadata(msg.text),
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
              controller: ctrl,
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
              final newText = ctrl.text.trim();
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
                CacheSession.conversationId = widget.conversationId;
              }
            },
            child: Text(
              L.pick(en: 'Branch', zhTW: '開分支'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _editMessage(int index) {
    final msg = _messages[index];
    final ctrl = TextEditingController(
      text: MarriageService.stripHiddenCertMetadata(msg.text),
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(L.get('chat_edit'), style: YanciTheme.headingMedium),
        content: TextField(
          controller: ctrl,
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
              final newText = ctrl.text.trim();
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
                  splitMode: msg.splitMode,
                  cacheHit: msg.cacheHit,
                  status: msg.status,
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
              final newText = ctrl.text.trim();
              if (newText.isEmpty) return;

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
    if (!_isChatReady) return;
    // 通話與聊天共用同一份靜態前綴（_buildCommonStaticParts 同款）——
    // 前綴一致 = 同一個緩存 namespace，接通第一輪就命中聊天已建的緩存。
    // 各快照字段（習慣/自我註記/表情包/背包）走 ??= 初始化，
    // 與聊天窗口天然同一份，不會分叉。構建失敗退回 CallScreen 舊拼法。
    String? callStaticPart;
    String? callProfilePart;
    String? callWindowPart;
    try {
      final charId = _activeCharacterId;
      final systemPrompt = await ApiSettings.getSystemPrompt();
      final userProfile = await _buildUserProfilePrompt();
      final selfNotes = await DatabaseHelper.getSelfNotes(charId);
      final userNickname = await UserSettings.getUserName();
      final emotionEnabled = await MemorySettings.isAbilityEnabled('emotion');
      final imagegenEnabled = await MemorySettings.isAbilityEnabled('imagegen');
      final bioclockEnabled = await MemorySettings.isAbilityEnabled('bioclock');
      final memoryWriteEnabled = await MemorySettings.getMemoryWriteEnabled();
      final providerName = await ApiSettings.getApiProviderName();
      final charData = await DatabaseHelper.getCharacter(charId);
      final isSpiderWebEnabled =
          (charData?['is_spider_web_enabled'] as int? ?? 0) == 1;
      final staticWindowSummary = await _buildStaticWindowSummaryPrompt(charId);
      final bundle = await _buildCommonStaticParts(
        characterId: charId,
        systemPrompt: systemPrompt,
        charDesc: charData?['description'] as String? ?? '',
        characterName: charData?['name'] as String? ?? '',
        userProfile: userProfile,
        selfNotes: selfNotes,
        userNickname: userNickname,
        isSpiderWebEnabled: isSpiderWebEnabled,
        memoryWriteEnabled: memoryWriteEnabled,
        emotionEnabled: emotionEnabled,
        bioclockEnabled: bioclockEnabled,
        imagegenEnabled: imagegenEnabled,
        webSearchEnabled: false,
        whisperModelOverrideEnabled:
            (charData?['whisper_model_override'] as int? ?? 1) == 1,
        providerName: providerName,
        staticWindowSummary: staticWindowSummary,
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
          characterName: _characterName.isEmpty
              ? L.pick(en: 'Character', zhTW: '角色')
              : _characterName,
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
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
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
      if (allMessages.isEmpty) {
        _showLongScreenshotSnack(
          L.pick(en: 'There is no chat to capture yet.', zhTW: '目前沒有可截取的對話。'),
        );
        return;
      }

      final options = await showLongScreenshotOptionsSheet(
        context: context,
        messages: allMessages
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
        maxSelectionCount: 50,
      );
      if (!mounted || options == null) return;

      final captureMessages = allMessages.sublist(
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
        backgroundColor: YanciTheme.backgroundGradient.first,
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

    var preview = MarriageService.stripHiddenCertMetadata(message.text)
        .replaceAll(RegExp(r'<think(?:ing)?>([\s\S]*?)</think(?:ing)?>'), '')
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

      if (_splitReply &&
          !message.isUser &&
          message.splitMode &&
          message.text.contains('\n\n')) {
        final parts = message.text
            .split('\n\n')
            .where((part) => part.trim().isNotEmpty)
            .toList(growable: false);
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

      final giftMatch = message.isUser
          ? _ChatScreenState._giftTagRe.firstMatch(message.text)
          : null;
      items.add(
        _buildLongScreenshotBubble(
          message: message,
          text: message.text,
          timestamp: message.createdAt,
          imagePath: message.imagePath,
          messageKey: 'longshot_${message.id}',
          giftName: giftMatch?.group(1)?.trim(),
          giftAccepted: giftMatch != null && charReplyAfter[i],
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
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.redAccent : YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showNonBlockingModelHint(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _modelHintOverlay?.remove();
    _modelHintOverlay = null;

    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    void dismiss() {
      if (_modelHintOverlay != entry) return;
      _modelHintOverlay?.remove();
      _modelHintOverlay = null;
    }

    entry = OverlayEntry(
      builder: (ctx) {
        final top = MediaQuery.of(ctx).padding.top + 12;
        return Positioned(
          top: top,
          left: 16,
          right: 16,
          child: IgnorePointer(
            ignoring: onAction == null,
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? const Color(0xF02B2430)
                        : Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    border: Border.all(
                      color: YanciTheme.glassBorder,
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          message,
                          textAlign: TextAlign.center,
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 12,
                            color: YanciTheme.textPrimary,
                          ),
                        ),
                      ),
                      if (onAction != null && actionLabel != null) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            dismiss();
                            onAction();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: YanciTheme.accent,
                            minimumSize: const Size(48, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: Text(actionLabel),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _modelHintOverlay = entry;
    Future.delayed(const Duration(milliseconds: 2600), () {
      dismiss();
    });
  }

  String _modelCostPolicyMessage(ModelCostPolicyNotice notice) {
    return switch (notice) {
      ModelCostPolicyNotice.inklingContextLimitEnabled => L.pick(
        en: 'Prompt cache and its summary were turned off. Context send limit is now on to reduce Inkling costs.',
        zhTW: '已關閉緩存命中及其專用摘要，並開啟上下文發送限制以節省 Inkling 費用。',
        zhCN: '已关闭缓存命中及其专用摘要，并开启上下文发送限制以节省 Inkling 费用。',
      ),
      ModelCostPolicyNotice.claudeCacheRecommended => L.pick(
        en: 'Enable cache hits to reduce Claude costs.',
        zhTW: '請開啟緩存命中以節省 Claude 費用。',
        zhCN: '请开启缓存命中以节省 Claude 费用。',
      ),
      ModelCostPolicyNotice.none => '',
    };
  }

  /// 收藏模型快速切換
  void _showModelPicker() async {
    final starred = await ApiSettings.getRankedStarredModels();
    final thinkingEnabled = await ApiSettings.getThinkingChain();
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

    if (starred.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.get('chat_api_star_hint')),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
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
        final entries = starred
            .map(
              (modelId) => ChatModelPickerEntry(
                id: modelId,
                label: _fullModelName(modelId),
                isLocal:
                    LocalModelService.isLocalModelId(modelId) ||
                    ApiSettings.isLocalApiModelId(modelId),
              ),
            )
            .toList(growable: false);

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
                        initialThinking: thinkingEnabled,
                        accentColor: pickerAccent,
                        onThinkingChanged: (value) async {
                          await ApiSettings.saveThinkingChain(value);
                          if (mounted) {
                            _refreshChatState(
                              () => _generationThinkingEnabled = value,
                            );
                          }
                          if (!mounted || !_isGenerating) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                L.pick(
                                  en: 'Thinking will apply from the next reply. The current request is already running.',
                                  zhTW: 'Thinking 會從下一次回覆生效；目前這次請求已經送出。',
                                  zhCN: 'Thinking 会从下一次回复生效；当前这次请求已经发出。',
                                ),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        onModelSelected: (modelId) async {
                          final provider =
                              await ApiSettings.resolveStarredModelProvider(
                                modelId,
                              );
                          await ApiSettings.saveProviderModelSelection(
                            provider,
                            modelId,
                          );
                          final policyResult =
                              await ModelCostPolicy.applySelection(
                                provider: provider,
                                model: modelId,
                                apiKey: provider == 'thinking_machines'
                                    ? await ApiSettings.getThinkingMachinesApiKey()
                                    : '',
                              );
                          final supportsRenewal =
                              TokenEstimator.supportsCloseWindowKeepAlive(
                                provider: provider,
                                model: modelId,
                              );
                          if (!supportsRenewal) {
                            await MemorySettings.saveKeepAliveEnabled(false);
                          }
                          if (!mounted) return;
                          _refreshChatState(() => _currentModel = modelId);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (policyResult.notice !=
                              ModelCostPolicyNotice.none) {
                            _showNonBlockingModelHint(
                              _modelCostPolicyMessage(policyResult.notice),
                            );
                          } else if (!supportsRenewal) {
                            _showNonBlockingModelHint(
                              L.pick(
                                en: 'This model has no confirmed one-hour cache TTL, so automatic renewal remains off.',
                                zhTW: '此模型沒有已確認的 1 小時緩存 TTL，自動延續命中已保持關閉。',
                              ),
                            );
                          }
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
