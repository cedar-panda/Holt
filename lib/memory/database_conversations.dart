part of 'database.dart';

class _ConversationStore {
  static Future<void> createConversation(Conversation conv) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      if (conv.contextMode == ContextMode.rp) {
        await _ensureRpStoryline(
          txn,
          characterId: conv.characterId,
          storylineId: conv.continuityId,
        );
        await txn.update(
          'rp_storylines',
          <String, Object?>{'updated_at': DateTime.now().toIso8601String()},
          where: 'character_id = ? AND id = ?',
          whereArgs: <Object?>[conv.characterId, conv.continuityId],
        );
      }
      await txn.insert(
        'conversations',
        conv.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<void> _ensureRpStoryline(
    DatabaseExecutor db, {
    required String characterId,
    required String storylineId,
  }) async {
    final existing = await db.query(
      'rp_storylines',
      columns: const <String>['id'],
      where: 'character_id = ? AND id = ?',
      whereArgs: <Object?>[characterId, storylineId],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final countRows = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM rp_storylines "
      "WHERE character_id = ? AND status = 'active'",
      <Object?>[characterId],
    );
    final activeCount = countRows.single['count'] as int? ?? 0;
    if (activeCount >= 3) {
      throw StateError('A character can have at most three active storylines');
    }
    final now = DateTime.now().toIso8601String();
    await db.insert('rp_storylines', <String, Object?>{
      'character_id': characterId,
      'id': storylineId,
      'name': '',
      'status': 'active',
      'is_default': storylineId == 'main' ? 1 : 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  static Future<List<Map<String, Object?>>> getRpStorylines(
    String characterId, {
    bool includeArchived = false,
  }) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'rp_storylines',
      where: includeArchived
          ? 'character_id = ?'
          : "character_id = ? AND status = 'active'",
      whereArgs: <Object?>[characterId],
      orderBy: 'is_default DESC, updated_at DESC, created_at ASC',
    );
  }

  static Future<void> ensureDefaultRpStoryline(String characterId) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      await _ensureRpStoryline(
        txn,
        characterId: characterId,
        storylineId: 'main',
      );
    });
  }

  static Future<String> createRpStoryline({
    required String characterId,
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError('Storyline name is required');
    }
    final db = await DatabaseHelper.database;
    return db.transaction<String>((txn) async {
      final countRows = await txn.rawQuery(
        "SELECT COUNT(*) AS count FROM rp_storylines "
        "WHERE character_id = ? AND status = 'active'",
        <Object?>[characterId],
      );
      final activeCount = countRows.single['count'] as int? ?? 0;
      if (activeCount >= 3) {
        throw StateError(
          'A character can have at most three active storylines',
        );
      }
      final id = const Uuid().v4();
      final now = DateTime.now().toIso8601String();
      await txn.insert('rp_storylines', <String, Object?>{
        'character_id': characterId,
        'id': id,
        'name': normalizedName,
        'status': 'active',
        'is_default': activeCount == 0 ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      });
      return id;
    });
  }

  static Future<void> renameRpStoryline({
    required String characterId,
    required String storylineId,
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError('Storyline name is required');
    }
    final db = await DatabaseHelper.database;
    await db.update(
      'rp_storylines',
      <String, Object?>{
        'name': normalizedName,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'character_id = ? AND id = ?',
      whereArgs: <Object?>[characterId, storylineId],
    );
  }

  static Future<void> setRpStorylineArchived({
    required String characterId,
    required String storylineId,
    required bool archived,
  }) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        'rp_storylines',
        where: 'character_id = ? AND id = ?',
        whereArgs: <Object?>[characterId, storylineId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final currentlyArchived = rows.single['status'] == 'archived';
      if (currentlyArchived == archived) return;
      final countRows = await txn.rawQuery(
        "SELECT COUNT(*) AS count FROM rp_storylines "
        "WHERE character_id = ? AND status = 'active'",
        <Object?>[characterId],
      );
      final activeCount = countRows.single['count'] as int? ?? 0;
      if (archived && activeCount <= 1) {
        throw StateError('At least one RP storyline must remain active');
      }
      if (!archived && activeCount >= 3) {
        throw StateError(
          'A character can have at most three active storylines',
        );
      }
      final wasDefault = rows.single['is_default'] == 1;
      await txn.update(
        'rp_storylines',
        <String, Object?>{
          'status': archived ? 'archived' : 'active',
          'is_default': archived ? 0 : rows.single['is_default'],
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'character_id = ? AND id = ?',
        whereArgs: <Object?>[characterId, storylineId],
      );
      if (archived && wasDefault) {
        final replacement = await txn.query(
          'rp_storylines',
          columns: const <String>['id'],
          where: "character_id = ? AND status = 'active'",
          whereArgs: <Object?>[characterId],
          orderBy: 'updated_at DESC, created_at ASC',
          limit: 1,
        );
        if (replacement.isNotEmpty) {
          await txn.update(
            'rp_storylines',
            <String, Object?>{'is_default': 1},
            where: 'character_id = ? AND id = ?',
            whereArgs: <Object?>[characterId, replacement.single['id']],
          );
        }
      }
    });
  }

  static Future<void> setDefaultRpStoryline({
    required String characterId,
    required String storylineId,
  }) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      final target = await txn.query(
        'rp_storylines',
        columns: const <String>['id'],
        where: "character_id = ? AND id = ? AND status = 'active'",
        whereArgs: <Object?>[characterId, storylineId],
        limit: 1,
      );
      if (target.isEmpty) return;
      await txn.update(
        'rp_storylines',
        <String, Object?>{'is_default': 0},
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
      );
      await txn.update(
        'rp_storylines',
        <String, Object?>{
          'is_default': 1,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'character_id = ? AND id = ?',
        whereArgs: <Object?>[characterId, storylineId],
      );
    });
  }

  static Future<bool> hasConversationHistoryForCharacter({
    required String characterId,
    required ContextMode contextMode,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT 1
        FROM conversations c
        JOIN messages m ON m.conversation_id = c.id
        WHERE c.character_id = ? AND c.context_mode = ?
          AND trim(m.text) != ''
          AND (m.status IS NULL OR m.status = '')
        LIMIT 1
        ''',
      <Object?>[characterId, contextMode.storageValue],
    );
    return rows.isNotEmpty;
  }

  static Future<bool> rebindEmptyRpConversation({
    required String conversationId,
    required String characterId,
    required String storylineId,
    required String userPersonaId,
    required String userPersonaSnapshot,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final conversations = await txn.query(
        'conversations',
        columns: const <String>['id', 'character_id', 'context_mode'],
        where: 'id = ?',
        whereArgs: <Object?>[conversationId],
        limit: 1,
      );
      if (conversations.isEmpty) return false;
      final conversation = conversations.single;
      if (conversation['character_id'] != characterId ||
          conversation['context_mode'] != ContextMode.rp.storageValue) {
        return false;
      }
      final messageCount =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM messages WHERE conversation_id = ?',
              <Object?>[conversationId],
            ),
          ) ??
          0;
      if (messageCount > 0) return false;
      final storylines = await txn.query(
        'rp_storylines',
        columns: const <String>['id'],
        where: "character_id = ? AND id = ? AND status = 'active'",
        whereArgs: <Object?>[characterId, storylineId],
        limit: 1,
      );
      if (storylines.isEmpty) return false;

      final now = DateTime.now().toIso8601String();
      await txn.update(
        'rp_storylines',
        <String, Object?>{'is_default': 0},
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
      );
      await txn.update(
        'rp_storylines',
        <String, Object?>{'is_default': 1, 'updated_at': now},
        where: 'character_id = ? AND id = ?',
        whereArgs: <Object?>[characterId, storylineId],
      );
      final updated = await txn.update(
        'conversations',
        <String, Object?>{
          'continuity_id': storylineId,
          'user_persona_id': userPersonaId,
          'user_persona_snapshot': userPersonaSnapshot,
          'updated_at': now,
        },
        where: 'id = ? AND character_id = ? AND context_mode = ?',
        whereArgs: <Object?>[
          conversationId,
          characterId,
          ContextMode.rp.storageValue,
        ],
      );
      return updated == 1;
    });
  }

  static Future<void> updateConversation(String id, {String? title}) async {
    final db = await DatabaseHelper.database;
    final updates = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (title != null) updates['title'] = title;
    await db.update('conversations', updates, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateConversationCharacter(
    String conversationId,
    String characterId,
  ) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'conversations',
      {'character_id': characterId},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  static Future<void> toggleStarConversation(String id, bool starred) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'conversations',
      {'is_starred': starred ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Conversation>> getConversations({
    String? characterId,
  }) async {
    final db = await DatabaseHelper.database;
    final where = characterId != null ? 'character_id = ?' : null;
    final args = characterId != null ? [characterId] : null;
    final maps = await db.query(
      'conversations',
      where: where,
      whereArgs: args,
      orderBy: 'is_starred DESC, updated_at DESC',
    );
    return maps.map((m) => Conversation.fromMap(m)).toList();
  }

  static Future<List<Message>> getPreviousConversationTurns({
    required String currentConversationId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    int turnCount = 2,
  }) async {
    final db = await DatabaseHelper.database;
    final currentRows = await db.query(
      'conversations',
      columns: const <String>['created_at'],
      where: 'id = ?',
      whereArgs: <Object?>[currentConversationId],
      limit: 1,
    );
    if (currentRows.isEmpty || turnCount < 1) return const <Message>[];
    final createdAt = currentRows.first['created_at']?.toString() ?? '';
    final oldestCurrentMessage = await db.rawQuery(
      'SELECT MIN(created_at) AS first_at FROM messages '
      'WHERE conversation_id = ?',
      <Object?>[currentConversationId],
    );
    final firstAt = oldestCurrentMessage.first['first_at']?.toString() ?? '';
    // Branched windows already contain copied history dated before their own
    // creation. Adding another previous-window bridge would duplicate it.
    if (firstAt.isNotEmpty && firstAt.compareTo(createdAt) < 0) {
      return const <Message>[];
    }
    final windows = await db.rawQuery(
      '''
        SELECT c.id
        FROM conversations c
        WHERE c.id != ? AND c.character_id = ? AND c.context_mode = ?
          AND c.continuity_id = ? AND c.created_at < ?
          AND EXISTS (
            SELECT 1 FROM messages m
            WHERE m.conversation_id = c.id AND trim(m.text) != ''
          )
        ORDER BY c.created_at DESC
        LIMIT 8
        ''',
      <Object?>[
        currentConversationId,
        characterId,
        contextMode.storageValue,
        continuityId,
        createdAt,
      ],
    );
    for (final window in windows) {
      final id = window['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final rows = await db.query(
        'messages',
        where:
            "conversation_id = ? AND trim(text) != '' "
            "AND (status IS NULL OR status = '')",
        whereArgs: <Object?>[id],
        orderBy: 'created_at DESC, id DESC',
        limit: max(12, turnCount * 6),
      );
      final messages = rows
          .map(Message.fromMap)
          .toList(growable: false)
          .reversed
          .toList(growable: false);
      final bridge = _latestCompleteConversationTurns(messages, turnCount);
      if (bridge.isNotEmpty) return bridge;
    }
    return const <Message>[];
  }

  static List<Message> _latestCompleteConversationTurns(
    List<Message> messages,
    int turnCount,
  ) {
    if (turnCount < 1) return const <Message>[];
    final pairs = <List<Message>>[];
    Message? pendingUser;
    for (final message in messages) {
      if (message.isUser) {
        pendingUser = message;
      } else if (pendingUser != null) {
        pairs.add(<Message>[pendingUser, message]);
        pendingUser = null;
      }
    }
    if (pairs.isEmpty) return const <Message>[];
    return pairs
        .skip(max(0, pairs.length - turnCount))
        .expand((pair) => pair)
        .toList(growable: false);
  }

  static Future<List<RpChapterContinuationSource>>
  getRpChapterContinuationSources({
    required String currentConversationId,
    required String characterId,
    required String continuityId,
    ContextMode contextMode = ContextMode.rp,
    int limit = 20,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT c.*, MAX(m.created_at) AS last_message_at
        FROM conversations c
        JOIN messages m ON m.conversation_id = c.id
        WHERE c.id != ? AND c.character_id = ? AND c.context_mode = ?
          AND c.continuity_id = ? AND trim(m.text) != ''
          AND (m.status IS NULL OR m.status = '')
        GROUP BY c.id
        ORDER BY last_message_at DESC, c.updated_at DESC
        LIMIT ?
        ''',
      <Object?>[
        currentConversationId,
        characterId,
        contextMode.storageValue,
        continuityId,
        limit.clamp(1, 50),
      ],
    );
    final sources = <RpChapterContinuationSource>[];
    for (final row in rows) {
      final source = await _buildRpChapterContinuationSource(
        db,
        row,
        continuityId: continuityId,
        contextMode: contextMode,
      );
      if (source != null) sources.add(source);
    }
    return sources;
  }

  static Future<RpChapterContinuationSource?> getRpChapterContinuationSource({
    required String sourceConversationId,
    required String currentConversationId,
    required String characterId,
    required String continuityId,
    ContextMode contextMode = ContextMode.rp,
    int? throughMessageId,
    DateTime? summariesThrough,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT c.*, MAX(m.created_at) AS last_message_at
        FROM conversations c
        JOIN messages m ON m.conversation_id = c.id
        WHERE c.id = ? AND c.id != ? AND c.character_id = ?
          AND c.context_mode = ? AND c.continuity_id = ?
          AND trim(m.text) != '' AND (m.status IS NULL OR m.status = '')
        GROUP BY c.id
        LIMIT 1
        ''',
      <Object?>[
        sourceConversationId,
        currentConversationId,
        characterId,
        contextMode.storageValue,
        continuityId,
      ],
    );
    if (rows.isEmpty) return null;
    return _buildRpChapterContinuationSource(
      db,
      rows.first,
      continuityId: continuityId,
      contextMode: contextMode,
      throughMessageId: throughMessageId,
      summariesThrough: summariesThrough,
    );
  }

  static Future<Message?> getLatestRpChapterContinuationAction(
    String conversationId,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ? AND is_user = 1 AND text LIKE ?',
      whereArgs: <Object?>[
        conversationId,
        '${Message.rpChapterContinuationPrefix}%',
      ],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  static Future<RpChapterContinuationSource?> _buildRpChapterContinuationSource(
    Database db,
    Map<String, Object?> row, {
    required String continuityId,
    required ContextMode contextMode,
    int? throughMessageId,
    DateTime? summariesThrough,
  }) async {
    final conversation = Conversation.fromMap(row);
    final messageRows = await db.query(
      'messages',
      where:
          "conversation_id = ? AND trim(text) != '' "
          "AND (status IS NULL OR status = '') "
          'AND text NOT LIKE ? '
          '${throughMessageId == null ? '' : 'AND id <= ?'}',
      whereArgs: <Object?>[
        conversation.id,
        '${Message.rpChapterContinuationPrefix}%',
        ?throughMessageId,
      ],
      orderBy: 'created_at DESC, id DESC',
      // 多取一些再組成最後一個完整回合，避免末尾剛好是半個回合。
      limit: 12,
    );
    final messageCandidates = messageRows
        .map(Message.fromMap)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    final completeTurns = _latestCompleteConversationTurns(
      messageCandidates,
      1,
    );
    // 很短的新章可能尚未形成完整回合；仍允許續接唯一已有的內容。
    final messages = completeTurns.isNotEmpty
        ? completeTurns
        : messageCandidates
              .skip(max(0, messageCandidates.length - 2))
              .toList(growable: false);
    if (messages.isEmpty) return null;
    final effectiveThroughMessageId =
        throughMessageId ??
        messageCandidates.map((message) => message.id ?? 0).fold<int>(0, max);
    var summaryRows = await db.query(
      'context_summaries',
      columns: const <String>['content'],
      where:
          'source_conversation_id = ? AND context_mode = ? '
          "AND continuity_id = ? AND revision_status = 'valid' "
          '${effectiveThroughMessageId <= 0 ? '' : 'AND (source_message_end_id IS NULL OR source_message_end_id <= ?) '}'
          '${summariesThrough == null ? '' : 'AND created_at <= ?'}',
      whereArgs: <Object?>[
        conversation.id,
        contextMode.storageValue,
        continuityId,
        if (effectiveThroughMessageId > 0) effectiveThroughMessageId,
        if (summariesThrough != null) summariesThrough.toIso8601String(),
      ],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    if (summaryRows.isEmpty) {
      final lastMessageAt =
          DateTime.tryParse(row['last_message_at']?.toString() ?? '') ??
          conversation.updatedAt;
      summaryRows = await db.query(
        'context_summaries',
        columns: const <String>['content'],
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND revision_status = 'valid' AND created_at <= ?",
        whereArgs: <Object?>[
          conversation.characterId,
          contextMode.storageValue,
          continuityId,
          (summariesThrough ?? lastMessageAt).toIso8601String(),
        ],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
    }
    final summaries = summaryRows
        .map((item) => item['content']?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return RpChapterContinuationSource(
      conversation: conversation,
      lastMessageAt:
          DateTime.tryParse(row['last_message_at']?.toString() ?? '') ??
          conversation.updatedAt,
      messages: messages,
      summaries: summaries,
    );
  }

  static Future<List<Conversation>> searchConversations(
    String query, {
    String? characterId,
  }) async {
    final db = await DatabaseHelper.database;
    final pattern = DatabaseHelper._likeContains(query);
    String where = '''
        (
          conversations.title LIKE ? ESCAPE '\\'
          OR EXISTS (
            SELECT 1
            FROM messages
            WHERE messages.conversation_id = conversations.id
              AND messages.text LIKE ? ESCAPE '\\'
          )
        )
      ''';
    final args = <dynamic>[pattern, pattern];
    if (characterId != null) {
      where += ' AND conversations.character_id = ?';
      args.add(characterId);
    }
    final maps = await db.query(
      'conversations',
      where: where,
      whereArgs: args,
      orderBy: 'is_starred DESC, updated_at DESC',
    );
    return maps.map((m) => Conversation.fromMap(m)).toList();
  }

  static Future<Conversation?> getConversation(String id) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  static Future<String> ensureConversationWindowSummaryId(String id) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'conversations',
        columns: ['window_summary_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Conversation $id does not exist');
      }
      final existing = (rows.first['window_summary_id'] as String? ?? '')
          .trim();
      if (existing.isNotEmpty) return existing;

      final generated = await DatabaseHelper._generateWindowSummaryId(txn);
      await txn.update(
        'conversations',
        {'window_summary_id': generated},
        where: 'id = ?',
        whereArgs: [id],
      );
      return generated;
    });
  }

  static Future<String> rotateConversationWindowSummaryId(String id) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final generated = await DatabaseHelper._generateWindowSummaryId(txn);
      final changed = await txn.update(
        'conversations',
        {'window_summary_id': generated},
        where: 'id = ?',
        whereArgs: [id],
      );
      if (changed != 1) {
        throw StateError('Conversation $id does not exist');
      }
      return generated;
    });
  }

  static Future<String?> getConversationWindowSummaryId(String id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      columns: ['window_summary_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = (rows.first['window_summary_id'] as String? ?? '').trim();
    return value.isEmpty ? null : value;
  }

  static Future<int> getConversationSummaryCursor(String id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      columns: ['summary_cursor_message_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['summary_cursor_message_id'] as int?) ?? 0;
  }

  static Future<String?> getConversationPinnedSummary(String id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      columns: ['pinned_static_summary'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['pinned_static_summary'] as String?;
  }

  static Future<String> setConversationPinnedSummaryIfAbsent(
    String id,
    String text,
  ) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final changed = await txn.update(
        'conversations',
        {'pinned_static_summary': text},
        where: 'id = ? AND pinned_static_summary IS NULL',
        whereArgs: [id],
      );
      if (changed == 1) return text;

      final rows = await txn.query(
        'conversations',
        columns: ['pinned_static_summary'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Conversation $id does not exist');
      }
      return rows.first['pinned_static_summary'] as String? ?? text;
    });
  }

  static Future<String?> getConversationPinnedSelfNotes(String id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      columns: ['pinned_static_self_notes'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['pinned_static_self_notes'] as String?;
  }

  static Future<String> setConversationPinnedSelfNotesIfAbsent(
    String id,
    String text,
  ) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final changed = await txn.update(
        'conversations',
        {'pinned_static_self_notes': text},
        where: 'id = ? AND pinned_static_self_notes IS NULL',
        whereArgs: [id],
      );
      if (changed == 1) return text;
      final rows = await txn.query(
        'conversations',
        columns: ['pinned_static_self_notes'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Conversation $id does not exist');
      return rows.first['pinned_static_self_notes'] as String? ?? text;
    });
  }

  static Future<ConversationCoinSnapshot?> getConversationPinnedCoinSnapshot(
    String id,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      columns: <String>[
        'pinned_coin_snapshot_char',
        'pinned_coin_snapshot_user',
      ],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final characterCoins = rows.first['pinned_coin_snapshot_char'];
    final userCoins = rows.first['pinned_coin_snapshot_user'];
    if (characterCoins is! int || userCoins is! int) return null;
    return (characterCoins: characterCoins, userCoins: userCoins);
  }

  static Future<ConversationCoinSnapshot>
  setConversationPinnedCoinSnapshotIfAbsent(
    String id, {
    required int characterCoins,
    required int userCoins,
  }) async {
    if (characterCoins < 0 || userCoins < 0) {
      throw ArgumentError('Coin snapshots must be non-negative');
    }
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      await txn.update(
        'conversations',
        <String, Object?>{
          'pinned_coin_snapshot_char': characterCoins,
          'pinned_coin_snapshot_user': userCoins,
        },
        where:
            'id = ? AND (pinned_coin_snapshot_char IS NULL '
            'OR pinned_coin_snapshot_user IS NULL)',
        whereArgs: <Object?>[id],
      );
      final rows = await txn.query(
        'conversations',
        columns: <String>[
          'pinned_coin_snapshot_char',
          'pinned_coin_snapshot_user',
        ],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Conversation $id does not exist');
      final storedCharacter = rows.first['pinned_coin_snapshot_char'];
      final storedUser = rows.first['pinned_coin_snapshot_user'];
      if (storedCharacter is! int || storedUser is! int) {
        throw StateError('Conversation $id has an incomplete coin snapshot');
      }
      return (characterCoins: storedCharacter, userCoins: storedUser);
    });
  }

  static Future<void> deleteConversation(String id) async {
    final db = await DatabaseHelper.database;
    final filesToDelete = await db.transaction<Set<String>>((txn) async {
      final voices = await txn.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'source_conversation_id = ?',
        whereArgs: [id],
      );
      final images = await txn.query(
        'messages',
        columns: ['image_path', 'image_paths_json'],
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      final files = <String>{
        ...voices.map((row) => row['file_path']).whereType<String>(),
        ...images.expand(DatabaseHelper._imagePathsFromRow),
        ...await ReplyVariants._archivedMedia(txn, id),
      };
      await txn.delete(
        'saved_voices',
        where: 'source_conversation_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'saved_messages',
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      // 記憶刻意不刪：記憶的設計就是要活得比對話久。
      // Deleted source dialogue cannot be replayed. Keep the invalidated
      // summary audit row, but do not leave a repair job that blocks future
      // summaries of the same character/storyline forever.
      await txn.update(
        'context_summary_repairs',
        <String, Object?>{
          'status': 'completed',
          'last_error': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'source_conversation_id = ? AND status != ?',
        whereArgs: <Object?>[id, 'completed'],
      );
      await txn.delete(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
      await txn.delete(
        'message_revisions',
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'pending_memory_actions',
        where:
            "source_conversation_id = ? AND status IN ('pending','snoozed','failed','stale')",
        whereArgs: [id],
      );
      return files;
    });
    await AppFileSafety.deleteOwnedFiles(filesToDelete);
  }
}
