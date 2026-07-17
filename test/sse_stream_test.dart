import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/sse_stream.dart';

void main() {
  test('flushes a final SSE event that has no trailing newline', () async {
    final bytes = utf8.encode('data: {"tail":"kept"}');

    expect(
      await SseStream.data(Stream<List<int>>.value(bytes)).toList(),
      <String>['{"tail":"kept"}'],
    );
  });

  test('malformed UTF-8 is replaced and counted instead of aborting', () async {
    final diagnostics = SseStreamDiagnostics();
    final bytes = <int>[...utf8.encode('data: '), 0xC3, 0x28, 0x0A];

    final events = await SseStream.data(
      Stream<List<int>>.value(bytes),
      diagnostics: diagnostics,
    ).toList();

    expect(events, hasLength(1));
    expect(events.single, contains('\uFFFD'));
    expect(diagnostics.malformedUtf8Replacements, 1);
  });

  test('idle stream fails instead of waiting forever', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);

    await expectLater(
      SseStream.data(
        controller.stream,
        idleTimeout: const Duration(milliseconds: 20),
      ).toList(),
      throwsA(isA<StreamStallException>()),
    );
  });
}
