import 'dart:developer' as developer;

import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/message.dart';
import 'context_compressor.dart';
import 'rp_worldbook_service.dart';

typedef ContextSummaryRepairRunner =
    Future<int> Function(
      Map<String, Object?> job,
      List<Message> sourceMessages,
    );

/// Rebuilds summary revisions invalidated by message edits, deletion or
/// re-roll. Invalidations only enqueue immutable source spans inside the
/// database transaction; this worker performs model calls later so editing a
/// message never blocks on network I/O and pending work survives app restarts.
class ContextSummaryRepairService {
  const ContextSummaryRepairService._();

  static final Map<String, Future<int>> _scopeFlights = <String, Future<int>>{};

  static Future<int> processPendingForConversation(
    String conversationId, {
    ContextSummaryRepairRunner? runner,
  }) async {
    final conversation = await DatabaseHelper.getConversation(conversationId);
    if (conversation == null) return 0;
    return processScope(
      characterId: conversation.characterId,
      contextMode: conversation.contextMode,
      continuityId: conversation.continuityId,
      runner: runner,
    );
  }

  static Future<int> processScope({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    ContextSummaryRepairRunner? runner,
  }) {
    final scope = continuityId.trim().isEmpty ? 'main' : continuityId.trim();
    final key = '$characterId\u0000${contextMode.storageValue}\u0000$scope';
    final existing = _scopeFlights[key];
    if (existing != null) return existing;

    late final Future<int> operation;
    operation =
        _processScope(
              characterId: characterId,
              contextMode: contextMode,
              continuityId: scope,
              runner: runner ?? _runSummaryRepair,
            )
            .catchError((Object error, StackTrace stackTrace) {
              developer.log(
                'Summary repair worker stopped; pending jobs remain retryable',
                name: 'ContextSummaryRepairService',
                error: error,
                stackTrace: stackTrace,
              );
              return 0;
            })
            .whenComplete(() {
              if (identical(_scopeFlights[key], operation)) {
                _scopeFlights.remove(key);
              }
            });
    _scopeFlights[key] = operation;
    return operation;
  }

  static Future<int> _processScope({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required ContextSummaryRepairRunner runner,
  }) async {
    final db = await DatabaseHelper.database;
    var rebuilt = 0;
    final seenJobIds = <int>{};
    while (seenJobIds.length < 100) {
      // Refetch after each completion so invalidations arriving during a
      // model call are picked up by the same worker invocation.
      final jobs = await db.query(
        'context_summary_repairs',
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND status != 'completed'",
        whereArgs: <Object?>[
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        orderBy: 'original_summary_id ASC',
      );
      final unseen = jobs.where((job) {
        final id = job['id'] as int?;
        return id != null && !seenJobIds.contains(id);
      });
      if (unseen.isEmpty) break;
      final rawJob = unseen.first;
      final job = Map<String, Object?>.from(rawJob);
      final jobId = job['id'] as int?;
      final originalSummaryId = job['original_summary_id'] as int?;
      if (jobId == null || originalSummaryId == null) continue;
      seenJobIds.add(jobId);
      final now = DateTime.now().toIso8601String();
      final claimed = await db.update(
        'context_summary_repairs',
        <String, Object?>{
          'status': 'running',
          'attempts': (job['attempts'] as int? ?? 0) + 1,
          'last_error': '',
          'updated_at': now,
        },
        where: "id = ? AND status != 'completed'",
        whereArgs: <Object?>[jobId],
      );
      if (claimed == 0) continue;

      final summary = await db.query(
        'context_summaries',
        columns: const <String>['revision_status', 'invalidation_reason'],
        where: 'id = ?',
        whereArgs: <Object?>[originalSummaryId],
        limit: 1,
      );
      if (summary.isEmpty ||
          summary.single['revision_status'] != 'invalidated') {
        await _finishJob(db, jobId, status: 'completed');
        continue;
      }

      final conversationId =
          job['source_conversation_id']?.toString().trim() ?? '';
      final startId = job['source_message_start_id'] as int?;
      var endId = job['source_message_end_id'] as int?;
      if (conversationId.isEmpty || startId == null || endId == null) {
        await _finishJob(
          db,
          jobId,
          status: 'failed',
          error: 'Missing reproducible source span',
        );
        break;
      }
      final oldEndRows = await db.query(
        'messages',
        columns: const <String>['id'],
        where: 'conversation_id = ? AND id = ?',
        whereArgs: <Object?>[conversationId, endId],
        limit: 1,
      );
      if (oldEndRows.isEmpty) {
        final replacementRows = await db.query(
          'messages',
          columns: const <String>['id'],
          where: 'conversation_id = ? AND id > ?',
          whereArgs: <Object?>[conversationId, endId],
          orderBy: 'id DESC',
          limit: 1,
        );
        if (replacementRows.isEmpty) {
          // The old assistant reply was removed for edit/re-roll and its
          // replacement has not been persisted yet. Keep the job pending;
          // generation completion will wake this worker again.
          await _finishJob(db, jobId, status: 'pending');
          break;
        }
        endId = replacementRows.single['id'] as int;
        job['source_message_end_id'] = endId;
        await db.update(
          'context_summary_repairs',
          <String, Object?>{
            'source_message_end_id': endId,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[jobId],
        );
      }
      final sourceRows = await db.query(
        'messages',
        where: 'conversation_id = ? AND id BETWEEN ? AND ?',
        whereArgs: <Object?>[conversationId, startId, endId],
        orderBy: 'id ASC',
      );
      final sourceMessages = sourceRows
          .map(Message.fromMap)
          .toList(growable: false);
      if (sourceMessages.isEmpty ||
          sourceMessages.every((message) => message.text.trim().isEmpty)) {
        // A re-roll may intentionally remove the entire old source span. No
        // replacement summary should be invented for content that no longer
        // exists, but later jobs in the chain can still be rebuilt.
        await _finishJob(db, jobId, status: 'completed');
        continue;
      }

      try {
        final tokenCount = await runner(job, sourceMessages);
        if (tokenCount <= 0) {
          await _finishJob(
            db,
            jobId,
            status: 'failed',
            error: 'No replacement summary was produced',
          );
          // Do not rebuild a child against the wrong parent. A later app open
          // or explicit retry starts from this same failed checkpoint.
          break;
        }
        await _finishJob(db, jobId, status: 'completed');
        rebuilt++;
      } catch (error, stackTrace) {
        developer.log(
          'Summary repair failed',
          name: 'ContextSummaryRepairService',
          error: error,
          stackTrace: stackTrace,
        );
        await _finishJob(
          db,
          jobId,
          status: 'failed',
          error: 'Model request or summary persistence failed',
        );
        break;
      }
    }

    if (rebuilt > 0 && contextMode == ContextMode.rp) {
      try {
        await RpWorldbookService.maybeProcessAfterSummary(
          characterId: characterId,
          continuityId: continuityId,
        );
      } catch (error, stackTrace) {
        developer.log(
          'Worldbook update after repair failed',
          name: 'ContextSummaryRepairService',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return rebuilt;
  }

  static Future<int> _runSummaryRepair(
    Map<String, Object?> job,
    List<Message> sourceMessages,
  ) {
    final firstId = sourceMessages.first.id;
    final lastId = sourceMessages.last.id;
    return ContextCompressor.compress(
      messages: sourceMessages,
      characterId: job['character_id']?.toString() ?? 'default',
      conversationId: job['source_conversation_id']?.toString() ?? '',
      contextMode: ContextMode.fromStorage(job['context_mode']?.toString()),
      continuityId: job['continuity_id']?.toString() ?? 'main',
      minimumSourceTokens: 1,
      sourceMessageStartIdOverride: firstId,
      displayAnchorMessageIdOverride: lastId,
      triggerWorldbook: false,
      isRepair: true,
      repairSummaryId: job['original_summary_id'] as int?,
    );
  }

  static Future<void> _finishJob(
    Database db,
    int jobId, {
    required String status,
    String error = '',
  }) async {
    await db.update(
      'context_summary_repairs',
      <String, Object?>{
        'status': status,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: "id = ? AND status != 'completed'",
      whereArgs: <Object?>[jobId],
    );
  }
}
