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

  test('memory-disabled cleanup still captures local chat search tags', () {
    const windowId = 'memory-disabled-chat-search';
    addTearDown(() => MemoryActions.releaseWindow(windowId));

    final visible = MemoryActions.stripReply(
      '<SEARCH_CHAT>  previous promise  </SEARCH_CHAT>',
      windowId: windowId,
      captureSearchQuery: true,
    );

    expect(visible, isEmpty);
    expect(MemoryActions.lastSearchQueryFor(windowId), 'previous promise');
  });

  test(
    'a second response pass preserves earlier memory action state',
    () async {
      const windowId = 'multi-pass-memory-state';
      addTearDown(() => MemoryActions.releaseWindow(windowId));

      await MemoryActions.processReply(
        '<search_chat>上一次的約定</search_chat>',
        characterId: 'char-1',
        mode: 'romance',
        windowId: windowId,
      );
      MemoryActions.stripReply('第二次回覆', windowId: windowId, resetState: false);

      expect(MemoryActions.lastSearchQueryFor(windowId), '上一次的約定');
      expect(
        MemoryActions.lastActionLogFor(windowId),
        contains('🔍 搜尋「上一次的約定」'),
      );
    },
  );

  test('revoked KeepAlive lease cannot authorize a stale worker', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'keepalive_conv_id': 'conv-live',
      'keepalive_char_id': 'char-live',
      'keepalive_lease_token': 'conv-live:7',
    });

    expect(
      await KeepAliveService.instance.ownsPersistedLeaseForTesting(
        conversationId: 'conv-live',
        characterId: 'char-live',
        leaseToken: 'conv-live:7',
      ),
      isTrue,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('keepalive_lease_token', 'conv-live:8');

    expect(
      await KeepAliveService.instance.ownsPersistedLeaseForTesting(
        conversationId: 'conv-live',
        characterId: 'char-live',
        leaseToken: 'conv-live:7',
      ),
      isFalse,
    );
  });
}
