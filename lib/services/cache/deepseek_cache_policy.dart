/// DeepSeek's direct API cache is automatic prefix matching. It exposes no
/// controllable one-hour retention parameter, so Holt only preserves a stable
/// prefix and reads the provider's hit/miss usage fields.
abstract final class DeepSeekCachePolicy {
  static bool isDirectProvider(String provider) =>
      provider.trim().toLowerCase() == 'deepseek';
}
