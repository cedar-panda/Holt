// ignore_for_file: invalid_use_of_protected_member

part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopBackgroundPage on _ThemeWorkshopScreenState {
  Future<void> _openBackgroundPage() async {
    var selectedScope = 'home'; // 'home' or 'chat'
    var homePositionExpanded = false;
    var chatPositionExpanded = false;
    var chatColorsExpanded = false;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setPageState) {
            final isHome = selectedScope == 'home';
            final activePath = isHome ? _homeBgPath : _chatBgPath;
            final activeScale = isHome ? _homeBgScale : _chatBgScale;
            final activeOffsetX = isHome ? _homeBgOffsetX : _chatBgOffsetX;
            final activeOffsetY = isHome ? _homeBgOffsetY : _chatBgOffsetY;
            final activeBlur = isHome ? _homeBgBlur : _chatBgBlur;
            final activeFileExists =
                activePath.isNotEmpty && File(activePath).existsSync();
            final positionExpanded = isHome
                ? homePositionExpanded
                : chatPositionExpanded;

            return Scaffold(
              body: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: YanciTheme.backgroundGradient,
                  ),
                ),
                child: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: L.pick(en: 'Back', zhTW: '返回'),
                                  icon: Icon(
                                    Icons.arrow_back_ios_rounded,
                                    size: 20,
                                    color: YanciTheme.textPrimary,
                                  ),
                                  onPressed: () => Navigator.pop(ctx),
                                ),
                                Expanded(
                                  child: Text(
                                    L.pick(
                                      en: 'Background',
                                      zhTW: '背景',
                                      zhCN: '背景',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: YanciTheme.headingMedium,
                                  ),
                                ),
                                const SizedBox(width: 48),
                              ],
                            ),
                          ),

                          _buildBackgroundSlotSelector(setPageState),
                          _buildBackgroundCharacterBindingEntry(setPageState),

                          // 上方雙預覽；選中項決定下方正在編輯的背景。
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                              child: LayoutBuilder(
                                builder: (ctx, constraints) {
                                  final previewW =
                                      (constraints.maxWidth - 12) / 2;
                                  final previewH = constraints.maxHeight;
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _bgDialogPreview(
                                        scope: 'home',
                                        label: L.pick(en: 'Home', zhTW: '首頁'),
                                        path: _homeBgPath,
                                        scale: _homeBgScale,
                                        offsetX: _homeBgOffsetX,
                                        offsetY: _homeBgOffsetY,
                                        blur: _homeBgBlur,
                                        selected: isHome,
                                        width: previewW,
                                        height: previewH,
                                        onTap: () => setPageState(
                                          () => selectedScope = 'home',
                                        ),
                                        onAdd: () => _pickBackgroundImage(
                                          'home',
                                          setPageState,
                                        ),
                                        overlay: _buildPortraitHomePreview(),
                                      ),
                                      const SizedBox(width: 12),
                                      _bgDialogPreview(
                                        scope: 'chat',
                                        label: L.pick(en: 'Chat', zhTW: '對話框'),
                                        path: _chatBgPath,
                                        scale: _chatBgScale,
                                        offsetX: _chatBgOffsetX,
                                        offsetY: _chatBgOffsetY,
                                        blur: _chatBgBlur,
                                        selected: !isHome,
                                        width: previewW,
                                        height: previewH,
                                        onTap: () => setPageState(
                                          () => selectedScope = 'chat',
                                        ),
                                        onAdd: () => _pickBackgroundImage(
                                          'chat',
                                          setPageState,
                                        ),
                                        overlay: _buildPortraitChatPreview(),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),

                          _buildCallBackgroundSelection(
                            selectedScope: selectedScope,
                            selectedPath: isHome ? _homeBgPath : _chatBgPath,
                            setPageState: setPageState,
                          ),

                          Expanded(
                            flex: 2,
                            child: Stack(
                              children: [
                                ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    4,
                                    24,
                                    24,
                                  ),
                                  children: [
                                    _bgDialogCollapsible(
                                      key: ValueKey(
                                        'background-$selectedScope-position-section',
                                      ),
                                      title: L.pick(
                                        en: 'Image position',
                                        zhTW: '圖片位置微調',
                                      ),
                                      expanded: positionExpanded,
                                      onToggle: () => setPageState(() {
                                        if (isHome) {
                                          homePositionExpanded =
                                              !homePositionExpanded;
                                        } else {
                                          chatPositionExpanded =
                                              !chatPositionExpanded;
                                        }
                                      }),
                                      child: Column(
                                        children: [
                                          _slider(
                                            L.pick(en: 'Scale', zhTW: '大小'),
                                            activeScale,
                                            0.8,
                                            2.0,
                                            12,
                                            '${(activeScale * 100).round()}%',
                                            (v) => _setBackgroundScale(
                                              selectedScope,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(en: 'X', zhTW: '左右'),
                                            activeOffsetX,
                                            -0.5,
                                            0.5,
                                            20,
                                            _offsetDisplay(
                                              activeOffsetX,
                                              axis: Axis.horizontal,
                                            ),
                                            (v) => _setBackgroundOffset(
                                              selectedScope,
                                              v,
                                              activeOffsetY,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(en: 'Y', zhTW: '上下'),
                                            activeOffsetY,
                                            -0.5,
                                            0.5,
                                            20,
                                            _offsetDisplay(
                                              activeOffsetY,
                                              axis: Axis.vertical,
                                            ),
                                            (v) => _setBackgroundOffset(
                                              selectedScope,
                                              activeOffsetX,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                          _slider(
                                            L.pick(
                                              en: 'Blur',
                                              zhTW: '模糊度',
                                              zhCN: '模糊度',
                                            ),
                                            activeBlur,
                                            0.0,
                                            20.0,
                                            20,
                                            activeBlur == 0
                                                ? L.pick(
                                                    en: 'Off',
                                                    zhTW: '關閉',
                                                    zhCN: '关闭',
                                                  )
                                                : activeBlur.round().toString(),
                                            (v) => _setBackgroundBlur(
                                              selectedScope,
                                              v,
                                              setPageState,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    if (!isHome)
                                      _bgDialogCollapsible(
                                        key: const ValueKey(
                                          'background-chat-colors-section',
                                        ),
                                        title: L.pick(
                                          en: 'Text & bubble colors',
                                          zhTW: '字體氣泡顏色',
                                        ),
                                        expanded: chatColorsExpanded,
                                        onToggle: () => setPageState(
                                          () => chatColorsExpanded =
                                              !chatColorsExpanded,
                                        ),
                                        child: Column(
                                          children: [
                                            _buildChatBackgroundColorPreview(
                                              path: _chatBgPath,
                                              scale: _chatBgScale,
                                              offsetX: _chatBgOffsetX,
                                              offsetY: _chatBgOffsetY,
                                              fileExists:
                                                  _chatBgPath.isNotEmpty &&
                                                  File(
                                                    _chatBgPath,
                                                  ).existsSync(),
                                            ),
                                            const SizedBox(height: 10),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .aiBubble,
                                              label: L.pick(
                                                en: 'Character bubble',
                                                zhTW: '角色氣泡',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .userBubble,
                                              label: L.pick(
                                                en: 'User bubble',
                                                zhTW: '用戶氣泡',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .bubbleText,
                                              label: L.pick(
                                                en: 'Bubble text',
                                                zhTW: '氣泡內字體顏色',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundColorRow(
                                              role: _ChatBackgroundColorRole
                                                  .thinkingText,
                                              label: L.pick(
                                                en: 'Thinking text',
                                                zhTW: 'Thinking 字體顏色',
                                              ),
                                              setSheetState: setPageState,
                                            ),
                                            _chatBackgroundOpacityControl(
                                              setPageState,
                                            ),
                                          ],
                                        ),
                                      ),

                                    if (activeFileExists)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: TextButton.icon(
                                          onPressed: () =>
                                              _clearBackgroundImage(
                                                selectedScope,
                                                setPageState,
                                              ),
                                          icon: Icon(
                                            Icons.delete_outline_rounded,
                                            size: 16,
                                            color: YanciTheme.textSecondary
                                                .withValues(alpha: 0.7),
                                          ),
                                          label: Text(
                                            L.pick(
                                              en: 'Remove image',
                                              zhTW: '刪除圖片',
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.7),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (!isHome && chatColorsExpanded)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 4,
                                    child: Center(
                                      child: _AlternatingDoubleChevronHint(
                                        color: YanciTheme.textSecondary,
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
          },
        ),
      ),
    );

    if (mounted) setState(() {});
  }

  Widget _buildBackgroundSlotSelector(StateSetter setPageState) {
    return SizedBox(
      height: 48,
      child: Row(
        key: const ValueKey('background-preset-slots'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(BackgroundPresetService.slotCount, (
          index,
        ) {
          final slot = index + 1;
          final selected = slot == _backgroundSlot;
          final label = L.pick(
            en: 'Background set $slot',
            zhTW: '背景套組 $slot',
            zhCN: '背景套组 $slot',
          );
          return Semantics(
            button: true,
            selected: selected,
            label: label,
            child: Tooltip(
              message: label,
              child: InkResponse(
                key: ValueKey('background-preset-slot-$slot'),
                radius: 22,
                onTap: () => _selectBackgroundSlot(slot, setPageState),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.34,
                                ),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        '$slot',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selected
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(
                                  alpha: 0.72,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBackgroundCharacterBindingEntry(StateSetter setPageState) {
    final count = _backgroundBindings.values
        .where((slot) => slot == _backgroundSlot)
        .length;
    final detail = count == 0
        ? L.pick(
            en: 'No characters use set $_backgroundSlot',
            zhTW: '第 $_backgroundSlot 套尚未綁定角色',
            zhCN: '第 $_backgroundSlot 套尚未绑定角色',
          )
        : L.pick(
            en: '$count characters use set $_backgroundSlot',
            zhTW: '第 $_backgroundSlot 套 · 已綁定 $count 位角色',
            zhCN: '第 $_backgroundSlot 套 · 已绑定 $count 位角色',
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: Semantics(
        button: true,
        label: L.pick(
          en: 'Bind characters to background set $_backgroundSlot',
          zhTW: '為背景套組 $_backgroundSlot 綁定角色',
          zhCN: '为背景套组 $_backgroundSlot 绑定角色',
        ),
        child: InkWell(
          key: const ValueKey('background-preset-character-binding'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openBackgroundCharacterBindings(setPageState),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.pick(
                            en: 'Bind characters',
                            zhTW: '綁定角色',
                            zhCN: '绑定角色',
                          ),
                          style: TextStyle(
                            color: YanciTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.66,
                            ),
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.42),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBackgroundCharacterBindings(
    StateSetter setPageState,
  ) async {
    final characters = await DatabaseHelper.getCharacters();
    final bindings = Map<String, int>.from(
      await BackgroundPresetService.getCharacterBindings(),
    );
    if (!mounted) return;
    final slot = _backgroundSlot;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return SafeArea(
            top: false,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
              ),
              decoration: BoxDecoration(
                color: YanciTheme.backgroundGradient.last,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border(
                  top: BorderSide(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.16),
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 34,
                    height: 3,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            L.pick(
                              en: 'Set $slot · Bind characters',
                              zhTW: '第 $slot 套 · 綁定角色',
                              zhCN: '第 $slot 套 · 绑定角色',
                            ),
                            style: YanciTheme.headingMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
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
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        L.pick(
                          en: 'Selected characters use this set on Home and in chat.',
                          zhTW: '選中的角色會在首頁與對話框使用這套背景。',
                          zhCN: '选中的角色会在首页与对话框使用这套背景。',
                        ),
                        style: TextStyle(
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.72,
                          ),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  Flexible(
                    child: characters.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                L.pick(
                                  en: 'No characters yet',
                                  zhTW: '目前還沒有角色',
                                  zhCN: '目前还没有角色',
                                ),
                                style: YanciTheme.bodySmall,
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                            itemCount: characters.length,
                            itemBuilder: (context, index) {
                              final character = characters[index];
                              final id = (character['id'] as String?) ?? '';
                              final name = (character['name'] as String?)
                                  ?.trim();
                              final avatarPath =
                                  (character['avatar_path'] as String?) ?? '';
                              final avatarFile = avatarPath.isEmpty
                                  ? null
                                  : File(avatarPath);
                              final selected = bindings[id] == slot;
                              final otherSlot = bindings[id];
                              final subtitle = !selected && otherSlot != null
                                  ? L.pick(
                                      en: 'Currently uses set $otherSlot',
                                      zhTW: '目前使用第 $otherSlot 套',
                                      zhCN: '目前使用第 $otherSlot 套',
                                    )
                                  : null;
                              return CheckboxListTile(
                                key: ValueKey(
                                  'background-binding-character-$id',
                                ),
                                value: selected,
                                controlAffinity:
                                    ListTileControlAffinity.trailing,
                                activeColor: YanciTheme.accent,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                secondary: CircleAvatar(
                                  radius: 19,
                                  backgroundColor: YanciTheme.accent.withValues(
                                    alpha: 0.1,
                                  ),
                                  foregroundImage:
                                      avatarFile?.existsSync() ?? false
                                      ? FileImage(avatarFile!)
                                      : null,
                                  child: avatarFile?.existsSync() ?? false
                                      ? null
                                      : Icon(
                                          Icons.person_outline_rounded,
                                          size: 18,
                                          color: YanciTheme.textSecondary,
                                        ),
                                ),
                                title: Text(
                                  name?.isNotEmpty == true
                                      ? name!
                                      : L.pick(
                                          en: 'Unnamed character',
                                          zhTW: '未命名角色',
                                          zhCN: '未命名角色',
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: YanciTheme.textPrimary,
                                    fontSize: 13,
                                  ),
                                ),
                                subtitle: subtitle == null
                                    ? null
                                    : Text(
                                        subtitle,
                                        style: TextStyle(
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.62),
                                          fontSize: 10.5,
                                        ),
                                      ),
                                onChanged: (_) async {
                                  HapticFeedback.selectionClick();
                                  await BackgroundPresetService.setCharacterBinding(
                                    id,
                                    selected ? null : slot,
                                  );
                                  if (!mounted || !sheetContext.mounted) {
                                    return;
                                  }
                                  if (selected) {
                                    bindings.remove(id);
                                  } else {
                                    bindings[id] = slot;
                                  }
                                  _backgroundBindings = Map<String, int>.from(
                                    bindings,
                                  );
                                  setSheetState(() {});
                                  setPageState(() {});
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
