part of 'database.dart';

class _MessageInvalidation {
  static Future<void> _archiveMessageRevision(
    DatabaseExecutor db,
    Map<String, Object?> row, {
    required String reason,
  }) async {
    final messageId = row['id'] as int?;
    final conversationId = row['conversation_id'] as String?;
    if (messageId == null || conversationId == null) return;
    final userId = row['is_user'] == 0
        ? row['reply_to_message_id'] ??
              await ReplyVariants._precedingUser(
                db,
                conversationId,
                beforeId: messageId,
              )
        : null;
    final snapshot = Map<String, Object?>.from(row);
    if (userId != null) {
      final prompts = await db.query(
        'messages',
        where: 'id = ? AND conversation_id = ? AND is_user = 1',
        whereArgs: [userId, conversationId],
        limit: 1,
      );
      if (prompts.isNotEmpty) snapshot['reply_user_snapshot'] = prompts.single;
    }
    await db.insert('message_revisions', <String, Object?>{
      'message_id': messageId,
      'conversation_id': conversationId,
      'reply_user_message_id': userId,
      'revision': row['revision'] as int? ?? 1,
      'snapshot_json': jsonEncode(snapshot),
      'archive_reason': reason,
      'archived_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _invalidateSummaryChainForMessage(
    DatabaseExecutor db, {
    required String conversationId,
    required int messageId,
    required String reason,
  }) async {
    final roots = await db.rawQuery(
      '''
        SELECT id
        FROM context_summaries
        WHERE source_conversation_id = ?
          AND revision_status = 'valid'
          AND (
            (
              source_message_start_id IS NOT NULL
              AND source_message_end_id IS NOT NULL
              AND ? BETWEEN source_message_start_id AND source_message_end_id
            )
            OR (
              source_message_start_id IS NULL
              AND source_message_end_id IS NULL
              AND (
                display_anchor_message_id IS NULL
                OR display_anchor_message_id >= ?
              )
            )
          )
        ''',
      <Object?>[conversationId, messageId, messageId],
    );
    final invalidIds = roots
        .map((row) => row['id'] as int?)
        .whereType<int>()
        .toSet();
    if (invalidIds.isEmpty) return;

    var frontier = invalidIds.toList(growable: false);
    while (frontier.isNotEmpty) {
      final placeholders = List.filled(frontier.length, '?').join(',');
      final children = await db.rawQuery(
        'SELECT id FROM context_summaries '
        "WHERE revision_status = 'valid' "
        'AND parent_summary_id IN ($placeholders)',
        <Object?>[...frontier],
      );
      final next = children
          .map((row) => row['id'] as int?)
          .whereType<int>()
          .where(invalidIds.add)
          .toList(growable: false);
      frontier = next;
    }

    final placeholders = List.filled(invalidIds.length, '?').join(',');
    final affected = await db.rawQuery(
      'SELECT id, character_id, context_mode, continuity_id, '
      'source_conversation_id, display_anchor_message_id, '
      'source_message_start_id, source_message_end_id '
      'FROM context_summaries WHERE id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    final now = DateTime.now().toIso8601String();
    await db.rawUpdate(
      'UPDATE context_summaries SET revision_status = ?, invalidated_at = ?, '
      'invalidation_reason = ? WHERE id IN ($placeholders)',
      <Object?>['invalidated', now, reason, ...invalidIds],
    );
    // Queue exact source spans before removing any derived projections. Model
    // work happens later, outside this transaction. Legacy/manual summaries
    // without a reproducible message span stay invalidated and can still be
    // repaired manually; guessing a span here would risk importing unrelated
    // dialogue into the replacement chain.
    for (final summary in affected) {
      final originalSummaryId = summary['id'] as int?;
      final characterId = summary['character_id']?.toString().trim() ?? '';
      final sourceConversationId =
          summary['source_conversation_id']?.toString().trim() ?? '';
      final sourceStart = summary['source_message_start_id'] as int?;
      final sourceEnd = summary['source_message_end_id'] as int?;
      if (originalSummaryId == null ||
          characterId.isEmpty ||
          sourceConversationId.isEmpty ||
          sourceStart == null ||
          sourceEnd == null) {
        continue;
      }
      await db.insert('context_summary_repairs', <String, Object?>{
        'original_summary_id': originalSummaryId,
        'character_id': characterId,
        'context_mode': summary['context_mode']?.toString() ?? 'daily',
        'continuity_id': summary['continuity_id']?.toString() ?? 'main',
        'source_conversation_id': sourceConversationId,
        'source_message_start_id': sourceStart,
        'source_message_end_id': sourceEnd,
        'status': 'pending',
        'attempts': 0,
        'last_error': '',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.rawDelete(
      'DELETE FROM context_keywords WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    // Keep the immutable segment snapshot for audit and repair. All recall
    // readers join against context_summaries.revision_status='valid', so these
    // rows cannot leak stale story facts. Deleting them here used to make a
    // temporarily failed repair permanently lose its recall labels.
    // RP mutable state is a projection of one summary revision. Once that
    // revision is invalid, keeping its machine-written state would leak a
    // ghost injury, promise, identity or scene into the next reply. User edits
    // remain authoritative and are never removed by automatic rollback.
    await db.rawDelete(
      'DELETE FROM rp_story_states '
      'WHERE user_edited = 0 AND source_summary_id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    await _rollbackInvalidatedRpStoryProjections(
      db,
      invalidSummaryIds: invalidIds,
    );
    await _deleteInvalidatedRpTimelineProjection(
      db,
      affectedSummaries: affected,
      editedConversationId: conversationId,
      editedMessageId: messageId,
    );

    // Invalidating a newer archived summary removes its active keyword rows.
    // Refill every missing label from still-valid archived summaries; otherwise
    // earlier labels lost under the legacy bounded index never return.
    final affectedScopes = <String, Map<String, Object?>>{};
    for (final summary in affected) {
      final characterId = summary['character_id']?.toString().trim() ?? '';
      final mode = summary['context_mode']?.toString().trim() ?? 'daily';
      final continuity = summary['continuity_id']?.toString().trim() ?? 'main';
      if (characterId.isEmpty) continue;
      affectedScopes['$characterId\u0000$mode\u0000$continuity'] =
          <String, Object?>{
            'character_id': characterId,
            'context_mode': mode,
            'continuity_id': continuity,
          };
    }
    for (final scope in affectedScopes.values) {
      await _ContextSummaryStore._restoreArchivedSummaryKeywords(
        db,
        characterId: scope['character_id']! as String,
        contextMode: ContextMode.fromStorage(scope['context_mode']?.toString()),
        continuityId: scope['continuity_id']! as String,
      );
    }

    final anchorsByConversation = <String, Set<int>>{};
    for (final row in affected) {
      final sourceConversationId =
          row['source_conversation_id']?.toString().trim() ?? '';
      final anchor = row['display_anchor_message_id'] as int?;
      if (sourceConversationId.isEmpty || anchor == null) continue;
      anchorsByConversation
          .putIfAbsent(sourceConversationId, () => <int>{})
          .add(anchor);
    }
    for (final entry in anchorsByConversation.entries) {
      final anchorPlaceholders = List.filled(entry.value.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE messages SET summary_recorded = 0 '
        'WHERE conversation_id = ? AND id IN ($anchorPlaceholders)',
        <Object?>[entry.key, ...entry.value],
      );
    }

    final affectedConversations = <String>{conversationId};
    affectedConversations.addAll(anchorsByConversation.keys);
    for (final sourceConversationId in affectedConversations) {
      final cursorRows = await db.rawQuery(
        'SELECT COALESCE(MAX(COALESCE(source_message_end_id, '
        'display_anchor_message_id, 0)), 0) AS cursor '
        'FROM context_summaries '
        "WHERE source_conversation_id = ? AND revision_status = 'valid'",
        <Object?>[sourceConversationId],
      );
      final cursor = cursorRows.single['cursor'] as int? ?? 0;
      await db.update(
        'conversations',
        <String, Object?>{'summary_cursor_message_id': cursor},
        where: 'id = ?',
        whereArgs: <Object?>[sourceConversationId],
      );
    }
  }

  static Future<void> _rollbackInvalidatedRpStoryProjections(
    DatabaseExecutor db, {
    required Set<int> invalidSummaryIds,
  }) async {
    if (invalidSummaryIds.isEmpty) return;
    final placeholders = List.filled(invalidSummaryIds.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM rp_story_relationship_events '
      'WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidSummaryIds],
    );
    final revisions = await db.rawQuery(
      'SELECT * FROM rp_story_projection_revisions '
      'WHERE source_summary_id IN ($placeholders) ORDER BY id DESC',
      <Object?>[...invalidSummaryIds],
    );
    for (final revision in revisions) {
      final kind = revision['projection_table']?.toString() ?? '';
      final projectionId = revision['projection_id']?.toString() ?? '';
      final table = switch (kind) {
        'character' => 'rp_story_characters',
        'relationship' => 'rp_story_relationships',
        _ => '',
      };
      if (table.isEmpty || projectionId.isEmpty) continue;
      final current = await db.query(
        table,
        where: 'id = ?',
        whereArgs: <Object?>[projectionId],
        limit: 1,
      );
      if (current.isNotEmpty && current.first['user_edited'] == 1) continue;

      if (revision['operation'] == 'create') {
        if (kind == 'relationship') {
          await db.delete(
            'rp_story_relationship_events',
            where: 'relationship_id = ?',
            whereArgs: <Object?>[projectionId],
          );
        } else if (current.isNotEmpty) {
          await db.delete(
            'rp_story_entity_aliases',
            where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
            whereArgs: <Object?>[
              current.first['character_id'],
              current.first['continuity_id'],
              current.first['entity_key'],
            ],
          );
        }
        await db.delete(
          table,
          where: 'id = ?',
          whereArgs: <Object?>[projectionId],
        );
        continue;
      }

      final rawSnapshot = revision['snapshot_json']?.toString() ?? '';
      try {
        final decoded = jsonDecode(rawSnapshot);
        if (decoded is! Map) continue;
        final snapshot = <String, Object?>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
        if (current.isEmpty) {
          await db.insert(table, snapshot);
        } else {
          await db.update(
            table,
            snapshot,
            where: 'id = ?',
            whereArgs: <Object?>[projectionId],
          );
        }
        if (kind == 'character') {
          await _restoreRpStoryCharacterAliases(db, snapshot);
        }
      } catch (_) {
        // A damaged audit snapshot must not replace the current projection.
      }
    }
    await db.rawDelete(
      'DELETE FROM rp_story_projection_revisions '
      'WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidSummaryIds],
    );
  }

  static Future<void> _restoreRpStoryCharacterAliases(
    DatabaseExecutor db,
    Map<String, Object?> character,
  ) async {
    final characterId = character['character_id']?.toString() ?? '';
    final continuityId = character['continuity_id']?.toString() ?? '';
    final entityKey = character['entity_key']?.toString() ?? '';
    if (characterId.isEmpty || continuityId.isEmpty || entityKey.isEmpty) {
      return;
    }
    await db.delete(
      'rp_story_entity_aliases',
      where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
      whereArgs: <Object?>[characterId, continuityId, entityKey],
    );
    final name = character['name']?.toString().trim() ?? '';
    final aliases = <String>{if (name.isNotEmpty) name};
    try {
      final decoded = jsonDecode(character['aliases_json']?.toString() ?? '');
      if (decoded is List) {
        aliases.addAll(
          decoded
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty),
        );
      }
    } catch (_) {
      // The stable name still restores the minimum safe alias map.
    }
    final createdAt =
        character['created_at']?.toString() ?? DateTime.now().toIso8601String();
    final updatedAt =
        character['updated_at']?.toString() ?? DateTime.now().toIso8601String();
    for (final alias in aliases) {
      final normalized = alias.toLowerCase().replaceAll(
        RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
        '',
      );
      if (normalized.isEmpty) continue;
      await db.insert('rp_story_entity_aliases', <String, Object?>{
        'character_id': characterId,
        'continuity_id': continuityId,
        'entity_key': entityKey,
        'normalized_alias': normalized,
        'display_alias': alias,
        'alias_type': alias == name ? 'name' : 'identity',
        'created_at': createdAt,
        'updated_at': updatedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> _deleteInvalidatedRpTimelineProjection(
    DatabaseExecutor db, {
    required List<Map<String, Object?>> affectedSummaries,
    required String editedConversationId,
    required int editedMessageId,
  }) async {
    final messageIdsByConversation = <String, Set<int>>{
      editedConversationId: <int>{editedMessageId},
    };
    for (final summary in affectedSummaries) {
      final sourceConversationId =
          summary['source_conversation_id']?.toString().trim() ?? '';
      if (sourceConversationId.isEmpty) continue;
      final ids = messageIdsByConversation.putIfAbsent(
        sourceConversationId,
        () => <int>{},
      );
      final start = summary['source_message_start_id'] as int?;
      final end = summary['source_message_end_id'] as int?;
      if (start != null && end != null) {
        final rows = await db.query(
          'messages',
          columns: const <String>['id'],
          where: 'conversation_id = ? AND id BETWEEN ? AND ?',
          whereArgs: <Object?>[sourceConversationId, start, end],
        );
        ids.addAll(rows.map((row) => row['id']).whereType<int>());
      } else {
        final anchor = summary['display_anchor_message_id'] as int?;
        if (anchor != null) ids.add(anchor);
      }
    }

    for (final entry in messageIdsByConversation.entries) {
      if (entry.value.isEmpty) continue;
      final rows = await db.query(
        'rp_character_timeline',
        columns: const <String>[
          'id',
          'source_message_id',
          'source_message_ids',
        ],
        where: 'source_conversation_id = ?',
        whereArgs: <Object?>[entry.key],
      );
      final staleIds = <int>[];
      for (final row in rows) {
        final sourceIds = <int>{};
        final primary = row['source_message_id'] as int?;
        if (primary != null) sourceIds.add(primary);
        final encoded = row['source_message_ids']?.toString() ?? '';
        if (encoded.isNotEmpty) {
          try {
            final decoded = jsonDecode(encoded);
            if (decoded is List) {
              sourceIds.addAll(decoded.whereType<int>());
            }
          } catch (_) {
            // The legacy primary id still provides a safe fallback.
          }
        }
        if (sourceIds.any(entry.value.contains)) {
          final id = row['id'] as int?;
          if (id != null) staleIds.add(id);
        }
      }
      if (staleIds.isEmpty) continue;
      final stalePlaceholders = List.filled(staleIds.length, '?').join(',');
      await db.rawDelete(
        'DELETE FROM rp_character_timeline '
        'WHERE id IN ($stalePlaceholders)',
        <Object?>[...staleIds],
      );
    }
  }

  static Future<void> updateMessageStatus(int id, String status) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
