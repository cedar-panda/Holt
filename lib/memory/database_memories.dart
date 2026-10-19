part of 'database.dart';

class _MemoryStore {
  static Future<int> insertMemory(Memory mem) async {
    final db = await DatabaseHelper.database;
    return await db.insert('memories', mem.toMap());
  }

  static Future<void> insertMemories(List<Memory> memories) async {
    final db = await DatabaseHelper.database;
    final batch = db.batch();
    for (final mem in memories) {
      batch.insert('memories', mem.toMap());
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Memory>> getActiveMemories(
    String mode, {
    String characterId = 'default',
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'memories',
      where:
          'mode = ? AND status = ? AND character_id = ? '
          'AND context_mode = ? AND continuity_id = ?',
      whereArgs: [
        mode,
        'active',
        characterId,
        contextMode.storageValue,
        continuityId,
      ],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  static Future<List<Memory>> getAllActiveMemories({
    String characterId = 'default',
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final where = contextMode == null
        ? 'status = ? AND character_id = ?'
        : 'status = ? AND character_id = ? AND context_mode = ? '
              'AND continuity_id = ?';
    final args = contextMode == null
        ? <Object?>['active', characterId]
        : <Object?>[
            'active',
            characterId,
            contextMode.storageValue,
            continuityId,
          ];
    final maps = await db.query(
      'memories',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return maps.map(Memory.fromMap).toList();
  }

  static Future<List<Memory>> getPermanentMemories(
    String mode, {
    String characterId = 'default',
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'memories',
      where:
          'mode = ? AND is_permanent = 1 AND status = ? AND character_id = ? '
          'AND context_mode = ? AND continuity_id = ?',
      whereArgs: [
        mode,
        'active',
        characterId,
        contextMode.storageValue,
        continuityId,
      ],
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  static Future<List<Memory>> searchMemories(
    String mode,
    String keyword, {
    String characterId = 'default',
    int limit = 10,
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'memories',
      where:
          "mode = ? AND status = ? AND character_id = ? "
          "AND content LIKE ? ESCAPE '\\'",
      whereArgs: [
        mode,
        'active',
        characterId,
        DatabaseHelper._likeContains(keyword),
      ],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  static Future<List<Memory>> searchMemoriesForCharacter(
    String keyword, {
    String characterId = 'default',
    int? limit = 10,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return const [];
    final db = await DatabaseHelper.database;
    final pattern = DatabaseHelper._likeContains(normalized);
    final scopeClause = contextMode == null
        ? ''
        : ' AND context_mode = ? AND continuity_id = ?';
    final maps = await db.query(
      'memories',
      where:
          "status = ? AND character_id = ? AND "
          "(content LIKE ? ESCAPE '\\' OR triggers LIKE ? ESCAPE '\\' "
          "OR category LIKE ? ESCAPE '\\')$scopeClause",
      whereArgs: [
        'active',
        characterId,
        pattern,
        pattern,
        pattern,
        if (contextMode != null) contextMode.storageValue,
        if (contextMode != null) continuityId,
      ],
      orderBy: 'mention_count DESC, updated_at DESC',
      limit: limit?.clamp(1, 500),
    );
    return maps.map(Memory.fromMap).toList();
  }

  static Future<List<Memory>> getLowConfidenceForReview({
    String characterId = 'default',
    int minCount = 3,
  }) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'memories',
      where:
          'confidence = ? AND status = ? AND character_id = ? AND review_count >= ?',
      whereArgs: ['low', 'active', characterId, minCount],
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  static Future<void> incrementMention(int memoryId) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate(
      'UPDATE memories SET mention_count = mention_count + 1 WHERE id = ?',
      [memoryId],
    );
  }

  static Future<void> incrementReviewCount(int memoryId) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate(
      'UPDATE memories SET review_count = review_count + 1 WHERE id = ?',
      [memoryId],
    );
  }

  static Future<bool> archiveMemory(
    int memoryId,
    String reason, {
    required String characterId,
  }) async {
    final db = await DatabaseHelper.database;
    final requestedCharacter = characterId.trim().isEmpty
        ? 'default'
        : characterId.trim();
    return db.transaction(
      (txn) => _archiveMemoryInTransaction(
        txn,
        memoryId,
        reason,
        requestedCharacter,
      ),
    );
  }

  static Future<int> archiveMemories(
    Iterable<int> memoryIds,
    String reason, {
    required String characterId,
  }) async {
    final ids = memoryIds.where((id) => id > 0).toSet().toList()..sort();
    if (ids.isEmpty) return 0;
    final db = await DatabaseHelper.database;
    final requestedCharacter = characterId.trim().isEmpty
        ? 'default'
        : characterId.trim();
    return db.transaction((txn) async {
      var archived = 0;
      for (final id in ids) {
        if (await _archiveMemoryInTransaction(
          txn,
          id,
          reason,
          requestedCharacter,
        )) {
          archived++;
        }
      }
      return archived;
    });
  }

  static Future<bool> _archiveMemoryInTransaction(
    Transaction txn,
    int memoryId,
    String reason,
    String requestedCharacter,
  ) async {
    final maps = await txn.query(
      'memories',
      where: 'id = ? AND character_id = ? AND status = ?',
      whereArgs: [memoryId, requestedCharacter, 'active'],
      limit: 1,
    );
    if (maps.isEmpty) return false;

    final mem = maps.first;
    final actualCharacter = (mem['character_id'] as String? ?? 'default')
        .trim();
    final scopedCharacter = actualCharacter.isEmpty
        ? 'default'
        : actualCharacter;
    final values = <String, Object?>{
      'character_id': scopedCharacter,
      'original_id': memoryId,
      'original_table': 'memories',
      'content_snapshot': jsonEncode(Map<String, dynamic>.from(mem)),
      'archived_at': DateTime.now().toIso8601String(),
      'reason': reason,
    };

    final existing = await txn.query(
      'archive',
      columns: ['id'],
      where: 'original_table = ? AND original_id = ?',
      whereArgs: ['memories', memoryId],
      limit: 1,
    );
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
      {'status': 'deleted'},
      where: 'id = ? AND character_id = ? AND status = ?',
      whereArgs: [memoryId, scopedCharacter, 'active'],
    );
    return changed == 1;
  }

  static Future<void> promoteMemory(int memoryId) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'memories',
      {'confidence': 'medium', 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [memoryId],
    );
  }

  static Future<int> getMemoryCount(
    String mode, {
    String characterId = 'default',
  }) async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM memories WHERE mode = ? AND status = ? AND character_id = ?',
      [mode, 'active', characterId],
    );
    return result.first['count'] as int;
  }

  static Future<List<Map<String, dynamic>>> getArchivedMemories({
    required String characterId,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'archive',
      where: 'character_id = ? AND original_table = ?',
      whereArgs: [characterId, 'memories'],
      orderBy: 'archived_at DESC, id DESC',
    );
    if (contextMode == null) return rows;
    return rows
        .where((row) {
          try {
            final snapshot = jsonDecode(
              row['content_snapshot']?.toString() ?? '',
            );
            if (snapshot is! Map) return false;
            return ContextMode.fromStorage(snapshot['context_mode']) ==
                    contextMode &&
                (snapshot['continuity_id']?.toString() ?? 'main') ==
                    continuityId;
          } catch (_) {
            return false;
          }
        })
        .toList(growable: false);
  }

  static Future<int> getArchivedCount({
    required String characterId,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    if (contextMode != null) {
      return (await getArchivedMemories(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      )).length;
    }
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM archive '
      'WHERE character_id = ? AND original_table = ?',
      [characterId, 'memories'],
    );
    return result.first['count'] as int;
  }

  static Future<bool> deleteArchivedMemory(
    int archiveId, {
    required String characterId,
  }) {
    return permanentlyDelete(archiveId, characterId: characterId);
  }

  static Future<void> clearAllArchived({required String characterId}) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'archive',
        columns: ['original_id', 'original_table'],
        where: 'character_id = ?',
        whereArgs: [characterId],
      );
      for (final row in rows) {
        if (row['original_table'] == 'memories') {
          await _hardDeleteMemoryInTransaction(
            txn,
            row['original_id'] as int,
            characterId,
          );
        }
      }
      await txn.delete(
        'archive',
        where: 'character_id = ?',
        whereArgs: [characterId],
      );
    });
  }

  static Future<bool> deleteMemory(
    int memoryId, {
    bool archive = true,
    required String characterId,
  }) async {
    final db = await DatabaseHelper.database;
    if (archive) {
      return archiveMemory(memoryId, '用戶手動刪除', characterId: characterId);
    }

    return db.transaction((txn) async {
      final rows = await txn.query(
        'memories',
        columns: ['character_id'],
        where: 'id = ? AND character_id = ?',
        whereArgs: [memoryId, characterId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final actualCharacter =
          (rows.first['character_id'] as String? ?? 'default').trim();
      await _hardDeleteMemoryInTransaction(
        txn,
        memoryId,
        actualCharacter.isEmpty ? 'default' : actualCharacter,
      );
      return true;
    });
  }

  static Future<bool> restoreFromArchive(
    int archiveId, {
    required String characterId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction(
      (txn) => _restoreFromArchiveInTransaction(txn, archiveId, characterId),
    );
  }

  static Future<int> restoreFromArchives(
    Iterable<int> archiveIds, {
    required String characterId,
  }) async {
    final ids = archiveIds.where((id) => id > 0).toSet().toList()..sort();
    if (ids.isEmpty) return 0;
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      var restored = 0;
      for (final archiveId in ids) {
        final success = await _restoreFromArchiveInTransaction(
          txn,
          archiveId,
          characterId,
        );
        if (!success) throw StateError('archive entry changed during restore');
        restored++;
      }
      return restored;
    });
  }

  static Future<bool> _restoreFromArchiveInTransaction(
    Transaction txn,
    int archiveId,
    String characterId,
  ) async {
    final archiveRows = await txn.query(
      'archive',
      where: 'id = ? AND character_id = ? AND original_table = ?',
      whereArgs: [archiveId, characterId, 'memories'],
      limit: 1,
    );
    if (archiveRows.isEmpty) return false;
    final archive = archiveRows.first;
    final originalId = archive['original_id'] as int;

    final existing = await txn.query(
      'memories',
      where: 'id = ?',
      whereArgs: [originalId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      if (existing.first['character_id'] != characterId) return false;
      final now = DateTime.now().toIso8601String();
      final changed = await txn.update(
        'memories',
        {
          'status': 'active',
          'mention_count': 0,
          'clarity': 1.0,
          'last_accessed': now,
          'updated_at': now,
        },
        where: 'id = ? AND character_id = ?',
        whereArgs: [originalId, characterId],
      );
      if (changed != 1) return false;
    } else {
      Map<String, dynamic> snapshot;
      try {
        final decoded = jsonDecode(archive['content_snapshot'] as String);
        if (decoded is! Map) return false;
        snapshot = Map<String, dynamic>.from(decoded);
      } on FormatException {
        return false;
      } on TypeError {
        return false;
      }
      // Preserve the original id so any surviving emotion/timeline/spider
      // references remain attached to the restored memory.
      snapshot['id'] = originalId;
      snapshot['character_id'] = characterId;
      snapshot['status'] = 'active';
      snapshot['mention_count'] = 0;
      snapshot['clarity'] = 1.0;
      snapshot['last_accessed'] = DateTime.now().toIso8601String();
      snapshot['updated_at'] = snapshot['last_accessed'];
      await txn.insert('memories', snapshot);
    }

    await txn.delete(
      'archive',
      where: 'id = ? AND character_id = ?',
      whereArgs: [archiveId, characterId],
    );
    return true;
  }

  static Future<int> permanentlyDeleteArchives(
    Iterable<int> archiveIds, {
    required String characterId,
  }) async {
    final ids = archiveIds.where((id) => id > 0).toSet().toList()..sort();
    if (ids.isEmpty) return 0;
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      var deleted = 0;
      for (final archiveId in ids) {
        final archiveRows = await txn.query(
          'archive',
          columns: ['original_id', 'original_table'],
          where: 'id = ? AND character_id = ?',
          whereArgs: [archiveId, characterId],
          limit: 1,
        );
        if (archiveRows.isEmpty) {
          throw StateError('archive entry changed during delete');
        }
        final archive = archiveRows.first;
        if (archive['original_table'] == 'memories') {
          await _hardDeleteMemoryInTransaction(
            txn,
            archive['original_id'] as int,
            characterId,
          );
        }
        await txn.delete(
          'archive',
          where: 'id = ? AND character_id = ?',
          whereArgs: [archiveId, characterId],
        );
        deleted++;
      }
      return deleted;
    });
  }

  static Future<bool> permanentlyDelete(
    int archiveId, {
    required String characterId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final archiveRows = await txn.query(
        'archive',
        columns: ['original_id', 'original_table'],
        where: 'id = ? AND character_id = ?',
        whereArgs: [archiveId, characterId],
        limit: 1,
      );
      if (archiveRows.isEmpty) return false;
      final archive = archiveRows.first;
      if (archive['original_table'] == 'memories') {
        await _hardDeleteMemoryInTransaction(
          txn,
          archive['original_id'] as int,
          characterId,
        );
      }
      await txn.delete(
        'archive',
        where: 'id = ? AND character_id = ?',
        whereArgs: [archiveId, characterId],
      );
      return true;
    });
  }

  static Future<void> _hardDeleteMemoryInTransaction(
    Transaction txn,
    int memoryId,
    String characterId,
  ) async {
    await txn.delete(
      'spider_web_links',
      where: 'character_id = ? AND (memory_id_1 = ? OR memory_id_2 = ?)',
      whereArgs: [characterId, memoryId, memoryId],
    );
    await txn.delete(
      'emotion_points',
      // memory id 全域唯一；不能再限角色 id，否則會漏掉 RP 範圍的情緒點。
      where: 'memory_id = ?',
      whereArgs: [memoryId],
    );
    await txn.delete(
      'grudge_seals',
      // memory id 全域唯一；不能再限角色 id，否則會漏掉 RP 範圍的情緒點。
      where: 'memory_id = ?',
      whereArgs: [memoryId],
    );
    await txn.delete(
      'character_timeline',
      where: 'character_id = ? AND source_memory_id = ?',
      whereArgs: [characterId, memoryId],
    );
    await txn.delete(
      'memories',
      where: 'id = ? AND character_id = ?',
      whereArgs: [memoryId, characterId],
    );
    await txn.delete(
      'archive',
      where: 'character_id = ? AND original_table = ? AND original_id = ?',
      whereArgs: [characterId, 'memories', memoryId],
    );
  }
}
