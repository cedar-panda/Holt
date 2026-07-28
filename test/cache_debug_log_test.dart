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

  test('fingerprint comparison skips other sessions and internal requests', () {
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-sonnet-4',
      'hash': 'older-a',
      'internal': false,
    });
    CacheDebugLog.add(<String, Object?>{
      'session_id': '',
      'model': 'claude-sonnet-4',
      'hash': 'internal',
      'internal': true,
    });
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-b',
      'model': 'claude-sonnet-4',
      'hash': 'other-window',
      'internal': false,
    });
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-sonnet-4',
      'hash': 'latest-a',
      'internal': false,
    });

    final previous = CacheDebugLog.previousComparableMain(0);
    expect(previous?['hash'], 'older-a');
  });

  test('fingerprint comparison does not cross model namespaces', () {
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-opus-4',
      'hash': 'other-model',
      'internal': false,
    });
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-sonnet-4',
      'hash': 'current-model',
      'internal': false,
    });

    expect(CacheDebugLog.previousComparableMain(0), isNull);
  });

  test('fingerprint comparison does not cross text and call channels', () {
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-sonnet-4',
      'cache_channel': 'text',
      'hash': 'text-older',
      'internal': false,
    });
    CacheDebugLog.add(<String, Object?>{
      'session_id': 'conv-a',
      'model': 'claude-sonnet-4',
      'cache_channel': 'call',
      'hash': 'call-latest',
      'internal': false,
    });

    expect(CacheDebugLog.previousComparableMain(0), isNull);
  });
}
