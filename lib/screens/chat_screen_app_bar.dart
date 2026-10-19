// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatAppBarMethods on _ChatScreenState {
  Widget _buildAppBar() {
    final headerPrimary =
        _boundChatForeground?.primary ?? YanciTheme.textPrimary;
    final headerSecondary =
        _boundChatForeground?.secondary ?? YanciTheme.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingSm,
        vertical: YanciTheme.spacingXs,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ═══ 置中的標題區域 ═══
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  MediaQuery.sizeOf(context).width *
                  (_showHeaderModelDetails
                      ? 0.58
                      : _sessionIdentity?.contextMode == ContextMode.daily
                      ? 0.34
                      : 0.48),
            ),
            child: SizedBox(
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  AnimatedAlign(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 190),
                    curve: Curves.easeOutCubic,
                    alignment: _showHeaderModelDetails
                        ? Alignment.topCenter
                        : Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            _characterName.isNotEmpty ? _characterName : 'Holt',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              color: headerPrimary.withValues(alpha: 0.94),
                              fontFamily: YanciTheme.fontFamily,
                              letterSpacing: 0.5,
                              decoration: TextDecoration.none,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _buildCostModeRecommendationSwitch(),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Transform.translate(
                      offset: const Offset(0, 3),
                      child: IgnorePointer(
                        ignoring: !_showHeaderModelDetails,
                        child: AnimatedOpacity(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 150),
                          opacity: _showHeaderModelDetails ? 1 : 0,
                          child: ChatHeaderModelAttention(
                            accentColor: YanciTheme.accent,
                            playAttention: _headerModelNeedsAttention,
                            onAttentionComplete: () {
                              if (!mounted || !_headerModelNeedsAttention) {
                                return;
                              }
                              setState(
                                () => _headerModelNeedsAttention = false,
                              );
                            },
                            child: Semantics(
                              button: true,
                              label: L.pick(
                                en: 'Choose model',
                                zhTW: '選擇模型',
                                zhCN: '选择模型',
                              ),
                              child: GestureDetector(
                                key: _modelPickerAnchorKey,
                                behavior: HitTestBehavior.opaque,
                                onTap: _showModelPicker,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (_localModelLoading) ...<Widget>[
                                        SizedBox(
                                          width: 10,
                                          height: 10,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.5,
                                            color: headerSecondary.withValues(
                                              alpha: 0.62,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Flexible(
                                        child: Text(
                                          _localModelLoading
                                              ? L.pick(
                                                  en: 'Loading…',
                                                  zhTW: '加載中…',
                                                  zhCN: '加载中…',
                                                )
                                              : _shortModelName(_currentModel),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: headerSecondary.withValues(
                                              alpha: 0.62,
                                            ),
                                            fontFamily: YanciTheme.fontFamily,
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                      ),
                                      if (_tokenTracker.totalTokens >
                                          0) ...<Widget>[
                                        Text(
                                          ' · ',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: headerSecondary.withValues(
                                              alpha: 0.32,
                                            ),
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                        Text(
                                          '${_tokenTracker.formatTokens()} tokens',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: headerSecondary.withValues(
                                              alpha: 0.48,
                                            ),
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 3),
                                      Icon(
                                        Icons.unfold_more_rounded,
                                        size: 10,
                                        color: headerSecondary.withValues(
                                          alpha: 0.38,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ═══ 左右按鈕 ═══
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_rounded,
                  size: 20,
                  color:
                      _boundChatForeground?.primary ?? YanciTheme.textPrimary,
                ),
                onPressed: () => Navigator.of(context).pop(_walletChanged),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: _showHeaderModelDetails
                        ? null
                        : ChatWindowStatusButton(
                            color:
                                _boundChatForeground?.primary ??
                                YanciTheme.textPrimary,
                            accentColor: YanciTheme.accent,
                            playAttention: _statusButtonNeedsAttention,
                            onAttentionComplete: () {
                              if (!mounted || !_statusButtonNeedsAttention) {
                                return;
                              }
                              setState(
                                () => _statusButtonNeedsAttention = false,
                              );
                            },
                            onPressed: _showWindowStatus,
                          ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _shortModelName(String model) {
    if (model.isEmpty) {
      return L.pick(en: 'Select model', zhTW: '選模型', zhCN: '选模型');
    }
    // 本地模型：local:qwen3-1.7b-q4 → 📱 Qwen3 1.7B
    if (model.startsWith('local:')) {
      final key = model.substring(6);
      final info = LocalModelService.availableModels
          .where((m) => m.key == key)
          .firstOrNull;
      var localName = info != null
          ? L.pick(en: info.nameEn, zhTW: info.name)
          : LocalModelService.fallbackDisplayNameForKey(key);
      if (localName.length > 16) localName = '${localName.substring(0, 14)}…';
      return '📱 $localName';
    }
    if (ApiSettings.isLocalApiModelId(model)) {
      var localApiName = ApiSettings.extractLocalApiModel(model);
      if (localApiName.length > 16) {
        localApiName = '${localApiName.substring(0, 14)}…';
      }
      return '🖥 $localApiName';
    }
    var name = model;
    if (name.contains('/')) name = name.split('/').last;
    // 去掉日期後綴
    name = name.replaceAll(RegExp(r'-\d{8}$'), '');
    // 簡化 Claude 模型名：claude-sonnet-4.5 → sonnet 4.5
    name = name.replaceAll('claude-', '');
    // 簡化其他常見前綴
    name = name.replaceAll('gpt-', 'gpt');
    name = name.replaceAll('gemini-', 'gemini ');
    name = name.replaceAll('deepseek-', 'ds-');
    // 頂欄空間有限，太長就截
    if (name.length > 18) name = '${name.substring(0, 16)}…';
    return name;
  }

  String _fullModelName(String model) {
    if (model.isEmpty) {
      return L.pick(en: 'Select model', zhTW: '選模型', zhCN: '选模型');
    }
    if (model.startsWith('local:')) {
      final key = model.substring(6);
      final info = LocalModelService.availableModels
          .where((m) => m.key == key)
          .firstOrNull;
      return info != null
          ? L.pick(en: info.nameEn, zhTW: info.name)
          : LocalModelService.fallbackDisplayNameForKey(key);
    }
    if (ApiSettings.isLocalApiModelId(model)) {
      return ApiSettings.extractLocalApiModel(model);
    }
    var name = model;
    if (name.contains('/')) name = name.split('/').last;
    name = name.replaceAll(RegExp(r'-\d{8}$'), '');
    name = name.replaceAll('claude-', '');
    name = name.replaceAll('gpt-', 'gpt');
    name = name.replaceAll('gemini-', 'gemini ');
    name = name.replaceAll('deepseek-', 'ds-');
    return name;
  }

  Color? _savedThemeColor(String? hex) {
    if (hex == null) return null;
    final normalized = hex.replaceAll('#', '').trim();
    final value = int.tryParse(
      normalized.length == 6 ? 'FF$normalized' : normalized,
      radix: 16,
    );
    return value == null ? null : Color(value);
  }

  Widget _buildEmptyState() {
    final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
    final showDailyContinuation = !isRp && _canContinuePreviousRpChapter;
    final showRpChapterChoices =
        isRp && _hasAnyRpWindow && !_rpStartChoiceResolved;
    final hasMultipleRpStorylines = _rpStorylines.length > 1;
    final showPlaceholder = !isRp || !_hasAnyRpWindow;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 48,
              color: YanciTheme.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: YanciTheme.spacingMd),
            if (showPlaceholder)
              Text(
                L.get('chat_placeholder'),
                textAlign: TextAlign.center,
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
              ),
            if (showDailyContinuation) ...<Widget>[
              const SizedBox(height: 24),
              Semantics(
                button: true,
                label: L.pick(
                  en: 'Continue the previous conversation. Let them respond first.',
                  zhTW: '繼續上一窗口的對話，讓 TA 先自然回應',
                  zhCN: '继续上一窗口的对话，让 TA 先自然回应',
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 176),
                  child: OutlinedButton(
                    onPressed: _continuePreviousRpChapter,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(176, 48),
                      foregroundColor: YanciTheme.textPrimary.withValues(
                        alpha: 0.82,
                      ),
                      side: BorderSide(
                        color: YanciTheme.accent.withValues(alpha: 0.30),
                        width: 0.8,
                      ),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 12,
                      ),
                    ),
                    child: Text(
                      L.pick(
                        en: 'Continue this conversation',
                        zhTW: '繼續這段對話',
                        zhCN: '继续这段对话',
                      ),
                      textAlign: TextAlign.center,
                      style: YanciTheme.bodyText.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'Let them respond first',
                  zhTW: '讓 TA 先自然回應',
                  zhCN: '让 TA 先自然回应',
                ),
                textAlign: TextAlign.center,
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.58),
                  height: 1.35,
                ),
              ),
            ],
            if (showRpChapterChoices) ...<Widget>[
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 190),
                child: OutlinedButton(
                  key: const ValueKey('rp-continue-chapter-action'),
                  onPressed: hasMultipleRpStorylines
                      ? _selectCurrentRpChapter
                      : _continuePreviousRpChapter,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(190, 48),
                    foregroundColor: YanciTheme.textPrimary.withValues(
                      alpha: 0.84,
                    ),
                    side: BorderSide(
                      color: YanciTheme.accent.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    L.pick(
                      en: hasMultipleRpStorylines
                          ? 'Choose current chapter'
                          : 'Continue this chapter',
                      zhTW: hasMultipleRpStorylines ? '選擇當前篇章' : '繼續這一篇章',
                      zhCN: hasMultipleRpStorylines ? '选择当前篇章' : '继续这一篇章',
                    ),
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 190),
                child: TextButton(
                  key: const ValueKey('rp-open-new-chapter-action'),
                  onPressed: _openNewRpChapter,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(190, 44),
                    foregroundColor: YanciTheme.accent.withValues(alpha: 0.82),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 10,
                    ),
                  ),
                  child: Text(
                    L.pick(
                      en: 'Open a new chapter',
                      zhTW: '開啟新篇章',
                      zhCN: '开启新篇章',
                    ),
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
