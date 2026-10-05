part of 'home_screen.dart';

const bool _showDeveloperDiagnostics = bool.fromEnvironment(
  'HOLT_ENABLE_DEVELOPER_DIAGNOSTICS',
  defaultValue:
      !bool.fromEnvironment('dart.vm.product') &&
      !bool.fromEnvironment('dart.vm.profile'),
);

extension _HomeProfileMethods on _HomeScreenState {
  void _openSelectedPersonaFile() {
    final personaId = _selectedUserPersona?.id;
    unawaited(() async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserProfileScreen(personaId: personaId),
        ),
      );
      if (!mounted) return;
      await _loadPersonaShelf();
      await _loadLatestNote();
    }());
  }

  void _createUserPersona() {
    showThemedPillNotice(
      context,
      L.pick(
        en: 'This will add a new identity',
        zhTW: '這將新增你的身分',
        zhCN: '这将新增你的身份',
      ),
    );
    unawaited(() async {
      final persona = await UserPersonaService.createPersona();
      await UserPersonaService.selectPersona(persona.id);
      if (!mounted) return;
      _setUserPersonaCreateSlot(false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserProfileScreen(personaId: persona.id),
        ),
      );
      if (!mounted) return;
      await _loadPersonaShelf();
      await _loadLatestNote();
    }());
  }

  void _openAnniversaryPanel() {
    final persona = _selectedUserPersona;
    if (persona == null || _userPersonaCreateSlotSelected) return;
    unawaited(() async {
      final changed = await showAnniversaryPanel(
        context,
        userPersonaId: persona.id,
        characterId: _anniversaryCharacterId ?? _activeCharacterId,
      );
      if (!mounted || !changed) return;
      await _loadPersonaShelf();
    }());
  }

  Widget _buildGridTile({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    Widget? customIcon,
    double? height,
    bool isSecondary = false,
    Color? iconColor,
    bool glowIcon = false,
    bool hideText = false,
    Color? imagePrimaryForeground,
    Color? imageSecondaryForeground,
  }) {
    final effectiveAccent =
        iconColor ??
        imageSecondaryForeground ??
        (isSecondary
            ? YanciTheme.accent.withValues(alpha: 0.45)
            : YanciTheme.accent);

    final iconSize = hideText ? 32.0 : (isSecondary ? 28.0 : 34.0);
    final fontSize = isSecondary ? 13.5 : 16.0;
    final fontWeight = isSecondary ? FontWeight.w500 : FontWeight.w600;
    final textColor = isSecondary
        ? imageSecondaryForeground ?? YanciTheme.textSecondary
        : imagePrimaryForeground ?? YanciTheme.textPrimary;

    final baseIcon =
        customIcon ?? Icon(icon, color: effectiveAccent, size: iconSize);

    final iconWidget = glowIcon && customIcon == null
        ? Stack(
            alignment: Alignment.center,
            children: [
              // 真實的光暈擴散層（非生硬的文字陰影）
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: Icon(
                  icon,
                  color: effectiveAccent.withValues(alpha: 0.65),
                  size: iconSize,
                ),
              ),
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Icon(
                  icon,
                  color: effectiveAccent.withValues(alpha: 0.35),
                  size: iconSize,
                ),
              ),
              baseIcon,
            ],
          )
        : baseIcon;

    if (isSecondary && !hideText) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 34, child: Center(child: iconWidget)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 86,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      color: textColor,
                      fontFamily: YanciTheme.fontFamily,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isSecondary)
                iconWidget
              else if (hideText)
                iconWidget
              else ...[
                iconWidget,
                const SizedBox(width: 10),
              ],
              if (!hideText) ...[
                if (!isSecondary) const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    title,
                    maxLines: isSecondary ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: isSecondary ? TextAlign.left : TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      color: textColor,
                      fontFamily: YanciTheme.fontFamily,
                      height: isSecondary ? 1.2 : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplitGridTile({
    required IconData leftIcon,
    required VoidCallback leftOnTap,
    required IconData rightIcon,
    required VoidCallback rightOnTap,
    double? height,
    Color? imageSecondaryForeground,
  }) {
    final effectiveAccent =
        imageSecondaryForeground ?? YanciTheme.accent.withValues(alpha: 0.45);

    final iconSize = 32.0;

    return SizedBox(
      width: double.infinity,
      height: height,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: leftOnTap,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Icon(leftIcon, color: effectiveAccent, size: iconSize),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: rightOnTap,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Icon(rightIcon, color: effectiveAccent, size: iconSize),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSoftProfileDivider({
    bool dots = false,
    Color? imageSecondaryForeground,
  }) {
    final lineColor =
        imageSecondaryForeground?.withValues(alpha: 0.30) ??
        YanciTheme.textSecondary.withValues(alpha: 0.16);
    final accent = imageSecondaryForeground ?? YanciTheme.accent;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.transparent, lineColor]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: dots
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.34),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.52),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.34),
                      ),
                    ),
                  ],
                )
              : Icon(
                  Icons.auto_awesome,
                  size: 10,
                  color: accent.withValues(alpha: 0.36),
                ),
        ),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [lineColor, Colors.transparent]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProfilePage() {
    final lineAnniversaries = _anniversariesAt(AnniversaryPlacement.avatarLine);
    final belowAnniversaries = _anniversariesAt(
      AnniversaryPlacement.belowAvatars,
    );
    final imagePrimaryForeground = _homeForegroundPalette?.primary;
    final imageSecondaryForeground = _homeForegroundPalette?.secondary;
    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 24, right: 24, top: 0, bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Header (右上角與左上角工具按鈕)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 紀念日與日/夜模式入口對調：日/夜模式常駐，
                    // 即使窗口有背景圖片也不隱藏；背景綁定只影響窗口內容。
                    IconButton(
                      key: const ValueKey('open-anniversary-panel'),
                      tooltip: L.pick(
                        en: 'Anniversaries',
                        zhTW: '紀念日',
                        zhCN: '纪念日',
                      ),
                      onPressed:
                          _selectedUserPersona == null ||
                              _userPersonaCreateSlotSelected
                          ? null
                          : _openAnniversaryPanel,
                      icon: const Icon(Icons.calendar_month_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor:
                            imageSecondaryForeground ?? YanciTheme.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: YanciTheme.isDark
                          ? L.pick(en: 'Light Mode', zhTW: '日間模式', zhCN: '日间模式')
                          : L.pick(en: 'Dark Mode', zhTW: '夜間模式', zhCN: '夜间模式'),
                      onPressed: _toggleProfileThemeMode,
                      icon: Icon(
                        YanciTheme.isDark
                            ? Icons.light_mode_rounded
                            : Icons.dark_mode_rounded,
                        size: 22,
                      ),
                      style: IconButton.styleFrom(
                        foregroundColor:
                            imageSecondaryForeground ?? YanciTheme.accent,
                      ),
                    ),
                  ],
                ),
                // 右上角：備份與設定
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: L.get('me_backup_title'),
                      onPressed: () {
                        _showBackupSheet();
                      },
                      icon: const Icon(Icons.save_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor:
                            imageSecondaryForeground ?? YanciTheme.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: L.get('nav_settings'),
                      onPressed: () {
                        Navigator.of(context).pushNamed('/settings');
                      },
                      icon: const Icon(Icons.settings_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor:
                            imageSecondaryForeground ?? YanciTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 28),

            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_selectedUserPersona != null) ...[
                  Center(
                    child: _userPersonaCreateSlotSelected
                        ? UserPersonaCreateAvatar(
                            key: const ValueKey('persona-create-avatar'),
                            size: 84,
                            onTap: _createUserPersona,
                          )
                        : UserPersonaAvatarPair(
                            key: ValueKey(
                              'home-persona-pair-${_selectedUserPersona!.id}',
                            ),
                            persona: _selectedUserPersona!,
                            companion: _selectedPersonaCompanion,
                            showAddWhenUnbound: false,
                            connectionLabel: lineAnniversaries.isEmpty
                                ? null
                                : AnniversaryDayCounterGroup(
                                    entries: lineAnniversaries,
                                    compact: true,
                                    splitAroundLine: true,
                                  ),
                            size: 84,
                            onUserAvatarTap: () => _openSelectedPersonaFile(),
                            onBindingTap: () => _openSelectedPersonaFile(),
                          ),
                  ),
                  if (!_userPersonaCreateSlotSelected &&
                      belowAnniversaries.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    if (belowAnniversaries.length == 1)
                      AnniversaryDayCounter(entry: belowAnniversaries.first)
                    else
                      AnniversaryDayCounterGroup(entries: belowAnniversaries),
                  ],
                  // Keep the name and book-turn controls visually below the
                  // avatar composition instead of crowding its lower edge.
                  const SizedBox(height: 24),
                  UserPersonaSwitcher(
                    personas: _userPersonas,
                    selectedId: _selectedUserPersona!.id,
                    onSelected: (persona) =>
                        unawaited(_selectUserPersona(persona)),
                    onOpenProfile: _openSelectedPersonaFile,
                    onCreate: _createUserPersona,
                    createSlotSelected: _userPersonaCreateSlotSelected,
                    onCreateSlotChanged: _setUserPersonaCreateSlot,
                    hideName:
                        !_userPersonaCreateSlotSelected &&
                        _anniversaryDisplaySettings.hideUserName,
                    imagePrimaryForeground: imagePrimaryForeground,
                    imageSecondaryForeground: imageSecondaryForeground,
                  ),
                ] else
                  const SizedBox(height: 126),
              ],
            ),
            const SizedBox(height: 28),

            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 裝飾分割線
                _buildSoftProfileDivider(
                  imageSecondaryForeground: imageSecondaryForeground,
                ),
                const SizedBox(height: 24),

                // Profile 佔用原「開關」主入口；圖示沿用主入口尺寸規格。
                _buildGridTile(
                  title: L.pick(
                    en: 'Profile',
                    zhTW: '相處方式',
                    zhCN: '相处方式',
                  ),
                  icon: Icons.person_outline_rounded,
                  height: 76,
                  imagePrimaryForeground: imagePrimaryForeground,
                  imageSecondaryForeground: imageSecondaryForeground,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ProfileScreen(personaId: _selectedUserPersona?.id),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildGridTile(
                  title: L.pick(en: 'Theme Studio', zhTW: '主題工坊'),
                  icon: Icons.palette_outlined,
                  iconColor:
                      imageSecondaryForeground ??
                      HSLColor.fromColor(YanciTheme.accent)
                          .withSaturation(
                            (HSLColor.fromColor(
                              YanciTheme.accent,
                            ).saturation).clamp(0.5, 1.0),
                          )
                          .withLightness(0.62)
                          .toColor(),
                  glowIcon: true,
                  height: 76,
                  imagePrimaryForeground: imagePrimaryForeground,
                  imageSecondaryForeground: imageSecondaryForeground,
                  onTap: () async {
                    await Navigator.of(context).pushNamed('/theme_workshop');
                    if (!mounted) return;
                    await _refreshProfileTheme();
                  },
                ),
                const SizedBox(height: 26),

                // 裝飾分割線 (三個小點)
                _buildSoftProfileDivider(
                  dots: true,
                  imageSecondaryForeground: imageSecondaryForeground,
                ),
                const SizedBox(height: 24),

                Row(
                  children: [
                    Expanded(
                      child: _buildGridTile(
                        title: L.pick(en: 'Voice / Ringtone', zhTW: '語音/鈴聲'),
                        icon: Icons.record_voice_over_rounded,
                        height: 76,
                        isSecondary: true,
                        imagePrimaryForeground: imagePrimaryForeground,
                        imageSecondaryForeground: imageSecondaryForeground,
                        onTap: () =>
                            Navigator.of(context).pushNamed('/voice_call'),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildGridTile(
                        title: L.pick(
                          en: 'Preferences',
                          zhTW: '偏好設定',
                          zhCN: '偏好设置',
                        ),
                        icon: Icons.tune_rounded,
                        height: 76,
                        isSecondary: true,
                        imagePrimaryForeground: imagePrimaryForeground,
                        imageSecondaryForeground: imageSecondaryForeground,
                        onTap: () =>
                            Navigator.of(context).pushNamed('/cost_context'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // 附加應用 (Bottom Row)
                Row(
                  children: [
                    Expanded(
                      child: _buildGridTile(
                        title: L.pick(en: 'Tool API', zhTW: '工具 API'),
                        icon: Icons.build_circle_outlined,
                        height: 76,
                        isSecondary: true,
                        imagePrimaryForeground: imagePrimaryForeground,
                        imageSecondaryForeground: imageSecondaryForeground,
                        onTap: () =>
                            Navigator.of(context).pushNamed('/tool_model'),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildGridTile(
                        title: L.pick(en: 'My Stickers', zhTW: '我的表情'),
                        icon: Icons.emoji_emotions_outlined,
                        height: 76,
                        isSecondary: true,
                        imagePrimaryForeground: imagePrimaryForeground,
                        imageSecondaryForeground: imageSecondaryForeground,
                        onTap: () => Navigator.of(
                          context,
                        ).pushNamed('/sticker', arguments: 'user'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // 商店與背包
                if (_shopEnabled)
                  _buildSplitGridTile(
                    leftIcon: Icons.storefront_outlined,
                    leftOnTap: () => _showShopBottomSheet(context),
                    rightIcon: Icons.backpack_outlined,
                    rightOnTap: () => _showBackpackBottomSheet(context, 'user'),
                    height: 76,
                    imageSecondaryForeground: imageSecondaryForeground,
                  ),
                if (_showDeveloperDiagnostics) ...[
                  const SizedBox(height: 28),
                  GestureDetector(
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed('/developer_diagnostics'),
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      height: 60,
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.bug_report_outlined,
                              color:
                                  imageSecondaryForeground ?? YanciTheme.accent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'DeBug',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color:
                                    imagePrimaryForeground ??
                                    YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 48), // Bottom padding
          ],
        ),
      ),
    );
  }

  Future<void> _handleImportBackup() async {
    if (!mounted) return;

    // 使用系統文件選擇器（跨平台：Android / iOS / macOS 均可用）
    // FileType.any：custom+['json'] 在 Android SAF 下常因 MIME 誤判
    // （json 被標 octet-stream）導致備份檔灰色不可選——「搜不到」的真兇。
    // 檔案合法性由 importFromJson 的 type/version 驗證兜底。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      withReadStream: false,
    );

    if (result == null || result.files.isEmpty) return;
    final filePath = result.files.single.path;
    if (filePath == null || filePath.isEmpty) return;

    // 確認導入
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF1E1E2E)
            : Colors.white,
        title: Text(
          L.pick(en: '⚠️ Confirm import', zhTW: '⚠️ 確認導入'),
          style: TextStyle(
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        content: Text(
          L.pick(
            en: 'Importing will overwrite existing data. Continue?',
            zhTW: '導入將覆蓋現有數據，確定要繼續嗎？',
          ),
          style: TextStyle(
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Import', zhTW: '確認導入'),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final selectedFile = File(filePath);
    if (!await selectedFile.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.pick(en: 'Backup file not found.', zhTW: '找不到備份檔。')),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final isEncrypted = await BackupService.isEncryptedBackup(filePath);
    String? password;
    if (isEncrypted) {
      password = await _promptBackupPassword(confirmPassword: false);
      if (password == null || !mounted) return;
    }
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const OrbitLoadingIndicator(size: 16, color: Colors.white),
            const SizedBox(width: 12),
            Text(
              L.get('backup_importing'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
      ),
    );

    try {
      final header = await selectedFile.openRead(0, 4).first;
      final isZip =
          header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;
      final result = isEncrypted
          ? await BackupService.importEncryptedPortableBundle(
              path: filePath,
              password: password!,
            )
          : isZip
          ? await BackupService.importPortableBundle(filePath)
          : await BackupService.importFromJson(
              jsonDecode(await selectedFile.readAsString())
                  as Map<String, dynamic>,
            );
      await _reloadHomeAfterRestore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_import_done', [result])),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_error', [e.toString()])),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    }
  }

  Future<void> _handleExternalChatImport() async {
    if (!mounted) return;
    final result = await FilePicker.platform.pickFiles(
      // Android providers often expose JSON as application/octet-stream.
      // Let the parser validate the file instead of greying it out.
      type: FileType.any,
      withData: false,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null || path.trim().isEmpty) {
      showThemedPillNotice(
        context,
        L.pick(
          en: 'This file is not available to the app.',
          zhTW: 'App 無法存取這個檔案。',
          zhCN: 'App 无法访问这个文件。',
        ),
      );
      return;
    }
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExternalChatImportScreen(filePath: path),
      ),
    );
    if (imported == true && mounted) await _reloadHomeAfterRestore();
  }

  Future<void> _handleExportBackup(_BackupExportMode mode) async {
    if (!mounted || _backupExportRunning) return;
    final password = await _promptBackupPassword(confirmPassword: true);
    if (password == null || !mounted) return;
    _backupExportRunning = true;
    String? artifactPath;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const OrbitLoadingIndicator(size: 16, color: Colors.white),
            const SizedBox(width: 12),
            Text(
              L.get('backup_exporting'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(minutes: 5),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
      ),
    );
    try {
      artifactPath = await BackupService.exportPortableBundle(
        password: password,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final completed = mode == _BackupExportMode.save
          ? await _saveExportedBackup(artifactPath)
          : await _shareExportedBackup(artifactPath);
      if (!completed) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.get(
              mode == _BackupExportMode.save ? 'backup_saved' : 'backup_shared',
            ),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_error', [e.toString()])),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } finally {
      _backupExportRunning = false;
      if (artifactPath != null) {
        try {
          await BackupService.discardExportArtifact(artifactPath);
        } catch (error) {
          debugPrint('Export artifact cleanup failed (${error.runtimeType})');
        }
      }
    }
  }

  Future<String?> _promptBackupPassword({required bool confirmPassword}) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _BackupPasswordDialog(confirmPassword: confirmPassword),
    );
  }

  Future<bool> _saveExportedBackup(String path) async {
    final file = File(path);
    final fileName = p.basename(path);
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (Platform.isAndroid) {
      final uri = await DeviceFileSaver.saveAndroidFile(
        sourcePath: path,
        suggestedName: fileName,
        mimeType: 'application/octet-stream',
      );
      return uri != null;
    }

    final savedTo = await FilePicker.platform.saveFile(
      dialogTitle: L.pick(en: 'Save backup', zhTW: '保存備份檔'),
      fileName: fileName,
      bytes: isMobile ? await file.readAsBytes() : null,
    );
    if (savedTo == null) return false;
    if (!isMobile && p.normalize(savedTo) != p.normalize(path)) {
      await file.copy(savedTo);
    }
    return true;
  }

  Future<bool> _shareExportedBackup(String path) async {
    final fileName = p.basename(path);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(path, mimeType: 'application/octet-stream')],
        fileNameOverrides: <String>[fileName],
        title: L.pick(en: 'Share Holt backup', zhTW: '分享 Holt 備份'),
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }

  Future<void> _confirmDeleteLegacyExports(LegacyExportStats stats) async {
    if (!mounted || stats.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF1E1E2E)
            : Colors.white,
        title: Text(
          L.get('backup_cleanup_confirm_title'),
          style: TextStyle(
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        content: Text(
          L.fmt('backup_cleanup_confirm_body', [
            stats.fileCount,
            _formatByteSize(stats.totalBytes),
          ]),
          style: TextStyle(
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              L.get('confirm_delete'),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final removed = await BackupService.deleteLegacyExports();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.fmt('backup_cleanup_done', [
              removed.fileCount,
              _formatByteSize(removed.totalBytes),
            ]),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_error', [error.toString()])),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
    }
  }

  String _formatByteSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
    final mib = kib / 1024;
    if (mib < 1024) return '${mib.toStringAsFixed(1)} MiB';
    return '${(mib / 1024).toStringAsFixed(2)} GiB';
  }

  Future<void> _showBackupSheet() async {
    await _refreshLastBackupTime();
    if (!mounted) return;
    final legacyStats = await BackupService.getLegacyExportStats();
    if (!mounted) return;
    final action = await showModalBottomSheet<_BackupSheetAction>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Container(
              decoration: BoxDecoration(
                color: YanciTheme.isDark
                    ? const Color(0xF0252228)
                    : Colors.white.withValues(alpha: 0.97),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YanciTheme.radiusLg),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(
                        Icons.save_outlined,
                        size: 20,
                        color: YanciTheme.accent,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        L.get('me_backup_title'),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: YanciTheme.textPrimary,
                          fontFamily: YanciTheme.fontFamily,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => showDialog<void>(
                          context: sheetContext,
                          builder: (dialogContext) => AlertDialog(
                            title: Text(L.get('me_backup_auto_title')),
                            content: Text(
                              '${L.get('me_backup_auto_sub')}\n\n'
                              '${L.fmt('me_backup_last', [_formatBackupTime(_lastLocalBackupAt)])}',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                child: Text(
                                  L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        tooltip: L.get('me_backup_auto_title'),
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        icon: Container(
                          width: 20,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: YanciTheme.accent),
                          ),
                          child: Text(
                            '!',
                            style: TextStyle(
                              color: YanciTheme.accent,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.pop(sheetContext, _BackupSheetAction.share);
                        },
                        tooltip: L.get('me_share_backup'),
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        icon: Icon(
                          Icons.share_outlined,
                          size: 20,
                          color: YanciTheme.accent,
                        ),
                      ),
                      if (!legacyStats.isEmpty) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: () {
                            Navigator.pop(
                              sheetContext,
                              _BackupSheetAction.cleanup,
                            );
                          },
                          tooltip:
                              '${L.get('me_cleanup_exports')} · '
                              '${L.fmt('me_cleanup_exports_sub', [legacyStats.fileCount, _formatByteSize(legacyStats.totalBytes)])}',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          icon: Icon(
                            Icons.cleaning_services_outlined,
                            size: 20,
                            color: Colors.red.shade400,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.pop(sheetContext, _BackupSheetAction.sync),
                      style: TextButton.styleFrom(
                        foregroundColor: YanciTheme.accent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                      ),
                      child: Text(
                        L.pick(
                          en: 'One-time Wi-Fi device sync',
                          zhTW: 'Wi-Fi單次設備同步',
                          zhCN: 'Wi-Fi单次设备同步',
                        ),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  _buildBackupSheetAction(
                    icon: Icons.save_outlined,
                    title: L.get('me_export_json'),
                    subtitle: L.get('me_export_json_sub'),
                    onTap: () {
                      Navigator.pop(sheetContext, _BackupSheetAction.save);
                    },
                  ),
                  const SizedBox(height: 8),
                  _buildBackupSheetAction(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: L.pick(
                      en: 'Import external chats',
                      zhTW: '匯入外部對話',
                      zhCN: '导入外部对话',
                    ),
                    subtitle: L.pick(
                      en: 'Add ChatGPT, Claude, Gemini, Grok, JSON or Markdown windows',
                      zhTW: '追加 ChatGPT、Claude、Gemini、Grok、JSON 或 Markdown 窗口',
                      zhCN: '追加 ChatGPT、Claude、Gemini、Grok、JSON 或 Markdown 窗口',
                    ),
                    onTap: () {
                      Navigator.pop(
                        sheetContext,
                        _BackupSheetAction.importExternal,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  _buildBackupSheetAction(
                    icon: Icons.file_download_outlined,
                    title: L.get('me_import_json'),
                    subtitle: L.get('me_import_json_sub'),
                    warning: true,
                    onTap: () {
                      Navigator.pop(sheetContext, _BackupSheetAction.import);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 先等待底部窗口完整退出，再建立下一個 dialog/文件選擇器。
    // 若在 pop 動畫期間立即 push，Flutter 會在 InheritedElement 尚未
    // 完成 deactivate 時看到仍有 dependents，觸發 framework assertion。
    if (!mounted || action == null) return;
    switch (action) {
      case _BackupSheetAction.sync:
        final restored = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (_) => const LocalDeviceSyncScreen(),
          ),
        );
        if (restored == true && mounted) {
          await _reloadHomeAfterRestore();
          if (mounted) {
            showThemedPillNotice(
              context,
              L.pick(
                en: 'Device sync complete',
                zhTW: '設備同步完成',
                zhCN: '设备同步完成',
              ),
            );
          }
        }
      case _BackupSheetAction.save:
        await _handleExportBackup(_BackupExportMode.save);
      case _BackupSheetAction.share:
        await _handleExportBackup(_BackupExportMode.share);
      case _BackupSheetAction.importExternal:
        await _handleExternalChatImport();
      case _BackupSheetAction.import:
        await _handleImportBackup();
      case _BackupSheetAction.cleanup:
        await _confirmDeleteLegacyExports(legacyStats);
    }
  }

  String _formatBackupTime(DateTime? value) {
    if (value == null) return L.get('me_backup_never');
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _buildBackupSheetAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool warning = false,
  }) {
    final tint = warning ? Colors.red.shade400 : YanciTheme.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: warning
                  ? tint.withValues(alpha: 0.18)
                  : (YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06)),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: YanciTheme.textPrimary,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: YanciTheme.textSecondary.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showShopBottomSheet(BuildContext context) async {
    if (!(await ToolFeatureSettings.load()).shopEnabled || !context.mounted) {
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const ShopBottomSheet(),
    );
  }

  Future<void> _showBackpackBottomSheet(
    BuildContext context,
    String ownerId,
  ) async {
    if (!(await ToolFeatureSettings.load()).shopEnabled || !context.mounted) {
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BackpackBottomSheet(ownerId: ownerId),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  final bool confirmPassword;

  const _BackupPasswordDialog({required this.confirmPassword});

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(
        () => _errorText = L.pick(
          en: 'Enter the backup password.',
          zhTW: '請輸入備份密碼。',
        ),
      );
      return;
    }
    if (widget.confirmPassword && password.length < 8) {
      setState(
        () => _errorText = L.pick(
          en: 'Use at least 8 characters.',
          zhTW: '請至少使用 8 個字元。',
        ),
      );
      return;
    }
    if (widget.confirmPassword && password != _confirmationController.text) {
      setState(
        () => _errorText = L.pick(
          en: 'The passwords do not match.',
          zhTW: '兩次輸入的密碼不一致。',
        ),
      );
      return;
    }
    Navigator.pop(context, password);
  }

  @override
  Widget build(BuildContext context) {
    final confirmPassword = widget.confirmPassword;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      ),
      backgroundColor: YanciTheme.isDark
          ? const Color(0xFF1E1E2E)
          : Colors.white,
      title: Text(
        L.pick(
          en: confirmPassword ? 'Encrypt backup' : 'Unlock backup',
          zhTW: confirmPassword ? '加密備份' : '解鎖備份',
        ),
        style: TextStyle(
          color: YanciTheme.textPrimary,
          fontFamily: YanciTheme.fontFamily,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(
              en: confirmPassword
                  ? 'This password is required to restore the backup. Holt cannot recover it for you.'
                  : 'Enter the password used when this backup was created.',
              zhTW: confirmPassword
                  ? '還原備份時必須輸入此密碼；Holt 無法替你找回。'
                  : '請輸入建立這份備份時使用的密碼。',
            ),
            style: TextStyle(
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: confirmPassword
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: confirmPassword ? null : (_) => _submit(),
            decoration: InputDecoration(
              labelText: L.pick(en: 'Password', zhTW: '備份密碼'),
              errorText: _errorText,
            ),
          ),
          if (confirmPassword) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirmationController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: L.pick(en: 'Confirm password', zhTW: '再次輸入密碼'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L.get('cancel')),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            L.pick(
              en: confirmPassword ? 'Encrypt' : 'Unlock',
              zhTW: confirmPassword ? '加密匯出' : '解鎖',
            ),
          ),
        ),
      ],
    );
  }
}
