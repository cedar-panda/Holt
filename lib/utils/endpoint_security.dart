/// Validation for user-configured API endpoints.
///
/// Public endpoints must use HTTPS. Plain HTTP remains available for loopback,
/// private-network addresses, and mDNS `.local` hosts used by local model
/// servers such as LM Studio.
class EndpointSecurity {
  static Uri parseAndValidate(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Base URL 無效');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw const FormatException('Base URL 只支援 HTTPS 或 HTTP');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('Base URL 不可包含帳號或密碼');
    }
    if (scheme == 'http' && !_isLocalOrPrivateHost(uri.host)) {
      throw const FormatException(
        '公網 API 必須使用 HTTPS；HTTP 僅限 localhost 或區域網路服務',
      );
    }
    return uri;
  }

  static bool _isLocalOrPrivateHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' ||
        normalized.endsWith('.localhost') ||
        normalized.endsWith('.local')) {
      return true;
    }

    final ipv4 = _parseIpv4(normalized);
    if (ipv4 != null) {
      final first = ipv4[0];
      final second = ipv4[1];
      return first == 10 ||
          first == 127 ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168);
    }

    if (!normalized.contains(':')) return false;
    if (normalized == '::1') return true;
    if (normalized.startsWith('fc') || normalized.startsWith('fd')) {
      return true;
    }
    if (normalized.startsWith('fe8') ||
        normalized.startsWith('fe9') ||
        normalized.startsWith('fea') ||
        normalized.startsWith('feb')) {
      return true;
    }
    const mappedPrefix = '::ffff:';
    if (normalized.startsWith(mappedPrefix)) {
      return _isLocalOrPrivateHost(normalized.substring(mappedPrefix.length));
    }
    return false;
  }

  static List<int>? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final values = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
        return null;
      }
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      values.add(value);
    }
    return values;
  }
}
