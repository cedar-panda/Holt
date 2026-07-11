import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../widgets/gradient_background.dart';
import '../main.dart'; // for changeFont, changeFontScale, previewFontScale, themeNotifier

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _fontScale = YanciTheme.fontScale;
  bool _fontScaleDirty = false;

  @override
  void initState() {
    super.initState();
    _loadFontScale();
  }

  Future<void> _loadFontScale() async {
    final scale = await ThemeSettings.getFontSizeScale();
    if (mounted && !_fontScaleDirty) setState(() => _fontScale = scale);
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
          child: child,
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
                              themeNotifier.value++;
                            },
                            labels: L.localeNames,
                          ),
                          _softDivider(),
                          _buildDropdownRow(
                            L.pick(en: 'Font', zhTW: '字體'),
                            YanciTheme.fontFamily,
                            YanciTheme.fontPairings.keys.toList(),
                            (v) async {
                              await changeFont(v);
                              setState(() {});
                            },
                            labels: YanciTheme.fontDisplayNames,
                          ),
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
