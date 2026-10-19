import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../memory/database.dart';
import '../models/message.dart';
import 'character_timeline_service.dart';
import 'locale_strings.dart';
import 'recall_text_matcher.dart';
import 'token_estimator.dart';

/// RP chronology has its own storage and dedupe domain. It intentionally does
/// not reuse daily health/state inference or device-calendar correction.
abstract final class RpCharacterTimelineService {
  static const int extractionLimit = 8;

  static String _storageLayer(String raw) => switch (raw) {
    'mainline' => 'main',
    'flashback' => 'memory',
    'side_story' => 'au',
    'dream' || 'hypothetical' => raw,
    _ => 'main',
  };

  static Future<int> storeSummaryCandidates({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required List<TimelineEventCandidate> candidates,
    required List<Message> sourceMessages,
    int? sourceSummaryId,
  }) async {
    final source = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final db = await DatabaseHelper.database;
    final inserted = await db.transaction<int>((txn) async {
      if (sourceSummaryId != null) {
        final summary = await txn.query(
          'context_summaries',
          columns: const <String>['id'],
          where: "id = ? AND revision_status = 'valid'",
          whereArgs: <Object?>[sourceSummaryId],
          limit: 1,
        );
        if (summary.isEmpty) return 0;
      }
      var stored = 0;
      for (final candidate in candidates.take(extractionLimit)) {
        // Mutable/ongoing RP facts belong to RpStoryStateService. Keeping the
        // legacy `state` shape here would make the same fact compete in both
        // the story-state and chronology prompt blocks.
        if (candidate.type == 'state') continue;
        final ids = candidate.sourceMessageIds
            .where(source.containsKey)
            .toList();
        final evidence = candidate.evidence.trim();
        if (ids.isEmpty || evidence.isEmpty) continue;
        final supported = ids.any((id) => source[id]!.text.contains(evidence));
        if (!supported) continue;
        final value = candidate.value.trim();
        if (value.isEmpty) continue;
        final narrativeLayer = _storageLayer(candidate.narrativeLayer.trim());
        final eventKey = candidate.eventKey.trim();
        final sequenceOrder = ids.reduce(
          (left, right) => left < right ? left : right,
        );
        final duplicate = await txn.query(
          'rp_character_timeline',
          columns: const <String>['id'],
          where: eventKey.isNotEmpty
              ? 'character_id = ? AND continuity_id = ? AND type = ? '
                    'AND event_key = ? AND confirmed = 1'
              : 'character_id = ? AND continuity_id = ? AND type = ? '
                    'AND value = ? AND story_time_text = ? AND confirmed = 1',
          whereArgs: eventKey.isNotEmpty
              ? <Object?>[characterId, continuityId, 'event', eventKey]
              : <Object?>[
                  characterId,
                  continuityId,
                  'event',
                  value,
                  candidate.occurredOn.trim(),
                ],
          limit: 1,
        );
        if (duplicate.isNotEmpty) continue;
        final changed = await txn.rawInsert(
          '''INSERT OR IGNORE INTO rp_character_timeline
        (character_id, continuity_id, source_conversation_id, type, key,
         event_key, narrative_layer, subject_entity_ids, value,
         story_time_text, sequence_order, scene, source_message_id,
         source_message_ids, source_evidence, confirmed, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, datetime('now'), datetime('now'))''',
          <Object?>[
            characterId,
            continuityId,
            sourceConversationId,
            'event',
            null,
            eventKey,
            narrativeLayer,
            jsonEncode(candidate.subjectEntityIds),
            value,
            candidate.occurredOn.trim(),
            sequenceOrder,
            '',
            ids.first,
            jsonEncode(ids),
            evidence,
          ],
        );
        if (changed > 0) stored++;
      }
      return stored;
    });
    debugPrint(
      '[RpTimelineDebug] stored=$inserted rejected=${candidates.length - inserted} '
      'character=$characterId continuity=$continuityId',
    );
    return inserted;
  }

  static Future<List<Map<String, dynamic>>> getEntries(
    String characterId, {
    String continuityId = 'main',
    int limit = 200,
    bool newestFirst = false,
    bool includeNonCanonical = false,
  }) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'rp_character_timeline',
      where: includeNonCanonical
          ? 'character_id = ? AND continuity_id = ? AND confirmed = 1'
          : "character_id = ? AND continuity_id = ? AND confirmed = 1 AND narrative_layer IN ('main', 'memory')",
      whereArgs: <Object?>[characterId, continuityId],
      orderBy: newestFirst
          ? 'sequence_order DESC, id DESC'
          : 'sequence_order ASC, id ASC',
      limit: limit,
    );
  }

  static Future<bool> deleteEntry({
    required String characterId,
    required int id,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    return await db.delete(
          'rp_character_timeline',
          where: 'id = ? AND character_id = ? AND continuity_id = ?',
          whereArgs: <Object?>[id, characterId, continuityId],
        ) >
        0;
  }

  /// Updates one existing chronology event only when the main model points to
  /// its stable key and quotes the latest user correction verbatim. The event
  /// keeps its original order/id, so correcting it cannot move history or
  /// create a competing duplicate.
  static Future<bool> applyModelCorrection({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required int sourceMessageId,
    required String eventKey,
    required String value,
    required String storyTime,
    required String evidence,
  }) async {
    final normalizedKey = eventKey.trim();
    final normalizedValue = value.trim();
    final normalizedEvidence = evidence.trim();
    if (normalizedKey.isEmpty ||
        normalizedValue.isEmpty ||
        normalizedEvidence.isEmpty) {
      return false;
    }
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'rp_character_timeline',
        where:
            'character_id = ? AND continuity_id = ? AND type = ? '
            'AND event_key = ? AND confirmed = 1',
        whereArgs: <Object?>[characterId, continuityId, 'event', normalizedKey],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final previous = rows.first;
      final correctedTime = storyTime.trim();
      return await txn.update(
            'rp_character_timeline',
            <String, Object?>{
              'value': normalizedValue,
              if (correctedTime.isNotEmpty) 'story_time_text': correctedTime,
              'scene': 'model_user_correction',
              'source_conversation_id': sourceConversationId,
              'source_message_id': sourceMessageId,
              'source_message_ids': jsonEncode(<int>[sourceMessageId]),
              'source_evidence': normalizedEvidence,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ? AND confirmed = 1',
            whereArgs: <Object?>[previous['id']],
          ) ==
          1;
    });
  }

  static Future<String> recallPrompt(
    String characterId,
    String userMessage, {
    String continuityId = 'main',
  }) async {
    final entries = await getEntries(
      characterId,
      continuityId: continuityId,
      limit: 200,
      newestFirst: true,
    );
    if (entries.isEmpty) return '';

    // RP chronology contains discrete events only. Ongoing scene/body/
    // promise/identity facts are recalled by RpStoryStateService.
    final query = userMessage.trim().toLowerCase();
    final terms = RecallTextMatcher.relevanceTerms(query);
    final events = entries
        .where((row) => (row['type'] as String? ?? '') != 'state')
        .toList();

    final scoredEvents = events.map((row) {
      final value = (row['value'] as String? ?? '').toLowerCase();
      final time = (row['story_time_text'] as String? ?? '').toLowerCase();
      var score = 0.0;
      if (query.isNotEmpty && value.contains(query)) score += 5;
      for (final term in terms) {
        if (value.contains(term) || time.contains(term)) {
          score += term.length >= 3 ? 2 : 1;
        }
      }
      final sequence = (row['sequence_order'] as int?) ?? 0;
      // Tiny deterministic tie-breaker only; it must never turn an unrelated
      // event into a recall match.
      score += sequence / 1000000000000;
      return (row: row, score: score);
    }).toList();
    scoredEvents.sort((left, right) => right.score.compareTo(left.score));

    // Completed chronology is recall-only. Never fill the block with six
    // unrelated recent events merely because fewer keywords matched; that is
    // what made settled plans repeatedly reappear as current objectives.
    final selected = scoredEvents
        .where((candidate) => candidate.score >= 1)
        .take(6)
        .map((candidate) => candidate.row)
        .toList(growable: false);
    if (selected.isEmpty) return '';
    selected.sort(_chronological);

    final lines = <String>[];
    var usedTokens = 0;
    for (final row in selected) {
      final time = (row['story_time_text'] as String? ?? '').trim();
      final value = (row['value'] as String? ?? '').trim();
      if (value.isEmpty) continue;
      final layerLabel = row['narrative_layer'] == 'memory'
          ? L.pick(en: 'flashback', zhTW: '回憶', zhCN: '回忆')
          : '';
      final prefix = time.isEmpty ? '' : '[$time] ';
      final labels = <String>[
        L.pick(en: 'completed', zhTW: '已完成', zhCN: '已完成'),
        if (row['scene'] == 'model_user_correction')
          L.pick(en: 'corrected', zhTW: '已修正', zhCN: '已修正'),
        if (layerLabel.isNotEmpty) layerLabel,
      ].map((value) => '[$value]').join();
      final eventKey = row['event_key']?.toString().trim() ?? '';
      final keyLabel = eventKey.isEmpty ? '' : '[event_key=$eventKey] ';
      final line =
          '- $keyLabel$prefix$labels${labels.isEmpty ? '' : ' '}$value';
      final cost = TokenEstimator.estimate(line);
      if (usedTokens + cost > 500 && lines.isNotEmpty) break;
      lines.add(line);
      usedTokens += cost;
    }
    if (lines.isEmpty) return '';
    debugPrint(
      '[RpTimelineDebug] phase=recall character=$characterId '
      'continuity=$continuityId entries=${entries.length} selected=${lines.length}',
    );
    return '${L.pick(en: '【RP chronology reference】', zhTW: '【RP 劇情時間線參考】', zhCN: '【RP 剧情时间线参考】')}\n${lines.join('\n')}';
  }

  static int _chronological(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final leftOrder = (left['sequence_order'] as int?) ?? 0;
    final rightOrder = (right['sequence_order'] as int?) ?? 0;
    final bySequence = leftOrder.compareTo(rightOrder);
    if (bySequence != 0) return bySequence;
    return ((left['id'] as int?) ?? 0).compareTo((right['id'] as int?) ?? 0);
  }
}
