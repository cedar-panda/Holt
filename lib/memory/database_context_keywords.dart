part of 'database.dart';

class _ContextKeywordStore {
  static Future<int> insertContextKeywords({
    required String characterId,
    required String keywords,
    required int tokenCount,
    int? sourceSummaryId,
    String sourceSummaryContent = '',
    String sourceWindowId = '',
    String sourceConversationId = '',
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    return await db.insert('context_keywords', {
      'character_id': characterId,
      'source_window_id': sourceWindowId,
      'source_conversation_id': sourceConversationId,
      'context_mode': contextMode.storageValue,
      'continuity_id': continuityId,
      'keywords': keywords,
      'token_count': tokenCount,
      'source_summary_id': sourceSummaryId,
      'source_summary_content': sourceSummaryContent,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getContextKeywords(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    // One-time/idempotent self-heal for databases whose older RP labels were
    // evicted by the former 1800-token cap. Keep it out of repeated UI reads
    // and the per-message recall path after this scope has been healed once.
    if (contextMode == ContextMode.rp &&
        DatabaseHelper._recallIndexHealedScopes.add(
          '$characterId|$continuityId',
        )) {
      await _ContextSummaryStore.restoreArchivedSummaryKeywords(
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
    }
    final db = await DatabaseHelper.database;
    return await db.query(
      'context_keywords',
      where: 'character_id = ? AND context_mode = ? AND continuity_id = ?',
      whereArgs: [characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC',
    );
  }

  static Future<int> getContextKeywordTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_keywords '
      'WHERE character_id = ? AND context_mode = ? AND continuity_id = ?',
      [characterId, contextMode.storageValue, continuityId],
    );
    return r.first['total'] as int;
  }

  static Future<void> updateContextKeywordBlock({
    required int id,
    required String keywords,
    required int tokenCount,
    required String sourceSummaryContent,
  }) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'context_keywords',
      {
        'keywords': keywords,
        'token_count': tokenCount,
        'source_summary_content': sourceSummaryContent,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteOldestContextKeyword(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final oldest = await db.query(
      'context_keywords',
      where: 'character_id = ? AND context_mode = ? AND continuity_id = ?',
      whereArgs: [characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (oldest.isNotEmpty) {
      await db.delete(
        'context_keywords',
        where: 'id = ?',
        whereArgs: [oldest.first['id']],
      );
    }
  }

  static Future<void> clearContextData(String characterId) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'context_summaries',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'context_keywords',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_story_relationship_events',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_story_relationships',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_story_states',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_worldbook_review_items',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_worldbook_sync_state',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_worldbook_entries',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_story_entity_aliases',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'rp_story_characters',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
  }
}
