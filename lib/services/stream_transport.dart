import 'dart:async';

import 'locale_strings.dart';

/// The server may need substantial time to ingest a long conversation before
/// it can return HTTP response headers. This is separate from an SSE stream
/// that has already started and then stalls between chunks.
class ResponseStartTimeoutException implements Exception {
  final String provider;
  final Duration timeout;

  const ResponseStartTimeoutException({
    required this.provider,
    required this.timeout,
  });

  @override
  String toString() => L.pick(
    en:
        '$provider took more than ${timeout.inSeconds} seconds to start '
        'responding. Long conversations can take longer; please retry or '
        'send less context.',
    zhTW:
        '$provider 等待開始回覆超過 ${timeout.inSeconds} 秒。'
        '長對話可能需要較久，請重試或減少本次發送的上下文。',
  );
}

class StreamTransport {
  /// Header/first-response deadline. The old 30-second limit was shorter than
  /// normal server-side prompt ingestion for some long Claude/Inkling windows.
  static const Duration responseStartTimeout = Duration(minutes: 3);

  static Future<T> waitForResponseStart<T>(
    Future<T> response, {
    required String provider,
    Duration timeout = responseStartTimeout,
  }) async {
    try {
      return await response.timeout(timeout);
    } on TimeoutException {
      throw ResponseStartTimeoutException(provider: provider, timeout: timeout);
    }
  }
}
