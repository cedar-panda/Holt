import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../secure_store.dart';
import '../api_adapter.dart';
import '../openrouter_service.dart';
import '../xai_service.dart';
import '../aws_bedrock_service.dart';
import '../gemini_service.dart';
import '../deepseek_service.dart';
import '../qwen_service.dart';
import '../openai_compatible_service.dart';
import '../thinking_machines_service.dart';
import '../local_model_service.dart';
import '../locale_strings.dart';
import 'memory_settings.dart';

/// 使用者尚未完成 API 來源設定。這類錯誤應由 UI 引導設定，不能當成
/// 角色回覆寫入聊天紀錄。
class ApiConfigException implements Exception {
  const ApiConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// API 供應商配置（OpenRouter / xAI / Bedrock / Gemini / DeepSeek / Qwen / OpenAI Compatible / Local API）
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
      case 'xai':
        await saveXaiApiKey(key);
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
      case 'thinking_machines':
        await saveThinkingMachinesApiKey(key);
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
      case 'xai':
        return getXaiApiKey();
      case 'gemini':
        return getGeminiApiKey();
      case 'deepseek':
        return getDeepseekApiKey();
      case 'qwen':
        return getQwenApiKey();
      case 'thinking_machines':
        return getThinkingMachinesApiKey();
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
    if (provider == 'local') {
      return p.getString(_keyModel) ?? '';
    }
    if (provider == 'openai_compatible') {
      return p.getString(_keyOaiCompatModel) ?? '';
    }
    if (provider == 'gemini') {
      return p.getString(_keyGeminiModel) ?? 'gemini-2.5-flash';
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
    if (provider == 'thinking_machines') {
      return p.getString(_keyThinkingMachinesModel) ??
          ThinkingMachinesService.defaultModel;
    }
    if (provider == 'xai') {
      return p.getString(_keyXaiModel) ?? XaiService.defaultModel;
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
      case 'thinking_machines':
        await saveThinkingMachinesModel(value);
        break;
      case 'xai':
        await saveXaiModel(value);
        break;
      case 'openai_compatible':
        await saveOaiCompatModel(value);
        break;
      case 'local_api':
        await saveLocalApiModel(value);
        break;
      case 'local':
      case 'openrouter':
        await saveModel(value);
        break;
      default:
        throw UnsupportedError('不支援的 API 來源：$provider');
    }
  }

  /// 將「來源＋模型」視為同一次選擇保存，避免快速切換時只改到其中一項。
  static Future<void> saveProviderModelSelection(
    String provider,
    String model,
  ) async {
    await saveModelForProvider(provider, model);
    await saveApiProvider(provider);
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
    return p.getString(_keyGeminiModel) ?? 'gemini-2.5-flash';
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

  // ═══ xAI / Grok ═══
  static const String _keyXaiApiKey = 'xai_api_key';
  static const String _keyXaiModel = 'xai_model';

  static Future<void> saveXaiApiKey(String value) async {
    await SecureStore.write(_keyXaiApiKey, value);
  }

  static Future<String> getXaiApiKey() async {
    return SecureStore.read(_keyXaiApiKey);
  }

  static Future<void> saveXaiModel(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyXaiModel, normalized);
  }

  static Future<String> getXaiModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyXaiModel) ?? XaiService.defaultModel;
  }

  // ═══ Thinking Machines / Inkling ═══
  static const String _keyThinkingMachinesApiKey = 'thinking_machines_api_key';
  static const String _keyThinkingMachinesModel = 'thinking_machines_model';
  static const String _keyThinkingMachinesEffort =
      'thinking_machines_thinking_effort';

  static Future<void> saveThinkingMachinesApiKey(String value) async {
    await SecureStore.write(_keyThinkingMachinesApiKey, value);
  }

  static Future<String> getThinkingMachinesApiKey() async {
    return SecureStore.read(_keyThinkingMachinesApiKey);
  }

  static Future<void> saveThinkingMachinesModel(String value) async {
    final normalized = value.trim().isEmpty
        ? ThinkingMachinesService.defaultModel
        : value.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyThinkingMachinesModel, normalized);
  }

  static Future<String> getThinkingMachinesModel() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyThinkingMachinesModel)?.trim() ?? '';
    return saved.isEmpty ? ThinkingMachinesService.defaultModel : saved;
  }

  static Future<void> saveThinkingMachinesEffort(String value) async {
    const supported = <String>{'low', 'medium', 'high', 'xhigh'};
    final normalized = value.trim().toLowerCase();
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _keyThinkingMachinesEffort,
      supported.contains(normalized) ? normalized : 'high',
    );
  }

  static Future<String> getThinkingMachinesEffort() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyThinkingMachinesEffort) ?? 'high';
    const supported = <String>{'low', 'medium', 'high', 'xhigh'};
    return supported.contains(saved) ? saved : 'high';
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
  static const String _keyStarredModelProviders = 'starred_model_providers_v1';
  static const String _keyStarredModelUsage = 'starred_model_usage_v1';

  static Future<Map<String, int>> getStarredModelUsageCounts() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keyStarredModelUsage);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) {
        final count = value is num
            ? value.toInt()
            : int.tryParse('$value') ?? 0;
        return MapEntry('$key', count < 0 ? 0 : count);
      });
    } catch (_) {
      return {};
    }
  }

  /// 只計算仍在收藏中的模型。取消收藏後計數休眠但不刪除，
  /// 重新收藏即可延續原本的常用度排序。
  static Future<void> recordStarredModelUsage(String modelId) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final starred = p.getStringList(_keyStarredModels) ?? const <String>[];
    if (!starred.contains(normalized)) return;
    final counts = await getStarredModelUsageCounts();
    counts[normalized] = (counts[normalized] ?? 0) + 1;
    await p.setString(_keyStarredModelUsage, jsonEncode(counts));
  }

  /// 雲端模型優先、本地模型置底；每組內按完成聊天輪數由高到低。
  /// 同次數時維持原收藏順序，避免每次打開列表跳動。
  static Future<List<String>> getRankedStarredModels() async {
    final starred = await getStarredModels();
    final counts = await getStarredModelUsageCounts();
    final originalOrder = <String, int>{
      for (var i = 0; i < starred.length; i++) starred[i]: i,
    };
    bool isLocal(String modelId) =>
        LocalModelService.isLocalModelId(modelId) || isLocalApiModelId(modelId);

    return [...starred]..sort((a, b) {
      final localOrder = (isLocal(a) ? 1 : 0).compareTo(isLocal(b) ? 1 : 0);
      if (localOrder != 0) return localOrder;
      final usageOrder = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
      if (usageOrder != 0) return usageOrder;
      return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
    });
  }

  static Future<Map<String, String>> getStarredModelProviders() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keyStarredModelProviders);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } catch (_) {
      return {};
    }
  }

  static Future<String?> getStarredModelProvider(String modelId) async {
    final providers = await getStarredModelProviders();
    return providers[modelId];
  }

  /// 兼容舊版只保存模型 ID、沒有保存來源的星標。
  static Future<String> resolveStarredModelProvider(String modelId) async {
    if (isLocalApiModelId(modelId)) return 'local_api';
    if (LocalModelService.isLocalModelId(modelId)) return 'local';
    if (isThinkingMachinesModelId(modelId)) {
      await rememberStarredModelProviders([modelId], 'thinking_machines');
      return 'thinking_machines';
    }

    final saved = await getStarredModelProvider(modelId);
    if (saved != null && saved.isNotEmpty) return saved;

    final currentProvider = await getApiProvider();
    final currentModel = await getModelForProvider(currentProvider);
    if (currentModel == modelId) {
      await rememberStarredModelProviders([modelId], currentProvider);
      return currentProvider;
    }

    // OpenRouter 的模型 ID 通常帶供應商前綴（例如 anthropic/...）；
    // New API / One API 中轉常直接使用模型名或帶 [渠道] 前綴。
    final inferred = modelId.contains('/')
        ? 'openrouter'
        : (await getOaiCompatBaseUrl()).isNotEmpty
        ? 'openai_compatible'
        : currentProvider;
    await rememberStarredModelProviders([modelId], inferred);
    return inferred;
  }

  /// Thinking Machines 模型永遠走自己的 provider，不能因模型 ID 含 `/`
  /// 被舊版星標推斷綁到 OpenRouter。
  static bool isThinkingMachinesModelId(String modelId) {
    final normalized = modelId.trim().toLowerCase();
    return normalized.startsWith('thinkingmachines/') ||
        normalized.startsWith('tinker://');
  }

  static Future<void> rememberStarredModelProviders(
    Iterable<String> modelIds,
    String provider,
  ) async {
    final starred = (await getStarredModels()).toSet();
    final providers = await getStarredModelProviders();
    var changed = false;
    for (final modelId in modelIds) {
      if (starred.contains(modelId) && providers[modelId] != provider) {
        providers[modelId] = provider;
        changed = true;
      }
    }
    if (!changed) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyStarredModelProviders, jsonEncode(providers));
  }

  static Future<void> saveStarredModels(List<String> models) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyStarredModels, models);
    final providers = await getStarredModelProviders();
    providers.removeWhere((modelId, _) => !models.contains(modelId));
    await p.setString(_keyStarredModelProviders, jsonEncode(providers));
  }

  static Future<List<String>> getStarredModels() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_keyStarredModels) ?? [];
  }

  static Future<void> toggleStarModel(
    String modelId, {
    String? provider,
  }) async {
    final list = await getStarredModels();
    final providers = await getStarredModelProviders();
    if (list.contains(modelId)) {
      list.remove(modelId);
      providers.remove(modelId);
    } else {
      list.add(modelId);
      if (provider != null && provider.isNotEmpty) {
        providers[modelId] = provider;
      }
    }
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyStarredModels, list);
    await p.setString(_keyStarredModelProviders, jsonEncode(providers));
  }

  // ═══ 工廠方法 ═══

  static Future<ApiAdapter> buildAdapter({
    String? overrideModel,
    String? overrideProvider,
  }) async {
    final provider = overrideProvider ?? await getApiProvider();
    final thinkingEnabled = await getThinkingChain();
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
      if (baseUrl.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'Local API Base URL is not configured',
            zhTW: '本地 API Base URL 未設定',
          ),
        );
      }
      return OpenAICompatibleService(
        apiKey: key,
        baseUrl: baseUrl,
        modelPrefixToStrip: localApiModelPrefix,
        thinkingEnabled: thinkingEnabled,
      );
    }

    await _disposeCachedLocalModel();

    if (provider == 'local_api') {
      final baseUrl = await getLocalApiBaseUrl();
      final key = await getLocalApiKey();
      if (baseUrl.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'Local API Base URL is not configured',
            zhTW: '本地 API Base URL 未設定',
          ),
        );
      }
      return OpenAICompatibleService(
        apiKey: key,
        baseUrl: baseUrl,
        modelPrefixToStrip: localApiModelPrefix,
        thinkingEnabled: thinkingEnabled,
      );
    }

    if (provider == 'bedrock') {
      final accessKeyId = await getAwsAccessKeyId();
      final secretAccessKey = await getAwsSecretAccessKey();
      final region = await getAwsRegion();
      final bedrockModelId = overrideModel ?? await getAwsModelId();
      if (accessKeyId.isEmpty || secretAccessKey.isEmpty) {
        throw ApiConfigException(
          L.pick(en: 'AWS credentials are not configured', zhTW: 'AWS 憑證未設定'),
        );
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
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'Gemini API Key is not configured',
            zhTW: 'Gemini API Key 未設定',
          ),
        );
      }
      final model = overrideModel ?? await getGeminiModel();
      final cached = _cachedGeminiService;
      if (_cachedGeminiKey == key &&
          _cachedGeminiModel == model &&
          cached != null) {
        cached.thinkingEnabled = thinkingEnabled;
        return cached;
      }
      _cachedGeminiKey = key;
      _cachedGeminiModel = model;
      _cachedGeminiService = GeminiService(
        apiKey: key,
        modelId: model,
        thinkingEnabled: thinkingEnabled,
      );
      return _cachedGeminiService!;
    }

    if (provider == 'deepseek') {
      final key = await getDeepseekApiKey();
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'DeepSeek API Key is not configured',
            zhTW: 'DeepSeek API Key 未設定',
          ),
        );
      }
      return DeepSeekService(apiKey: key, thinkingEnabled: thinkingEnabled);
    }

    if (provider == 'qwen') {
      final key = await getQwenApiKey();
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'Qwen API Key is not configured',
            zhTW: 'Qwen API Key 未設定',
          ),
        );
      }
      return QwenService(apiKey: key, thinkingEnabled: thinkingEnabled);
    }

    if (provider == 'thinking_machines') {
      final key = await getThinkingMachinesApiKey();
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'Thinking Machines API Key is not configured',
            zhTW: 'Thinking Machines API Key 未設定',
          ),
        );
      }
      return ThinkingMachinesService(
        apiKey: key,
        thinkingEnabled: thinkingEnabled,
        thinkingEffort: await getThinkingMachinesEffort(),
      );
    }

    if (provider == 'openai_compatible') {
      final baseUrl = await getOaiCompatBaseUrl();
      final key = await getOaiCompatApiKey();
      if (baseUrl.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'API Base URL is not configured',
            zhTW: 'API Base URL 未設定',
          ),
        );
      }
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(en: 'API Key is not configured', zhTW: 'API Key 未設定'),
        );
      }
      return OpenAICompatibleService(
        apiKey: key,
        baseUrl: baseUrl,
        thinkingEnabled: thinkingEnabled,
      );
    }

    if (provider == 'openrouter') {
      final apiKey = await getOpenRouterApiKey();
      if (apiKey.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'OpenRouter API Key is not configured',
            zhTW: 'OpenRouter API Key 未設定',
          ),
        );
      }
      return OpenRouterService(
        apiKey: apiKey,
        thinkingEnabled: await getThinkingChain(),
      );
    }

    if (provider == 'xai') {
      final apiKey = await getXaiApiKey();
      if (apiKey.isEmpty) {
        throw ApiConfigException(
          L.pick(en: 'xAI API Key is not configured', zhTW: 'xAI API Key 未設定'),
        );
      }
      return XaiService(apiKey: apiKey, thinkingEnabled: thinkingEnabled);
    }

    if (provider == 'local') {
      throw ApiConfigException(
        L.pick(en: 'No local model is configured', zhTW: '本地模型未設定'),
      );
    }
    throw UnsupportedError('不支援的 API 來源：$provider');
  }

  /// 工具模型（摘要、表情包視覺等）按星標保存的來源建立 adapter。
  /// 這能避免帶供應商前綴的 Inkling 被目前主 provider 或 OpenRouter 承載。
  static Future<ApiAdapter> buildAdapterForModel(String modelId) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return buildAdapter();
    final provider = await resolveStarredModelProvider(normalized);
    return buildAdapter(overrideModel: normalized, overrideProvider: provider);
  }

  /// 窗口摘要模型使用自己保存的「來源＋模型」；舊版只存模型名時才走
  /// 星標來源推斷。這條路徑不會因目前聊天 provider 改變而漂移。
  static Future<String> resolveSummaryModelProvider(String modelId) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return getApiProvider();
    final savedProvider = await MemorySettings.getSummaryProvider();
    if (savedProvider.isNotEmpty) return savedProvider;
    return resolveStarredModelProvider(normalized);
  }

  static Future<ApiAdapter> buildAdapterForSummaryModel(String modelId) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return buildAdapter();
    final provider = await resolveSummaryModelProvider(normalized);
    return buildAdapter(overrideModel: normalized, overrideProvider: provider);
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
      case 'thinking_machines':
        return getThinkingMachinesModel();
      case 'xai':
        return getXaiModel();
      case 'openai_compatible':
        return getOaiCompatModel();
      case 'local_api':
        final model = await getLocalApiModel();
        return model.isEmpty ? '' : toLocalApiModelId(model);
      case 'local':
      case 'openrouter':
        final p = await SharedPreferences.getInstance();
        return p.getString(_keyModel) ?? 'anthropic/claude-sonnet-4-20250514';
      default:
        throw UnsupportedError('不支援的 API 來源：$provider');
    }
  }
}
