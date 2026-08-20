import 'dart:async';
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
import '../services/static_token_estimator.dart';
import '../services/token_estimator.dart';
import '../widgets/gradient_background.dart';
import '../widgets/api_advanced_settings.dart';
import '../widgets/api_aws_bedrock_settings_card.dart';
import '../widgets/api_compatible_provider_settings_card.dart';
import '../widgets/api_model_picker.dart';
import '../widgets/api_memory_settings_card.dart';
import '../widgets/api_provider_key_settings_card.dart';
import '../widgets/api_provider_picker.dart';
import '../widgets/api_web_search_settings_card.dart';
import '../widgets/thinking_machines_settings_card.dart';

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

  Future<void> _saveNow() async {
    if (!_settingsLoaded) return;
    _settingsDirty = true;
    try {
      await _flushPendingSave();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.pick(en: 'Settings saved', zhTW: '設定已儲存')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      _reportSaveError(error);
    }
  }

  final _apiKeyController = TextEditingController();
  final _xaiKeyCtrl = TextEditingController();

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
  final _webSearchRelayEndpointCtrl = TextEditingController();
  final _webSearchRelayKeyCtrl = TextEditingController();
  final _webSearchRelayModelCtrl = TextEditingController();

  String _selectedModel = '';
  String _summaryProvider = MemorySettings.defaultSummaryProvider;
  String _summaryModel = MemorySettings.defaultSummaryModel;
  bool _dreamCurationEnabled = false;
  int _dreamCurationThreshold = MemorySettings.defaultDreamThreshold;
  bool _webSearchEnabled = false;
  WebSearchMode _webSearchMode = WebSearchMode.auto;
  int _webSearchDailyProviderLaunchCap =
      WebSearchSettings.defaultDailyProviderLaunchCap;
  int _webSearchMaxResults = WebSearchSettings.defaultMaxResults;
  String _webSearchGeminiModel = '';
  String _webSearchXaiModel = '';
  String _wsSearchOrModelOverride = '';
  String _wsSearchGeminiModelOverride = '';
  String _wsSearchXaiModelOverride = '';
  List<ModelInfo> _models = [];
  List<ModelInfo> _filteredModels = [];
  Set<String> _starredModels = {};
  Map<String, String> _starredModelProviders = {};
  final _modelSearchController = TextEditingController();

  bool _isFetchingModels = false;
  bool _isTestingApi = false;
  String? _modelError;
  String? _modelErrorProvider;
  bool _showModelSection = true;
  bool _showModelList = true;
  bool _showOtherProviders = false;
  bool _showAdvancedSettings = false;
  bool _obscureProviderKeys = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    final xaiKey = await ApiSettings.getXaiApiKey();
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
    final webSearchMaxResults = await WebSearchSettings.getMaxResults();
    final webSearchGeminiModel = await ApiSettings.getModelForProvider(
      'gemini',
    );
    final webSearchXaiModel = await ApiSettings.getModelForProvider('xai');
    final wsSearchOrOverride =
        await WebSearchSettings.getOpenRouterSearchModel();
    final wsSearchGeminiOverride =
        await WebSearchSettings.getGeminiSearchModel();
    final wsSearchXaiOverride = await WebSearchSettings.getXaiSearchModel();
    final webSearchRelayEndpoint = await WebSearchSettings.getRelayEndpoint();
    final webSearchRelayKey = await WebSearchSettings.getRelayApiKey();
    final webSearchRelayModel = await WebSearchSettings.getRelayModel();

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
        _provider = provider;

        _geminiKeyCtrl.text = gm;
        _deepseekKeyCtrl.text = ds;
        _qwenKeyCtrl.text = qw;

        _awsAccessKeyIdCtrl.text = awsId;
        _awsSecretAccessKeyCtrl.text = awsSec;
        _awsRegionCtrl.text = awsReg;
        _webSearchRelayEndpointCtrl.text = webSearchRelayEndpoint;
        _webSearchRelayKeyCtrl.text = webSearchRelayKey;
        _webSearchRelayModelCtrl.text = webSearchRelayModel;

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
        _webSearchMaxResults = webSearchMaxResults;
        _webSearchGeminiModel = webSearchGeminiModel;
        _webSearchXaiModel = webSearchXaiModel;
        _wsSearchOrModelOverride = wsSearchOrOverride;
        _wsSearchGeminiModelOverride = wsSearchGeminiOverride;
        _wsSearchXaiModelOverride = wsSearchXaiOverride;
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

  Future<void> _handleProviderChanged(String? value) async {
    if (value == null) return;
    _modelFetchTimer?.cancel();
    _modelFetchGeneration++;
    setState(() {
      _provider = value;
      _models = const <ModelInfo>[];
      _filteredModels = const <ModelInfo>[];
      _modelSearchController.clear();
      _modelError = null;
      _modelErrorProvider = null;
      _isFetchingModels = false;
    });
    final savedModel = await ApiSettings.getModelForProvider(value);
    if (!mounted) return;
    setState(() {
      _selectedModel = savedModel;
      // 只更新顯示用主模型；搜尋模型由專屬選擇器獨立管理。
      if (value == 'gemini') _webSearchGeminiModel = savedModel;
    });
    if (value == 'openrouter' ||
        value == 'gemini' ||
        value == 'deepseek' ||
        value == 'xai' ||
        value == 'openai_compatible') {
      _fetchModels();
    } else {
      setState(() => _models = []);
      _filteredModels = [];
    }
    await _applyCostPolicy(
      provider: value,
      model: savedModel,
      apiKey: value == 'thinking_machines'
          ? _thinkingMachinesKeyCtrl.text
          : null,
    );
    _debouncedSave();
  }

  List<ApiProviderOption> _providerOptions() => [
    const ApiProviderOption(id: 'openrouter', label: 'OpenRouter'),
    ApiProviderOption(
      id: 'openai_compatible',
      label: L.pick(en: 'Custom Relay', zhTW: '自訂中轉站', zhCN: '自定义中转站'),
    ),
    const ApiProviderOption(id: 'xai', label: 'xAI (Grok)'),
    const ApiProviderOption(id: 'gemini', label: 'Google Gemini'),
    const ApiProviderOption(id: 'deepseek', label: 'DeepSeek'),
    const ApiProviderOption(id: 'qwen', label: 'Qwen'),
    const ApiProviderOption(id: 'bedrock', label: 'AWS Bedrock'),
    const ApiProviderOption(
      id: 'thinking_machines',
      label: 'Thinking Machines',
    ),
    ApiProviderOption(
      id: 'local',
      label: L.pick(en: 'Local Model', zhTW: '本地模型', zhCN: '本地模型'),
    ),
    ApiProviderOption(
      id: 'local_api',
      label: L.pick(en: 'Local API', zhTW: '本地 API', zhCN: '本地 API'),
    ),
  ];

  Widget _buildProviderPicker() {
    return ApiProviderPicker(
      options: _providerOptions(),
      selectedId: _provider,
      showOtherProviders: _showOtherProviders,
      primaryIds: const {'openrouter', 'openai_compatible'},
      borderColor: _settingsBorderColor,
      onChanged: _handleProviderChanged,
    );
  }

  Widget _buildProviderSectionHeader() {
    return Row(
      children: [
        Expanded(child: _buildSectionTitle(L.get('settings_api_source'))),
        IconButton(
          key: const Key('api_settings_provider_toggle'),
          icon: Icon(
            _showOtherProviders
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded,
            size: 22,
            color: YanciTheme.textSecondary,
          ),
          tooltip: L.pick(
            en: _showOtherProviders
                ? 'Hide other providers'
                : 'Show other providers',
            zhTW: _showOtherProviders ? '收起其他來源' : '展開其他來源',
            zhCN: _showOtherProviders ? '收起其他来源' : '展开其他来源',
          ),
          onPressed: () =>
              setState(() => _showOtherProviders = !_showOtherProviders),
        ),
      ],
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
      return _thinkingMachinesModelValue;
    }
    return _selectedModel;
  }

  String get _thinkingMachinesModelValue =>
      _normalizeThinkingMachinesModel(_thinkingMachinesModelCtrl.text);

  String _normalizeThinkingMachinesModel(String value) {
    final model = value.trim();
    return model.isEmpty ? ThinkingMachinesService.defaultModel : model;
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
    final webSearchMaxResults = _webSearchMaxResults;
    final wsSearchOrOverride = _wsSearchOrModelOverride;
    final wsSearchGeminiOverride = _wsSearchGeminiModelOverride;
    final wsSearchXaiOverride = _wsSearchXaiModelOverride;
    final webSearchRelayEndpoint = _webSearchRelayEndpointCtrl.text.trim();
    final webSearchRelayKey = _webSearchRelayKeyCtrl.text.trim();
    final webSearchRelayModel = _webSearchRelayModelCtrl.text.trim();

    await ApiSettings.saveOpenRouterApiKey(openRouterKey);
    await ApiSettings.saveXaiApiKey(xaiKey);
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
    await WebSearchSettings.saveMaxResults(webSearchMaxResults);
    await WebSearchSettings.saveOpenRouterSearchModel(wsSearchOrOverride);
    await WebSearchSettings.saveGeminiSearchModel(wsSearchGeminiOverride);
    await WebSearchSettings.saveXaiSearchModel(wsSearchXaiOverride);
    await WebSearchSettings.saveRelayEndpoint(webSearchRelayEndpoint);
    await WebSearchSettings.saveRelayApiKey(webSearchRelayKey);
    await WebSearchSettings.saveRelayModel(webSearchRelayModel);
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
    _webSearchRelayEndpointCtrl.dispose();
    _webSearchRelayKeyCtrl.dispose();
    _webSearchRelayModelCtrl.dispose();
    _modelSearchController.dispose();
    super.dispose();
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingMd,
        vertical: YanciTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(color: _settingsBorderColor, width: 0.75),
      ),
      child: child,
    );
  }

  Color get _settingsBorderColor => Color.lerp(
    YanciTheme.textSecondary,
    YanciTheme.accent,
    YanciTheme.isDark ? 0.38 : 0.28,
  )!.withValues(alpha: 0.82);

  Color get _selectionSuccessColor =>
      Color.lerp(const Color(0xFF4CAF6A), YanciTheme.accent, 0.24)!;

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

  Widget _buildModelPicker() {
    return ApiModelPicker(
      selectedModel: _modelValueForProvider(),
      models: _models,
      filteredModels: _filteredModels,
      searchController: _modelSearchController,
      isFetchingModels: _isFetchingModels,
      showModelList: _showModelList,
      starredModels: _starredModels,
      selectionSuccessColor: _selectionSuccessColor,
      onFilter: _filterModels,
      onSelectModel: (modelId) => unawaited(_selectModel(modelId)),
      onFetchModels: () => unawaited(_fetchModels()),
      onToggleModelList: () => setState(() => _showModelList = !_showModelList),
      onToggleStar: _toggleStarModel,
    );
  }

  Future<void> _toggleStarModel(String modelId) async {
    await ApiSettings.toggleStarModel(modelId, provider: _provider);
    final starred = await ApiSettings.getStarredModels();
    final providers = await ApiSettings.getStarredModelProviders();
    if (!mounted) return;
    setState(() {
      _starredModels = starred.toSet();
      _starredModelProviders = providers;
    });
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
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.phone_android_rounded,
                                  size: 20,
                                ),
                                color: YanciTheme.textSecondary,
                                onPressed: () => Navigator.of(
                                  context,
                                ).pushNamed('/local_models'),
                                tooltip: L.pick(
                                  en: 'Local Models',
                                  zhTW: '本地模型',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _settingsLoaded
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(
                            YanciTheme.spacingMd,
                            YanciTheme.spacingXs,
                            YanciTheme.spacingMd,
                            YanciTheme.spacingMd,
                          ),
                          children: [
                            _buildProviderSectionHeader(),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildProviderPicker(),
                            const SizedBox(height: YanciTheme.spacingMd),
                            _buildSectionTitle(
                              L.pick(
                                en: 'API Key',
                                zhTW: 'API Key',
                                zhCN: 'API Key',
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingSm),
                            if (_provider == 'thinking_machines') ...[
                              ThinkingMachinesSettingsCard(
                                keyController: _thinkingMachinesKeyCtrl,
                                modelController: _thinkingMachinesModelCtrl,
                                modelValue: _thinkingMachinesModelValue,
                                defaultModel:
                                    ThinkingMachinesService.defaultModel,
                                isTesting: _isTestingApi,
                                obscureKey: _obscureProviderKeys,
                                isStarred: _starredModels.contains(
                                  _thinkingMachinesModelValue,
                                ),
                                effort: _thinkingMachinesEffort,
                                borderColor: _settingsBorderColor,
                                onKeyChanged: (_) => _debouncedSave(),
                                onModelChanged: (value) {
                                  _selectedModel =
                                      _normalizeThinkingMachinesModel(value);
                                  setState(() {});
                                  _debouncedSave();
                                },
                                onEffortChanged: (value) {
                                  setState(
                                    () => _thinkingMachinesEffort = value,
                                  );
                                  _debouncedSave();
                                },
                                onTestConnection: (key) => _testApiConnection(
                                  'thinking_machines',
                                  key,
                                ),
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                onToggleStar: _toggleStarModel,
                              ),
                            ],
                            if (_provider == 'openrouter') ...[
                              ApiProviderKeySettingsCard(
                                controller: _apiKeyController,
                                hintText: L.get('settings_api_key_hint'),
                                obscureText: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                borderColor: _settingsBorderColor,
                                onChanged: (value) {
                                  _scheduleProviderModelFetch(
                                    'openrouter',
                                    value,
                                  );
                                  _debouncedSave();
                                },
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                              ),
                            ],
                            if (_provider == 'xai') ...[
                              ApiProviderKeySettingsCard(
                                controller: _xaiKeyCtrl,
                                hintText: 'xAI API Key',
                                obscureText: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                borderColor: _settingsBorderColor,
                                onChanged: (value) {
                                  _scheduleProviderModelFetch('xai', value);
                                  _debouncedSave();
                                },
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                testTooltip: L.pick(
                                  en: 'Test xAI connection',
                                  zhTW: '測試 xAI 連線',
                                ),
                                onTestConnection: () => _testApiConnection(
                                  'xai',
                                  _xaiKeyCtrl.text.trim(),
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
                              ApiProviderKeySettingsCard(
                                controller: _geminiKeyCtrl,
                                hintText: 'Gemini API Key',
                                obscureText: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                borderColor: _settingsBorderColor,
                                onChanged: (value) {
                                  _scheduleProviderModelFetch('gemini', value);
                                  _debouncedSave();
                                },
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                onTestConnection: () => _testApiConnection(
                                  'gemini',
                                  _geminiKeyCtrl.text,
                                ),
                              ),
                            ],
                            if (_provider == 'deepseek') ...[
                              ApiProviderKeySettingsCard(
                                controller: _deepseekKeyCtrl,
                                hintText: 'DeepSeek API Key',
                                obscureText: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                borderColor: _settingsBorderColor,
                                onChanged: (value) {
                                  _scheduleProviderModelFetch(
                                    'deepseek',
                                    value,
                                  );
                                  _debouncedSave();
                                },
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                onTestConnection: () => _testApiConnection(
                                  'deepseek',
                                  _deepseekKeyCtrl.text,
                                ),
                              ),
                            ],
                            if (_provider == 'qwen') ...[
                              ApiProviderKeySettingsCard(
                                controller: _qwenKeyCtrl,
                                hintText: 'Qwen API Key (DashScope)',
                                obscureText: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                borderColor: _settingsBorderColor,
                                onChanged: (_) => _debouncedSave(),
                                onToggleObscure: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                onTestConnection: () => _testApiConnection(
                                  'qwen',
                                  _qwenKeyCtrl.text,
                                ),
                              ),
                            ],
                            if (_provider == 'bedrock') ...[
                              ApiAwsBedrockSettingsCard(
                                accessKeyIdController: _awsAccessKeyIdCtrl,
                                secretAccessKeyController:
                                    _awsSecretAccessKeyCtrl,
                                regionController: _awsRegionCtrl,
                                obscureSecretAccessKey: _obscureProviderKeys,
                                borderColor: _settingsBorderColor,
                                onAccessKeyIdChanged: (_) => _debouncedSave(),
                                onSecretAccessKeyChanged: (_) =>
                                    _debouncedSave(),
                                onRegionChanged: (_) => _debouncedSave(),
                                onToggleObscureSecretAccessKey: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                              ),
                            ],
                            if (_provider == 'openai_compatible') ...[
                              ApiCompatibleProviderSettingsCard(
                                baseUrlController: _oaiCompatBaseUrlCtrl,
                                apiKeyController: _oaiCompatKeyCtrl,
                                modelController: _oaiCompatModelCtrl,
                                obscureApiKey: _obscureProviderKeys,
                                isTesting: _isTestingApi,
                                isFetchingModels: _isFetchingModels,
                                borderColor: _settingsBorderColor,
                                onBaseUrlChanged: (value) {
                                  _scheduleCompatibleModelFetch(value);
                                  _debouncedSave();
                                },
                                onApiKeyChanged: (_) {
                                  _scheduleCompatibleModelFetch(
                                    _oaiCompatBaseUrlCtrl.text,
                                  );
                                  _debouncedSave();
                                },
                                onModelChanged: (value) {
                                  _selectedModel = value.trim();
                                  _debouncedSave();
                                },
                                onToggleObscureApiKey: () => setState(
                                  () => _obscureProviderKeys =
                                      !_obscureProviderKeys,
                                ),
                                onTestConnection: () => _testApiConnection(
                                  'openai_compatible',
                                  _oaiCompatKeyCtrl.text,
                                ),
                                onFetchModels: _fetchModels,
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
                              L.get('settings_model_label'),
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
                              _buildModelPicker(),
                            ],
                            const SizedBox(height: YanciTheme.spacingLg),
                            const ApiAdvancedSettings(cacheOnly: true),
                            const SizedBox(height: YanciTheme.spacingLg),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    key: const Key('api_settings_save_button'),
                                    onPressed: _saveNow,
                                    icon: const Icon(
                                      Icons.save_outlined,
                                      size: 17,
                                    ),
                                    label: Text(
                                      L.pick(
                                        en: 'Save settings',
                                        zhTW: '儲存設定',
                                        zhCN: '保存设置',
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: YanciTheme.spacingSm),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    key: const Key(
                                      'api_settings_advanced_button',
                                    ),
                                    onPressed: () => setState(
                                      () => _showAdvancedSettings =
                                          !_showAdvancedSettings,
                                    ),
                                    icon: Icon(
                                      _showAdvancedSettings
                                          ? Icons.expand_less_rounded
                                          : Icons.tune_rounded,
                                      size: 17,
                                    ),
                                    label: Text(
                                      L.pick(
                                        en: 'Advanced',
                                        zhTW: '高級設定',
                                        zhCN: '高级设置',
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_showAdvancedSettings) ...[
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildSectionTitle(
                                L.pick(
                                  en: 'Advanced settings',
                                  zhTW: '高級設定',
                                  zhCN: '高级设置',
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingLg),
                              const SizedBox(height: YanciTheme.spacingSm),
                              ApiWebSearchSettingsCard(
                                viewState: ApiWebSearchViewState(
                                  openRouterKeyController: _apiKeyController,
                                  geminiKeyController: _geminiKeyCtrl,
                                  xaiKeyController: _xaiKeyCtrl,
                                  relayEndpointController:
                                      _webSearchRelayEndpointCtrl,
                                  relayKeyController: _webSearchRelayKeyCtrl,
                                  relayModelController:
                                      _webSearchRelayModelCtrl,
                                  enabled: _webSearchEnabled,
                                  mode: _webSearchMode,
                                  dailyProviderLaunchCap:
                                      _webSearchDailyProviderLaunchCap,
                                  maxResults: _webSearchMaxResults,
                                  geminiModel: _webSearchGeminiModel,
                                  xaiModel: _webSearchXaiModel,
                                  openRouterModelOverride:
                                      _wsSearchOrModelOverride,
                                  geminiModelOverride:
                                      _wsSearchGeminiModelOverride,
                                  xaiModelOverride: _wsSearchXaiModelOverride,
                                  currentProvider: _provider,
                                  starredModels: _starredModels,
                                  starredModelProviders: _starredModelProviders,
                                  obscureProviderKeys: _obscureProviderKeys,
                                  enabledToggleActive:
                                      webSearchLiveDeveloperPreviewEnabled,
                                  borderColor: _settingsBorderColor,
                                ),
                                actions: ApiWebSearchViewActions(
                                  onEnabledChanged: (value) {
                                    setState(() => _webSearchEnabled = value);
                                    _debouncedSave();
                                    StaticTokenEstimator.showAfterToggle(
                                      context,
                                    );
                                  },
                                  onModeChanged: (value) {
                                    setState(() => _webSearchMode = value);
                                    _debouncedSave();
                                  },
                                  onDailyProviderLaunchCapChanged: (value) {
                                    setState(
                                      () => _webSearchDailyProviderLaunchCap =
                                          value,
                                    );
                                    _debouncedSave();
                                  },
                                  onMaxResultsChanged: (value) {
                                    setState(
                                      () => _webSearchMaxResults = value,
                                    );
                                    _debouncedSave();
                                  },
                                  onOpenRouterModelChanged: (value) {
                                    setState(
                                      () => _wsSearchOrModelOverride = value,
                                    );
                                    _debouncedSave();
                                  },
                                  onGeminiModelChanged: (value) {
                                    setState(
                                      () =>
                                          _wsSearchGeminiModelOverride = value,
                                    );
                                    _debouncedSave();
                                  },
                                  onXaiModelChanged: (value) {
                                    setState(
                                      () => _wsSearchXaiModelOverride = value,
                                    );
                                    _debouncedSave();
                                  },
                                  onRelayModelChanged: (value) {
                                    setState(
                                      () =>
                                          _webSearchRelayModelCtrl.text = value,
                                    );
                                    _debouncedSave();
                                  },
                                  onToggleObscureProviderKeys: () => setState(
                                    () => _obscureProviderKeys =
                                        !_obscureProviderKeys,
                                  ),
                                  onRelayEndpointChanged: (_) =>
                                      _debouncedSave(),
                                  onRelayKeyChanged: (_) => _debouncedSave(),
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingLg),
                              _buildSectionTitle(
                                L.get('settings_summary_model'),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              ApiMemorySettingsCard(
                                summaryProvider: _summaryProvider,
                                summaryModel: _summaryModel,
                                starredModels: _starredModels,
                                starredModelProviders: _starredModelProviders,
                                dreamCurationEnabled: _dreamCurationEnabled,
                                dreamCurationThreshold: _dreamCurationThreshold,
                                borderColor: _settingsBorderColor,
                                onSummarySelectionChanged: (provider, model) {
                                  setState(() {
                                    _summaryProvider = provider;
                                    _summaryModel = model;
                                  });
                                  _debouncedSave();
                                },
                                onDreamCurationChanged: (value) {
                                  setState(() => _dreamCurationEnabled = value);
                                  _debouncedSave();
                                },
                                onDreamCurationThresholdChanged: (value) {
                                  _dreamCurationThreshold = value;
                                  _debouncedSave();
                                },
                              ),
                              const SizedBox(height: YanciTheme.spacingLg),
                              const ApiAdvancedSettings(
                                showCacheSection: false,
                              ),
                            ],
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
