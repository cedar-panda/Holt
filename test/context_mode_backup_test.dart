import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/backup_service.dart';

void main() {
  test('pre-v48 v5 backup receives the one-time daily baseline', () {
    final backup = _emptyV5(databaseVersion: 47);
    backup['characters'] = <Object?>[
      <String, Object?>{
        'id': 'char-a',
        'name': 'A',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <Object?>[
      <String, Object?>{
        'id': 'conv-old',
        'character_id': 'char-a',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];

    final normalized = BackupService.normalizeForTesting(backup);

    expect(normalized['characters']!.single['preferred_context_mode'], 'daily');
    expect(normalized['conversations']!.single['context_mode'], 'daily');
    expect(normalized['conversations']!.single['continuity_id'], 'main');
  });

  test('v48 backup preserves explicit RP window identity', () {
    final backup = _emptyV5(databaseVersion: 48);
    backup['characters'] = <Object?>[
      <String, Object?>{
        'id': 'char-a',
        'name': 'A',
        'preferred_context_mode': 'rp',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <Object?>[
      <String, Object?>{
        'id': 'conv-rp',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-b',
        'user_persona_id': 'persona-a',
        'worldbook_set_id': 'world-a',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];

    final row = BackupService.normalizeForTesting(
      backup,
    )['conversations']!.single;

    expect(row['context_mode'], 'rp');
    expect(row['continuity_id'], 'route-b');
    expect(row['user_persona_id'], 'persona-a');
    expect(row['worldbook_set_id'], 'world-a');
  });

  test('v50 backup preserves personas bindings and window snapshots', () {
    final backup = _emptyV5(databaseVersion: 50);
    backup['characters'] = <Object?>[_characterRow()];
    backup['user_personas'] = <Object?>[
      _personaRow(id: 'default', name: '小禾', isDefault: true),
      _personaRow(id: 'persona-rp', name: '巡夜人'),
    ];
    backup['character_persona_bindings'] = <Object?>[
      <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-b',
        'user_persona_id': 'persona-rp',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
    ];
    backup['conversations'] = <Object?>[
      <String, Object?>{
        'id': 'conv-rp',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-b',
        'user_persona_id': 'persona-rp',
        'user_persona_snapshot':
            '{"version":1,"id":"persona-rp","display_name":"巡夜人"}',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
    ];

    final normalized = BackupService.normalizeForTesting(backup);

    expect(normalized['user_personas'], hasLength(2));
    expect(
      normalized['character_persona_bindings']!.single['user_persona_id'],
      'persona-rp',
    );
    expect(
      normalized['conversations']!.single['user_persona_snapshot'],
      contains('persona-rp'),
    );
  });

  test('old mode-scoped bindings import as one newest shared pair', () {
    final backup = _emptyV5(databaseVersion: 81);
    backup['characters'] = <Object?>[_characterRow()];
    backup['user_personas'] = <Object?>[
      _personaRow(id: 'default', name: '小禾', isDefault: true),
      _personaRow(id: 'persona-daily', name: '日常'),
      _personaRow(id: 'persona-rp', name: 'RP'),
    ];
    backup['character_persona_bindings'] = <Object?>[
      <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
        'user_persona_id': 'persona-daily',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
      <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'route-b',
        'user_persona_id': 'persona-rp',
        'created_at': '2026-09-14T00:00:00.000Z',
        'updated_at': '2026-09-14T00:00:00.000Z',
      },
    ];

    final bindings = BackupService.normalizeForTesting(
      backup,
    )['character_persona_bindings']!;

    expect(bindings, hasLength(1));
    expect(bindings.single['user_persona_id'], 'persona-rp');
    expect(bindings.single['context_mode'], 'daily');
    expect(bindings.single['continuity_id'], 'main');
  });

  test('v50 backup without mode overrides remains importable', () {
    final backup = _emptyV5(databaseVersion: 50);
    final schema = backup['schema']! as Map<String, dynamic>;
    schema['tables'] = (schema['tables']! as List<String>)
        .where((table) => table != 'user_persona_mode_overrides')
        .toList(growable: false);
    backup.remove('user_persona_mode_overrides');

    final normalized = BackupService.normalizeForTesting(backup);
    expect(normalized['user_persona_mode_overrides'], isEmpty);
  });

  test('v50 backup rejects a binding to a missing persona', () {
    final backup = _emptyV5(databaseVersion: 50);
    backup['characters'] = <Object?>[_characterRow()];
    backup['user_personas'] = <Object?>[
      _personaRow(id: 'default', name: '小禾', isDefault: true),
    ];
    backup['character_persona_bindings'] = <Object?>[
      <String, Object?>{
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'main',
        'user_persona_id': 'missing',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('character_persona_bindings'),
        ),
      ),
    );
  });

  test('v50 backup rejects a window snapshot for another persona', () {
    final backup = _emptyV5(databaseVersion: 50);
    backup['characters'] = <Object?>[_characterRow()];
    backup['user_personas'] = <Object?>[
      _personaRow(id: 'default', name: '小禾', isDefault: true),
      _personaRow(id: 'persona-rp', name: '巡夜人'),
    ];
    backup['conversations'] = <Object?>[
      <String, Object?>{
        'id': 'conv-rp',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'main',
        'user_persona_id': 'persona-rp',
        'user_persona_snapshot': '{"version":1,"id":"default"}',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('snapshot'),
        ),
      ),
    );
  });

  test('v48 backup rejects an invalid or missing context mode', () {
    final invalid = _emptyV5(databaseVersion: 48);
    invalid['characters'] = <Object?>[
      <String, Object?>{
        'id': 'char-a',
        'name': 'A',
        'preferred_context_mode': 'daily',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];
    invalid['conversations'] = <Object?>[
      <String, Object?>{
        'id': 'conv-invalid',
        'character_id': 'char-a',
        'context_mode': 'story',
        'continuity_id': 'main',
        'created_at': '2026-09-12T00:00:00.000Z',
        'updated_at': '2026-09-12T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(invalid),
      throwsA(isA<FormatException>()),
    );
  });

  test('v48 backup rejects a scoped row bound to the wrong window mode', () {
    final backup = _v48WithConversation(mode: 'rp');
    backup['context_summaries'] = <Object?>[
      <String, Object?>{
        'id': 1,
        'character_id': 'char-a',
        'source_conversation_id': 'conv-a',
        'context_mode': 'daily',
        'continuity_id': 'main',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('context_summaries'),
        ),
      ),
    );
  });

  test('v48 backup rejects RP timeline data sourced from a daily window', () {
    final backup = _v48WithConversation(mode: 'daily');
    backup['rp_character_timeline'] = <Object?>[
      <String, Object?>{
        'id': 1,
        'character_id': 'char-a',
        'continuity_id': 'main',
        'source_conversation_id': 'conv-a',
        'type': 'event',
        'value': 'A fictional event',
        'created_at': '2026-09-13T00:00:00.000Z',
        'updated_at': '2026-09-13T00:00:00.000Z',
      },
    ];

    expect(
      () => BackupService.normalizeForTesting(backup),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('rp_character_timeline'),
        ),
      ),
    );
  });
}

Map<String, dynamic> _v48WithConversation({required String mode}) {
  final backup = _emptyV5(databaseVersion: 48);
  backup['characters'] = <Object?>[
    <String, Object?>{
      'id': 'char-a',
      'name': 'A',
      'preferred_context_mode': mode,
      'created_at': '2026-09-12T00:00:00.000Z',
      'updated_at': '2026-09-12T00:00:00.000Z',
    },
  ];
  backup['conversations'] = <Object?>[
    <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': mode,
      'continuity_id': 'main',
      'created_at': '2026-09-12T00:00:00.000Z',
      'updated_at': '2026-09-12T00:00:00.000Z',
    },
  ];
  return backup;
}

Map<String, Object?> _characterRow() => <String, Object?>{
  'id': 'char-a',
  'name': 'A',
  'preferred_context_mode': 'rp',
  'created_at': '2026-09-13T00:00:00.000Z',
  'updated_at': '2026-09-13T00:00:00.000Z',
};

Map<String, Object?> _personaRow({
  required String id,
  required String name,
  bool isDefault = false,
}) => <String, Object?>{
  'id': id,
  'display_name': name,
  'pronouns': '',
  'bio': '',
  'avatar_path': '',
  'prompt_content': '',
  'is_default': isDefault ? 1 : 0,
  'is_archived': 0,
  'created_at': '2026-09-13T00:00:00.000Z',
  'updated_at': '2026-09-13T00:00:00.000Z',
};

Map<String, dynamic> _emptyV5({required int databaseVersion}) =>
    <String, dynamic>{
      'version': BackupService.exportVersion,
      'type': 'holt_full_export',
      'app': 'Holt',
      'exported_at': '2026-09-13T00:00:00.000Z',
      'schema': <String, dynamic>{
        'database_version': databaseVersion,
        'tables': BackupService.appTables,
      },
      for (final table in BackupService.appTables) table: <Object?>[],
      'preferences': <String, Object?>{},
    };
