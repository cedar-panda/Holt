import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/backup_service.dart';

Map<String, dynamic> _emptyV5() => <String, dynamic>{
  'version': BackupService.exportVersion,
  'type': 'holt_full_export',
  'app': 'Holt',
  'exported_at': '2026-07-10T12:00:00.000Z',
  'schema': <String, dynamic>{
    'database_version': 32,
    'tables': BackupService.appTables,
  },
  for (final table in BackupService.appTables) table: <dynamic>[],
  'preferences': <String, dynamic>{},
};

void main() {
  test(
    'v5 preserves conversation cache identity and complete message rows',
    () {
      final backup = _emptyV5();
      backup['characters'] = <dynamic>[
        <String, dynamic>{
          'id': 'char-1',
          'name': 'Holt',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-01T00:00:00.000Z',
        },
      ];
      backup['conversations'] = <dynamic>[
        <String, dynamic>{
          'id': 'conv-1',
          'character_id': 'char-1',
          'window_summary_id': 'abc',
          'pinned_static_summary': 'stable prompt',
          'title': 'first',
          'is_starred': 1,
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-01T00:00:00.000Z',
        },
      ];
      backup['messages'] = <dynamic>[
        <String, dynamic>{
          'id': 42,
          'conversation_id': 'conv-1',
          'character_id': 'char-1',
          'text': 'hello',
          'is_user': 0,
          'split_mode': 1,
          'memory_log': 'memory trace',
          'cache_hit': 1,
          'created_at': '2026-01-01T00:00:01.000Z',
        },
      ];

      final tables = BackupService.normalizeForTesting(backup);

      expect(tables.keys, containsAll(BackupService.appTables));
      expect(
        tables['conversations']!.single,
        containsPair('window_summary_id', 'abc'),
      );
      expect(
        tables['conversations']!.single,
        containsPair('pinned_static_summary', 'stable prompt'),
      );
      expect(tables['messages']!.single, containsPair('id', 42));
      expect(tables['messages']!.single, containsPair('split_mode', 1));
      expect(
        tables['messages']!.single,
        containsPair('memory_log', 'memory trace'),
      );
      expect(tables['messages']!.single, containsPair('cache_hit', 1));
    },
  );

  test('v4 Yanci backup is accepted with safe message defaults', () {
    final backup = <String, dynamic>{
      'version': 4,
      'type': 'yanci_full_export',
      'exported_at': '2026-07-10T12:00:00.000Z',
      'characters': <dynamic>[
        <String, dynamic>{'id': 'char-1', 'name': 'Holt'},
      ],
      'conversations': <dynamic>[
        <String, dynamic>{
          'conversation_id': 'conv-1',
          'character_id': 'char-1',
          'title': 'legacy',
          'messages': <dynamic>[
            <String, dynamic>{
              'text': 'old answer',
              'is_user': false,
              'character_id': 'char-1',
            },
          ],
        },
      ],
      'saved_messages': <dynamic>[
        <String, dynamic>{
          'id': 9,
          'message_id': '999',
          'content': 'old answer',
          'conversation_id': 'conv-1',
          'character_id': 'char-1',
        },
      ],
      'archive': <dynamic>[
        <String, dynamic>{
          'id': 7,
          'original_id': 3,
          'original_table': 'memories',
          'content_snapshot':
              '{"id":3,"character_id":"char-1","content":"old"}',
          'archived_at': '2026-01-01T00:00:00.000Z',
          'reason': 'legacy',
        },
      ],
    };

    final tables = BackupService.normalizeForTesting(backup);
    final message = tables['messages']!.single;

    expect(message['id'], 1);
    expect(message['split_mode'], 0);
    expect(message['memory_log'], '');
    expect(message['cache_hit'], 0);
    expect(tables['saved_messages']!.single['message_id'], '1');
    expect(tables['archive']!.single['character_id'], 'char-1');
  });

  test('v5 rejects an incomplete table manifest before restore', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['tables'] = <String>['characters', 'conversations', 'messages'];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(isA<FormatException>()),
    );
  });

  test('v5 rejects a message whose conversation does not exist', () {
    final backup = _emptyV5();
    backup['messages'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'conversation_id': 'missing',
        'text': 'orphan',
        'is_user': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(isA<FormatException>()),
    );
  });
}
