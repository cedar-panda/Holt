import 'deepseek_service.dart';
import 'gemini_service.dart';
import 'model_info.dart';
import 'openai_compatible_service.dart';
import 'openrouter_service.dart';
import 'xai_service.dart';

/// Provider-neutral model discovery used by the API settings screen.
///
/// Keeping dispatch here prevents a provider switch from accidentally reusing
/// another provider's key, endpoint, parser, or error label.
abstract final class ProviderModelCatalog {
  static const Set<String> remoteProviders = <String>{
    'openrouter',
    'xai',
    'gemini',
    'deepseek',
    'openai_compatible',
  };

  static bool supports(String provider) => remoteProviders.contains(provider);

  static String label(String provider) => switch (provider) {
    'openrouter' => 'OpenRouter',
    'xai' => 'xAI',
    'gemini' => 'Gemini',
    'deepseek' => 'DeepSeek',
    'openai_compatible' => 'OpenAI Compatible',
    _ => provider,
  };

  static String providerTag(String provider) => switch (provider) {
    'openai_compatible' => 'openai_compatible',
    'xai' => 'xai',
    'gemini' => 'gemini',
    'deepseek' => 'deepseek',
    _ => 'openrouter',
  };

  static bool looksUsableKey(String provider, String key) {
    final normalized = key.trim();
    return switch (provider) {
      'openrouter' => normalized.startsWith('sk-or-'),
      'gemini' || 'xai' || 'deepseek' => normalized.length >= 8,
      _ => false,
    };
  }

  static Future<List<ModelInfo>> fetch({
    required String provider,
    required String apiKey,
    String baseUrl = '',
  }) => switch (provider) {
    'openai_compatible' => OpenAICompatibleService.fetchModels(
      baseUrl: baseUrl,
      apiKey: apiKey,
    ),
    'xai' => XaiService.fetchModels(apiKey),
    'gemini' => GeminiService.fetchModels(apiKey),
    'deepseek' => DeepSeekService.fetchModels(apiKey),
    'openrouter' => OpenRouterService.fetchModels(apiKey),
    _ => Future<List<ModelInfo>>.error(
      UnsupportedError('Provider does not expose model discovery: $provider'),
    ),
  };

  /// Embedding discovery is intentionally separate from chat models. Only
  /// entries whose id/name contains "embedding" are exposed to the picker.
  static Future<List<ModelInfo>> fetchEmbeddingModels({
    required String provider,
    required String apiKey,
    String baseUrl = '',
  }) async {
    final discovered = switch (provider) {
      'openrouter' => await OpenRouterService.fetchEmbeddingModels(apiKey),
      'gemini' => await GeminiService.fetchEmbeddingModels(apiKey),
      _ => await fetch(provider: provider, apiKey: apiKey, baseUrl: baseUrl),
    };
    return discovered
        .where((model) {
          final searchable = '${model.id} ${model.name}'.toLowerCase();
          return searchable.contains('embedding');
        })
        .toList(growable: false);
  }
}
