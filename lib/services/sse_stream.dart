import 'dart:async';
import 'dart:convert';

class StreamStallException implements Exception {
  final Duration timeout;

  const StreamStallException(this.timeout);

  @override
  String toString() => '串流超過 ${timeout.inSeconds} 秒沒有收到資料，已停止等待';
}

class SseStreamDiagnostics {
  int malformedUtf8Replacements = 0;
}

/// 共用 SSE data parser：
/// - 每個 chunk 閒置超時；
/// - malformed UTF-8 以 U+FFFD 容錯並計數；
/// - EOF 時仍解析沒有換行的最後一個 data event。
class SseStream {
  static const Duration defaultIdleTimeout = Duration(seconds: 60);

  static Stream<String> data(
    Stream<List<int>> bytes, {
    Duration idleTimeout = defaultIdleTimeout,
    SseStreamDiagnostics? diagnostics,
  }) async* {
    final diag = diagnostics ?? SseStreamDiagnostics();
    var buffer = '';
    final decoded = bytes
        .timeout(
          idleTimeout,
          onTimeout: (sink) {
            sink.addError(StreamStallException(idleTimeout));
            sink.close();
          },
        )
        .transform(const Utf8Decoder(allowMalformed: true));

    await for (final chunk in decoded) {
      diag.malformedUtf8Replacements += '\uFFFD'.allMatches(chunk).length;
      buffer += chunk;
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      for (final line in lines) {
        final payload = _payload(line);
        if (payload != null) yield payload;
      }
    }

    if (buffer.isNotEmpty) {
      final payload = _payload(buffer);
      if (payload != null) yield payload;
    }
  }

  static String? _payload(String rawLine) {
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (!line.startsWith('data:')) return null;
    return line.substring(5).trim();
  }
}
