import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import '../models/memory.dart';
import '../models/memory_action_proposal.dart';
import '../models/context_mode.dart';
import 'locale_strings.dart';
import 'memory_duplicate_detector.dart';
import 'memory_debug_log.dart';

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
  static final RegExp _mergeProcessNotePattern = RegExp(
    r'\s*[（(]\s*(?:重複記憶已合併|重复记忆已合并|duplicate memor(?:y|ies) (?:was |were )?merged|merged duplicate memor(?:y|ies))\s*[）)]\s*',
    caseSensitive: false,
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
      if (_requiresManualConfirmation(source) &&
          await _matchesRejectedSuggestion(txn, candidate)) {
        return const GuardedMemoryWriteResult(
          disposition: GuardedMemoryWriteDisposition.skippedDuplicate,
        );
      }
      if (_requiresManualConfirmation(source) &&
          await _matchesOpenSuggestion(txn, candidate)) {
        return const GuardedMemoryWriteResult(
          disposition: GuardedMemoryWriteDisposition.skippedDuplicate,
        );
      }
      final rows = await txn.query(
        'memories',
        where:
            'character_id = ? AND mode = ? AND context_mode = ? '
            'AND continuity_id = ? AND status = ?',
        whereArgs: [
          candidate.characterId,
          candidate.mode,
          candidate.contextMode.storageValue,
          candidate.continuityId,
          'active',
        ],
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

  /// Keeps a rejected model suggestion from returning merely because the
  /// provider paraphrased it. Scope is deliberately limited to the same
  /// character, lane, continuity and memory mode, and contradictory/new facts
  /// are never suppressed.
  static Future<bool> _matchesRejectedSuggestion(
    DatabaseExecutor db,
    Memory candidate,
  ) async {
    final tombstones = await db.query(
      'memory_rejection_tombstones',
      columns: const <String>['candidate_json'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          'AND mode = ?',
      whereArgs: <Object?>[
        candidate.characterId,
        candidate.contextMode.storageValue,
        candidate.continuityId,
        candidate.mode,
      ],
      orderBy: 'created_at DESC',
      limit: 1000,
    );
    for (final row in tombstones) {
      try {
        final raw = jsonDecode(row['candidate_json']?.toString() ?? '');
        if (raw is! Map) continue;
        final rejected = Map<String, dynamic>.from(raw);
        final content = rejected['content']?.toString().trim() ?? '';
        if (content.isEmpty) continue;
        final previous = Memory(
          characterId: candidate.characterId,
          contextMode: candidate.contextMode,
          continuityId: candidate.continuityId,
          mode: rejected['mode']?.toString() ?? candidate.mode,
          category: rejected['category']?.toString() ?? '',
          content: content,
          triggers: rejected['triggers']?.toString() ?? '',
          isPermanent: rejected['permanent'] == true,
        );
        if (_isRejectedSuggestionMatch(candidate, previous)) return true;
      } catch (_) {
        // A damaged tombstone must not suppress an unrelated new fact.
      }
    }

    // Legacy fallback: older versions kept the decision only on the proposal.
    final rows = await db.query(
      'pending_memory_actions',
      columns: ['payload_json', 'source_conversation_id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          'AND mode = ? AND action = ? AND status = ?',
      whereArgs: [
        candidate.characterId,
        candidate.contextMode.storageValue,
        candidate.continuityId,
        candidate.mode,
        MemoryActionProposal.actionCreate,
        MemoryActionProposal.statusRejected,
      ],
      orderBy: 'resolved_at DESC, created_at DESC',
      limit: 1000,
    );
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload_json']?.toString() ?? '');
        if (payload is! Map || payload['candidate'] is! Map) continue;
        final rejected = Map<String, dynamic>.from(payload['candidate'] as Map);
        final content = rejected['content']?.toString().trim() ?? '';
        if (content.isEmpty) continue;
        final previous = Memory(
          characterId: candidate.characterId,
          contextMode: candidate.contextMode,
          continuityId: candidate.continuityId,
          mode: rejected['mode']?.toString() ?? candidate.mode,
          category: rejected['category']?.toString() ?? '',
          content: content,
          triggers: rejected['triggers']?.toString() ?? '',
          isPermanent: rejected['permanent'] == true,
          sourceConversationId: row['source_conversation_id']?.toString(),
        );
        if (_isRejectedSuggestionMatch(candidate, previous)) {
          return true;
        }
      } catch (_) {
        // A malformed historical proposal must not block a new memory write.
      }
    }
    return false;
  }

  static bool _isRejectedSuggestionMatch(Memory candidate, Memory rejected) {
    final match = MemoryDuplicateDetector.compare(candidate, rejected);
    if (_hasMaterialSuggestionConflict(candidate.content, rejected.content)) {
      return false;
    }
    if (match.exactContent || match.contentScore >= 0.82) return true;
    final overlap = _suggestionTextOverlap(candidate.content, rejected.content);
    if (overlap.common >= 6 &&
        overlap.coverage >= 0.72 &&
        overlap.dice >= 0.35) {
      return true;
    }
    final triggerCoverage = _semanticTriggerCoverage(
      candidate.triggers,
      rejected.triggers,
    );
    if (triggerCoverage >= 0.66 &&
        overlap.common >= 10 &&
        overlap.dice >= 0.25) {
      return true;
    }
    return match.categoryScore > 0 &&
        triggerCoverage >= 0.5 &&
        overlap.common >= 8 &&
        overlap.dice >= 0.16;
  }

  /// Pending model extractions are compared with one another before a new
  /// review card is created. This prevents one response (or a quick retry)
  /// from filling the inbox with several rewrites of the same fact.
  static Future<bool> _matchesOpenSuggestion(
    DatabaseExecutor db,
    Memory candidate,
  ) async {
    final rows = await db.query(
      'pending_memory_actions',
      columns: ['payload_json', 'source_conversation_id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          'AND mode = ? AND action = ? '
          "AND source IN ('model', 'summary') "
          "AND status IN ('pending', 'snoozed', 'failed')",
      whereArgs: [
        candidate.characterId,
        candidate.contextMode.storageValue,
        candidate.continuityId,
        candidate.mode,
        MemoryActionProposal.actionCreate,
      ],
      orderBy: 'created_at DESC',
      limit: 200,
    );
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['payload_json']?.toString() ?? '');
        if (payload is! Map || payload['candidate'] is! Map) continue;
        final raw = Map<String, dynamic>.from(payload['candidate'] as Map);
        final content = raw['content']?.toString().trim() ?? '';
        if (content.isEmpty) continue;
        final open = Memory(
          characterId: candidate.characterId,
          contextMode: candidate.contextMode,
          continuityId: candidate.continuityId,
          mode: raw['mode']?.toString() ?? candidate.mode,
          category: raw['category']?.toString() ?? '',
          content: content,
          triggers: raw['triggers']?.toString() ?? '',
          isPermanent: raw['permanent'] == true,
          sourceConversationId: row['source_conversation_id']?.toString(),
        );
        if (_isRejectedSuggestionMatch(candidate, open)) return true;
      } catch (_) {
        // A malformed historical proposal must not block a new suggestion.
      }
    }
    return false;
  }

  static ({int common, double coverage, double dice}) _suggestionTextOverlap(
    String left,
    String right,
  ) {
    final leftGrams = _bigrams(_canonicalSuggestionText(left));
    final rightGrams = _bigrams(_canonicalSuggestionText(right));
    if (leftGrams.isEmpty || rightGrams.isEmpty) {
      return (common: 0, coverage: 0, dice: 0);
    }
    final common = leftGrams.intersection(rightGrams).length;
    return (
      common: common,
      coverage: common / min(leftGrams.length, rightGrams.length),
      dice: (2 * common) / (leftGrams.length + rightGrams.length),
    );
  }

  static Set<String> _bigrams(String value) {
    if (value.length < 2) return value.isEmpty ? const {} : <String>{value};
    return <String>{
      for (var index = 0; index < value.length - 1; index++)
        value.substring(index, index + 2),
    };
  }

  static String _canonicalSuggestionText(String raw) {
    var value = MemoryDuplicateDetector.normalizeContent(raw);
    const aliases = <String, String>{
      '父親': '父',
      '父亲': '父',
      '爸爸': '父',
      '爹': '父',
      '爸': '父',
      '母親': '母',
      '母亲': '母',
      '媽媽': '母',
      '妈妈': '母',
      '娘': '母',
      '媽': '母',
      '妈': '母',
    };
    for (final entry in aliases.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }
    return value;
  }

  static Set<String> _canonicalTriggers(String raw) => raw
      .split(RegExp(r'[,，、;；]'))
      .map(_canonicalSuggestionText)
      .where((value) => value.isNotEmpty)
      .toSet();

  static double _semanticTriggerCoverage(String left, String right) {
    final leftSet = _canonicalTriggers(left);
    final rightSet = _canonicalTriggers(right);
    if (leftSet.isEmpty || rightSet.isEmpty) return 0;
    var matches = 0;
    final remaining = rightSet.toList(growable: true);
    for (final leftTrigger in leftSet) {
      final index = remaining.indexWhere(
        (rightTrigger) =>
            leftTrigger == rightTrigger ||
            leftTrigger.contains(rightTrigger) ||
            rightTrigger.contains(leftTrigger),
      );
      if (index < 0) continue;
      matches++;
      remaining.removeAt(index);
    }
    return matches / min(leftSet.length, rightSet.length);
  }

  /// Only explicit opposing facts block rejection matching. The generic
  /// duplicate detector intentionally remains cautious, but treating any
  /// newly added Chinese negation (for example "not deceased") as a conflict
  /// lets ordinary paraphrases repeatedly escape a user's rejection.
  static bool _hasMaterialSuggestionConflict(String left, String right) {
    final leftText = _canonicalSuggestionText(left);
    final rightText = _canonicalSuggestionText(right);
    const opposites = <(String, String)>[
      ('喜歡', '不喜歡'),
      ('喜欢', '不喜欢'),
      ('願意', '不願意'),
      ('愿意', '不愿意'),
      ('同意', '拒絕'),
      ('同意', '拒绝'),
      ('親近', '不親近'),
      ('亲近', '不亲近'),
      ('在一起', '分開'),
      ('在一起', '分开'),
    ];
    for (final pair in opposites) {
      final leftNegative = leftText.contains(pair.$2);
      final rightNegative = rightText.contains(pair.$2);
      final leftPositive = leftText.replaceAll(pair.$2, '').contains(pair.$1);
      final rightPositive = rightText.replaceAll(pair.$2, '').contains(pair.$1);
      if ((leftNegative && rightPositive) || (rightNegative && leftPositive)) {
        return true;
      }
    }

    final leftNumbers = _nonDateNumbers(left);
    final rightNumbers = _nonDateNumbers(right);
    return leftNumbers.isNotEmpty &&
        rightNumbers.isNotEmpty &&
        (leftNumbers.length != rightNumbers.length ||
            !leftNumbers.containsAll(rightNumbers));
  }

  static Set<String> _nonDateNumbers(String raw) {
    var value = raw.replaceAll(
      RegExp(
        r'(?:\d{4}[./-])?\d{1,2}[./-]\d{1,2}|\d{4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日',
      ),
      ' ',
    );
    value = value.replaceAll(_recordDatePattern, ' ');
    return RegExp(
      r'\d+(?:\.\d+)?',
    ).allMatches(value).map((match) => match.group(0)!).toSet();
  }

  /// Cleans up proposals that were already rejected in an earlier reply but
  /// returned after the provider paraphrased them. Rejection is a durable user
  /// decision inside the same character/lane/story/memory scope.
  static Future<int> suppressReappearingRejectedSuggestions(
    String characterId,
  ) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      final rows = await txn.query(
        'pending_memory_actions',
        where:
            'character_id = ? AND action = ? '
            "AND source IN ('model', 'summary') "
            "AND status IN ('pending', 'snoozed', 'failed')",
        whereArgs: [characterId, MemoryActionProposal.actionCreate],
      );
      if (rows.isEmpty) return 0;
      final rejectedRows = await txn.query(
        'pending_memory_actions',
        where: 'character_id = ? AND action = ? AND status = ?',
        whereArgs: [
          characterId,
          MemoryActionProposal.actionCreate,
          MemoryActionProposal.statusRejected,
        ],
        orderBy: 'resolved_at DESC, created_at DESC',
        limit: 1000,
      );
      if (rejectedRows.isEmpty) return 0;

      Memory? candidateFromRow(Map<String, Object?> row) {
        try {
          final payload = jsonDecode(row['payload_json']?.toString() ?? '');
          if (payload is! Map || payload['candidate'] is! Map) return null;
          final raw = Map<String, dynamic>.from(payload['candidate'] as Map);
          final content = raw['content']?.toString().trim() ?? '';
          if (content.isEmpty) return null;
          return Memory(
            characterId: characterId,
            contextMode: ContextMode.fromStorage(
              row['context_mode']?.toString() ?? 'daily',
            ),
            continuityId: row['continuity_id']?.toString() ?? 'main',
            mode: row['mode']?.toString() ?? 'romance',
            category: raw['category']?.toString() ?? '',
            content: content,
            triggers: raw['triggers']?.toString() ?? '',
            isPermanent: raw['permanent'] == true,
            sourceConversationId: row['source_conversation_id']?.toString(),
          );
        } catch (_) {
          return null;
        }
      }

      final rejectedByScope = <String, List<Memory>>{};
      for (final row in rejectedRows) {
        final memory = candidateFromRow(row);
        if (memory == null) continue;
        final key =
            '${memory.contextMode.storageValue}\u0000'
            '${memory.continuityId}\u0000${memory.mode}';
        rejectedByScope.putIfAbsent(key, () => <Memory>[]).add(memory);
      }

      final now = DateTime.now().toIso8601String();
      var suppressed = 0;
      for (final row in rows) {
        final candidate = candidateFromRow(row);
        if (candidate == null) continue;
        final key =
            '${candidate.contextMode.storageValue}\u0000'
            '${candidate.continuityId}\u0000${candidate.mode}';
        final rejected = rejectedByScope[key] ?? const <Memory>[];
        if (!rejected.any(
          (previous) => _isRejectedSuggestionMatch(candidate, previous),
        )) {
          continue;
        }
        suppressed += await txn.update(
          'pending_memory_actions',
          <String, Object?>{
            'status': MemoryActionProposal.statusRejected,
            'seen_at': now,
            'resolved_at': now,
            'error': '',
          },
          where:
              'id = ? AND character_id = ? '
              "AND status IN ('pending', 'snoozed', 'failed')",
          whereArgs: [row['id'], characterId],
        );
      }
      return suppressed;
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
              'context_mode': candidate.contextMode.storageValue,
              'continuity_id': candidate.continuityId,
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
        'context_mode': candidate.contextMode.storageValue,
        'continuity_id': candidate.continuityId,
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
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    return _createProposal(
      characterId: characterId,
      mode: mode,
      action: MemoryActionProposal.actionDelete,
      sourceConversationId: sourceConversationId,
      targetIds: targetIds,
      mergeResult: null,
      contextMode: contextMode,
      continuityId: continuityId,
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
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
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
      contextMode: contextMode,
      continuityId: continuityId,
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
    if (memories.isEmpty) return null;
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null &&
            memory.characterId == characterId &&
            memory.mode == mode &&
            memory.contextMode == memories.first.contextMode &&
            memory.continuityId == memories.first.continuityId)
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
      contextMode: rows.first.contextMode,
      continuityId: rows.first.continuityId,
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
    final sourceList = sources
        .map(_stripMergeProcessNarration)
        .toList(growable: false);
    preferred = _stripMergeProcessNarration(preferred);
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
      // A deterministic on-device pass cannot safely author new facts. For a
      // duplicate cluster, keep the most complete source instead of visibly
      // concatenating every source into a synthetic "merged" paragraph.
      body = byLength.firstWhere(
        (content) => content.isNotEmpty,
        orElse: () => '',
      );
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

  static String _stripMergeProcessNarration(String content) => content
      .replaceAll(_mergeProcessNotePattern, ' ')
      .replaceAll(
        RegExp(
          r'\s*(?:重複記憶已合併|重复记忆已合并|duplicate memor(?:y|ies) (?:was |were )?merged|merged duplicate memor(?:y|ies))\s*[。.!！]?\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
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
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final uniqueIds = targetIds.toSet().toList()..sort();
    if (uniqueIds.isEmpty) return null;
    final db = await DatabaseHelper.database;
    final placeholders = List.filled(uniqueIds.length, '?').join(',');
    final rows = (await db.rawQuery(
      'SELECT * FROM memories WHERE id IN ($placeholders) '
      'AND character_id = ? AND context_mode = ? AND continuity_id = ? '
      'AND status = ?',
      [
        ...uniqueIds,
        characterId,
        contextMode.storageValue,
        continuityId,
        'active',
      ],
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
              'context_mode': contextMode.storageValue,
              'continuity_id': continuityId,
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
          'context_mode': contextMode.storageValue,
          'continuity_id': continuityId,
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
    if (policyAdvanced && _reviewStatuses.contains(existingStatus)) {
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
    await db.transaction<void>((txn) async {
      final message = await txn.query(
        'messages',
        columns: ['id'],
        where: 'id = ? AND conversation_id = ?',
        whereArgs: [messageId, conversationId],
        limit: 1,
      );
      if (message.isEmpty) {
        // Reroll/delete may win the race before proposal binding completes.
        await txn.delete(
          'pending_memory_actions',
          where:
              'id IN ($placeholders) AND source_conversation_id = ? '
              "AND source_message_id IS NULL AND status IN ('pending','snoozed','failed','stale')",
          whereArgs: [...ids, conversationId],
        );
        return;
      }
      await txn.rawUpdate(
        'UPDATE pending_memory_actions SET source_message_id = ? '
        'WHERE id IN ($placeholders) AND source_conversation_id = ? '
        'AND source_message_id IS NULL',
        [messageId, ...ids, conversationId],
      );
    });
  }

  static Future<List<MemoryActionProposal>> listForReview(
    String characterId, {
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    await suppressReappearingRejectedSuggestions(characterId);
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final scopeClause = contextMode == null
        ? ''
        : ' AND context_mode = ? AND continuity_id = ?';
    final rows = await db.rawQuery(
      'SELECT * FROM pending_memory_actions '
      'WHERE character_id = ? AND status IN ($placeholders)$scopeClause '
      "ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'failed' THEN 1 "
      "WHEN 'stale' THEN 2 ELSE 3 END, created_at DESC",
      [
        characterId,
        ...statuses,
        if (contextMode != null) contextMode.storageValue,
        if (contextMode != null) continuityId,
      ],
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
          contextMode: proposal.contextMode,
          continuityId: proposal.continuityId,
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
            contextMode: proposal.contextMode,
            continuityId: proposal.continuityId,
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

  static Future<({int total, int unread})> counts(
    String characterId, {
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    await suppressReappearingRejectedSuggestions(characterId);
    final db = await DatabaseHelper.database;
    final statuses = _reviewStatuses.toList(growable: false);
    final placeholders = List.filled(statuses.length, '?').join(',');
    final scopeClause = contextMode == null
        ? ''
        : ' AND context_mode = ? AND continuity_id = ?';
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      "SUM(CASE WHEN status = 'pending' AND seen_at IS NULL THEN 1 ELSE 0 END) AS unread "
      'FROM pending_memory_actions '
      'WHERE character_id = ? AND status IN ($placeholders)$scopeClause',
      [
        characterId,
        ...statuses,
        if (contextMode != null) contextMode.storageValue,
        if (contextMode != null) continuityId,
      ],
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
    await suppressReappearingRejectedSuggestions(characterId);
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
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final sourceClause = sourceMessageId == null
        ? ''
        : includeLocalScan
        ? ' AND (source_message_id = ? OR source = ?)'
        : ' AND source_message_id = ?';
    final scopeClause = contextMode == null
        ? ''
        : ' AND context_mode = ? AND continuity_id = ?';
    await db.update(
      'pending_memory_actions',
      {'seen_at': DateTime.now().toIso8601String()},
      where:
          'character_id = ? AND status = ? AND seen_at IS NULL'
          '$sourceClause$scopeClause',
      whereArgs: [
        characterId,
        MemoryActionProposal.statusPending,
        ?sourceMessageId,
        if (sourceMessageId != null && includeLocalScan) 'local_scan',
        if (contextMode != null) contextMode.storageValue,
        if (contextMode != null) continuityId,
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

  static Future<void> reject(String id, String characterId) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        'pending_memory_actions',
        where: 'id = ? AND character_id = ?',
        whereArgs: <Object?>[id, characterId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final proposal = MemoryActionProposal.fromMap(rows.single);
      if (!_reviewStatuses.contains(proposal.status)) return;
      await _storeRejectionTombstone(txn, proposal);
      await _setStatusInDatabase(
        txn,
        id,
        characterId,
        from: _reviewStatuses,
        to: MemoryActionProposal.statusRejected,
        resolved: true,
      );
    });
  }

  /// Rejects every currently reviewable proposal for one character without
  /// deleting or rewriting any stored memory. Suggested graph edges attached
  /// to those proposals are rejected as well; confirmed edges are preserved.
  static Future<int> rejectAllForReview(
    String characterId, {
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      final statuses = _reviewStatuses.toList(growable: false);
      final placeholders = List.filled(statuses.length, '?').join(',');
      final scopeClause = contextMode == null
          ? ''
          : ' AND context_mode = ? AND continuity_id = ?';
      final scopeArgs = <Object?>[
        if (contextMode != null) contextMode.storageValue,
        if (contextMode != null) continuityId,
      ];
      final rows = await txn.rawQuery(
        'SELECT * FROM pending_memory_actions '
        'WHERE character_id = ? AND status IN ($placeholders)$scopeClause',
        [characterId, ...statuses, ...scopeArgs],
      );
      if (rows.isEmpty) return 0;

      final proposals = rows
          .map(MemoryActionProposal.fromMap)
          .toList(growable: false);
      for (final proposal in proposals) {
        await _storeRejectionTombstone(txn, proposal);
      }
      final now = DateTime.now().toIso8601String();
      final changed = await txn.rawUpdate(
        'UPDATE pending_memory_actions SET status = ?, '
        'seen_at = COALESCE(seen_at, ?), resolved_at = ? '
        'WHERE character_id = ? AND status IN ($placeholders)$scopeClause',
        [
          MemoryActionProposal.statusRejected,
          now,
          now,
          characterId,
          ...statuses,
          ...scopeArgs,
        ],
      );

      for (final proposal in proposals) {
        final ids = proposal.targetIds.toSet().toList()..sort();
        for (var leftIndex = 0; leftIndex < ids.length; leftIndex++) {
          for (
            var rightIndex = leftIndex + 1;
            rightIndex < ids.length;
            rightIndex++
          ) {
            await txn.update(
              'spider_web_links',
              <String, Object?>{
                'status': 'rejected',
                'source': 'user',
                'updated_at': now,
              },
              where:
                  'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ? '
                  'AND status = ?',
              whereArgs: [
                characterId,
                ids[leftIndex],
                ids[rightIndex],
                'suggested',
              ],
            );
          }
        }
      }
      return changed;
    });
  }

  /// Rejects every unconfirmed graph relation for one character while keeping
  /// memories and confirmed edges untouched. Matching duplicate-review items
  /// are rejected in the same transaction so the cleared relation cannot
  /// remain visible in another review surface.
  static Future<int> rejectAllSuggestedRelations(String characterId) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      final links = await txn.query(
        'spider_web_links',
        columns: <String>['memory_id_1', 'memory_id_2', 'relation_type'],
        where: 'character_id = ? AND status = ?',
        whereArgs: <Object?>[characterId, 'suggested'],
      );
      if (links.isEmpty) return 0;

      final now = DateTime.now().toIso8601String();
      final changed = await txn.update(
        'spider_web_links',
        <String, Object?>{
          'status': 'rejected',
          'source': 'user',
          'updated_at': now,
        },
        where: 'character_id = ? AND status = ?',
        whereArgs: <Object?>[characterId, 'suggested'],
      );

      final duplicatePairs = <String>{
        for (final link in links)
          if (link['relation_type'] == 'duplicate_candidate')
            '${link['memory_id_1']}:${link['memory_id_2']}',
      };
      if (duplicatePairs.isNotEmpty) {
        final statuses = _reviewStatuses.toList(growable: false);
        final placeholders = List.filled(statuses.length, '?').join(',');
        final proposalRows = await txn.rawQuery(
          'SELECT * FROM pending_memory_actions '
          'WHERE character_id = ? AND status IN ($placeholders)',
          <Object?>[characterId, ...statuses],
        );
        for (final row in proposalRows) {
          final proposal = MemoryActionProposal.fromMap(row);
          if (!proposal.isExistingDuplicateScan) continue;
          final ids = proposal.targetIds.toSet().toList()..sort();
          if (ids.length != 2 ||
              !duplicatePairs.contains('${ids.first}:${ids.last}')) {
            continue;
          }
          await txn.update(
            'pending_memory_actions',
            <String, Object?>{
              'status': MemoryActionProposal.statusRejected,
              'seen_at': row['seen_at'] ?? now,
              'resolved_at': now,
            },
            where: 'id = ? AND character_id = ?',
            whereArgs: <Object?>[proposal.id, characterId],
          );
        }
      }
      return changed;
    });
  }

  static Future<void> _setStatus(
    String id,
    String characterId, {
    required Set<String> from,
    required String to,
    required bool resolved,
  }) async {
    final db = await DatabaseHelper.database;
    await _setStatusInDatabase(
      db,
      id,
      characterId,
      from: from,
      to: to,
      resolved: resolved,
    );
  }

  static Future<void> _setStatusInDatabase(
    DatabaseExecutor db,
    String id,
    String characterId, {
    required Set<String> from,
    required String to,
    required bool resolved,
  }) async {
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

  static Future<void> _storeRejectionTombstone(
    DatabaseExecutor db,
    MemoryActionProposal proposal,
  ) async {
    if (proposal.action != MemoryActionProposal.actionCreate) return;
    final candidate = proposal.candidatePreview;
    final content = candidate['content']?.toString().trim() ?? '';
    if (content.isEmpty) return;
    final category = candidate['category']?.toString().trim() ?? '';
    final triggers = candidate['triggers']?.toString().trim() ?? '';
    final canonical = <String>[
      _canonicalSuggestionText(category),
      _canonicalSuggestionText(content),
      ...(_canonicalTriggers(triggers).toList()..sort()),
    ].join('|');
    final factKey = sha256.convert(utf8.encode(canonical)).toString();
    final storedCandidate = <String, Object?>{
      ...candidate,
      'mode': candidate['mode']?.toString() ?? proposal.mode,
      'category': category,
      'content': content,
      'triggers': triggers,
    };
    final scopeKey = <String>[
      proposal.characterId,
      proposal.contextMode.storageValue,
      proposal.continuityId,
      proposal.mode,
      factKey,
    ].join('|');
    await db.insert('memory_rejection_tombstones', <String, Object?>{
      'id': sha256.convert(utf8.encode(scopeKey)).toString(),
      'character_id': proposal.characterId,
      'context_mode': proposal.contextMode.storageValue,
      'continuity_id': proposal.continuityId,
      'mode': proposal.mode,
      'category': category,
      'fact_key': factKey,
      'candidate_json': jsonEncode(storedCandidate),
      'source_proposal_id': proposal.id,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
    var debugAction = '';
    var debugMode = '';
    var debugContinuity = '';
    var debugTargetIds = const <int>[];
    int? debugNewMemoryId;
    var debugLinkedPairs = 0;
    try {
      final status = await db.transaction<String>((txn) async {
        final proposals = await txn.query(
          'pending_memory_actions',
          where: 'id = ? AND character_id = ?',
          whereArgs: [id, characterId],
          limit: 1,
        );
        if (proposals.isEmpty) return 'missing';
        final proposal = MemoryActionProposal.fromMap(proposals.first);
        debugAction = proposal.action;
        debugMode = proposal.contextMode.storageValue;
        debugContinuity = proposal.continuityId;
        debugTargetIds = List<int>.unmodifiable(proposal.targetIds);
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
          debugLinkedPairs = linkedPairs;
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
            contextMode: proposal.contextMode,
            continuityId: proposal.continuityId,
            mode: preview['mode']?.toString() ?? proposal.mode,
            category: preview['category']?.toString() ?? '重要事件',
            content: preview['content']?.toString() ?? '',
            confidence: 'high',
            triggers: preview['triggers']?.toString() ?? '',
            isPermanent: targetPermanent || preview['permanent'] == true,
            sourceConversationId: proposal.sourceConversationId,
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
          debugNewMemoryId = newId;
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
            contextMode: proposal.contextMode,
            continuityId: proposal.continuityId,
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
                candidate['source_conversation_id']?.toString() ??
                proposal.sourceConversationId,
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
          debugNewMemoryId = newId;
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
      if (status == MemoryActionProposal.statusCompleted) {
        MemoryDebugLog.record(
          stage: debugMode == 'rp'
              ? 'rp_memory_change_applied'
              : 'daily_memory_change_applied',
          contextMode: debugMode,
          continuityId: debugContinuity,
          inputCount: debugTargetIds.length,
          resultIds: <int>[
            ...debugTargetIds,
            if (debugNewMemoryId != null) debugNewMemoryId!,
          ],
          details: <String, Object?>{
            'action': debugAction,
            'linked_pairs': debugLinkedPairs,
            'created_memory': debugNewMemoryId != null,
          },
        );
      }
      return status;
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
      MemoryDebugLog.record(
        stage: 'memory_change_failed',
        contextMode: debugMode,
        continuityId: debugContinuity,
        inputCount: debugTargetIds.length,
        resultIds: debugTargetIds,
        details: <String, Object?>{'action': debugAction},
        error: error,
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
    final now = DateTime.now().toIso8601String();
    for (final edge in edges) {
      final first = edge['memory_id_1'] as int;
      final second = edge['memory_id_2'] as int;
      final other = oldSet.contains(first) ? second : first;
      if (oldSet.contains(other) || other == newId) continue;
      final relationType = edge['relation_type']?.toString() ?? 'related';
      final incomingStatus = switch (edge['status']?.toString()) {
        'rejected' => 'rejected',
        'suggested' => 'suggested',
        _ => 'confirmed',
      };
      final targetFirst = min(newId, other);
      final targetSecond = max(newId, other);
      final existing = await txn.query(
        'spider_web_links',
        where:
            'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ? '
            'AND relation_type = ?',
        whereArgs: [characterId, targetFirst, targetSecond, relationType],
        limit: 1,
      );
      final incomingStrength = (edge['strength'] as num?)?.toDouble() ?? 1.0;
      final incomingReason = edge['reason']?.toString() ?? '';
      if (existing.isEmpty) {
        await txn.insert('spider_web_links', <String, Object?>{
          'character_id': characterId,
          'memory_id_1': targetFirst,
          'memory_id_2': targetSecond,
          'created_at': now,
          'relation_type': relationType,
          'strength': incomingStrength,
          'status': incomingStatus,
          'source': 'merge_remap',
          'reason': incomingReason,
          'updated_at': now,
        });
        continue;
      }

      final current = existing.first;
      final currentStatus = current['status']?.toString() ?? 'confirmed';
      // A rejected relation is a user decision, not a disposable suggestion.
      // Keep it rejected when another old endpoint remaps a weaker relation
      // onto the same pair; otherwise a merge could silently revive it.
      if (currentStatus == 'rejected' && incomingStatus != 'rejected') {
        continue;
      }
      if (currentStatus == 'confirmed' && incomingStatus != 'confirmed') {
        continue;
      }
      final nextStatus =
          currentStatus == 'confirmed' || incomingStatus == 'confirmed'
          ? 'confirmed'
          : incomingStatus;
      final currentStrength = (current['strength'] as num?)?.toDouble() ?? 1.0;
      final currentReason = current['reason']?.toString() ?? '';
      await txn.update(
        'spider_web_links',
        <String, Object?>{
          'strength': max(currentStrength, incomingStrength),
          'status': nextStatus,
          'source': 'merge_remap',
          'reason': currentReason.isNotEmpty ? currentReason : incomingReason,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [current['id']],
      );
    }
    await txn.rawDelete(
      'DELETE FROM spider_web_links WHERE character_id = ? AND '
      '(memory_id_1 IN ($placeholders) OR memory_id_2 IN ($placeholders))',
      [characterId, ...oldIds, ...oldIds],
    );
  }
}
