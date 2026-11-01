import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/locale_strings.dart';
import '../../services/provider_model_catalog.dart';
import '../../services/settings_manager.dart';
import '../../services/tts_service.dart';
import '../../theme/app_theme.dart';
import '../api_memory_settings_card.dart';
import '../image_generation_settings_card.dart';
import 'holt_sidebar_shell.dart';
import 'sidebar_accordion.dart';
import 'sidebar_visual_tokens.dart';

/// Functional model-selection surfaces for the main sidebar.
///
/// Visual ownership intentionally stays outside this class. Claude can search
/// the UI_SLOT markers and replace the presentation without touching the
/// persistence and provider-selection behavior below.
class SidebarModelSettings extends StatefulWidget {
  const SidebarModelSettings({super.key, this.pageMode = false});

  /// Sidebar mode only exposes the two stable destinations. The detailed
  /// selectors live on their own route so model discovery, favorites and
  /// provider fallbacks share one focused surface.
  final bool pageMode;

  @override
  State<SidebarModelSettings> createState() => _SidebarModelSettingsState();
}

class _SidebarModelSettingsState extends State<SidebarModelSettings> {
  static const String _separator = '\u0000';

  List<StarredModelEntry> _starred = const <StarredModelEntry>[];
  List<StarredModelEntry> _embeddingModels = const <StarredModelEntry>[];
  String _summaryProvider = '';
  String _summaryModel = '';
  String _embeddingProvider = '';
  String _embeddingModel = '';
  String _stickerProvider = '';
  String _stickerModel = '';
  String _ttsProvider = 'openai';
  String _ttsElevenlabsModel = 'eleven_multilingual_v2';
  String _ttsOpenaiVoice = 'nova';
  String _ttsElevenlabsVoiceId = '';
  List<String> _ttsVoiceIds = const <String>[];
  Map<String, String> _ttsVoiceLabels = const <String, String>{};
  final TextEditingController _ttsVoiceIdController = TextEditingController();
  WebSearchMode _webSearchMode = WebSearchMode.auto;
  String _webSearchModel = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.pageMode) unawaited(_load());
  }

  Future<void> _load() async {
    final starred = await ApiSettings.getRankedStarredModelEntries();
    final activeProvider = await ApiSettings.getApiProvider();
    final activeModel = await ApiSettings.getModelForProvider(activeProvider);
    final activeReady = await ApiSettings.hasUsableProviderConfiguration(
      activeProvider,
    );
    final selectableModels = <String, StarredModelEntry>{
      for (final entry in starred) entry.identity: entry,
      if (activeReady && activeModel.trim().isNotEmpty)
        StarredModelEntry(
          provider: activeProvider,
          modelId: activeModel.trim(),
        ).identity: StarredModelEntry(
          provider: activeProvider,
          modelId: activeModel.trim(),
        ),
    }.values.toList(growable: false);
    final summaryModel = await MemorySettings.getSummaryModel();
    var summaryProvider = await MemorySettings.getSummaryProvider();
    if (summaryModel.isNotEmpty && summaryProvider.isEmpty) {
      summaryProvider = await ApiSettings.resolveStarredModelProvider(
        summaryModel,
      );
    }
    final embedding = await MemorySettings.getEmbeddingSelection();
    final stickerModel = await UserSettings.getStickerVisionModel();
    var stickerProvider = await UserSettings.getStickerVisionProvider();
    if (stickerModel.isNotEmpty && stickerProvider.isEmpty) {
      stickerProvider = await ApiSettings.resolveStarredModelProvider(
        stickerModel,
      );
    }
    final webMode = await WebSearchSettings.getMode();
    final webModel = await _loadWebSearchModel(webMode);
    final ttsProvider = await TtsSettings.getTtsProvider();
    final ttsElevenlabsModel = await TtsSettings.getTtsElevenlabsModel();
    final ttsOpenaiVoice = await TtsSettings.getTtsVoice();
    final ttsElevenlabsVoiceId = await TtsSettings.getTtsElevenlabsVoiceId();
    final ttsVoiceIds = TtsSettings.normalizeVoiceIdOptions(
      await TtsSettings.getVoiceIdList(),
      boundVoiceId: ttsElevenlabsVoiceId,
    );
    final ttsVoiceLabels = await TtsSettings.getVoiceIdLabels();
    if (!mounted) return;
    setState(() {
      _starred = selectableModels;
      _summaryProvider = summaryProvider;
      _summaryModel = summaryModel;
      _embeddingProvider = embedding.provider;
      _embeddingModel = embedding.model;
      _stickerProvider = stickerProvider;
      _stickerModel = stickerModel;
      _ttsProvider = ttsProvider;
      _ttsElevenlabsModel = ttsElevenlabsModel;
      _ttsOpenaiVoice = TtsService.openaiVoices.contains(ttsOpenaiVoice)
          ? ttsOpenaiVoice
          : 'nova';
      _ttsElevenlabsVoiceId = ttsElevenlabsVoiceId;
      _ttsVoiceIds = ttsVoiceIds;
      _ttsVoiceLabels = ttsVoiceLabels;
      _webSearchMode = webMode;
      _webSearchModel = webModel;
      _loaded = true;
    });
    unawaited(_discoverEmbeddingModels());
  }

  @override
  void dispose() {
    _ttsVoiceIdController.dispose();
    super.dispose();
  }

  Future<void> _addTtsVoiceId() async {
    final value = _ttsVoiceIdController.text.trim();
    if (value.isEmpty) return;
    final voiceIds = await TtsSettings.addAndSelectVoiceId(value);
    if (!mounted) return;
    setState(() {
      _ttsVoiceIds = voiceIds;
      _ttsElevenlabsVoiceId = value;
      _ttsVoiceIdController.clear();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1200),
        content: Text(
          L.pick(
            en: 'Voice ID saved and selected',
            zhTW: 'Voice ID 已儲存並設為預設',
            zhCN: 'Voice ID 已保存并设为默认',
          ),
        ),
      ),
    );
  }

  Future<void> _removeTtsVoiceId(String voiceId) async {
    await TtsSettings.removeVoiceId(voiceId);
    final voiceIds = await TtsSettings.getVoiceIdList();
    final selected = await TtsSettings.getTtsElevenlabsVoiceId();
    if (!mounted) return;
    setState(() {
      _ttsVoiceIds = voiceIds;
      _ttsElevenlabsVoiceId = selected;
      _ttsVoiceLabels = Map<String, String>.from(_ttsVoiceLabels)
        ..remove(voiceId);
    });
  }

  Future<void> _renameTtsVoiceId(String voiceId) async {
    final controller = TextEditingController(
      text: _ttsVoiceLabels[voiceId] ?? '',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Voice name', zhTW: '聲音名稱', zhCN: '声音名称'),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: YanciTheme.themedInputDecoration(
            hintText: L.pick(
              en: 'For example: soft Cantonese',
              zhTW: '例如：溫柔粵語',
              zhCN: '例如：温柔粤语',
            ),
          ),
          onSubmitted: (text) => Navigator.of(dialogContext).pop(text),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消', zhCN: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(L.pick(en: 'Save', zhTW: '儲存', zhCN: '保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await TtsSettings.saveVoiceIdLabel(voiceId, value);
    final labels = await TtsSettings.getVoiceIdLabels();
    if (mounted) setState(() => _ttsVoiceLabels = labels);
  }

  Future<void> _discoverEmbeddingModels() async {
    final openRouterKey = await ApiSettings.getOpenRouterApiKey();
    final geminiKey = await ApiSettings.getGeminiApiKey();
    final deepInfraKey = await ApiSettings.getDeepInfraApiKey();
    final relayKey = await ApiSettings.getOaiCompatApiKey();
    final relayBase = await ApiSettings.getOaiCompatBaseUrl();
    final requests = <Future<List<StarredModelEntry>>>[];

    void add(String provider, String key, {String baseUrl = ''}) {
      if (provider == 'openai_compatible') {
        if (baseUrl.trim().isEmpty) return;
      } else if (key.trim().isEmpty) {
        return;
      }
      requests.add(() async {
        try {
          final models = await ProviderModelCatalog.fetchEmbeddingModels(
            provider: provider,
            apiKey: key.trim(),
            baseUrl: baseUrl.trim(),
          );
          return models
              .map(
                (model) =>
                    StarredModelEntry(provider: provider, modelId: model.id),
              )
              .toList(growable: false);
        } catch (_) {
          return const <StarredModelEntry>[];
        }
      }());
    }

    add('openrouter', openRouterKey);
    add('gemini', geminiKey);
    add('deepinfra', deepInfraKey);
    add('openai_compatible', relayKey, baseUrl: relayBase);
    final discovered = await Future.wait(requests);
    if (!mounted) return;
    final unique = <String, StarredModelEntry>{};
    for (final entry in discovered.expand((group) => group)) {
      unique[entry.identity] = entry;
    }
    setState(() => _embeddingModels = unique.values.toList(growable: false));
  }

  Future<String> _loadWebSearchModel(WebSearchMode mode) => switch (mode) {
    WebSearchMode.openRouter => WebSearchSettings.getOpenRouterSearchModel(),
    WebSearchMode.gemini => WebSearchSettings.getGeminiSearchModel(),
    WebSearchMode.xai => WebSearchSettings.getXaiSearchModel(),
    WebSearchMode.relay => WebSearchSettings.getRelayModel(),
    _ => Future<String>.value(''),
  };

  Future<void> _saveWebSearchModel(String value) => switch (_webSearchMode) {
    WebSearchMode.openRouter => WebSearchSettings.saveOpenRouterSearchModel(
      value,
    ),
    WebSearchMode.gemini => WebSearchSettings.saveGeminiSearchModel(value),
    WebSearchMode.xai => WebSearchSettings.saveXaiSearchModel(value),
    WebSearchMode.relay => WebSearchSettings.saveRelayModel(value),
    _ => Future<void>.value(),
  };

  String _selection(String provider, String model) => model.trim().isEmpty
      ? ''
      : '${provider.trim()}$_separator${model.trim()}';

  String _providerLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'gemini' => 'Gemini',
    'xai' => 'xAI',
    'deepseek' => 'DeepSeek',
    'deepinfra' => 'DeepInfra',
    'qwen' => 'Qwen',
    'bedrock' => 'AWS Bedrock',
    'thinking_machines' => 'Inkling',
    'openai_compatible' => L.pick(
      en: 'Custom Relay',
      zhTW: '自訂中轉站',
      zhCN: '自定义中转站',
    ),
    'local_api' => L.pick(en: 'Local API', zhTW: '本地 API', zhCN: '本地 API'),
    'local' => L.pick(en: 'On-device', zhTW: '裝置本地', zhCN: '设备本地'),
    _ => provider.isEmpty ? '—' : provider,
  };

  Widget _modelDropdown({
    required String provider,
    required String model,
    required List<StarredModelEntry> entries,
    required String emptyLabel,
    required ValueChanged<StarredModelEntry?> onChanged,
  }) {
    final options = <String, StarredModelEntry>{};
    for (final entry in entries) {
      if (entry.provider.isNotEmpty && entry.modelId.isNotEmpty) {
        options[entry.identity] = entry;
      }
    }
    if (model.isNotEmpty && provider.isNotEmpty) {
      final current = StarredModelEntry(provider: provider, modelId: model);
      options[current.identity] = current;
    }
    final selected = _selection(provider, model);
    return DropdownButton<String>(
      value: options.containsKey(selected) ? selected : '',
      isExpanded: true,
      style: YanciTheme.bodySmall.copyWith(
        color: SidebarVisualTokens.secondary,
        fontSize: 11.5,
      ),
      underline: const SizedBox.shrink(),
      dropdownColor: YanciTheme.surfacePanel,
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem(value: '', child: Text(emptyLabel)),
        ...options.values.map(
          (entry) => DropdownMenuItem<String>(
            value: entry.identity,
            child: Text(
              '${entry.modelId} · ${_providerLabel(entry.provider)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: (identity) => onChanged(
        identity == null || identity.isEmpty ? null : options[identity],
      ),
    );
  }

  Widget _buildSummaryModel() {
    // UI_SLOT: sidebar_summary_model
    return SidebarAccordionSection(
      id: 'summary_model',
      relationGroup: 'memory_models',
      title: Text(L.pick(en: 'Summary model', zhTW: '摘要模型', zhCN: '摘要模型')),
      children: [
        ApiMemorySettingsCard(
          summaryProvider: _summaryProvider,
          summaryModel: _summaryModel,
          embeddingProvider: _embeddingProvider,
          embeddingModel: _embeddingModel,
          embeddingModelEntries: _embeddingModels,
          starredModelEntries: _starred,
          availableModelEntries: _starred,
          dreamCurationEnabled: false,
          dreamCurationThreshold: MemorySettings.defaultDreamThreshold,
          showSummarySelection: true,
          showAdvancedMemoryOptions: false,
          showRpSummaryOptions: true,
          borderColor: Colors.transparent,
          onSummarySelectionChanged: (provider, model) async {
            setState(() {
              _summaryProvider = provider;
              _summaryModel = model;
            });
            await MemorySettings.saveSummarySelection(
              provider: provider,
              model: model,
            );
            if (model.trim().isEmpty) {
              await Future.wait<void>([
                MemorySettings.saveCacheWindowSummaryEnabled(false),
                MemorySettings.saveContextWindowSummaryEnabled(false),
              ]);
            }
            if (mounted) setState(() {});
          },
          onEmbeddingSelectionChanged: (_, _) {},
          onDreamCurationChanged: (_) {},
          onDreamCurationThresholdChanged: (_) {},
        ),
      ],
    );
  }

  Widget _buildEmbeddingModel() {
    final entries = <StarredModelEntry>[
      ..._embeddingModels,
      ..._starred.where(
        (entry) => entry.modelId.toLowerCase().contains('embedding'),
      ),
    ];
    // UI_SLOT: sidebar_embedding_model
    return SidebarAccordionSection(
      id: 'embedding_model',
      relationGroup: 'memory_models',
      title: Text(
        L.pick(en: 'Vector recall model', zhTW: '向量召回模型', zhCN: '向量召回模型'),
      ),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        _modelDropdown(
          provider: _embeddingProvider,
          model: _embeddingModel,
          entries: entries,
          emptyLabel: L.pick(
            en: 'Off · trigram only',
            zhTW: '關閉 · 僅使用 trigram',
            zhCN: '关闭 · 仅使用 trigram',
          ),
          onChanged: (entry) {
            final provider = entry?.provider ?? '';
            final model = entry?.modelId ?? '';
            setState(() {
              _embeddingProvider = provider;
              _embeddingModel = model;
            });
            unawaited(
              MemorySettings.saveEmbeddingSelection(
                provider: provider,
                model: model,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildImageModel() {
    // UI_SLOT: sidebar_image_model
    return SidebarAccordionSection(
      id: 'image_model',
      relationGroup: 'media_models',
      title: Text(L.pick(en: 'Image model', zhTW: '畫圖模型', zhCN: '画图模型')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: const [ImageGenerationSettingsCard()],
    );
  }

  Widget _buildStickerModel() {
    // UI_SLOT: sidebar_sticker_vision_model
    return SidebarAccordionSection(
      id: 'sticker_model',
      relationGroup: 'media_models',
      title: Text(
        L.pick(en: 'Sticker recognition model', zhTW: '表情辨識模型', zhCN: '表情识别模型'),
      ),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        _modelDropdown(
          provider: _stickerProvider,
          model: _stickerModel,
          entries: _starred,
          emptyLabel: L.pick(
            en: 'Follow chat model',
            zhTW: '跟隨聊天模型',
            zhCN: '跟随聊天模型',
          ),
          onChanged: (entry) {
            final provider = entry?.provider ?? '';
            final model = entry?.modelId ?? '';
            setState(() {
              _stickerProvider = provider;
              _stickerModel = model;
            });
            unawaited(
              UserSettings.saveStickerVisionSelection(
                provider: provider,
                model: model,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildVoiceModel() {
    // UI_SLOT: functional_tts_model
    final modelItems = _ttsProvider == 'elevenlabs'
        ? TtsService.elevenlabsModels.entries
              .map(
                (entry) => DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(growable: false)
        : const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'tts-1', child: Text('tts-1')),
          ];
    final selectedModel = _ttsProvider == 'elevenlabs'
        ? (TtsService.elevenlabsModels.containsKey(_ttsElevenlabsModel)
              ? _ttsElevenlabsModel
              : 'eleven_multilingual_v2')
        : 'tts-1';
    return SidebarAccordionSection(
      id: 'voice_model',
      relationGroup: 'media_models',
      title: Text(L.pick(en: 'Voice model', zhTW: '聲音模型', zhCN: '声音模型')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: <Widget>[
        DropdownButton<String>(
          key: const ValueKey('functional_tts_provider'),
          value: _ttsProvider == 'elevenlabs' ? 'elevenlabs' : 'openai',
          isExpanded: true,
          underline: const SizedBox.shrink(),
          dropdownColor: YanciTheme.surfacePanel,
          style: YanciTheme.bodySmall.copyWith(
            color: SidebarVisualTokens.secondary,
            fontSize: 11.5,
          ),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(
              value: 'openai',
              child: Text('OpenAI TTS'),
            ),
            DropdownMenuItem<String>(
              value: 'elevenlabs',
              child: Text('ElevenLabs'),
            ),
          ],
          onChanged: (provider) {
            if (provider == null) return;
            setState(() => _ttsProvider = provider);
            unawaited(TtsSettings.saveTtsProvider(provider));
          },
        ),
        const SizedBox(height: 4),
        DropdownButton<String>(
          key: const ValueKey('functional_tts_model'),
          value: selectedModel,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          dropdownColor: YanciTheme.surfacePanel,
          style: YanciTheme.bodySmall.copyWith(
            color: SidebarVisualTokens.secondary,
            fontSize: 11.5,
          ),
          items: modelItems,
          onChanged: _ttsProvider == 'elevenlabs'
              ? (model) {
                  if (model == null) return;
                  setState(() => _ttsElevenlabsModel = model);
                  unawaited(TtsSettings.saveTtsElevenlabsModel(model));
                }
              : null,
        ),
        const SizedBox(height: 8),
        if (_ttsProvider == 'openai')
          DropdownButton<String>(
            key: const ValueKey('functional_tts_openai_voice'),
            value: _ttsOpenaiVoice,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: YanciTheme.surfacePanel,
            style: YanciTheme.bodySmall.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 11.5,
            ),
            items: TtsService.openaiVoices
                .map(
                  (voice) => DropdownMenuItem<String>(
                    value: voice,
                    child: Text(voice),
                  ),
                )
                .toList(growable: false),
            onChanged: (voice) {
              if (voice == null) return;
              setState(() => _ttsOpenaiVoice = voice);
              unawaited(TtsSettings.saveTtsVoice(voice));
            },
          )
        else ...<Widget>[
          DropdownButton<String>(
            key: const ValueKey('functional_tts_elevenlabs_voice'),
            value:
                _ttsElevenlabsVoiceId.isEmpty ||
                    !_ttsVoiceIds.contains(_ttsElevenlabsVoiceId)
                ? ''
                : _ttsElevenlabsVoiceId,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: YanciTheme.surfacePanel,
            style: YanciTheme.bodySmall.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 11.5,
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: '',
                child: Text(
                  L.pick(
                    en: 'Select a default Voice ID',
                    zhTW: '選擇預設 Voice ID',
                    zhCN: '选择默认 Voice ID',
                  ),
                ),
              ),
              ..._ttsVoiceIds.map(
                (voiceId) => DropdownMenuItem<String>(
                  value: voiceId,
                  child: Text(
                    TtsSettings.voiceIdDisplayName(
                      voiceId,
                      _ttsVoiceLabels,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            onChanged: (voiceId) {
              if (voiceId == null) return;
              setState(() => _ttsElevenlabsVoiceId = voiceId);
              unawaited(TtsSettings.saveTtsElevenlabsVoiceId(voiceId));
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey('functional_tts_voice_id_input'),
                  controller: _ttsVoiceIdController,
                  style: YanciTheme.bodySmall.copyWith(
                    color: SidebarVisualTokens.primary,
                    fontSize: 11.5,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_addTtsVoiceId()),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: L.pick(
                      en: 'Paste a new Voice ID',
                      zhTW: '貼上新的 Voice ID',
                      zhCN: '粘贴新的 Voice ID',
                    ),
                    hintStyle: YanciTheme.bodySmall.copyWith(
                      color: SidebarVisualTokens.secondary.withValues(
                        alpha: 0.62,
                      ),
                      fontSize: 11,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('functional_tts_voice_id_add'),
                tooltip: L.pick(
                  en: 'Add Voice ID',
                  zhTW: '新增 Voice ID',
                  zhCN: '新增 Voice ID',
                ),
                onPressed: () => unawaited(_addTtsVoiceId()),
                icon: const Icon(Icons.add_rounded, size: 19),
              ),
            ],
          ),
          if (_ttsVoiceIds.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _ttsVoiceIds
                  .map(
                    (voiceId) => InputChip(
                      avatar: IconButton(
                        tooltip: L.pick(
                          en: 'Rename voice',
                          zhTW: '命名聲音',
                          zhCN: '命名声音',
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        icon: const Icon(Icons.edit_rounded, size: 13),
                        onPressed: () => unawaited(_renameTtsVoiceId(voiceId)),
                      ),
                      label: Text(
                        TtsSettings.voiceIdDisplayName(
                          voiceId,
                          _ttsVoiceLabels,
                          compact: true,
                        ),
                      ),
                      labelStyle: YanciTheme.bodySmall.copyWith(fontSize: 10.5),
                      backgroundColor: YanciTheme.glassInputBg,
                      side: BorderSide(
                        color: YanciTheme.glassBorder.withValues(alpha: 0.7),
                        width: 0.5,
                      ),
                      deleteIcon: const Icon(Icons.close_rounded, size: 14),
                      onDeleted: () => unawaited(_removeTtsVoiceId(voiceId)),
                    ),
                  )
                  .toList(growable: false),
            ),
          const SizedBox(height: 4),
          Text(
            L.pick(
              en: 'Characters can bind their own Voice ID in the character card. Unbound characters use this default.',
              zhTW: '角色可在人設卡綁定專屬 Voice ID；未綁定時使用這個預設聲音。',
              zhCN: '角色可在人设卡绑定专属 Voice ID；未绑定时使用这个默认声音。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              color: SidebarVisualTokens.secondary.withValues(alpha: 0.62),
              fontSize: 10.5,
            ),
          ),
        ],
      ],
    );
  }

  Iterable<StarredModelEntry> get _webSearchOptions sync* {
    final provider = switch (_webSearchMode) {
      WebSearchMode.openRouter => 'openrouter',
      WebSearchMode.gemini => 'gemini',
      WebSearchMode.xai => 'xai',
      WebSearchMode.relay => 'openai_compatible',
      _ => '',
    };
    if (provider.isEmpty) return;
    yield* _starred.where((entry) => entry.provider == provider);
  }

  Widget _buildSearchModel() {
    // UI_SLOT: functional_search_model
    return SidebarAccordionSection(
      id: 'search_model',
      relationGroup: 'functional_models',
      title: Text(L.pick(en: 'Search model', zhTW: '搜尋模型', zhCN: '搜索模型')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        DropdownButton<WebSearchMode>(
          value: _webSearchMode,
          isExpanded: true,
          style: YanciTheme.bodySmall.copyWith(
            color: SidebarVisualTokens.secondary,
            fontSize: 11.5,
          ),
          underline: const SizedBox.shrink(),
          dropdownColor: YanciTheme.surfacePanel,
          items: [
            DropdownMenuItem(
              value: WebSearchMode.auto,
              child: Text(L.pick(en: 'Automatic', zhTW: '自動', zhCN: '自动')),
            ),
            const DropdownMenuItem(
              value: WebSearchMode.gemini,
              child: Text('Gemini'),
            ),
            const DropdownMenuItem(
              value: WebSearchMode.openRouter,
              child: Text('OpenRouter'),
            ),
            const DropdownMenuItem(
              value: WebSearchMode.xai,
              child: Text('xAI'),
            ),
            DropdownMenuItem(
              value: WebSearchMode.relay,
              child: Text(
                L.pick(en: 'Custom Relay', zhTW: '自訂中轉站', zhCN: '自定义中转站'),
              ),
            ),
          ],
          onChanged: (mode) async {
            if (mode == null) return;
            await WebSearchSettings.saveMode(mode);
            final model = await _loadWebSearchModel(mode);
            if (!mounted) return;
            setState(() {
              _webSearchMode = mode;
              _webSearchModel = model;
            });
          },
        ),
        if (_webSearchMode != WebSearchMode.auto)
          _modelDropdown(
            provider: switch (_webSearchMode) {
              WebSearchMode.openRouter => 'openrouter',
              WebSearchMode.gemini => 'gemini',
              WebSearchMode.xai => 'xai',
              WebSearchMode.relay => 'openai_compatible',
              _ => '',
            },
            model: _webSearchModel,
            entries: _webSearchOptions.toList(growable: false),
            emptyLabel: L.pick(
              en: 'Use provider default',
              zhTW: '使用來源預設模型',
              zhCN: '使用来源默认模型',
            ),
            onChanged: (entry) {
              final model = entry?.modelId ?? '';
              setState(() => _webSearchModel = model);
              unawaited(_saveWebSearchModel(model));
            },
          ),
      ],
    );
  }

  Widget _navigationTile({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          minVerticalPadding: 11,
          title: Text(
            title,
            style: YanciTheme.bodyText.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: YanciTheme.bodySmall.copyWith(
              color: SidebarVisualTokens.secondary.withValues(alpha: 0.72),
              fontSize: 11,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: SidebarVisualTokens.secondary.withValues(alpha: 0.62),
          ),
          onTap: onTap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pageMode) {
      return Column(
        children: [
          // UI_SLOT: sidebar_chat_model
          _navigationTile(
            title: L.pick(en: 'Chat model', zhTW: '聊天模型', zhCN: '聊天模型'),
            subtitle: L.pick(
              en: 'Source, API key, model and favorites',
              zhTW: '來源、API Key、模型與我的收藏模型',
              zhCN: '来源、API Key、模型与我的收藏模型',
            ),
            onTap: () {
              HoltSidebarShell.maybeOf(context)?.close();
              Navigator.of(context).pushNamed('/api_settings');
            },
          ),
          // UI_SLOT: sidebar_functional_models
          _navigationTile(
            title: L.pick(
              en: 'Other functional models',
              zhTW: '其他功能模型設定',
              zhCN: '其他功能模型设置',
            ),
            subtitle: L.pick(
              en: 'Summary, vector, image, recognition, voice and search',
              zhTW: '摘要、向量、畫圖、辨識、聲音與搜尋模型',
              zhCN: '摘要、向量、画图、识别、声音与搜索模型',
            ),
            onTap: () {
              HoltSidebarShell.maybeOf(context)?.close();
              Navigator.of(context).pushNamed('/functional_models');
            },
          ),
        ],
      );
    }
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        _buildSummaryModel(),
        _buildEmbeddingModel(),
        _buildImageModel(),
        _buildStickerModel(),
        _buildVoiceModel(),
        _buildSearchModel(),
        // UI_SLOT: functional_starred_models
        _navigationTile(
          title: L.pick(
            en: 'My favorite models',
            zhTW: '我的收藏模型',
            zhCN: '我的收藏模型',
          ),
          subtitle: L.pick(
            en: 'View and remove starred models',
            zhTW: '查看與刪除已收藏的模型',
            zhCN: '查看与删除已收藏的模型',
          ),
          onTap: () => Navigator.of(context).pushNamed('/api_settings'),
        ),
      ],
    );
  }
}
