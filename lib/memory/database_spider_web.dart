part of 'database.dart';

class _SpiderWebStore {
  static Future<List<Map<String, dynamic>>> getSpiderWebLinks(
    String characterId, {
    bool includeRejected = false,
  }) async {
    final db = await DatabaseHelper.database;
    return db.rawQuery(
      '''
        SELECT link.*
        FROM spider_web_links AS link
        INNER JOIN memories AS first_memory
          ON first_memory.id = link.memory_id_1
         AND first_memory.character_id = link.character_id
         AND first_memory.status = 'active'
        INNER JOIN memories AS second_memory
          ON second_memory.id = link.memory_id_2
         AND second_memory.character_id = link.character_id
         AND second_memory.status = 'active'
        WHERE link.character_id = ?
          ${includeRejected ? '' : "AND link.status != 'rejected'"}
        ORDER BY link.status ASC, link.strength DESC, link.id ASC
        ''',
      [characterId],
    );
  }

  static Future<bool> insertSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) async {
    return (await upsertSpiderWebRelationDetailed(
          characterId,
          firstMemoryId,
          secondMemoryId,
          relationType: 'related',
          strength: 1,
          status: 'confirmed',
          source: 'model',
          reason: '',
        )) ==
        SpiderWebRelationWriteResult.inserted;
  }

  static Future<bool> upsertSpiderWebRelation(
    String characterId,
    int firstMemoryId,
    int secondMemoryId, {
    required String relationType,
    required double strength,
    required String status,
    required String source,
    required String reason,
  }) async => switch (await upsertSpiderWebRelationDetailed(
    characterId,
    firstMemoryId,
    secondMemoryId,
    relationType: relationType,
    strength: strength,
    status: status,
    source: source,
    reason: reason,
  )) {
    SpiderWebRelationWriteResult.inserted ||
    SpiderWebRelationWriteResult.updated => true,
    _ => false,
  };

  static Future<SpiderWebRelationWriteResult> upsertSpiderWebRelationDetailed(
    String characterId,
    int firstMemoryId,
    int secondMemoryId, {
    required String relationType,
    required double strength,
    required String status,
    required String source,
    required String reason,
  }) async {
    if (firstMemoryId == secondMemoryId) {
      return SpiderWebRelationWriteResult.invalid;
    }
    final db = await DatabaseHelper.database;
    final first = min(firstMemoryId, secondMemoryId);
    final second = max(firstMemoryId, secondMemoryId);
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
    final safeStatus =
        const {'suggested', 'confirmed', 'rejected'}.contains(status)
        ? status
        : 'suggested';
    final safeSource =
        const {
          'legacy',
          'model',
          'local_scan',
          'user',
          'user_curation',
          'vector',
          'merge_remap',
        }.contains(source)
        ? source
        : 'local_scan';
    final safeStrength = strength.clamp(0.0, 1.0);
    final now = DateTime.now().toIso8601String();
    return db.transaction((txn) async {
      final valid = await txn.query(
        'memories',
        columns: ['id'],
        where: 'id IN (?, ?) AND character_id = ? AND status = ?',
        whereArgs: [first, second, characterId, 'active'],
      );
      if (valid.length != 2) {
        return SpiderWebRelationWriteResult.invalid;
      }
      final existing = await txn.query(
        'spider_web_links',
        where:
            'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ? '
            'AND relation_type = ?',
        whereArgs: [characterId, first, second, safeType],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final current = existing.first;
        final currentStatus = current['status']?.toString() ?? 'confirmed';
        final currentStrength = (current['strength'] as num?)?.toDouble() ?? 1;
        final currentReason = current['reason']?.toString() ?? '';
        final currentSource = current['source']?.toString() ?? 'legacy';
        final unchanged =
            currentStatus == safeStatus &&
            currentStrength == safeStrength &&
            currentReason == reason.trim() &&
            currentSource == safeSource;
        if (unchanged) return SpiderWebRelationWriteResult.unchanged;

        final userAuthority =
            safeSource == 'user' ||
            safeSource == 'user_curation' ||
            safeSource == 'merge_remap';
        if (currentStatus == 'rejected' &&
            safeStatus != 'rejected' &&
            safeSource != 'user') {
          return SpiderWebRelationWriteResult.protected;
        }
        if (safeStatus == 'suggested' &&
            (currentStatus == 'confirmed' || currentStatus == 'rejected')) {
          return SpiderWebRelationWriteResult.protected;
        }
        if ((currentStatus == 'confirmed' || currentStatus == 'rejected') &&
            !userAuthority) {
          return SpiderWebRelationWriteResult.protected;
        }
        final changed = await txn.update(
          'spider_web_links',
          <String, Object?>{
            'relation_type': safeType,
            'strength': safeStrength,
            'status': safeStatus,
            'source': safeSource,
            'reason': reason.trim(),
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [current['id']],
        );
        return changed == 1
            ? SpiderWebRelationWriteResult.updated
            : SpiderWebRelationWriteResult.invalid;
      }
      final inserted = await txn.insert('spider_web_links', <String, Object?>{
        'character_id': characterId,
        'memory_id_1': first,
        'memory_id_2': second,
        'created_at': now,
        'relation_type': safeType,
        'strength': safeStrength,
        'status': safeStatus,
        'source': safeSource,
        'reason': reason.trim(),
        'updated_at': now,
      });
      return inserted > 0
          ? SpiderWebRelationWriteResult.inserted
          : SpiderWebRelationWriteResult.invalid;
    });
  }

  static Future<bool> resolveSpiderWebRelation(
    String characterId,
    int relationId, {
    required bool confirmed,
  }) async {
    final db = await DatabaseHelper.database;
    final changed = await db.update(
      'spider_web_links',
      <String, Object?>{
        'status': confirmed ? 'confirmed' : 'rejected',
        'source': 'user',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND character_id = ?',
      whereArgs: [relationId, characterId],
    );
    return changed == 1;
  }

  static Future<bool> deleteSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) async {
    if (firstMemoryId == secondMemoryId) return false;
    final db = await DatabaseHelper.database;
    final first = min(firstMemoryId, secondMemoryId);
    final second = max(firstMemoryId, secondMemoryId);
    final changed = await db.update(
      'spider_web_links',
      <String, Object?>{
        'status': 'rejected',
        'source': 'user',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
      whereArgs: [characterId, first, second],
    );
    return changed == 1;
  }
}
