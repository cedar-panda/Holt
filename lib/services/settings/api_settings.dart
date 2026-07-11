import 'package:shared_preferences/shared_preferences.dart';
import '../secure_store.dart';
import '../api_adapter.dart';
import '../openrouter_service.dart';
import '../aws_bedrock_service.dart';
import '../gemini_service.dart';
import '../deepseek_service.dart';
import '../qwen_service.dart';
import '../openai_compatible_service.dart';
import '../local_model_service.dart';

/// API 供應商配置（OpenRouter / Bedrock / Gemini / DeepSeek / Qwen / OpenAI Compatible / Local API）
class ApiSettings {
  // ═══ 通用 ═══
  static const String _keyLegacyApiKey = 'api_key';
  static const String _keyOpenRouterApiKey = 'openrouter_api_key';
  static const String _keyModel = 'model';
  static const String _keySystemPrompt = 'system_prompt';
  static const String _keyApiProvider = 'api_provider';
  static const String _keyImageGenModel = 'image_gen_model';
  static String? _cachedLocalModelKey;
  static LocalModelService? _cachedLocalModelService;
  static Future<LocalModelService>? _cachedLocalModelFuture;
  static String? _cachedGeminiKey;
  static String? _cachedGeminiModel;
  static GeminiService? _cachedGeminiService;
  static const String localApiModelPrefix = 'local_api:';

  static Future<String> getApiProviderName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyApiProvider) ?? 'openrouter';
  }

  /// 畫圖模型（OpenRouter 圖像輸出模型）
  static Future<void> saveImageGenModel(String model) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyImageGenModel, model);
  }

  static Future<String> getImageGenModel() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_keyImageGenModel) ?? '';
    return v.isEmpty ? 'openai/gpt-5.4-image-2' : v;
  }

  static Future<void> saveApiKey(String key) async {
    await saveOpenRouterApiKey(key);
  }

  static Future<String> getApiKey() async {
    return getApiKeyForProvider(await getApiProvider());
  }

  static Future<void> saveOpenRouterApiKey(String key) async {
    await SecureStore.write(_keyOpenRouterApiKey, key);
    await SecureStore.delete(_keyLegacyApiKey);
  }

  static Future<String> getOpenRouterApiKey() async {
    final key = await SecureStore.read(_keyOpenRouterApiKey);
    if (key.isNotEmpty) return key;

    final legacy = await SecureStore.read(_keyLegacyApiKey);
    if (legacy.isNotEmpty) {
      await saveOpenRouterApiKey(legacy);
    }
    return legacy;
  }

  static Future<void> saveApiKeyForProvider(String provider, String key) async {
    switch (provider) {
      case 'openrouter':
        await saveOpenRouterApiKey(key);
        break;
      case 'gemini':
        await saveGeminiApiKey(key);
        break;
      case 'deepseek':
        await saveDeepseekApiKey(key);
        break;
      case 'qwen':
        await saveQwenApiKey(key);
        break;
      case 'openai_compatible':
        await saveOaiCompatApiKey(key);
        break;
      case 'local_api':
        await saveLocalApiKey(key);
        break;
    }
  }

  static Future<String> getApiKeyForProvider(String provider) async {
    switch (provider) {
      case 'openrouter':
        return getOpenRouterApiKey();
      case 'gemini':
        return getGeminiApiKey();
      case 'deepseek':
        return getDeepseekApiKey();
      case 'qwen':
        return getQwenApiKey();
      case 'openai_compatible':
        return getOaiCompatApiKey();
      case 'local_api':
        return getLocalApiKey();
      default:
        return '';
    }
  }

  static Future<void> saveModel(String model) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyModel, model);
    if (isLocalApiModelId(model)) {
      await p.setString(_keyLocalApiModel, extractLocalApiModel(model));
      await p.setString(_keyApiProvider, 'local_api');
    } else if ((p.getString(_keyApiProvider) ?? 'openrouter') == 'local_api') {
      await p.setString(_keyApiProvider, 'openrouter');
    }
  }

  static Future<String> getModel() async {
    final p = await SharedPreferences.getInstance();
    final provider = p.getString(_keyApiProvider) ?? 'openrouter';
    if (provider == 'local_api') {
      final model = p.getString(_keyLocalApiModel) ?? '';
      if (model.isNotEmpty) return toLocalApiModelId(model);
      final savedModel = p.getString(_keyModel) ?? '';
      return isLocalApiModelId(savedModel) ? savedModel : '';
    }
    if (provider == 'openai_compatible') {
      return p.getString(_keyOaiCompatModel) ?? '';
    }
    if (provider == 'gemini') {
      return p.getString(_keyGeminiModel) ?? 'gemini-2.0-flash';
    }
    if (provider == 'bedrock') {
      return p.getString(_keyAwsModelId) ??
          'anthropic.claude-sonnet-4-20250514-v1:0';
    }
    if (provider == 'deepseek') {
      return p.getString(_keyDeepseekModel) ?? 'deepseek-chat';
    }
    if (provider == 'qwen') {
      return p.getString(_keyQwenModel) ?? 'qwen-plus';
    }
    return p.getString(_keyModel) ?? 'anthropic/claude-sonnet-4-20250514';
  }

  static Future<String> getModelForProvider(String provider) {
    return _modelForProvider(provider);
  }

  static Future<void> saveModelForProvider(
    String provider,
    String model,
  ) async {
    final value = model.trim();
    if (value.isEmpty) return;

    switch (provider) {
      case 'bedrock':
        await saveAwsModelId(value);
        break;
      case 'gemini':
        await saveGeminiModel(value);
        break;
      case 'deepseek':
        await saveDeepseekModel(value);
        break;
      case 'qwen':
        await saveQwenModel(value);
        break;
      case 'openai_compatible':
        await saveOaiCompatModel(value);
        break;
      case 'local_api':
        await saveLocalApiModel(value);
        break;
      default:
        await saveModel(value);
        break;
    }
  }

  static Future<void> saveSystemPrompt(String prompt) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySystemPrompt, prompt);
  }

  static Future<String> getSystemPrompt() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keySystemPrompt) ?? '';
  }

  static Future<void> saveApiProvider(String provider) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyApiProvider, provider);
  }

  static Future<String> getApiProvider() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyApiProvider) ?? 'openrouter';
  }

  // ═══ AWS Bedrock ═══
  static const String _keyAwsAccessKeyId = 'aws_access_key_id';
  static const String _keyAwsSecretAccessKey = 'aws_secret_access_key';
  static const String _keyAwsRegion = 'aws_region';
  static const String _keyAwsModelId = 'aws_model_id';

  static Future<void> saveAwsAccessKeyId(String id) async {
    await SecureStore.write(_keyAwsAccessKeyId, id);
  }

  static Future<String> getAwsAccessKeyId() async {
    return SecureStore.read(_keyAwsAccessKeyId);
  }

  static Future<void> saveAwsSecretAccessKey(String key) async {
    await SecureStore.write(_keyAwsSecretAccessKey, key);
  }

  static Future<String> getAwsSecretAccessKey() async {
    return SecureStore.read(_keyAwsSecretAccessKey);
  }

  static Future<void> saveAwsRegion(String region) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyAwsRegion, region);
  }

  static Future<String> getAwsRegion() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyAwsRegion) ?? 'us-east-1';
  }

  static Future<void> saveAwsModelId(String modelId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyAwsModelId, modelId);
  }

  static Future<String> getAwsModelId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyAwsModelId) ??
        'anthropic.claude-sonnet-4-20250514-v1:0';
  }

  // ═══ Gemini ═══
  static const String _keyGeminiApiKey = 'gemini_api_key';
  static const String _keyGeminiModel = 'gemini_model';

  static Future<void> saveGeminiApiKey(String v) async {
    await SecureStore.write(_keyGeminiApiKey, v);
  }

  static Future<String> getGeminiApiKey() async {
    return SecureStore.read(_keyGeminiApiKey);
  }

  static Future<void> saveGeminiModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyGeminiModel, v);
  }

  static Future<String> getGeminiModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyGeminiModel) ?? 'gemini-2.0-flash';
  }

  // ═══ DeepSeek ═══
  static const String _keyDeepseekApiKey = 'deepseek_api_key';
  static const String _keyDeepseekModel = 'deepseek_model';

  static Future<void> saveDeepseekApiKey(String v) async {
    await SecureStore.write(_keyDeepseekApiKey, v);
  }

  static Future<String> getDeepseekApiKey() async {
    return SecureStore.read(_keyDeepseekApiKey);
  }

  static Future<void> saveDeepseekModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyDeepseekModel, v);
  }

  static Future<String> getDeepseekModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyDeepseekModel) ?? 'deepseek-chat';
  }

  // ═══ Qwen ═══
  static const String _keyQwenApiKey = 'qwen_api_key';
  static const String _keyQwenModel = 'qwen_model';

  static Future<void> saveQwenApiKey(String v) async {
    await SecureStore.write(_keyQwenApiKey, v);
  }

  static Future<String> getQwenApiKey() async {
    return SecureStore.read(_keyQwenApiKey);
  }

  static Future<void> saveQwenModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyQwenModel, v);
  }

  static Future<String> getQwenModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyQwenModel) ?? 'qwen-plus';
  }

  // ═══ OpenAI Compatible（中轉站）═══
  static const String _keyOaiCompatBaseUrl = 'oai_compat_base_url';
  static const String _keyOaiCompatApiKey = 'oai_compat_api_key';
  static const String _keyOaiCompatModel = 'oai_compat_model';

  static Future<void> saveOaiCompatBaseUrl(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyOaiCompatBaseUrl, v);
  }

  static Future<String> getOaiCompatBaseUrl() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyOaiCompatBaseUrl) ?? '';
  }

  static Future<void> saveOaiCompatApiKey(String v) async {
    await SecureStore.write(_keyOaiCompatApiKey, v);
  }

  static Future<String> getOaiCompatApiKey() async {
    return SecureStore.read(_keyOaiCompatApiKey);
  }

  static Future<void> saveOaiCompatModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyOaiCompatModel, v);
  }

  static Future<String> getOaiCompatModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyOaiCompatModel) ?? '';
  }

  // ═══ Local API（電腦 / 局域網 OpenAI-compatible 端點）═══
  static const String _keyLocalApiBaseUrl = 'local_api_base_url';
  static const String _keyLocalApiKey = 'local_api_key';
  static const String _keyLocalApiModel = 'local_api_model';

  static bool isLocalApiModelId(String modelId) =>
      modelId.startsWith(localApiModelPrefix);

  static String toLocalApiModelId(String model) {
    final trimmed = model.trim();
    if (trimmed.startsWith(localApiModelPrefix)) return trimmed;
    return '$localApiModelPrefix$trimmed';
  }

  static String extractLocalApiModel(String modelId) =>
      modelId.startsWith(localApiModelPrefix)
      ? modelId.substring(localApiModelPrefix.length)
      : modelId;

  static Future<void> saveLocalApiBaseUrl(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyLocalApiBaseUrl, v);
  }

  static Future<String> getLocalApiBaseUrl() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyLocalApiBaseUrl) ?? '';
  }

  static Future<void> saveLocalApiKey(String v) async {
    await SecureStore.write(_keyLocalApiKey, v);
  }

  static Future<String> getLocalApiKey() async {
    return SecureStore.read(_keyLocalApiKey);
  }

  static Future<void> saveLocalApiModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyLocalApiModel, extractLocalApiModel(v.trim()));
  }

  static Future<String> getLocalApiModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyLocalApiModel) ?? '';
  }

  // ═══ 星標模型 ═══
  static const String _keyStarredModels = 'starred_models';

  static Future<void> saveStarredModels(List<String> models) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyStarredModels, models);
  }

  static Future<List<String>> getStarredModels() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_keyStarredModels) ?? [];
  }

  static Future<void> toggleStarModel(String modelId) async {
    final list = await getStarredModels();
    if (list.contains(modelId)) {
      list.remove(modelId);
    } else {
      list.add(modelId);
    }
    await saveStarredModels(list);
  }

  // ═══ 工廠方法 ═══

  static Future<ApiAdapter> buildAdapter({
    String? overrideModel,
    String? overrideProvider,
  }) async {
    final provider = overrideProvider ?? await getApiProvider();
    // 如果指定了本地模型，直接返回 LocalModelService
    final modelId = overrideModel ?? await _modelForProvider(provider);
    if (LocalModelService.isLocalModelId(modelId)) {
      final key = LocalModelService.extractKey(modelId);
      final cached = _cachedLocalModelService;
      if (_cachedLocalModelKey == key && cached != null) return cached;

      final pending = _cachedLocalModelFuture;
      if (_cachedLocalModelKey == key && pending != null) return pending;

      await _disposeCachedLocalModel();
      _cachedLocalModelKey = key;
      _cachedLocalModelFuture = _loadLocalModelService(key);
      try {
        final service = await _cachedLocalModelFuture!;
        _cachedLocalModelService = service;
        return service;
      } finally {
        _cachedLocalModelFuture = null;
      }
    }

    if (isLocalApiModelId(modelId)) {
      await _disposeCachedLocalModel();
      final baseUrl = await getLocalApiBaseUrl();
      final key = await getLocalApiKey();
      if (baseUrl.isEmpty) throw Exception('本地 API Base URL 未設定');
      return OpenAICompatibleService(
        apiKey: key,
        baseUrl: baseUrl,
        modelPrefixToStrip: localApiModelPrefix,
      );
    }

    await _disposeCachedLocalModel();

    if (provider == 'local_api') {
      final baseUrl = await getLocalApiBaseUrl();
      final key = await getLocalApiKey();
      if (baseUrl.isEmpty) throw Exception('本地 API Base URL 未設定');
      return OpenAICompatibleService(
        apiKey: key,
        baseUrl: baseUrl,
        modelPrefixToStrip: localApiModelPrefix,
      );
    }

    if (provider == 'bedrock') {
      final accessKeyId = await getAwsAccessKeyId();
      final secretAccessKey = await getAwsSecretAccessKey();
      final region = await getAwsRegion();
      final bedrockModelId = overrideModel ?? await getAwsModelId();
      if (accessKeyId.isEmpty || secretAccessKey.isEmpty) {
        throw Exception('AWS 憑證未設定');
      }
      return BedrockService(
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        region: region,
        modelId: bedrockModelId,
      );
    }

    if (provider == 'gemini') {
      final key = await getGeminiApiKey();
      if (key.isEmpty) throw Exception('Gemini API Key 未設定');
      final model = overrideModel ?? await getGeminiModel();
      final cached = _cachedGeminiService;
      if (_cachedGeminiKey == key &&
          _cachedGeminiModel == model &&
          cached != null) {
        return cached;
      }
      _cachedGeminiKey = key;
      _cachedGeminiModel = model;
      _cachedGeminiService = GeminiService(apiKey: key, modelId: model);
      return _cachedGeminiService!;
    }

    if (provider == 'deepseek') {
      final key = await getDeepseekApiKey();
      if (key.isEmpty) throw Exception('DeepSeek API Key 未設定');
      return DeepSeekService(apiKey: key);
    }

    if (provider == 'qwen') {
      final key = await getQwenApiKey();
      if (key.isEmpty) throw Exception('Qwen API Key 未設定');
      return QwenService(apiKey: key);
    }

    if (provider == 'openai_compatible') {
      final baseUrl = await getOaiCompatBaseUrl();
      final key = await getOaiCompatApiKey();
      if (baseUrl.isEmpty) throw Exception('API Base URL 未設定');
      if (key.isEmpty) throw Exception('API Key 未設定');
      return OpenAICompatibleService(apiKey: key, baseUrl: baseUrl);
    }

    // 默認 OpenRouter
    final apiKey = await getOpenRouterApiKey();
    if (apiKey.isEmpty) {
      throw Exception('OpenRouter API Key 未設定');
    }
    return OpenRouterService(apiKey: apiKey);
  }

  // ═══ 思考鏈 ═══
  static const String _keyThinkingChain = 'thinking_chain_enabled';

  static Future<void> saveThinkingChain(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyThinkingChain, v);
  }

  static Future<bool> getThinkingChain() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyThinkingChain) ?? false;
  }

  // ═══ 節省 Token ═══
  static const String _keyConciseMode = 'token_save_concise';
  static const String _keyFreeformMode = 'token_save_freeform';
  static const String _keyFreeformMaxLines = 'token_save_max_lines';

  static Future<void> saveConciseMode(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyConciseMode, v);
  }

  static Future<bool> getConciseMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyConciseMode) ?? false;
  }

  static Future<void> saveFreeformMode(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyFreeformMode, v);
  }

  static Future<bool> getFreeformMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyFreeformMode) ?? false;
  }

  static Future<void> saveFreeformMaxLines(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyFreeformMaxLines, v);
  }

  static Future<int> getFreeformMaxLines() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyFreeformMaxLines) ?? 8;
  }

  static Future<LocalModelService> _loadLocalModelService(String key) async {
    final service = LocalModelService(modelKey: key);
    final ok = await service.initialize();
    if (!ok) {
      await service.dispose();
      throw Exception('本地模型加載失敗');
    }
    return service;
  }

  static Future<void> _disposeCachedLocalModel() async {
    await _cachedLocalModelService?.dispose();
    _cachedLocalModelService = null;
    _cachedLocalModelFuture = null;
    _cachedLocalModelKey = null;
  }

  static Future<String> _modelForProvider(String provider) async {
    switch (provider) {
      case 'bedrock':
        return getAwsModelId();
      case 'gemini':
        return getGeminiModel();
      case 'deepseek':
        return getDeepseekModel();
      case 'qwen':
        return getQwenModel();
      case 'openai_compatible':
        return getOaiCompatModel();
      case 'local_api':
        final model = await getLocalApiModel();
        return model.isEmpty ? '' : toLocalApiModelId(model);
      default:
        final p = await SharedPreferences.getInstance();
        return p.getString(_keyModel) ?? 'anthropic/claude-sonnet-4-20250514';
    }
  }
}
