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

  List<({String id, String label})> _providerOptions() => [
    (id: 'openrouter', label: 'OpenRouter'),
    (
      id: 'openai_compatible',
      label: L.pick(en: 'Custom Relay', zhTW: '自訂中轉站', zhCN: '自定义中转站'),
    ),
    (id: 'xai', label: 'xAI (Grok)'),
    (id: 'gemini', label: 'Google Gemini'),
    (id: 'deepseek', label: 'DeepSeek'),
    (id: 'qwen', label: 'Qwen'),
    (id: 'bedrock', label: 'AWS Bedrock'),
    (id: 'thinking_machines', label: 'Thinking Machines'),
    (id: 'local', label: L.pick(en: 'Local Model', zhTW: '本地模型', zhCN: '本地模型')),
    (
      id: 'local_api',
      label: L.pick(en: 'Local API', zhTW: '本地 API', zhCN: '本地 API'),
    ),
  ];

  Widget _buildProviderPicker() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 3 : 2;
        const gap = YanciTheme.spacingSm;
        final cardWidth =
            (constraints.maxWidth - (columns - 1) * gap) / columns;
        const primaryIds = {'openrouter', 'openai_compatible'};
        final options = _providerOptions();
        final visibleOptions = _showOtherProviders
            ? options
            : options
                  .where(
                    (option) =>
                        primaryIds.contains(option.id) ||
                        option.id == _provider,
                  )
                  .toList();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final option in visibleOptions)
              SizedBox(
                width: cardWidth,
                child: _buildProviderOption(id: option.id, label: option.label),
              ),
          ],
        );
      },
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

  Widget _buildProviderOption({required String id, required String label}) {
    final selected = _provider == id;
    final selectedColor = Color.lerp(
      const Color(0xFF4CAF6A),
      YanciTheme.accent,
      0.28,
    )!;
    return Semantics(
      key: ValueKey<String>('api_settings_provider_$id'),
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        onTap: selected ? null : () => _handleProviderChanged(id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: selected ? selectedColor : _settingsBorderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? selectedColor : Colors.transparent,
                  border: Border.all(
                    color: selected
                        ? selectedColor
                        : YanciTheme.textSecondary.withValues(alpha: 0.72),
                    width: selected ? 1 : 1.5,
                  ),
                ),
                child: selected
                    ? Center(
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: YanciTheme.spacingSm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: YanciTheme.bodyText.copyWith(
                    fontSize: 13.5,
                    color: selected
                        ? YanciTheme.textPrimary
                        : YanciTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _buildApiKeyDecoration({
    required String hintText,
    List<Widget> trailingActions = const <Widget>[],
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: YanciTheme.bodySmall.copyWith(
        color: YanciTheme.textSecondary.withValues(alpha: 0.48),
      ),
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      isDense: true,
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...trailingActions,
          IconButton(
            icon: Icon(
              _obscureProviderKeys
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 21,
            ),
            color: YanciTheme.textSecondary,
            tooltip: L.pick(en: 'Show API Key', zhTW: '顯示 API Key'),
            onPressed: () =>
                setState(() => _obscureProviderKeys = !_obscureProviderKeys),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyField({
    required TextEditingController controller,
    required String hintText,
    required ValueChanged<String> onChanged,
    List<Widget> trailingActions = const <Widget>[],
  }) {
    return TextField(
      controller: controller,
      obscureText: _obscureProviderKeys,
      style: YanciTheme.bodyText.copyWith(fontSize: 14),
      onChanged: onChanged,
      decoration: _buildApiKeyDecoration(
        hintText: hintText,
        trailingActions: trailingActions,
      ),
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
    'openai_compatible' => L.pick(
      en: 'Custom Relay',
      zhTW: '自訂中轉站',
      zhCN: '自定义中转站',
    ),
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
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 4,
                      ),
                      border: _thinInputBorder(),
                      enabledBorder: _thinInputBorder(),
                      focusedBorder: _thinInputBorder(
                        color: YanciTheme.accent.withValues(alpha: 0.85),
                        width: 1,
                      ),
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
    WebSearchMode.auto => L.pick(en: 'Auto', zhTW: '自動選擇', zhCN: '自动选择'),
    WebSearchMode.gemini => 'Gemini',
    WebSearchMode.openRouter => 'OpenRouter',
    WebSearchMode.xai => 'Grok / xAI',
    WebSearchMode.relay => L.pick(
      en: 'Search relay',
      zhTW: '搜尋中轉站',
      zhCN: '搜索中转站',
    ),
    // Retained only to migrate old stored values; it is no longer shown.
    WebSearchMode.dual => L.pick(en: 'Auto', zhTW: '自動選擇', zhCN: '自动选择'),
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
    String? emptySelectionLabel,
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
    final effectiveModel = currentOverride.isNotEmpty
        ? currentOverride
        : fallbackModel;

    // 確保 currentOverride 在候選清單裡（即使已取消星標）。
    if (currentOverride.isNotEmpty && !candidates.contains(currentOverride)) {
      candidates.insert(0, currentOverride);
    }

    final ready = hasApiKey && effectiveModel.isNotEmpty;
    final statusText = !hasApiKey
        ? L.pick(en: 'No API key', zhTW: '尚未輸入 API 金鑰', zhCN: '尚未输入 API 密钥')
        : ready
        ? L.pick(en: 'Ready', zhTW: '已就緒', zhCN: '已就绪')
        : L.pick(en: 'No model selected', zhTW: '尚未選擇模型', zhCN: '尚未选择模型');

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
                ready ? Icons.check_circle_outline_rounded : Icons.info_outline,
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
              zhCN: '$providerLabel 搜索模型',
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
                      en:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? 'Choose a starred model'
                              : 'Auto · $fallbackModel'),
                      zhTW:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? '選擇已星標模型'
                              : '自動 · $fallbackModel'),
                      zhCN:
                          emptySelectionLabel ??
                          (fallbackModel.isEmpty
                              ? '选择已星标模型'
                              : '自动 · $fallbackModel'),
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
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              L.pick(
                en: 'Star models for this source above, then choose one here.',
                zhTW: '請先在上方替此來源的模型加上星標，再於此選擇。',
                zhCN: '请先在上方为此来源的模型加上星标，再在此选择。',
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

  WebSearchMode _resolvedAutomaticWebSearchMode() {
    final openRouterModel = _wsSearchOrModelOverride.isNotEmpty
        ? _wsSearchOrModelOverride
        : openRouterWebSearchPreviewModel;
    final geminiModel = _wsSearchGeminiModelOverride.isNotEmpty
        ? _wsSearchGeminiModelOverride
        : _webSearchGeminiModel;
    final xaiModel = _wsSearchXaiModelOverride.isNotEmpty
        ? _wsSearchXaiModelOverride
        : _webSearchXaiModel;
    final relayEndpoint = Uri.tryParse(_webSearchRelayEndpointCtrl.text.trim());

    final ready = <WebSearchMode, bool>{
      WebSearchMode.openRouter:
          _apiKeyController.text.trim().isNotEmpty &&
          isExplicitOpenRouterWebSearchModel(openRouterModel),
      WebSearchMode.gemini:
          _geminiKeyCtrl.text.trim().isNotEmpty &&
          isSupportedGeminiWebSearchModel(geminiModel),
      WebSearchMode.xai:
          _xaiKeyCtrl.text.trim().isNotEmpty && xaiModel.trim().isNotEmpty,
      WebSearchMode.relay:
          _webSearchRelayKeyCtrl.text.trim().isNotEmpty &&
          _webSearchRelayModelCtrl.text.trim().isNotEmpty &&
          relayEndpoint != null &&
          relayEndpoint.scheme == 'https' &&
          relayEndpoint.host.isNotEmpty &&
          relayEndpoint.userInfo.isEmpty &&
          relayEndpoint.fragment.isEmpty,
    };
    final current = switch (_provider) {
      'gemini' => WebSearchMode.gemini,
      'openrouter' => WebSearchMode.openRouter,
      'xai' => WebSearchMode.xai,
      _ => null,
    };
    if (current != null && ready[current] == true) return current;
    for (final mode in const <WebSearchMode>[
      WebSearchMode.gemini,
      WebSearchMode.openRouter,
      WebSearchMode.xai,
      WebSearchMode.relay,
    ]) {
      if (ready[mode] == true) return mode;
    }

    // Nothing is configured yet: expose the most relevant picker so setup can
    // continue without silently changing the runtime auto-selection order.
    return switch (_provider) {
      'openrouter' => WebSearchMode.openRouter,
      'xai' => WebSearchMode.xai,
      'openai_compatible' => WebSearchMode.relay,
      _ => WebSearchMode.gemini,
    };
  }

  List<Widget> _buildSelectedWebSearchSourceOptions() {
    final mode = _webSearchMode == WebSearchMode.auto
        ? _resolvedAutomaticWebSearchMode()
        : _webSearchMode;
    final showOpenRouter = mode == WebSearchMode.openRouter;
    final showGemini = mode == WebSearchMode.gemini;
    final showXai = mode == WebSearchMode.xai;
    final showRelay = mode == WebSearchMode.relay;
    if (!showOpenRouter && !showGemini && !showXai && !showRelay) {
      return <Widget>[];
    }
    final sections = <Widget>[];
    void addSection(Widget child) {
      if (sections.isNotEmpty) {
        sections.add(
          Divider(
            color: YanciTheme.textSecondary.withValues(alpha: 0.12),
            height: 1,
          ),
        );
      }
      sections.add(child);
    }

    if (showOpenRouter) {
      addSection(
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
      );
    }
    if (showGemini) {
      addSection(
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
      );
    }
    if (showXai) {
      addSection(
        _buildWebSearchSearchModelPicker(
          providerLabel: 'Grok / xAI',
          filterProvider: 'xai',
          currentOverride: _wsSearchXaiModelOverride,
          fallbackModel: _webSearchXaiModel,
          hasApiKey: _xaiKeyCtrl.text.trim().isNotEmpty,
          onChanged: (value) {
            setState(() => _wsSearchXaiModelOverride = value);
            _debouncedSave();
          },
        ),
      );
    }
    if (showRelay) addSection(_buildWebSearchRelayOptions());
    return sections;
  }

  Widget _buildWebSearchRelayOptions() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            L.pick(
              en: 'Search relay (OpenAI-compatible)',
              zhTW: '搜尋中轉站（OpenAI 相容）',
              zhCN: '搜索中转站（OpenAI 兼容）',
            ),
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _webSearchRelayEndpointCtrl,
            keyboardType: TextInputType.url,
            onChanged: (_) => _debouncedSave(),
            decoration: InputDecoration(
              hintText: L.pick(
                en: 'https://relay.example/v1/chat/completions',
                zhTW: 'https://relay.example/v1/chat/completions',
                zhCN: 'https://relay.example/v1/chat/completions',
              ),
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _webSearchRelayKeyCtrl,
            obscureText: _obscureProviderKeys,
            onChanged: (_) => _debouncedSave(),
            decoration: InputDecoration(
              hintText: L.pick(
                en: 'Relay API Key',
                zhTW: '中轉站 API 金鑰',
                zhCN: '中转站 API 密钥',
              ),
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureProviderKeys
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                tooltip: L.pick(en: 'Show API Key', zhTW: '顯示 API Key'),
                onPressed: () => setState(
                  () => _obscureProviderKeys = !_obscureProviderKeys,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _buildWebSearchSearchModelPicker(
            providerLabel: L.pick(
              en: 'Search relay',
              zhTW: '搜尋中轉站',
              zhCN: '搜索中转站',
            ),
            filterProvider: 'openai_compatible',
            currentOverride: _webSearchRelayModelCtrl.text.trim(),
            fallbackModel: '',
            hasApiKey:
                _webSearchRelayEndpointCtrl.text.trim().isNotEmpty &&
                _webSearchRelayKeyCtrl.text.trim().isNotEmpty,
            onChanged: (value) {
              setState(() => _webSearchRelayModelCtrl.text = value);
              _debouncedSave();
            },
          ),
          const SizedBox(height: 6),
          Text(
            L.pick(
              en: 'Only HTTPS OpenAI Chat Completions relays are accepted; the relay must return url_citation annotations.',
              zhTW:
                  '只接受 HTTPS OpenAI Chat Completions 中轉站；中轉站必須回傳 url_citation 引用。',
              zhCN:
                  '只接受 HTTPS OpenAI Chat Completions 中转站；中转站必须返回 url_citation 引用。',
            ),
            style: YanciTheme.bodySmall.copyWith(
              fontSize: 11,
              height: 1.4,
              color: YanciTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebSearchSettingsCard() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _apiKeyController,
        _geminiKeyCtrl,
        _xaiKeyCtrl,
        _webSearchRelayEndpointCtrl,
        _webSearchRelayKeyCtrl,
        _webSearchRelayModelCtrl,
      ]),
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
                    L.pick(
                      en: 'Native web search',
                      zhTW: '原生網路搜尋',
                      zhCN: '原生网络搜索',
                    ),
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                  value: _webSearchEnabled,
                  activeThumbColor: YanciTheme.accent,
                  activeTrackColor: YanciTheme.accent.withValues(alpha: 0.3),
                  onChanged: webSearchLiveDeveloperPreviewEnabled
                      ? (value) {
                          setState(() => _webSearchEnabled = value);
                          _debouncedSave();
                          StaticTokenEstimator.showAfterToggle(context);
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
                  L.pick(en: 'Source', zhTW: '來源', zhCN: '来源'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Semantics(
                  label: L.pick(
                    en: 'Search source',
                    zhTW: '搜尋來源',
                    zhCN: '搜索来源',
                  ),
                  value: selectedModeLabel,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                      border: Border.all(
                        color: _settingsBorderColor,
                        width: 0.75,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
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
                          if (mode != WebSearchMode.dual)
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
                ),
                const SizedBox(height: 10),
                ..._buildSelectedWebSearchSourceOptions(),
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
                          en: 'Web pages per search',
                          zhTW: '每次搜尋網頁數',
                          zhCN: '每次搜索网页数',
                        ),
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      L.pick(
                        en: '$_webSearchMaxResults pages',
                        zhTW: '$_webSearchMaxResults 頁',
                        zhCN: '$_webSearchMaxResults 页',
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
                    en: 'Web pages per search',
                    zhTW: '每次搜尋網頁數',
                    zhCN: '每次搜索网页数',
                  ),
                  value: '$_webSearchMaxResults',
                  child: Slider.adaptive(
                    value: _webSearchMaxResults.toDouble(),
                    min: WebSearchSettings.minMaxResults.toDouble(),
                    max: WebSearchSettings.maxMaxResults.toDouble(),
                    divisions:
                        WebSearchSettings.maxMaxResults -
                        WebSearchSettings.minMaxResults,
                    label: '$_webSearchMaxResults',
                    activeColor: YanciTheme.accent,
                    onChanged: (value) {
                      setState(() => _webSearchMaxResults = value.round());
                      _debouncedSave();
                    },
                    semanticFormatterCallback: (value) => L.pick(
                      en: '${value.round()} web pages per search',
                      zhTW: '每次搜尋 ${value.round()} 個網頁',
                      zhCN: '每次搜索 ${value.round()} 个网页',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
                          zhCN: '每日供应商启动上限',
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
                        zhCN: '$_webSearchDailyProviderLaunchCap 次／日',
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
                    zhCN: '每日供应商启动上限',
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
                      zhCN: '每日 ${value.round()} 次供应商启动',
                    ),
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

  OutlineInputBorder _thinInputBorder({Color? color, double width = 0.75}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
      borderSide: BorderSide(
        color: color ?? _settingsBorderColor,
        width: width,
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

  Widget _buildModelPicker(BuildContext context) {
    final selectedModel = _modelValueForProvider();
    final hasModels = _models.isNotEmpty;
    final hasSearchResults = _filteredModels.isNotEmpty;
    final query = _modelSearchController.text.trim();
    final modelCountText = hasModels
        ? L.pick(
            en: '${_models.length} models available',
            zhTW: '已載入 ${_models.length} 個模型',
            zhCN: '已加载 ${_models.length} 个模型',
          )
        : L.pick(
            en: 'Enter a model ID or fetch the list',
            zhTW: '可直接填入模型 ID，或拉取列表',
            zhCN: '可直接填入模型 ID，或拉取列表',
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YanciTheme.spacingXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectedModel.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: YanciTheme.spacingSm,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: YanciTheme.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                border: Border.all(
                  color: _selectionSuccessColor.withValues(alpha: 0.72),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: _selectionSuccessColor,
                  ),
                  const SizedBox(width: YanciTheme.spacingSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.pick(
                            en: 'Current model',
                            zhTW: '目前模型',
                            zhCN: '当前模型',
                          ),
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 11,
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 22),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: Text(
                              selectedModel,
                              maxLines: 1,
                              softWrap: false,
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 13,
                                color: YanciTheme.textPrimary,
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
            const SizedBox(height: YanciTheme.spacingSm),
          ],
          Semantics(
            textField: true,
            label: L.pick(en: 'Search models', zhTW: '搜尋模型', zhCN: '搜索模型'),
            child: TextField(
              key: const Key('api_settings_model_search_field'),
              controller: _modelSearchController,
              style: YanciTheme.bodyText.copyWith(fontSize: 14),
              decoration: InputDecoration(
                hintText: _models.isEmpty
                    ? L.get('settings_model_hint_empty')
                    : L.get('settings_model_hint_search'),
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.52),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: YanciTheme.textSecondary,
                ),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        tooltip: L.pick(en: 'Clear search', zhTW: '清除搜尋'),
                        onPressed: () {
                          _modelSearchController.clear();
                          _filterModels('');
                        },
                      )
                    : null,
              ),
              onChanged: _filterModels,
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  _selectModel(value.trim());
                }
              },
            ),
          ),
          const SizedBox(height: YanciTheme.spacingXs),
          Row(
            children: [
              Expanded(
                child: Text(
                  modelCountText,
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (hasModels)
                TextButton.icon(
                  key: const Key('api_settings_model_list_toggle'),
                  onPressed: () =>
                      setState(() => _showModelList = !_showModelList),
                  icon: Icon(
                    _showModelList
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                  ),
                  label: Text(
                    L.pick(
                      en: _showModelList ? 'Collapse' : 'Show list',
                      zhTW: _showModelList ? '收起' : '展開列表',
                      zhCN: _showModelList ? '收起' : '展开列表',
                    ),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: YanciTheme.textSecondary,
                  ),
                ),
              Tooltip(
                message: L.get('settings_model_refresh'),
                child: TextButton.icon(
                  key: const Key('api_settings_model_refresh_button'),
                  onPressed: _isFetchingModels ? null : _fetchModels,
                  icon: _isFetchingModels
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded, size: 17),
                  label: Text(
                    L.pick(en: 'Fetch list', zhTW: '拉取列表', zhCN: '拉取列表'),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: YanciTheme.accent,
                  ),
                ),
              ),
            ],
          ),
          if (hasModels && _showModelList) ...[
            const SizedBox(height: YanciTheme.spacingXs),
            ConstrainedBox(
              constraints: BoxConstraints(
                // Keep the first three results visible; the rest scrolls.
                maxHeight: 172,
              ),
              child: hasSearchResults
                  ? ListView.separated(
                      shrinkWrap: true,
                      itemCount: _filteredModels.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: YanciTheme.spacingSm,
                        endIndent: YanciTheme.spacingSm,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.10),
                      ),
                      itemBuilder: (context, index) {
                        final model = _filteredModels[index];
                        final isSelected = model.id == _modelValueForProvider();
                        return InkWell(
                          onTap: () => _selectModel(model.id),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: YanciTheme.spacingSm,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    model.id,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: YanciTheme.bodyText.copyWith(
                                      fontSize: 13,
                                      color: isSelected
                                          ? YanciTheme.accent
                                          : YanciTheme.textPrimary,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: YanciTheme.accent,
                                    ),
                                  ),
                                IconButton(
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  padding: EdgeInsets.zero,
                                  onPressed: () async {
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
                                      _starredModels = starred.toSet();
                                      _starredModelProviders = providers;
                                    });
                                  },
                                  icon: Icon(
                                    _starredModels.contains(model.id)
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    size: 20,
                                    color: _starredModels.contains(model.id)
                                        ? YanciTheme.accent
                                        : YanciTheme.textSecondary.withValues(
                                            alpha: 0.42,
                                          ),
                                  ),
                                  tooltip: _starredModels.contains(model.id)
                                      ? L.pick(
                                          en: 'Remove from favorites',
                                          zhTW: '取消收藏',
                                        )
                                      : L.pick(
                                          en: 'Add to favorites',
                                          zhTW: '加入收藏',
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.all(YanciTheme.spacingMd),
                      child: Text(
                        L.pick(
                          en: 'No matching models',
                          zhTW: '沒有符合的模型',
                          zhCN: '没有符合的模型',
                        ),
                        style: YanciTheme.bodySmall,
                      ),
                    ),
            ),
          ],
        ],
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
          _buildApiKeyField(
            controller: _thinkingMachinesKeyCtrl,
            hintText: 'Tinker API Key',
            onChanged: (_) => _debouncedSave(),
            trailingActions: [
              _isTestingApi
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
            ],
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
                              _buildThinkingMachinesCard(),
                            ],
                            if (_provider == 'openrouter') ...[
                              _buildGlassCard(
                                child: _buildApiKeyField(
                                  controller: _apiKeyController,
                                  hintText: L.get('settings_api_key_hint'),
                                  onChanged: (v) {
                                    _scheduleProviderModelFetch(
                                      'openrouter',
                                      v,
                                    );
                                    _debouncedSave();
                                  },
                                ),
                              ),
                            ],
                            if (_provider == 'xai') ...[
                              _buildGlassCard(
                                child: _buildApiKeyField(
                                  controller: _xaiKeyCtrl,
                                  hintText: 'xAI API Key',
                                  onChanged: (value) {
                                    _scheduleProviderModelFetch('xai', value);
                                    _debouncedSave();
                                  },
                                  trailingActions: [
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
                                  ],
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
                                child: _buildApiKeyField(
                                  controller: _geminiKeyCtrl,
                                  hintText: 'Gemini API Key',
                                  onChanged: (v) {
                                    _scheduleProviderModelFetch('gemini', v);
                                    _debouncedSave();
                                  },
                                  trailingActions: [
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
                                  ],
                                ),
                              ),
                            ],
                            if (_provider == 'deepseek') ...[
                              _buildGlassCard(
                                child: _buildApiKeyField(
                                  controller: _deepseekKeyCtrl,
                                  hintText: 'DeepSeek API Key',
                                  onChanged: (v) {
                                    _scheduleProviderModelFetch('deepseek', v);
                                    _debouncedSave();
                                  },
                                  trailingActions: [
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
                                  ],
                                ),
                              ),
                            ],
                            if (_provider == 'qwen') ...[
                              _buildGlassCard(
                                child: _buildApiKeyField(
                                  controller: _qwenKeyCtrl,
                                  hintText: 'Qwen API Key (DashScope)',
                                  onChanged: (v) => _debouncedSave(),
                                  trailingActions: [
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
                                          'qwen',
                                          _qwenKeyCtrl.text,
                                        ),
                                      ),
                                  ],
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
                                    _buildApiKeyField(
                                      controller: _awsSecretAccessKeyCtrl,
                                      hintText: 'AWS Secret Access Key',
                                      onChanged: (v) => _debouncedSave(),
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
                                    _buildApiKeyField(
                                      controller: _oaiCompatKeyCtrl,
                                      hintText: 'API Key',
                                      onChanged: (v) {
                                        _scheduleCompatibleModelFetch(
                                          _oaiCompatBaseUrlCtrl.text,
                                        );
                                        _debouncedSave();
                                      },
                                      trailingActions: [
                                        _isTestingApi
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
                                      ],
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
                              _buildModelPicker(context),
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
                              _buildWebSearchSettingsCard(),
                              const SizedBox(height: YanciTheme.spacingLg),
                              _buildSectionTitle(
                                L.get('settings_summary_model'),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildSummaryModelCard(),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildDreamCurationCard(),
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
