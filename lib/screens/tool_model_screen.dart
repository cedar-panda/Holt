import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../widgets/gradient_background.dart';
import '../widgets/image_generation_settings_card.dart';

class ToolModelScreen extends StatefulWidget {
  const ToolModelScreen({super.key});

  @override
  State<ToolModelScreen> createState() => _ToolModelScreenState();
}

class _ToolModelScreenState extends State<ToolModelScreen> {
  String _stickerVisionModel = '';
  String _stickerVisionProvider = '';
  List<StarredModelEntry> _starredModels = const <StarredModelEntry>[];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final stickerModel = await UserSettings.getStickerVisionModel();
    var stickerProvider = await UserSettings.getStickerVisionProvider();
    final starred = await ApiSettings.getStarredModelEntries();
    if (stickerModel.isNotEmpty && stickerProvider.isEmpty) {
      stickerProvider = await ApiSettings.resolveStarredModelProvider(
        stickerModel,
      );
    }

    if (mounted) {
      setState(() {
        _stickerVisionModel = stickerModel;
        _stickerVisionProvider = stickerProvider;
        _starredModels = starred;
      });
    }
  }

  Future<void> _saveSettings() async {
    await UserSettings.saveStickerVisionSelection(
      provider: _stickerVisionProvider,
      model: _stickerVisionModel,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.get('saved')),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: YanciTheme.spacingMd,
            vertical: YanciTheme.spacingXs,
          ),
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
    return Text(
      title,
      style: YanciTheme.bodySmall.copyWith(
        color: YanciTheme.textSecondary,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildModelDropdown({
    required String model,
    required String provider,
    required void Function(String provider, String model) onChanged,
  }) {
    final options = List<StarredModelEntry>.from(_starredModels);
    if (model.isNotEmpty &&
        !options.any(
          (entry) => entry.provider == provider && entry.modelId == model,
        )) {
      options.add(StarredModelEntry(provider: provider, modelId: model));
    }
    final selectedIdentity = model.isEmpty
        ? ''
        : StarredModelEntry(provider: provider, modelId: model).identity;
    return DropdownButton<String>(
      value: options.any((entry) => entry.identity == selectedIdentity)
          ? selectedIdentity
          : '',
      isExpanded: true,
      underline: const SizedBox(),
      dropdownColor: YanciTheme.isDark ? const Color(0xF0302830) : Colors.white,
      style: YanciTheme.bodyText.copyWith(
        fontSize: 12,
        color: YanciTheme.textPrimary,
      ),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          value: '',
          child: Text(
            L.get('settings_same_as_main'),
            style: TextStyle(fontSize: 12, color: YanciTheme.textSecondary),
          ),
        ),
        ...options.map((entry) {
          final m = entry.modelId;
          String label;
          if (m.contains('/')) {
            label = m.split('/').last.replaceAll(RegExp(r'-\d{8}$'), '');
          } else {
            label = m;
          }
          return DropdownMenuItem<String>(
            value: entry.identity,
            child: Text(
              '$label · ${entry.provider}',
              style: TextStyle(
                fontSize: 12,
                color: YanciTheme.isDark
                    ? Colors.white.withValues(alpha: 0.85)
                    : YanciTheme.textPrimary,
              ),
            ),
          );
        }),
      ],
      onChanged: (identity) {
        if (identity == null || identity.isEmpty) {
          onChanged('', '');
          return;
        }
        final entry = options.firstWhere(
          (candidate) => candidate.identity == identity,
        );
        onChanged(entry.provider, entry.modelId);
      },
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
                          L.pick(en: 'Tool Models', zhTW: '工具模型'),
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
                  padding: const EdgeInsets.all(YanciTheme.spacingMd),
                  children: [
                    _buildSectionTitle(L.get('settings_sticker_vision_title')),
                    const SizedBox(height: YanciTheme.spacingSm),
                    _buildGlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            L.get('settings_sticker_model'),
                            style: YanciTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          _buildModelDropdown(
                            model: _stickerVisionModel,
                            provider: _stickerVisionProvider,
                            onChanged: (provider, model) => setState(() {
                              _stickerVisionProvider = provider;
                              _stickerVisionModel = model;
                            }),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: YanciTheme.spacingLg),

                    _buildSectionTitle(L.pick(en: 'Image Model', zhTW: '畫圖模型')),
                    const SizedBox(height: YanciTheme.spacingSm),
                    _buildGlassCard(child: const ImageGenerationSettingsCard()),

                    const SizedBox(height: YanciTheme.spacingXl),

                    Center(
                      child: TextButton(
                        onPressed: _saveSettings,
                        style: TextButton.styleFrom(
                          backgroundColor: YanciTheme.accent.withValues(
                            alpha: 0.1,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              YanciTheme.radiusLg,
                            ),
                          ),
                        ),
                        child: Text(
                          L.get('save'),
                          style: YanciTheme.bodyText.copyWith(
                            color: YanciTheme.accent,
                          ),
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
    );
  }
}
