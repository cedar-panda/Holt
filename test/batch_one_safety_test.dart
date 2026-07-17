import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/keep_alive_service.dart';
import 'package:project_yanci/services/memory_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'KeepAlive reload adopts newer anchors written by background isolate',
    () async {
      final memoryStart = DateTime.utc(2026, 7, 17, 1);
      final memoryLastRequest = DateTime.utc(2026, 7, 17, 1, 10);
      final persistedStart = DateTime.utc(2026, 7, 17, 2);
      final persistedLastRequest = DateTime.utc(2026, 7, 17, 2, 20);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'keepalive_conv_id': 'test-conversation',
        'keepalive_char_id': 'test-character',
        'keepalive_start_time': persistedStart.toIso8601String(),
        'keepalive_last_request_at': persistedLastRequest.toIso8601String(),
      });

      final anchors = await KeepAliveService.instance
          .reloadPersistedAnchorsForTesting(
            startTime: memoryStart,
            lastRequestAt: memoryLastRequest,
          );

      expect(anchors.$1, persistedStart);
      expect(anchors.$2, persistedLastRequest);
    },
  );

  test('KeepAlive ignores anchors belonging to another conversation', () async {
    final memoryStart = DateTime.utc(2026, 7, 17, 3);
    final memoryLastRequest = DateTime.utc(2026, 7, 17, 3, 10);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'keepalive_conv_id': 'different-conversation',
      'keepalive_char_id': 'test-character',
      'keepalive_start_time': DateTime.utc(2026, 7, 17, 4).toIso8601String(),
      'keepalive_last_request_at': DateTime.utc(
        2026,
        7,
        17,
        4,
        20,
      ).toIso8601String(),
    });

    final anchors = await KeepAliveService.instance
        .reloadPersistedAnchorsForTesting(
          startTime: memoryStart,
          lastRequestAt: memoryLastRequest,
        );

    expect(anchors.$1, memoryStart);
    expect(anchors.$2, memoryLastRequest);
  });

  test('image-style cleanup clears a recorded search query', () async {
    const windowId = 'image-search-cleanup';
    addTearDown(() => MemoryActions.releaseWindow(windowId));

    await MemoryActions.processReply(
      '<search_chat>上一次的查詢</search_chat>',
      characterId: 'char-1',
      mode: 'balanced',
      windowId: windowId,
    );
    expect(MemoryActions.lastSearchQueryFor(windowId), '上一次的查詢');

    MemoryActions.clearSearchQuery(windowId);

    expect(MemoryActions.lastSearchQueryFor(windowId), isNull);
  });
}
