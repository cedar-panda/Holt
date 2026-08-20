import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import '../models/memory.dart';
import '../models/memory_action_proposal.dart';
import 'locale_strings.dart';
import 'memory_duplicate_detector.dart';

enum GuardedMemoryWriteDisposition {
  inserted,
  skippedDuplicate,
  proposalCreated,
}

class GuardedMemoryWriteResult {
  final GuardedMemoryWriteDisposition disposition;
  final int? memoryId;
  final int? existingMemoryId;
  final String? proposalId;
  final double duplicateScore;

  const GuardedMemoryWriteResult({
    required this.disposition,
    this.memoryId,
    this.existingMemoryId,
    this.proposalId,
    this.duplicateScore = 0,
  });
}

class MemoryGuardService {
  static const String createDecisionUseNew = 'use_new';
  static const String createDecisionMerge = 'merge';
  static const String linkDecisionConfirm = 'confirm';
  static const String linkDecisionDefer = 'defer';
  static const _uuid = Uuid();
  static const _reviewStatuses = <String>{
    MemoryActionProposal.statusPending,
    MemoryActionProposal.statusSnoozed,
    MemoryActionProposal.statusFailed,
    MemoryActionProposal.statusStale,
  };
  static const _executableStatuses = <String>{
    MemoryActionProposal.statusPending,
    MemoryActionProposal.statusSnoozed,
    MemoryActionProposal.statusFailed,
  };
  static final RegExp _recordDatePattern = RegExp(
    r'\[\s*(?:(?:\d{2,4})[./-])?\d{1,2}[./-]\d{1,2}\s*\]',
  );

  static bool _requiresManualConfirmation(String source) =>
      source == 'model' || source == 'summary';

  /// The single write gate for every newly extracted or manually entered
  /// memory. Detection, proposal creation and direct insertion share one
  /// SQLite transaction, so concurrent writers cannot both pass the same
  /// pre-insert check.
  static Future<GuardedMemoryWriteResult> guardNewMemory({
    required Memory candidate,
    required String source,
    String? sourceConversationId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<GuardedMemoryWriteResult>((txn) async {
      final rows = await txn.query(
        'memories',
        where: 'character_id = ? AND mode = ? AND status = ?',
        whereArgs: [candidate.characterId, candidate.mode, 'active'],
        orderBy: 'updated_at DESC, id DESC',
      );
      final existing = rows.map(Memory.fromMap).toList(growable: false);
      final assessment = MemoryDuplicateDetector.assess(candidate, existing);
      final best = assessment.best;

      if (assessment.disposition == MemoryDuplicateDisposition.newMemory &&
          !_requiresManualConfirmation(source)) {
        final id = await txn.insert('memories', candidate.toMap());
        return GuardedMemoryWriteResult(
          disposition: GuardedMemoryWriteDisposition.inserted,
          memoryId: id,
        );
      }

      if (assessment.disposition == MemoryDuplicateDisposition.clearDuplicate) {
        return GuardedMemoryWriteResult(
          disposition: GuardedMemoryWriteDisposition.skippedDuplicate,
          existingMemoryId: best?.memory.id,
          duplicateScore: best?.score ?? 1,
        );
      }

      final bestMatch = best;
      if (bestMatch == null || bestMatch.memory.id == null) {
        if (_requiresManualConfirmation(source)) {
          final proposalId = await _createCandidateProposal(
            txn,
            candidate: candidate,
            best: null,
            relatedMatches: const [],
            source: source,
            sourceConversationId: sourceConversationId,
          );
          return GuardedMemoryWriteResult(
            disposition: proposalId == null
                ? GuardedMemoryWriteDisposition.skippedDuplicate
                : GuardedMemoryWriteDisposition.proposalCreated,
            proposalId: proposalId,
          );
        }
        final id = await txn.insert('memories', candidate.toMap());
        return GuardedMemoryWriteResult(
          disposition: GuardedMemoryWriteDisposition.inserted,
          memoryId: id,
        );
      }

      final proposalId = await _createCandidateProposal(
        txn,
        candidate: candidate,
        best: bestMatch,
        relatedMatches: assessment.matches.take(3).toList(growable: false),
        source: source,
        sourceConversationId: sourceConversationId,
      );
      return GuardedMemoryWriteResult(
        disposition: proposalId == null
            ? GuardedMemoryWriteDisposition.skippedDuplicate
            : GuardedMemoryWriteDisposition.proposalCreated,
        existingMemoryId: bestMatch.memory.id,
        proposalId: proposalId,
        duplicateScore: bestMatch.score,
      );
    });
  }

  static Future<String?> _createCandidateProposal(
    DatabaseExecutor db, {
    required Memory candidate,
    required MemoryDuplicateMatch? best,
    required List<MemoryDuplicateMatch> relatedMatches,
    required String source,
    required String? sourceConversationId,
  }) async {
    final target = best?.memory;
    final targetId = target?.id;
    final targetSnapshot = target == null ? null : _memorySnapshot(target);
    final baseVersions = <String, Object?>{
      if (target != null && targetId != null)
        '$targetId': <String, Object?>{
          'updated_at': target.updatedAt.toIso8601String(),
          'status': target.status,
        },
    };
    final candidatePayload = _candidatePayload(candidate);
    final mergePreview = target == null
        ? const <String, Object?>{}
        : _defaultMergePreview(target, candidate);
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'character_id': candidate.characterId,
              'action': MemoryActionProposal.actionCreate,
              'target_id': targetId,
              'target_version': targetId == null
                  ? null
                  : baseVersions['$targetId'],
              'candidate': <String, Object?>{
                'mode': candidate.mode,
                'category': candidate.category.trim().toLowerCase(),
                'content': MemoryDuplicateDetector.normalizeContent(
                  candidate.content,
                ),
                'triggers': candidate.triggers.trim().toLowerCase(),
                'permanent': candidate.isPermanent,
              },
            }),
          ),
        )
        .toString();
    final id = _uuid.v4();
    final inserted = await db.insert(
      'pending_memory_actions',
      <String, Object?>{
        'id': id,
        'character_id': candidate.characterId,
        'mode': candidate.mode,
        'action': MemoryActionProposal.actionCreate,
        'source': source,
        'source_conversation_id': sourceConversationId,
        'source_message_id': null,
        'target_ids_json': jsonEncode(
          targetId == null ? const <int>[] : <int>[targetId],
        ),
        'payload_json': jsonEncode(<String, Object?>{
          'targets': targetSnapshot == null
              ? const <Map<String, Object?>>[]
              : <Map<String, Object?>>[targetSnapshot],
          'candidate': candidatePayload,
          'result': mergePreview,
          'duplicate_score': best?.score ?? 0,
          'reasons': best?.reasons ?? const <String>[],
          'similar_matches': [
            for (final match in relatedMatches)
              <String, Object?>{
                ..._memorySnapshot(match.memory),
                'score': match.score,
                'reasons': match.reasons,
              },
          ],
        }),
        'base_versions_json': jsonEncode(baseVersions),
        'fingerprint': fingerprint,
        'status': MemoryActionProposal.statusPending,
        'created_at': DateTime.now().toIso8601String(),
        'seen_at': null,
        'resolved_at': null,
        'error': '',
        'result_json': '{}',
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (inserted > 0) return id;
    final prior = await db.query(
      'pending_memory_actions',
      columns: ['id', 'status'],
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
      limit: 1,
    );
    if (prior.isEmpty ||
        !_reviewStatuses.contains(prior.first['status']?.toString())) {
      return null;
    }
    return prior.first['id']?.toString();
  }

  static Map<String, Object?> _memorySnapshot(Memory memory) =>
      <String, Object?>{
        'id': memory.id,
        'category': memory.category,
        'content': memory.content,
        'triggers': memory.triggers,
        'permanent': memory.isPermanent,
        'mention_count': memory.mentionCount,
        'updated_at': memory.updatedAt.toIso8601String(),
      };

  static Map<String, Object?> _candidatePayload(Memory memory) =>
      <String, Object?>{
        'mode': memory.mode,
        'category': memory.category,
        'content': memory.content,
        'confidence': memory.confidence,
        'narrative_weight': memory.narrativeWeight,
        'permanent': memory.isPermanent,
        'source_conversation_id': memory.sourceConversationId,
        'triggers': memory.triggers,
        'emotion_x': memory.emotionX,
        'emotion_y': memory.emotionY,
        'emotion_resonance': memory.emotionResonance,
      };

  static Map<String, Object?> _defaultMergePreview(
    Memory existing,
    Memory candidate,
  ) => _normalizedMergePreview([existing, candidate]);

  static Future<String?> proposeDelete({
    required String characterId,
    required String mode,
    required String sourceConversationId,
    required List<int> targetIds,
  }) async {
    return _createProposal(
      characterId: characterId,
      mode: mode,
      action: MemoryActionProposal.actionDelete,
      sourceConversationId: sourceConversationId,
      targetIds: targetIds,
      mergeResult: null,
    );
  }

  static Future<String?> proposeMerge({
    required String characterId,
    required String mode,
    required String sourceConversationId,
    required List<int> targetIds,
    required String category,
    required String content,
    required String triggers,
  }) async {
    if (targetIds.toSet().length < 2) return null;
    return _createProposal(
      characterId: characterId,
      mode: mode,
      action: MemoryActionProposal.actionMerge,
      sourceConversationId: sourceConversationId,
      targetIds: targetIds,
      mergeResult: <String, Object?>{
        'category': category,
        'content': content,
        'triggers': triggers,
      },
    );
  }

  static Future<String?> proposeLink({
    required String characterId,
    required String mode,
    required String sourceConversationId,
    required List<int> targetIds,
    String relationType = 'related',
    double strength = 0.92,
    String reason = 'model_memo_link',
  }) async {
    if (targetIds.toSet().length < 2) return null;
    return _createProposal(
      characterId: characterId,
      mode: mode,
      action: MemoryActionProposal.actionLink,
      sourceConversationId: sourceConversationId,
      targetIds: targetIds,
      mergeResult: null,
      payloadExtras: <String, Object?>{
        'link': <String, Object?>{
          'relation_type': relationType,
          'strength': strength.clamp(0.0, 1.0),
          'reason': reason,
        },
      },
    );
  }

  /// Creates a reviewable merge proposal for two already-stored memories.
  /// The local scanner never archives either row by itself.
  static Future<String?> proposeExistingDuplicate({
    required String characterId,
    required String mode,
    required Memory first,
    required Memory second,
    required double score,
    required List<String> reasons,
    Map<String, Object?>? mergeResult,
  }) async {
    if (first.id == null || second.id == null || first.id == second.id) {
      return null;
    }
    return proposeExistingDuplicateGroup(
      characterId: characterId,
      mode: mode,
      memories: [first, second],
      score: score,
      reasons: reasons,
      mergeResult: mergeResult,
    );
  }

  /// Collapses an overlapping duplicate cluster into one review item instead
  /// of asking the user to resolve every pair in the same cluster.
  static Future<String?> proposeExistingDuplicateGroup({
    required String characterId,
    required String mode,
    required List<Memory> memories,
    required double score,
    required List<String> reasons,
    Map<String, Object?>? mergeResult,
  }) async {
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null &&
            memory.characterId == characterId &&
            memory.mode == mode)
          memory.id!: memory,
    };
    if (unique.length < 2) return null;
    final rows = unique.values.toList(growable: false);
    return _createProposal(
      characterId: characterId,
      mode: mode,
      action: MemoryActionProposal.actionMerge,
      sourceConversationId: '',
      source: 'local_scan',
      targetIds: unique.keys.toList(growable: false),
      mergeResult: _normalizedMergePreview(rows, preferred: mergeResult),
      payloadExtras: <String, Object?>{
        'duplicate_score': score,
        'reasons': reasons.toSet().toList(growable: false),
        'existing_duplicate_scan': true,
        'dedupe_policy_version': 2,
      },
    );
  }

  static Map<String, Object?> _normalizedMergePreview(
    List<Memory> memories, {
    Map<String, Object?>? preferred,
  }) {
    if (memories.isEmpty) return const <String, Object?>{};
    final triggers = <String>{
      for (final memory in memories)
        ...memory.triggers
            .split(RegExp(r'[,，、]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty),
    }.take(3).join(',');
    final fallbackCategory = memories.reversed
        .map((memory) => memory.category.trim())
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => L.pick(en: 'Important Event', zhTW: '重要事件'),
        );
    final preferredCategory = preferred?['category']?.toString().trim() ?? '';
    final preferredTriggers = preferred?['triggers']?.toString().trim() ?? '';
    return <String, Object?>{
      'mode': memories.first.mode,
      'category': preferredCategory.isEmpty
          ? fallbackCategory
          : preferredCategory,
      'content': _mergedContentWithSingleDate(
        memories.map((memory) => memory.content),
        preferred: preferred?['content']?.toString() ?? '',
      ),
      'triggers': preferredTriggers.isEmpty ? triggers : preferredTriggers,
      'permanent': memories.any((memory) => memory.isPermanent),
    };
  }

  static String _mergedContentWithSingleDate(
    Iterable<String> sources, {
    String preferred = '',
  }) {
    final sourceList = sources.toList(growable: false);
    final date =
        _recordDatePattern.firstMatch(preferred)?.group(0) ??
        sourceList
            .map((content) => _recordDatePattern.firstMatch(content)?.group(0))
            .whereType<String>()
            .firstOrNull ??
        '';
    final preferredBody = _stripRecordDates(preferred);
    String body;
    if (preferredBody.isNotEmpty) {
      body = preferredBody;
    } else {
      final byLength = sourceList.map(_stripRecordDates).toList()
        ..sort((left, right) => right.length.compareTo(left.length));
      final kept = <String>[];
      final normalized = <String>[];
      for (final content in byLength) {
        final next = MemoryDuplicateDetector.normalizeContent(content);
        if (next.isEmpty || normalized.any((prior) => prior.contains(next))) {
          continue;
        }
        kept.add(content);
        normalized.add(next);
      }
      body = kept.join(L.locale == 'en' ? '; ' : '；');
    }
    if (date.isEmpty) return body;
    if (body.isEmpty) return date;
    return '$date $body';
  }

  static String _stripRecordDates(String content) => content
      .replaceAll(_recordDatePattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^[；;,，。\s]+'), '')
      .trim();

  /// Repairs pairwise local-scan proposals created by older builds. Only the
  /// review inbox changes; memories, archives and spider links are untouched.
  static Future<int> consolidateExistingDuplicateProposals(
    String characterId,
  ) async {
    final proposals = (await listForReview(characterId))
        .where(
          (proposal) =>
              proposal.isExistingDuplicateScan &&
              proposal.action == MemoryActionProposal.actionMerge &&
              proposal.status != MemoryActionProposal.statusStale,
        )
        .toList(growable: false);
    if (proposals.length < 2) return 0;

    final groups = <List<MemoryActionProposal>>[];
    for (final proposal in proposals) {
      final overlapping = groups
          .where(
            (group) => group.any(
              (member) => member.targetIds.any(proposal.targetIds.contains),
            ),
          )
          .toList(growable: false);
      if (overlapping.isEmpty) {
        groups.add([proposal]);
        continue;
      }
      final merged = <MemoryActionProposal>[proposal];
      for (final group in overlapping) {
        merged.addAll(group);
        groups.remove(group);
      }
      groups.add(merged);
    }

    var consolidated = 0;
    final db = await DatabaseHelper.database;
    for (final group in groups.where((group) => group.length > 1)) {
      final ids =
          group.expand((proposal) => proposal.targetIds).toSet().toList()
            ..sort();
      final keeper = group.where((proposal) {
        final proposalIds = proposal.targetIds.toSet();
        return proposalIds.length == ids.length && proposalIds.containsAll(ids);
      }).firstOrNull;

      String? keeperId = keeper?.id;
      if (keeperId == null) {
        final placeholders = List.filled(ids.length, '?').join(',');
        final rows = await db.rawQuery(
          'SELECT * FROM memories WHERE id IN ($placeholders) '
          'AND character_id = ? AND status = ?',
          [...ids, characterId, 'active'],
        );
        if (rows.length != ids.length) continue;
        final memories = rows.map(Memory.fromMap).toList(growable: false);
        final score = group
            .map((proposal) => proposal.duplicateScore)
            .fold<double>(0, max);
        final reasons = group
            .expand((proposal) => proposal.duplicateReasons)
            .toSet()
            .toList(growable: false);
        keeperId = await proposeExistingDuplicateGroup(
          characterId: characterId,
          mode: group.first.mode,
          memories: memories,
          score: score,
          reasons: reasons,
        );
      }
      if (keeperId == null) continue;
      for (final proposal in group) {
        if (proposal.id == keeperId) continue;
        await reject(proposal.id, characterId);
        consolidated++;
      }
    }
    return consolidated;
  }

  static Future<String?> _createProposal({
    required String characterId,
    required String mode,
    required String action,
    required String sourceConversationId,
    required List<int> targetIds,
    required Map<String, Object?>? mergeResult,
    String source = 'model',
    Map<String, Object?> payloadExtras = const <String, Object?>{},
  }) async {
    final uniqueIds = targetIds.toSet().toList()..sort();
    if (uniqueIds.isEmpty) return null;
    final db = await DatabaseHelper.database;
    final placeholders = List.filled(uniqueIds.length, '?').join(',');
    final rows = (await db.rawQuery(
      'SELECT * FROM memories WHERE id IN ($placeholders) '
      'AND character_id = ? AND status = ?',
      [...uniqueIds, characterId, 'active'],
    )).toList();
    if (rows.length != uniqueIds.length) return null;
    rows.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));

    final targets = <Map<String, Object?>>[];
    final baseVersions = <String, Object?>{};
    var permanent = false;
    for (final row in rows) {
      final id = row['id'] as int;
      permanent = permanent || (row['is_permanent'] as int? ?? 0) == 1;
      targets.add(<String, Object?>{
        'id': id,
        'category': row['category']?.toString() ?? '',
        'content': row['content']?.toString() ?? '',
        'triggers': row['triggers']?.toString() ?? '',
        'permanent': (row['is_permanent'] as int? ?? 0) == 1,
        'mention_count': row['mention_count'] as int? ?? 0,
        'updated_at': row['updated_at']?.toString() ?? '',
      });
      baseVersions['$id'] = <String, Object?>{
        'updated_at': row['updated_at']?.toString() ?? '',
        'status': row['status']?.toString() ?? '',
      };
    }

    final sourceMemories = rows
        .map((row) => Memory.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
    final safeMergeResult =
        action == MemoryActionProposal.actionMerge && mergeResult != null
        ? _normalizedMergePreview(sourceMemories, preferred: mergeResult)
        : mergeResult;
    final result = safeMergeResult == null
        ? null
        : <String, Object?>{
            ...safeMergeResult,
            'mode': mode,
            'permanent': permanent,
          };
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'character_id': characterId,
              'action': action,
              'target_ids': uniqueIds,
              'base_versions': baseVersions,
            }),
          ),
        )
        .toString();
    final now = DateTime.now().toIso8601String();
    final id = _uuid.v4();
    final payload = <String, Object?>{
      'targets': targets,
      'result': ?result,
      ...payloadExtras,
    };
    final inserted = await db
        .insert('pending_memory_actions', <String, Object?>{
          'id': id,
          'character_id': characterId,
          'mode': mode,
          'action': action,
          'source': source,
          'source_conversation_id': sourceConversationId,
          'source_message_id': null,
          'target_ids_json': jsonEncode(uniqueIds),
          'payload_json': jsonEncode(payload),
          'base_versions_json': jsonEncode(baseVersions),
          'fingerprint': fingerprint,
          'status': MemoryActionProposal.statusPending,
          'created_at': now,
          'seen_at': null,
          'resolved_at': null,
          'error': '',
          'result_json': '{}',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted > 0) return id;

    final existing = await db.query(
      'pending_memory_actions',
      columns: ['id', 'status', 'payload_json'],
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
      limit: 1,
    );
    if (existing.isEmpty) return null;
    final existingRow = existing.first;
    final existingId = existingRow['id']?.toString();
    if (existingId == null) return null;
    final existingStatus = existingRow['status']?.toString() ?? '';
    final requestedPolicy = payloadExtras['dedupe_policy_version'] as int? ?? 0;
    var existingPolicy = 0;
    Map<String, dynamic> existingPayload = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(existingRow['payload_json']?.toString() ?? '');
      if (decoded is Map) {
        existingPayload = Map<String, dynamic>.from(decoded);
        if (decoded['dedupe_policy_version'] is num) {
          existingPolicy = (decoded['dedupe_policy_version'] as num).toInt();
        }
      }
    } catch (_) {}
    final policyAdvanced =
        source == 'local_scan' && requestedPolicy > existingPolicy;
    final existingResult = existingPayload['result'];
    final mergeChanged =
        result != null &&
        jsonEncode(existingResult is Map ? existingResult : const {}) !=
            jsonEncode(result);
    if (policyAdvanced &&
        (_reviewStatuses.contains(existingStatus) ||
            existingStatus == MemoryActionProposal.statusRejected)) {
      await db.update(
        'pending_memory_actions',
        <String, Object?>{
          'payload_json': jsonEncode(payload),
          'base_versions_json': jsonEncode(baseVersions),
          'status': MemoryActionProposal.statusPending,
          'created_at': now,
          'seen_at': null,
          'resolved_at': null,
          'error': '',
          'result_json': '{}',
        },
        where: 'id = ? AND character_id = ?',
        whereArgs: [existingId, characterId],
      );
      return existingId;
    }
    if (mergeChanged && _reviewStatuses.contains(existingStatus)) {
      await db.update(
        'pending_memory_actions',
        <String, Object?>{'payload_json': jsonEncode(payload)},
        where: 'id = ? AND character_id = ?',
        whereArgs: [existingId, characterId],
      );
      return existingId;
    }
    if (!_reviewStatuses.contains(existingStatus)) {
      return null;
    }
    return existingId;
  }

  static Future<void> bindToMessage({
    required Iterable<String> proposalIds,
    required String conversationId,
    required int messageId,
  }) async {
    final ids = proposalIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await DatabaseHelper.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pending_memory_actions SET source_message_id = ? '
      'WHERE id IN ($placeholders) AND source_conversation_id = ? '
      'AND source_message_id IS NULL',
      [messageId, ...ids, conversationId],
    );
  }

  static Future<List<MemoryActionProposal>> listForReview(
    String characterId,
  ) async {
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM pending_memory_actions '
      'WHERE character_id = ? AND status IN ($placeholders) '
      "ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'failed' THEN 1 "
      "WHEN 'stale' THEN 2 ELSE 3 END, created_at DESC",
      [characterId, ...statuses],
    );
    final result = <MemoryActionProposal>[];
    for (final rawRow in rows) {
      var row = Map<String, dynamic>.from(rawRow);
      var proposal = MemoryActionProposal.fromMap(row);
      if ((proposal.action == MemoryActionProposal.actionMerge ||
              proposal.action == MemoryActionProposal.actionCreate) &&
          proposal.mergePreview.isNotEmpty) {
        final sources = _proposalMergeSources(proposal);
        if (sources.isNotEmpty) {
          final repaired = _normalizedMergePreview(
            sources,
            preferred: proposal.mergePreview,
          );
          if (jsonEncode(repaired) != jsonEncode(proposal.mergePreview)) {
            final payload = <String, dynamic>{
              ...proposal.payload,
              'result': repaired,
            };
            await db.update(
              'pending_memory_actions',
              <String, Object?>{'payload_json': jsonEncode(payload)},
              where: 'id = ? AND character_id = ?',
              whereArgs: [proposal.id, characterId],
            );
            row = <String, dynamic>{
              ...row,
              'payload_json': jsonEncode(payload),
            };
            proposal = MemoryActionProposal.fromMap(row);
          }
        }
      }
      result.add(proposal);
    }
    return result;
  }

  static List<Memory> _proposalMergeSources(MemoryActionProposal proposal) {
    final now = DateTime.now();
    final sources = <Memory>[
      for (final snapshot in proposal.targetSnapshots)
        Memory(
          id: snapshot['id'] as int?,
          characterId: proposal.characterId,
          mode: proposal.mode,
          category: snapshot['category']?.toString() ?? '',
          content: snapshot['content']?.toString() ?? '',
          triggers: snapshot['triggers']?.toString() ?? '',
          isPermanent: snapshot['permanent'] == true,
          mentionCount: (snapshot['mention_count'] as num?)?.toInt() ?? 0,
          updatedAt:
              DateTime.tryParse(snapshot['updated_at']?.toString() ?? '') ??
              now,
        ),
    ];
    if (proposal.action == MemoryActionProposal.actionCreate) {
      final candidate = proposal.candidatePreview;
      final content = candidate['content']?.toString() ?? '';
      if (content.trim().isNotEmpty) {
        sources.add(
          Memory(
            characterId: proposal.characterId,
            mode: candidate['mode']?.toString() ?? proposal.mode,
            category: candidate['category']?.toString() ?? '',
            content: content,
            triggers: candidate['triggers']?.toString() ?? '',
            isPermanent: candidate['permanent'] == true,
          ),
        );
      }
    }
    return sources;
  }

  static Future<({int total, int unread})> counts(String characterId) async {
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      "SUM(CASE WHEN status = 'pending' AND seen_at IS NULL THEN 1 ELSE 0 END) AS unread "
      'FROM pending_memory_actions '
      'WHERE character_id = ? AND status IN ($placeholders)',
      [characterId, ...statuses],
    );
    final row = rows.first;
    return (
      total: row['total'] as int? ?? 0,
      unread: row['unread'] as int? ?? 0,
    );
  }

  static Future<Map<int, ({int total, int unread})>> pendingCountsByMessage(
    String conversationId,
  ) async {
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT source_message_id, COUNT(*) AS total, '
      "SUM(CASE WHEN status = 'pending' AND seen_at IS NULL THEN 1 ELSE 0 END) AS unread "
      'FROM pending_memory_actions '
      'WHERE source_conversation_id = ? AND source_message_id IS NOT NULL '
      'AND status IN ($placeholders) GROUP BY source_message_id',
      [conversationId, ...statuses],
    );
    return <int, ({int total, int unread})>{
      for (final row in rows)
        if (row['source_message_id'] is int)
          row['source_message_id'] as int: (
            total: row['total'] as int? ?? 0,
            unread: row['unread'] as int? ?? 0,
          ),
    };
  }

  static Future<Map<int, List<MemoryActionProposal>>>
  pendingProposalsByMessage({
    required String characterId,
    required String conversationId,
  }) async {
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM pending_memory_actions '
      'WHERE character_id = ? AND source_conversation_id = ? '
      'AND source_message_id IS NOT NULL AND status IN ($placeholders) '
      'ORDER BY created_at ASC',
      [characterId, conversationId, ...statuses],
    );
    final grouped = <int, List<MemoryActionProposal>>{};
    for (final raw in rows) {
      final messageId = raw['source_message_id'] is int
          ? raw['source_message_id'] as int
          : int.tryParse(raw['source_message_id']?.toString() ?? '');
      if (messageId == null) continue;
      grouped
          .putIfAbsent(messageId, () => <MemoryActionProposal>[])
          .add(MemoryActionProposal.fromMap(raw));
    }
    return grouped;
  }

  static Future<void> markSeen(
    String characterId, {
    int? sourceMessageId,
    bool includeLocalScan = false,
  }) async {
    final db = await DatabaseHelper.database;
    final sourceClause = sourceMessageId == null
        ? ''
        : includeLocalScan
        ? ' AND (source_message_id = ? OR source = ?)'
        : ' AND source_message_id = ?';
    await db.update(
      'pending_memory_actions',
      {'seen_at': DateTime.now().toIso8601String()},
      where: 'character_id = ? AND status = ? AND seen_at IS NULL$sourceClause',
      whereArgs: [
        characterId,
        MemoryActionProposal.statusPending,
        ?sourceMessageId,
        if (sourceMessageId != null && includeLocalScan) 'local_scan',
      ],
    );
  }

  static Future<void> snooze(String id, String characterId) {
    return _setStatus(
      id,
      characterId,
      from: const {MemoryActionProposal.statusPending},
      to: MemoryActionProposal.statusSnoozed,
      resolved: false,
    );
  }

  static Future<void> reject(String id, String characterId) {
    return _setStatus(
      id,
      characterId,
      from: _reviewStatuses,
      to: MemoryActionProposal.statusRejected,
      resolved: true,
    );
  }

  static Future<void> _setStatus(
    String id,
    String characterId, {
    required Set<String> from,
    required String to,
    required bool resolved,
  }) async {
    final db = await DatabaseHelper.database;
    final statuses = from.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pending_memory_actions SET status = ?, seen_at = COALESCE(seen_at, ?), '
      'resolved_at = ? WHERE id = ? AND character_id = ? '
      'AND status IN ($placeholders)',
      [
        to,
        DateTime.now().toIso8601String(),
        resolved ? DateTime.now().toIso8601String() : null,
        id,
        characterId,
        ...statuses,
      ],
    );
  }

  static Future<String> execute(
    String id,
    String characterId, {
    String? createDecision,
    String? linkDecision,
    Map<String, Object?>? createResultOverride,
    Map<String, Object?>? mergeResultOverride,
  }) async {
    final db = await DatabaseHelper.database;
    try {
      return await db.transaction<String>((txn) async {
        final proposals = await txn.query(
          'pending_memory_actions',
          where: 'id = ? AND character_id = ?',
          whereArgs: [id, characterId],
          limit: 1,
        );
        if (proposals.isEmpty) return 'missing';
        final proposal = MemoryActionProposal.fromMap(proposals.first);
        if (!_executableStatuses.contains(proposal.status)) {
          return proposal.status;
        }

        final current = await _loadCurrentTargets(txn, proposal);
        if (!_matchesBaseVersions(proposal, current)) {
          await txn.update(
            'pending_memory_actions',
            <String, Object?>{
              'status': MemoryActionProposal.statusStale,
              'resolved_at': DateTime.now().toIso8601String(),
              'error': '記憶已在提案後變更',
            },
            where: 'id = ? AND character_id = ?',
            whereArgs: [id, characterId],
          );
          return MemoryActionProposal.statusStale;
        }

        final claimed = await txn.rawUpdate(
          'UPDATE pending_memory_actions SET status = ? '
          'WHERE id = ? AND character_id = ? '
          'AND status IN (${List.filled(_executableStatuses.length, '?').join(',')})',
          [
            MemoryActionProposal.statusExecuting,
            id,
            characterId,
            ..._executableStatuses,
          ],
        );
        if (claimed != 1) return 'busy';

        final result = <String, Object?>{};
        if (proposal.action == MemoryActionProposal.actionDelete) {
          for (final targetId in proposal.targetIds) {
            await _archiveInTransaction(
              txn,
              targetId,
              characterId,
              '使用者確認模型刪除提案',
            );
          }
          result['archived_ids'] = proposal.targetIds;
        } else if (proposal.action == MemoryActionProposal.actionLink) {
          if (linkDecision != linkDecisionConfirm &&
              linkDecision != linkDecisionDefer) {
            throw StateError('缺少連線處理方式');
          }
          final link = proposal.linkPreview;
          final confirmed = linkDecision == linkDecisionConfirm;
          final linkedPairs = await _linkPairsInTransaction(
            txn,
            characterId: characterId,
            memoryIds: proposal.targetIds,
            relationType: link['relation_type']?.toString() ?? 'related',
            strength: (link['strength'] as num?)?.toDouble() ?? 0.92,
            reason: link['reason']?.toString() ?? 'model_memo_link',
            status: confirmed ? 'confirmed' : 'suggested',
            source: confirmed ? 'user' : 'model',
          );
          result['linked_pairs'] = linkedPairs;
          result['decision'] = linkDecision;
        } else if (proposal.action == MemoryActionProposal.actionMerge) {
          final preview = _normalizedMergePreview(
            _proposalMergeSources(proposal),
            preferred: <String, Object?>{
              ...proposal.mergePreview,
              ...?mergeResultOverride,
            },
          );
          final now = DateTime.now();
          final targetPermanent = proposal.targetSnapshots.any(
            (target) => target['permanent'] == true,
          );
          final newMemory = Memory(
            characterId: characterId,
            mode: preview['mode']?.toString() ?? proposal.mode,
            category: preview['category']?.toString() ?? '重要事件',
            content: preview['content']?.toString() ?? '',
            confidence: 'high',
            triggers: preview['triggers']?.toString() ?? '',
            isPermanent: targetPermanent || preview['permanent'] == true,
            createdAt: now,
            updatedAt: now,
          );
          if (newMemory.content.trim().isEmpty) {
            throw StateError('合併預覽內容為空');
          }
          final newId = await txn.insert('memories', newMemory.toMap());
          await _remapLinksInTransaction(
            txn,
            proposal.targetIds,
            newId,
            characterId,
          );
          for (final targetId in proposal.targetIds) {
            await _archiveInTransaction(
              txn,
              targetId,
              characterId,
              '使用者確認模型合併提案',
            );
          }
          result['new_memory_id'] = newId;
          result['archived_ids'] = proposal.targetIds;
        } else if (proposal.action == MemoryActionProposal.actionCreate) {
          if (createDecision != createDecisionUseNew &&
              createDecision != createDecisionMerge) {
            throw StateError('缺少新記憶處理方式');
          }
          final candidate = proposal.candidatePreview;
          final selected = createDecision == createDecisionUseNew
              ? candidate
              : _normalizedMergePreview(
                  _proposalMergeSources(proposal),
                  preferred: <String, Object?>{
                    ...proposal.mergePreview,
                    ...?createResultOverride,
                  },
                );
          final targetIsPermanent = proposal.targetSnapshots.any(
            (target) => target['permanent'] == true,
          );
          final now = DateTime.now();
          final newMemory = Memory(
            characterId: characterId,
            mode: selected['mode']?.toString() ?? proposal.mode,
            category: selected['category']?.toString() ?? '重要事件',
            content: selected['content']?.toString() ?? '',
            confidence:
                selected['confidence']?.toString() ??
                candidate['confidence']?.toString() ??
                'high',
            narrativeWeight:
                selected['narrative_weight']?.toString() ??
                candidate['narrative_weight']?.toString(),
            isPermanent:
                targetIsPermanent ||
                selected['permanent'] == true ||
                candidate['permanent'] == true,
            sourceConversationId:
                selected['source_conversation_id']?.toString() ??
                candidate['source_conversation_id']?.toString(),
            triggers: selected['triggers']?.toString() ?? '',
            emotionX:
                (selected['emotion_x'] as num?)?.toInt() ??
                (candidate['emotion_x'] as num?)?.toInt(),
            emotionY:
                (selected['emotion_y'] as num?)?.toInt() ??
                (candidate['emotion_y'] as num?)?.toInt(),
            emotionResonance:
                (selected['emotion_resonance'] as num?)?.toInt() ??
                (candidate['emotion_resonance'] as num?)?.toInt(),
            createdAt: now,
            updatedAt: now,
          );
          if (newMemory.content.trim().isEmpty) {
            throw StateError('候選記憶內容為空');
          }

          // A pending proposal may sit for days. Re-check every other active
          // memory inside the same transaction before applying an old choice.
          final placeholders = List.filled(
            proposal.targetIds.length,
            '?',
          ).join(',');
          final excludedTargets = proposal.targetIds.isEmpty
              ? ''
              : ' AND id NOT IN ($placeholders)';
          final otherRows = await txn.rawQuery(
            'SELECT * FROM memories WHERE character_id = ? AND mode = ? '
            'AND status = ?$excludedTargets',
            [characterId, newMemory.mode, 'active', ...proposal.targetIds],
          );
          final freshAssessment = MemoryDuplicateDetector.assess(
            newMemory,
            otherRows.map(Memory.fromMap),
          );
          if (freshAssessment.disposition !=
              MemoryDuplicateDisposition.newMemory) {
            await txn.update(
              'pending_memory_actions',
              <String, Object?>{
                'status': MemoryActionProposal.statusStale,
                'resolved_at': DateTime.now().toIso8601String(),
                'error': '等待確認期間出現了另一條相似記憶',
              },
              where: 'id = ? AND character_id = ?',
              whereArgs: [id, characterId],
            );
            return MemoryActionProposal.statusStale;
          }

          final newId = await txn.insert('memories', newMemory.toMap());
          await _remapLinksInTransaction(
            txn,
            proposal.targetIds,
            newId,
            characterId,
          );
          for (final targetId in proposal.targetIds) {
            await _archiveInTransaction(
              txn,
              targetId,
              characterId,
              createDecision == createDecisionUseNew
                  ? '使用者選擇使用新記憶'
                  : '使用者確認合併疑似重複記憶',
            );
          }
          result['decision'] = createDecision;
          result['new_memory_id'] = newId;
          result['archived_ids'] = proposal.targetIds;
        } else {
          throw StateError('不支援的記憶提案：${proposal.action}');
        }

        await txn.update(
          'pending_memory_actions',
          <String, Object?>{
            'status': MemoryActionProposal.statusCompleted,
            'seen_at':
                proposal.seenAt?.toIso8601String() ??
                DateTime.now().toIso8601String(),
            'resolved_at': DateTime.now().toIso8601String(),
            'error': '',
            'result_json': jsonEncode(result),
          },
          where: 'id = ? AND character_id = ?',
          whereArgs: [id, characterId],
        );
        return MemoryActionProposal.statusCompleted;
      });
    } catch (error) {
      await db.update(
        'pending_memory_actions',
        <String, Object?>{
          'status': MemoryActionProposal.statusFailed,
          'seen_at': DateTime.now().toIso8601String(),
          'error': error.toString(),
        },
        where: 'id = ? AND character_id = ? AND status != ?',
        whereArgs: [id, characterId, MemoryActionProposal.statusCompleted],
      );
      return MemoryActionProposal.statusFailed;
    }
  }

  static Future<int> _linkPairsInTransaction(
    Transaction txn, {
    required String characterId,
    required List<int> memoryIds,
    required String relationType,
    required double strength,
    required String reason,
    required String status,
    required String source,
  }) async {
    final ids = memoryIds.toSet().toList()..sort();
    final safeType =
        const {
          'related',
          'same_event',
          'temporal',
          'duplicate_candidate',
          'conflict_update',
        }.contains(relationType)
        ? relationType
        : 'related';
    final safeStrength = strength.clamp(0.0, 1.0);
    final now = DateTime.now().toIso8601String();
    var linked = 0;
    for (var left = 0; left < ids.length - 1; left++) {
      for (var right = left + 1; right < ids.length; right++) {
        final existing = await txn.query(
          'spider_web_links',
          columns: ['id'],
          where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
          whereArgs: [characterId, ids[left], ids[right]],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('spider_web_links', <String, Object?>{
            'character_id': characterId,
            'memory_id_1': ids[left],
            'memory_id_2': ids[right],
            'created_at': now,
            'relation_type': safeType,
            'strength': safeStrength,
            'status': status,
            'source': source,
            'reason': reason.trim(),
            'updated_at': now,
          });
        } else {
          await txn.update(
            'spider_web_links',
            <String, Object?>{
              'relation_type': safeType,
              'strength': safeStrength,
              'status': status,
              'source': source,
              'reason': reason.trim(),
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [existing.first['id']],
          );
        }
        linked++;
      }
    }
    return linked;
  }

  static Future<List<Map<String, Object?>>> _loadCurrentTargets(
    Transaction txn,
    MemoryActionProposal proposal,
  ) async {
    final ids = proposal.targetIds;
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    return txn.rawQuery(
      'SELECT id, character_id, status, updated_at FROM memories '
      'WHERE id IN ($placeholders) AND character_id = ?',
      [...ids, proposal.characterId],
    );
  }

  static bool _matchesBaseVersions(
    MemoryActionProposal proposal,
    List<Map<String, Object?>> current,
  ) {
    if (current.length != proposal.targetIds.length) return false;
    for (final row in current) {
      final id = row['id'] as int?;
      final expected = id == null ? null : proposal.baseVersions['$id'];
      if (expected is! Map) return false;
      if (row['status']?.toString() != expected['status']?.toString() ||
          row['updated_at']?.toString() != expected['updated_at']?.toString()) {
        return false;
      }
    }
    return true;
  }

  static Future<void> _archiveInTransaction(
    Transaction txn,
    int memoryId,
    String characterId,
    String reason,
  ) async {
    final rows = await txn.query(
      'memories',
      where: 'id = ? AND character_id = ? AND status = ?',
      whereArgs: [memoryId, characterId, 'active'],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('記憶 #$memoryId 已不可用');
    final snapshot = Map<String, Object?>.from(rows.first);
    final existing = await txn.query(
      'archive',
      columns: ['id'],
      where: 'original_table = ? AND original_id = ?',
      whereArgs: ['memories', memoryId],
      limit: 1,
    );
    final values = <String, Object?>{
      'character_id': characterId,
      'original_id': memoryId,
      'original_table': 'memories',
      'content_snapshot': jsonEncode(snapshot),
      'archived_at': DateTime.now().toIso8601String(),
      'reason': reason,
    };
    if (existing.isEmpty) {
      await txn.insert('archive', values);
    } else {
      await txn.update(
        'archive',
        values,
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
    final changed = await txn.update(
      'memories',
      <String, Object?>{
        'status': 'deleted',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND character_id = ? AND status = ?',
      whereArgs: [memoryId, characterId, 'active'],
    );
    if (changed != 1) throw StateError('記憶 #$memoryId 歸檔失敗');
  }

  static Future<void> _remapLinksInTransaction(
    Transaction txn,
    List<int> oldIds,
    int newId,
    String characterId,
  ) async {
    if (oldIds.isEmpty) return;
    final placeholders = List.filled(oldIds.length, '?').join(',');
    final edges = await txn.rawQuery(
      'SELECT * FROM spider_web_links '
      'WHERE character_id = ? AND '
      '(memory_id_1 IN ($placeholders) OR memory_id_2 IN ($placeholders))',
      [characterId, ...oldIds, ...oldIds],
    );
    final oldSet = oldIds.toSet();
    for (final edge in edges) {
      if (edge['status']?.toString() != 'confirmed') continue;
      final first = edge['memory_id_1'] as int;
      final second = edge['memory_id_2'] as int;
      final other = oldSet.contains(first) ? second : first;
      if (oldSet.contains(other) || other == newId) continue;
      await txn.rawInsert(
        'INSERT OR IGNORE INTO spider_web_links '
        '(character_id, memory_id_1, memory_id_2, created_at, '
        'relation_type, strength, status, source, reason, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          characterId,
          min(newId, other),
          max(newId, other),
          DateTime.now().toIso8601String(),
          edge['relation_type']?.toString() ?? 'related',
          (edge['strength'] as num?)?.toDouble() ?? 1.0,
          'confirmed',
          'merge_remap',
          edge['reason']?.toString() ?? '',
          DateTime.now().toIso8601String(),
        ],
      );
    }
    await txn.rawDelete(
      'DELETE FROM spider_web_links WHERE character_id = ? AND '
      '(memory_id_1 IN ($placeholders) OR memory_id_2 IN ($placeholders))',
      [characterId, ...oldIds, ...oldIds],
    );
  }
}
