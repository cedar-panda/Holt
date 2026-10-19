part of 'database.dart';

/// Only tiny archive identifiers are held by the UI. Reply bodies stay in
/// SQLite; selecting a version decodes exactly one existing revision snapshot.
class ReplyVariantIndex {
  final List<int?> archiveIds;
  final int selected;
  const ReplyVariantIndex(this.archiveIds, this.selected);
}

abstract final class ReplyVariants {
  static Future<Set<String>> _archivedMedia(
    DatabaseExecutor db,
    String conversation,
  ) async {
    final rows = await db.query(
      'message_revisions',
      columns: ['snapshot_json'],
      where: 'conversation_id = ?',
      whereArgs: [conversation],
    );
    final paths = <String>{};
    for (final row in rows) {
      try {
        final snapshot = jsonDecode(row['snapshot_json'] as String);
        if (snapshot is Map) {
          paths.addAll(
            DatabaseHelper._imagePathsFromRow(
              Map<String, Object?>.from(snapshot),
            ),
          );
          final prompt = snapshot['reply_user_snapshot'];
          if (prompt is Map) {
            paths.addAll(
              DatabaseHelper._imagePathsFromRow(
                Map<String, Object?>.from(prompt),
              ),
            );
          }
        }
      } on FormatException {
        // A damaged legacy audit snapshot must not block conversation deletion.
      }
    }
    return paths;
  }

  static Future<int?> _precedingUser(
    DatabaseExecutor db,
    String conversation, {
    int? beforeId,
  }) async {
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where:
          'conversation_id = ? AND is_user = 1'
          '${beforeId == null ? '' : ' AND id < ?'}',
      whereArgs: [conversation, ?beforeId],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['id'] as int;
  }

  static Future<void> _clearPending(DatabaseExecutor db, int messageId) async {
    // Confirmed memories and rejection tombstones are intentionally untouched.
    await db.delete(
      'pending_memory_actions',
      where:
          "source_message_id = ? AND status IN ('pending','snoozed','failed','stale')",
      whereArgs: [messageId],
    );
  }

  static Future<Map<String, Object?>?> _latestReply(
    DatabaseExecutor db,
    int messageId,
  ) async {
    final rows = await db.query(
      'messages',
      where: 'id = ? AND is_user = 0',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final later = await db.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ? AND id > ?',
      whereArgs: [row['conversation_id'], messageId],
      limit: 1,
    );
    return later.isEmpty ? row : null;
  }

  /// Editing/resending a user turn is the only UI path creating new choices.
  /// Preserve the turn id and archive its direct replies BEFORE updating its
  /// text. Later turns are discarded as ordinary history edits, not choices.
  static Future<Message?> prepareUserResend(int userId, String text) async {
    if (text.trim().isEmpty) return null;
    final db = await DatabaseHelper.database;
    final deletedMedia = <String>{};
    final edited = await db.transaction<Message?>((txn) async {
      final prompts = await txn.query(
        'messages',
        where: 'id = ? AND is_user = 1',
        whereArgs: [userId],
        limit: 1,
      );
      if (prompts.isEmpty) return null;
      final prompt = prompts.single;
      final conversation = prompt['conversation_id'] as String;
      final following = await txn.query(
        'messages',
        where: 'conversation_id = ? AND id > ?',
        whereArgs: [conversation, userId],
        orderBy: 'id ASC',
      );
      var directReply = true;
      for (final row in following) {
        final id = row['id'] as int;
        if (row['is_user'] == 1) directReply = false;
        final retainReply =
            directReply && row['is_user'] == 0 && (row['status'] ?? '') == '';
        await DatabaseHelper._archiveMessageRevision(
          txn,
          row,
          reason: retainReply ? 'user_resend' : 'history_edit',
        );
        await _clearPending(txn, id);
        await DatabaseHelper._invalidateSummaryChainForMessage(
          txn,
          conversationId: conversation,
          messageId: id,
          reason: 'history_edit',
        );
        if (row['is_user'] == 1) {
          // These later turns are no longer valid continuations of this prompt.
          await txn.delete(
            'message_revisions',
            where: 'reply_user_message_id = ?',
            whereArgs: [id],
          );
        }
        if (!retainReply) {
          deletedMedia.addAll(DatabaseHelper._imagePathsFromRow(row));
        }
      }
      await txn.delete(
        'chat_diagnostics',
        where:
            'conversation_id = ? AND (source_message_id >= ? OR anchor_message_id >= ?)',
        whereArgs: [conversation, userId, userId],
      );
      await txn.delete(
        'messages',
        where: 'conversation_id = ? AND id > ?',
        whereArgs: [conversation, userId],
      );
      await _clearPending(txn, userId);
      await DatabaseHelper._archiveMessageRevision(txn, prompt, reason: 'edit');
      await DatabaseHelper._invalidateSummaryChainForMessage(
        txn,
        conversationId: conversation,
        messageId: userId,
        reason: 'edit',
      );
      final replacement = <String, Object?>{
        'text': text,
        'revision': (prompt['revision'] as int? ?? 1) + 1,
        'summary_recorded': 0,
      };
      await txn.update(
        'messages',
        replacement,
        where: 'id = ?',
        whereArgs: [userId],
      );
      // Never remove media still referenced by a retained reply or this prompt.
      deletedMedia.removeAll(await _archivedMedia(txn, conversation));
      final remaining = await txn.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversation],
      );
      for (final row in remaining) {
        deletedMedia.removeAll(DatabaseHelper._imagePathsFromRow(row));
      }
      return Message.fromMap({...prompt, ...replacement});
    });
    await AppFileSafety.deleteOwnedFiles(deletedMedia);
    return edited;
  }

  static Future<ReplyVariantIndex> index(int messageId) async {
    final db = await DatabaseHelper.database;
    final row = await _latestReply(db, messageId);
    if (row == null) return const ReplyVariantIndex([], 0);
    final userId =
        row['reply_to_message_id'] ??
        await _precedingUser(
          db,
          row['conversation_id'] as String,
          beforeId: messageId,
        );
    if (userId == null) return const ReplyVariantIndex([null], 0);
    final prompts = await db.query(
      'messages',
      columns: ['text'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    final promptText = prompts.isEmpty ? '' : prompts.single['text'];
    // Group by actual visible content, not archive revision: switching back
    // and forth never creates duplicate choices. SQL does not return bodies.
    final archived = await db.rawQuery(
      '''
      SELECT MIN(id) AS archive_id,
        (json_extract(snapshot_json, '\$.text') = ? AND
         COALESCE(json_extract(snapshot_json, '\$.image_paths_json'), '[]') = ? AND
         COALESCE(json_extract(snapshot_json, '\$.reply_user_snapshot.text'), ?) = ?)
         AS is_selected
      FROM message_revisions
      WHERE conversation_id = ? AND reply_user_message_id = ?
        AND archive_reason IN ('reroll', 'user_resend', 'reply_switch')
        AND json_extract(snapshot_json, '\$.is_user') = 0
        AND COALESCE(json_extract(snapshot_json, '\$.status'), '') = ''
      GROUP BY json_extract(snapshot_json, '\$.text'),
        COALESCE(json_extract(snapshot_json, '\$.image_paths_json'), '[]'),
        COALESCE(json_extract(snapshot_json, '\$.reply_user_snapshot.text'), ?)
      ORDER BY archive_id
    ''',
      [
        row['text'],
        row['image_paths_json'] ?? '[]',
        promptText,
        promptText,
        row['conversation_id'],
        userId,
        promptText,
      ],
    );
    final ids = <int?>[];
    int? selected;
    for (final archivedRow in archived) {
      if (archivedRow['is_selected'] == 1) selected = ids.length;
      ids.add(archivedRow['archive_id'] as int);
    }
    if (selected == null) {
      selected = ids.length;
      ids.add(null);
    }
    return ReplyVariantIndex(List.unmodifiable(ids), selected);
  }

  static Future<Message?> select(int messageId, int archiveId) async {
    final db = await DatabaseHelper.database;
    return db.transaction<Message?>((txn) async {
      final current = await _latestReply(txn, messageId);
      if (current == null) return null;
      final userId =
          current['reply_to_message_id'] ??
          await _precedingUser(
            txn,
            current['conversation_id'] as String,
            beforeId: messageId,
          );
      final archives = await txn.query(
        'message_revisions',
        where:
            "id = ? AND conversation_id = ? AND reply_user_message_id = ? "
            "AND archive_reason IN ('reroll','user_resend','reply_switch')",
        whereArgs: [archiveId, current['conversation_id'], userId],
        limit: 1,
      );
      if (archives.isEmpty) return null;
      final snapshot = Map<String, Object?>.from(
        jsonDecode(archives.single['snapshot_json'] as String) as Map,
      );
      if (snapshot['is_user'] != 0 || (snapshot['status'] ?? '') != '') {
        return null;
      }
      final prompts = await txn.query(
        'messages',
        where: 'id = ? AND is_user = 1',
        whereArgs: [userId],
        limit: 1,
      );
      if (prompts.isEmpty) return null;
      final prompt = prompts.single;
      final archivedPrompt = snapshot['reply_user_snapshot'];
      final pairedPrompt =
          archivedPrompt is Map &&
          archivedPrompt['id'] == userId &&
          archivedPrompt['conversation_id'] == current['conversation_id'] &&
          archivedPrompt['is_user'] == 1;
      if (snapshot['text'] == current['text'] &&
          snapshot['image_paths_json'] == current['image_paths_json'] &&
          (!pairedPrompt || prompt['text'] == archivedPrompt['text'])) {
        return Message.fromMap(current);
      }
      await DatabaseHelper._archiveMessageRevision(
        txn,
        current,
        reason: 'reply_switch',
      );
      // A reply belongs to the version of the user prompt that produced it.
      // Restore the pair together so continuing never combines new wording
      // with an old answer. Static character settings are not touched.
      if (pairedPrompt) {
        if (prompt['text'] != archivedPrompt['text']) {
          await DatabaseHelper._archiveMessageRevision(
            txn,
            prompt,
            reason: 'edit',
          );
          await _clearPending(txn, userId as int);
          await DatabaseHelper._invalidateSummaryChainForMessage(
            txn,
            conversationId: current['conversation_id'] as String,
            messageId: userId,
            reason: 'reply_switch',
          );
          await txn.update(
            'messages',
            {
              'text': archivedPrompt['text'],
              'revision': (prompt['revision'] as int? ?? 1) + 1,
              'summary_recorded': 0,
            },
            where: 'id = ?',
            whereArgs: [userId],
          );
        }
      }
      await _clearPending(txn, messageId);
      await DatabaseHelper._invalidateSummaryChainForMessage(
        txn,
        conversationId: current['conversation_id'] as String,
        messageId: messageId,
        reason: 'reply_switch',
      );
      final replacement = <String, Object?>{
        for (final key in [
          'text',
          'image_path',
          'image_paths_json',
          'split_mode',
          'web_search_trace_json',
          'email_draft_json',
          'cache_hit',
          'status',
        ])
          key: snapshot[key] ?? current[key],
        'memory_log':
            '', // Never resurrect old pending proposals or execute tools.
        'summary_recorded': 0,
        'revision': (current['revision'] as int? ?? 1) + 1,
        'reply_to_message_id': userId,
      };
      await txn.update(
        'messages',
        replacement,
        where: 'id = ?',
        whereArgs: [messageId],
      );
      return Message.fromMap({...current, ...replacement});
    });
  }
}
