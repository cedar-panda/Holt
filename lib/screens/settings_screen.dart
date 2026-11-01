import 'dart:async';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/custom_font_service.dart';
import '../widgets/gradient_background.dart';
import '../main.dart'; // for changeFont, changeFontScale, previewFontScale
import 'storage_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _fontScale = YanciTheme.fontScale;
  bool _fontScaleDirty = false;
  bool _fontImporting = false;
  CustomFontInfo? _customFont;

  @override
  void initState() {
    super.initState();
    _loadFontScale();
    _loadCustomFont();
  }

  Future<void> _loadFontScale() async {
    final scale = await ThemeSettings.getFontSizeScale();
    if (mounted && !_fontScaleDirty) setState(() => _fontScale = scale);
  }

  Future<void> _loadCustomFont() async {
    final font = await CustomFontService.getSavedFont();
    if (mounted && !_fontImporting) setState(() => _customFont = font);
  }

  List<String> get _fontFamilies => [
    ...YanciTheme.fontPairings.keys,
    if (_customFont != null) _customFont!.family,
  ];

  Map<String, String> get _fontLabels => {
    ...YanciTheme.fontDisplayNames,
    if (_customFont != null) _customFont!.family: _customFont!.displayName,
  };

  String get _selectedFontFamily {
    final families = _fontFamilies;
    return families.contains(YanciTheme.fontFamily)
        ? YanciTheme.fontFamily
        : 'Lora';
  }

  void _previewFontScale(double v) {
    setState(() {
      _fontScale = v;
      _fontScaleDirty = true;
    });
    previewFontScale(v);
  }

  Future<void> _saveFontScale([double? v]) async {
    final scale = v ?? _fontScale;
    _fontScaleDirty = false;
    await changeFontScale(scale);
  }

  Future<void> _selectFont(String family) async {
    final customFont = _customFont;
    if (customFont != null && family == customFont.family) {
      await changeCustomFont(customFont);
    } else {
      await changeFont(family);
    }
    if (mounted) setState(() {});
  }

  Future<void> _importFont() async {
    if (_fontImporting) return;
    setState(() => _fontImporting = true);
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ttf', 'otf'],
        allowMultiple: false,
        withData: false,
      );
      if (selection == null) return;
      final picked = selection.files.single;
      final path = picked.path;
      if (path == null || path.isEmpty) {
        throw const CustomFontException(CustomFontFailure.missingFile);
      }
      final font = await CustomFontService.importFont(
        sourcePath: path,
        originalName: picked.name,
      );
      await changeCustomFont(font);
      if (!mounted) return;
      setState(() => _customFont = font);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: '${font.displayName} imported and applied',
              zhTW: '已導入並套用 ${font.displayName}',
              zhCN: '已导入并应用 ${font.displayName}',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on CustomFontException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_customFontError(error.failure)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Could not import this font',
              zhTW: '無法導入這個字體',
              zhCN: '无法导入这个字体',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _fontImporting = false);
    }
  }

  String _customFontError(CustomFontFailure failure) {
    return switch (failure) {
      CustomFontFailure.unsupportedFormat => L.pick(
        en: 'Choose a TTF or OTF font',
        zhTW: '請選擇 TTF 或 OTF 字體',
        zhCN: '请选择 TTF 或 OTF 字体',
      ),
      CustomFontFailure.tooLarge => L.pick(
        en: 'Font files must be 50 MB or smaller',
        zhTW: '字體檔不可超過 50 MB',
        zhCN: '字体文件不可超过 50 MB',
      ),
      CustomFontFailure.emptyFile || CustomFontFailure.invalidFont => L.pick(
        en: 'This is not a valid TTF or OTF font',
        zhTW: '這不是有效的 TTF 或 OTF 字體',
        zhCN: '这不是有效的 TTF 或 OTF 字体',
      ),
      CustomFontFailure.missingFile || CustomFontFailure.loadFailed => L.pick(
        en: 'The font could not be read or loaded',
        zhTW: '無法讀取或載入這個字體',
        zhCN: '无法读取或载入这个字体',
      ),
    };
  }

  Widget _buildFontImportRow() {
    final customFont = _customFont;
    final active =
        customFont != null && YanciTheme.fontFamily == customFont.family;
    final subtitle = customFont == null
        ? L.pick(
            en: 'TTF or OTF · up to 50 MB',
            zhTW: '支援 TTF、OTF · 最大 50 MB',
            zhCN: '支持 TTF、OTF · 最大 50 MB',
          )
        : L.pick(
            en: '${active ? 'Applied' : 'Imported'} · ${customFont.displayName}',
            zhTW: '${active ? '已套用' : '已導入'} · ${customFont.displayName}',
            zhCN: '${active ? '已应用' : '已导入'} · ${customFont.displayName}',
          );
    return Semantics(
      button: true,
      enabled: !_fontImporting,
      label: L.pick(
        en: 'Import and apply a custom font',
        zhTW: '導入並套用自訂字體',
        zhCN: '导入并应用自定义字体',
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        onTap: _fontImporting ? null : _importFont,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.font_download_outlined,
                  color: YanciTheme.accent,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        L.pick(
                          en: 'Import font',
                          zhTW: '一鍵導入字體',
                          zhCN: '一键导入字体',
                        ),
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: YanciTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_fontImporting)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: YanciTheme.accent,
                    ),
                  )
                else
                  Icon(
                    Icons.file_open_outlined,
                    color: YanciTheme.textSecondary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showBundledDocument(String asset, String title) async {
    final text = await rootBundle.loadString(asset);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        title: Text(title, style: YanciTheme.headingMedium),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text, style: YanciTheme.bodySmall),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L.pick(en: 'Close', zhTW: '關閉')),
          ),
        ],
      ),
    );
  }

  Widget _legalRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 48,
      leading: Icon(icon, color: YanciTheme.accent),
      title: Text(label, style: YanciTheme.bodyText.copyWith(fontSize: 14)),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: YanciTheme.textSecondary,
      ),
      onTap: onTap,
    );
  }

  @override
  void dispose() {
    if (_fontScaleDirty) {
      unawaited(ThemeSettings.saveFontSizeScale(_fontScale));
    }
    super.dispose();
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: YanciTheme.glassInputBg,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
      child: Text(
        title,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _softDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.transparent,
              YanciTheme.glassBorder.withValues(alpha: 0.45),
              YanciTheme.glassBorder.withValues(alpha: 0.45),
              Colors.transparent,
            ],
            stops: const [0, 0.18, 0.82, 1],
          ),
        ),
      ),
    );
  }

  Widget _buildDropdownRow(
    String title,
    String currentValue,
    List<String> items,
    Function(String) onChanged, {
    Map<String, String>? labels,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: YanciTheme.bodyText.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: YanciTheme.textPrimary,
            ),
          ),
          DropdownButton<String>(
            value: currentValue,
            underline: const SizedBox(),
            dropdownColor: YanciTheme.isDark
                ? const Color(0xF0302830)
                : Colors.white,
            icon: Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: YanciTheme.textSecondary,
            ),
            style: YanciTheme.bodyText.copyWith(
              fontSize: 13,
              color: YanciTheme.textPrimary,
            ),
            items: items
                .map(
                  (e) =>
                      DropdownMenuItem(value: e, child: Text(labels?[e] ?? e)),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: Text(
                          L.pick(en: 'Settings', zhTW: '設定'),
                          textAlign: TextAlign.center,
                          style: YanciTheme.headingMedium,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: Icon(
                            Icons.arrow_back_ios_rounded,
                            size: 20,
                            color: YanciTheme.textPrimary,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                  children: [
                    _buildSectionTitle(
                      L.pick(en: 'Preferences', zhTW: '介面與語言'),
                    ),
                    _buildGlassCard(
                      child: Column(
                        children: [
                          _buildDropdownRow(
                            L.pick(en: 'Language', zhTW: '語言'),
                            L.locale,
                            L.localeNames.keys.toList(),
                            (v) async {
                              await L.setLocale(v);
                              if (mounted) setState(() {});
                            },
                            labels: L.localeNames,
                          ),
                          _softDivider(),
                          _buildDropdownRow(
                            L.pick(en: 'Font', zhTW: '字體'),
                            _selectedFontFamily,
                            _fontFamilies,
                            _selectFont,
                            labels: _fontLabels,
                          ),
                          _softDivider(),
                          _buildFontImportRow(),
                          _softDivider(),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L.pick(en: 'Font Size', zhTW: '字體大小'),
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: YanciTheme.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Text(
                                      'A',
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 12,
                                      ),
                                    ),
                                    Expanded(
                                      child: Slider(
                                        value: _fontScale,
                                        min: 0.8,
                                        max: 1.5,
                                        divisions: 7,
                                        activeColor: YanciTheme.accent,
                                        inactiveColor: YanciTheme.glassBorder,
                                        onChanged: _previewFontScale,
                                        onChangeEnd: (v) async {
                                          await _saveFontScale(v);
                                        },
                                      ),
                                    ),
                                    Text(
                                      'A',
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildSectionTitle(L.pick(en: 'Guidance', zhTW: '引導')),
                    _buildGlassCard(
                      child: _legalRow(
                        icon: Icons.tune_rounded,
                        label: L.pick(
                          en: 'Choose your relationship mode again',
                          zhTW: '再次選擇相處模式',
                          zhCN: '再次选择相处模式',
                        ),
                        onTap: () async {
                          final navigator = Navigator.of(context);
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              backgroundColor: YanciTheme.surfacePanel,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  YanciTheme.radiusLg,
                                ),
                              ),
                              title: Text(
                                L.pick(
                                  en: 'Choose relationship mode again?',
                                  zhTW: '重新選擇相處模式？',
                                  zhCN: '重新选择相处模式？',
                                ),
                              ),
                              content: Text(
                                L.pick(
                                  en: 'Your characters and conversations stay unchanged. New choices are applied only after you confirm them in the guide.',
                                  zhTW: '角色與對話不會被刪除；只有在引導內正式確認後，新的相處設定才會套用。',
                                  zhCN: '角色与对话不会被删除；只有在引导内正式确认后，新的相处设置才会应用。',
                                ),
                              ),
                              actions: <Widget>[
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, false),
                                  child: Text(L.get('cancel')),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, true),
                                  child: Text(
                                    L.pick(
                                      en: 'Continue',
                                      zhTW: '繼續',
                                      zhCN: '继续',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true || !mounted) return;
                          await navigator.pushNamed('/initial_setup');
                        },
                      ),
                    ),
                    _buildSectionTitle(L.pick(en: 'Storage', zhTW: '儲存空間')),
                    _buildGlassCard(
                      child: _legalRow(
                        icon: Icons.storage_rounded,
                        label: L.pick(
                          en: 'Manage storage',
                          zhTW: '查看與清理（圖片、語音、模型、暫存）',
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const StorageScreen(),
                          ),
                        ),
                      ),
                    ),
                    _buildSectionTitle(
                      L.pick(en: 'Legal & open source', zhTW: '法律與開源'),
                    ),
                    _buildGlassCard(
                      child: Column(
                        children: [
                          _legalRow(
                            icon: Icons.article_outlined,
                            label: L.pick(
                              en: 'Open-source licenses',
                              zhTW: '開源授權',
                            ),
                            onTap: () => showLicensePage(
                              context: context,
                              applicationName: 'Holt',
                              applicationVersion: '1.0.0',
                            ),
                          ),
                          _softDivider(),
                          _legalRow(
                            icon: Icons.fact_check_outlined,
                            label: L.pick(
                              en: 'Third-party notices',
                              zhTW: '第三方聲明',
                            ),
                            onTap: () => _showBundledDocument(
                              'THIRD_PARTY_NOTICES.md',
                              L.pick(en: 'Third-party notices', zhTW: '第三方聲明'),
                            ),
                          ),
                          _softDivider(),
                          _legalRow(
                            icon: Icons.privacy_tip_outlined,
                            label: L.pick(en: 'Privacy', zhTW: '隱私說明'),
                            onTap: () => _showBundledDocument(
                              'PRIVACY.md',
                              L.pick(en: 'Privacy', zhTW: '隱私說明'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
