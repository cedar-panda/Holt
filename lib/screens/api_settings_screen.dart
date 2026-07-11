import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/openrouter_service.dart';
import '../services/settings_manager.dart';
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

  String _selectedModel = '';
  List<ModelInfo> _models = [];
  List<ModelInfo> _filteredModels = [];
  Set<String> _starredModels = {};
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

    final starred = await ApiSettings.getStarredModels();
    final savedModel = await ApiSettings.getModelForProvider(provider);

    if (mounted) {
      setState(() {
        _apiKeyController.text = apiKey;
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

        _starredModels = starred.toSet();
        _selectedModel = savedModel;
        _settingsLoaded = true;
      });
      if (_provider == 'openrouter' && apiKey.isNotEmpty) {
        _fetchModels();
      }
    }
  }

  Future<void> _fetchModels() async {
    final requestGeneration = ++_modelFetchGeneration;
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      if (mounted) {
        setState(() {
          _isFetchingModels = false;
          _modelError = L.get('settings_model_error_no_key');
        });
      }
      return;
    }
    setState(() {
      _isFetchingModels = true;
      _modelError = null;
    });

    try {
      final models = await OpenRouterService.fetchModels(apiKey);
      if (mounted && requestGeneration == _modelFetchGeneration) {
        setState(() {
          _models = models;
          _filteredModels = models;
          _isFetchingModels = false;
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
        final base = Uri.tryParse(rawBase);
        if (base == null || !base.hasScheme || base.host.isEmpty) {
          throw const FormatException('Base URL 無效');
        }
        final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
        final modelsUri = base.replace(path: '$basePath/models');
        response = await http
            .get(
              modelsUri,
              headers: {
                if (keyStr.isNotEmpty) 'Authorization': 'Bearer $keyStr',
              },
            )
            .timeout(const Duration(seconds: 20));
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
    return _selectedModel;
  }

  Future<void> _saveSettings() async {
    // 先取完整快照；保存途中繼續輸入時，下一輪會再保存新快照，
    // 不會讓同一輪混入新舊欄位值。
    final openRouterKey = _apiKeyController.text.trim();
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

    await ApiSettings.saveOpenRouterApiKey(openRouterKey);
    await ApiSettings.saveSystemPrompt(systemPrompt);
    await ApiSettings.saveApiProvider(provider);
    await ApiSettings.saveModelForProvider(provider, model);
    await ApiSettings.saveGeminiApiKey(geminiKey);
    await ApiSettings.saveDeepseekApiKey(deepseekKey);
    await ApiSettings.saveQwenApiKey(qwenKey);
    await ApiSettings.saveAwsAccessKeyId(awsAccessKeyId);
    await ApiSettings.saveAwsSecretAccessKey(awsSecretAccessKey);
    await ApiSettings.saveAwsRegion(awsRegion);
    await ApiSettings.saveOaiCompatBaseUrl(oaiBaseUrl);
    await ApiSettings.saveOaiCompatApiKey(oaiKey);
    await ApiSettings.saveOaiCompatModel(oaiModel);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _modelFetchTimer?.cancel();
    _modelFetchGeneration++;
    _apiKeyController.dispose();
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
                                    value: 'openai_compatible',
                                    child: Text('OpenAI Compatible (Custom)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'local_api',
                                    child: Text('Local API (Endpoint)'),
                                  ),
                                ],
                                onChanged: (v) async {
                                  if (v == null) return;
                                  setState(() => _provider = v);
                                  final savedModel =
                                      await ApiSettings.getModelForProvider(v);
                                  setState(() => _selectedModel = savedModel);
                                  if (v == 'openrouter') {
                                    _fetchModels();
                                  } else {
                                    setState(() => _models = []);
                                    _filteredModels = [];
                                  }
                                  _debouncedSave();
                                },
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingMd),
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
                                      onChanged: (v) => _debouncedSave(),
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
                                      onChanged: (v) => _debouncedSave(),
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
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: 'Model name (e.g. gpt-4o)',
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
                            if (_provider == 'local_api') ...[
                              _buildGlassCard(
                                child: Text(
                                  L.pick(
                                    en: 'Local API is configured on the Local Models page.',
                                    zhTW: '本地 API 在「本地模型」頁面設定。',
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
                              '${L.get('settings_model_label')}${_selectedModel.isNotEmpty ? "：$_selectedModel" : ""}',
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
                                      setState(() {
                                        _selectedModel = v.trim();
                                        _modelSearchController.clear();
                                        _filteredModels = _models;
                                      });
                                      _debouncedSave();
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
                                              model.id == _selectedModel;
                                          return InkWell(
                                            onTap: () {
                                              setState(() {
                                                _selectedModel = model.id;
                                                _modelSearchController.clear();
                                                _filteredModels = _models;
                                              });
                                              _debouncedSave();
                                            },
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
                                                      );
                                                      final starred =
                                                          await ApiSettings.getStarredModels();
                                                      if (!mounted) return;
                                                      setState(
                                                        () => _starredModels =
                                                            starred.toSet(),
                                                      );
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
