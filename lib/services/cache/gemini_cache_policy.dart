/// Gemini direct API cache capability.
abstract final class GeminiCachePolicy {
  static bool matches({required String provider, required String model}) =>
      provider.trim().toLowerCase() == 'gemini' &&
      model.trim().toLowerCase().contains('gemini');

  /// Gemini 4 uses provider-managed implicit caching and rejects the
  /// `cachedContents` explicit-cache API.
  static bool usesImplicitCaching(String model) {
    final normalized = _normalizeModel(model);
    return normalized == 'gemini-4-argon' || normalized.startsWith('gemini-4-');
  }

  static bool supportsExplicitCaching(String model) =>
      !usesImplicitCaching(model);

  static String _normalizeModel(String model) {
    final normalized = model.trim().toLowerCase();
    if (!normalized.contains('/')) return normalized;
    return normalized.split('/').last;
  }

  static const Duration ttl = Duration(hours: 1);
}
