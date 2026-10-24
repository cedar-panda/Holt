part of 'theme_workshop_screen.dart';

extension _ThemeWorkshopBackgroundPreview on _ThemeWorkshopScreenState {
  /// Pixel 風格的單張預覽卡片（用在彈窗上部 2/3）
  Widget _bgDialogPreview({
    required String scope,
    required String label,
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    required double blur,
    required bool selected,
    required double width,
    required double height,
    required VoidCallback onTap,
    required VoidCallback onAdd,
    required Widget overlay,
  }) {
    final fileExists = path.isNotEmpty && File(path).existsSync();
    return GestureDetector(
      key: ValueKey('background-$scope-preview'),
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: selected ? 1.0 : 0.5,
        duration: const Duration(milliseconds: 200),
        child: AnimatedScale(
          scale: selected ? 1.0 : 0.92,
          duration: const Duration(milliseconds: 200),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                // 標籤
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? YanciTheme.accent
                          : YanciTheme.textSecondary,
                    ),
                  ),
                ),
                // 手機預覽框
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _backgroundPreviewCanvas(
                          path: path,
                          scale: scale,
                          offsetX: offsetX,
                          offsetY: offsetY,
                          blur: blur,
                          fileExists: fileExists,
                          overlay: overlay,
                        ),
                        // 選中邊框
                        if (selected)
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: YanciTheme.accent.withValues(alpha: 0.6),
                                width: 2,
                              ),
                            ),
                          ),
                        // 中心 + 按鈕（加圖片）
                        if (!fileExists)
                          Center(
                            child: GestureDetector(
                              onTap: onAdd,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.15,
                                  ),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.4,
                                    ),
                                    width: 1,
                                  ),
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  size: 20,
                                  color: YanciTheme.accent,
                                ),
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
        ),
      ),
    );
  }

  /// 無邊框無底色的可收起區塊（用在彈窗下部 1/3）
  Widget _bgDialogCollapsible({
    Key? key,
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Column(
      key: key,
      children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: child,
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  Widget _backgroundPreviewCanvas({
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    double blur = 0,
    required bool fileExists,
    required Widget overlay,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: YanciTheme.backgroundGradient,
              ),
            ),
          ),
          if (fileExists)
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: blur.clamp(0.0, 20.0).toDouble(),
                sigmaY: blur.clamp(0.0, 20.0).toDouble(),
                tileMode: TileMode.clamp,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Transform.translate(
                  offset: Offset(
                    offsetX.clamp(-0.5, 0.5).toDouble() * constraints.maxWidth,
                    offsetY.clamp(-0.5, 0.5).toDouble() * constraints.maxHeight,
                  ),
                  child: Transform.scale(
                    scale: scale.clamp(0.8, 2.0).toDouble(),
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                      gaplessPlayback: true,
                      isAntiAlias: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          if (!fileExists)
            Center(
              child: Icon(
                Icons.image_outlined,
                color: YanciTheme.textSecondary.withValues(alpha: 0.35),
              ),
            ),
          overlay,
        ],
      ),
    );
  }

  Widget _buildPortraitHomePreview() {
    return Stack(
      children: [
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Container(
            height: 18,
            decoration: BoxDecoration(
              color: YanciTheme.glassWhite.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(9),
            ),
          ),
        ),
        Positioned(
          bottom: 12,
          left: 12,
          right: 28,
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              color: YanciTheme.aiBubble.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(13),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitChatPreview() {
    final thinkingColor = _chatBackgroundColor(
      _ChatBackgroundColorRole.thinkingText,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 3),
          // Thinking 提示
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              'Thinking  ›',
              style: TextStyle(fontSize: 6.5, color: thinkingColor),
            ),
          ),
          // AI 氣泡（左對齊，左下角小圓角）
          Align(
            alignment: Alignment.centerLeft,
            child: _miniPreviewBubble(
              color: _chatBackgroundColor(_ChatBackgroundColorRole.aiBubble),
              textColor: _chatBackgroundColor(
                _ChatBackgroundColorRole.bubbleText,
              ),
              borderColor: YanciTheme.aiBubbleBorder,
              text: L.get('theme_preview_hi'),
              isUser: false,
            ),
          ),
          const SizedBox(height: 8),
          // 用戶氣泡（右對齊，右下角小圓角）
          Align(
            alignment: Alignment.centerRight,
            child: _miniPreviewBubble(
              color: _chatBackgroundColor(_ChatBackgroundColorRole.userBubble),
              textColor: _chatBackgroundColor(
                _ChatBackgroundColorRole.bubbleText,
              ),
              borderColor: YanciTheme.userBubbleBorder,
              text: L.get('theme_preview_reply'),
              isUser: true,
            ),
          ),
          const Spacer(flex: 5),
        ],
      ),
    );
  }

  Widget _miniPreviewBubble({
    required Color color,
    required Color textColor,
    required Color borderColor,
    required String text,
    required bool isUser,
  }) {
    final flat = !isUser && _aiBubbleFlat;
    return Container(
      constraints: BoxConstraints(maxWidth: flat ? 120 : 84),
      padding: EdgeInsets.symmetric(
        horizontal: flat ? 2 : 7,
        vertical: flat ? 3 : 5,
      ),
      decoration: flat
          ? null
          : BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: borderColor.withValues(alpha: 0.5),
                width: 0.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.16 : 0.04,
                  ),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
      child: Text(
        text,
        key: ValueKey(
          isUser
              ? 'chat-portrait-preview-user-text'
              : 'chat-portrait-preview-ai-text',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 6.5,
          color: textColor,
          fontFamily: YanciTheme.fontFamily,
        ),
      ),
    );
  }

  Widget _buildChatBackgroundColorPreview({
    required String path,
    required double scale,
    required double offsetX,
    required double offsetY,
    required bool fileExists,
  }) {
    final thinkingColor = _chatBackgroundColor(
      _ChatBackgroundColorRole.thinkingText,
    );
    return SizedBox(
      key: const ValueKey('chat-background-color-preview'),
      height: 178,
      width: double.infinity,
      child: _backgroundPreviewCanvas(
        path: path,
        scale: scale,
        offsetX: offsetX,
        offsetY: offsetY,
        fileExists: fileExists,
        overlay: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thinking 提示行
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 10,
                    color: thinkingColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Thinking  ›  Memory · Mood',
                    style: TextStyle(
                      fontSize: 11,
                      color: thinkingColor,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // AI 氣泡（左對齊，左下角尖）
              Align(
                alignment: Alignment.centerLeft,
                child: _colorPreviewBubble(
                  color: _chatBackgroundColor(
                    _ChatBackgroundColorRole.aiBubble,
                  ),
                  textColor: _chatBackgroundColor(
                    _ChatBackgroundColorRole.bubbleText,
                  ),
                  borderColor: YanciTheme.aiBubbleBorder,
                  text: L.get('theme_preview_hi'),
                  isUser: false,
                ),
              ),
              const Spacer(),
              // 用戶氣泡（右對齊，右下角尖）
              Align(
                alignment: Alignment.centerRight,
                child: _colorPreviewBubble(
                  color: _chatBackgroundColor(
                    _ChatBackgroundColorRole.userBubble,
                  ),
                  textColor: _chatBackgroundColor(
                    _ChatBackgroundColorRole.bubbleText,
                  ),
                  borderColor: YanciTheme.userBubbleBorder,
                  text: L.get('theme_preview_reply'),
                  isUser: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorPreviewBubble({
    required Color color,
    required Color textColor,
    required Color borderColor,
    required String text,
    required bool isUser,
  }) {
    final flat = !isUser && _aiBubbleFlat;
    return Container(
      constraints: BoxConstraints(maxWidth: flat ? 260 : 200),
      padding: EdgeInsets.symmetric(
        horizontal: flat ? 4 : 12,
        vertical: flat ? 4 : 8,
      ),
      decoration: flat
          ? null
          : BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: borderColor.withValues(alpha: 0.5),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: YanciTheme.isDark ? 0.18 : 0.05,
                  ),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
      child: Text(
        text,
        key: ValueKey(
          isUser
              ? 'chat-color-preview-user-text'
              : 'chat-color-preview-ai-text',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: YanciTheme.bodyText.copyWith(fontSize: 12, color: textColor),
      ),
    );
  }

  Widget _chatBackgroundColorRow({
    required _ChatBackgroundColorRole role,
    required String label,
    required StateSetter setSheetState,
  }) {
    final color = _chatBackgroundColor(role);
    final hasOverride = _chatBackgroundColorOverride(role) != null;
    final isText =
        role == _ChatBackgroundColorRole.thinkingText ||
        role == _ChatBackgroundColorRole.bubbleText;
    final isUser = role == _ChatBackgroundColorRole.userBubble;
    // 氣泡型色塊 / 文字色條
    Widget colorChip;
    if (isText) {
      // Thinking 顏色 → 用文字預覽取代色塊
      colorChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              role == _ChatBackgroundColorRole.thinkingText
                  ? Icons.auto_awesome
                  : Icons.text_fields_rounded,
              size: 11,
              color: color.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
            Text(
              role == _ChatBackgroundColorRole.thinkingText ? 'Thinking' : 'Aa',
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontFamily: YanciTheme.fontFamily,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    } else {
      // 氣泡顏色 → 用 mini bubble 形狀預覽
      colorChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color:
                (isUser
                        ? YanciTheme.userBubbleBorder
                        : YanciTheme.aiBubbleBorder)
                    .withValues(alpha: 0.5),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: YanciTheme.isDark ? 0.12 : 0.04,
              ),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          isUser ? 'Hi' : 'Hello',
          style: TextStyle(
            fontSize: 10,
            color: YanciTheme.textOnBubble,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: label,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pickChatBackgroundColor(role, label, setSheetState),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    colorChip,
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: YanciTheme.textPrimary,
                          ),
                        ),
                        Text(
                          '#${_colorToHex(color)}',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          if (hasOverride)
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                key: ValueKey('chat-background-${role.name}-reset'),
                tooltip: L.pick(en: 'Use theme default', zhTW: '恢復主題預設'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await _saveChatBackgroundColor(role, null);
                  setSheetState(() {});
                },
                icon: Icon(
                  Icons.restart_alt_rounded,
                  size: 16,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatBackgroundOpacityControl(StateSetter setSheetState) {
    final opacity = _chatBackgroundBubbleOpacity;
    final hasOverride = _chatBgBubbleOpacity != null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(en: 'Bubble opacity', zhTW: '氣泡透明度', zhCN: '气泡透明度'),
            style: YanciTheme.bodyText.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Slider(
                  key: const ValueKey('chat-background-bubble-opacity'),
                  value: opacity.clamp(0.0, 1.0),
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  onChanged: (value) {
                    setSheetState(() => _chatBgBubbleOpacity = value);
                    YanciTheme.chatBackgroundBubbleOpacityOverride = value;
                    _notifyThemeChanged();
                  },
                  onChangeEnd: (value) =>
                      _saveChatBackgroundBubbleOpacity(value),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${(opacity * 100).round()}%',
                  key: const ValueKey('chat-background-bubble-opacity-value'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.accent,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('chat-background-bubble-opacity-reset'),
                tooltip: L.pick(en: 'Use theme default', zhTW: '恢復主題預設'),
                visualDensity: VisualDensity.compact,
                onPressed: hasOverride
                    ? () async {
                        await _saveChatBackgroundBubbleOpacity(null);
                        setSheetState(() {});
                      }
                    : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _offsetDisplay(double value, {required Axis axis}) {
    final pct = (value * 100).round();
    if (pct == 0) return '0%';
    if (L.locale == 'en') return '${pct > 0 ? '+' : ''}$pct%';
    if (axis == Axis.horizontal) {
      return pct > 0
          ? L.pick(en: 'Right $pct%', zhTW: '右$pct%')
          : L.pick(en: 'Left ${pct.abs()}%', zhTW: '左${pct.abs()}%');
    }
    return pct > 0
        ? L.pick(en: 'Down $pct%', zhTW: '下$pct%')
        : L.pick(en: 'Up ${pct.abs()}%', zhTW: '上${pct.abs()}%');
  }
}
