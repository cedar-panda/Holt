import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../services/openrouter_service.dart';
import '../widgets/gradient_background.dart';

class ToolModelScreen extends StatefulWidget {
  const ToolModelScreen({super.key});

  @override
  State<ToolModelScreen> createState() => _ToolModelScreenState();
}

class _ToolModelScreenState extends State<ToolModelScreen> {
  String _stickerVisionModel = '';
  String _summaryModel = '';
  Set<String> _starredModels = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final stickerModel = await UserSettings.getStickerVisionModel();
    final summaryModel = await MemorySettings.getSummaryModel();
    final starred = await ApiSettings.getStarredModels();

    if (mounted) {
      setState(() {
        _stickerVisionModel = stickerModel;
        _summaryModel = summaryModel;
        _starredModels = starred.toSet();
      });
    }
  }

  Future<void> _saveSettings() async {
    await UserSettings.saveStickerVisionModel(_stickerVisionModel);
    await MemorySettings.saveSummaryModel(_summaryModel);

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
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final options = <String>['', ..._starredModels];
    if (value.isNotEmpty && !options.contains(value)) {
      options.add(value);
    }
    return DropdownButton<String>(
      value: options.contains(value) ? value : '',
      isExpanded: true,
      underline: const SizedBox(),
      dropdownColor: YanciTheme.isDark ? const Color(0xF0302830) : Colors.white,
      style: YanciTheme.bodyText.copyWith(
        fontSize: 12,
        color: YanciTheme.textPrimary,
      ),
      items: options.map((m) {
        String label;
        if (m.isEmpty) {
          label = L.get('settings_same_as_main');
        } else if (m.contains('/')) {
          label = m.split('/').last.replaceAll(RegExp(r'-\d{8}$'), '');
        } else {
          label = m;
        }
        return DropdownMenuItem(
          value: m,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: m.isEmpty
                  ? YanciTheme.textSecondary
                  : YanciTheme.isDark
                  ? Colors.white.withValues(alpha: 0.85)
                  : YanciTheme.textPrimary,
            ),
          ),
        );
      }).toList(),
      onChanged: (v) => onChanged(v ?? ''),
    );
  }

  void _showSummaryModelHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF2C2C2E)
            : Colors.white,
        title: Text(
          L.get('settings_summary_model'),
          style: YanciTheme.bodyText.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          L.pick(
            en: 'Used for background summary tasks (Window Summary & Auto Memory). Requires a model from your "Starred" list in API Settings. If left blank, it defaults to the main model.',
            zhTW: '用於背景摘要任務（窗口摘要、自動記憶）。\n僅能從 API 設定中你「打星標」的模型裡選擇。留空則代表跟主要模型相同。',
          ),
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              L.pick(en: 'OK', zhTW: '好'),
              style: TextStyle(color: YanciTheme.accent),
            ),
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
                            value: _stickerVisionModel,
                            onChanged: (v) =>
                                setState(() => _stickerVisionModel = v),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: YanciTheme.spacingLg),

                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSectionTitle(L.get('settings_summary_model')),
                        const SizedBox(width: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _showSummaryModelHelp,
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.help_outline_rounded,
                              size: 15,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: YanciTheme.spacingSm),
                    _buildGlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildModelDropdown(
                            value: _summaryModel,
                            onChanged: (v) => setState(() => _summaryModel = v),
                          ),
                          if (_summaryModel.isEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              L.pick(
                                en: 'Blank means same as main model; choose a cheap model if the main model is expensive.',
                                zhTW: '留空會使用主模型；主模型貴的話，建議改選便宜摘要模型。',
                              ),
                              style: YanciTheme.bodySmall.copyWith(
                                fontSize: 10,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: YanciTheme.spacingLg),

                    _buildSectionTitle(L.pick(en: 'Image Model', zhTW: '畫圖模型')),
                    const SizedBox(height: YanciTheme.spacingSm),
                    _buildGlassCard(child: const _ImageModelField()),

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

class _ImageModelField extends StatefulWidget {
  const _ImageModelField();

  @override
  State<_ImageModelField> createState() => _ImageModelFieldState();
}

class _ImageModelFieldState extends State<_ImageModelField> {
  final _ctrl = TextEditingController();
  bool _isFetching = false;
  String? _error;
  List<ModelInfo> _imageModels = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await ApiSettings.getImageGenModel();
    if (mounted) _ctrl.text = saved;

    final apiKey = await ApiSettings.getOpenRouterApiKey();
    if (apiKey.isEmpty) {
      if (mounted) {
        setState(() {
          _error = L.pick(
            en: 'Add an OpenRouter API key to load selectable image models.',
            zhTW: '填入 OpenRouter API Key 後可獲取可選畫圖模型。',
          );
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isFetching = true;
        _error = null;
      });
    }

    try {
      final models = await OpenRouterService.fetchModels(apiKey);
      final imageModels = models.where((m) => m.supportsImageOutput).toList();
      if (!mounted) return;
      setState(() {
        _imageModels = imageModels;
        _isFetching = false;
        _error = imageModels.isEmpty
            ? (L.pick(
                en: 'No image-output model was marked in the source list. Manual ID still works.',
                zhTW: '來源清單未標記圖像輸出模型，仍可手動貼模型 ID。',
              ))
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isFetching = false;
        _error = L.pick(
          en: 'Could not load OpenRouter image models. Manual ID still works.',
          zhTW: '無法獲取 OpenRouter 畫圖模型，仍可手動輸入。',
        );
      });
    }
  }

  @override
  void dispose() {
    final v = _ctrl.text.trim();
    if (v.isNotEmpty) ApiSettings.saveImageGenModel(v);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _ctrl.text.trim();
    final options = [..._imageModels];
    if (current.isNotEmpty && !options.any((m) => m.id == current)) {
      options.insert(0, ModelInfo(id: current, name: current));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isFetching)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  L.pick(en: 'Loading source models...', zhTW: '正在獲取來源模型...'),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        if (options.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButton<String>(
              value: current.isEmpty ? null : current,
              hint: Text(
                L.pick(en: 'Choose from source', zhTW: '從來源選擇'),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
              ),
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              style: YanciTheme.bodyText.copyWith(fontSize: 12),
              items: options.map((model) {
                final label = model.name == model.id
                    ? model.id
                    : '${model.name} · ${model.id}';
                return DropdownMenuItem(
                  value: model.id,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (v) async {
                if (v == null || v.isEmpty) return;
                _ctrl.text = v;
                await ApiSettings.saveImageGenModel(v);
                if (mounted) setState(() {});
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _ctrl,
          style: YanciTheme.bodyText,
          onEditingComplete: () {
            final v = _ctrl.text.trim();
            if (v.isNotEmpty) ApiSettings.saveImageGenModel(v);
            FocusScope.of(context).unfocus();
          },
          decoration: InputDecoration(
            hintText: 'openai/gpt-4o',
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            filled: true,
            fillColor: YanciTheme.glassInputBg.withValues(alpha: 0.3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          L.pick(
            en: 'OpenRouter image-output model for <draw>. Choose one above or paste a model ID.',
            zhTW: 'OpenRouter 圖像輸出模型，角色畫畫用。可從上方選擇，也可手動貼模型 ID。',
          ),
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10,
            color: YanciTheme.textSecondary.withValues(alpha: 0.5),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 10,
              color: Colors.orange.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }
}
