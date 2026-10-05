import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/rp_story_service.dart';
import 'package:project_yanci/services/rp_story_state_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '測試角色',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('rp_storylines', <String, Object?>{
      'character_id': 'char-a',
      'id': 'story-a',
      'name': '第一線',
      'status': 'active',
      'is_default': 1,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'entity keys and aliases are program-issued within one storyline',
    () async {
      final source = Message(
        id: 10,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '霍念安坦言自己曾用江離這個名字。',
        isUser: false,
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'name': '霍念安',
            'aliases': <String>['江離'],
            'identity': '顧夫人',
            'source_message_ids': <int>[10],
            'evidence': '霍念安坦言自己曾用江離這個名字',
          },
        ],
        relationships: const <Map<String, Object?>>[],
        sourceMessages: <Message>[source],
      );

      final character = (await db.query('rp_story_characters')).single;
      expect(character['entity_key'], 'P-0001');
      final aliases = await db.query(
        'rp_story_entity_aliases',
        orderBy: 'display_alias ASC',
      );
      expect(
        aliases.map((row) => row['display_alias']),
        containsAll(<String>['霍念安', '江離']),
      );
      expect(aliases.every((row) => row['entity_key'] == 'P-0001'), isTrue);
    },
  );

  test(
    'relationships use entity keys so aliases do not create duplicate edges',
    () async {
      final source = Message(
        id: 11,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '霍念安也叫江離；她與顧淵結為伴侶。',
        isUser: false,
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'name': '霍念安',
            'aliases': <String>['江離'],
            'source_message_ids': <int>[11],
            'evidence': '霍念安也叫江離',
          },
          <String, Object?>{
            'name': '顧淵',
            'source_message_ids': <int>[11],
            'evidence': '顧淵',
          },
        ],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from': '霍念安',
            'to': '顧淵',
            'direction': 'mutual',
            'current_relation': '伴侶',
            'source_message_ids': <int>[11],
            'evidence': '她與顧淵結為伴侶',
          },
        ],
        sourceMessages: <Message>[source],
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: const <Map<String, Object?>>[],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from': '江離',
            'to': '顧淵',
            'direction': 'mutual',
            'current_relation': '已婚伴侶',
            'source_message_ids': <int>[11],
            'evidence': '她與顧淵結為伴侶',
          },
        ],
        sourceMessages: <Message>[source],
      );

      final relationships = await db.query('rp_story_relationships');
      expect(relationships, hasLength(1));
      expect(relationships.single['normalized_edge'], 'P-0001|P-0002|mutual');
      expect(relationships.single['current_relation'], '已婚伴侶');
    },
  );

  test(
    'entity id updates one card and preserves unchanged profile fields',
    () async {
      final source = Message(
        id: 12,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '霍念安以江離之名現身，立場轉為協助顧淵。',
        isUser: false,
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'name': '霍念安',
            'appearance': '左眉有痣',
            'core_motivation': '洗清舊案',
            'identities': <Object?>[
              <String, Object?>{
                'name': '霍念安',
                'identity_type': '官面身份',
                'visibility': '公開',
              },
            ],
            'source_message_ids': <int>[12],
            'evidence': '霍念安',
          },
        ],
        relationships: const <Map<String, Object?>>[],
        sourceMessages: <Message>[source],
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'entity_id': 'P-0001',
            'name': '江離',
            'aliases': <String>['江離'],
            'current_stance': '協助顧淵',
            'identities': <Object?>[
              <String, Object?>{
                'name': '江離',
                'identity_type': '藝名',
                'visibility': '私下',
              },
            ],
            'source_message_ids': <int>[12],
            'evidence': '江離之名現身',
          },
        ],
        relationships: const <Map<String, Object?>>[],
        sourceMessages: <Message>[source],
      );

      final rows = await db.query('rp_story_characters');
      expect(rows, hasLength(1));
      expect(rows.single['name'], '霍念安');
      expect(rows.single['appearance'], '左眉有痣');
      expect(rows.single['core_motivation'], '洗清舊案');
      expect(rows.single['current_stance'], '協助顧淵');
      expect(rows.single['identities_json'].toString(), contains('官面身份'));
      expect(rows.single['identities_json'].toString(), contains('藝名'));
    },
  );

  test('v70 migration backfills stable entity keys and aliases', () async {
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('rp_story_characters', <String, Object?>{
      'id': 'legacy-person',
      'entity_key': '',
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'normalized_name': '霍念安',
      'name': '霍念安',
      'aliases_json': '["江離"]',
      'last_seen_at': now,
      'created_at': now,
      'updated_at': now,
    });

    await DatabaseHelper.upgradeSchemaForTesting(db, 69);

    final character = (await db.query('rp_story_characters')).single;
    expect(character['entity_key'], 'P-0001');
    final aliases = await db.query('rp_story_entity_aliases');
    expect(
      aliases.map((row) => row['display_alias']),
      containsAll(<String>['霍念安', '江離']),
    );
  });

  test('state upsert validates status, entity and narrative layer', () async {
    const now = '2026-10-02T00:00:00.000Z';
    await db.insert('context_summaries', <String, Object?>{
      'id': 77,
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'content': '城門一戰',
      'token_count': 8,
      'created_at': now,
    });
    await db.insert('rp_story_characters', <String, Object?>{
      'id': 'internal-a',
      'entity_key': 'P-0001',
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'normalized_name': '霍念安',
      'name': '霍念安',
      'last_seen_at': now,
      'created_at': now,
      'updated_at': now,
    });
    final source = Message(
      id: 12,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '城門一戰後，她的左手正在恢復。',
      isUser: false,
    );
    final stored = await RpStoryStateService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      sourceSummaryId: 77,
      states: <Map<String, Object?>>[
        <String, Object?>{
          'state_key': 'body.P-0001.left_hand',
          'state_type': 'body',
          'subject_entity_key': 'P-0001',
          'narrative_layer': 'main',
          'value': '左手箭傷，正在恢復',
          'status': 'recovering',
          'source_message_ids': <int>[12],
          'evidence': '左手正在恢復',
        },
        <String, Object?>{
          'state_key': 'body.P-9999.left_hand',
          'state_type': 'body',
          'subject_entity_key': 'P-9999',
          'value': '不存在的人物',
          'status': 'recovering',
          'source_message_ids': <int>[12],
          'evidence': '左手正在恢復',
        },
      ],
      sourceMessages: <Message>[source],
    );

    expect(stored, 1);
    final state = (await db.query('rp_story_states')).single;
    expect(state['state_key'], 'body.P-0001.left_hand');
    expect(state['status'], 'recovering');
    expect(state['source_summary_id'], 77);

    final dreamSource = Message(
      id: 13,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '她夢見左手已經痊癒。',
      isUser: true,
    );
    await RpStoryStateService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      states: <Map<String, Object?>>[
        <String, Object?>{
          'state_key': 'body.P-0001.left_hand_dream',
          'state_type': 'body',
          'subject_entity_key': 'P-0001',
          'narrative_layer': 'dream',
          'value': '夢中已痊癒',
          'status': 'healed',
          'source_message_ids': <int>[13],
          'evidence': '夢見左手已經痊癒',
        },
      ],
      sourceMessages: <Message>[dreamSource],
    );

    expect(
      await RpStoryStateService.listStates('char-a', continuityId: 'story-a'),
      hasLength(1),
    );
    expect(
      await RpStoryStateService.listStates(
        'char-a',
        continuityId: 'story-a',
        includeNonMain: true,
      ),
      hasLength(2),
    );
    final prompt = await RpStoryStateService.recallPrompt(
      'char-a',
      continuityId: 'story-a',
    );
    expect(prompt, contains('左手箭傷，正在恢復'));
    expect(prompt, isNot(contains('夢中已痊癒')));
  });

  test(
    'manual state correction remains protected from later extraction',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_characters', <String, Object?>{
        'id': 'internal-a',
        'entity_key': 'P-0001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'normalized_name': '霍念安',
        'name': '霍念安',
        'last_seen_at': now,
        'created_at': now,
        'updated_at': now,
      });
      final source = Message(
        id: 20,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '她的左手箭傷仍在恢復。',
        isUser: false,
      );
      final candidate = <String, Object?>{
        'state_key': 'body.P-0001.left_hand',
        'state_type': 'body',
        'subject_entity_key': 'P-0001',
        'narrative_layer': 'main',
        'value': '左手箭傷仍在恢復',
        'status': 'recovering',
        'source_message_ids': <int>[20],
        'evidence': '左手箭傷仍在恢復',
      };
      await RpStoryStateService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        states: <Map<String, Object?>>[candidate],
        sourceMessages: <Message>[source],
      );
      final original = (await db.query('rp_story_states')).single;
      await RpStoryStateService.updateState(
        original['id'].toString(),
        value: '左手已完全痊癒',
        status: 'healed',
      );

      await RpStoryStateService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        states: <Map<String, Object?>>[candidate],
        sourceMessages: <Message>[source],
      );

      final corrected = (await db.query('rp_story_states')).single;
      expect(corrected['value'], '左手已完全痊癒');
      expect(corrected['status'], 'healed');
      expect(corrected['user_edited'], 1);
      expect(RpStoryStateService.validStatuses('promise'), contains('pending'));
    },
  );

  test('live recall omits closed state rows but keeps active facts', () async {
    const now = '2026-10-02T00:00:00.000Z';
    final rows = <Map<String, Object?>>[
      <String, Object?>{
        'id': 'pending-promise',
        'state_key': 'promise.P-0001.city_gate',
        'state_type': 'promise',
        'subject_entity_key': 'P-0001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'narrative_layer': 'main',
        'value': '仍要在城門赴約',
        'status': 'pending',
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'id': 'fulfilled-promise',
        'state_key': 'promise.P-0001.old_oath',
        'state_type': 'promise',
        'subject_entity_key': 'P-0001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'narrative_layer': 'main',
        'value': '舊誓言已兌現',
        'status': 'fulfilled',
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'id': 'healed-body',
        'state_key': 'body.P-0001.shoulder',
        'state_type': 'body',
        'subject_entity_key': 'P-0001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'narrative_layer': 'main',
        'value': '肩傷已痊癒',
        'status': 'healed',
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'id': 'destroyed-item',
        'state_key': 'item.P-0001.seal',
        'state_type': 'item',
        'subject_entity_key': 'P-0001',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'narrative_layer': 'main',
        'value': '白鶴印已被焚毀',
        'status': 'destroyed',
        'created_at': now,
        'updated_at': now,
      },
    ];
    for (final row in rows) {
      await db.insert('rp_story_states', row);
    }

    final prompt = await RpStoryStateService.recallPrompt(
      'char-a',
      continuityId: 'story-a',
    );
    expect(prompt, contains('仍要在城門赴約'));
    expect(prompt, contains('白鶴印已被焚毀'));
    expect(prompt, isNot(contains('舊誓言已兌現')));
    expect(prompt, isNot(contains('肩傷已痊癒')));
  });
}
