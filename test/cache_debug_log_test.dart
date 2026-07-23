import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/services/cache_debug_log.dart';

void main() {
  setUp(CacheDebugLog.clear);

  test(
    'flags a context cache that only reads the fixed prefix three times',
    () {
      for (var i = 0; i < 3; i++) {
        CacheDebugLog.add(<String, Object?>{
          'session_id': 'conv-1',
          'model': 'claude-sonnet-4',
          'internal': false,
          'static_t': 5000,
          'dynamic_t': 800,
          'prompt_t': 12000,
          'read': 5100,
        });
      }

      expect(CacheDebugLog.entries.first['context_stall_count'], 3);
      expect(CacheDebugLog.entries.first['context_cache_stalled'], isTrue);
    },
  );

  test('resets the stall counter after history cache grows', () {
    for (var i = 0; i < 2; i++) {
      CacheDebugLog.add(<String, Object?>{
        'session_id': 'conv-1',
        'model': 'claude-sonnet-4',
        'internal': false,
        'static_t': 5000,
        'dynamic_t': 800,
        'prompt_t': 12000,
        'read': 5100,
      });
    }
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-1',
      'model': 'claude-sonnet-4',
      'internal': false,
      'static_t': 5000,
      'dynamic_t': 800,
      'prompt_t': 12000,
      'read': 10000,
    });

    expect(CacheDebugLog.entries.first['context_stall_count'], 0);
    expect(CacheDebugLog.entries.first['context_cache_stalled'], isFalse);
  });
}
