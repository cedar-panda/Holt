/// Anthropic prompt-cache capability detection.
///
/// Keep this class declarative: the established Claude transport and rolling
/// breakpoints remain in their provider adapters. This policy only answers
/// whether a selected route/model belongs to that existing implementation.
abstract final class ClaudeCachePolicy {
  static const Set<String> _providers = <String>{
    'openrouter',
    'openai_compatible',
    'bedrock',
    'aws_bedrock',
    'anthropic',
    'claude',
  };

  static const List<String> _familyKeywords = <String>[
    'claude',
    'anthropic',
    'opus',
    'sonnet',
    'haiku',
    'fable',
    'mythos',
  ];

  static bool isFamilyModel(String model) {
    final normalized = model.trim().toLowerCase();
    return normalized.isNotEmpty && _familyKeywords.any(normalized.contains);
  }

  static bool supportsRoute(String provider) =>
      _providers.contains(provider.trim().toLowerCase());

  static bool matches({required String provider, required String model}) =>
      supportsRoute(provider) && isFamilyModel(model);

  static Map<String, String>? cacheControl({
    required String provider,
    required String model,
  }) {
    if (!matches(provider: provider, model: model)) return null;
    return const <String, String>{'type': 'ephemeral', 'ttl': '1h'};
  }
}
