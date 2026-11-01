// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatMessageListMethods on _ChatScreenState {
  RegExp get _callActionRe => _ChatScreenState._callActionRe;
  RegExp get _callDividerRe => _ChatScreenState._callDividerRe;
  RegExp get _giftTagRe => _ChatScreenState._giftTagRe;
  RegExp get _receivedGiftTagRe => _ChatScreenState._receivedGiftTagRe;
  RegExp get _marriageCertTagRe => _ChatScreenState._marriageCertTagRe;
  String get _marriageCertCharTag => _ChatScreenState._marriageCertCharTag;
  double get _chatHeaderHeight => _ChatScreenState._chatHeaderHeight;
  double get _messageListBottomBreathingSpace =>
      _ChatScreenState._messageListBottomBreathingSpace;
  double get _composerViewportUnderlay =>
      _ChatScreenState._composerViewportUnderlay;
  int get _renderPageSize => _ChatScreenState._renderPageSize;

  Widget _buildMessageList() {
    final hasWebSearchActivity = _webSearchActivity != null;
    // Search owns the pending assistant surface. The model's tool-call preface
    // must not appear as a second bubble above Thinking/search status.
    // 建立生成任務時就掛上流式氣泡，而不是等第一個可見字元到達後才插入。
    // 各來源首包大小不同，但都共用同一個 ChatBubble，因而能走一致的 QQ
    // 彈彈入場動畫；內容仍由既有 stream queue 逐字填入。
    final hasStreamingBubble =
        _isGenerating &&
        _streamSurfaceVisible &&
        !_isGeneratingImage &&
        !hasWebSearchActivity;
    final pendingWebSearchTrace = _pendingWebSearchResult?.toDisplayTrace();
    // Web search owns the active Thinking surface. Avoid rendering the generic
    // atom above it, which otherwise looks like an empty assistant bubble.
    // 文字生成使用上方的 QQ 流式氣泡；原子動畫只保留給圖片生成。
    final showAtom =
        _isGenerating &&
        _isGeneratingImage &&
        _streamingText.isEmpty &&
        !hasWebSearchActivity;

    // 構建顯示列表（拆分回覆時 AI 消息按段落拆開）
    // 渲染窗：只掛 _renderFrom 起的消息；i 保持全量索引（editMessage 等依賴）
    final renderFrom = _renderFrom.clamp(0, _messages.length);
    // Do not expose the pagination affordance while the window is still
    // initializing; the first partial build can otherwise flash it briefly.
    final hasOlderButton =
        _isChatReady && _olderButtonReady && (renderFrom > 0 || _olderHasMore);
    // 渲染源 = 錨點前純顯示段（永不進上下文）+ 發送窗的渲染段。
    // 純顯示段 originalIndex 為 -1：編輯/重發等窗內索引操作不適用。
    final renderSource = <(Message, int)>[
      for (final m in _olderMessages) (m, -1),
      for (int i = renderFrom; i < _messages.length; i++) (_messages[i], i),
    ];
    // 預計算：renderSource[k] 之後是否還有角色的非空回覆（禮物「已收下」判定）
    final charReplyAfter = List<bool>.filled(renderSource.length, false);
    var seenCharReply = false;
    for (var k = renderSource.length - 1; k >= 0; k--) {
      charReplyAfter[k] = seenCharReply;
      final m = renderSource[k].$1;
      if (!m.isUser && m.text.trim().isNotEmpty) seenCharReply = true;
    }

    final displayItems = <_DisplayItem>[];
    for (var srcIdx = 0; srcIdx < renderSource.length; srcIdx++) {
      final (msg, i) = renderSource[srcIdx];

      // RP 新窗口的「繼續這一篇章」是模型可見的使用者動作，但不是
      // 對話正文；保留在歷史中維持因果與 cache 前綴。畫面改用來源窗口
      // 的只讀虛擬拼接，避免把舊消息複製進本窗口後污染摘要、編輯與刪除。
      if (msg.isRpChapterContinuation) {
        if (_rpContinuationSourceConversationId != null &&
            _rpContinuationDisplayMessages.isNotEmpty) {
          displayItems.add(
            _DisplayItem(
              text: '',
              isUser: false,
              messageId: 'rp_continuation_header',
              originalIndex: -1,
              showToolbar: false,
              continuationKind: _RpContinuationDisplayKind.header,
            ),
          );
          for (final sourceMessage in _rpContinuationDisplayMessages) {
            displayItems.add(
              _DisplayItem(
                text: sourceMessage.text,
                isUser: sourceMessage.isUser,
                timestamp: sourceMessage.createdAt,
                imagePath: sourceMessage.imagePath,
                imagePaths: sourceMessage.imagePaths,
                messageId:
                    'rp_source_${_rpContinuationSourceConversationId}_'
                    '${sourceMessage.id ?? sourceMessage.createdAt.microsecondsSinceEpoch}',
                originalIndex: -1,
                showToolbar: false,
              ),
            );
          }
          displayItems.add(
            _DisplayItem(
              text: '',
              isUser: false,
              messageId: 'rp_continuation_boundary',
              originalIndex: -1,
              showToolbar: false,
              continuationKind: _RpContinuationDisplayKind.boundary,
            ),
          );
        }
        continue;
      }

      // 通話操作是模型可見的 user action，入庫以維持跨模式 append-only
      // cache prefix；純協議標記不在聊天 UI 顯示。
      if (_callActionRe.hasMatch(msg.text.trim())) continue;

      // ═══ 通話結束/中斷 → 居中分割線（declined/missed 維持隱藏）═══
      final callMatch = _callDividerRe.firstMatch(msg.text.trim());
      if (callMatch != null) {
        final kind = callMatch.group(1)!;
        final dur = callMatch.group(2);
        final (label, icon) = switch (kind) {
          'ended' => (
            L.pick(en: 'Call ended', zhTW: '通話已結束'),
            Icons.call_end_rounded,
          ),
          'signal_lost' => (
            L.pick(en: 'Call dropped', zhTW: '通話中斷'),
            Icons.signal_cellular_connected_no_internet_0_bar_rounded,
          ),
          // 她打來、你拒接
          'declined' => (
            L.pick(en: 'Call declined', zhTW: '已拒絕來電'),
            Icons.phone_disabled_rounded,
          ),
          // 你打去、她拒接
          'declined_by_you' => (
            L.pick(en: 'Declined by them', zhTW: '對方已拒絕'),
            Icons.phone_disabled_rounded,
          ),
          // 她打來、響鈴未接
          _ => (
            L.pick(en: 'Missed call', zhTW: '未接來電'),
            Icons.phone_missed_rounded,
          ),
        };
        displayItems.add(
          _DisplayItem(
            text: '',
            isUser: msg.isUser,
            messageId: 'msg_${msg.id}',
            dbMessageId: msg.id,
            originalIndex: i,
            callDivider: dur == null ? label : '$label · $dur',
            callDividerIcon: icon,
          ),
        );
        continue;
      }

      final splitParts = _splitReply && !msg.isUser && msg.splitMode
          ? splitReplyParagraphs(msg.text)
          : const <String>[];
      if (splitParts.length > 1) {
        final parts = splitParts;
        final splitHasCert = msg.text.contains(_marriageCertCharTag);
        for (int j = 0; j < parts.length; j++) {
          final isLast = j == parts.length - 1;
          displayItems.add(
            _DisplayItem(
              text: parts[j].trim(),
              isUser: false,
              timestamp: isLast ? msg.createdAt : null,
              imagePath: j == 0 ? msg.imagePath : null,
              imagePaths: j == 0 ? msg.imagePaths : const <String>[],
              messageId: 'msg_${msg.id}_$j',
              dbMessageId: msg.id,
              originalIndex: i,
              showToolbar: isLast,
              // The final split bubble owns actions for the whole reply, but
              // actions must use the presentation-safe prose rather than the
              // raw response (which can still contain thinking/tool markup).
              toolbarText: isLast
                  ? VisibleModelOutput.finalOnly(msg.text)
                  : null,
              toolbarMessageId: isLast ? 'msg_${msg.id}' : null,
              isSplitReplySegment: true,
              memoryLog: j == 0 ? msg.memoryLog : '',
              pendingMemoryActionCount: j == 0 && msg.id != null
                  ? (_pendingMemoryActionCounts[msg.id]?.total ?? 0)
                  : 0,
              hasUnreadMemoryActions: j == 0 && msg.id != null
                  ? (_pendingMemoryActionCounts[msg.id]?.unread ?? 0) > 0
                  : false,
              cacheHit:
                  isLast &&
                  !msg.isUser &&
                  (msg.cacheHit || _cacheHitIndices.contains(i)),
              incomplete: isLast && msg.isIncomplete,
              webSearchResult: isLast && msg.id != null
                  ? _webSearchResultsByMessageId[msg.id]
                  : null,
              webSearchTrace: isLast ? msg.webSearchTrace : null,
              emailDraft: isLast ? msg.emailDraft : null,
              personaCard: isLast ? msg.personaCard : null,
              // 她遞的證書卡跟在拆分回覆的最後一段
              hasMarriageCert: isLast && splitHasCert,
              certFromChar: isLast && splitHasCert,
              summaryRecordedId: isLast && msg.id != null
                  ? _summaryRecordedSummaryIds[msg.id]
                  : null,
            ),
          );
        }
      } else {
        // ═══ 送禮標記 → 禮物卡片跟隨氣泡；對方之後回了話 = 已收下 ═══
        final sentGiftMatch = msg.isUser
            ? _giftTagRe.firstMatch(msg.text)
            : null;
        final receivedGiftMatch = msg.isUser
            ? null
            : _receivedGiftTagRe.firstMatch(msg.text);
        final giftMatch = sentGiftMatch ?? receivedGiftMatch;
        // 多氣泡寫的回覆（段落之間空一行）在平鋪／單氣泡顯示時，
        // 把段落間的空行收成一般換行，不留一大段空白。只影響顯示，
        // 資料庫原文、複製以外的處理都不動；切回多氣泡會照原樣拆開。
        final displayText = !msg.isUser && msg.splitMode && !_splitReply
            ? msg.text.replaceAll(RegExp(r'\n[ \t]*\n\s*'), '\n')
            : msg.text;
        displayItems.add(
          _DisplayItem(
            text: displayText,
            isUser: msg.isUser,
            timestamp: msg.createdAt,
            imagePath: msg.imagePath,
            imagePaths: msg.imagePaths,
            messageId: 'msg_${msg.id}',
            dbMessageId: msg.id,
            originalIndex: i,
            cacheHit:
                !msg.isUser && (msg.cacheHit || _cacheHitIndices.contains(i)),
            memoryLog: msg.memoryLog,
            pendingMemoryActionCount: msg.id == null
                ? 0
                : (_pendingMemoryActionCounts[msg.id]?.total ?? 0),
            hasUnreadMemoryActions:
                msg.id != null &&
                (_pendingMemoryActionCounts[msg.id]?.unread ?? 0) > 0,
            incomplete: msg.isIncomplete,
            webSearchResult: !msg.isUser && msg.id != null
                ? _webSearchResultsByMessageId[msg.id]
                : null,
            webSearchTrace: msg.isUser ? null : msg.webSearchTrace,
            emailDraft: msg.isUser ? null : msg.emailDraft,
            personaCard: msg.isUser ? null : msg.personaCard,
            giftName: giftMatch?.group(1)?.trim(),
            giftAccepted:
                receivedGiftMatch != null ||
                (sentGiftMatch != null && charReplyAfter[srcIdx]),
            giftReceivedFromCharacter: receivedGiftMatch != null,
            hasMarriageCert:
                (msg.isUser && _marriageCertTagRe.hasMatch(msg.text)) ||
                (!msg.isUser && msg.text.contains(_marriageCertCharTag)),
            certFromChar:
                !msg.isUser && msg.text.contains(_marriageCertCharTag),
            summaryRecordedId: msg.id == null
                ? null
                : _summaryRecordedSummaryIds[msg.id],
          ),
        );

        if (msg.isUser && msg.id != null) {
          final msgKey = 'msg_${msg.id}';
          final sd = _scratchDataMap[msgKey];
          if (sd != null && sd.who == 'char') {
            displayItems.add(
              _DisplayItem(
                text: '',
                isUser: false, // Force it to the left side
                timestamp: msg.createdAt,
                imagePath: null,
                messageId: msgKey,
                dbMessageId: null,
                originalIndex: i,
                cacheHit: false,
                memoryLog: '',
              ),
            );
          }
        }
      }
    }

    final hasSearchCard = _chatSearchQuery.isNotEmpty;
    final itemCount =
        (hasOlderButton ? 1 : 0) +
        displayItems.length +
        (hasStreamingBubble ? 1 : 0) +
        (hasSearchCard ? 1 : 0) +
        (hasWebSearchActivity ? 1 : 0) +
        (showAtom ? 1 : 0);
    final keepFirstUserBelowTopFade =
        !hasOlderButton &&
        _olderMessages.isEmpty &&
        displayItems.isNotEmpty &&
        displayItems.first.isUser &&
        displayItems.first.continuationKind == null;
    final messageListTopPadding = keepFirstUserBelowTopFade
        ? _chatHeaderHeight + 70 + YanciTheme.spacingSm
        : YanciTheme.spacingSm + _chatHeaderHeight;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _followKeyboardViewport = false;
          _rpContinuationPullDistance = 0;
          _rpContinuationPullTriggered = false;
          _hideHeaderModelDetails();
          _userIsScrolling = true;
          _userScrolledUp = true;
        } else if (notification is OverscrollNotification &&
            notification.depth == 0 &&
            notification.overscroll < 0 &&
            notification.metrics.pixels <=
                notification.metrics.minScrollExtent + 1 &&
            _rpContinuationSourceConversationId != null &&
            !_rpContinuationSourceLoading) {
          _rpContinuationPullDistance += -notification.overscroll;
          if (!_rpContinuationPullTriggered &&
              _rpContinuationPullDistance >= 64) {
            _rpContinuationPullTriggered = true;
            HapticFeedback.selectionClick();
            if (!_rpContinuationSourceExpanded) {
              unawaited(_toggleRpContinuationSourceHistory());
            } else if (_rpContinuationSourceHasMore) {
              unawaited(_loadEarlierRpContinuationSourceHistory());
            }
          }
        } else if (notification is UserScrollNotification) {
          if (notification.direction == ScrollDirection.idle) {
            _userIsScrolling = false;
          } else if (!_streamScrollAnimating) {
            _userIsScrolling = true;
            if (_isGenerating) _userScrolledUp = true;
          }
        } else if (notification is ScrollEndNotification) {
          _rpContinuationPullDistance = 0;
          _rpContinuationPullTriggered = false;
          _userIsScrolling = false;
        }
        return false;
      },
      child: RawScrollbar(
        controller: _scrollController,
        interactive: true,
        timeToFade: const Duration(milliseconds: 1600),
        fadeDuration: const Duration(milliseconds: 250),
        notificationPredicate: (notification) {
          if (notification.depth != 0) return false;

          final programmaticFollow =
              _streamScrollAnimating ||
              _followKeyboardViewport ||
              (_isGenerating && !_userScrolledUp && !_userIsScrolling);
          if (programmaticFollow) return false;

          if (notification is ScrollUpdateNotification &&
              notification.scrollDelta == null &&
              !_userIsScrolling) {
            // Bubble relayouts and viewport metric changes are not user
            // scrolling. Ignoring them prevents the thumb flashing while a
            // response streams or the keyboard changes the available height.
            return false;
          }
          return true;
        },
        thickness: 8,
        minThumbLength: 96.0,
        radius: const Radius.circular(10),
        thumbColor: YanciTheme.accent.withValues(alpha: 0.55),
        child: ListView.builder(
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          scrollCacheExtent: ScrollCacheExtent.pixels(800.0),
          padding: EdgeInsets.only(
            // At a window's initial resting position, its first user message
            // starts just below the alpha fade. Once later messages arrive,
            // normal scrolling can push it through the fade like every other
            // message.
            top: messageListTopPadding,
            bottom:
                _messageListBottomBreathingSpace + _composerViewportUnderlay,
          ),
          itemCount: itemCount,
          itemBuilder: (context, rawIndex) {
            // 頭部「查看更早」：先翻完發送窗的渲染段，再從 DB 往前掛
            // 純顯示段（錨點前歷史，永不進上下文）
            if (hasOlderButton && rawIndex == 0) {
              final page = renderFrom > 0 && renderFrom < _renderPageSize
                  ? renderFrom
                  : _renderPageSize;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: GestureDetector(
                    onTap: () {
                      if (renderFrom > 0) {
                        setState(() {
                          _renderFrom = (renderFrom - _renderPageSize).clamp(
                            0,
                            _messages.length,
                          );
                        });
                      } else {
                        _loadOlderForDisplay();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: YanciTheme.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: YanciTheme.accent.withValues(alpha: 0.25),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        L.pick(
                          en: '↑ Show $page earlier',
                          zhTW: '↑ 查看更早的 $page 條',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: YanciTheme.accent.withValues(alpha: 0.9),
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
            final index = hasOlderButton ? rawIndex - 1 : rawIndex;
            if (index < displayItems.length) {
              final item = displayItems[index];
              switch (item.continuationKind) {
                case _RpContinuationDisplayKind.header:
                  return _buildRpContinuationHeader();
                case _RpContinuationDisplayKind.boundary:
                  return _buildRpContinuationBoundary();
                case null:
                  break;
              }
              // ═══ 通話結束分割線：線 — 文字 — 線，主題色低調款 ═══
              if (item.callDivider != null) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 0.6,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                YanciTheme.accent.withValues(alpha: 0.35),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              item.callDividerIcon ?? Icons.call_end_rounded,
                              size: 12,
                              color: YanciTheme.accent.withValues(alpha: 0.55),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              item.callDivider!,
                              style: TextStyle(
                                fontSize: 11,
                                color: YanciTheme.accent.withValues(
                                  alpha: 0.65,
                                ),
                                fontFamily: YanciTheme.fontFamily,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 0.6,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                YanciTheme.accent.withValues(alpha: 0.35),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              final selectable =
                  _manualSummarySelecting &&
                  item.dbMessageId != null &&
                  item.text.trim().isNotEmpty;
              final groupedWithPrevious =
                  index > 0 &&
                  _canGroupDisplayItems(displayItems[index - 1], item);
              final groupedWithNext =
                  index + 1 < displayItems.length &&
                  _canGroupDisplayItems(item, displayItems[index + 1]);
              final tightGroupWithPrevious =
                  index > 0 &&
                  _isSameSplitReplyGroup(displayItems[index - 1], item);
              final tightGroupWithNext =
                  index + 1 < displayItems.length &&
                  _isSameSplitReplyGroup(item, displayItems[index + 1]);
              final bubble = ChatBubble(
                text: item.text,
                isUser: item.isUser,
                timestamp: item.timestamp,
                memoryLog: item.memoryLog,
                pendingMemoryActionCount: item.pendingMemoryActionCount,
                hasUnreadMemoryActions: item.hasUnreadMemoryActions,
                pendingMemoryProposals: item.dbMessageId == null
                    ? const []
                    : (_pendingMemoryProposals[item.dbMessageId] ?? const []),
                onInlineMemoryProposal: _applyInlineMemoryProposal,
                onMemoryReviewTap:
                    item.pendingMemoryActionCount > 0 &&
                        item.dbMessageId != null
                    ? () => _openMemoryReview(item.dbMessageId!)
                    : null,
                webSearchTrace: item.webSearchTrace,
                // 窗內消息 → 原地編輯重發；
                // 純顯示段（originalIndex -1）→ 編輯即開分支對話，原時間線不動
                onEdit: item.isUser
                    ? (item.originalIndex >= 0
                          ? () => _editMessage(item.originalIndex)
                          : (item.dbMessageId != null
                                ? () => _editAsBranch(item.dbMessageId!)
                                : null))
                    : null,
                messageId: item.messageId,
                imagePath: item.imagePath,
                imagePaths: item.imagePaths,
                conversationId: widget.conversationId,
                conversationTitle: _characterName,
                characterId: _activeCharacterId,
                showAvatar: _showChatAvatar,
                showAvatarImage: !groupedWithPrevious,
                groupedWithPrevious: groupedWithPrevious,
                groupedWithNext: groupedWithNext,
                tightGroupWithPrevious: tightGroupWithPrevious,
                tightGroupWithNext: tightGroupWithNext,
                avatarPath: item.isUser ? _userAvatarPath : _charAvatarPath,
                showToolbar: item.showToolbar,
                toolbarText: item.toolbarText,
                toolbarMessageId: item.toolbarMessageId,
                cacheHit: item.cacheHit,
                incomplete: item.incomplete,
                onRetryIncomplete:
                    item.incomplete &&
                        item.dbMessageId != null &&
                        item.originalIndex == _messages.length - 1
                    ? () =>
                          unawaited(_retryIncompleteMessage(item.dbMessageId!))
                    : null,
                scratchData: _scratchDataMap[item.messageId],
                transferData: _transferDataMap[item.messageId],
                giftName: item.giftName,
                giftAccepted: item.giftAccepted,
                giftReceivedFromCharacter: item.giftReceivedFromCharacter,
                marriageCert: item.hasMarriageCert
                    ? MarriageCertDisplay(
                        userName: _userNameCache,
                        charName: _characterName,
                        signed: _isMarried,
                        date: _marriageDate,
                      )
                    : null,
                onCertSignTap: item.certFromChar && !_isMarried
                    ? _signCharCert
                    : null,
                onTransferUpdated: () => _refreshTransfer(item.messageId),
                selectable: selectable,
                selected:
                    item.dbMessageId != null &&
                    _manualSummarySelectedIds.contains(item.dbMessageId),
                // The assistant already entered as the streaming bubble.
                // Persisting it must not replay the text-hidden entrance.
                animateEntry: item.isUser,
                animateContextReveal:
                    !item.isUser &&
                    item.dbMessageId == _freshAssistantContextMessageId,
                onSelectionToggle: item.dbMessageId == null
                    ? null
                    : () => _toggleManualSummaryMessage(item.dbMessageId!),
              );
              final geminiDisplayResult = item.webSearchResult == null
                  ? null
                  : WebSearchFollowUp.geminiDisplayResultFor(
                      item.webSearchResult!,
                    );
              final attachments = <Widget>[];
              if (!selectable &&
                  !item.isUser &&
                  item.showToolbar &&
                  !item.incomplete &&
                  item.dbMessageId != null &&
                  _messages.isNotEmpty &&
                  item.dbMessageId == _messages.last.id &&
                  !_isGenerating &&
                  !_isGeneratingImage &&
                  !_sendSubmissionInProgress) {
                attachments.add(
                  ReplyVariantControls(
                    messageId: item.dbMessageId!,
                    revision: _messages.last.revision,
                    color:
                        (_boundChatForeground?.primary ??
                                YanciTheme.textPrimary)
                            .withValues(alpha: 0.55),
                    onSelect: (archiveId) => unawaited(
                      _selectReplyVariant(item.dbMessageId!, archiveId),
                    ),
                  ),
                );
              }
              if (item.summaryRecordedId != null) {
                attachments.add(
                  _buildSummaryRecordedDivider(item.summaryRecordedId!),
                );
              }
              if (item.dbMessageId != null) {
                for (final diagnostic in _chatDiagnostics.where(
                  (event) => event.anchorMessageId == item.dbMessageId,
                )) {
                  attachments.add(
                    ChatDiagnosticCard(
                      key: ValueKey('chat-diagnostic-${diagnostic.id}'),
                      event: diagnostic,
                      onRetry: () => _retryChatDiagnostic(diagnostic),
                    ),
                  );
                }
              }
              final emailDraft = item.emailDraft;
              if (emailDraft != null && item.dbMessageId != null) {
                attachments.add(
                  EmailDraftCard(
                    draft: emailDraft,
                    showAvatar: _showChatAvatar,
                    onEdit: () => unawaited(
                      _editEmailDraft(item.dbMessageId!, emailDraft),
                    ),
                    onOpen: () => unawaited(_openEmailDraft(emailDraft)),
                    onDelete: () =>
                        unawaited(_deleteEmailDraft(item.dbMessageId!)),
                  ),
                );
              }
              final personaCard = item.personaCard;
              if (personaCard != null && item.dbMessageId != null) {
                attachments.add(
                  NewCharacterDraftCard(
                    key: ValueKey<String>('persona-card-${item.dbMessageId}'),
                    state: personaCard,
                    showAvatar: _showChatAvatar,
                    onDraftChanged: (draft) =>
                        _savePersonaCardDraft(item.dbMessageId!, draft),
                    onAdd: (draft) =>
                        _addCharacterFromPersonaCard(item.dbMessageId!, draft),
                    onOpenCharacter: () =>
                        _openPersonaCharacter(personaCard.createdCharacterId!),
                  ),
                );
              }
              if (geminiDisplayResult != null) {
                attachments.add(
                  WebSearchResultCard(result: geminiDisplayResult),
                );
              }
              if (attachments.isEmpty) return bubble;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[bubble, ...attachments],
              );
            } else if (showAtom && index == displayItems.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AtomThinkingWidget(size: 36, color: YanciTheme.accent),
                ),
              );
            } else {
              // ═══ 搜索卡片（streaming 後、最末尾）═══
              final streamSlots = hasStreamingBubble ? 1 : 0;
              final searchCardIdx =
                  displayItems.length + (showAtom ? 1 : 0) + streamSlots;
              if (hasSearchCard && index == searchCardIdx) {
                return _buildSearchCard();
              }
              final webSearchActivityIdx =
                  searchCardIdx + (hasSearchCard ? 1 : 0);
              final webSearchActivity = _webSearchActivity;
              if (hasWebSearchActivity &&
                  webSearchActivity != null &&
                  index == webSearchActivityIdx) {
                return WebSearchThinkingActivity(
                  status: webSearchActivity.status,
                  query: webSearchActivity.query,
                  providers: webSearchActivity.providers,
                  safeMessage: webSearchActivity.safeMessage,
                  showAvatar: _showChatAvatar,
                  avatarPath: _charAvatarPath,
                );
              }
              // ═══ 流式氣泡（拆分回覆時按段落拆）═══
              return ValueListenableBuilder<int>(
                valueListenable: _streamRevision,
                builder: (context, _, _) {
                  if (!_splitReply) {
                    final groupedWithPrevious =
                        displayItems.isNotEmpty &&
                        _canGroupDisplayItems(
                          displayItems.last,
                          _DisplayItem.streamingAssistant,
                        );
                    return ChatBubble(
                      text: _displayStreamingText,
                      isUser: false,
                      isStreaming: !_visibleReplyComplete,
                      messageId: 'streaming',
                      conversationId: widget.conversationId,
                      conversationTitle: _characterName,
                      characterId: _activeCharacterId,
                      showAvatar: _showChatAvatar,
                      showAvatarImage: !groupedWithPrevious,
                      groupedWithPrevious: groupedWithPrevious,
                      avatarPath: _charAvatarPath,
                      webSearchTrace: pendingWebSearchTrace,
                      animateEntry: true,
                    );
                  }
                  final parts = _streamingSplitParts();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (
                        var streamIdx = 0;
                        streamIdx < parts.length;
                        streamIdx++
                      )
                        ChatBubble(
                          key: ValueKey<String>('streaming_$streamIdx'),
                          text: parts[streamIdx],
                          isUser: false,
                          isStreaming:
                              !_visibleReplyComplete &&
                              streamIdx == parts.length - 1,
                          messageId: 'streaming_$streamIdx',
                          conversationId: widget.conversationId,
                          conversationTitle: _characterName,
                          characterId: _activeCharacterId,
                          showAvatar: _showChatAvatar,
                          showAvatarImage:
                              streamIdx == 0 &&
                              !(displayItems.isNotEmpty &&
                                  _canGroupDisplayItems(
                                    displayItems.last,
                                    _DisplayItem.streamingAssistant,
                                  )),
                          groupedWithPrevious:
                              streamIdx > 0 ||
                              (displayItems.isNotEmpty &&
                                  _canGroupDisplayItems(
                                    displayItems.last,
                                    _DisplayItem.streamingAssistant,
                                  )),
                          groupedWithNext: streamIdx < parts.length - 1,
                          avatarPath: _charAvatarPath,
                          webSearchTrace: streamIdx == parts.length - 1
                              ? pendingWebSearchTrace
                              : null,
                          animateEntry: true,
                        ),
                    ],
                  );
                },
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildSummaryRecordedDivider(int summaryId) {
    final thinkingColor = _boundBackgroundPreset?.chatThinkingTextColor == null
        ? _boundChatPalette?.thinkingText ??
              Color.lerp(
                YanciTheme.textSecondary,
                YanciTheme.textPrimary,
                0.34,
              )!
        : Color(_boundBackgroundPreset!.chatThinkingTextColor!);
    final color = thinkingColor.withValues(alpha: 0.6);
    final label = L.pick(en: 'Summary recorded', zhTW: '摘要已記錄', zhCN: '摘要已记录');
    final semanticLabel = L.pick(
      en: 'Summary recorded. Tap to view or edit this summary.',
      zhTW: '摘要已記錄，點擊查看或編輯本次摘要',
      zhCN: '摘要已记录，点击查看或编辑本次摘要',
    );

    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showWindowSummaryEditor(summaryId),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: 5, bottom: 9),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(width: 22, height: 0.6, color: color),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontFamily: YanciTheme.fontFamily,
                      letterSpacing: 0.35,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 22, height: 0.6, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showWindowSummaryEditor(int summaryId) async {
    if (_summaryEditorVisible) return;
    _summaryEditorVisible = true;
    try {
      final identity = _requiredSessionIdentity;
      final row = await DatabaseHelper.getConversationContextSummaryById(
        summaryId: summaryId,
        conversationId: widget.conversationId,
        contextMode: identity.contextMode,
        continuityId: identity.continuityId,
      );
      if (!mounted) return;
      if (row == null || row['id'] is! int) {
        _showChatNotice(
          L.pick(
            en: 'No summary is available for this window yet',
            zhTW: '目前窗口還沒有可查看的摘要',
            zhCN: '当前窗口还没有可查看的摘要',
          ),
        );
        return;
      }
      final content = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _WindowSummaryEditorSheet(
          initialContent: row['content']?.toString() ?? '',
        ),
      );
      if (content == null || !mounted) return;
      await DatabaseHelper.updateContextSummary(
        id: row['id'] as int,
        content: content,
        tokenCount: TokenEstimator.estimate(content),
      );
      if (mounted) {
        _showChatNotice(
          L.pick(en: 'Summary updated', zhTW: '摘要已更新', zhCN: '摘要已更新'),
        );
      }
    } finally {
      _summaryEditorVisible = false;
    }
  }

  Widget _buildManualSummarySelectionBar() {
    final count = _manualSummarySelectedIds.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg,
        border: Border(
          top: BorderSide(
            color: YanciTheme.textSecondary.withValues(alpha: 0.10),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                L.pick(
                  en: count == 0
                      ? 'Select messages to summarize'
                      : '$count messages selected',
                  zhTW: count == 0 ? '勾選要摘要的消息' : '已選 $count 條消息',
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: YanciTheme.textPrimary.withValues(alpha: 0.78),
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ),
            TextButton(
              onPressed: _manualSummaryRunning
                  ? null
                  : () {
                      setState(() {
                        _manualSummarySelecting = false;
                        _manualSummarySelectedIds.clear();
                      });
                    },
              child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: count == 0 || _manualSummaryRunning
                  ? null
                  : _confirmManualSummarySelected,
              icon: _manualSummaryRunning
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    )
                  : const Icon(Icons.edit_note_rounded, size: 18),
              label: Text(
                L.pick(
                  en: _manualSummaryRunning ? 'Summarizing' : 'Summarize',
                  zhTW: _manualSummaryRunning ? '摘要中' : '摘要',
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: YanciTheme.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
