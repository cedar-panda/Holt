import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/backup_service.dart';
import 'package:project_yanci/models/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  setUpAll(sqfliteFfiInit);
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
          'pinned_static_self_notes': 'stable self notes',
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
          'status': Message.statusIncomplete,
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
      expect(
        tables['conversations']!.single,
        containsPair('pinned_static_self_notes', 'stable self notes'),
      );
      expect(tables['messages']!.single, containsPair('id', 42));
      expect(tables['messages']!.single, containsPair('split_mode', 1));
      expect(
        tables['messages']!.single,
        containsPair('memory_log', 'memory trace'),
      );
      expect(tables['messages']!.single, containsPair('cache_hit', 1));
      expect(
        tables['messages']!.single,
        containsPair('status', Message.statusIncomplete),
      );
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
    expect(message['status'], Message.statusComplete);
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

  test('v5 drops orphan messages, reports count, and never logs text', () {
    final backup = _emptyV5();
    const secretText = 'private-orphan-message-body';
    backup['messages'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'conversation_id': 'missing',
        'text': secretText,
        'is_user': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      final report = BackupService.normalizeWithReportForTesting(backup);

      expect(report.tables['messages'], isEmpty);
      expect(report.droppedOrphanMessageCount, 1);
      expect(BackupService.orphanImportSummaryForTesting(1), '捨棄1條孤兒訊息');
      expect(logs.join('\n'), contains('id=1'));
      expect(logs.join('\n'), isNot(contains(secretText)));
    } finally {
      debugPrint = originalDebugPrint;
    }
  });

  test('backup normalizes reverse spider links and duplicate favorites', () {
    final backup = _emptyV5();
    backup['spider_web_links'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-1',
        'memory_id_1': 9,
        'memory_id_2': 5,
        'created_at': '2026-01-01T00:00:00.000Z',
      },
      <String, dynamic>{
        'id': 2,
        'character_id': 'char-1',
        'memory_id_1': 5,
        'memory_id_2': 9,
        'created_at': '2026-01-01T00:00:01.000Z',
      },
    ];
    backup['saved_messages'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'message_id': '42',
        'content': 'first',
        'created_at': '2026-01-01T00:00:00.000Z',
      },
      <String, dynamic>{
        'id': 2,
        'message_id': '42',
        'content': 'duplicate',
        'created_at': '2026-01-01T00:00:01.000Z',
      },
    ];

    final tables = BackupService.normalizeForTesting(backup);

    expect(tables['spider_web_links'], hasLength(1));
    expect(tables['spider_web_links']!.single['memory_id_1'], 5);
    expect(tables['spider_web_links']!.single['memory_id_2'], 9);
    expect(tables['saved_messages'], hasLength(1));
    expect(tables['saved_messages']!.single['content'], 'first');
  });

  test('VACUUM INTO escapes a quote in its target path', () {
    expect(
      BackupService.vacuumIntoSqlForTesting("/tmp/user's/yanci.db"),
      "VACUUM INTO '/tmp/user''s/yanci.db'",
    );
  });

  test('VACUUM INTO creates a readable single-file snapshot', () async {
    final source = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final temp = await Directory.systemTemp.createTemp('holt-vacuum-test-');
    final snapshotPath = '${temp.path}/snapshot.db';
    try {
      await source.execute('CREATE TABLE sample (value TEXT NOT NULL)');
      await source.insert('sample', {'value': 'consistent'});
      await source.execute(BackupService.vacuumIntoSqlForTesting(snapshotPath));
      final snapshot = await databaseFactoryFfi.openDatabase(snapshotPath);
      try {
        expect((await snapshot.query('sample')).single['value'], 'consistent');
      } finally {
        await snapshot.close();
      }
      expect(await File('$snapshotPath-wal').exists(), isFalse);
      expect(await File('$snapshotPath-shm').exists(), isFalse);
    } finally {
      await source.close();
      await temp.delete(recursive: true);
    }
  });
}
