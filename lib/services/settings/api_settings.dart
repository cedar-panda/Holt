import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import '../secure_store.dart';
import '../api_adapter.dart';
import '../openrouter_service.dart';
import '../xai_service.dart';
import '../aws_bedrock_service.dart';
import '../gemini_service.dart';
import '../deepseek_service.dart';
import '../deepinfra_service.dart';
import '../qwen_service.dart';
import '../openai_compatible_service.dart';
import '../thinking_machines_service.dart';
import '../local_model_service.dart';
import '../locale_strings.dart';
import '../reasoning_effort.dart';
import 'memory_settings.dart';
import '../../models/context_mode.dart';

/// 使用者尚未完成 API 來源設定。這類錯誤應由 UI 引導設定，不能當成
/// 角色回覆寫入聊天紀錄。
class ApiConfigException implements Exception {
  const ApiConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一筆收藏模型的穩定身分。相同 [modelId] 可分別收藏於不同 [provider]。
class StarredModelEntry {
  final String provider;
  final String modelId;

  const StarredModelEntry({required this.provider, required this.modelId});

  String get identity => '$provider\u0000$modelId';

  Map<String, String> toJson() => <String, String>{
    'provider': provider,
    'model_id': modelId,
  };

  static StarredModelEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final provider = '${value['provider'] ?? ''}'.trim();
    final modelId = '${value['model_id'] ?? ''}'.trim();
    if (provider.isEmpty || modelId.isEmpty) return null;
    return StarredModelEntry(provider: provider, modelId: modelId);
  }
}

/// API 供應商配置（OpenRouter / xAI / Bedrock / Gemini / DeepSeek / DeepInfra / Qwen / OpenAI Compatible / Local API）
class ApiSettings {
  // ═══ 通用 ═══
  static const String _keyLegacyApiKey = 'api_key';
  static const String _keyOpenRouterApiKey = 'openrouter_api_key';
  static const String _keyModel = 'model';
  static const String _keySystemPrompt = 'system_prompt';
  static const String _keyRpSystemPrompt = 'system_prompt_rp_v1';
  static const String _keyApiProvider = 'api_provider';
  static const String _keyImageGenModel = 'image_gen_model';
  static const String _keyImageGenProvider = 'image_gen_provider';
  static const String _keyImageGenModels = 'image_gen_models_v1';
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

  /// 畫圖來源。與主聊天來源分開保存，讓任何聊天模型都能調用同一個畫圖能力。
  static Future<void> saveImageGenProvider(String provider) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyImageGenProvider, provider.trim());
  }

  static Future<String> getImageGenProvider() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keyImageGenProvider)?.trim() ?? '';
    return saved.isEmpty ? 'openrouter' : saved;
  }

  /// 每個畫圖來源各自保存模型，切換來源時不覆蓋另一來源的選擇。
  /// 舊版 OpenRouter 單值會在首次讀取時自然遷移。
  static Future<void> saveImageGenModel(
    String model, {
    String? provider,
  }) async {
    final normalized = model.trim();
    if (normalized.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final source = provider?.trim().isNotEmpty == true
        ? provider!.trim()
        : await getImageGenProvider();
    final models = _decodeImageGenModels(p.getString(_keyImageGenModels));
    models[source] = normalized;
    await p.setString(_keyImageGenModels, jsonEncode(models));
    if (source == 'openrouter') {
      await p.setString(_keyImageGenModel, normalized);
    }
  }

  static Future<String> getImageGenModel({String? provider}) async {
    final p = await SharedPreferences.getInstance();
    final source = provider?.trim().isNotEmpty == true
        ? provider!.trim()
        : await getImageGenProvider();
    final models = _decodeImageGenModels(p.getString(_keyImageGenModels));
    final saved = models[source]?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    if (source == 'openrouter') {
      final legacy = p.getString(_keyImageGenModel)?.trim() ?? '';
      if (legacy.isNotEmpty) return legacy;
    }
    return switch (source) {
      'gemini' => 'gemini-3.1-flash-image',
      'xai' => 'grok-imagine-image-2.0',
      'qwen' => 'qwen-image-3.0-pro',
      'openai_compatible' || 'local_api' => 'gpt-image-1',
      _ => 'openai/gpt-5.4-image-2',
    };
  }

  static Map<String, String> _decodeImageGenModels(String? raw) {
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } catch (_) {
      return <String, String>{};
    }
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
      case 'deepinfra':
        await saveDeepInfraApiKey(key);
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
      case 'deepinfra':
        return getDeepInfraApiKey();
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

  /// 收藏模型快速切換前的輕量配置檢查。
  ///
  /// 這裡只判斷建立對應 adapter 所需的最低配置是否存在，不發送網路
  /// 請求，也不驗證憑證是否仍有效。如此可讓模型選單保留所有收藏，同時
  /// 避免點到尚未設定的來源後，把目前可用來源悄悄切走。
  static Future<bool> hasUsableProviderConfiguration(String provider) async {
    switch (provider) {
      case 'local':
        return true;
      case 'local_api':
        return (await getLocalApiBaseUrl()).trim().isNotEmpty;
      case 'openai_compatible':
        return (await getOaiCompatBaseUrl()).trim().isNotEmpty &&
            (await getOaiCompatApiKey()).trim().isNotEmpty;
      case 'bedrock':
        return (await getAwsAccessKeyId()).trim().isNotEmpty &&
            (await getAwsSecretAccessKey()).trim().isNotEmpty;
      case 'openrouter':
      case 'xai':
      case 'gemini':
      case 'deepseek':
      case 'deepinfra':
      case 'qwen':
      case 'thinking_machines':
        return (await getApiKeyForProvider(provider)).trim().isNotEmpty;
      default:
        return false;
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
    if (provider == 'deepinfra') {
      return p.getString(_keyDeepInfraModel) ?? DeepInfraService.defaultModel;
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
      case 'deepinfra':
        await saveDeepInfraModel(value);
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

  static Future<void> saveSystemPromptFor(
    ContextMode mode,
    String prompt,
  ) async {
    if (mode == ContextMode.daily) return saveSystemPrompt(prompt);
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyRpSystemPrompt, prompt);
  }

  static Future<String> getSystemPromptFor(ContextMode mode) async {
    if (mode == ContextMode.daily) return getSystemPrompt();
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyRpSystemPrompt) ?? '';
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

  // ═══ DeepInfra ═══
  static const String _keyDeepInfraApiKey = 'deepinfra_api_key';
  static const String _keyDeepInfraModel = 'deepinfra_model';

  static Future<void> saveDeepInfraApiKey(String value) async {
    await SecureStore.write(_keyDeepInfraApiKey, value);
  }

  static Future<String> getDeepInfraApiKey() async {
    return SecureStore.read(_keyDeepInfraApiKey);
  }

  static Future<void> saveDeepInfraModel(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyDeepInfraModel, normalized);
  }

  static Future<String> getDeepInfraModel() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_keyDeepInfraModel) ??
        DeepInfraService.defaultModel;
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
    final savedValue = supported.contains(normalized) ? normalized : 'high';
    await p.setString(_keyThinkingMachinesEffort, savedValue);

    // The provider-specific card may still expose `xhigh`, while the shared
    // window selector intentionally has four levels. Keep an already-enabled
    // global selector in sync without turning Thinking on when it is off.
    final sharedSaved = p.getString(_keyReasoningEffort);
    final sharedEnabled = sharedSaved != null
        ? ReasoningEffort.isEnabled(sharedSaved)
        : (p.getBool(_keyThinkingChain) ?? false);
    if (sharedEnabled) {
      await p.setString(
        _keyReasoningEffort,
        ReasoningEffort.normalize(savedValue),
      );
      await p.setBool(_keyThinkingChain, true);
    }
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
  static const String _keyOaiCompatDeveloperRole =
      'oai_compat_capability_developer_role';
  static const String _keyOaiCompatMidSystem =
      'oai_compat_capability_mid_system';
  static const String _keyOaiCompatCacheControl =
      'oai_compat_capability_cache_control';
  static const String _keyOaiCompatTools = 'oai_compat_capability_tools';

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

  static Future<void> saveOaiCompatCapabilities(
    OpenAICompatibleCapabilities value,
  ) async {
    final p = await SharedPreferences.getInstance();
    await Future.wait(<Future<bool>>[
      p.setBool(_keyOaiCompatDeveloperRole, value.supportsDeveloperRole),
      p.setBool(_keyOaiCompatMidSystem, value.supportsMidConversationSystem),
      p.setBool(_keyOaiCompatCacheControl, value.supportsCacheControl),
      p.setBool(_keyOaiCompatTools, value.supportsTools),
    ]);
  }

  static Future<OpenAICompatibleCapabilities> getOaiCompatCapabilities() async {
    final p = await SharedPreferences.getInstance();
    return OpenAICompatibleCapabilities(
      supportsDeveloperRole: p.getBool(_keyOaiCompatDeveloperRole) ?? false,
      supportsMidConversationSystem: p.getBool(_keyOaiCompatMidSystem) ?? true,
      supportsCacheControl: p.getBool(_keyOaiCompatCacheControl) ?? true,
      supportsTools: p.getBool(_keyOaiCompatTools) ?? false,
    );
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
  static const String _keyStarredModelEntries = 'starred_model_entries_v2';
  static const String _keyStarredModelUsage = 'starred_model_usage_v1';
  static const String _keyStarredModelManualOrder =
      'starred_model_manual_order_v1';

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

  /// 只計算仍在收藏中的來源＋模型。取消收藏後計數休眠但不刪除，
  /// 重新收藏即可延續原本的常用度排序。
  static Future<void> recordStarredModelUsage(
    String modelId, {
    String? provider,
  }) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return;
    final resolvedProvider = (provider ?? '').trim().isNotEmpty
        ? provider!.trim()
        : await resolveStarredModelProvider(normalized);
    final identity = StarredModelEntry(
      provider: resolvedProvider,
      modelId: normalized,
    ).identity;
    final starred = await getStarredModelEntries();
    if (!starred.any((entry) => entry.identity == identity)) return;
    final p = await SharedPreferences.getInstance();
    final counts = await getStarredModelUsageCounts();
    counts[identity] = (counts[identity] ?? counts[normalized] ?? 0) + 1;
    await p.setString(_keyStarredModelUsage, jsonEncode(counts));
  }

  /// 雲端模型優先、本地模型置底；每組內按完成聊天輪數由高到低。
  /// 同次數時維持原收藏順序，避免每次打開列表跳動。
  static Future<List<StarredModelEntry>> getRankedStarredModelEntries() async {
    final saved = await getStarredModelEntries();
    final starred = Platform.isIOS
        ? saved
              .where(
                (entry) =>
                    entry.provider != 'local' &&
                    !LocalModelService.isLocalModelId(entry.modelId),
              )
              .toList()
        : saved;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_keyStarredModelManualOrder) == true) {
      return starred;
    }
    final counts = await getStarredModelUsageCounts();
    final originalOrder = <String, int>{
      for (var i = 0; i < starred.length; i++) starred[i].identity: i,
    };
    bool isLocal(StarredModelEntry entry) =>
        entry.provider == 'local' ||
        entry.provider == 'local_api' ||
        LocalModelService.isLocalModelId(entry.modelId) ||
        isLocalApiModelId(entry.modelId);

    return [...starred]..sort((a, b) {
      final localOrder = (isLocal(a) ? 1 : 0).compareTo(isLocal(b) ? 1 : 0);
      if (localOrder != 0) return localOrder;
      final usageA = counts[a.identity] ?? counts[a.modelId] ?? 0;
      final usageB = counts[b.identity] ?? counts[b.modelId] ?? 0;
      final usageOrder = usageB.compareTo(usageA);
      if (usageOrder != 0) return usageOrder;
      return (originalOrder[a.identity] ?? 0).compareTo(
        originalOrder[b.identity] ?? 0,
      );
    });
  }

  /// 舊呼叫端只需要模型 ID；相同 ID 的不同來源在這個兼容視圖中合併。
  static Future<List<String>> getRankedStarredModels() async {
    final entries = await getRankedStarredModelEntries();
    final seen = <String>{};
    return <String>[
      for (final entry in entries)
        if (seen.add(entry.modelId)) entry.modelId,
    ];
  }

  static Future<List<StarredModelEntry>> getStarredModelEntries() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_keyStarredModelEntries);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final entries = <StarredModelEntry>[];
          final seen = <String>{};
          for (final value in decoded) {
            final entry = StarredModelEntry.fromJson(value);
            if (entry != null && seen.add(entry.identity)) entries.add(entry);
          }
          return entries;
        }
      } catch (_) {
        // 解析失敗時從舊欄位重建，避免整份收藏消失。
      }
    }
    return _migrateLegacyStarredModelEntries(preferences);
  }

  static Future<List<StarredModelEntry>> _migrateLegacyStarredModelEntries(
    SharedPreferences preferences,
  ) async {
    final models = preferences.getStringList(_keyStarredModels) ?? <String>[];
    final providers = await getStarredModelProviders();
    final currentProvider = await getApiProvider();
    final currentModel = await getModelForProvider(currentProvider);
    final hasCustomRelay = (await getOaiCompatBaseUrl()).trim().isNotEmpty;
    final entries = <StarredModelEntry>[];
    final seen = <String>{};
    for (final rawModel in models) {
      final modelId = rawModel.trim();
      if (modelId.isEmpty) continue;
      final savedProvider = (providers[modelId] ?? '').trim();
      final provider = savedProvider.isNotEmpty
          ? savedProvider
          : isLocalApiModelId(modelId)
          ? 'local_api'
          : LocalModelService.isLocalModelId(modelId)
          ? 'local'
          : isThinkingMachinesModelId(modelId)
          ? 'thinking_machines'
          : currentModel == modelId
          ? currentProvider
          : modelId.contains('/')
          ? 'openrouter'
          : hasCustomRelay
          ? 'openai_compatible'
          : currentProvider;
      final entry = StarredModelEntry(provider: provider, modelId: modelId);
      if (seen.add(entry.identity)) entries.add(entry);
    }
    await _writeStarredModelEntries(entries, preferences: preferences);
    return entries;
  }

  static Future<void> _writeStarredModelEntries(
    Iterable<StarredModelEntry> values, {
    SharedPreferences? preferences,
  }) async {
    final entries = <StarredModelEntry>[];
    final seen = <String>{};
    for (final value in values) {
      final provider = value.provider.trim();
      final modelId = value.modelId.trim();
      if (provider.isEmpty || modelId.isEmpty) continue;
      final entry = StarredModelEntry(provider: provider, modelId: modelId);
      if (seen.add(entry.identity)) entries.add(entry);
    }
    final p = preferences ?? await SharedPreferences.getInstance();
    await p.setString(
      _keyStarredModelEntries,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );

    // 同步舊欄位，讓尚未來源化的邊緣功能仍能讀取不重複的模型清單。
    final legacyModels = <String>[];
    final legacyProviders = <String, String>{};
    for (final entry in entries) {
      if (!legacyModels.contains(entry.modelId)) {
        legacyModels.add(entry.modelId);
      }
      legacyProviders.putIfAbsent(entry.modelId, () => entry.provider);
    }
    await p.setStringList(_keyStarredModels, legacyModels);
    await p.setString(_keyStarredModelProviders, jsonEncode(legacyProviders));
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
    final normalized = modelId.trim();
    for (final entry in await getStarredModelEntries()) {
      if (entry.modelId == normalized) return entry.provider;
    }
    return null;
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
    final entries = await getStarredModelEntries();
    var changed = false;
    for (final rawModelId in modelIds) {
      final modelId = rawModelId.trim();
      final matchingIndexes = <int>[
        for (var i = 0; i < entries.length; i++)
          if (entries[i].modelId == modelId) i,
      ];
      if (matchingIndexes.isEmpty ||
          matchingIndexes.any((index) => entries[index].provider == provider)) {
        continue;
      }
      if (matchingIndexes.length == 1) {
        entries[matchingIndexes.single] = StarredModelEntry(
          provider: provider,
          modelId: modelId,
        );
        changed = true;
      }
    }
    if (!changed) return;
    await _writeStarredModelEntries(entries);
  }

  static Future<void> saveStarredModels(List<String> models) async {
    final normalizedModels = <String>[];
    final seenModels = <String>{};
    for (final model in models) {
      final value = model.trim();
      if (value.isNotEmpty && seenModels.add(value)) {
        normalizedModels.add(value);
      }
    }
    final existing = await getStarredModelEntries();
    final byModel = <String, List<StarredModelEntry>>{};
    for (final entry in existing) {
      byModel
          .putIfAbsent(entry.modelId, () => <StarredModelEntry>[])
          .add(entry);
    }
    final entries = <StarredModelEntry>[];
    for (final modelId in normalizedModels) {
      final retained = byModel[modelId];
      if (retained != null && retained.isNotEmpty) {
        entries.addAll(retained);
        continue;
      }
      final provider = isLocalApiModelId(modelId)
          ? 'local_api'
          : LocalModelService.isLocalModelId(modelId)
          ? 'local'
          : isThinkingMachinesModelId(modelId)
          ? 'thinking_machines'
          : await resolveStarredModelProvider(modelId);
      entries.add(StarredModelEntry(provider: provider, modelId: modelId));
    }
    await _writeStarredModelEntries(entries);
  }

  /// 使用者在收藏模型管理窗手動排定的順序。手動排序後，聊天模型選擇框
  /// 會忠實採用這個順序，不再被完成輪數的自動排名覆蓋。
  static Future<void> saveStarredModelOrder(List<String> models) async {
    final normalized = <String>[];
    final seen = <String>{};
    for (final model in models) {
      final value = model.trim();
      if (value.isNotEmpty && seen.add(value)) normalized.add(value);
    }
    await saveStarredModels(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_keyStarredModelManualOrder, true);
  }

  static Future<void> saveStarredModelEntryOrder(
    List<StarredModelEntry> entries,
  ) async {
    await _writeStarredModelEntries(entries);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_keyStarredModelManualOrder, true);
  }

  static Future<List<String>> getStarredModels() async {
    final entries = await getStarredModelEntries();
    final seen = <String>{};
    return <String>[
      for (final entry in entries)
        if (seen.add(entry.modelId)) entry.modelId,
    ];
  }

  static Future<bool> isStarredModel(String modelId, String provider) async {
    final identity = StarredModelEntry(
      provider: provider.trim(),
      modelId: modelId.trim(),
    ).identity;
    return (await getStarredModelEntries()).any(
      (entry) => entry.identity == identity,
    );
  }

  static Future<void> toggleStarModel(
    String modelId, {
    String? provider,
  }) async {
    final normalizedModel = modelId.trim();
    if (normalizedModel.isEmpty) return;
    final normalizedProvider = (provider ?? '').trim().isNotEmpty
        ? provider!.trim()
        : await resolveStarredModelProvider(normalizedModel);
    final entries = await getStarredModelEntries();
    final identity = StarredModelEntry(
      provider: normalizedProvider,
      modelId: normalizedModel,
    ).identity;
    final index = entries.indexWhere((entry) => entry.identity == identity);
    if (index >= 0) {
      entries.removeAt(index);
    } else {
      entries.add(
        StarredModelEntry(
          provider: normalizedProvider,
          modelId: normalizedModel,
        ),
      );
    }
    await _writeStarredModelEntries(entries);
  }

  // ═══ 工廠方法 ═══

  static Future<ApiAdapter> buildAdapter({
    String? overrideModel,
    String? overrideProvider,
    bool? thinkingEnabledOverride,
    String? reasoningEffortOverride,
    String? conversationId,
  }) async {
    final provider = overrideProvider ?? await getApiProvider();
    final reasoningEffort = reasoningEffortOverride != null
        ? ReasoningEffort.normalize(reasoningEffortOverride)
        : await getReasoningEffort(conversationId: conversationId);
    final thinkingEnabled =
        thinkingEnabledOverride ??
        await getThinkingChain(conversationId: conversationId);
    // 如果指定了本地模型，直接返回 LocalModelService
    final modelId = overrideModel ?? await _modelForProvider(provider);
    if (LocalModelService.isLocalModelId(modelId)) {
      if (Platform.isIOS) {
        throw ApiConfigException(
          L.pick(
            en: 'On-device models are unavailable on iOS. Select an API model.',
            zhTW: 'iOS 不提供本機模型，請選擇 API 模型。',
            zhCN: 'iOS 不提供本地模型，请选择 API 模型。',
          ),
        );
      }
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
      // Utility requests such as character signatures must not mutate the
      // shared chat adapter's Thinking state while a chat request is active.
      if (thinkingEnabledOverride != null || reasoningEffortOverride != null) {
        return GeminiService(
          apiKey: key,
          modelId: model,
          thinkingEnabled: thinkingEnabled,
          reasoningEffort: reasoningEffort,
        );
      }
      final cached = _cachedGeminiService;
      if (_cachedGeminiKey == key &&
          _cachedGeminiModel == model &&
          cached != null) {
        cached.thinkingEnabled = thinkingEnabled;
        cached.reasoningEffort = reasoningEffort;
        return cached;
      }
      _cachedGeminiKey = key;
      _cachedGeminiModel = model;
      _cachedGeminiService = GeminiService(
        apiKey: key,
        modelId: model,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
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

    if (provider == 'deepinfra') {
      final key = await getDeepInfraApiKey();
      if (key.isEmpty) {
        throw ApiConfigException(
          L.pick(
            en: 'DeepInfra API Key is not configured',
            zhTW: 'DeepInfra API Key 未設定',
            zhCN: 'DeepInfra API Key 未设置',
          ),
        );
      }
      return DeepInfraService(
        apiKey: key,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
      );
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
        thinkingEffort: reasoningEffort,
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
        capabilities: await getOaiCompatCapabilities(),
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
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
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
  static const String _keyReasoningEffort = 'reasoning_effort_v1';
  static const String _keyConversationReasoningEfforts =
      'conversation_reasoning_efforts_v1';
  static const String _keyConversationThinkingEnabled =
      'conversation_thinking_enabled_v1';
  static const String _keyThinkingRequestStates = 'thinking_request_states_v1';

  static Future<void> saveThinkingChain(bool v) async {
    final p = await SharedPreferences.getInstance();
    if (v && !p.containsKey(_keyReasoningEffort)) {
      await p.setString(_keyReasoningEffort, ReasoningEffort.medium);
    }
    await setThinkingChain(v);
  }

  static Future<bool> getThinkingChain({String? conversationId}) async {
    final p = await SharedPreferences.getInstance();
    final scope = (conversationId ?? '').trim();
    if (scope.isNotEmpty) {
      final raw = p.getString(_keyConversationThinkingEnabled);
      if (raw != null) {
        try {
          final values = jsonDecode(raw);
          if (values is Map && values[scope] is bool) {
            return values[scope] as bool;
          }
        } catch (_) {
          // Ignore a damaged optional window override.
        }
      }
      // Older windows inferred the switch from their strength choice.
      final oldRaw = p.getString(_keyConversationReasoningEfforts);
      if (oldRaw != null) {
        try {
          final values = jsonDecode(oldRaw);
          if (values is Map && values[scope] is String) {
            return ReasoningEffort.isEnabled(values[scope] as String);
          }
        } catch (_) {}
      }
    }
    if (p.containsKey(_keyThinkingChain)) {
      return p.getBool(_keyThinkingChain) ?? false;
    }
    final legacyEffort = p.getString(_keyReasoningEffort);
    return legacyEffort != null && ReasoningEffort.isEnabled(legacyEffort);
  }

  static Future<void> setThinkingChain(
    bool enabled, {
    String? conversationId,
  }) async {
    final p = await SharedPreferences.getInstance();
    final scope = (conversationId ?? '').trim();
    if (scope.isEmpty) {
      await p.setBool(_keyThinkingChain, enabled);
      return;
    }
    final values = <String, bool>{};
    try {
      final decoded = jsonDecode(
        p.getString(_keyConversationThinkingEnabled) ?? '{}',
      );
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is bool) {
            values[entry.key as String] = entry.value as bool;
          }
        }
      }
    } catch (_) {}
    values[scope] = enabled;
    await p.setString(_keyConversationThinkingEnabled, jsonEncode(values));
  }

  static Future<String> getReasoningEffort({String? conversationId}) async {
    final p = await SharedPreferences.getInstance();
    final scope = (conversationId ?? '').trim();
    if (scope.isNotEmpty) {
      final raw = p.getString(_keyConversationReasoningEfforts);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded[scope] is String) {
            return ReasoningEffort.normalize(decoded[scope] as String);
          }
        } catch (_) {
          // A damaged optional override must fall back to the global setting.
        }
      }
    }

    final saved = p.getString(_keyReasoningEffort);
    if (saved != null && saved.trim().isNotEmpty) {
      return ReasoningEffort.normalize(saved);
    }

    final legacyEnabled = p.getBool(_keyThinkingChain) ?? false;
    if (!legacyEnabled) return ReasoningEffort.off;
    if (p.containsKey(_keyThinkingMachinesEffort)) {
      return ReasoningEffort.normalize(p.getString(_keyThinkingMachinesEffort));
    }
    return ReasoningEffort.medium;
  }

  static Future<void> setReasoningEffort(
    String effort, {
    String? conversationId,
  }) async {
    final normalized = ReasoningEffort.normalize(effort);
    final p = await SharedPreferences.getInstance();
    final scope = (conversationId ?? '').trim();
    // Migrate the old strength-derived switch before changing strength.
    final wasEnabled = await getThinkingChain(conversationId: conversationId);
    if (scope.isNotEmpty) {
      await setThinkingChain(wasEnabled, conversationId: scope);
    } else if (!p.containsKey(_keyThinkingChain)) {
      await setThinkingChain(wasEnabled);
    }
    if (scope.isNotEmpty) {
      final values = <String, String>{};
      final raw = p.getString(_keyConversationReasoningEfforts);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final key = entry.key.toString().trim();
              final value = entry.value?.toString() ?? '';
              if (key.isNotEmpty) {
                values[key] = ReasoningEffort.normalize(value);
              }
            }
          }
        } catch (_) {
          // Replace a damaged optional map with the current valid override.
        }
      }
      values[scope] = normalized;
      await p.setString(_keyConversationReasoningEfforts, jsonEncode(values));
    } else {
      await p.setString(_keyReasoningEffort, normalized);
    }

    // Keep the dedicated Thinking Machines settings card aligned with the
    // latest non-off shared strength. `off` remains represented by its bool.
    if (normalized != ReasoningEffort.off) {
      await p.setString(_keyThinkingMachinesEffort, normalized);
    }
  }

  static String _thinkingRequestIdentity({
    required String conversationId,
    required String provider,
    required String model,
    required String cacheChannel,
  }) => jsonEncode(<String>[
    conversationId.trim(),
    provider.trim().toLowerCase(),
    model.trim(),
    cacheChannel.trim().toLowerCase(),
  ]);

  /// The Thinking value committed by the latest dispatched request for one concrete
  /// cache identity. Merely toggling the UI never writes this state.
  static Future<bool?> getLastSentThinkingState({
    required String conversationId,
    required String provider,
    required String model,
    required String cacheChannel,
  }) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keyThinkingRequestStates);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final identity = _thinkingRequestIdentity(
        conversationId: conversationId,
        provider: provider,
        model: model,
        cacheChannel: cacheChannel,
      );
      final entry = decoded[identity];
      if (entry is Map && entry['enabled'] is bool) {
        return entry['enabled'] as bool;
      }
    } catch (_) {
      // Corrupt diagnostic state must never block model selection.
    }
    return null;
  }

  /// Records only a value committed when a request is dispatched.
  /// Entries are bounded because model/provider changes create new identities.
  static Future<void> recordSentThinkingState({
    required String conversationId,
    required String provider,
    required String model,
    required String cacheChannel,
    required bool enabled,
  }) async {
    final p = await SharedPreferences.getInstance();
    final states = <String, dynamic>{};
    final raw = p.getString(_keyThinkingRequestStates);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            states[entry.key.toString()] = entry.value;
          }
        }
      } catch (_) {
        // Replace corrupt non-essential state with a clean bounded map.
      }
    }
    final identity = _thinkingRequestIdentity(
      conversationId: conversationId,
      provider: provider,
      model: model,
      cacheChannel: cacheChannel,
    );
    states[identity] = <String, Object>{
      'enabled': enabled,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (states.length > 160) {
      final ordered = states.entries.toList()
        ..sort((left, right) {
          String timestamp(MapEntry<String, dynamic> entry) {
            final value = entry.value;
            return value is Map ? '${value['updated_at'] ?? ''}' : '';
          }

          return timestamp(right).compareTo(timestamp(left));
        });
      states
        ..clear()
        ..addEntries(ordered.take(160));
    }
    await p.setString(_keyThinkingRequestStates, jsonEncode(states));
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
      case 'deepinfra':
        return getDeepInfraModel();
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
