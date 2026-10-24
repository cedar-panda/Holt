import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../models/message.dart';
import 'locale_strings.dart';
import 'token_estimator.dart';

class RpStoryExtractionReport {
  final int characterSubmitted;
  final int characterCreated;
  final int characterUpdated;
  final int characterRejectedMissingSource;
  final int characterRejectedEvidenceMismatch;
  final int characterEntityIdMismatch;
  final int relationshipSubmitted;
  final int relationshipStored;
  final int relationshipRejectedMissingSource;
  final int relationshipRejectedEvidenceMismatch;
  final int relationshipRejectedMissingParties;
  final int relationshipProtectedByUserEdit;
  final bool sourceSummaryInvalid;

  const RpStoryExtractionReport({
    this.characterSubmitted = 0,
    this.characterCreated = 0,
    this.characterUpdated = 0,
    this.characterRejectedMissingSource = 0,
    this.characterRejectedEvidenceMismatch = 0,
    this.characterEntityIdMismatch = 0,
    this.relationshipSubmitted = 0,
    this.relationshipStored = 0,
    this.relationshipRejectedMissingSource = 0,
    this.relationshipRejectedEvidenceMismatch = 0,
    this.relationshipRejectedMissingParties = 0,
    this.relationshipProtectedByUserEdit = 0,
    this.sourceSummaryInvalid = false,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'characterSubmitted': characterSubmitted,
    'characterCreated': characterCreated,
    'characterUpdated': characterUpdated,
    'characterRejectedMissingSource': characterRejectedMissingSource,
    'characterRejectedEvidenceMismatch': characterRejectedEvidenceMismatch,
    'characterEntityIdMismatch': characterEntityIdMismatch,
    'submitted': relationshipSubmitted,
    'stored': relationshipStored,
    'rejectedMissingSource': relationshipRejectedMissingSource,
    'rejectedEvidenceMismatch': relationshipRejectedEvidenceMismatch,
    'rejectedMissingParties': relationshipRejectedMissingParties,
    'protectedByUserEdit': relationshipProtectedByUserEdit,
    'sourceSummaryInvalid': sourceSummaryInvalid,
  };
}

enum _SourceSupportFailure { missingSource, evidenceMismatch }

/// Persistence and request-only recall for RP story characters and relations.
/// Every query is scoped by the parent character card and continuity id so a
/// future multi-story UI can switch lanes without migrating these records.
abstract final class RpStoryService {
  static const Uuid _uuid = Uuid();
  static const int characterExtractionLimit = 24;
  static const int relationshipExtractionLimit = 8;
  static const int fullProfileLimit = 3;
  static const int compactProfileLimit = 6;
  static const int defaultTokenBudget = 1000;
  static final Map<String, RpStoryExtractionReport> _latestExtractionReports =
      <String, RpStoryExtractionReport>{};
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void _notifyChanged() => revision.value += 1;

  static String _scope(String value) =>
      value.trim().isEmpty ? 'main' : value.trim();

  static String _normalizedName(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

  static List<int> _sourceIds(Object? raw) {
    Object? normalized = raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        normalized = jsonDecode(raw);
      } catch (_) {
        normalized = raw
            .split(RegExp(r'[,，\s]+'))
            .where((value) => value.trim().isNotEmpty)
            .toList(growable: false);
      }
    }
    if (normalized is! List) return const <int>[];
    return normalized
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

  static String _firstText(Map<String, Object?> row, Iterable<String> keys) {
    for (final key in keys) {
      final value = _text(row, key);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _normalizedEvidence(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

  /// Returns true when [name] (≥2 chars after normalisation) appears in at
  /// least one source message's text. Used as a relaxed gate for brand-new
  /// character candidates whose evidence excerpt didn't pass verbatim check.
  static bool _nameAppearsInSources(String name, Iterable<Message> sources) {
    final normalized = name.trim().toLowerCase();
    if (normalized.length < 2) return false;
    return sources.any(
      (message) => message.text.toLowerCase().contains(normalized),
    );
  }

  static bool _sourceExplicitlyLinksIdentity({
    required String existingName,
    required String candidateName,
    required Iterable<Message> sources,
  }) {
    final left = existingName.trim();
    final right = candidateName.trim();
    if (left.isEmpty || right.isEmpty) return false;
    final patterns = <String>[
      '$left以$right之名',
      '$left又名$right',
      '$left本名$right',
      '$left即$right',
      '$left就是$right',
      '$right是$left的化名',
      '$right是$left的本名',
      '$right即$left',
      '$right就是$left',
    ];
    return sources.any((message) {
      final text = message.text.replaceAll(RegExp(r'\s+'), '');
      return patterns.any(text.contains);
    });
  }

  static List<int> _supportedSourceIds(
    Map<String, Object?> candidate,
    Map<int, Message> sources,
  ) {
    final explicit = _sourceIds(candidate['source_message_ids']);
    if (explicit.isNotEmpty) return explicit;

    // Structured-output support varies between providers. If the model omits
    // only the id but supplies a genuinely verbatim excerpt, infer the source
    // from one unambiguous message in the batch. Paraphrases and ambiguous
    // matches remain rejected.
    final evidence = _text(candidate, 'evidence');
    final normalizedEvidence = _normalizedEvidence(evidence);
    if (evidence.isEmpty || normalizedEvidence.length < 4) {
      return const <int>[];
    }
    final matches = sources.entries
        .where((entry) {
          final text = entry.value.text;
          return text.contains(evidence) ||
              _normalizedEvidence(text).contains(normalizedEvidence);
        })
        .map((entry) => entry.key)
        .toList(growable: false);
    return matches.length == 1 ? matches : const <int>[];
  }

  static _SourceSupportFailure? _sourceSupportFailure(
    Map<String, Object?> candidate,
    Map<int, Message> sources,
  ) {
    final ids = _supportedSourceIds(candidate, sources);
    final evidence = _text(candidate, 'evidence');
    if (ids.isEmpty || evidence.isEmpty || !ids.every(sources.containsKey)) {
      return _SourceSupportFailure.missingSource;
    }
    final citedTexts = ids
        .map((id) => sources[id]!.text)
        .toList(growable: false);
    if (citedTexts.any((text) => text.contains(evidence))) return null;

    // Providers often normalize quotes, spaces, and punctuation in an
    // otherwise verbatim excerpt. Accept that transport-only difference,
    // including an excerpt crossing two explicitly cited messages, while
    // still rejecting semantic paraphrases and unsupported claims.
    final normalizedEvidence = _normalizedEvidence(evidence);
    if (normalizedEvidence.length < 4) {
      return _SourceSupportFailure.evidenceMismatch;
    }
    final normalizedTexts = citedTexts
        .map(_normalizedEvidence)
        .toList(growable: false);
    if (normalizedTexts.any((text) => text.contains(normalizedEvidence))) {
      return null;
    }
    return normalizedTexts.join().contains(normalizedEvidence)
        ? null
        : _SourceSupportFailure.evidenceMismatch;
  }

  static String _reportKey(String characterId, String continuityId) =>
      '$characterId|${_scope(continuityId)}';

  static RpStoryExtractionReport? latestExtractionReport(
    String characterId, {
    String continuityId = 'main',
  }) => _latestExtractionReports[_reportKey(characterId, continuityId)];

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

  static Future<RpStoryExtractionReport> storeExtraction({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required List<Map<String, Object?>> characters,
    required List<Map<String, Object?>> relationships,
    required List<Message> sourceMessages,
    int? sourceSummaryId,
  }) async {
    var characterCreated = 0;
    var characterUpdated = 0;
    var characterRejectedMissingSource = 0;
    var characterRejectedEvidenceMismatch = 0;
    var characterEntityIdMismatch = 0;
    var relationshipStored = 0;
    var rejectedMissingSource = 0;
    var rejectedEvidenceMismatch = 0;
    var rejectedMissingParties = 0;
    var protectedByUserEdit = 0;
    var sourceSummaryInvalid = false;
    final characterSubmitted = characters.take(characterExtractionLimit).length;
    final submitted = relationships.take(relationshipExtractionLimit).length;
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    final sources = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final now = DateTime.now().toIso8601String();

    // A rolling dossier may legitimately refer to an older source message
    // from another window in the same storyline. The model has seen that id
    // through the prior dossier, but the current compression batch only
    // carries the newest raw messages. Rehydrate only explicitly cited ids
    // that belong to this character + RP storyline, then apply the same exact
    // evidence check below. This closes the false "missing source" drop
    // without accepting unsupported or cross-story claims.
    final citedIds = <int>{
      for (final candidate in <Map<String, Object?>>[
        ...characters.take(characterExtractionLimit),
        ...relationships.take(relationshipExtractionLimit),
      ])
        ..._sourceIds(candidate['source_message_ids']),
    };
    final missingIds = citedIds.difference(sources.keys.toSet()).toList();
    if (missingIds.isNotEmpty) {
      final placeholders = List.filled(missingIds.length, '?').join(',');
      final rows = await db.rawQuery(
        '''
        SELECT m.*
        FROM messages m
        INNER JOIN conversations c ON c.id = m.conversation_id
        WHERE m.id IN ($placeholders)
          AND c.character_id = ?
          AND c.context_mode = 'rp'
          AND c.continuity_id = ?
        ''',
        <Object?>[...missingIds, characterId, scope],
      );
      for (final row in rows) {
        final message = Message.fromMap(row);
        if (message.id != null) sources[message.id!] = message;
      }
    }

    await db.transaction((txn) async {
      if (sourceSummaryId != null) {
        final summary = await txn.query(
          'context_summaries',
          columns: const <String>['id'],
          where: "id = ? AND revision_status = 'valid'",
          whereArgs: <Object?>[sourceSummaryId],
          limit: 1,
        );
        if (summary.isEmpty) {
          sourceSummaryInvalid = true;
          return;
        }
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
        final supportFailure = _sourceSupportFailure(candidate, sources);
        if (supportFailure != null) {
          // For brand-new characters the model may paraphrase the evidence
          // slightly. As long as the character name actually appears in at
          // least one source message, allow creation — the name-in-source
          // check is strong enough to prevent hallucinated entries.
          final isNewCandidate =
              _text(candidate, 'entity_id').isEmpty ||
              _text(candidate, 'entity_id') == 'new';
          final nameInSource = _nameAppearsInSources(
            _text(candidate, 'name'),
            sources.values,
          );
          if (!isNewCandidate || !nameInSource) {
            if (supportFailure == _SourceSupportFailure.missingSource) {
              characterRejectedMissingSource += 1;
            } else {
              characterRejectedEvidenceMismatch += 1;
            }
            developer.log(
              'Dropped RP character candidate without valid source evidence: '
              '${_text(candidate, 'name')}',
              name: 'RpStoryService',
            );
            continue;
          }
          developer.log(
            'Relaxed evidence check for new character whose name appears '
            'in source: ${_text(candidate, 'name')}',
            name: 'RpStoryService',
          );
        }
        final name = _text(candidate, 'name');
        final normalized = _normalizedName(name);
        if (normalized.isEmpty) continue;
        var ids = _supportedSourceIds(candidate, sources);
        // When the relaxed evidence path accepted this candidate, ids may be
        // empty. Fall back to every source message that mentions the name.
        if (ids.isEmpty && name.isNotEmpty) {
          final lowerName = name.toLowerCase();
          ids = sources.entries
              .where((e) => e.value.text.toLowerCase().contains(lowerName))
              .map((e) => e.key)
              .toList(growable: false);
        }
        final requestedEntityKey = _text(candidate, 'entity_id');
        var existing = <Map<String, Object?>>[];
        if (requestedEntityKey.isNotEmpty && requestedEntityKey != 'new') {
          final requested = await txn.query(
            'rp_story_characters',
            where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
            whereArgs: <Object?>[characterId, scope, requestedEntityKey],
            limit: 1,
          );
          if (requested.isNotEmpty) {
            final aliases = await txn.query(
              'rp_story_entity_aliases',
              columns: const <String>['entity_key'],
              where:
                  'character_id = ? AND continuity_id = ? AND entity_key = ? AND normalized_alias = ?',
              whereArgs: <Object?>[
                characterId,
                scope,
                requestedEntityKey,
                normalized,
              ],
              limit: 1,
            );
            final baseNameMatches =
                requested.first['normalized_name']?.toString() == normalized;
            final explicitlyLinked = _sourceExplicitlyLinksIdentity(
              existingName: requested.first['name']?.toString() ?? '',
              candidateName: name,
              sources: ids.map((id) => sources[id]).whereType<Message>(),
            );
            if (baseNameMatches || aliases.isNotEmpty || explicitlyLinked) {
              existing = requested;
            } else {
              characterEntityIdMismatch += 1;
              developer.log(
                'Ignored mismatched RP character entity id: '
                '$requestedEntityKey was supplied for $name',
                name: 'RpStoryService',
              );
            }
          }
        }
        if (existing.isEmpty) {
          final resolvedEntityKey = await _resolveEntityKey(
            txn,
            characterId: characterId,
            continuityId: scope,
            name: name,
          );
          if (resolvedEntityKey.isNotEmpty) {
            existing = await txn.query(
              'rp_story_characters',
              where:
                  'character_id = ? AND continuity_id = ? AND entity_key = ?',
              whereArgs: <Object?>[characterId, scope, resolvedEntityKey],
              limit: 1,
            );
          }
        }
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
          characterCreated += 1;
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
          characterUpdated += 1;
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
        final supportFailure = _sourceSupportFailure(candidate, sources);
        if (supportFailure != null) {
          if (supportFailure == _SourceSupportFailure.missingSource) {
            rejectedMissingSource += 1;
          } else {
            rejectedEvidenceMismatch += 1;
          }
          developer.log(
            'Dropped RP relationship candidate: ${supportFailure.name}; '
            '${_text(candidate, 'from')} -> ${_text(candidate, 'to')}',
            name: 'RpStoryService',
          );
          continue;
        }
        final requestedFromKey = _firstText(candidate, const <String>[
          'from_entity_id',
          'from_entity_key',
        ]);
        final requestedToKey = _firstText(candidate, const <String>[
          'to_entity_id',
          'to_entity_key',
        ]);

        Future<String> entityName(String requested) async {
          if (!RegExp(r'^P-\d{4,}$').hasMatch(requested)) return '';
          final rows = await txn.query(
            'rp_story_characters',
            columns: const <String>['name'],
            where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
            whereArgs: <Object?>[characterId, scope, requested],
            limit: 1,
          );
          return rows.isEmpty
              ? ''
              : rows.first['name']?.toString().trim() ?? '';
        }

        var from = _firstText(candidate, const <String>['from', 'from_name']);
        var to = _firstText(candidate, const <String>['to', 'to_name']);
        if (from.isEmpty) from = await entityName(requestedFromKey);
        if (to.isEmpty) to = await entityName(requestedToKey);
        if (_normalizedName(from).isEmpty || _normalizedName(to).isEmpty) {
          rejectedMissingParties += 1;
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
        final ids = _supportedSourceIds(candidate, sources);
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
          final resolved = await _resolveEntityKey(
            txn,
            characterId: characterId,
            continuityId: scope,
            name: fallbackName,
          );
          if (resolved.isNotEmpty) return resolved;

          // A relationship candidate is already source-validated. When the
          // model omits the matching story_characters item, preserve a minimal
          // anchor rather than storing an unlinked edge that never appears in
          // the character list.
          final normalized = _normalizedName(fallbackName);
          final existingByName = await txn.query(
            'rp_story_characters',
            columns: const <String>['entity_key'],
            where:
                'character_id = ? AND continuity_id = ? AND normalized_name = ?',
            whereArgs: <Object?>[characterId, scope, normalized],
            limit: 1,
          );
          if (existingByName.isNotEmpty) {
            final key = existingByName.first['entity_key']!.toString();
            await _replaceAliases(
              txn,
              characterId: characterId,
              continuityId: scope,
              entityKey: key,
              name: fallbackName,
              aliases: const <String>[],
              now: now,
            );
            return key;
          }

          final key = await _nextEntityKey(txn, characterId, scope);
          await txn.insert('rp_story_characters', <String, Object?>{
            'id': _uuid.v4(),
            'entity_key': key,
            'character_id': characterId,
            'continuity_id': scope,
            'normalized_name': normalized,
            'name': fallbackName,
            'tier': 'active',
            'mention_count': 1,
            'last_seen_at': now,
            'source_conversation_id': sourceConversationId,
            'source_message_ids': jsonEncode(ids),
            'evidence': _text(candidate, 'evidence'),
            'created_at': now,
            'updated_at': now,
          });
          await _replaceAliases(
            txn,
            characterId: characterId,
            continuityId: scope,
            entityKey: key,
            name: fallbackName,
            aliases: const <String>[],
            now: now,
          );
          return key;
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
          relationshipStored += 1;
        } else if (existing.first['user_edited'] != 1) {
          await txn.update(
            'rp_story_relationships',
            values,
            where: 'id = ?',
            whereArgs: <Object?>[relationshipId],
          );
          relationshipStored += 1;
        } else {
          protectedByUserEdit += 1;
        }
        final change = _text(candidate, 'change');
        var storedNewEvent = false;
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
            storedNewEvent = true;
          }
        }
        if (existing.isNotEmpty &&
            existing.first['user_edited'] == 1 &&
            storedNewEvent) {
          // Manual edits protect the user's canonical relationship wording,
          // but must not freeze the card in time. Keep the protected fields
          // intact while advancing provenance/order so the latest supported
          // relationship event remains visible in the UI.
          await txn.update(
            'rp_story_relationships',
            <String, Object?>{
              'source_conversation_id': sourceConversationId,
              'source_message_ids': jsonEncode(ids),
              'source_summary_id': sourceSummaryId,
              'evidence': _text(candidate, 'evidence'),
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: <Object?>[relationshipId],
          );
        }
      }
    });
    final report = RpStoryExtractionReport(
      characterSubmitted: characterSubmitted,
      characterCreated: characterCreated,
      characterUpdated: characterUpdated,
      characterRejectedMissingSource: characterRejectedMissingSource,
      characterRejectedEvidenceMismatch: characterRejectedEvidenceMismatch,
      characterEntityIdMismatch: characterEntityIdMismatch,
      relationshipSubmitted: submitted,
      relationshipStored: relationshipStored,
      relationshipRejectedMissingSource: rejectedMissingSource,
      relationshipRejectedEvidenceMismatch: rejectedEvidenceMismatch,
      relationshipRejectedMissingParties: rejectedMissingParties,
      relationshipProtectedByUserEdit: protectedByUserEdit,
      sourceSummaryInvalid: sourceSummaryInvalid,
    );
    _latestExtractionReports[_reportKey(characterId, scope)] = report;
    developer.log(
      'RP story extraction: ${report.toJson()}',
      name: 'RpStoryService',
    );
    if (characters.isNotEmpty || relationships.isNotEmpty) _notifyChanged();
    return report;
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
    return db.rawQuery(
      '''
SELECT
  relation.*,
  latest.change_text AS latest_change,
  latest.story_time AS latest_change_story_time,
  latest.created_at AS latest_change_at
FROM rp_story_relationships AS relation
LEFT JOIN rp_story_relationship_events AS latest
  ON latest.id = (
    SELECT event.id
    FROM rp_story_relationship_events AS event
    WHERE event.relationship_id = relation.id
    ORDER BY event.created_at DESC, event.rowid DESC
    LIMIT 1
  )
WHERE relation.character_id = ? AND relation.continuity_id = ?
ORDER BY COALESCE(latest.created_at, relation.updated_at) DESC
''',
      <Object?>[characterId, _scope(continuityId)],
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
    _notifyChanged();
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
    _notifyChanged();
  }

  static Future<void> updateRelationship(
    String id, {
    required String currentRelation,
    required String origin,
    required String visibility,
  }) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'rp_story_relationships',
      columns: const <String>['current_relation', 'origin', 'visibility'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (existing.isEmpty) return;
    final nextCurrentRelation = currentRelation.trim();
    final nextOrigin = origin.trim();
    final nextVisibility = visibility.trim();
    final unchanged =
        _text(existing.first, 'current_relation') == nextCurrentRelation &&
        _text(existing.first, 'origin') == nextOrigin &&
        _text(existing.first, 'visibility') == nextVisibility;
    if (unchanged) return;
    await db.update(
      'rp_story_relationships',
      <String, Object?>{
        'current_relation': nextCurrentRelation,
        'origin': nextOrigin,
        'visibility': nextVisibility,
        'user_edited': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    _notifyChanged();
  }

  static Future<String> recallPrompt(
    String characterId,
    String currentText, {
    String continuityId = 'main',
    int tokenBudget = defaultTokenBudget,
    List<Message> recentMessages = const <Message>[],
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
    final recentNarrative = recentMessages.reversed
        .where((message) => !message.isIncomplete)
        .map((message) => message.promptVisibleText.trim())
        .where((text) => text.isNotEmpty)
        .take(3)
        .toList(growable: false)
        .reversed;
    final sceneNeedle = <String>[
      currentText,
      ...recentNarrative,
    ].join('\n').toLowerCase();
    Iterable<String> termsFor(Map<String, dynamic> row) =>
        <String>[
              row['name']?.toString() ?? '',
              ..._decodeStringList(row['aliases_json']),
            ]
            .map((term) => term.trim().toLowerCase())
            .where((term) => term.length >= 2);

    bool isRelevant(Map<String, dynamic> row) =>
        sceneNeedle.isNotEmpty && termsFor(row).any(sceneNeedle.contains);

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
        .where(isRelevant)
        .take(fullProfileLimit)
        .toList(growable: false);
    final fullIds = full.map((row) => row['id']).toSet();
    final compact = characters
        .where(
          (row) =>
              !fullIds.contains(row['id']) &&
              (isRelevant(row) ||
                  row['tier'] == 'active' ||
                  row['tier'] == 'common' ||
                  (row['mention_count'] as int? ?? 0) >= 5),
        )
        .take(compactProfileLimit)
        .toList(growable: false);
    final selectedEntityKeys = <Map<String, dynamic>>[...full, ...compact]
        .map((row) => row['entity_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    final appearingEntityKeys = characters
        .where(isRelevant)
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
          en: '【Story Cast】Continuity reference only. Offstage cast must not enter merely because they are listed.',
          zhTW: '【劇情人物】僅供連貫；未在最新正文出場者不得因此登場。',
          zhCN: '【剧情人物】仅供连贯；未在最新正文出场者不得因此登场。',
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
    var includedNewestOffstageRelationship = false;
    final includedRelationshipPairs = <String>{};
    for (final relation in relationships) {
      final fromKey = relation['from_entity_key']?.toString() ?? '';
      final toKey = relation['to_entity_key']?.toString() ?? '';
      if (!selectedEntityKeys.contains(fromKey) &&
          !selectedEntityKeys.contains(toKey)) {
        continue;
      }
      final direction = relation['direction']?.toString() ?? '';
      final pairKey = direction == 'mutual'
          ? (<String>[fromKey, toKey]..sort()).join('|')
          : '$fromKey|$toKey';
      // Historical imports and early summary passes could create more than
      // one row for the same pair. listRelationships is newest-first, so the
      // first row is the effective one for prompt injection.
      if (!includedRelationshipPairs.add('$direction|$pairKey')) continue;
      final involvesAppearing =
          appearingEntityKeys.contains(fromKey) ||
          appearingEntityKeys.contains(toKey);
      if (!involvesAppearing) {
        // listRelationships is newest-first. For cast who are not in the
        // recent narrative, retain only the single newest relation instead of
        // sending the offstage social graph on every turn.
        if (includedNewestOffstageRelationship) continue;
        includedNewestOffstageRelationship = true;
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
