import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/openai_compatible_service.dart';
import '../services/openrouter_service.dart';
import '../services/model_info.dart';
import '../services/xai_service.dart';
import '../services/thinking_machines_service.dart';
import '../services/model_cost_policy.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
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
  List<ModelInfo> _models = [];
  List<ModelInfo> _filteredModels = [];
  Set<String> _starredModels = {};
  Map<String, String> _starredModelProviders = {};
  final _modelSearchController = TextEditingController();

  bool _isFetchingModels = false;
  bool _isTestingApi = false;
  String? _modelError;
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
    final requestGeneration = ++_modelFetchGeneration;
    final isCompatible = _provider == 'openai_compatible';
    final isXai = _provider == 'xai';
    final apiKey = isCompatible
        ? _oaiCompatKeyCtrl.text.trim()
        : isXai
        ? _xaiKeyCtrl.text.trim()
        : _apiKeyController.text.trim();
    final baseUrl = _oaiCompatBaseUrlCtrl.text.trim();
    if ((!isCompatible && apiKey.isEmpty) ||
        (isCompatible && baseUrl.isEmpty)) {
      if (mounted) {
        setState(() {
          _isFetchingModels = false;
          _modelError = isCompatible
              ? L.pick(en: 'Enter a Base URL first', zhTW: '請先輸入 Base URL')
              : L.get('settings_model_error_no_key');
        });
      }
      return;
    }
    setState(() {
      _isFetchingModels = true;
      _modelError = null;
    });

    try {
      final models = isCompatible
          ? await OpenAICompatibleService.fetchModels(
              baseUrl: baseUrl,
              apiKey: apiKey,
            )
          : isXai
          ? await XaiService.fetchModels(apiKey)
          : await OpenRouterService.fetchModels(apiKey);
      if (mounted && requestGeneration == _modelFetchGeneration) {
        await ApiSettings.rememberStarredModelProviders(
          models.map((model) => model.id),
          isCompatible ? 'openai_compatible' : (isXai ? 'xai' : 'openrouter'),
        );
        if (!mounted || requestGeneration != _modelFetchGeneration) return;
        setState(() {
          _models = models;
          _filteredModels = models;
          _isFetchingModels = false;
          if (isCompatible) _showModelSection = true;
        });
      }
    } catch (e) {
      if (mounted && requestGeneration == _modelFetchGeneration) {
        setState(() {
          _isFetchingModels = false;
          _modelError = '${L.get('settings_model_error_fetch')}: $e';
        });
      }
    }
  }

  void _scheduleModelFetch(String key) {
    _modelFetchTimer?.cancel();
    if (!key.trim().startsWith('sk-or-')) {
      _modelFetchGeneration++;
      if (mounted) {
        setState(() {
          _isFetchingModels = false;
          _modelError = null;
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

  void _scheduleXaiModelFetch(String key) {
    _modelFetchTimer?.cancel();
    if (key.trim().length < 8) {
      _modelFetchGeneration++;
      return;
    }
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
                'https://generativelanguage.googleapis.com/v1beta/models?key=$keyStr',
              ),
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
              Uri.parse('https://dashscope.aliyuncs.com/api/v1/models'),
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
    await MemorySettings.saveSummarySelection(
      provider: summaryProvider,
      model: summaryModel,
    );
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
                                  setState(() => _provider = v);
                                  final savedModel =
                                      await ApiSettings.getModelForProvider(v);
                                  if (!mounted) return;
                                  setState(() => _selectedModel = savedModel);
                                  if (v == 'openrouter' ||
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
                                          _scheduleModelFetch(v);
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
                                    _scheduleXaiModelFetch(value);
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
                                  onChanged: (v) => _debouncedSave(),
                                  decoration: InputDecoration(
                                    hintText: 'Gemini API Key',
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
                                              'gemini',
                                              _geminiKeyCtrl.text,
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
                            if (_provider == 'deepseek') ...[
                              _buildGlassCard(
                                child: TextField(
                                  controller: _deepseekKeyCtrl,
                                  obscureText: _obscureProviderKeys,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 13,
                                  ),
                                  onChanged: (v) => _debouncedSave(),
                                  decoration: InputDecoration(
                                    hintText: 'DeepSeek API Key',
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
                                              'deepseek',
                                              _deepseekKeyCtrl.text,
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
                              if (_modelError != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: YanciTheme.spacingSm,
                                  ),
                                  child: Text(
                                    _modelError!,
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
                            _buildSectionTitle(L.get('settings_summary_model')),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildSummaryModelCard(),
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
