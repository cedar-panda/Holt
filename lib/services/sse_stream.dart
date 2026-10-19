import 'dart:async';
import 'dart:convert';

import 'locale_strings.dart';

class StreamStallException implements Exception {
  final Duration timeout;

  const StreamStallException(this.timeout);

  @override
  String toString() => '串流超過 ${timeout.inSeconds} 秒沒有收到資料，已停止等待';
}

class StreamEndedWithoutTerminalException implements Exception {
  final String provider;

  const StreamEndedWithoutTerminalException(this.provider);

  @override
  String toString() => L.pick(
    en: '$provider connection ended before the provider confirmed completion. The received text was kept as incomplete; retry to continue.',
    zhTW: '$provider 連線在服務端確認完成前中斷；已收到的文字會保留為未完成，可重新發送繼續。',
    zhCN: '$provider 连接在服务端确认完成前中断；已收到的文字会保留为未完成，可重新发送继续。',
  );
}

class StreamEndedWithReasonException implements Exception {
  final String provider;
  final String reason;

  const StreamEndedWithReasonException(this.provider, this.reason);

  @override
  String toString() => L.pick(
    en: '$provider ended the reply with $reason. The received text was kept as incomplete.',
    zhTW: '$provider 以 $reason 結束回覆；已收到的文字會保留為未完成。',
    zhCN: '$provider 以 $reason 结束回复；已收到的文字会保留为未完成。',
  );
}

abstract final class StreamTerminalGuard {
  static void requireOpenAiCompatible({
    required String provider,
    required bool sawDone,
    required String? finishReason,
  }) {
    final reason = finishReason?.trim().toLowerCase() ?? '';
    if (reason == 'length' || reason == 'max_tokens') {
      throw StreamEndedWithReasonException(provider, finishReason!);
    }
    if (sawDone ||
        const <String>{
          'stop',
          'tool_calls',
          'function_call',
        }.contains(reason)) {
      return;
    }
    if (reason.isNotEmpty) {
      throw StreamEndedWithReasonException(provider, finishReason!);
    }
    throw StreamEndedWithoutTerminalException(provider);
  }
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
