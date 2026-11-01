/// Provider-neutral reasoning strength shared by settings, UI, and adapters.
abstract final class ReasoningEffort {
  /// Let the provider/model use its native default. No explicit reasoning
  /// strength is sent on the wire.
  static const String auto = 'auto';

  /// Source-compatibility alias. Persisted legacy `off` values are migrated to
  /// [auto] by [normalize] instead of continuing to promise that every model
  /// can actually disable reasoning.
  static const String off = auto;
  static const String low = 'low';
  static const String medium = 'medium';
  static const String high = 'high';

  static const Set<String> values = <String>{auto, low, medium, high};

  static String normalize(String? value, {String fallback = medium}) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized == 'off' || normalized == 'none' || normalized == 'default') {
      return auto;
    }
    if (values.contains(normalized)) return normalized;
    if (normalized == 'xhigh' || normalized == 'max') return high;
    return values.contains(fallback) ? fallback : medium;
  }

  static bool isEnabled(String? value) => normalize(value) != auto;
}
