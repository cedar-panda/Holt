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
    'newer narrative suppresses old scene without deleting durable state',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_states', {
        'id': 'old-scene',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'state_key': 'scene.current',
        'state_type': 'scene',
        'narrative_layer': 'main',
        'value': '準備前往客棧抄查',
        'status': '',
        'source_message_ids': '[10]',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('rp_story_states', {
        'id': 'durable-item',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'state_key': 'item.seal',
        'state_type': 'item',
        'narrative_layer': 'main',
        'value': '印信已遺失',
        'status': 'lost',
        'source_message_ids': '[10]',
        'created_at': now,
        'updated_at': now,
      });
      final recent = [
        Message(
          id: 12,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '抄查已結束，兩人回到內室。',
          isUser: false,
        ),
      ];
      final prompt = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
        recentMessages: recent,
      );
      expect(prompt, isNot(contains('準備前往客棧抄查')));
      expect(prompt, contains('印信已遺失'));
      expect(prompt, contains('not a live scene'));
      expect(await db.query('rp_story_states'), hasLength(2));
      final checkpointPrompt = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
      );
      expect(checkpointPrompt, contains('準備前往客棧抄查'));
    },
  );

  test(
    'fresh scene and user correction remain reference rather than authority',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_states', {
        'id': 'scene',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'state_key': 'scene.current',
        'state_type': 'scene',
        'narrative_layer': 'main',
        'value': '在內室喝藥',
        'status': '',
        'source_message_ids': '[12]',
        'created_at': now,
        'updated_at': now,
      });
      final recent = [
        Message(
          id: 12,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '在內室喝藥',
          isUser: false,
        ),
      ];
      expect(
        await RpStoryStateService.recallPrompt(
          'char-a',
          continuityId: 'story-a',
          recentMessages: recent,
        ),
        contains('在內室喝藥'),
      );
      await RpStoryStateService.updateState(
        'scene',
        value: '使用者修正的場景',
        status: '',
      );
      expect(
        await RpStoryStateService.recallPrompt(
          'char-a',
          continuityId: 'story-a',
          recentMessages: [
            Message(
              id: 20,
              conversationId: 'conv-a',
              text: '後續正文',
              isUser: false,
            ),
          ],
        ),
        contains('使用者修正的場景'),
      );
    },
  );

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
    'relationship evidence tolerates punctuation and explicit message joins',
    () async {
      final first = Message(
        id: 21,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '清川把青鸞印交給顧遠，',
        isUser: true,
      );
      final second = Message(
        id: 22,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '兩人因此正式結盟。',
        isUser: false,
      );
      final report = await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: const <Map<String, Object?>>[],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from': '清川',
            'to': '顧遠',
            'direction': 'mutual',
            'current_relation': '盟友',
            'source_message_ids': <int>[21, 22],
            'evidence': '清川把青鸞印交給顧遠 兩人因此正式結盟',
          },
        ],
        sourceMessages: <Message>[first, second],
      );

      expect(report.relationshipSubmitted, 1);
      expect(report.relationshipStored, 1);
      expect(report.relationshipRejectedEvidenceMismatch, 0);
      expect(await db.query('rp_story_relationships'), hasLength(1));
      expect(
        RpStoryService.latestExtractionReport(
          'char-a',
          continuityId: 'story-a',
        )?.toJson(),
        report.toJson(),
      );
    },
  );

  test(
    'relationship accepts entity-only parties and string source ids',
    () async {
      final source = Message(
        id: 24,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '清川與顧遠在渡口正式結盟。',
        isUser: false,
      );
      await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: <Map<String, Object?>>[
          <String, Object?>{
            'entity_id': 'P-0001',
            'name': '清川',
            'source_message_ids': '[24]',
            'evidence': '清川',
          },
          <String, Object?>{
            'entity_id': 'P-0002',
            'name': '顧遠',
            'source_message_ids': '[24]',
            'evidence': '顧遠',
          },
        ],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from_entity_key': 'P-0001',
            'to_entity_key': 'P-0002',
            'direction': 'mutual',
            'current_relation': '盟友',
            'source_message_ids': '[24]',
            'evidence': '清川與顧遠在渡口正式結盟',
          },
        ],
        sourceMessages: <Message>[source],
      );

      final relationships = await db.query('rp_story_relationships');
      expect(relationships, hasLength(1));
      expect(relationships.single['from_name'], '清川');
      expect(relationships.single['to_name'], '顧遠');
      expect(relationships.single['normalized_edge'], 'P-0001|P-0002|mutual');
    },
  );

  test(
    'relationship accepts name aliases used by structured providers',
    () async {
      final source = Message(
        id: 25,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '許清川收留顧遠，兩人成為暫住同伴。',
        isUser: true,
      );
      final report = await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        characters: const <Map<String, Object?>>[],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from_name': '許清川',
            'to_name': '顧遠',
            'direction': 'mutual',
            'current_relation': '暫住同伴',
            'source_message_ids': <int>[25],
            'evidence': '許清川收留顧遠',
          },
        ],
        sourceMessages: <Message>[source],
      );

      expect(report.relationshipStored, 1);
      expect(report.relationshipRejectedMissingParties, 0);
      expect(await db.query('rp_story_characters'), hasLength(2));
    },
  );

  test('relationship infers one unambiguous omitted source id', () async {
    final source = Message(
      id: 26,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '許清川將唯一的通行令交給顧遠保管。',
      isUser: false,
    );
    final report = await RpStoryService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      characters: const <Map<String, Object?>>[],
      relationships: <Map<String, Object?>>[
        <String, Object?>{
          'from': '許清川',
          'to': '顧遠',
          'direction': 'from_to',
          'current_relation': '託付重要物品',
          'source_message_ids': const <int>[],
          'evidence': '許清川將唯一的通行令交給顧遠保管',
        },
      ],
      sourceMessages: <Message>[source],
    );

    expect(report.relationshipStored, 1);
    final row = (await db.query('rp_story_relationships')).single;
    expect(row['source_message_ids'], '[26]');
  });

  test(
    'relationship rehydrates cited source from the same RP storyline',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('conversations', <String, Object?>{
        'id': 'conv-archived',
        'character_id': 'char-a',
        'context_mode': 'rp',
        'continuity_id': 'story-a',
        'title': '舊窗口',
        'created_at': now,
        'updated_at': now,
      });
      final messageId = await db.insert('messages', <String, Object?>{
        'conversation_id': 'conv-archived',
        'character_id': 'char-a',
        'text': '清川在雨夜替顧遠擋下一箭，兩人從此互信。',
        'is_user': 0,
        'created_at': now,
      });

      final report = await RpStoryService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-current',
        characters: const <Map<String, Object?>>[],
        relationships: <Map<String, Object?>>[
          <String, Object?>{
            'from': '清川',
            'to': '顧遠',
            'direction': 'mutual',
            'current_relation': '互信同伴',
            'source_message_ids': <int>[messageId],
            'evidence': '清川在雨夜替顧遠擋下一箭',
          },
        ],
        sourceMessages: const <Message>[],
      );

      expect(report.relationshipStored, 1);
      expect(report.relationshipRejectedMissingSource, 0);
      expect(await db.query('rp_story_relationships'), hasLength(1));
      expect(await db.query('rp_story_characters'), hasLength(2));
    },
  );

  test('relationship report explains unsupported evidence rejection', () async {
    final source = Message(
      id: 23,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '清川與顧遠在藥鋪短暫交談。',
      isUser: false,
    );
    final report = await RpStoryService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      characters: const <Map<String, Object?>>[],
      relationships: <Map<String, Object?>>[
        <String, Object?>{
          'from': '清川',
          'to': '顧遠',
          'direction': 'mutual',
          'current_relation': '生死盟友',
          'source_message_ids': <int>[23],
          'evidence': '兩人交換信物並立下生死之盟',
        },
      ],
      sourceMessages: <Message>[source],
    );

    expect(report.relationshipSubmitted, 1);
    expect(report.relationshipStored, 0);
    expect(report.relationshipRejectedEvidenceMismatch, 1);
    expect(await db.query('rp_story_relationships'), isEmpty);
  });

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

  test('one extraction can create more than six named characters', () async {
    final sources = <Message>[
      for (var index = 0; index < 20; index += 1)
        Message(
          id: 100 + index,
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '新人物$index在堂前報上姓名。',
          isUser: false,
        ),
    ];
    await RpStoryService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      characters: <Map<String, Object?>>[
        for (var index = 0; index < 20; index += 1)
          <String, Object?>{
            'entity_id': 'new',
            'name': '新人物$index',
            'first_scene': '堂前報名',
            'source_message_ids': <int>[100 + index],
            'evidence': '新人物$index在堂前報上姓名',
          },
      ],
      relationships: const <Map<String, Object?>>[],
      sourceMessages: sources,
    );

    final rows = await db.query('rp_story_characters');
    expect(rows, hasLength(20));
    final report = RpStoryService.latestExtractionReport(
      'char-a',
      continuityId: 'story-a',
    );
    expect(report?.characterSubmitted, 20);
    expect(report?.characterCreated, 20);
    expect(report?.characterUpdated, 0);
    expect(
      rows.map((row) => row['entity_key']),
      containsAll(<String>['P-0001', 'P-0020']),
    );
  });

  test('mismatched model entity id cannot overwrite another person', () async {
    final first = Message(
      id: 130,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '霍念安走入公堂。',
      isUser: false,
    );
    await RpStoryService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      characters: <Map<String, Object?>>[
        <String, Object?>{
          'entity_id': 'new',
          'name': '霍念安',
          'source_message_ids': <int>[130],
          'evidence': '霍念安走入公堂',
        },
      ],
      relationships: const <Map<String, Object?>>[],
      sourceMessages: <Message>[first],
    );

    final second = Message(
      id: 131,
      conversationId: 'conv-a',
      characterId: 'char-a',
      text: '裴念也隨後走入公堂。',
      isUser: false,
    );
    await RpStoryService.storeExtraction(
      characterId: 'char-a',
      continuityId: 'story-a',
      sourceConversationId: 'conv-a',
      characters: <Map<String, Object?>>[
        <String, Object?>{
          'entity_id': 'P-0001',
          'name': '裴念',
          'source_message_ids': <int>[131],
          'evidence': '裴念也隨後走入公堂',
        },
      ],
      relationships: const <Map<String, Object?>>[],
      sourceMessages: <Message>[second],
    );

    final rows = await db.query(
      'rp_story_characters',
      orderBy: 'entity_key ASC',
    );
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['name']), <Object?>['霍念安', '裴念']);
    expect(rows.map((row) => row['entity_key']), <Object?>['P-0001', 'P-0002']);
    expect(
      RpStoryService.latestExtractionReport(
        'char-a',
        continuityId: 'story-a',
      )?.characterEntityIdMismatch,
      1,
    );
  });

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
    'replacement keys update one verified snapshot and remove duplicates',
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
      for (final key in <String>[
        'body.P-0001.fever',
        'body.P-0001.high_fever',
      ]) {
        await db.insert('rp_story_states', <String, Object?>{
          'id': key,
          'character_id': 'char-a',
          'continuity_id': 'story-a',
          'state_key': key,
          'state_type': 'body',
          'subject_entity_key': 'P-0001',
          'object_entity_key': '',
          'narrative_layer': 'main',
          'value': '高熱恢復中',
          'status': 'recovering',
          'source_message_ids': '[10]',
          'created_at': now,
          'updated_at': now,
        });
      }
      final source = Message(
        id: 20,
        conversationId: 'conv-a',
        characterId: 'char-a',
        text: '霍念安的高熱已退。',
        isUser: false,
      );

      final stored = await RpStoryStateService.storeExtraction(
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        states: <Map<String, Object?>>[
          <String, Object?>{
            'state_key': 'body.P-0001.recovered_fever',
            'replaces_state_keys': <String>[
              'body.P-0001.fever',
              'body.P-0001.high_fever',
            ],
            'state_type': 'body',
            'subject_entity_key': 'P-0001',
            'object_entity_key': '',
            'narrative_layer': 'mainline',
            'value': '高熱已退',
            'status': 'healed',
            'source_message_ids': <int>[20],
            'evidence': '高熱已退',
          },
        ],
        sourceMessages: <Message>[source],
      );

      final rows = await db.query('rp_story_states');
      expect(stored, 1);
      expect(rows, hasLength(1));
      expect(rows.single['state_key'], isNot('body.P-0001.recovered_fever'));
      expect(rows.single['value'], '高熱已退');
      expect(rows.single['status'], 'healed');
    },
  );

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
        'value': '青鸞印已被焚毀',
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
    expect(prompt, contains('青鸞印已被焚毀'));
    expect(prompt, isNot(contains('舊誓言已兌現')));
    expect(prompt, isNot(contains('肩傷已痊癒')));
  });

  test(
    'internal state keys appear only for an explicit correction turn',
    () async {
      const now = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_states', <String, Object?>{
        'id': 'fatigue',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'state_key': 'body.P-0014.fatigue',
        'state_type': 'body',
        'narrative_layer': 'main',
        'value': '疲憊仍在恢復',
        'status': 'recovering',
        'source_message_ids': '[12]',
        'created_at': now,
        'updated_at': now,
      });

      final ordinary = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
        recentMessages: <Message>[
          Message(
            id: 13,
            conversationId: 'conv-a',
            text: '接著往下說。',
            isUser: true,
          ),
        ],
      );
      expect(ordinary, contains('疲憊仍在恢復'));
      expect(ordinary, isNot(contains('state_key=')));

      final correction = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
        recentMessages: <Message>[
          Message(
            id: 14,
            conversationId: 'conv-a',
            text: '修正：不是疲憊，應該是已經痊癒。',
            isUser: true,
          ),
        ],
      );
      expect(correction, contains('state_key=body.P-0014.fatigue'));
    },
  );

  test(
    'ordinary recall compacts offstage snapshots and hides storage enums',
    () async {
      const base = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_characters', <String, Object?>{
        'id': 'person-a',
        'entity_key': 'P-0014',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'normalized_name': '円樾',
        'name': '円樾',
        'aliases_json': '[]',
        'tier': 'active',
        'last_seen_at': base,
        'created_at': base,
        'updated_at': base,
      });
      final rows = <Map<String, Object?>>[
        <String, Object?>{
          'id': 'identity-new',
          'state_key': 'identity.P-0014.special_status',
          'state_type': 'identity',
          'subject_entity_key': 'P-0014',
          'value': '乾清宮伴駕寵妃',
          'status': 'active',
          'updated_at': '2026-10-02T03:00:00.000Z',
        },
        <String, Object?>{
          'id': 'body-new',
          'state_key': 'body.P-0014.fatigue',
          'state_type': 'body',
          'subject_entity_key': 'P-0014',
          'value': '腰肢酸軟，正在恢復',
          'status': 'recovering',
          'updated_at': '2026-10-02T03:00:00.000Z',
        },
        <String, Object?>{
          'id': 'body-old',
          'state_key': 'body.P-0014.defloration',
          'state_type': 'body',
          'subject_entity_key': 'P-0014',
          'value': '舊的身體階段',
          'status': 'recovering',
          'updated_at': '2026-10-02T02:00:00.000Z',
        },
        <String, Object?>{
          'id': 'promise-new',
          'state_key': 'promise.P-0014.new',
          'state_type': 'promise',
          'subject_entity_key': 'P-0014',
          'value': '最新約定',
          'status': 'pending',
          'updated_at': '2026-10-02T03:00:00.000Z',
        },
        <String, Object?>{
          'id': 'promise-old',
          'state_key': 'promise.P-0014.old',
          'state_type': 'promise',
          'subject_entity_key': 'P-0014',
          'value': '舊約定',
          'status': 'pending',
          'updated_at': '2026-10-02T01:00:00.000Z',
        },
      ];
      for (final row in rows) {
        await db.insert('rp_story_states', <String, Object?>{
          'character_id': 'char-a',
          'continuity_id': 'story-a',
          'narrative_layer': 'main',
          'source_message_ids': '[]',
          'created_at': base,
          ...row,
        });
      }

      final prompt = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
        recentMessages: <Message>[
          Message(
            id: 99,
            conversationId: 'conv-a',
            text: '接著往下說。',
            isUser: true,
          ),
        ],
      );

      expect(prompt, contains('乾清宮伴駕寵妃'));
      expect(prompt, contains('腰肢酸軟，正在恢復'));
      expect(prompt, contains('最新約定'));
      expect(prompt, isNot(contains('舊的身體階段')));
      expect(prompt, isNot(contains('舊約定')));
      expect(prompt, isNot(contains('[body')));
      expect(prompt, isNot(contains('recovering')));
    },
  );

  test(
    'ordinary recall keeps distinct active states for an appearing person',
    () async {
      const base = '2026-10-02T00:00:00.000Z';
      await db.insert('rp_story_characters', <String, Object?>{
        'id': 'person-a',
        'entity_key': 'P-0014',
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'normalized_name': '円樾',
        'name': '円樾',
        'aliases_json': '[]',
        'tier': 'active',
        'last_seen_at': base,
        'created_at': base,
        'updated_at': base,
      });
      for (final entry in <(String, String)>[
        ('body.P-0014.shoulder', '左肩箭傷恢復中'),
        ('body.P-0014.fever', '低熱尚未退淨'),
      ]) {
        await db.insert('rp_story_states', <String, Object?>{
          'id': entry.$1,
          'character_id': 'char-a',
          'continuity_id': 'story-a',
          'state_key': entry.$1,
          'state_type': 'body',
          'subject_entity_key': 'P-0014',
          'narrative_layer': 'main',
          'value': entry.$2,
          'status': 'recovering',
          'source_message_ids': '[]',
          'created_at': base,
          'updated_at': base,
        });
      }

      final prompt = await RpStoryStateService.recallPrompt(
        'char-a',
        continuityId: 'story-a',
        recentMessages: <Message>[
          Message(
            id: 99,
            conversationId: 'conv-a',
            text: '円樾走進房間。',
            isUser: true,
          ),
        ],
      );

      expect(prompt, contains('左肩箭傷恢復中'));
      expect(prompt, contains('低熱尚未退淨'));
    },
  );

  test('offstage relationship recall keeps only the newest edge', () async {
    const base = '2026-10-02T00:00:00.000Z';
    for (final entry in <(String, String, String)>[
      ('person-a', 'P-0001', '甲'),
      ('person-b', 'P-0002', '乙'),
      ('person-c', 'P-0003', '丙'),
    ]) {
      await db.insert('rp_story_characters', <String, Object?>{
        'id': entry.$1,
        'entity_key': entry.$2,
        'character_id': 'char-a',
        'continuity_id': 'story-a',
        'normalized_name': entry.$3,
        'name': entry.$3,
        'tier': 'active',
        'last_seen_at': base,
        'created_at': base,
        'updated_at': base,
      });
    }
    Future<void> addRelation({
      required String id,
      required String from,
      required String to,
      required String fromName,
      required String toName,
      required String relation,
      required String updatedAt,
    }) => db.insert('rp_story_relationships', <String, Object?>{
      'id': id,
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'from_name': fromName,
      'to_name': toName,
      'from_entity_key': from,
      'to_entity_key': to,
      'normalized_edge': '$from|$to|mutual',
      'current_relation': relation,
      'created_at': base,
      'updated_at': updatedAt,
    });
    await addRelation(
      id: 'newest',
      from: 'P-0002',
      to: 'P-0003',
      fromName: '乙',
      toName: '丙',
      relation: '最新的離場關係',
      updatedAt: '2026-10-02T03:00:00.000Z',
    );
    await addRelation(
      id: 'older',
      from: 'P-0001',
      to: 'P-0002',
      fromName: '甲',
      toName: '乙',
      relation: '更舊的離場關係',
      updatedAt: '2026-10-02T02:00:00.000Z',
    );

    final prompt = await RpStoryService.recallPrompt(
      'char-a',
      '接著說。',
      continuityId: 'story-a',
    );
    expect(prompt, contains('最新的離場關係'));
    expect(prompt, isNot(contains('更舊的離場關係')));
  });
}
