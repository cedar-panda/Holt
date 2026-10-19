/// Resolves the locale id accepted by the device speech recognizer.
///
/// Apple and Android may expose the same language with different identifiers
/// (`zh_TW`, `zh-TW`, `zh-Hant-TW`, or `cmn-Hant-TW`). Always return the exact
/// id reported by the current device when one is available.
class SpeechLocaleResolver {
  const SpeechLocaleResolver._();

  static String resolve({
    required String configuredLocale,
    required Iterable<String> availableLocaleIds,
    required bool preferAppleStyle,
  }) {
    final available = availableLocaleIds
        .where((id) => id.trim().isNotEmpty)
        .toList(growable: false);
    final byNormalized = <String, String>{
      for (final id in available) _normalize(id): id,
    };

    final candidates = _candidates(
      configuredLocale,
      preferAppleStyle: preferAppleStyle,
    );
    for (final candidate in candidates) {
      final match = byNormalized[_normalize(candidate)];
      if (match != null) return match;
    }

    final target = _normalize(configuredLocale);
    if (target.startsWith('zh-') || target.startsWith('cmn-')) {
      final traditional = target.contains('tw') || target.contains('hant');
      final scriptOrRegion = traditional
          ? const ['tw', 'hant', 'hk']
          : const ['cn', 'hans', 'sg'];
      for (final id in available) {
        final normalized = _normalize(id);
        final isChinese =
            normalized.startsWith('zh-') || normalized.startsWith('cmn-');
        if (isChinese && scriptOrRegion.any(normalized.contains)) return id;
      }
    }

    final language = target.split('-').first;
    for (final id in available) {
      if (_normalize(id).split('-').first == language) return id;
    }

    // Android does not always report every network recognizer locale, while
    // Apple prefers the standard language-region form.
    return candidates.first;
  }

  static List<String> _candidates(
    String configuredLocale, {
    required bool preferAppleStyle,
  }) {
    final normalized = _normalize(configuredLocale);
    if (normalized == 'zh-tw') {
      return preferAppleStyle
          ? const ['zh-TW', 'zh-Hant-TW', 'cmn-Hant-TW']
          : const ['cmn-Hant-TW', 'zh-TW', 'zh-Hant-TW'];
    }
    if (normalized == 'zh-cn') {
      return preferAppleStyle
          ? const ['zh-CN', 'zh-Hans-CN', 'cmn-Hans-CN']
          : const ['cmn-Hans-CN', 'zh-CN', 'zh-Hans-CN'];
    }
    if (normalized == 'en-us') return const ['en-US'];
    return [configuredLocale.replaceAll('_', '-')];
  }

  static String _normalize(String value) =>
      value.trim().replaceAll('_', '-').toLowerCase();
}
