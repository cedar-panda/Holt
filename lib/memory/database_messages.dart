part of 'database.dart';

class _MessageStore {
  static Future<void> updateMessageDraw(
    int messageId,
    String? imagePath,
    String memoryLog,
  ) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'messages',
      {'image_path': ?imagePath, 'memory_log': memoryLog},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  static Future<List<Map<String, dynamic>>> searchMessages({
    required String keyword,
    required String characterId,
    String scope = 'current',
    ContextMode currentMode = ContextMode.daily,
    int limit = 5,
  }) async {
    final db = await DatabaseHelper.database;
    final normalizedScope =
        const <String>{'current', 'daily', 'rp', 'all'}.contains(scope)
        ? scope
        : 'current';
    final selectedMode = normalizedScope == 'current'
        ? currentMode.storageValue
        : normalizedScope;
    final modeClause = normalizedScope == 'all' ? '' : 'AND c.context_mode = ?';
    final orderPriority = normalizedScope == 'all'
        ? 'CASE WHEN c.context_mode = ? THEN 0 ELSE 1 END, '
        : '';
    final args = <Object?>[characterId];
    if (normalizedScope != 'all') args.add(selectedMode);
    args
      ..add(DatabaseHelper._likeContains(keyword))
      ..add(DatabaseHelper._likeContains(keyword));
    if (normalizedScope == 'all') args.add(currentMode.storageValue);
    args.add(limit);
    return db.rawQuery("""
        SELECT recent.id, recent.text, recent.is_user, recent.created_at,
               recent.title, recent.context_mode, recent.conversation_id
        FROM (
          SELECT m.id, m.text, m.is_user, m.created_at, c.title,
                 c.context_mode, c.id AS conversation_id
          FROM messages m
          INNER JOIN conversations c ON m.conversation_id = c.id
          WHERE m.character_id = ?
            $modeClause
            AND (m.text LIKE ? ESCAPE '\\' OR c.title LIKE ? ESCAPE '\\')
          ORDER BY $orderPriority m.created_at DESC, m.id DESC
          LIMIT ?
        ) AS recent
        ORDER BY recent.created_at ASC, recent.id ASC
      """, args);
  }

  static Future<DateTime?> getLastMessageTime(String characterId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT MAX(created_at) AS last FROM messages WHERE character_id = ?',
      [characterId],
    );
    final v = rows.isEmpty ? null : rows.first['last'] as String?;
    return v == null ? null : DateTime.tryParse(v);
  }

  static Future<Set<String>> getCharacterActiveDateKeys(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT m.created_at
        FROM messages m
        INNER JOIN conversations c ON c.id = m.conversation_id
        WHERE m.character_id = ?
          AND m.is_user = 1
          AND c.context_mode = ?
        ORDER BY m.created_at ASC, m.id ASC
        ''',
      [characterId, contextMode.storageValue],
    );
    final dates = <String>{};
    for (final row in rows) {
      final parsed = DateTime.tryParse(row['created_at']?.toString() ?? '');
      if (parsed == null) continue;
      final local = parsed.isUtc ? parsed.toLocal() : parsed;
      dates.add(
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}',
      );
    }
    return dates;
  }

  static Future<int> insertMessage(Message msg) async {
    final db = await DatabaseHelper.database;
    final id = await db.transaction<int>((txn) async {
      final row = msg.toMap();
      if (!msg.isUser) {
        row['reply_to_message_id'] = await ReplyVariants._precedingUser(
          txn,
          msg.conversationId,
        );
      }
      return txn.insert('messages', row);
    });
    await _ConversationStore.updateConversation(msg.conversationId);
    return id;
  }

  static Future<List<Message>> getMessagesFromId(
    String conversationId,
    int fromId,
  ) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id >= ?',
      whereArgs: [conversationId, fromId],
      orderBy: 'created_at ASC, id ASC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  static Future<List<Message>> getMessagesAfterId(
    String conversationId,
    int afterId,
  ) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id > ?',
      whereArgs: [conversationId, afterId],
      orderBy: 'id ASC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  static Future<int?> getLatestMessageId(String conversationId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'messages',
      columns: const <String>['id'],
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  static Future<Set<int>> getSummaryRecordedMessageIds(
    String conversationId,
  ) async {
    return (await getSummaryRecordedAnchors(conversationId)).keys.toSet();
  }

  static Future<Map<int, int>> getSummaryRecordedAnchors(
    String conversationId,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'context_summaries',
      columns: const <String>['id', 'display_anchor_message_id'],
      where:
          "source_conversation_id = ? AND revision_status = 'valid' "
          'AND display_anchor_message_id IS NOT NULL',
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at ASC, id ASC',
    );
    final anchors = <int, int>{};
    for (final row in rows) {
      final messageId = row['display_anchor_message_id'] as int?;
      final summaryId = row['id'] as int?;
      if (messageId != null && summaryId != null) {
        anchors[messageId] = summaryId;
      }
    }
    if (anchors.isNotEmpty) return anchors;

    final legacyMarkers = await db.query(
      'messages',
      columns: const <String>['id'],
      where: 'conversation_id = ? AND summary_recorded = 1',
      whereArgs: <Object?>[conversationId],
      limit: 1,
    );
    if (legacyMarkers.isEmpty) return anchors;

    final summaries = await db.query(
      'context_summaries',
      columns: const <String>['id', 'created_at'],
      where: "source_conversation_id = ? AND revision_status = 'valid'",
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    if (summaries.isEmpty) return anchors;
    final summaryId = summaries.first['id'] as int?;
    final completedAt = summaries.first['created_at']?.toString();
    if (summaryId == null || completedAt == null) return anchors;

    final messageRows = await db.query(
      'messages',
      columns: const <String>['id'],
      where: 'conversation_id = ? AND created_at <= ?',
      whereArgs: <Object?>[conversationId, completedAt],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    final messageId = messageRows.isEmpty
        ? null
        : messageRows.first['id'] as int?;
    if (messageId != null) anchors[messageId] = summaryId;
    return anchors;
  }

  static Future<String> branchConversation({
    required String sourceConversationId,
    required int beforeMessageId,
    String? title,
  }) async {
    final db = await DatabaseHelper.database;
    final src = await _ConversationStore.getConversation(sourceConversationId);
    if (src == null) {
      throw StateError('Source conversation $sourceConversationId not found');
    }
    final newId = const Uuid().v4();
    final branchTitle =
        title ??
        ((src.title?.isNotEmpty ?? false) ? '⑂ ${src.title}' : '⑂ 分支對話');

    await db.transaction((txn) async {
      await txn.insert(
        'conversations',
        Conversation(
          id: newId,
          characterId: src.characterId,
          contextMode: src.contextMode,
          continuityId: src.continuityId,
          userPersonaId: src.userPersonaId,
          userPersonaSnapshot: src.userPersonaSnapshot,
          worldbookSetId: src.worldbookSetId,
          title: branchTitle,
        ).toMap(),
      );
      final msgs = await txn.query(
        'messages',
        where: 'conversation_id = ? AND id < ?',
        whereArgs: [sourceConversationId, beforeMessageId],
        orderBy: 'created_at ASC, id ASC',
      );
      final batch = txn.batch();
      for (final m in msgs) {
        final copy = Map<String, dynamic>.from(m)
          ..remove('id')
          ..['conversation_id'] = newId;
        batch.insert('messages', copy);
      }
      await batch.commit(noResult: true);
    });
    return newId;
  }

  static Future<List<Message>> getMessagesBeforeId(
    String conversationId,
    int beforeId, {
    int limit = 50,
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id < ?',
      whereArgs: [conversationId, beforeId],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return maps.map((m) => Message.fromMap(m)).toList().reversed.toList();
  }

  static Future<bool> hasMessagesBefore(
    String conversationId,
    int beforeId,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ? AND id < ?',
      whereArgs: [conversationId, beforeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<List<Message>> getMessages(
    String conversationId, {
    int? limit,
    int? offset,
  }) async {
    final db = await DatabaseHelper.database;
    if (limit != null) {
      final maps = await db.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at DESC, id DESC',
        limit: limit,
        offset: offset,
      );
      return maps.map((m) => Message.fromMap(m)).toList().reversed.toList();
    } else {
      final maps = await db.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at ASC, id ASC',
      );
      return maps.map((m) => Message.fromMap(m)).toList();
    }
  }

  static Future<List<Message>> getMessagesUpToId(
    String conversationId,
    int throughMessageId, {
    int limit = 50,
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id <= ?',
      whereArgs: <Object?>[conversationId, throughMessageId],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return maps.map(Message.fromMap).toList().reversed.toList();
  }

  static Future<int> getMessageCount(String conversationId) async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['count'] as int;
  }

  static Future<int> getRpStorylineSourceCharacterCount({
    required String characterId,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT COALESCE(SUM(LENGTH(m.text)), 0) AS source_chars
        FROM messages m
        INNER JOIN conversations c ON c.id = m.conversation_id
        WHERE c.character_id = ?
          AND c.context_mode = 'rp'
          AND c.continuity_id = ?
          AND trim(m.text) != ''
        ''',
      <Object?>[
        characterId,
        continuityId.trim().isEmpty ? 'main' : continuityId,
      ],
    );
    return (rows.first['source_chars'] as num?)?.toInt() ?? 0;
  }

  static Future<Message?> getLastMessage(String conversationId) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Message.fromMap(maps.first);
  }

  static Future<void> deleteMessageById(
    int id, {
    String reason = 'delete',
  }) async {
    final db = await DatabaseHelper.database;
    final imagePaths = await db.transaction<List<String>>((txn) async {
      final rows = await txn.query(
        'messages',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return const <String>[];
      final row = rows.single;
      await ReplyVariants._clearPending(txn, id);
      if (row['is_user'] == 1) {
        await txn.delete(
          'message_revisions',
          where: 'reply_user_message_id = ?',
          whereArgs: [id],
        );
      }
      await _MessageInvalidation._archiveMessageRevision(
        txn,
        row,
        reason: reason,
      );
      await _MessageInvalidation._invalidateSummaryChainForMessage(
        txn,
        conversationId: row['conversation_id'] as String,
        messageId: id,
        reason: reason,
      );
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      // Regenerated replies may be selected again; keep their referenced media.
      return reason == 'reroll' && row['is_user'] == 0
          ? const <String>[]
          : rows.expand(DatabaseHelper._imagePathsFromRow).toSet().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  static Future<void> deleteMessageByFingerprint(
    Message msg, {
    String reason = 'delete',
  }) async {
    final db = await DatabaseHelper.database;
    final imagePaths = await db.transaction<List<String>>((txn) async {
      const where =
          'conversation_id = ? AND character_id = ? AND text = ? '
          'AND is_user = ? AND created_at = ?';
      final args = [
        msg.conversationId,
        msg.characterId,
        msg.text,
        msg.isUser ? 1 : 0,
        msg.createdAt.toIso8601String(),
      ];
      final rows = await txn.query('messages', where: where, whereArgs: args);
      for (final row in rows) {
        final messageId = row['id'] as int?;
        final conversationId = row['conversation_id'] as String?;
        if (messageId == null || conversationId == null) continue;
        await ReplyVariants._clearPending(txn, messageId);
        await _MessageInvalidation._archiveMessageRevision(
          txn,
          row,
          reason: reason,
        );
        await _MessageInvalidation._invalidateSummaryChainForMessage(
          txn,
          conversationId: conversationId,
          messageId: messageId,
          reason: reason,
        );
      }
      await txn.delete('messages', where: where, whereArgs: args);
      return rows.expand(DatabaseHelper._imagePathsFromRow).toSet().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  static Future<Message?> getMessageById(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  static Future<bool> messageSnapshotsStillCurrent(
    Iterable<Message> snapshots,
  ) async {
    final expected = <int, int>{};
    for (final message in snapshots) {
      final id = message.id;
      if (id != null) expected[id] = message.revision;
    }
    if (expected.isEmpty) return true;
    final db = await DatabaseHelper.database;
    final placeholders = List.filled(expected.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, revision FROM messages WHERE id IN ($placeholders)',
      <Object?>[...expected.keys],
    );
    if (rows.length != expected.length) return false;
    for (final row in rows) {
      final id = row['id'] as int?;
      if (id == null || (row['revision'] as int? ?? 1) != expected[id]) {
        return false;
      }
    }
    return true;
  }

  static Future<List<ChatDiagnosticEvent>> getChatDiagnostics(
    String conversationId,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'chat_diagnostics',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(ChatDiagnosticEvent.fromMap).toList(growable: false);
  }

  static Future<ChatDiagnosticEvent> upsertChatDiagnostic(
    ChatDiagnosticEvent event,
  ) async {
    final db = await DatabaseHelper.database;
    final id = await db.transaction<int>((txn) async {
      final existing = await txn.query(
        'chat_diagnostics',
        columns: const <String>['id'],
        where: 'conversation_id = ? AND source_message_id = ?',
        whereArgs: <Object?>[event.conversationId, event.sourceMessageId],
        limit: 1,
      );
      final values = event.toMap()..remove('id');
      if (existing.isNotEmpty) {
        final existingId = existing.single['id'] as int;
        await txn.update(
          'chat_diagnostics',
          values,
          where: 'id = ?',
          whereArgs: <Object?>[existingId],
        );
        return existingId;
      }
      return txn.insert('chat_diagnostics', values);
    });
    return ChatDiagnosticEvent(
      id: id,
      conversationId: event.conversationId,
      sourceMessageId: event.sourceMessageId,
      anchorMessageId: event.anchorMessageId,
      category: event.category,
      statusCode: event.statusCode,
      provider: event.provider,
      model: event.model,
      rawLog: event.rawLog,
      createdAt: event.createdAt,
    );
  }

  static Future<void> deleteChatDiagnostic(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'chat_diagnostics',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  static Future<void> deleteChatDiagnosticsForMessages(
    Iterable<int> messageIds,
  ) async {
    final ids = messageIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final db = await DatabaseHelper.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      'chat_diagnostics',
      where:
          'source_message_id IN ($placeholders) OR '
          'anchor_message_id IN ($placeholders)',
      whereArgs: <Object?>[...ids, ...ids],
    );
  }

  static Future<void> updateMessageText(int id, String newText) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        'messages',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.single;
      if ((row['text'] as String? ?? '') == newText) return;
      await ReplyVariants._clearPending(txn, id);
      if (row['is_user'] == 1) {
        await txn.delete(
          'message_revisions',
          where: 'reply_user_message_id = ?',
          whereArgs: [id],
        );
      }
      await _MessageInvalidation._archiveMessageRevision(
        txn,
        row,
        reason: 'edit',
      );
      await _MessageInvalidation._invalidateSummaryChainForMessage(
        txn,
        conversationId: row['conversation_id'] as String,
        messageId: id,
        reason: 'edit',
      );
      await txn.rawUpdate(
        'UPDATE messages SET text = ?, revision = revision + 1, '
        'summary_recorded = 0, persona_card_json = ? WHERE id = ?',
        <Object?>[newText, '', id],
      );
    });
  }

  static Future<bool> updateMessagePersonaCard(
    int messageId,
    PersonaCardState state,
  ) async {
    final db = await DatabaseHelper.database;
    final updated = await db.update(
      'messages',
      <String, Object?>{'persona_card_json': state.encode()},
      where: 'id = ? AND is_user = 0',
      whereArgs: <Object?>[messageId],
    );
    return updated == 1;
  }

  static Future<bool> addCharacterFromPersonaCard({
    required int messageId,
    required Map<String, Object?> character,
    required PersonaCardState cardState,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'messages',
        columns: <String>['id'],
        where: 'id = ? AND is_user = 0',
        whereArgs: <Object?>[messageId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      await txn.insert('characters', character);
      final updated = await txn.update(
        'messages',
        <String, Object?>{'persona_card_json': cardState.encode()},
        where: 'id = ? AND is_user = 0',
        whereArgs: <Object?>[messageId],
      );
      if (updated != 1) {
        throw StateError('Source reply disappeared while adding character.');
      }
      return true;
    });
  }
}
