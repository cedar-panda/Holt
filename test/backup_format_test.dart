import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
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
    'current schema manifest backs up diagnostics and reusable vectors',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      try {
        await DatabaseHelper.createSchemaForTesting(db);
        await expectLater(
          BackupService.verifyTableManifestForTesting(db),
          completes,
        );
        expect(BackupService.appTables, contains('chat_diagnostics'));
        expect(BackupService.appTables, contains('memory_embeddings'));
      } finally {
        await db.close();
      }
    },
  );

  test('older v5 backups may omit derived vectors', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['tables'] = (schema['tables'] as List<String>)
        .where((table) => table != 'memory_embeddings')
        .toList(growable: false);
    backup.remove('memory_embeddings');

    final tables = BackupService.normalizeForTesting(backup);
    expect(tables['memory_embeddings'], isEmpty);
  });

  test('v5 preserves daily character diaries', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['database_version'] = DatabaseHelper.schemaVersionForTesting;
    backup['characters'] = <dynamic>[
      <String, dynamic>{
        'id': 'char-diary',
        'name': 'Holt',
        'preferred_context_mode': 'daily',
        'created_at': '2026-10-04T00:00:00.000Z',
        'updated_at': '2026-10-04T00:00:00.000Z',
      },
    ];
    backup['user_personas'] = <dynamic>[
      <String, dynamic>{
        'id': 'default',
        'display_name': '',
        'pronouns': '',
        'bio': '',
        'avatar_path': '',
        'prompt_content': '',
        'is_default': 1,
        'is_archived': 0,
        'created_at': '2026-10-04T00:00:00.000Z',
        'updated_at': '2026-10-04T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <dynamic>[
      <String, dynamic>{
        'id': 'daily-window',
        'character_id': 'char-diary',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'user_persona_id': 'default',
        'user_persona_snapshot': '',
        'created_at': '2026-10-04T00:00:00.000Z',
        'updated_at': '2026-10-04T00:00:00.000Z',
      },
    ];
    backup['character_diaries'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-diary',
        'diary_date': '2026-10-04',
        'title': '今晚',
        'body': '今天想留下的一句話。',
        'source_conversation_id': 'daily-window',
        'source_message_id': null,
        'created_at': '2026-10-04T13:00:00.000Z',
        'updated_at': '2026-10-04T13:00:00.000Z',
      },
    ];

    final diaries = BackupService.normalizeForTesting(
      backup,
    )['character_diaries']!;
    expect(diaries, hasLength(1));
    expect(diaries.single['body'], '今天想留下的一句話。');
    expect(diaries.single['diary_date'], '2026-10-04');
  });

  test('guide conversation and messages survive backup normalization', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['database_version'] = DatabaseHelper.schemaVersionForTesting;
    backup['user_personas'] = <dynamic>[
      <String, dynamic>{
        'id': 'default',
        'display_name': '',
        'pronouns': '',
        'bio': '',
        'avatar_path': '',
        'prompt_content': '',
        'is_default': 1,
        'is_archived': 0,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <dynamic>[
      <String, dynamic>{
        'id': 'holt-guide-main',
        'character_id': '__holt_guide__',
        'context_mode': 'daily',
        'continuity_id': 'guide',
        'user_persona_id': 'default',
        'user_persona_snapshot': '',
        'title': '嚮導',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['messages'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'conversation_id': 'holt-guide-main',
        'character_id': '__holt_guide__',
        'text': '嘿，你好啊',
        'is_user': 0,
        'created_at': '2026-01-01T00:00:01.000Z',
      },
    ];

    final normalized = BackupService.normalizeForTesting(backup);
    expect(normalized['conversations']!.single['id'], 'holt-guide-main');
    expect(normalized['messages']!.single['text'], '嘿，你好啊');
  });

  test('v5 preserves valid memory embeddings for reuse after restore', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['database_version'] = DatabaseHelper.schemaVersionForTesting;
    backup['characters'] = <dynamic>[
      <String, dynamic>{
        'id': 'char-1',
        'name': 'Holt',
        'preferred_context_mode': 'daily',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['user_personas'] = <dynamic>[
      <String, dynamic>{
        'id': 'default',
        'display_name': '',
        'pronouns': '',
        'bio': '',
        'avatar_path': '',
        'prompt_content': '',
        'is_default': 1,
        'is_archived': 0,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['memories'] = <dynamic>[
      <String, dynamic>{
        'id': 7,
        'character_id': 'char-1',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'mode': 'romance',
        'category': '偏好',
        'content': '昭昭喜歡雨天',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['memory_embeddings'] = <dynamic>[
      <String, dynamic>{
        'memory_id': 7,
        'provider': 'gemini',
        'model': 'embedding-001',
        'content_hash': 'content-hash',
        'dimensions': 3,
        'vector_json': '[0.1,0.2,0.3]',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    final rows = BackupService.normalizeForTesting(
      backup,
    )['memory_embeddings']!;
    expect(rows, hasLength(1));
    expect(rows.single['memory_id'], 7);
    expect(rows.single['dimensions'], 3);
  });

  test('pre-diagnostic v5 backups may omit diagnostic cards', () {
    final backup = _emptyV5();
    backup['schema'] = <String, dynamic>{
      'database_version': 56,
      'tables': <String>[
        for (final table in BackupService.appTables)
          if (table != 'chat_diagnostics') table,
      ],
    };
    backup.remove('chat_diagnostics');

    final tables = BackupService.normalizeForTesting(backup);
    expect(tables['chat_diagnostics'], isEmpty);
  });

  test('v5 preserves persistent chat diagnostic cards', () {
    final backup = _emptyV5();
    final schema = backup['schema'] as Map<String, dynamic>;
    schema['database_version'] = DatabaseHelper.schemaVersionForTesting;
    backup['characters'] = <dynamic>[
      <String, dynamic>{
        'id': 'char-1',
        'name': 'Holt',
        'preferred_context_mode': 'daily',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['user_personas'] = <dynamic>[
      <String, dynamic>{
        'id': 'default',
        'display_name': '',
        'pronouns': '',
        'bio': '',
        'avatar_path': '',
        'prompt_content': '',
        'is_default': 1,
        'is_archived': 0,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <dynamic>[
      <String, dynamic>{
        'id': 'conv-1',
        'character_id': 'char-1',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'user_persona_id': 'default',
        'user_persona_snapshot': '',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];
    backup['messages'] = <dynamic>[
      <String, dynamic>{
        'id': 42,
        'conversation_id': 'conv-1',
        'character_id': 'char-1',
        'text': 'retry this request',
        'is_user': 1,
        'created_at': '2026-01-01T00:00:01.000Z',
      },
    ];
    backup['chat_diagnostics'] = <dynamic>[
      <String, dynamic>{
        'id': 7,
        'conversation_id': 'conv-1',
        'source_message_id': 42,
        'anchor_message_id': 42,
        'category': 'rate_limited',
        'status_code': 429,
        'provider': 'openrouter',
        'model': 'model-a',
        'raw_log': '429 quota',
        'created_at': '2026-01-01T00:00:02.000Z',
      },
    ];

    final diagnostics = BackupService.normalizeForTesting(
      backup,
    )['chat_diagnostics']!;
    expect(diagnostics, hasLength(1));
    expect(diagnostics.single['id'], 7);
    expect(diagnostics.single['status_code'], 429);
    expect(diagnostics.single['raw_log'], '429 quota');
  });

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
          'summary_cursor_message_id': 999,
          'pinned_static_summary': 'stable prompt',
          'pinned_static_self_notes': 'stable self notes',
          'pinned_coin_snapshot_char': 800,
          'pinned_coin_snapshot_user': 900,
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
          'summary_recorded': 1,
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
      expect(
        tables['conversations']!.single,
        containsPair('pinned_coin_snapshot_char', 800),
      );
      expect(
        tables['conversations']!.single,
        containsPair('pinned_coin_snapshot_user', 900),
      );
      expect(
        tables['conversations']!.single,
        containsPair('summary_cursor_message_id', 42),
      );
      expect(tables['messages']!.single, containsPair('id', 42));
      expect(tables['messages']!.single, containsPair('split_mode', 1));
      expect(
        tables['messages']!.single,
        containsPair('memory_log', 'memory trace'),
      );
      expect(tables['messages']!.single, containsPair('cache_hit', 1));
      expect(tables['messages']!.single, containsPair('summary_recorded', 1));
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

  test('timeline import deduplicates a day and repairs ISO week-year', () {
    final backup = _emptyV5();
    backup['character_timeline'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-a',
        'type': 'event',
        'value': '約會',
        'week_group': '2025-W52',
        'confirmed': 0,
        'source_message_id': 9,
        'source_message_ids': '[9,7,9]',
        'source_evidence': '那天正式約會了',
        'created_at': '2025-12-29T09:00:00.000',
        'updated_at': '2025-12-29T09:00:00.000',
      },
      <String, dynamic>{
        'id': 2,
        'character_id': 'char-a',
        'type': 'event',
        'value': '約會',
        'week_group': '2025-W52',
        'confirmed': 1,
        'created_at': '2025-12-29T20:00:00.000',
        'updated_at': '2025-12-29T20:00:00.000',
      },
    ];

    final rows = BackupService.normalizeForTesting(
      backup,
    )['character_timeline']!;
    expect(rows, hasLength(1));
    expect(rows.single['confirmed'], 1);
    expect(rows.single['week_group'], '2026-W01');
    expect(rows.single['source_message_id'], 7);
    expect(rows.single['source_message_ids'], '[7,9]');
    expect(rows.single['source_evidence'], '那天正式約會了');
  });

  test('RP timeline backup preserves v72 narrative metadata', () {
    final backup = _emptyV5();
    backup['rp_character_timeline'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-a',
        'continuity_id': 'main',
        'type': 'event',
        'event_key': 'event.meeting.rain',
        'narrative_layer': 'memory',
        'subject_entity_ids': '["P-0002","P-0001","P-0002"]',
        'value': '雨夜初遇的回憶',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    final row = BackupService.normalizeForTesting(
      backup,
    )['rp_character_timeline']!.single;
    expect(row['event_key'], 'event.meeting.rain');
    expect(row['narrative_layer'], 'memory');
    expect(row['subject_entity_ids'], '["P-0002","P-0001"]');
  });

  test('legacy RP timeline backup defaults v72 narrative metadata', () {
    final backup = _emptyV5();
    backup['rp_character_timeline'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-a',
        'continuity_id': 'main',
        'type': 'event',
        'value': '主線事件',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    final row = BackupService.normalizeForTesting(
      backup,
    )['rp_character_timeline']!.single;
    expect(row['event_key'], '');
    expect(row['narrative_layer'], 'main');
    expect(row['subject_entity_ids'], '[]');
  });

  test('RP timeline backup rejects invalid narrative metadata', () {
    final backup = _emptyV5();
    backup['rp_character_timeline'] = <dynamic>[
      <String, dynamic>{
        'id': 1,
        'character_id': 'char-a',
        'continuity_id': 'main',
        'type': 'event',
        'narrative_layer': 'hallucination',
        'subject_entity_ids': '["not-an-entity"]',
        'value': '錯誤事件',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(isA<FormatException>()),
    );
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
      <String, dynamic>{
        'id': 3,
        'character_id': 'char-1',
        'memory_id_1': 5,
        'memory_id_2': 9,
        'relation_type': 'temporal',
        'created_at': '2026-01-01T00:00:02.000Z',
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

    expect(tables['spider_web_links'], hasLength(2));
    expect(
      tables['spider_web_links']!.every(
        (link) => link['memory_id_1'] == 5 && link['memory_id_2'] == 9,
      ),
      isTrue,
    );
    expect(
      tables['spider_web_links']!.map((link) => link['relation_type']).toSet(),
      <Object?>{'related', 'temporal'},
    );
    expect(tables['saved_messages'], hasLength(1));
    expect(tables['saved_messages']!.single['content'], 'first');
  });

  test('VACUUM INTO escapes a quote in its target path', () {
    expect(
      BackupService.vacuumIntoSqlForTesting("/tmp/user's/yanci.db"),
      "VACUUM INTO '/tmp/user''s/yanci.db'",
    );
  });

  test('export cleanup only recognizes Holt backup artifacts', () {
    expect(
      BackupService.isExportArtifactNameForTesting(
        'holt_backup_2026-08-03T12-39-31.holt.zip',
      ),
      isTrue,
    );
    expect(
      BackupService.isExportArtifactNameForTesting(
        'holt_backup_2026-08-03T12-39-31.holt.backup',
      ),
      isTrue,
    );
    expect(
      BackupService.isExportArtifactNameForTesting(
        'holt_export_2026-08-03T12-39-31.json',
      ),
      isTrue,
    );
    expect(
      BackupService.isExportArtifactNameForTesting('family-photo.zip'),
      isFalse,
    );
    expect(
      BackupService.isExportArtifactNameForTesting(
        'holt_backup_2026-08-03T12-39-31.holt.zip.bak',
      ),
      isFalse,
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
