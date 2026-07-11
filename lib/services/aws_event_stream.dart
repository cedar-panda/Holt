import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 一個已通過 CRC 驗證的 Amazon EventStream message。
class AwsEventStreamMessage {
  const AwsEventStreamMessage({required this.headers, required this.payload});

  final Map<String, Object?> headers;
  final Uint8List payload;

  String? get messageType => headers[':message-type'] as String?;
  String? get eventType => headers[':event-type'] as String?;
}

/// Amazon EventStream 增量 frame decoder。
///
/// Wire format（所有整數皆 big-endian）：
/// total length / headers length / prelude CRC / headers / payload / message CRC。
/// 一個 transport chunk 可以包含半個、完整或多個 frame。
class AwsEventStreamDecoder {
  static const int _minimumFrameLength = 16;

  // 合法 AWS frame 的 payload + headers 上限約 25.3 MB。留出餘裕，同時避免
  // 損壞的 total_length 要求客戶端無限累積記憶體。
  static const int _maximumFrameLength = 32 * 1024 * 1024;

  Uint8List _buffer = Uint8List(1024);
  int _length = 0;

  List<AwsEventStreamMessage> add(List<int> chunk) {
    if (chunk.isNotEmpty) {
      _ensureCapacity(_length + chunk.length);
      _buffer.setRange(_length, _length + chunk.length, chunk);
      _length += chunk.length;
    }

    final messages = <AwsEventStreamMessage>[];
    var offset = 0;
    while (_length - offset >= 12) {
      final view = ByteData.sublistView(_buffer, offset, _length);
      final totalLength = view.getUint32(0, Endian.big);
      final headersLength = view.getUint32(4, Endian.big);
      final expectedPreludeCrc = view.getUint32(8, Endian.big);

      if (totalLength < _minimumFrameLength) {
        throw FormatException(
          'AWS EventStream frame length $totalLength 小於最小值 '
          '$_minimumFrameLength',
        );
      }
      if (totalLength > _maximumFrameLength) {
        throw FormatException(
          'AWS EventStream frame length $totalLength 超過安全上限 '
          '$_maximumFrameLength',
        );
      }
      if (headersLength > totalLength - _minimumFrameLength) {
        throw FormatException(
          'AWS EventStream headers length $headersLength 超過 frame 範圍',
        );
      }

      final actualPreludeCrc = crc32(_buffer, offset, offset + 8);
      if (actualPreludeCrc != expectedPreludeCrc) {
        throw FormatException(
          'AWS EventStream prelude CRC 不符：'
          'expected 0x${_hex32(expectedPreludeCrc)}, '
          'actual 0x${_hex32(actualPreludeCrc)}',
        );
      }

      if (_length - offset < totalLength) break;

      final messageEnd = offset + totalLength;
      final expectedMessageCrc = ByteData.sublistView(
        _buffer,
        messageEnd - 4,
        messageEnd,
      ).getUint32(0, Endian.big);
      final actualMessageCrc = crc32(_buffer, offset, messageEnd - 4);
      if (actualMessageCrc != expectedMessageCrc) {
        throw FormatException(
          'AWS EventStream message CRC 不符：'
          'expected 0x${_hex32(expectedMessageCrc)}, '
          'actual 0x${_hex32(actualMessageCrc)}',
        );
      }

      final headersStart = offset + 12;
      final headersEnd = headersStart + headersLength;
      final payloadEnd = messageEnd - 4;
      final headers = _decodeHeaders(
        Uint8List.fromList(_buffer.sublist(headersStart, headersEnd)),
      );
      final payload = Uint8List.fromList(
        _buffer.sublist(headersEnd, payloadEnd),
      );
      messages.add(AwsEventStreamMessage(headers: headers, payload: payload));
      offset = messageEnd;
    }

    if (offset > 0) {
      final remaining = _length - offset;
      if (remaining > 0) {
        final rest = Uint8List.fromList(_buffer.sublist(offset, _length));
        _buffer.setRange(0, remaining, rest);
      }
      _length = remaining;
    }
    return messages;
  }

  /// Transport 正常結束時呼叫；殘留 bytes 代表最後一個 frame 被截斷。
  void close() {
    if (_length != 0) {
      throw FormatException('AWS EventStream 在 frame 完成前結束（殘留 $_length bytes）');
    }
  }

  void _ensureCapacity(int needed) {
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final expanded = Uint8List(capacity)..setRange(0, _length, _buffer);
    _buffer = expanded;
  }

  /// IEEE CRC-32（poly 0xEDB88320），供 frame decoder 與測試 fixture 共用。
  static int crc32(List<int> bytes, [int start = 0, int? end]) {
    final stop = end ?? bytes.length;
    if (start < 0 || stop < start || stop > bytes.length) {
      throw RangeError.range(stop, start, bytes.length, 'end');
    }
    var crc = 0xFFFFFFFF;
    for (var i = start; i < stop; i++) {
      crc ^= bytes[i] & 0xFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? ((crc >>> 1) ^ 0xEDB88320) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Map<String, Object?> _decodeHeaders(Uint8List bytes) {
    final headers = <String, Object?>{};
    final data = ByteData.sublistView(bytes);
    var cursor = 0;

    void require(int count, String field) {
      if (count < 0 || cursor + count > bytes.length) {
        throw FormatException('AWS EventStream header 的 $field 被截斷');
      }
    }

    int uint16(String field) {
      require(2, field);
      final result = data.getUint16(cursor, Endian.big);
      cursor += 2;
      return result;
    }

    while (cursor < bytes.length) {
      require(1, 'name length');
      final nameLength = bytes[cursor++];
      if (nameLength == 0) {
        throw const FormatException('AWS EventStream header name 不可為空');
      }
      require(nameLength, 'name');
      final name = utf8.decode(
        bytes.sublist(cursor, cursor + nameLength),
        allowMalformed: false,
      );
      cursor += nameLength;
      if (headers.containsKey(name)) {
        throw FormatException('AWS EventStream header 重複：$name');
      }

      require(1, '$name type');
      final type = bytes[cursor++];
      Object? value;
      switch (type) {
        case 0:
          value = true;
        case 1:
          value = false;
        case 2:
          require(1, '$name byte');
          value = data.getInt8(cursor);
          cursor += 1;
        case 3:
          require(2, '$name short');
          value = data.getInt16(cursor, Endian.big);
          cursor += 2;
        case 4:
          require(4, '$name integer');
          value = data.getInt32(cursor, Endian.big);
          cursor += 4;
        case 5:
          require(8, '$name long');
          value = data.getInt64(cursor, Endian.big);
          cursor += 8;
        case 6:
          final length = uint16('$name byte-array length');
          require(length, '$name byte-array');
          value = Uint8List.fromList(bytes.sublist(cursor, cursor + length));
          cursor += length;
        case 7:
          final length = uint16('$name string length');
          require(length, '$name string');
          value = utf8.decode(
            bytes.sublist(cursor, cursor + length),
            allowMalformed: false,
          );
          cursor += length;
        case 8:
          require(8, '$name timestamp');
          value = data.getInt64(cursor, Endian.big);
          cursor += 8;
        case 9:
          require(16, '$name UUID');
          value = _formatUuid(bytes.sublist(cursor, cursor + 16));
          cursor += 16;
        default:
          throw FormatException('AWS EventStream header $name 使用未知型別 $type');
      }
      headers[name] = value;
    }
    return headers;
  }

  static String _formatUuid(List<int> bytes) {
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static String _hex32(int value) => value.toRadixString(16).padLeft(8, '0');
}

/// Bedrock 在 HTTP 200 後透過 EventStream 傳回的服務端例外。
class BedrockStreamException implements Exception {
  const BedrockStreamException({
    required this.type,
    required this.message,
    this.originalStatusCode,
    this.originalMessage,
  });

  final String type;
  final String message;
  final int? originalStatusCode;
  final String? originalMessage;

  @override
  String toString() {
    final status = originalStatusCode == null ? '' : ' ($originalStatusCode)';
    final original = originalMessage == null || originalMessage!.isEmpty
        ? ''
        : '；$originalMessage';
    return 'Bedrock 串流錯誤 [$type]$status：$message$original';
  }
}

/// 將 raw Amazon EventStream 轉為模型本身的 JSON event。
class BedrockEventStream {
  static const Duration defaultIdleTimeout = Duration(seconds: 45);

  static Stream<Map<String, dynamic>> decode(
    Stream<List<int>> source, {
    Duration idleTimeout = defaultIdleTimeout,
  }) async* {
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout', '必須大於零');
    }

    final decoder = AwsEventStreamDecoder();
    final guarded = _withIdleTimeout(source, idleTimeout);
    await for (final transportChunk in guarded) {
      for (final message in decoder.add(transportChunk)) {
        final messageType = message.messageType;
        if (messageType == 'event') {
          if (message.eventType != 'chunk') {
            throw FormatException(
              'Bedrock 收到未知 EventStream event：${message.eventType}',
            );
          }
          yield _decodeChunkPayload(message.payload);
          continue;
        }

        if (messageType == 'exception' || messageType == 'error') {
          throw _decodeException(message);
        }
        throw FormatException(
          'Bedrock EventStream 缺少或包含未知 :message-type：$messageType',
        );
      }
    }
    decoder.close();
  }

  static Map<String, dynamic> _decodeChunkPayload(Uint8List payload) {
    final envelope = _decodeJsonMap(payload, label: 'chunk envelope');
    final encoded = envelope['bytes'];
    late List<int> modelBytes;
    if (encoded is String) {
      try {
        modelBytes = base64Decode(encoded);
      } on FormatException catch (error) {
        throw FormatException('Bedrock chunk.bytes 不是合法 base64：$error');
      }
    } else if (encoded is List && encoded.every((value) => value is int)) {
      modelBytes = encoded.cast<int>();
    } else {
      throw const FormatException('Bedrock chunk event 缺少 bytes');
    }
    return _decodeJsonMap(modelBytes, label: 'model event');
  }

  static BedrockStreamException _decodeException(AwsEventStreamMessage event) {
    Map<String, dynamic> payload = const {};
    if (event.payload.isNotEmpty) {
      payload = _decodeJsonMap(event.payload, label: 'exception payload');
    }
    final isModeled = event.messageType == 'exception';
    final type =
        (isModeled
                ? event.headers[':exception-type']
                : event.headers[':error-code'])
            ?.toString();
    final headerMessage = event.headers[':error-message']?.toString();
    return BedrockStreamException(
      type: type == null || type.isEmpty ? 'UnknownException' : type,
      message:
          payload['message']?.toString() ?? headerMessage ?? '服務端在串流期間終止請求',
      originalStatusCode: _asInt(payload['originalStatusCode']),
      originalMessage: payload['originalMessage']?.toString(),
    );
  }

  static Map<String, dynamic> _decodeJsonMap(
    List<int> bytes, {
    required String label,
  }) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map) {
        throw FormatException('$label 不是 JSON object');
      }
      return <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    } on FormatException catch (error) {
      throw FormatException('Bedrock $label 無法解析：$error');
    }
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static Stream<List<int>> _withIdleTimeout(
    Stream<List<int>> source,
    Duration timeout,
  ) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var terminated = false;

    void armTimer() {
      timer?.cancel();
      if (terminated) return;
      timer = Timer(timeout, () {
        if (terminated) return;
        terminated = true;
        controller.addError(
          TimeoutException(
            'Bedrock 串流在連線後 ${timeout.inMilliseconds}ms 內沒有收到資料',
            timeout,
          ),
        );
        unawaited(subscription?.cancel());
        unawaited(controller.close());
      });
    }

    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (data) {
            if (terminated) return;
            armTimer();
            controller.add(data);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (terminated) return;
            terminated = true;
            timer?.cancel();
            controller.addError(error, stackTrace);
            unawaited(controller.close());
          },
          onDone: () {
            if (terminated) return;
            terminated = true;
            timer?.cancel();
            unawaited(controller.close());
          },
          cancelOnError: false,
        );
        armTimer();
      },
      onPause: () {
        timer?.cancel();
        subscription?.pause();
      },
      onResume: () {
        subscription?.resume();
        armTimer();
      },
      onCancel: () async {
        terminated = true;
        timer?.cancel();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
