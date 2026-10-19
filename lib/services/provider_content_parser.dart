/// Normalizes provider message content into visible text.
///
/// OpenAI-compatible providers are allowed to return either a plain string
/// or a list of content blocks. Anthropic-style routers commonly use the
/// latter even when the request itself is OpenAI-shaped.
abstract final class ProviderContentParser {
  static String visibleText(Object? raw) {
    if (raw is String) return raw;
    if (raw is List) {
      return raw.map(visibleText).where((part) => part.isNotEmpty).join();
    }
    if (raw is Map) {
      final type = '${raw['type'] ?? ''}'.toLowerCase();
      if (_nonVisibleBlockTypes.contains(type)) return '';

      final text = raw['text'];
      if (text != null) return visibleText(text);
      final content = raw['content'];
      if (content != null) return visibleText(content);
      final value = raw['value'];
      if (value != null) return visibleText(value);
    }
    return '';
  }

  static const Set<String> _nonVisibleBlockTypes = <String>{
    'reasoning',
    'thinking',
    'redacted_reasoning',
    'tool_use',
    'tool_result',
  };
}
