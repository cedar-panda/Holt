part of 'home_screen.dart';

const bool _showDeveloperDiagnostics = bool.fromEnvironment(
  'HOLT_ENABLE_DEVELOPER_DIAGNOSTICS',
  defaultValue:
      !bool.fromEnvironment('dart.vm.product') &&
      !bool.fromEnvironment('dart.vm.profile'),
);

extension _HomeProfileMethods on _HomeScreenState {
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
  }) {
    final effectiveAccent =
        iconColor ??
        (isSecondary
            ? YanciTheme.accent.withValues(alpha: 0.45)
            : YanciTheme.accent);

    final iconSize = hideText ? 32.0 : (isSecondary ? 28.0 : 34.0);
    final fontSize = isSecondary ? 13.5 : 16.0;
    final fontWeight = isSecondary ? FontWeight.w500 : FontWeight.w600;
    final textColor = isSecondary
        ? YanciTheme.textSecondary
        : YanciTheme.textPrimary;

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
  }) {
    final effectiveAccent = YanciTheme.accent.withValues(alpha: 0.45);

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

  Widget _buildSoftProfileDivider({bool dots = false}) {
    final lineColor = YanciTheme.textSecondary.withValues(alpha: 0.16);
    final accent = YanciTheme.accent;
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
                // 左上角：日/夜模式切換（回到最近選過的對應主題）
                IconButton(
                  tooltip: YanciTheme.isDark
                      ? (L.pick(en: 'Light Mode', zhTW: '日間模式'))
                      : (L.pick(en: 'Dark Mode', zhTW: '夜間模式')),
                  onPressed: _toggleProfileThemeMode,
                  icon: Icon(
                    YanciTheme.isDark
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    size: 22,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: YanciTheme.accent,
                  ),
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
                      icon: const Icon(Icons.backup_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor: YanciTheme.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: L.get('nav_settings'),
                      onPressed: () {
                        Navigator.of(context).pushNamed('/settings');
                      },
                      icon: const Icon(Icons.settings_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor: YanciTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 28),

            // 居中頭像 + 名字
            Center(
              child: InkWell(
                onTap: () async {
                  await Navigator.of(context).pushNamed('/user_profile');
                  if (!mounted) return;
                  _loadLatestNote();
                },
                borderRadius: BorderRadius.circular(40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Column(
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: YanciTheme.accent.withValues(alpha: 0.1),
                          border: Border.all(
                            color: YanciTheme.accent.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                          image:
                              _userAvatar != null &&
                                  File(_userAvatar!).existsSync()
                              ? DecorationImage(
                                  image: FileImage(File(_userAvatar!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child:
                            _userAvatar == null ||
                                !File(_userAvatar!).existsSync()
                            ? Icon(
                                Icons.person_rounded,
                                size: 38,
                                color: YanciTheme.accent.withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 22),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: max(
                                120.0,
                                MediaQuery.of(context).size.width - 140,
                              ),
                            ),
                            child: Text(
                              _userName.isNotEmpty
                                  ? _userName
                                  : L.get('me_user_profile'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // 裝飾分割線
            _buildSoftProfileDivider(),
            const SizedBox(height: 24),

            // 核心系統與模型 (Super Group)
            _buildGridTile(
              title: L.pick(en: 'Controls', zhTW: '開關'),
              icon: Icons.data_usage_rounded,
              customIcon: _SegmentedUsageIcon(
                size: 28,
                baseColor: YanciTheme.textSecondary.withValues(alpha: 0.38),
                accentColor: YanciTheme.accent,
              ),
              height: 76,
              onTap: () => Navigator.of(context).pushNamed('/cost_context'),
            ),
            const SizedBox(height: 14),
            _buildGridTile(
              title: L.pick(en: 'Theme Studio', zhTW: '主題工坊'),
              icon: Icons.palette_outlined,
              iconColor: HSLColor.fromColor(YanciTheme.accent)
                  .withSaturation(
                    (HSLColor.fromColor(
                      YanciTheme.accent,
                    ).saturation).clamp(0.5, 1.0),
                  )
                  .withLightness(0.62)
                  .toColor(),
              glowIcon: true,
              height: 76,
              onTap: () async {
                await Navigator.of(context).pushNamed('/theme_workshop');
                if (!mounted) return;
                _refreshProfileTheme();
              },
            ),
            const SizedBox(height: 26),

            // 裝飾分割線 (三個小點)
            _buildSoftProfileDivider(dots: true),
            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'Voice / Ringtone', zhTW: '語音/鈴聲'),
                    icon: Icons.record_voice_over_rounded,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(context).pushNamed('/voice_call'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'Tool API', zhTW: '工具 API'),
                    icon: Icons.build_circle_outlined,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(context).pushNamed('/tool_model'),
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
                    title: L.pick(en: 'Local Models', zhTW: '本地模型'),
                    icon: Icons.phone_android_rounded,
                    height: 76,
                    isSecondary: true,
                    onTap: () =>
                        Navigator.of(context).pushNamed('/local_models'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'My Stickers', zhTW: '我的表情'),
                    icon: Icons.emoji_emotions_outlined,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed('/sticker', arguments: 'user'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 商店與背包
            _buildSplitGridTile(
              leftIcon: Icons.storefront_outlined,
              leftOnTap: () => _showShopBottomSheet(context),
              rightIcon: Icons.backpack_outlined,
              rightOnTap: () => _showBackpackBottomSheet(context, 'user'),
              height: 76,
            ),
            if (_showDeveloperDiagnostics) ...[
              const SizedBox(height: 28),
              GestureDetector(
                onTap: () =>
                    Navigator.of(context).pushNamed('/developer_diagnostics'),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 60,
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bug_report_outlined,
                          color: YanciTheme.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'DeBug',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: YanciTheme.textPrimary,
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
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
      final file = File(filePath);
      if (!await file.exists()) throw '檔案不存在：$filePath';
      final header = await file.openRead(0, 4).first;
      final isZip =
          header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;
      final result = isZip
          ? await BackupService.importPortableBundle(filePath)
          : await BackupService.importFromJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
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

  Future<void> _handleExportBackup(_BackupExportMode mode) async {
    if (!mounted || _backupExportRunning) return;
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
      artifactPath = await BackupService.exportPortableBundle();
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
          debugPrint('Export artifact cleanup failed: $error');
        }
      }
    }
  }

  Future<bool> _saveExportedBackup(String path) async {
    final file = File(path);
    final fileName = p.basename(path);
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (Platform.isAndroid) {
      final uri = await DeviceFileSaver.saveAndroidFile(
        sourcePath: path,
        suggestedName: fileName,
        mimeType: 'application/zip',
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
        files: <XFile>[XFile(path, mimeType: 'application/zip')],
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
    showModalBottomSheet<void>(
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
                        Icons.backup_outlined,
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
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _handleExportBackup(_BackupExportMode.share);
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
                            Navigator.pop(sheetContext);
                            _confirmDeleteLegacyExports(legacyStats);
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
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: YanciTheme.accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                      border: Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.16),
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.autorenew_rounded,
                          size: 20,
                          color: YanciTheme.accent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.get('me_backup_auto_title'),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: YanciTheme.textPrimary,
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                L.get('me_backup_auto_sub'),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.76,
                                  ),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                L.fmt('me_backup_last', [
                                  _formatBackupTime(_lastLocalBackupAt),
                                ]),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: YanciTheme.accent,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildBackupSheetAction(
                    icon: Icons.save_alt_rounded,
                    title: L.get('me_export_json'),
                    subtitle: L.get('me_export_json_sub'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _handleExportBackup(_BackupExportMode.save);
                    },
                  ),
                  const SizedBox(height: 8),
                  _buildBackupSheetAction(
                    icon: Icons.file_download_outlined,
                    title: L.get('me_import_json'),
                    subtitle: L.get('me_import_json_sub'),
                    warning: true,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _handleImportBackup();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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

  void _showShopBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const ShopBottomSheet(),
    );
  }

  void _showBackpackBottomSheet(BuildContext context, String ownerId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BackpackBottomSheet(ownerId: ownerId),
    );
  }
}
