import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../models/message.dart';
import 'locale_strings.dart';
import 'token_estimator.dart';

/// Persistence and request-only recall for RP story characters and relations.
/// Every query is scoped by the parent character card and continuity id so a
/// future multi-story UI can switch lanes without migrating these records.
abstract final class RpStoryService {
  static const Uuid _uuid = Uuid();
  static const int characterExtractionLimit = 6;
  static const int relationshipExtractionLimit = 8;
  static const int fullProfileLimit = 3;
  static const int compactProfileLimit = 6;
  static const int defaultTokenBudget = 1800;

  static String _scope(String value) =>
      value.trim().isEmpty ? 'main' : value.trim();

  static String _normalizedName(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

  static List<int> _sourceIds(Object? raw) {
    if (raw is! List) return const <int>[];
    return raw
        .map(
          (value) => switch (value) {
            num number => number.toInt(),
            String text => int.tryParse(text.trim()),
            _ => null,
          },
        )
        .whereType<int>()
        .where((id) => id > 0)
        .toSet()
        .toList(growable: false);
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static List<Object?> _jsonList(Object? raw) {
    if (raw is List) return List<Object?>.from(raw);
    if (raw is! String || raw.trim().isEmpty) return const <Object?>[];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? List<Object?>.from(decoded) : const <Object?>[];
    } catch (_) {
      return const <Object?>[];
    }
  }

  static List<Object?> _mergeJsonLists(Object? existing, Object? incoming) {
    final merged = <Object?>[];
    final seen = <String>{};
    for (final value in <Object?>[
      ..._jsonList(existing),
      ..._jsonList(incoming),
    ]) {
      final key = jsonEncode(value);
      if (seen.add(key)) merged.add(value);
    }
    return merged;
  }

  static List<Object?> _mergeJsonObjectsByKeys(
    Object? existing,
    Object? incoming,
    List<String> keys,
  ) {
    final merged = <String, Object?>{};
    var anonymousOrdinal = 0;
    for (final value in <Object?>[
      ..._jsonList(existing),
      ..._jsonList(incoming),
    ]) {
      if (value is Map) {
        final normalized = <String, Object?>{
          for (final entry in value.entries) entry.key.toString(): entry.value,
        };
        final identity = keys
            .map(
              (key) => normalized[key]?.toString().trim().toLowerCase() ?? '',
            )
            .join('|');
        if (identity.replaceAll('|', '').isNotEmpty) {
          merged[identity] = normalized;
          continue;
        }
      }
      merged['#${anonymousOrdinal++}:${jsonEncode(value)}'] = value;
    }
    return merged.values.toList(growable: false);
  }

  static String _incomingOrExisting(
    Map<String, Object?> candidate,
    String key,
    Map<String, Object?>? existing,
  ) {
    final incoming = _text(candidate, key);
    if (incoming.isNotEmpty) return incoming;
    return existing == null ? '' : _text(existing, key);
  }

  static String _text(Map<String, Object?> row, String key) =>
      row[key]?.toString().trim() ?? '';

  static bool _supportedBySource(
    Map<String, Object?> candidate,
    Map<int, Message> sources,
  ) {
    final ids = _sourceIds(candidate['source_message_ids']);
    final evidence = _text(candidate, 'evidence');
    if (ids.isEmpty || evidence.isEmpty) return false;
    return ids.every(sources.containsKey) &&
        ids.any((id) => sources[id]!.text.contains(evidence));
  }

  static Future<String> _nextEntityKey(
    DatabaseExecutor db,
    String characterId,
    String continuityId,
  ) async {
    final rows = await db.query(
      'rp_story_characters',
      columns: const <String>['entity_key'],
      where: 'character_id = ? AND continuity_id = ?',
      whereArgs: <Object?>[characterId, continuityId],
    );
    var maxOrdinal = 0;
    for (final row in rows) {
      final key = row['entity_key']?.toString() ?? '';
      final match = RegExp(r'^P-(\d+)$').firstMatch(key);
      final ordinal = match == null ? null : int.tryParse(match.group(1)!);
      if (ordinal != null && ordinal > maxOrdinal) maxOrdinal = ordinal;
    }
    return 'P-${(maxOrdinal + 1).toString().padLeft(4, '0')}';
  }

  static Future<void> _replaceAliases(
    DatabaseExecutor db, {
    required String characterId,
    required String continuityId,
    required String entityKey,
    required String name,
    required List<String> aliases,
    required String now,
  }) async {
    final values = <String>{
      name,
      ...aliases,
    }.map((value) => value.trim()).where((value) => value.isNotEmpty);
    for (final alias in values) {
      final normalized = _normalizedName(alias);
      if (normalized.isEmpty) continue;
      await db.insert('rp_story_entity_aliases', <String, Object?>{
        'character_id': characterId,
        'continuity_id': continuityId,
        'entity_key': entityKey,
        'normalized_alias': normalized,
        'display_alias': alias,
        'alias_type': alias == name ? 'name' : 'identity',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<String> _resolveEntityKey(
    DatabaseExecutor db, {
    required String characterId,
    required String continuityId,
    required String name,
  }) async {
    final normalized = _normalizedName(name);
    if (normalized.isEmpty) return '';
    final aliases = await db.query(
      'rp_story_entity_aliases',
      columns: const <String>['entity_key'],
      where: 'character_id = ? AND continuity_id = ? AND normalized_alias = ?',
      whereArgs: <Object?>[characterId, continuityId, normalized],
      distinct: true,
    );
    return aliases.length == 1 ? aliases.first['entity_key']!.toString() : '';
  }

  static Future<void> storeExtraction({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required List<Map<String, Object?>> characters,
    required List<Map<String, Object?>> relationships,
    required List<Message> sourceMessages,
    int? sourceSummaryId,
  }) async {
    if (characters.isEmpty && relationships.isEmpty) return;
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    final sources = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      if (sourceSummaryId != null) {
        final summary = await txn.query(
          'context_summaries',
          columns: const <String>['id'],
          where: "id = ? AND revision_status = 'valid'",
          whereArgs: <Object?>[sourceSummaryId],
          limit: 1,
        );
        if (summary.isEmpty) return;
      }
      // Active means active in the newest archived batch, not permanently.
      await txn.rawUpdate(
        '''
        UPDATE rp_story_characters
        SET tier = CASE WHEN mention_count >= 3 THEN 'common' ELSE 'backstage' END
        WHERE character_id = ? AND continuity_id = ? AND tier = 'active'
        ''',
        <Object?>[characterId, scope],
      );

      for (final candidate in characters.take(characterExtractionLimit)) {
        if (!_supportedBySource(candidate, sources)) continue;
        final name = _text(candidate, 'name');
        final normalized = _normalizedName(name);
        if (normalized.isEmpty) continue;
        final ids = _sourceIds(candidate['source_message_ids']);
        final requestedEntityKey = _text(candidate, 'entity_id');
        var existing =
            requestedEntityKey.isNotEmpty && requestedEntityKey != 'new'
            ? await txn.query(
                'rp_story_characters',
                where:
                    'character_id = ? AND continuity_id = ? AND entity_key = ?',
                whereArgs: <Object?>[characterId, scope, requestedEntityKey],
                limit: 1,
              )
            : <Map<String, Object?>>[];
        if (existing.isEmpty) {
          existing = await txn.query(
            'rp_story_characters',
            where:
                'character_id = ? AND continuity_id = ? AND normalized_name = ?',
            whereArgs: <Object?>[characterId, scope, normalized],
            limit: 1,
          );
        }
        final entityKey = existing.isEmpty
            ? await _nextEntityKey(txn, characterId, scope)
            : (existing.first['entity_key']?.toString().trim().isNotEmpty ==
                      true
                  ? existing.first['entity_key']!.toString()
                  : await _nextEntityKey(txn, characterId, scope));
        final editable = existing.isEmpty || existing.first['user_edited'] != 1;
        final previous = existing.isEmpty ? null : existing.first;
        final internalId = existing.isEmpty
            ? _uuid.v4()
            : existing.first['id']!.toString();
        if (sourceSummaryId != null) {
          await txn.insert(
            'rp_story_projection_revisions',
            <String, Object?>{
              'projection_table': 'character',
              'projection_id': internalId,
              'character_id': characterId,
              'continuity_id': scope,
              'source_summary_id': sourceSummaryId,
              'operation': existing.isEmpty ? 'create' : 'update',
              'snapshot_json': existing.isEmpty
                  ? ''
                  : jsonEncode(existing.first),
              'created_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        final values = <String, Object?>{
          'name': existing.isEmpty ? name : existing.first['name'],
          'aliases_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['aliases_json'],
              candidate['aliases'],
            ),
          ),
          'identities_json': jsonEncode(
            _mergeJsonObjectsByKeys(
              previous?['identities_json'],
              candidate['identities'],
              const <String>['name', 'identity_type'],
            ),
          ),
          'gender': _incomingOrExisting(candidate, 'gender', previous),
          'identity': _incomingOrExisting(candidate, 'identity', previous),
          'relation_to_leads': _incomingOrExisting(
            candidate,
            'relation_to_leads',
            previous,
          ),
          'personality': _incomingOrExisting(
            candidate,
            'personality',
            previous,
          ),
          'appearance': _incomingOrExisting(candidate, 'appearance', previous),
          'first_scene': _incomingOrExisting(
            candidate,
            'first_scene',
            previous,
          ),
          'faction': _incomingOrExisting(candidate, 'faction', previous),
          'core_motivation': _incomingOrExisting(
            candidate,
            'core_motivation',
            previous,
          ),
          'current_stance': _incomingOrExisting(
            candidate,
            'current_stance',
            previous,
          ),
          'recurrence':
              const <String>{
                'one_off',
                'recurring',
                'unknown',
              }.contains(_text(candidate, 'recurrence'))
              ? _text(candidate, 'recurrence')
              : (previous?['recurrence']?.toString() ?? 'unknown'),
          'tier': 'active',
          'last_seen_at': now,
          'source_conversation_id': sourceConversationId,
          'source_message_ids': jsonEncode(ids),
          'evidence': _text(candidate, 'evidence'),
          'tags_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['tags_json'],
              candidate['tags'],
            ),
          ),
          'updated_at': now,
        };
        if (existing.isEmpty) {
          await txn.insert('rp_story_characters', <String, Object?>{
            'id': internalId,
            'entity_key': entityKey,
            'character_id': characterId,
            'continuity_id': scope,
            'normalized_name': normalized,
            ...values,
            'mention_count': 1,
            'created_at': now,
          });
        } else {
          final update = editable
              ? values
              : <String, Object?>{
                  'tier': 'active',
                  'last_seen_at': now,
                  'updated_at': now,
                };
          update['mention_count'] =
              (existing.first['mention_count'] as int? ?? 0) + 1;
          await txn.update(
            'rp_story_characters',
            <String, Object?>{'entity_key': entityKey, ...update},
            where: 'id = ?',
            whereArgs: <Object?>[existing.first['id']],
          );
        }
        await _replaceAliases(
          txn,
          characterId: characterId,
          continuityId: scope,
          entityKey: entityKey,
          name: existing.isEmpty ? name : existing.first['name'].toString(),
          aliases: _mergeJsonLists(
            existing.isEmpty ? null : existing.first['aliases_json'],
            candidate['aliases'],
          ).map((value) => value.toString()).toList(growable: false),
          now: now,
        );
      }

      for (final candidate in relationships.take(relationshipExtractionLimit)) {
        if (!_supportedBySource(candidate, sources)) continue;
        final from = _text(candidate, 'from');
        final to = _text(candidate, 'to');
        if (_normalizedName(from).isEmpty || _normalizedName(to).isEmpty) {
          continue;
        }
        final direction =
            const <String>{
              'mutual',
              'from_to',
              'to_from',
            }.contains(_text(candidate, 'direction'))
            ? _text(candidate, 'direction')
            : 'mutual';
        final ids = _sourceIds(candidate['source_message_ids']);
        final requestedFromKey = _text(candidate, 'from_entity_id');
        final requestedToKey = _text(candidate, 'to_entity_id');
        Future<String> resolve(String requested, String fallbackName) async {
          if (RegExp(r'^P-\d{4,}$').hasMatch(requested)) {
            final rows = await txn.query(
              'rp_story_characters',
              columns: const <String>['entity_key'],
              where:
                  'character_id = ? AND continuity_id = ? AND entity_key = ?',
              whereArgs: <Object?>[characterId, scope, requested],
              limit: 1,
            );
            if (rows.isNotEmpty) return requested;
          }
          return _resolveEntityKey(
            txn,
            characterId: characterId,
            continuityId: scope,
            name: fallbackName,
          );
        }

        final fromEntityKey = await resolve(requestedFromKey, from);
        final toEntityKey = await resolve(requestedToKey, to);
        final normalizedParties = <String>[
          fromEntityKey.isNotEmpty ? fromEntityKey : _normalizedName(from),
          toEntityKey.isNotEmpty ? toEntityKey : _normalizedName(to),
        ];
        if (direction == 'mutual') normalizedParties.sort();
        final edge =
            '${normalizedParties[0]}|${normalizedParties[1]}|$direction';
        final existing = await txn.query(
          'rp_story_relationships',
          where:
              'character_id = ? AND continuity_id = ? AND normalized_edge = ?',
          whereArgs: <Object?>[characterId, scope, edge],
          limit: 1,
        );
        final relationshipId = existing.isEmpty
            ? _uuid.v4()
            : existing.first['id']!.toString();
        if (sourceSummaryId != null) {
          await txn.insert(
            'rp_story_projection_revisions',
            <String, Object?>{
              'projection_table': 'relationship',
              'projection_id': relationshipId,
              'character_id': characterId,
              'continuity_id': scope,
              'source_summary_id': sourceSummaryId,
              'operation': existing.isEmpty ? 'create' : 'update',
              'snapshot_json': existing.isEmpty
                  ? ''
                  : jsonEncode(existing.first),
              'created_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        final storedOrigin = existing.isEmpty
            ? ''
            : _text(existing.first, 'origin');
        final extractedOrigin = _text(candidate, 'origin');
        final values = <String, Object?>{
          'from_name': from,
          'to_name': to,
          'from_entity_key': fromEntityKey,
          'to_entity_key': toEntityKey,
          'direction': direction,
          'current_relation': _incomingOrExisting(
            candidate,
            'current_relation',
            existing.isEmpty ? null : existing.first,
          ),
          // The origin is the first supported reason these people met or
          // became connected. Later turns belong in change/history and must
          // not silently replace that foundation.
          'origin': storedOrigin.isNotEmpty ? storedOrigin : extractedOrigin,
          'closeness_catalyst':
              existing.isNotEmpty &&
                  _text(existing.first, 'closeness_catalyst').isNotEmpty
              ? _text(existing.first, 'closeness_catalyst')
              : _text(candidate, 'closeness_catalyst'),
          'forms_of_address_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['forms_of_address_json'],
              candidate['forms_of_address'],
            ),
          ),
          'shared_secrets_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['shared_secrets_json'],
              candidate['shared_secrets'],
            ),
          ),
          'conflicts_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['conflicts_json'],
              candidate['conflicts'],
            ),
          ),
          'knowledge_scope_json': jsonEncode(
            _mergeJsonLists(
              existing.isEmpty ? null : existing.first['knowledge_scope_json'],
              candidate['knowledge_scope'],
            ),
          ),
          'visibility':
              const <String>{
                'public',
                'hidden',
                'one_sided',
                'unknown',
              }.contains(_text(candidate, 'visibility'))
              ? _text(candidate, 'visibility')
              : (existing.isEmpty ? 'unknown' : existing.first['visibility']),
          'story_time': _incomingOrExisting(
            candidate,
            'story_time',
            existing.isEmpty ? null : existing.first,
          ),
          'source_conversation_id': sourceConversationId,
          'source_message_ids': jsonEncode(ids),
          'source_summary_id': sourceSummaryId,
          'evidence': _text(candidate, 'evidence'),
          'updated_at': now,
        };
        if (existing.isEmpty) {
          await txn.insert('rp_story_relationships', <String, Object?>{
            'id': relationshipId,
            'character_id': characterId,
            'continuity_id': scope,
            'normalized_edge': edge,
            ...values,
            'created_at': now,
          });
        } else if (existing.first['user_edited'] != 1) {
          await txn.update(
            'rp_story_relationships',
            values,
            where: 'id = ?',
            whereArgs: <Object?>[relationshipId],
          );
        }
        final change = _text(candidate, 'change');
        if (change.isNotEmpty) {
          final duplicate = await txn.query(
            'rp_story_relationship_events',
            where: 'relationship_id = ? AND change_text = ? AND evidence = ?',
            whereArgs: <Object?>[
              relationshipId,
              change,
              _text(candidate, 'evidence'),
            ],
            limit: 1,
          );
          if (duplicate.isEmpty) {
            await txn.insert('rp_story_relationship_events', <String, Object?>{
              'id': _uuid.v4(),
              'relationship_id': relationshipId,
              'character_id': characterId,
              'continuity_id': scope,
              'change_text': change,
              'story_time': _text(candidate, 'story_time'),
              'source_conversation_id': sourceConversationId,
              'source_message_ids': jsonEncode(ids),
              'source_summary_id': sourceSummaryId,
              'evidence': _text(candidate, 'evidence'),
              'created_at': now,
            });
          }
        }
      }
    });
  }

  static Future<List<Map<String, dynamic>>> listCharacters(
    String characterId, {
    String continuityId = 'main',
    String query = '',
  }) async {
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    final needle = query.trim();
    return db.query(
      'rp_story_characters',
      where: needle.isEmpty
          ? 'character_id = ? AND continuity_id = ?'
          : 'character_id = ? AND continuity_id = ? AND '
                '(name LIKE ? OR aliases_json LIKE ? OR identity LIKE ? OR faction LIKE ?)',
      whereArgs: needle.isEmpty
          ? <Object?>[characterId, scope]
          : <Object?>[
              characterId,
              scope,
              '%$needle%',
              '%$needle%',
              '%$needle%',
              '%$needle%',
            ],
      orderBy:
          "is_important DESC, CASE tier WHEN 'active' THEN 0 WHEN 'common' THEN 1 ELSE 2 END, last_seen_at DESC",
    );
  }

  static Future<List<Map<String, dynamic>>> listRelationships(
    String characterId, {
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'rp_story_relationships',
      where: 'character_id = ? AND continuity_id = ?',
      whereArgs: <Object?>[characterId, _scope(continuityId)],
      orderBy: 'updated_at DESC',
    );
  }

  static Future<List<Map<String, dynamic>>> relationshipEvents(
    String relationshipId,
  ) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'rp_story_relationship_events',
      where: 'relationship_id = ?',
      whereArgs: <Object?>[relationshipId],
      orderBy: 'created_at ASC',
    );
  }

  static Future<int> setImportant(String id, bool important) async {
    final db = await DatabaseHelper.database;
    final target = await db.query(
      'rp_story_characters',
      columns: <String>['character_id', 'continuity_id'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (target.isEmpty) return 0;
    await db.update(
      'rp_story_characters',
      <String, Object?>{
        'is_important': important ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM rp_story_characters '
      'WHERE character_id = ? AND continuity_id = ? AND is_important = 1',
      <Object?>[target.first['character_id'], target.first['continuity_id']],
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  static Future<void> updateCharacter(
    String id, {
    required String identity,
    required String relationToLeads,
    required String personality,
    required String appearance,
    required String faction,
  }) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'rp_story_characters',
      <String, Object?>{
        'identity': identity.trim(),
        'relation_to_leads': relationToLeads.trim(),
        'personality': personality.trim(),
        'appearance': appearance.trim(),
        'faction': faction.trim(),
        'user_edited': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  static Future<void> updateRelationship(
    String id, {
    required String currentRelation,
    required String origin,
    required String visibility,
  }) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'rp_story_relationships',
      <String, Object?>{
        'current_relation': currentRelation.trim(),
        'origin': origin.trim(),
        'visibility': visibility.trim(),
        'user_edited': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  static Future<String> recallPrompt(
    String characterId,
    String currentText, {
    String continuityId = 'main',
    int tokenBudget = defaultTokenBudget,
  }) async {
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    // sqflite returns a read-only QueryResultSet. Sorting it in place throws
    // before the provider request is sent, which used to surface misleadingly
    // as a Gemini request failure.
    final characters = List<Map<String, dynamic>>.of(
      await listCharacters(characterId, continuityId: scope),
      growable: true,
    );
    if (characters.isEmpty) return '';
    final relationships = await listRelationships(
      characterId,
      continuityId: scope,
    );
    final needle = currentText.toLowerCase();
    Iterable<String> termsFor(Map<String, dynamic> row) =>
        <String>[
              row['name']?.toString() ?? '',
              row['identity']?.toString() ?? '',
              row['faction']?.toString() ?? '',
              ..._decodeStringList(row['aliases_json']),
              ..._decodeStringList(row['tags_json']),
            ]
            .map((term) => term.trim().toLowerCase())
            .where((term) => term.length >= 2);

    bool isRelevant(Map<String, dynamic> row) =>
        needle.isNotEmpty && termsFor(row).any(needle.contains);

    int score(Map<String, dynamic> row) {
      var value = row['is_important'] == 1 ? 35 : 0;
      value += switch (row['tier']) {
        'active' => 30,
        'common' => 15,
        _ => 0,
      };
      if ((row['mention_count'] as int? ?? 0) >= 5) value += 20;
      if (isRelevant(row)) {
        value += 80;
      }
      return value;
    }

    characters.sort((a, b) => score(b).compareTo(score(a)));
    final full = characters
        .where(
          (row) =>
              isRelevant(row) ||
              row['tier'] == 'active' ||
              (row['mention_count'] as int? ?? 0) >= 5,
        )
        .take(fullProfileLimit)
        .toList(growable: false);
    final fullIds = full.map((row) => row['id']).toSet();
    final compact = characters
        .where(
          (row) =>
              !fullIds.contains(row['id']) &&
              (isRelevant(row) ||
                  row['tier'] == 'active' ||
                  row['tier'] == 'common'),
        )
        .take(compactProfileLimit)
        .toList(growable: false);
    final selectedEntityKeys = <Map<String, dynamic>>[...full, ...compact]
        .map((row) => row['entity_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();

    final completedRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS total
      FROM messages AS m
      INNER JOIN conversations AS c ON c.id = m.conversation_id
      WHERE c.character_id = ? AND c.context_mode = 'rp'
        AND c.continuity_id = ? AND m.is_user = 0
      ''',
      <Object?>[characterId, scope],
    );
    final completedTurns = (completedRows.first['total'] as int?) ?? 0;
    final includeBackstageRoster =
        completedTurns > 0 && completedTurns % 30 == 0;
    final alreadySelected = <Object?>{
      ...full.map((row) => row['id']),
      ...compact.map((row) => row['id']),
    };
    final backstageRoster = <Map<String, dynamic>>[];
    if (includeBackstageRoster) {
      final candidates = characters
          .where(
            (row) =>
                row['tier'] == 'backstage' &&
                isRelevant(row) &&
                !alreadySelected.contains(row['id']),
          )
          .toList(growable: false);
      if (candidates.isNotEmpty) {
        final offset = (((completedTurns ~/ 30) - 1) * 15) % candidates.length;
        for (var index = 0; index < 15 && index < candidates.length; index++) {
          backstageRoster.add(candidates[(offset + index) % candidates.length]);
        }
      }
    }
    if (full.isEmpty && compact.isEmpty && backstageRoster.isEmpty) return '';

    final out = StringBuffer()
      ..writeln(
        L.pick(
          en: '【Story Character Reference】Reference data only. Do not introduce a character unless the current scene naturally requires it.',
          zhTW: '【劇情人物參考】以下僅為連貫性資料，不得因載入資料而主動讓角色登場。',
          zhCN: '【剧情人物参考】以下仅为连贯性资料，不得因载入资料而主动让角色登场。',
        ),
      );
    for (final row in full) {
      out
        ..writeln('— ${row['name']} —')
        ..writeln(
          <Object?>[
                row['gender'],
                row['identity'],
                row['relation_to_leads'],
                row['personality'],
                row['appearance'],
                row['faction'],
                row['core_motivation'],
                row['current_stance'],
              ]
              .map((value) => value?.toString().trim() ?? '')
              .where((v) => v.isNotEmpty)
              .join(' · '),
        );
    }
    if (compact.isNotEmpty) {
      out.writeln(
        '${L.pick(en: 'Related cast', zhTW: '相關人物', zhCN: '相关人物')}：'
        '${compact.map((row) => '${row['name']}（${row['identity']}／${row['relation_to_leads']}）').join('；')}',
      );
    }
    for (final relation in relationships) {
      if (!selectedEntityKeys.contains(relation['from_entity_key']) &&
          !selectedEntityKeys.contains(relation['to_entity_key'])) {
        continue;
      }
      out.writeln(
        '${relation['from_name']} → ${relation['to_name']}：'
        '${relation['current_relation']}；'
        '${L.pick(en: 'origin', zhTW: '形成經過', zhCN: '形成经过')}：${relation['origin']}；'
        '${L.pick(en: 'closeness catalyst', zhTW: '靠近契機', zhCN: '靠近契机')}：${relation['closeness_catalyst']}',
      );
    }
    if (backstageRoster.isNotEmpty) {
      final backstage = backstageRoster
          .map((row) => '${row['name']}（${row['identity']}）')
          .join('、');
      out.writeln(
        '${L.pick(en: 'Backstage roster', zhTW: '候場角色名冊', zhCN: '候场角色名册')}：$backstage',
      );
    }

    final lines = out.toString().trim().split('\n');
    final bounded = StringBuffer();
    for (final line in lines) {
      final candidate = bounded.isEmpty ? line : '${bounded.toString()}\n$line';
      if (TokenEstimator.estimate(candidate) > tokenBudget) break;
      if (bounded.isNotEmpty) bounded.writeln();
      bounded.write(line);
    }
    return bounded.toString().trim();
  }

  static List<String> _decodeStringList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    try {
      return _strings(jsonDecode(raw));
    } catch (_) {
      return const <String>[];
    }
  }
}
