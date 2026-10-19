part of 'database.dart';

class _ContextSummaryStore {
  static Future<int> insertContextSummary({
    required String characterId,
    required String content,
    required int tokenCount,
    String sourceWindowId = '',
    String sourceConversationId = '',
    int? displayAnchorMessageId,
    int? sourceMessageStartId,
    int? sourceMessageEndId,
    int? replaceSummaryId,
    bool replaceInvalidatedSummary = false,
    String storyTimeText = '',
    List<Message> expectedSourceMessages = const <Message>[],
    bool allowPendingRepairs = false,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    List<ContextSummarySegmentDraft> recallSegments =
        const <ContextSummarySegmentDraft>[],
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      if (!await _sourceMessagesMatch(
        txn,
        sourceConversationId,
        expectedSourceMessages,
      )) {
        return 0;
      }
      if (replaceSummaryId == null &&
          !allowPendingRepairs &&
          await _hasPendingSummaryRepairs(
            txn,
            characterId,
            contextMode,
            continuityId,
          )) {
        return 0;
      }
      Map<String, Object?>? replacement;
      int? parentId;
      if (replaceSummaryId != null) {
        final replacementRows = await txn.query(
          'context_summaries',
          where:
              'id = ? AND character_id = ? AND context_mode = ? '
              "AND continuity_id = ? AND revision_status = ? "
              'AND (? = 1 OR archived = 0)',
          whereArgs: <Object?>[
            replaceSummaryId,
            characterId,
            contextMode.storageValue,
            continuityId,
            replaceInvalidatedSummary ? 'invalidated' : 'valid',
            replaceInvalidatedSummary ? 1 : 0,
          ],
          limit: 1,
        );
        if (replacementRows.isEmpty) return 0;
        replacement = replacementRows.single;
        final targetConversation =
            replacement['source_conversation_id']?.toString() ?? '';
        if (targetConversation != sourceConversationId ||
            replacement['source_span_status']?.toString() != 'exact' ||
            sourceMessageStartId == null ||
            sourceMessageEndId == null ||
            replacement['source_message_start_id'] != sourceMessageStartId ||
            (!replaceInvalidatedSummary &&
                replacement['source_message_end_id'] != sourceMessageEndId)) {
          return 0;
        }
        final originalParentId = replacement['parent_summary_id'] as int?;
        parentId = originalParentId;
        if (replaceInvalidatedSummary && originalParentId != null) {
          final mappedParent = await txn.query(
            'context_summaries',
            columns: const <String>['id'],
            where:
                'replaces_summary_id = ? AND revision_status = ? '
                'AND character_id = ? AND context_mode = ? '
                'AND continuity_id = ?',
            whereArgs: <Object?>[
              originalParentId,
              'valid',
              characterId,
              contextMode.storageValue,
              continuityId,
            ],
            orderBy: 'revision DESC, id DESC',
            limit: 1,
          );
          if (mappedParent.isNotEmpty) {
            parentId = mappedParent.single['id'] as int?;
          } else {
            final stillValidParent = await txn.query(
              'context_summaries',
              columns: const <String>['id'],
              where: 'id = ? AND revision_status = ?',
              whereArgs: <Object?>[originalParentId, 'valid'],
              limit: 1,
            );
            if (stillValidParent.isEmpty) return 0;
          }
        }
        if (!replaceInvalidatedSummary) {
          await _MessageInvalidation._invalidateSummaryChainForMessage(
            txn,
            conversationId: targetConversation,
            messageId: sourceMessageStartId,
            reason: 'summary_rewrite',
          );
        }
        await txn.update(
          'context_summary_repairs',
          <String, Object?>{
            'status': 'completed',
            'last_error': '',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'original_summary_id = ?',
          whereArgs: <Object?>[replaceSummaryId],
        );
      } else {
        parentId = await _latestValidSummaryId(
          txn,
          characterId: characterId,
          contextMode: contextMode,
          continuityId: continuityId,
        );
      }
      final createdAt =
          replacement?['created_at']?.toString() ??
          DateTime.now().toIso8601String();
      final displayAnchor = replacement?['display_anchor_message_id'] as int?;
      final id = await txn.insert('context_summaries', {
        'character_id': characterId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': sourceConversationId,
        'display_anchor_message_id': displayAnchor ?? displayAnchorMessageId,
        'parent_summary_id': parentId,
        'replaces_summary_id': replaceSummaryId,
        'source_message_start_id': sourceMessageStartId,
        'source_message_end_id': sourceMessageEndId,
        'source_span_status':
            sourceMessageStartId != null && sourceMessageEndId != null
            ? 'exact'
            : 'unknown',
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId,
        'story_time_text': storyTimeText,
        'content': content,
        'token_count': tokenCount,
        'revision': (replacement?['revision'] as int? ?? 0) + 1,
        'created_at': createdAt,
      });
      await _replaceContextSummarySegments(
        txn,
        summaryId: id,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        sourceWindowId: sourceWindowId,
        sourceConversationId: sourceConversationId,
        createdAt: createdAt,
        segments: recallSegments,
      );
      final anchor = displayAnchor ?? displayAnchorMessageId;
      if (anchor != null && sourceConversationId.isNotEmpty) {
        await txn.update(
          'messages',
          <String, Object?>{'summary_recorded': 1},
          where: 'id = ? AND conversation_id = ?',
          whereArgs: <Object?>[anchor, sourceConversationId],
        );
      }
      return id;
    });
  }

  static Future<int> insertContextSummaryAndAdvanceCursor({
    required String characterId,
    required String content,
    required int tokenCount,
    required String conversationId,
    required int cursorMessageId,
    int? displayAnchorMessageId,
    int? sourceMessageStartId,
    String storyTimeText = '',
    String sourceWindowId = '',
    List<Message> expectedSourceMessages = const <Message>[],
    bool allowPendingRepairs = false,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    List<ContextSummarySegmentDraft> recallSegments =
        const <ContextSummarySegmentDraft>[],
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      if (!await _sourceMessagesMatch(
        txn,
        conversationId,
        expectedSourceMessages,
      )) {
        return 0;
      }
      if (!allowPendingRepairs) {
        if (await _hasPendingSummaryRepairs(
          txn,
          characterId,
          contextMode,
          continuityId,
        )) {
          return 0;
        }
      }
      final conversationRows = await txn.query(
        'conversations',
        columns: const <String>['summary_cursor_message_id'],
        where: 'id = ?',
        whereArgs: <Object?>[conversationId],
        limit: 1,
      );
      if (conversationRows.isEmpty) {
        throw StateError('Conversation $conversationId does not exist');
      }
      final previousCursor =
          conversationRows.first['summary_cursor_message_id'] as int? ?? 0;
      final resolvedStartId =
          sourceMessageStartId ??
          await _firstMessageIdInRange(
            txn,
            conversationId: conversationId,
            afterMessageId: previousCursor,
            throughMessageId: cursorMessageId,
          );
      final parentId = await _latestValidSummaryId(
        txn,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      final displayAnchorId = displayAnchorMessageId ?? cursorMessageId;
      final createdAt = DateTime.now().toIso8601String();
      final id = await txn.insert('context_summaries', {
        'character_id': characterId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': conversationId,
        'display_anchor_message_id': displayAnchorId,
        'parent_summary_id': parentId,
        'source_message_start_id': resolvedStartId,
        'source_message_end_id': cursorMessageId,
        'source_span_status': resolvedStartId == null ? 'unknown' : 'exact',
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId,
        'story_time_text': storyTimeText,
        'content': content,
        'token_count': tokenCount,
        'created_at': createdAt,
      });
      await _replaceContextSummarySegments(
        txn,
        summaryId: id,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
        sourceWindowId: sourceWindowId,
        sourceConversationId: conversationId,
        createdAt: createdAt,
        segments: recallSegments,
      );
      final changed = await txn.rawUpdate(
        '''
          UPDATE conversations
          SET summary_cursor_message_id = MAX(summary_cursor_message_id, ?)
          WHERE id = ?
          ''',
        [cursorMessageId, conversationId],
      );
      if (changed != 1) {
        throw StateError('Conversation $conversationId does not exist');
      }
      final marked = await txn.update(
        'messages',
        <String, Object?>{'summary_recorded': 1},
        where: 'id = ? AND conversation_id = ?',
        whereArgs: <Object?>[displayAnchorId, conversationId],
      );
      if (marked != 1) {
        throw StateError(
          'Summary display anchor $displayAnchorId does not exist in '
          '$conversationId',
        );
      }
      return id;
    });
  }

  static Future<int?> _latestValidSummaryId(
    DatabaseExecutor db, {
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final rows = await db.query(
      'context_summaries',
      columns: const <String>['id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid'",
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  static Future<void> _replaceContextSummarySegments(
    DatabaseExecutor db, {
    required int summaryId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String sourceWindowId,
    required String sourceConversationId,
    required String createdAt,
    required List<ContextSummarySegmentDraft> segments,
  }) async {
    await db.delete(
      'context_summary_segments',
      where: 'source_summary_id = ?',
      whereArgs: <Object?>[summaryId],
    );
    final usedOrders = <int>{};
    for (final segment in segments) {
      final content = segment.content.trim();
      final keywords = segment.keywords
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(1)
          .toList(growable: false);
      if (content.isEmpty ||
          keywords.isEmpty ||
          !usedOrders.add(segment.order)) {
        continue;
      }
      await db.insert('context_summary_segments', <String, Object?>{
        'source_summary_id': summaryId,
        'character_id': characterId,
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': sourceConversationId,
        'segment_order': segment.order,
        'title': segment.title.trim(),
        'content': content,
        'keywords': keywords.join(', '),
        'token_count': segment.tokenCount,
        'created_at': createdAt,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getContextSummarySegments(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    bool archivedOnly = false,
  }) async {
    final db = await DatabaseHelper.database;
    return db.rawQuery(
      '''
        SELECT segment.*, summary.archived, summary.revision_status
        FROM context_summary_segments AS segment
        INNER JOIN context_summaries AS summary
          ON summary.id = segment.source_summary_id
        WHERE segment.character_id = ?
          AND segment.context_mode = ?
          AND segment.continuity_id = ?
          AND summary.revision_status = 'valid'
          ${archivedOnly ? 'AND summary.archived = 1' : ''}
        ORDER BY segment.created_at ASC, segment.source_summary_id ASC,
          segment.segment_order ASC
        ''',
      <Object?>[characterId, contextMode.storageValue, continuityId],
    );
  }

  static Future<List<Map<String, dynamic>>> getRecallIndexRows(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = <Map<String, dynamic>>[];
    if (contextMode == ContextMode.rp) {
      if (DatabaseHelper._recallIndexHealedScopes.add(
        '$characterId|$continuityId',
      )) {
        await restoreArchivedSummaryKeywords(
          characterId: characterId,
          contextMode: contextMode,
          continuityId: continuityId,
        );
      }
      final segments = await db.rawQuery(
        '''
          SELECT segment.id, segment.source_summary_id, segment.segment_order,
            segment.title, segment.keywords, segment.source_window_id,
            segment.created_at
          FROM context_summary_segments AS segment
          INNER JOIN context_summaries AS summary
            ON summary.id = segment.source_summary_id
          WHERE segment.character_id = ?
            AND segment.context_mode = ?
            AND segment.continuity_id = ?
            AND summary.revision_status = 'valid'
          ORDER BY segment.created_at ASC, segment.source_summary_id ASC,
            segment.segment_order ASC
          ''',
        <Object?>[characterId, contextMode.storageValue, continuityId],
      );
      for (final row in segments) {
        rows.add(<String, dynamic>{...row, 'recall_kind': 'segment'});
      }
    }
    final indexedSummaryIds = rows
        .map((row) => row['source_summary_id'])
        .whereType<int>()
        .toSet();
    final labels = await db.query(
      'context_keywords',
      columns: const <String>[
        'id',
        'source_summary_id',
        'keywords',
        'source_window_id',
        'created_at',
      ],
      where: 'character_id = ? AND context_mode = ? AND continuity_id = ?',
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC',
    );
    for (final row in labels) {
      if (indexedSummaryIds.contains(row['source_summary_id'])) continue;
      rows.add(<String, dynamic>{...row, 'recall_kind': 'keyword'});
    }
    return rows;
  }

  static Future<List<Map<String, dynamic>>> fillRecallContents(
    List<Map<String, dynamic>> candidates,
  ) async {
    if (candidates.isEmpty) return const <Map<String, dynamic>>[];
    final db = await DatabaseHelper.database;
    Future<Map<int, String>> load(String sql, List<int> ids) async {
      if (ids.isEmpty) return const <int, String>{};
      final placeholders = List.filled(ids.length, '?').join(',');
      final result = await db.rawQuery('$sql ($placeholders)', ids);
      return <int, String>{
        for (final row in result)
          row['id'] as int: row['content'] as String? ?? '',
      };
    }

    List<int> idsOf(String kind) => <int>[
      for (final row in candidates)
        if (row['recall_kind'] == kind && row['id'] is int) row['id'] as int,
    ];
    final segmentContents = await load(
      'SELECT id, content FROM context_summary_segments WHERE id IN',
      idsOf('segment'),
    );
    final labelContents = await load(
      'SELECT id, source_summary_content AS content '
      'FROM context_keywords WHERE id IN',
      idsOf('keyword'),
    );
    return <Map<String, dynamic>>[
      for (final row in candidates)
        <String, dynamic>{
          ...row,
          'source_summary_content':
              (row['recall_kind'] == 'segment'
                  ? segmentContents
                  : labelContents)[row['id']] ??
              '',
        },
    ];
  }

  static Future<bool> _sourceMessagesMatch(
    DatabaseExecutor db,
    String conversationId,
    List<Message> snapshots,
  ) async {
    if (snapshots.isEmpty) return true;
    final expected = <int, int>{
      for (final message in snapshots)
        if (message.id != null) message.id!: message.revision,
    };
    if (expected.length != snapshots.length) return false;
    final placeholders = List.filled(expected.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, revision FROM messages WHERE conversation_id = ? '
      'AND id IN ($placeholders)',
      <Object?>[conversationId, ...expected.keys],
    );
    if (rows.length != expected.length) return false;
    return rows.every((row) {
      final id = row['id'] as int?;
      return id != null && (row['revision'] as int? ?? 1) == expected[id];
    });
  }

  static Future<bool> _hasPendingSummaryRepairs(
    DatabaseExecutor db,
    String characterId,
    ContextMode contextMode,
    String continuityId,
  ) async {
    final rows = await db.query(
      'context_summary_repairs',
      columns: const <String>['id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND status != 'completed'",
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<int?> _firstMessageIdInRange(
    DatabaseExecutor db, {
    required String conversationId,
    required int afterMessageId,
    required int throughMessageId,
  }) async {
    final rows = await db.rawQuery(
      'SELECT MIN(id) AS first_id FROM messages '
      'WHERE conversation_id = ? AND id > ? AND id <= ?',
      <Object?>[conversationId, afterMessageId, throughMessageId],
    );
    return rows.first['first_id'] as int?;
  }

  static Future<List<Map<String, dynamic>>> getContextSummaries(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    bool includeArchived = false,
  }) async {
    final db = await DatabaseHelper.database;
    return await db.rawQuery(
      '''
        SELECT summary.*,
               COALESCE(
                 source_end.created_at,
                 source_anchor.created_at,
                 source_start.created_at,
                 summary.created_at
               ) AS source_chronology_at,
               COALESCE(
                 summary.source_message_end_id,
                 summary.display_anchor_message_id,
                 summary.source_message_start_id,
                 summary.id
               ) AS source_chronology_id
        FROM context_summaries AS summary
        LEFT JOIN messages AS source_end
          ON source_end.id = summary.source_message_end_id
         AND source_end.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_anchor
          ON source_anchor.id = summary.display_anchor_message_id
         AND source_anchor.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_start
          ON source_start.id = summary.source_message_start_id
         AND source_start.conversation_id = summary.source_conversation_id
        WHERE summary.character_id = ?
          AND summary.context_mode = ?
          AND summary.continuity_id = ?
          AND summary.revision_status = 'valid'
          ${includeArchived ? '' : 'AND summary.archived = 0'}
        ORDER BY source_chronology_at ASC,
                 source_chronology_id ASC,
                 summary.id ASC
        ''',
      <Object?>[characterId, contextMode.storageValue, continuityId],
    );
  }

  static Future<Map<String, dynamic>?> getContextSummaryByExactSourceSpan({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String conversationId,
    required int sourceMessageStartId,
    required int sourceMessageEndId,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'context_summaries',
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND source_conversation_id = ? AND source_message_start_id = ? "
          "AND source_message_end_id = ? AND source_span_status = 'exact' "
          "AND revision_status = 'valid' AND archived = 0",
      whereArgs: <Object?>[
        characterId,
        contextMode.storageValue,
        continuityId,
        conversationId,
        sourceMessageStartId,
        sourceMessageEndId,
      ],
      orderBy: 'revision DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, dynamic>>> getLatestContextSummaries(
    String characterId, {
    String? excludeWindowId,
    int limit = 2,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final where = StringBuffer(
      'summary.character_id = ? AND summary.context_mode = ? '
      'AND summary.continuity_id = ? AND summary.archived = 0',
    )..write(" AND summary.revision_status = 'valid'");
    final args = <Object?>[characterId, contextMode.storageValue, continuityId];
    final excluded = (excludeWindowId ?? '').trim();
    if (excluded.isNotEmpty) {
      where.write(
        " AND (source_window_id IS NULL OR source_window_id = '' OR source_window_id != ?)",
      );
      args.add(excluded);
    }
    return await db.rawQuery(
      '''
        SELECT summary.*,
               COALESCE(
                 source_end.created_at,
                 source_anchor.created_at,
                 source_start.created_at,
                 summary.created_at
               ) AS source_chronology_at,
               COALESCE(
                 summary.source_message_end_id,
                 summary.display_anchor_message_id,
                 summary.source_message_start_id,
                 summary.id
               ) AS source_chronology_id
        FROM context_summaries AS summary
        LEFT JOIN messages AS source_end
          ON source_end.id = summary.source_message_end_id
         AND source_end.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_anchor
          ON source_anchor.id = summary.display_anchor_message_id
         AND source_anchor.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_start
          ON source_start.id = summary.source_message_start_id
         AND source_start.conversation_id = summary.source_conversation_id
        WHERE ${where.toString()}
        ORDER BY source_chronology_at DESC,
                 source_chronology_id DESC,
                 summary.id DESC
        LIMIT ?
        ''',
      <Object?>[...args, limit],
    );
  }

  static Future<List<Map<String, dynamic>>> getRelevantContextSummaries(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    Iterable<String> sourceConversationIds = const <String>[],
    int limit = 3,
  }) async {
    final db = await DatabaseHelper.database;
    final ids = sourceConversationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final where = StringBuffer(
      "summary.character_id = ? AND summary.context_mode = ? "
      "AND summary.continuity_id = ? "
      "AND summary.revision_status = 'valid'",
    );
    final args = <Object?>[characterId, contextMode.storageValue, continuityId];
    if (ids.isNotEmpty) {
      where.write(
        ' AND summary.source_conversation_id IN '
        '(${List.filled(ids.length, '?').join(',')})',
      );
      args.addAll(ids);
    }
    final rows = await db.rawQuery(
      '''
        SELECT summary.*,
               COALESCE(
                 source_end.created_at,
                 source_anchor.created_at,
                 source_start.created_at,
                 summary.created_at
               ) AS source_chronology_at,
               COALESCE(
                 summary.source_message_end_id,
                 summary.display_anchor_message_id,
                 summary.source_message_start_id,
                 summary.id
               ) AS source_chronology_id
        FROM context_summaries AS summary
        LEFT JOIN messages AS source_end
          ON source_end.id = summary.source_message_end_id
         AND source_end.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_anchor
          ON source_anchor.id = summary.display_anchor_message_id
         AND source_anchor.conversation_id = summary.source_conversation_id
        LEFT JOIN messages AS source_start
          ON source_start.id = summary.source_message_start_id
         AND source_start.conversation_id = summary.source_conversation_id
        WHERE ${where.toString()}
        ORDER BY source_chronology_at DESC,
                 source_chronology_id DESC,
                 summary.id DESC
        LIMIT ?
        ''',
      <Object?>[...args, limit.clamp(1, 10)],
    );
    if (rows.isNotEmpty || ids.isEmpty) return rows;
    return getLatestContextSummaries(
      characterId,
      limit: limit,
      contextMode: contextMode,
      continuityId: continuityId,
    );
  }

  static Future<Map<String, dynamic>?> getLatestConversationContextSummary({
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'context_summaries',
      where:
          'source_conversation_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid'",
      whereArgs: <Object?>[
        conversationId,
        contextMode.storageValue,
        continuityId,
      ],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>?> getConversationContextSummaryById({
    required int summaryId,
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'context_summaries',
      where:
          'id = ? AND source_conversation_id = ? AND context_mode = ? '
          "AND continuity_id = ? AND revision_status = 'valid'",
      whereArgs: <Object?>[
        summaryId,
        conversationId,
        contextMode.storageValue,
        continuityId,
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> getContextSummaryTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_summaries '
      "WHERE character_id = ? AND context_mode = ? AND continuity_id = ? "
      "AND archived = 0 AND revision_status = 'valid'",
      [characterId, contextMode.storageValue, continuityId],
    );
    return r.first['total'] as int;
  }

  static Future<void> updateContextSummary({
    required int id,
    required String content,
    required int tokenCount,
  }) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE context_summaries SET content = ?, token_count = ?, '
        'revision = revision + 1 WHERE id = ?',
        <Object?>[content, tokenCount, id],
      );
      // An archived original remains editable through its chat marker.
      await txn.update(
        'context_keywords',
        {'source_summary_content': content},
        where: 'source_summary_id = ?',
        whereArgs: [id],
      );
    });
  }

  static Future<bool> archiveContextSummaryWithKeywords({
    required int summaryId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String keywords,
    required int keywordTokenCount,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'context_summaries',
        where:
            'id = ? AND character_id = ? AND context_mode = ? '
            "AND continuity_id = ? AND archived = 0 "
            "AND revision_status = 'valid' AND COALESCE(locked, 0) = 0",
        whereArgs: [
          summaryId,
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final newest = await txn.query(
        'context_summaries',
        columns: const ['id'],
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND archived = 0 AND revision_status = 'valid'",
        whereArgs: [characterId, contextMode.storageValue, continuityId],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
      if (newest.isEmpty || newest.first['id'] == summaryId) return false;
      final row = rows.first;
      final existing = await txn.query(
        'context_keywords',
        columns: const ['id'],
        where: 'source_summary_id = ?',
        whereArgs: [summaryId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('context_keywords', {
          'character_id': characterId,
          'source_window_id': row['source_window_id'] as String? ?? '',
          'source_conversation_id':
              row['source_conversation_id'] as String? ?? '',
          'context_mode': contextMode.storageValue,
          'continuity_id': continuityId,
          'keywords': keywords,
          'token_count': keywordTokenCount,
          'source_summary_id': summaryId,
          'source_summary_content': row['content'] as String? ?? '',
          'created_at':
              row['created_at'] as String? ?? DateTime.now().toIso8601String(),
        });
      }
      await txn.update(
        'context_summaries',
        {'archived': 1},
        where: 'id = ?',
        whereArgs: [summaryId],
      );
      return true;
    });
  }

  static Future<bool> archiveContextSummaryWithStoredSegments({
    required int summaryId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'context_summaries',
        where:
            'id = ? AND character_id = ? AND context_mode = ? '
            "AND continuity_id = ? AND archived = 0 "
            "AND revision_status = 'valid' AND COALESCE(locked, 0) = 0",
        whereArgs: <Object?>[
          summaryId,
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final newest = await txn.query(
        'context_summaries',
        columns: const <String>['id'],
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND archived = 0 AND revision_status = 'valid'",
        whereArgs: <Object?>[
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
      if (newest.isEmpty || newest.first['id'] == summaryId) return false;
      final segments = await txn.query(
        'context_summary_segments',
        where: 'source_summary_id = ?',
        whereArgs: <Object?>[summaryId],
        orderBy: 'segment_order ASC',
      );
      if (segments.isEmpty) return false;
      final row = rows.single;
      for (final segment in segments) {
        final keywords = segment['keywords']?.toString().trim() ?? '';
        if (keywords.isEmpty) continue;
        await txn.insert('context_keywords', <String, Object?>{
          'character_id': characterId,
          'source_window_id': row['source_window_id'] as String? ?? '',
          'source_conversation_id':
              row['source_conversation_id'] as String? ?? '',
          'context_mode': contextMode.storageValue,
          'continuity_id': continuityId,
          'keywords': keywords,
          // This cap describes the always-loaded lookup index. The archived
          // paragraph is injected only after a match, so charging its full
          // token count here caused valid labels to evict one another.
          'token_count': _estimateContextKeywordTokens(keywords),
          'source_summary_id': summaryId,
          'source_summary_content': segment['content'] as String? ?? '',
          'created_at':
              row['created_at'] as String? ?? DateTime.now().toIso8601String(),
        });
      }
      await txn.update(
        'context_summaries',
        <String, Object?>{'archived': 1},
        where: 'id = ?',
        whereArgs: <Object?>[summaryId],
      );
      return true;
    });
  }

  static Future<int> completeCoveredSummaryRepairs({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String conversationId,
    required int sourceMessageStartId,
    required int sourceMessageEndId,
    required int replacementSummaryId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.update(
      'context_summary_repairs',
      <String, Object?>{
        'status': 'completed',
        'last_error': 'superseded_by_summary:$replacementSummaryId',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          'AND source_conversation_id = ? AND status != ? '
          'AND source_message_start_id >= ? AND source_message_end_id <= ?',
      whereArgs: <Object?>[
        characterId,
        contextMode.storageValue,
        continuityId,
        conversationId,
        'completed',
        sourceMessageStartId,
        sourceMessageEndId,
      ],
    );
  }

  static Future<int> restoreArchivedSummaryKeywords({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<int>(
      (txn) => _restoreArchivedSummaryKeywords(
        txn,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      ),
    );
  }

  static Future<int> _restoreArchivedSummaryKeywords(
    DatabaseExecutor db, {
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final existing = await db.query(
      'context_keywords',
      where: 'character_id = ? AND context_mode = ? AND continuity_id = ?',
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
    );
    for (final row in existing) {
      final keywords = row['keywords']?.toString().trim() ?? '';
      final corrected = _estimateContextKeywordTokens(keywords);
      if ((row['token_count'] as int? ?? 0) != corrected) {
        await db.update(
          'context_keywords',
          <String, Object?>{'token_count': corrected},
          where: 'id = ?',
          whereArgs: <Object?>[row['id']],
        );
      }
    }

    final summaries = await db.rawQuery(
      '''
        SELECT summary.*
        FROM context_summaries AS summary
        WHERE summary.character_id = ?
          AND summary.context_mode = ?
          AND summary.continuity_id = ?
          AND summary.archived = 1
          AND summary.revision_status = 'valid'
          AND EXISTS (
            SELECT 1 FROM context_summary_segments AS segment
            WHERE segment.source_summary_id = summary.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM context_keywords AS keyword
            WHERE keyword.source_summary_id = summary.id
          )
        ORDER BY summary.created_at DESC, summary.id DESC
        ''',
      <Object?>[characterId, contextMode.storageValue, continuityId],
    );

    var inserted = 0;
    for (final summary in summaries) {
      final summaryId = summary['id'] as int?;
      if (summaryId == null) continue;
      final segments = await db.query(
        'context_summary_segments',
        where: 'source_summary_id = ?',
        whereArgs: <Object?>[summaryId],
        orderBy: 'segment_order ASC',
      );
      for (final segment in segments) {
        final keywords = segment['keywords']?.toString().trim() ?? '';
        final content = segment['content']?.toString().trim() ?? '';
        if (keywords.isEmpty || content.isEmpty) continue;
        final cost = _estimateContextKeywordTokens(keywords);
        await db.insert('context_keywords', <String, Object?>{
          'character_id': characterId,
          'source_window_id': summary['source_window_id'] as String? ?? '',
          'source_conversation_id':
              summary['source_conversation_id'] as String? ?? '',
          'context_mode': contextMode.storageValue,
          'continuity_id': continuityId,
          'keywords': keywords,
          'token_count': cost,
          'source_summary_id': summaryId,
          'source_summary_content': content,
          'created_at':
              summary['created_at']?.toString() ??
              DateTime.now().toIso8601String(),
        });
        inserted++;
      }
    }
    return inserted;
  }

  static int _estimateContextKeywordTokens(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    // Retrieval labels are mostly CJK phrases. Four Latin characters per token
    // underestimates CJK badly, so count CJK runes directly and group the rest.
    var cjk = 0;
    var other = 0;
    for (final rune in trimmed.runes) {
      if ((rune >= 0x3400 && rune <= 0x9fff) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        cjk++;
      } else if (rune > 0x20) {
        other++;
      }
    }
    return max(1, cjk + ((other + 3) ~/ 4));
  }

  static Future<void> updateSummaryLockState({
    required int id,
    required bool locked,
  }) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'context_summaries',
      {'locked': locked ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteContextSummary(int id) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      await txn.delete(
        'context_keywords',
        where: 'source_summary_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'context_summary_segments',
        where: 'source_summary_id = ?',
        whereArgs: [id],
      );
      await txn.delete('context_summaries', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<Map<String, dynamic>?> deleteOldestContextSummary(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final oldest = await db.query(
      'context_summaries',
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid' AND (locked IS NULL OR locked = 0)",
      whereArgs: [characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (oldest.isEmpty) return null;
    await db.delete(
      'context_summaries',
      where: 'id = ?',
      whereArgs: [oldest.first['id']],
    );
    return oldest.first;
  }
}
