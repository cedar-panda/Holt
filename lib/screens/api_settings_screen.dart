import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/openai_compatible_service.dart';
import '../services/model_info.dart';
import '../services/provider_model_catalog.dart';
import '../services/thinking_machines_service.dart';
import '../services/model_cost_policy.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/web_search_service.dart';
import '../widgets/gradient_background.dart';
import '../widgets/api_advanced_settings.dart';

class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  Timer? _saveTimer;
  Timer? _modelFetchTimer;
  String _provider = 'openrouter';
  bool _settingsLoaded = false;
  bool _settingsDirty = false;
  bool _isPopping = false;
  Future<void>? _saveLoop;
  int _modelFetchGeneration = 0;
  bool _lastPolicySelectionWasClaude = false;

  void _debouncedSave() {
    if (!_settingsLoaded) return;
    _settingsDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushPendingSave().catchError(_reportSaveError));
    });
  }

  void _reportSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Settings could not be saved: $error',
            zhTW: '設定保存失敗：$error',
          ),
        ),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  Future<void> _flushPendingSave() async {
    _saveTimer?.cancel();
    if (!_settingsLoaded) return;

    final running = _saveLoop;
    if (running != null) {
      await running;
      return;
    }

    final loop = _drainPendingSaves();
    _saveLoop = loop;
    try {
      await loop;
    } finally {
      if (identical(_saveLoop, loop)) _saveLoop = null;
    }
  }

  Future<void> _drainPendingSaves() async {
    while (_settingsDirty) {
      _settingsDirty = false;
      try {
        await _saveSettings();
      } catch (_) {
        _settingsDirty = true;
        rethrow;
      }
    }
  }

  Future<void> _handleBack() async {
    if (_isPopping) return;
    _isPopping = true;
    try {
      await _flushPendingSave();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _reportSaveError(e);
      _isPopping = false;
    }
  }

  final _apiKeyController = TextEditingController();
  final _xaiKeyCtrl = TextEditingController();
  final _systemPromptController = TextEditingController();

  final _geminiKeyCtrl = TextEditingController();
  final _deepseekKeyCtrl = TextEditingController();
  final _qwenKeyCtrl = TextEditingController();

  final _awsAccessKeyIdCtrl = TextEditingController();
  final _awsSecretAccessKeyCtrl = TextEditingController();
  final _awsRegionCtrl = TextEditingController();

  final _oaiCompatBaseUrlCtrl = TextEditingController();
  final _oaiCompatKeyCtrl = TextEditingController();
  final _oaiCompatModelCtrl = TextEditingController();

  final _thinkingMachinesKeyCtrl = TextEditingController();
  final _thinkingMachinesModelCtrl = TextEditingController();
  String _thinkingMachinesEffort = 'high';

  String _selectedModel = '';
  String _summaryProvider = MemorySettings.defaultSummaryProvider;
  String _summaryModel = MemorySettings.defaultSummaryModel;
  bool _dreamCurationEnabled = false;
  int _dreamCurationThreshold = MemorySettings.defaultDreamThreshold;
  bool _webSearchEnabled = false;
  WebSearchMode _webSearchMode = WebSearchMode.auto;
  int _webSearchDailyProviderLaunchCap =
      WebSearchSettings.defaultDailyProviderLaunchCap;
  String _webSearchGeminiModel = '';
  String _wsSearchOrModelOverride = '';
  String _wsSearchGeminiModelOverride = '';
  List<ModelInfo> _models = [];
  List<ModelInfo> _filteredModels = [];
  Set<String> _starredModels = {};
  Map<String, String> _starredModelProviders = {};
  final _modelSearchController = TextEditingController();

  bool _isFetchingModels = false;
  bool _isTestingApi = false;
  String? _modelError;
  String? _modelErrorProvider;
  bool _showModelSection = false;
  bool _obscureProviderKeys = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    final xaiKey = await ApiSettings.getXaiApiKey();
    final systemPrompt = await ApiSettings.getSystemPrompt();
    final provider = await ApiSettings.getApiProvider();

    final gm = await ApiSettings.getGeminiApiKey();
    final ds = await ApiSettings.getDeepseekApiKey();
    final qw = await ApiSettings.getQwenApiKey();

    final awsId = await ApiSettings.getAwsAccessKeyId();
    final awsSec = await ApiSettings.getAwsSecretAccessKey();
    final awsReg = await ApiSettings.getAwsRegion();

    final oaiBase = await ApiSettings.getOaiCompatBaseUrl();
    final oaiKey = await ApiSettings.getOaiCompatApiKey();
    final oaiMod = await ApiSettings.getOaiCompatModel();

    final thinkingMachinesKey = await ApiSettings.getThinkingMachinesApiKey();
    final thinkingMachinesModel = await ApiSettings.getThinkingMachinesModel();
    final thinkingMachinesEffort =
        await ApiSettings.getThinkingMachinesEffort();
    final webSearchEnabled = await WebSearchSettings.getEnabled();
    final webSearchMode = await WebSearchSettings.getMode();
    final webSearchDailyProviderLaunchCap =
        await WebSearchSettings.getDailyProviderLaunchCap();
    final webSearchGeminiModel = await ApiSettings.getModelForProvider(
      'gemini',
    );
    final wsSearchOrOverride =
        await WebSearchSettings.getOpenRouterSearchModel();
    final wsSearchGeminiOverride =
        await WebSearchSettings.getGeminiSearchModel();

    final starred = await ApiSettings.getStarredModels();
    var starredProviders = await ApiSettings.getStarredModelProviders();
    for (final model in starred) {
      if ((starredProviders[model] ?? '').isEmpty) {
        await ApiSettings.resolveStarredModelProvider(model);
      }
    }
    starredProviders = await ApiSettings.getStarredModelProviders();
    final summaryModel = await MemorySettings.getSummaryModel();
    var summaryProvider = await MemorySettings.getSummaryProvider();
    if (summaryModel.isNotEmpty && summaryProvider.isEmpty) {
      summaryProvider = await ApiSettings.resolveStarredModelProvider(
        summaryModel,
      );
    }
    final dreamEnabled = await MemorySettings.getDreamCurationEnabled();
    final dreamThreshold = await MemorySettings.getDreamCurationThreshold();
    final savedModel = await ApiSettings.getModelForProvider(provider);

    if (mounted) {
      setState(() {
        _apiKeyController.text = apiKey;
        _xaiKeyCtrl.text = xaiKey;
        _systemPromptController.text = systemPrompt;
        _provider = provider;

        _geminiKeyCtrl.text = gm;
        _deepseekKeyCtrl.text = ds;
        _qwenKeyCtrl.text = qw;

        _awsAccessKeyIdCtrl.text = awsId;
        _awsSecretAccessKeyCtrl.text = awsSec;
        _awsRegionCtrl.text = awsReg;

        _oaiCompatBaseUrlCtrl.text = oaiBase;
        _oaiCompatKeyCtrl.text = oaiKey;
        _oaiCompatModelCtrl.text = oaiMod;

        _thinkingMachinesKeyCtrl.text = thinkingMachinesKey;
        _thinkingMachinesModelCtrl.text = thinkingMachinesModel;
        _thinkingMachinesEffort = thinkingMachinesEffort;

        _starredModels = starred.toSet();
        _starredModelProviders = starredProviders;
        _selectedModel = savedModel;
        _summaryProvider = summaryProvider;
        _summaryModel = summaryModel;
        _dreamCurationEnabled = dreamEnabled;
        _dreamCurationThreshold = dreamThreshold;
        _webSearchEnabled = webSearchEnabled;
        _webSearchMode = webSearchMode;
        _webSearchDailyProviderLaunchCap = webSearchDailyProviderLaunchCap;
        _webSearchGeminiModel = webSearchGeminiModel;
        _wsSearchOrModelOverride = wsSearchOrOverride;
        _wsSearchGeminiModelOverride = wsSearchGeminiOverride;
        _lastPolicySelectionWasClaude = TokenEstimator.isClaudePromptCacheModel(
          provider: provider,
          model: savedModel,
        );
        _settingsLoaded = true;
      });
      if (_provider == 'openrouter' && apiKey.isNotEmpty) {
        _fetchModels();
      } else if (_provider == 'xai' && xaiKey.isNotEmpty) {
        _fetchModels();
      } else if (_provider == 'gemini' && gm.isNotEmpty) {
        _fetchModels();
      } else if (_provider == 'deepseek' && ds.isNotEmpty) {
        _fetchModels();
      } else if (_provider == 'openai_compatible' && oaiBase.isNotEmpty) {
        _fetchModels();
      }
      if (provider == 'thinking_machines' && thinkingMachinesKey.isNotEmpty) {
        await _applyCostPolicy(
          provider: provider,
          model: savedModel,
          apiKey: thinkingMachinesKey,
        );
      }
    }
  }

  Future<void> _fetchModels() async {
    final provider = _provider;
    final requestGeneration = ++_modelFetchGeneration;
    final isCompatible = provider == 'openai_compatible';
    final isXai = provider == 'xai';
    final isGemini = provider == 'gemini';
    final isDeepSeek = provider == 'deepseek';
    if (!ProviderModelCatalog.supports(provider)) {
      if (mounted && requestGeneration == _modelFetchGeneration) {
        setState(() {
          _isFetchingModels = false;
          _modelError = null;
          _modelErrorProvider = null;
          _models = const <ModelInfo>[];
          _filteredModels = const <ModelInfo>[];
        });
      }
      return;
    }
    final apiKey = isCompatible
        ? _oaiCompatKeyCtrl.text.trim()
        : isXai
        ? _xaiKeyCtrl.text.trim()
        : isGemini
        ? _geminiKeyCtrl.text.trim()
        : isDeepSeek
        ? _deepseekKeyCtrl.text.trim()
        : _apiKeyController.text.trim();
    final baseUrl = _oaiCompatBaseUrlCtrl.text.trim();
    if ((!isCompatible && apiKey.isEmpty) ||
        (isCompatible && baseUrl.isEmpty)) {
      if (mounted) {
        setState(() {
          _isFetchingModels = false;
          _modelError = isCompatible
              ? L.pick(en: 'Enter a Base URL first', zhTW: '請先輸入 Base URL')
              : L.pick(
                  en: 'Enter a ${ProviderModelCatalog.label(provider)} API key first',
                  zhTW: '請先輸入 ${ProviderModelCatalog.label(provider)} API Key',
                  zhCN: '请先输入 ${ProviderModelCatalog.label(provider)} API Key',
                );
          _modelErrorProvider = provider;
        });
      }
      return;
    }
    setState(() {
      _isFetchingModels = true;
      _modelError = null;
      _modelErrorProvider = null;
    });

    try {
      final models = await ProviderModelCatalog.fetch(
        provider: provider,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );
      if (mounted &&
          requestGeneration == _modelFetchGeneration &&
          _provider == provider) {
        await ApiSettings.rememberStarredModelProviders(
          models.map((model) => model.id),
          ProviderModelCatalog.providerTag(provider),
        );
        if (!mounted || requestGeneration != _modelFetchGeneration) return;
        setState(() {
          _models = models;
          _filteredModels = models;
          _isFetchingModels = false;
          _modelErrorProvider = null;
          if (isCompatible) _showModelSection = true;
        });
      }
    } catch (e) {
      if (mounted &&
          requestGeneration == _modelFetchGeneration &&
          _provider == provider) {
        setState(() {
          _isFetchingModels = false;
          _modelError = '${L.get('settings_model_error_fetch')}: $e';
          _modelErrorProvider = provider;
        });
      }
    }
  }

  void _scheduleProviderModelFetch(String provider, String key) {
    _modelFetchTimer?.cancel();
    final normalizedKey = key.trim();
    final looksUsable = ProviderModelCatalog.looksUsableKey(
      provider,
      normalizedKey,
    );
    if (_provider != provider || !looksUsable) {
      _modelFetchGeneration++;
      if (mounted) {
        setState(() {
          _isFetchingModels = false;
          if (_modelErrorProvider == provider) {
            _modelError = null;
            _modelErrorProvider = null;
          }
        });
      }
      return;
    }
    _modelFetchTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(_fetchModels()),
    );
  }

  void _scheduleCompatibleModelFetch(String baseUrl) {
    _modelFetchTimer?.cancel();
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return;
    _modelFetchTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(_fetchModels()),
    );
  }

  Future<void> _testApiConnection(String provider, String keyStr) async {
    if (keyStr.isEmpty && provider != 'openai_compatible') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(en: 'Enter an API key first', zhTW: '請先輸入 API Key'),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }
    setState(() {
      _isTestingApi = true;
    });

    try {
      http.Response? response;
      if (provider == 'gemini') {
        response = await http
            .get(
              Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models',
              ),
              headers: {'x-goog-api-key': keyStr},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'deepseek') {
        response = await http
            .get(
              Uri.parse('https://api.deepseek.com/models'),
              headers: {'Authorization': 'Bearer $keyStr'},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'qwen') {
        response = await http
            .get(
              Uri.parse(
                'https://dashscope.aliyuncs.com/api/v1/deployments/models?page_no=1&page_size=1&version=v1.0&model_source=base',
              ),
              headers: {'Authorization': 'Bearer $keyStr'},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'openai_compatible') {
        final rawBase = _oaiCompatBaseUrlCtrl.text.trim();
        final modelsUri = OpenAICompatibleService.modelsUriForBase(rawBase);
        response = await http
            .get(
              modelsUri,
              headers: {
                if (keyStr.isNotEmpty) 'Authorization': 'Bearer $keyStr',
              },
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'thinking_machines') {
        await ThinkingMachinesService.testConnection(
          apiKey: keyStr,
          model: _thinkingMachinesModelCtrl.text.trim(),
        );
        response = http.Response('{}', 200);
      } else if (provider == 'openai') {
        response = await http
            .get(
              Uri.parse('https://api.openai.com/v1/models'),
              headers: {'Authorization': 'Bearer $keyStr'},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'openrouter') {
        response = await http
            .get(
              Uri.parse('https://openrouter.ai/api/v1/models'),
              headers: {'Authorization': 'Bearer $keyStr'},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'xai') {
        response = await http
            .get(
              Uri.parse('https://api.x.ai/v1/language-models'),
              headers: {'Authorization': 'Bearer $keyStr'},
            )
            .timeout(const Duration(seconds: 20));
      }

      if (response != null) {
        if (response.statusCode == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(en: 'Connection successful ☑️', zhTW: '連線成功 ☑️'),
                ),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          throw Exception('Status ${response.statusCode}: ${response.body}');
        }
      } else {
        throw UnsupportedError('尚未實作此服務的連線測試');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${L.pick(en: 'Connection failed', zhTW: '連線失敗')}: $e',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTestingApi = false);
    }
  }

  void _filterModels(String query) {
    if (query.isEmpty) {
      setState(() => _filteredModels = _models);
      return;
    }
    final q = query.toLowerCase();
    setState(() {
      _filteredModels = _models.where((m) {
        return m.id.toLowerCase().contains(q) ||
            m.name.toLowerCase().contains(q);
      }).toList();
    });
  }

  String _modelValueForProvider() {
    if (_provider == 'openai_compatible') {
      return _oaiCompatModelCtrl.text.trim();
    }
    if (_provider == 'thinking_machines') {
      final model = _thinkingMachinesModelCtrl.text.trim();
      return model.isEmpty ? ThinkingMachinesService.defaultModel : model;
    }
    return _selectedModel;
  }

  static const String _summarySelectionSeparator = '\u0000';

  String _summarySelectionValue(String provider, String model) {
    if (model.isEmpty) return '';
    return '$provider$_summarySelectionSeparator$model';
  }

  List<({String provider, String model})> _summaryModelOptions() {
    final options = <({String provider, String model})>[];
    final seen = <String>{};

    void add(String provider, String model) {
      final normalizedModel = model.trim();
      final normalizedProvider = normalizedModel.isEmpty ? '' : provider.trim();
      final value = _summarySelectionValue(normalizedProvider, normalizedModel);
      if (seen.add(value)) {
        options.add((provider: normalizedProvider, model: normalizedModel));
      }
    }

    add('', '');
    add(
      MemorySettings.defaultSummaryProvider,
      MemorySettings.defaultSummaryModel,
    );
    add(_summaryProvider, _summaryModel);

    final starred = _starredModels.toList()..sort();
    for (final model in starred) {
      final provider = _starredModelProviders[model] ?? '';
      if (provider.isNotEmpty) add(provider, model);
    }
    return options;
  }

  String _providerLabel(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'xai' => 'xAI (Grok)',
    'gemini' => 'Google Gemini',
    'deepseek' => 'DeepSeek',
    'qwen' => 'Qwen',
    'bedrock' => 'AWS Bedrock',
    'thinking_machines' => 'Thinking Machines',
    'openai_compatible' => 'OpenAI Compatible',
    'local' => L.pick(en: 'Local Model', zhTW: '本地模型'),
    'local_api' => 'Local API',
    _ => provider,
  };

  Widget _buildSummaryModelCard() {
    final options = _summaryModelOptions();
    final selected = _summarySelectionValue(_summaryProvider, _summaryModel);
    final selectedValue =
        options.any(
          (option) =>
              _summarySelectionValue(option.provider, option.model) == selected,
        )
        ? selected
        : '';

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: L.get('settings_summary_model'),
            child: DropdownButton<String>(
              value: selectedValue,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              style: YanciTheme.bodyText.copyWith(fontSize: 12),
              items: options.map((option) {
                final value = _summarySelectionValue(
                  option.provider,
                  option.model,
                );
                final label = option.model.isEmpty
                    ? L.pick(
                        en: 'Follow chat model',
                        zhTW: '跟隨聊天模型',
                        zhCN: '跟随聊天模型',
                      )
                    : '${_providerLabel(option.provider)} · ${option.model}';
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 12,
                      color: option.model.isEmpty
                          ? YanciTheme.textSecondary
                          : YanciTheme.textPrimary,
                    ),
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value == null) return;
                if (value.isEmpty) {
                  setState(() {
                    _summaryProvider = '';
                    _summaryModel = '';
                  });
                } else {
                  final separator = value.indexOf(_summarySelectionSeparator);
                  if (separator < 1) return;
                  setState(() {
                    _summaryProvider = value.substring(0, separator);
                    _summaryModel = value.substring(separator + 1);
                  });
                }
                _debouncedSave();
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L.pick(
              en: 'Window summaries and automatic memory use this API pair. Star another model above to add it here.',
              zhTW: '窗口摘要與自動記憶使用這組來源和模型；在上方替其他模型加星即可加入選單。',
              zhCN: '窗口摘要与自动记忆使用这组来源和模型；在上方为其他模型加星即可加入选单。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 10,
              color: YanciTheme.textSecondary.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDreamCurationCard() {
    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Dream Curation', zhTW: '做夢整理', zhCN: '做梦整理'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
              ),
              SizedBox(
                height: 24,
                child: Switch.adaptive(
                  value: _dreamCurationEnabled,
                  activeThumbColor: YanciTheme.accent,
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                  onChanged: (v) {
                    setState(() => _dreamCurationEnabled = v);
                    _debouncedSave();
                  },
                ),
              ),
            ],
          ),
          if (_dreamCurationEnabled) ...[
            const SizedBox(height: 6),
            Text(
              L.pick(
                en: 'Automatically organizes memories after conversations accumulate. Uses the summary model. Consumes a small amount of tokens.',
                zhTW: '對話累積後自動梳理記憶，使用摘要模型，需消耗少量 tokens。',
                zhCN: '对话累积后自动梳理记忆，使用摘要模型，需消耗少量 tokens。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  L.pick(en: 'Trigger after', zhTW: '累積', zhCN: '累积'),
                  style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: TextField(
                    controller: TextEditingController(
                      text: '$_dreamCurationThreshold',
                    ),
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodyText.copyWith(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 4,
                      ),
                      border: UnderlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null) {
                        _dreamCurationThreshold = n.clamp(
                          MemorySettings.minDreamThreshold,
                          MemorySettings.maxDreamThreshold,
                        );
                        _debouncedSave();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  L.pick(en: 'new memories', zhTW: '條新記憶後觸發', zhCN: '条新记忆后触发'),
                  style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _webSearchModeLabel(WebSearchMode mode) => switch (mode) {
    WebSearchMode.auto => L.pick(en: 'Auto', zhTW: '自動選擇'),
    WebSearchMode.gemini => 'Gemini',
    WebSearchMode.openRouter => 'OpenRouter',
    WebSearchMode.dual => L.pick(
      en: 'Two providers (shown separately)',
      zhTW: '雙供應商（分開顯示）',
    ),
  };

  String _webSearchModeDescription(WebSearchMode mode) => switch (mode) {
    WebSearchMode.auto => L.pick(
      en: 'After confirmation, one provider is selected from the current chat source and the API keys saved on this device.',
      zhTW: '確認後，會依目前聊天來源與此裝置已保存的 API 金鑰選擇一家供應商。',
    ),
    WebSearchMode.gemini => L.pick(
      en: 'Developer preview for professional/business, 18+ use only. The confirmed request is sent only to Gemini; detected personal data is blocked. Gemini may rewrite it into multiple search queries, and its billing and retention terms apply.',
      zhTW:
          '開發者預覽：僅供專業／商業及 18 歲以上用途。經確認的請求只會送往 Gemini，偵測到個人資料時會攔截；Gemini 可能自行改寫成多個搜尋詞，費用與留存依其規則計算。',
    ),
    WebSearchMode.openRouter => L.pick(
      en: 'Developer preview. Uses an explicit model and Exa. OpenRouter may select one ZDR endpoint; fallback is disabled. Router/search-native models are blocked. Verify the account has no enforced default web plugin, because an organization can prevent the App from disabling it.',
      zhTW:
          '開發者預覽。使用明確模型與 Exa；OpenRouter 可選一個 ZDR 端點，且已停用備援。Router／原生搜尋模型會被攔截。請先確認帳戶沒有強制預設 Web Plugin，因為組織可禁止 App 停用它。',
    ),
    WebSearchMode.dual => L.pick(
      en: 'Developer preview; Gemini restrictions above apply. The same confirmed request is sent to Gemini and OpenRouter, and results are shown in separate provider cards. Each may rewrite it into multiple search queries; billing and retention are calculated separately.',
      zhTW:
          '開發者預覽，並適用上述 Gemini 限制。同一段經確認的請求會送往 Gemini 與 OpenRouter，兩家結果使用獨立卡片顯示；兩家都可能自行改寫成多個搜尋詞，費用與留存分別計算。',
    ),
  };



  /// 搜尋模型選擇器：從星標模型中過濾出符合供應商的模型，
  /// 加上一個「自動（使用預設）」選項。
  Widget _buildWebSearchSearchModelPicker({
    required String providerLabel,
    required String filterProvider,
    required String currentOverride,
    required String fallbackModel,
    required bool hasApiKey,
    required ValueChanged<String> onChanged,
  }) {
    // 過濾出當前 provider 的星標模型（排除不支援即時 API 的 :batch 模型）。
    final candidates = <String>[];
    for (final modelId in _starredModels) {
      final p = _starredModelProviders[modelId] ?? '';
      if (p == filterProvider && !modelId.toLowerCase().contains(':batch')) {
        candidates.add(modelId);
      }
    }
    candidates.sort();

    // 有效模型 = override 如果非空，否則 fallback。
    final effectiveModel =
        currentOverride.isNotEmpty ? currentOverride : fallbackModel;

    // 確保 currentOverride 在候選清單裡（即使已取消星標）。
    if (currentOverride.isNotEmpty && !candidates.contains(currentOverride)) {
      candidates.insert(0, currentOverride);
    }

    final ready = hasApiKey && effectiveModel.isNotEmpty;
    final statusText = !hasApiKey
        ? L.pick(en: 'No API key', zhTW: '尚未輸入 API 金鑰')
        : ready
        ? L.pick(en: 'Ready', zhTW: '已就緒', zhCN: '已就绪')
        : L.pick(en: 'No model selected', zhTW: '尚未選擇模型');

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                ready
                    ? Icons.check_circle_outline_rounded
                    : Icons.info_outline,
                size: 18,
                color: ready ? YanciTheme.accent : YanciTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                '$providerLabel · $statusText',
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Semantics(
            label: L.pick(
              en: '$providerLabel search model',
              zhTW: '$providerLabel 搜尋模型',
            ),
            value: effectiveModel,
            child: DropdownButton<String>(
              value: currentOverride,
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: YanciTheme.isDark
                  ? const Color(0xF0302830)
                  : Colors.white,
              style: YanciTheme.bodyText.copyWith(
                fontSize: 12,
                color: YanciTheme.textPrimary,
              ),
              items: [
                // 「自動」選項 = 空字串 override
                DropdownMenuItem<String>(
                  value: '',
                  child: Text(
                    L.pick(
                      en: 'Auto · $fallbackModel',
                      zhTW: '自動 · $fallbackModel',
                      zhCN: '自动 · $fallbackModel',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 12,
                      color: YanciTheme.textSecondary,
                    ),
                  ),
                ),
                for (final modelId in candidates)
                  DropdownMenuItem<String>(
                    value: modelId,
                    child: Text(
                      modelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodyText.copyWith(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                onChanged(value);
              },
            ),
          ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                L.pick(
                  en: 'Star a $providerLabel model above to add it here.',
                  zhTW: '在上方替 $providerLabel 模型加星即可加入選單。',
                  zhCN: '在上方为 $providerLabel 模型加星即可加入选单。',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 10,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.65),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWebSearchSettingsCard() {
    return AnimatedBuilder(
      animation: Listenable.merge([_apiKeyController, _geminiKeyCtrl]),
      builder: (context, _) {
        final selectedModeLabel = _webSearchModeLabel(_webSearchMode);
        return _buildGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: Colors.transparent,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    L.pick(en: 'Native web search', zhTW: '原生網路搜尋'),
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      L.pick(
                        en: webSearchLiveDeveloperPreviewEnabled
                            ? 'Developer preview. Lets chat request public-web searches. The exact query and recipients still require confirmation before any provider request is sent.'
                            : 'Developer preview is not included in this build. Release distributors must opt in explicitly after reviewing provider terms and audience restrictions.',
                        zhTW: webSearchLiveDeveloperPreviewEnabled
                            ? '開發者預覽。允許聊天提出公開網頁搜尋；實際送往供應商前，仍需確認完整查詢內容與接收方。'
                            : '此版本未包含開發者預覽。Release 發布者須先審核供應商條款與受眾限制，再於建置時明確啟用。',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 11,
                        height: 1.45,
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                  value: _webSearchEnabled,
                  activeThumbColor: YanciTheme.accent,
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                  onChanged: webSearchLiveDeveloperPreviewEnabled
                      ? (value) {
                          setState(() => _webSearchEnabled = value);
                          _debouncedSave();
                        }
                      : null,
                ),
              ),
              if (_webSearchEnabled) ...[
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                const SizedBox(height: 12),
                Text(
                  L.pick(en: 'Provider mode', zhTW: '供應商模式'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Semantics(
                  label: L.pick(
                    en: 'Web search provider mode',
                    zhTW: '網路搜尋供應商模式',
                  ),
                  value: selectedModeLabel,
                  child: DropdownButton<WebSearchMode>(
                    value: _webSearchMode,
                    isExpanded: true,
                    underline: const SizedBox(),
                    dropdownColor: YanciTheme.isDark
                        ? const Color(0xF0302830)
                        : Colors.white,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 13,
                      color: YanciTheme.textPrimary,
                    ),
                    items: [
                      for (final mode in WebSearchMode.values)
                        DropdownMenuItem<WebSearchMode>(
                          value: mode,
                          child: Text(
                            _webSearchModeLabel(mode),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _webSearchMode = value);
                      _debouncedSave();
                    },
                  ),
                ),
                Text(
                  _webSearchModeDescription(_webSearchMode),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    height: 1.45,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                _buildWebSearchSearchModelPicker(
                  providerLabel: 'OpenRouter',
                  filterProvider: 'openrouter',
                  currentOverride: _wsSearchOrModelOverride,
                  fallbackModel: openRouterWebSearchPreviewModel,
                  hasApiKey: _apiKeyController.text.trim().isNotEmpty,
                  onChanged: (value) {
                    setState(() => _wsSearchOrModelOverride = value);
                    _debouncedSave();
                  },
                ),
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                _buildWebSearchSearchModelPicker(
                  providerLabel: 'Gemini',
                  filterProvider: 'gemini',
                  currentOverride: _wsSearchGeminiModelOverride,
                  fallbackModel: _webSearchGeminiModel,
                  hasApiKey: _geminiKeyCtrl.text.trim().isNotEmpty,
                  onChanged: (value) {
                    setState(() => _wsSearchGeminiModelOverride = value);
                    _debouncedSave();
                  },
                ),
                Divider(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.12),
                  height: 1,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'Daily provider-launch cap',
                          zhTW: '每日供應商啟動上限',
                        ),
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      L.pick(
                        en: '$_webSearchDailyProviderLaunchCap / day',
                        zhTW: '$_webSearchDailyProviderLaunchCap 次／日',
                      ),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Semantics(
                  label: L.pick(
                    en: 'Daily provider-launch cap',
                    zhTW: '每日供應商啟動上限',
                  ),
                  value: '$_webSearchDailyProviderLaunchCap',
                  child: Slider.adaptive(
                    value: _webSearchDailyProviderLaunchCap.toDouble(),
                    min: WebSearchSettings.minDailyProviderLaunchCap.toDouble(),
                    max: WebSearchSettings.maxDailyProviderLaunchCap.toDouble(),
                    divisions:
                        WebSearchSettings.maxDailyProviderLaunchCap -
                        WebSearchSettings.minDailyProviderLaunchCap,
                    label: '$_webSearchDailyProviderLaunchCap',
                    activeColor: YanciTheme.accent,
                    onChanged: (value) {
                      setState(
                        () => _webSearchDailyProviderLaunchCap = value.round(),
                      );
                      _debouncedSave();
                    },
                    semanticFormatterCallback: (value) => L.pick(
                      en: '${value.round()} provider launches per day',
                      zhTW: '每日 ${value.round()} 次供應商啟動',
                    ),
                  ),
                ),
                Text(
                  L.pick(
                    en: 'Each provider launch counts once. Dual mode uses two launches for one confirmed request. A provider may then rewrite it into multiple search queries; actual billing is separate from this cap.',
                    zhTW:
                        '每啟動一家供應商計 1 次；雙供應商模式下，同一段確認請求會使用 2 次啟動額度。供應商可能再改寫成多個搜尋詞，實際計費與此上限分開計算。',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    height: 1.45,
                    color: YanciTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showCostPolicyNotice(ModelCostPolicyNotice notice) {
    if (!mounted || notice == ModelCostPolicyNotice.none) return;
    final message = switch (notice) {
      ModelCostPolicyNotice.inklingContextLimitEnabled => L.pick(
        en: 'Prompt cache and its summary were turned off. Context send limit is now on to reduce Inkling costs.',
        zhTW: '已關閉緩存命中及其專用摘要，並開啟上下文發送限制以節省 Inkling 費用。',
        zhCN: '已关闭缓存命中及其专用摘要，并开启上下文发送限制以节省 Inkling 费用。',
      ),
      ModelCostPolicyNotice.claudeCacheRecommended => L.pick(
        en: 'Enable cache hits to reduce Claude costs.',
        zhTW: '請開啟緩存命中以節省 Claude 費用。',
        zhCN: '请开启缓存命中以节省 Claude 费用。',
      ),
      ModelCostPolicyNotice.none => '',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<ModelCostPolicyResult> _applyCostPolicy({
    required String provider,
    required String model,
    String? apiKey,
  }) async {
    final result = await ModelCostPolicy.applySelection(
      provider: provider,
      model: model,
      apiKey: apiKey ?? '',
    );
    _lastPolicySelectionWasClaude = TokenEstimator.isClaudePromptCacheModel(
      provider: provider,
      model: model,
    );
    if (!mounted) return result;
    if (result.changed) setState(() {});
    _showCostPolicyNotice(result.notice);
    return result;
  }

  Future<void> _selectModel(String modelId) async {
    setState(() {
      _selectedModel = modelId;
      // 只更新顯示用主模型；搜尋模型由專屬選擇器獨立管理。
      // 當搜尋模型 override 為空時，Gemini 搜尋仍會降級到主模型。
      if (_provider == 'gemini') {
        _webSearchGeminiModel = modelId;
      }
      if (_provider == 'openai_compatible') {
        _oaiCompatModelCtrl.text = modelId;
      }
      _modelSearchController.clear();
      _filteredModels = _models;
    });
    _debouncedSave();
    await _applyCostPolicy(
      provider: _provider,
      model: modelId,
      apiKey: _provider == 'thinking_machines'
          ? _thinkingMachinesKeyCtrl.text
          : null,
    );
  }

  Future<void> _saveSettings() async {
    // 先取完整快照；保存途中繼續輸入時，下一輪會再保存新快照，
    // 不會讓同一輪混入新舊欄位值。
    final openRouterKey = _apiKeyController.text.trim();
    final xaiKey = _xaiKeyCtrl.text.trim();
    final systemPrompt = _systemPromptController.text.trim();
    final provider = _provider;
    final model = _modelValueForProvider();
    final geminiKey = _geminiKeyCtrl.text.trim();
    final deepseekKey = _deepseekKeyCtrl.text.trim();
    final qwenKey = _qwenKeyCtrl.text.trim();
    final awsAccessKeyId = _awsAccessKeyIdCtrl.text.trim();
    final awsSecretAccessKey = _awsSecretAccessKeyCtrl.text.trim();
    final awsRegion = _awsRegionCtrl.text.trim();
    final oaiBaseUrl = _oaiCompatBaseUrlCtrl.text.trim();
    final oaiKey = _oaiCompatKeyCtrl.text.trim();
    final oaiModel = _oaiCompatModelCtrl.text.trim();
    final thinkingMachinesKey = _thinkingMachinesKeyCtrl.text.trim();
    final thinkingMachinesModel = _thinkingMachinesModelCtrl.text.trim();
    final thinkingMachinesEffort = _thinkingMachinesEffort;
    final summaryProvider = _summaryProvider;
    final summaryModel = _summaryModel;
    final dreamCurationEnabled = _dreamCurationEnabled;
    final dreamCurationThreshold = _dreamCurationThreshold;
    final webSearchEnabled = _webSearchEnabled;
    final webSearchMode = _webSearchMode;
    final webSearchDailyProviderLaunchCap = _webSearchDailyProviderLaunchCap;
    final wsSearchOrOverride = _wsSearchOrModelOverride;
    final wsSearchGeminiOverride = _wsSearchGeminiModelOverride;

    await ApiSettings.saveOpenRouterApiKey(openRouterKey);
    await ApiSettings.saveXaiApiKey(xaiKey);
    await ApiSettings.saveSystemPrompt(systemPrompt);
    await ApiSettings.saveProviderModelSelection(provider, model);
    await ApiSettings.saveGeminiApiKey(geminiKey);
    await ApiSettings.saveDeepseekApiKey(deepseekKey);
    await ApiSettings.saveQwenApiKey(qwenKey);
    await ApiSettings.saveAwsAccessKeyId(awsAccessKeyId);
    await ApiSettings.saveAwsSecretAccessKey(awsSecretAccessKey);
    await ApiSettings.saveAwsRegion(awsRegion);
    await ApiSettings.saveOaiCompatBaseUrl(oaiBaseUrl);
    await ApiSettings.saveOaiCompatApiKey(oaiKey);
    await ApiSettings.saveOaiCompatModel(oaiModel);
    await ApiSettings.saveThinkingMachinesApiKey(thinkingMachinesKey);
    await ApiSettings.saveThinkingMachinesModel(thinkingMachinesModel);
    await ApiSettings.saveThinkingMachinesEffort(thinkingMachinesEffort);
    await WebSearchSettings.saveEnabled(webSearchEnabled);
    await WebSearchSettings.saveMode(webSearchMode);
    await WebSearchSettings.saveDailyProviderLaunchCap(
      webSearchDailyProviderLaunchCap,
    );
    await WebSearchSettings.saveOpenRouterSearchModel(wsSearchOrOverride);
    await WebSearchSettings.saveGeminiSearchModel(wsSearchGeminiOverride);
    await MemorySettings.saveSummarySelection(
      provider: summaryProvider,
      model: summaryModel,
    );
    await MemorySettings.saveDreamCurationEnabled(dreamCurationEnabled);
    await MemorySettings.saveDreamCurationThreshold(dreamCurationThreshold);
    if (provider == 'thinking_machines' && thinkingMachinesKey.isNotEmpty) {
      await _applyCostPolicy(
        provider: provider,
        model: model,
        apiKey: thinkingMachinesKey,
      );
    } else {
      final isClaude = TokenEstimator.isClaudePromptCacheModel(
        provider: provider,
        model: model,
      );
      if (isClaude && !_lastPolicySelectionWasClaude) {
        await _applyCostPolicy(provider: provider, model: model);
      } else {
        _lastPolicySelectionWasClaude = isClaude;
      }
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _modelFetchTimer?.cancel();
    _modelFetchGeneration++;
    _apiKeyController.dispose();
    _xaiKeyCtrl.dispose();
    _systemPromptController.dispose();
    _geminiKeyCtrl.dispose();
    _deepseekKeyCtrl.dispose();
    _qwenKeyCtrl.dispose();
    _awsAccessKeyIdCtrl.dispose();
    _awsSecretAccessKeyCtrl.dispose();
    _awsRegionCtrl.dispose();
    _oaiCompatBaseUrlCtrl.dispose();
    _oaiCompatKeyCtrl.dispose();
    _oaiCompatModelCtrl.dispose();
    _thinkingMachinesKeyCtrl.dispose();
    _thinkingMachinesModelCtrl.dispose();
    _modelSearchController.dispose();
    super.dispose();
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

  Widget _buildCollapsibleTitle(
    String title,
    bool isExpanded,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      key: const Key('api_settings_model_section_toggle'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(
              title,
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: YanciTheme.textSecondary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingMachinesCard() {
    final model = _thinkingMachinesModelCtrl.text.trim().isEmpty
        ? ThinkingMachinesService.defaultModel
        : _thinkingMachinesModelCtrl.text.trim();
    final starred = _starredModels.contains(model);
    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              L.pick(
                en: 'First-party Inkling API via Tinker (beta)',
                zhTW: '透過 Tinker 使用第一方 Inkling API（beta）',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 11,
                color: YanciTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ),
          ),
          TextField(
            controller: _thinkingMachinesKeyCtrl,
            obscureText: _obscureProviderKeys,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: (_) => _debouncedSave(),
            decoration: InputDecoration(
              hintText: 'Tinker API Key',
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              suffixIcon: _isTestingApi
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.wifi_protected_setup, size: 18),
                      tooltip: L.pick(
                        en: 'Test Inkling connection',
                        zhTW: '測試 Inkling 連線',
                      ),
                      onPressed: () => _testApiConnection(
                        'thinking_machines',
                        _thinkingMachinesKeyCtrl.text.trim(),
                      ),
                    ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              isDense: true,
            ),
          ),
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
            height: 1,
          ),
          TextField(
            controller: _thinkingMachinesModelCtrl,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            onChanged: (value) {
              _selectedModel = value.trim().isEmpty
                  ? ThinkingMachinesService.defaultModel
                  : value.trim();
              setState(() {});
              _debouncedSave();
            },
            decoration: InputDecoration(
              labelText: L.pick(en: 'Model', zhTW: '模型'),
              hintText: ThinkingMachinesService.defaultModel,
              labelStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.6),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 20,
                  color: starred
                      ? Colors.amber
                      : YanciTheme.textSecondary.withValues(alpha: 0.5),
                ),
                tooltip: L.pick(en: 'Star model', zhTW: '將模型加上星標'),
                onPressed: () async {
                  await ApiSettings.toggleStarModel(
                    model,
                    provider: 'thinking_machines',
                  );
                  final starredModels = await ApiSettings.getStarredModels();
                  final providers =
                      await ApiSettings.getStarredModelProviders();
                  if (!mounted) return;
                  setState(() {
                    _starredModels = starredModels.toSet();
                    _starredModelProviders = providers;
                  });
                },
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              isDense: true,
            ),
          ),
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
            height: 1,
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Thinking effort', zhTW: '思考強度'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
              ),
              DropdownButton<String>(
                value: _thinkingMachinesEffort,
                underline: const SizedBox(),
                dropdownColor: YanciTheme.isDark
                    ? const Color(0xF0302830)
                    : Colors.white,
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                  DropdownMenuItem(value: 'xhigh', child: Text('XHigh')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _thinkingMachinesEffort = value);
                  _debouncedSave();
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              L.pick(
                en: 'Uses Inkling native thinking blocks. Prompt caching and audio input are not supported by this compatible endpoint.',
                zhTW: '使用 Inkling 原生思考區塊；此相容端點目前不支援提示詞快取與音訊輸入。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10.5,
                color: YanciTheme.textSecondary.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
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
                            L.pick(en: 'API Settings', zhTW: 'API 設定'),
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
                            onPressed: _handleBack,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            icon: Icon(
                              _obscureProviderKeys
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 20,
                              color: YanciTheme.textSecondary,
                            ),
                            onPressed: () => setState(
                              () =>
                                  _obscureProviderKeys = !_obscureProviderKeys,
                            ),
                            tooltip: L.pick(en: 'Show Keys', zhTW: '顯示金鑰'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _settingsLoaded
                      ? ListView(
                          padding: const EdgeInsets.all(YanciTheme.spacingMd),
                          children: [
                            _buildSectionTitle(L.get('settings_api_source')),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildGlassCard(
                              child: DropdownButton<String>(
                                value: _provider,
                                isExpanded: true,
                                underline: const SizedBox(),
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 13,
                                ),
                                dropdownColor: YanciTheme.isDark
                                    ? const Color(0xF0302830)
                                    : Colors.white,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'openrouter',
                                    child: Text('OpenRouter'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'xai',
                                    child: Text('xAI (Grok)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'gemini',
                                    child: Text('Google Gemini'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'deepseek',
                                    child: Text('DeepSeek'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'qwen',
                                    child: Text('Qwen (DashScope)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'bedrock',
                                    child: Text('AWS Bedrock'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'thinking_machines',
                                    child: Text('Thinking Machines (Inkling)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'openai_compatible',
                                    child: Text('OpenAI Compatible (Custom)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'local',
                                    child: Text('Local Model (On-device)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'local_api',
                                    child: Text('Local API (Endpoint)'),
                                  ),
                                ],
                                onChanged: (v) async {
                                  if (v == null) return;
                                  _modelFetchTimer?.cancel();
                                  _modelFetchGeneration++;
                                  setState(() {
                                    _provider = v;
                                    _models = const <ModelInfo>[];
                                    _filteredModels = const <ModelInfo>[];
                                    _modelSearchController.clear();
                                    _modelError = null;
                                    _modelErrorProvider = null;
                                    _isFetchingModels = false;
                                  });
                                  final savedModel =
                                      await ApiSettings.getModelForProvider(v);
                                  if (!mounted) return;
                                  setState(() {
                                    _selectedModel = savedModel;
                                    // 只更新顯示用主模型；搜尋模型由專屬選擇器獨立管理。
                                    if (v == 'gemini') {
                                      _webSearchGeminiModel = savedModel;
                                    }
                                  });
                                  if (v == 'openrouter' ||
                                      v == 'gemini' ||
                                      v == 'deepseek' ||
                                      v == 'xai' ||
                                      v == 'openai_compatible') {
                                    _fetchModels();
                                  } else {
                                    setState(() => _models = []);
                                    _filteredModels = [];
                                  }
                                  await _applyCostPolicy(
                                    provider: v,
                                    model: savedModel,
                                    apiKey: v == 'thinking_machines'
                                        ? _thinkingMachinesKeyCtrl.text
                                        : null,
                                  );
                                  _debouncedSave();
                                },
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingMd),
                            if (_provider == 'thinking_machines') ...[
                              _buildThinkingMachinesCard(),
                            ],
                            if (_provider == 'openrouter') ...[
                              _buildGlassCard(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _apiKeyController,
                                        obscureText: _obscureProviderKeys,
                                        style: YanciTheme.bodyText.copyWith(
                                          fontSize: 13,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: L.get(
                                            'settings_api_key_hint',
                                          ),
                                          hintStyle: YanciTheme.bodySmall
                                              .copyWith(
                                                color: YanciTheme.textSecondary
                                                    .withValues(alpha: 0.4),
                                              ),
                                          border: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                vertical: 12,
                                              ),
                                        ),
                                        onChanged: (v) {
                                          _scheduleProviderModelFetch(
                                            'openrouter',
                                            v,
                                          );
                                          _debouncedSave();
                                        },
                                      ),
                                    ),
                                    _isFetchingModels
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        : IconButton(
                                            icon: const Icon(
                                              Icons.refresh,
                                              size: 20,
                                            ),
                                            onPressed: _fetchModels,
                                            tooltip: L.get(
                                              'settings_model_refresh',
                                            ),
                                          ),
                                  ],
                                ),
                              ),
                            ],
                            if (_provider == 'xai') ...[
                              _buildGlassCard(
                                child: TextField(
                                  controller: _xaiKeyCtrl,
                                  obscureText: _obscureProviderKeys,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  onChanged: (value) {
                                    _scheduleProviderModelFetch('xai', value);
                                    _debouncedSave();
                                  },
                                  decoration: InputDecoration(
                                    hintText: 'xAI API Key',
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    suffixIconConstraints: const BoxConstraints(
                                      minWidth: 88,
                                    ),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isTestingApi)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.wifi_protected_setup,
                                              size: 18,
                                            ),
                                            tooltip: L.pick(
                                              en: 'Test xAI connection',
                                              zhTW: '測試 xAI 連線',
                                            ),
                                            onPressed: () => _testApiConnection(
                                              'xai',
                                              _xaiKeyCtrl.text.trim(),
                                            ),
                                          ),
                                        if (_isFetchingModels)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.refresh,
                                              size: 18,
                                            ),
                                            tooltip: L.get(
                                              'settings_model_refresh',
                                            ),
                                            onPressed: _fetchModels,
                                          ),
                                      ],
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingXs),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  L.pick(
                                    en: 'Grok prompt cache is automatic. Holt keeps a private append-only context ledger and sends x-grok-conv-id; no Anthropic cache_control is used.',
                                    zhTW:
                                        'Grok 使用官方自動 Prompt Cache。Holt 會保存本機隱藏的只追加背景並傳送 x-grok-conv-id；不會套用 Claude 的 cache_control。',
                                  ),
                                  style: YanciTheme.bodySmall.copyWith(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.65,
                                    ),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                            if (_provider == 'gemini') ...[
                              _buildGlassCard(
                                child: TextField(
                                  controller: _geminiKeyCtrl,
                                  obscureText: _obscureProviderKeys,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  onChanged: (v) {
                                    _scheduleProviderModelFetch('gemini', v);
                                    _debouncedSave();
                                  },
                                  decoration: InputDecoration(
                                    hintText: 'Gemini API Key',
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    suffixIconConstraints: const BoxConstraints(
                                      minWidth: 88,
                                    ),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isTestingApi)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.wifi_protected_setup,
                                              size: 18,
                                            ),
                                            onPressed: () => _testApiConnection(
                                              'gemini',
                                              _geminiKeyCtrl.text,
                                            ),
                                          ),
                                        if (_isFetchingModels)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.refresh,
                                              size: 18,
                                            ),
                                            tooltip: L.get(
                                              'settings_model_refresh',
                                            ),
                                            onPressed: _fetchModels,
                                          ),
                                      ],
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_provider == 'deepseek') ...[
                              _buildGlassCard(
                                child: TextField(
                                  controller: _deepseekKeyCtrl,
                                  obscureText: _obscureProviderKeys,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  onChanged: (v) {
                                    _scheduleProviderModelFetch('deepseek', v);
                                    _debouncedSave();
                                  },
                                  decoration: InputDecoration(
                                    hintText: 'DeepSeek API Key',
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    suffixIconConstraints: const BoxConstraints(
                                      minWidth: 88,
                                    ),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isTestingApi)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.wifi_protected_setup,
                                              size: 18,
                                            ),
                                            onPressed: () => _testApiConnection(
                                              'deepseek',
                                              _deepseekKeyCtrl.text,
                                            ),
                                          ),
                                        if (_isFetchingModels)
                                          const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.refresh,
                                              size: 18,
                                            ),
                                            tooltip: L.get(
                                              'settings_model_refresh',
                                            ),
                                            onPressed: _fetchModels,
                                          ),
                                      ],
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_provider == 'qwen') ...[
                              _buildGlassCard(
                                child: TextField(
                                  controller: _qwenKeyCtrl,
                                  obscureText: _obscureProviderKeys,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  onChanged: (v) => _debouncedSave(),
                                  decoration: InputDecoration(
                                    hintText: 'Qwen API Key (DashScope)',
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    suffixIcon: _isTestingApi
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        : IconButton(
                                            icon: const Icon(
                                              Icons.wifi_protected_setup,
                                              size: 18,
                                            ),
                                            onPressed: () => _testApiConnection(
                                              'qwen',
                                              _qwenKeyCtrl.text,
                                            ),
                                          ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_provider == 'bedrock') ...[
                              _buildGlassCard(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextField(
                                      controller: _awsAccessKeyIdCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: 'AWS Access Key ID',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                            ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                    Divider(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.1),
                                      height: 1,
                                    ),
                                    TextField(
                                      controller: _awsSecretAccessKeyCtrl,
                                      obscureText: _obscureProviderKeys,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: 'AWS Secret Access Key',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                            ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                    Divider(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.1),
                                      height: 1,
                                    ),
                                    TextField(
                                      controller: _awsRegionCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: 'Region (e.g. us-east-1)',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                              fontSize: 11,
                                            ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (_provider == 'openai_compatible') ...[
                              _buildGlassCard(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextField(
                                      controller: _oaiCompatBaseUrlCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) {
                                        _scheduleCompatibleModelFetch(v);
                                        _debouncedSave();
                                      },
                                      decoration: InputDecoration(
                                        hintText:
                                            'Base URL (e.g. https://api.example.com/v1)',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                              fontSize: 11,
                                            ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                    Divider(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.1),
                                      height: 1,
                                    ),
                                    TextField(
                                      controller: _oaiCompatKeyCtrl,
                                      obscureText: _obscureProviderKeys,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) {
                                        _scheduleCompatibleModelFetch(
                                          _oaiCompatBaseUrlCtrl.text,
                                        );
                                        _debouncedSave();
                                      },
                                      decoration: InputDecoration(
                                        hintText: 'API Key',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                            ),
                                        suffixIcon: _isTestingApi
                                            ? const Padding(
                                                padding: EdgeInsets.all(12),
                                                child: SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              )
                                            : IconButton(
                                                icon: const Icon(
                                                  Icons.wifi_protected_setup,
                                                  size: 18,
                                                ),
                                                onPressed: () =>
                                                    _testApiConnection(
                                                      'openai_compatible',
                                                      _oaiCompatKeyCtrl.text,
                                                    ),
                                              ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                    Divider(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.1),
                                      height: 1,
                                    ),
                                    TextField(
                                      controller: _oaiCompatModelCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) {
                                        _selectedModel = v.trim();
                                        _debouncedSave();
                                      },
                                      decoration: InputDecoration(
                                        hintText: 'Model name (e.g. gpt-4o)',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                              fontSize: 11,
                                            ),
                                        suffixIcon: _isFetchingModels
                                            ? const Padding(
                                                padding: EdgeInsets.all(12),
                                                child: SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              )
                                            : IconButton(
                                                icon: const Icon(
                                                  Icons.refresh,
                                                  size: 18,
                                                ),
                                                tooltip: L.get(
                                                  'settings_model_refresh',
                                                ),
                                                onPressed: _fetchModels,
                                              ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        isDense: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (_provider == 'local_api' ||
                                _provider == 'local') ...[
                              _buildGlassCard(
                                child: Text(
                                  L.pick(
                                    en: _provider == 'local'
                                        ? 'On-device models are selected on the Local Models page.'
                                        : 'Local API is configured on the Local Models page.',
                                    zhTW: _provider == 'local'
                                        ? '裝置本地模型在「本地模型」頁面選擇。'
                                        : '本地 API 在「本地模型」頁面設定。',
                                  ),
                                  style: YanciTheme.bodySmall.copyWith(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ),
                              ),
                            ],

                            const SizedBox(height: YanciTheme.spacingMd),
                            _buildCollapsibleTitle(
                              '${L.get('settings_model_label')}${_modelValueForProvider().isNotEmpty ? "：${_modelValueForProvider()}" : ""}',
                              _showModelSection,
                              () => setState(
                                () => _showModelSection = !_showModelSection,
                              ),
                            ),
                            if (_showModelSection) ...[
                              const SizedBox(height: YanciTheme.spacingSm),
                              if (_modelError != null &&
                                  _modelErrorProvider == _provider)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: YanciTheme.spacingSm,
                                  ),
                                  child: Text(
                                    _modelError!,
                                    key: const Key('api_settings_model_error'),
                                    style: YanciTheme.bodySmall.copyWith(
                                      color: Colors.red[300],
                                    ),
                                  ),
                                ),
                              _buildGlassCard(
                                child: TextField(
                                  controller: _modelSearchController,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: _models.isEmpty
                                        ? L.get('settings_model_hint_empty')
                                        : L.get('settings_model_hint_search'),
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.search,
                                      size: 18,
                                      color: YanciTheme.textSecondary,
                                    ),
                                  ),
                                  onChanged: _filterModels,
                                  onSubmitted: (v) {
                                    if (v.trim().isNotEmpty) {
                                      _selectModel(v.trim());
                                    }
                                  },
                                ),
                              ),
                              if (_filteredModels.isNotEmpty)
                                Container(
                                  constraints: BoxConstraints(
                                    maxHeight:
                                        MediaQuery.of(context).size.height *
                                        0.35,
                                  ),
                                  margin: const EdgeInsets.only(
                                    top: YanciTheme.spacingXs,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      YanciTheme.radiusMd,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: YanciTheme.surfacePanel,
                                        borderRadius: BorderRadius.circular(
                                          YanciTheme.radiusMd,
                                        ),
                                      ),
                                      child: ListView.builder(
                                        shrinkWrap: true,
                                        itemCount: _filteredModels.length,
                                        itemBuilder: (context, index) {
                                          final model = _filteredModels[index];
                                          final isSelected =
                                              model.id ==
                                              _modelValueForProvider();
                                          return InkWell(
                                            onTap: () => _selectModel(model.id),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal:
                                                        YanciTheme.spacingMd,
                                                    vertical: 10,
                                                  ),
                                              color: isSelected
                                                  ? YanciTheme.accent
                                                        .withValues(alpha: 0.1)
                                                  : null,
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      model.id,
                                                      style: YanciTheme.bodyText
                                                          .copyWith(
                                                            fontSize: 12,
                                                            color: isSelected
                                                                ? YanciTheme
                                                                      .accent
                                                                : YanciTheme
                                                                      .textPrimary,
                                                          ),
                                                    ),
                                                  ),
                                                  GestureDetector(
                                                    onTap: () async {
                                                      await ApiSettings.toggleStarModel(
                                                        model.id,
                                                        provider: _provider,
                                                      );
                                                      final starred =
                                                          await ApiSettings.getStarredModels();
                                                      final providers =
                                                          await ApiSettings.getStarredModelProviders();
                                                      if (!mounted) return;
                                                      setState(() {
                                                        _starredModels = starred
                                                            .toSet();
                                                        _starredModelProviders =
                                                            providers;
                                                      });
                                                    },
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            left: 8,
                                                          ),
                                                      child: Icon(
                                                        _starredModels.contains(
                                                              model.id,
                                                            )
                                                            ? Icons.star_rounded
                                                            : Icons
                                                                  .star_border_rounded,
                                                        size: 18,
                                                        color:
                                                            _starredModels
                                                                .contains(
                                                                  model.id,
                                                                )
                                                            ? YanciTheme.accent
                                                            : YanciTheme
                                                                  .textSecondary
                                                                  .withValues(
                                                                    alpha: 0.3,
                                                                  ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                            const SizedBox(height: YanciTheme.spacingLg),
                            _buildSectionTitle(
                              L.pick(en: 'Web search', zhTW: '網路搜尋'),
                            ),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildWebSearchSettingsCard(),
                            const SizedBox(height: YanciTheme.spacingLg),
                            _buildSectionTitle(L.get('settings_summary_model')),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildSummaryModelCard(),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildDreamCurationCard(),
                            const SizedBox(height: YanciTheme.spacingLg),
                            const ApiAdvancedSettings(),
                            const SizedBox(height: YanciTheme.spacingLg),
                            _buildSectionTitle(
                              L.pick(
                                en: 'Profile (global settings)',
                                zhTW: 'Profile（全域設定）',
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildGlassCard(
                              child: TextField(
                                controller: _systemPromptController,
                                maxLines: null,
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 13,
                                ),
                                onChanged: (v) => _debouncedSave(),
                                decoration: InputDecoration(
                                  hintText: L.pick(
                                    en: 'Enter global settings…\n(Changing this invalidates the current static cache)',
                                    zhTW: '輸入全域設定…\n（改動會打斷目前的靜態緩存狀態）',
                                  ),
                                  hintStyle: YanciTheme.bodySmall.copyWith(
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
