import 'dart:async';

import 'package:flutter/material.dart';

import '../services/image_gen_service.dart';
import '../services/app_error_log_service.dart';
import '../services/image_generation/image_generation_provider.dart';
import '../services/locale_strings.dart';
import '../services/model_info.dart';
import '../services/settings/api_settings.dart';
import '../theme/app_theme.dart';

class ImageGenerationSettingsCard extends StatefulWidget {
  const ImageGenerationSettingsCard({super.key});

  @override
  State<ImageGenerationSettingsCard> createState() =>
      _ImageGenerationSettingsCardState();
}

class _ImageGenerationSettingsCardState
    extends State<ImageGenerationSettingsCard> {
  final _modelController = TextEditingController();
  ImageGenerationProvider _provider = ImageGenerationProvider.openRouter;
  List<ModelInfo> _sourceModels = const <ModelInfo>[];
  List<StarredModelEntry> _favorites = const <StarredModelEntry>[];
  bool _loading = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final provider = ImageGenerationProvider.fromId(
      await ApiSettings.getImageGenProvider(),
    );
    final results = await Future.wait<Object>(<Future<Object>>[
      ApiSettings.getImageGenModel(provider: provider.id),
      ApiSettings.getStarredModelEntries(),
    ]);
    final favorites = results[1] as List<StarredModelEntry>;
    if (!mounted) return;
    _provider = provider;
    _modelController.text = results[0] as String;
    _favorites = favorites;
    await _loadModels();
  }

  Future<void> _loadModels() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _notice = null;
        _sourceModels = const <ModelInfo>[];
      });
    }
    try {
      final config = await ImageGenService.loadConfig(provider: _provider.id);
      if (!config.isConfigured && _provider != ImageGenerationProvider.qwen) {
        throw Exception(
          L.pick(
            en: 'Complete this source in API Settings first.',
            zhTW: '請先在 API 設定完成此來源的憑證或 Base URL。',
          ),
        );
      }
      final needsConfiguration = !config.isConfigured;
      final models = await ImageGenService.fetchModels(_provider.id);
      if (!mounted) return;
      setState(() {
        _sourceModels = models;
        _loading = false;
        if (needsConfiguration) {
          _notice = L.pick(
            en: 'Model choices are shown, but this source still needs an API key in API Settings.',
            zhTW: '已顯示模型選項，但仍需先在「API 設定」填入此來源的 API Key。',
          );
        } else if (models.isEmpty) {
          _notice = L.pick(
            en: 'The source did not mark image models. You can still paste an exact model ID.',
            zhTW: '來源清單未標記生圖模型，仍可手動貼上精確模型 ID。',
          );
        }
      });
    } catch (error) {
      await AppErrorLogService.record(
        error: error,
        trigger: 'functional_image_model_list',
        source: 'functional_model_settings',
        provider: _provider.id,
        model: _modelController.text.trim(),
      );
      if (!mounted) return;
      final text = error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _loading = false;
        _notice = text.length > 180 ? '${text.substring(0, 180)}…' : text;
      });
    }
  }

  Future<void> _selectProvider(ImageGenerationProvider provider) async {
    if (_provider == provider) return;
    await _saveCurrentModel();
    await ApiSettings.saveImageGenProvider(provider.id);
    final model = await ApiSettings.getImageGenModel(provider: provider.id);
    if (!mounted) return;
    setState(() {
      _provider = provider;
      _modelController.text = model;
    });
    await _loadModels();
  }

  Future<void> _saveCurrentModel() async {
    final model = _modelController.text.trim();
    if (model.isEmpty) return;
    await ApiSettings.saveImageGenModel(model, provider: _provider.id);
  }

  List<ModelInfo> get _options {
    final unique = <String, ModelInfo>{};
    void add(String id, [String? name]) {
      var normalized = id.trim();
      if (_provider == ImageGenerationProvider.localApi &&
          ApiSettings.isLocalApiModelId(normalized)) {
        normalized = ApiSettings.extractLocalApiModel(normalized);
      }
      if (normalized.isEmpty) return;
      unique[normalized] = ModelInfo(
        id: normalized,
        name: name?.trim().isNotEmpty == true ? name!.trim() : normalized,
      );
    }

    add(_modelController.text);
    add(_provider.defaultModel);
    for (final entry in _favorites) {
      if (entry.provider == _provider.id) add(entry.modelId);
    }
    for (final model in _sourceModels) {
      add(model.id, model.name);
    }
    return unique.values.toList(growable: false);
  }

  @override
  void dispose() {
    unawaited(_saveCurrentModel());
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final current = _modelController.text.trim();
    final borderColor = YanciTheme.textSecondary.withValues(alpha: 0.18);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          L.pick(en: 'Image source', zhTW: '生圖來源'),
          style: YanciTheme.bodySmall.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Semantics(
          label: L.pick(en: 'Image generation source', zhTW: '生圖來源'),
          value: _provider.displayName,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 0.75),
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            ),
            child: DropdownButton<ImageGenerationProvider>(
              value: _provider,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              items: ImageGenerationProvider.values
                  .map(
                    (provider) => DropdownMenuItem<ImageGenerationProvider>(
                      value: provider,
                      child: Text(provider.displayName),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (provider) {
                if (provider != null) unawaited(_selectProvider(provider));
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                L.pick(en: 'Image model', zhTW: '生圖模型'),
                style: YanciTheme.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (_loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Semantics(
                button: true,
                label: L.pick(en: 'Reload image models', zhTW: '重新獲取生圖模型'),
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: L.pick(en: 'Reload models', zhTW: '重新獲取模型'),
                  onPressed: () => unawaited(_loadModels()),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
              ),
          ],
        ),
        if (options.isNotEmpty) ...<Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
            ),
            child: DropdownButton<String>(
              value: options.any((model) => model.id == current)
                  ? current
                  : null,
              isExpanded: true,
              underline: const SizedBox(),
              hint: Text(L.pick(en: 'Choose a model', zhTW: '選擇模型')),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              items: options
                  .map(
                    (model) => DropdownMenuItem<String>(
                      value: model.id,
                      child: Text(
                        model.name == model.id
                            ? model.id
                            : '${model.name} · ${model.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (model) {
                if (model == null || model.isEmpty) return;
                setState(() => _modelController.text = model);
                unawaited(_saveCurrentModel());
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _modelController,
          style: YanciTheme.bodyText,
          onChanged: (_) => setState(() {}),
          onEditingComplete: () {
            unawaited(_saveCurrentModel());
            FocusScope.of(context).unfocus();
          },
          decoration: InputDecoration(
            hintText: _provider.defaultModel,
            filled: true,
            fillColor: YanciTheme.glassInputBg.withValues(alpha: 0.3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          L.pick(
            en: 'Uses this source\'s credentials from API Settings. Source and model are independent from the chat model.',
            zhTW: '沿用「API 設定」中此來源的憑證；生圖來源與模型不跟隨聊天模型切換。',
          ),
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 10,
            height: 1.4,
            color: YanciTheme.textSecondary.withValues(alpha: 0.65),
          ),
        ),
        if (_notice != null) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            _notice!,
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 10,
              height: 1.35,
              color: Colors.orange.withValues(alpha: 0.78),
            ),
          ),
        ],
      ],
    );
  }
}
