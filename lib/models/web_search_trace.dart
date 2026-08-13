import 'dart:convert';

class WebSearchTraceSource {
  const WebSearchTraceSource({required this.title, required this.host});

  final String title;
  final String host;
}

class WebSearchTraceFailure {
  const WebSearchTraceFailure({
    required this.provider,
    required this.safeMessage,
    this.statusCode,
  });

  final String provider;
  final String safeMessage;
  final int? statusCode;
}

/// Privacy-minimized, display-only record persisted with an assistant message.
///
/// It deliberately excludes the outgoing query, provider answer text, source
/// URLs, token usage, attribution payloads, and credentials.
class WebSearchDisplayTrace {
  WebSearchDisplayTrace({
    required List<String> providers,
    required List<WebSearchTraceSource> sources,
    required List<WebSearchTraceFailure> failures,
  }) : providers = List<String>.unmodifiable(providers.take(2)),
       sources = List<WebSearchTraceSource>.unmodifiable(sources.take(5)),
       failures = List<WebSearchTraceFailure>.unmodifiable(failures.take(2));

  final List<String> providers;
  final List<WebSearchTraceSource> sources;
  final List<WebSearchTraceFailure> failures;

  String encode() => jsonEncode(<String, Object?>{
    'v': 1,
    'providers': providers,
    'sources': <Map<String, String>>[
      for (final source in sources)
        <String, String>{'title': source.title, 'host': source.host},
    ],
    'failures': <Map<String, Object?>>[
      for (final failure in failures)
        <String, Object?>{
          'provider': failure.provider,
          'message': failure.safeMessage,
          if (failure.statusCode != null) 'status': failure.statusCode,
        },
    ],
  });

  static WebSearchDisplayTrace? decode(String? raw) {
    if (raw == null || raw.isEmpty || raw.length > 16 * 1024) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) return null;

      final providers = <String>[];
      final rawProviders = decoded['providers'];
      if (rawProviders is List) {
        for (final value in rawProviders.take(2)) {
          final provider = _safeText(value, maxLength: 32);
          if (provider != null) providers.add(provider);
        }
      }

      final sources = <WebSearchTraceSource>[];
      final rawSources = decoded['sources'];
      if (rawSources is List) {
        for (final value in rawSources.take(5)) {
          if (value is! Map) continue;
          final title = _safeText(value['title'], maxLength: 180);
          final host = _safeHost(value['host']);
          if (title == null || host == null) continue;
          sources.add(WebSearchTraceSource(title: title, host: host));
        }
      }

      final failures = <WebSearchTraceFailure>[];
      final rawFailures = decoded['failures'];
      if (rawFailures is List) {
        for (final value in rawFailures.take(2)) {
          if (value is! Map) continue;
          final provider = _safeText(value['provider'], maxLength: 32);
          final message = _safeText(value['message'], maxLength: 320);
          final rawStatus = value['status'];
          final status =
              rawStatus is int && rawStatus >= 100 && rawStatus <= 599
              ? rawStatus
              : null;
          if (provider == null || message == null) continue;
          failures.add(
            WebSearchTraceFailure(
              provider: provider,
              safeMessage: message,
              statusCode: status,
            ),
          );
        }
      }

      if (providers.isEmpty && sources.isEmpty && failures.isEmpty) return null;
      return WebSearchDisplayTrace(
        providers: providers,
        sources: sources,
        failures: failures,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _safeText(Object? value, {required int maxLength}) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty || text.length > maxLength) return null;
    if (RegExp(r'[\u0000-\u001F\u007F]').hasMatch(text)) return null;
    return text;
  }

  static String? _safeHost(Object? value) {
    final host = _safeText(value, maxLength: 253)?.toLowerCase();
    if (host == null ||
        !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host)) {
      return null;
    }
    return host;
  }
}
