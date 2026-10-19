part of 'database.dart';

class _CharacterStore {
  static Future<void> insertCharacter(Map<String, dynamic> char) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'characters',
      char,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> updateCharacter(
    String id,
    Map<String, dynamic> updates,
  ) async {
    final db = await DatabaseHelper.database;
    final safeUpdates = sanitizeCharacterUpdates(updates);
    await db.update(
      'characters',
      safeUpdates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateCharacterWhisper(
    String id, {
    String? userText,
    String? modelText,
    String? source,
    bool? modelOverrideEnabled,
  }) async {
    final updates = <String, Object?>{};
    if (userText != null) updates['whisper_user_text'] = userText;
    if (modelText != null) updates['whisper_model_text'] = modelText;
    if (source != null) updates['whisper_source'] = source;
    if (modelOverrideEnabled != null) {
      updates['whisper_model_override'] = modelOverrideEnabled ? 1 : 0;
    }
    if (updates.isEmpty) return;
    final db = await DatabaseHelper.database;
    await db.update('characters', updates, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateCharacterSignature(
    String id,
    String signature,
  ) async {
    final db = await DatabaseHelper.database;
    final bounded = signature
        .trim()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(4)
        .join('\n');
    await db.update(
      'characters',
      {'signature': String.fromCharCodes(bounded.runes.take(64))},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Map<String, dynamic> sanitizeCharacterUpdates(
    Map<String, dynamic> updates, {
    String? updatedAt,
  }) {
    final safeUpdates = Map<String, dynamic>.from(updates)
      ..remove('id')
      ..remove('created_at');
    safeUpdates['updated_at'] = updatedAt ?? DateTime.now().toIso8601String();
    return safeUpdates;
  }

  static Future<List<Map<String, dynamic>>> getCharacters() async {
    final db = await DatabaseHelper.database;
    return await db.query('characters', orderBy: 'updated_at DESC');
  }

  static Future<Map<String, dynamic>?> getCharacter(String id) async {
    final db = await DatabaseHelper.database;
    final maps = await db.query(
      'characters',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : maps.first;
  }

  static Future<void> deleteCharacter(String id) async {
    final db = await DatabaseHelper.database;
    final filesToDelete = await db.transaction<Set<String>>((txn) async {
      final files = <String>{};
      final convs = await txn.query(
        'conversations',
        columns: ['id'],
        where: 'character_id = ?',
        whereArgs: [id],
      );
      final convIds = convs.map((c) => c['id'] as String).toList();

      for (final cid in convIds) {
        final voices = await txn.query(
          'saved_voices',
          columns: ['file_path'],
          where: 'source_conversation_id = ?',
          whereArgs: [cid],
        );
        files.addAll(voices.map((row) => row['file_path']).whereType<String>());
        final images = await txn.query(
          'messages',
          columns: ['image_path', 'image_paths_json'],
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        files.addAll(images.expand(DatabaseHelper._imagePathsFromRow));
        files.addAll(await ReplyVariants._archivedMedia(txn, cid));
      }
      final voices = await txn.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'character_id = ?',
        whereArgs: [id],
      );
      files.addAll(voices.map((row) => row['file_path']).whereType<String>());
      final stickers = await txn.query(
        'stickers',
        columns: ['file_path'],
        where: 'character_id = ?',
        whereArgs: [id],
      );
      files.addAll(stickers.map((row) => row['file_path']).whereType<String>());

      final batch = txn.batch();
      for (final cid in convIds) {
        batch.delete(
          'saved_voices',
          where: 'source_conversation_id = ?',
          whereArgs: [cid],
        );
        batch.delete(
          'character_signatures',
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        batch.delete(
          'saved_messages',
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        batch.delete(
          'message_revisions',
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        batch.delete(
          'messages',
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        batch.delete('conversations', where: 'id = ?', whereArgs: [cid]);
      }
      batch.delete('stickers', where: 'character_id = ?', whereArgs: [id]);
      batch.delete('saved_voices', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'saved_messages',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.rawDelete(
        'DELETE FROM spider_web_links '
        'WHERE character_id = ? '
        'OR memory_id_1 IN '
        '(SELECT id FROM memories WHERE character_id = ?) '
        'OR memory_id_2 IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, id, id],
      );
      batch.rawDelete(
        'DELETE FROM emotion_points '
        'WHERE character_id = ? '
        // RP 故事線的情緒範圍存成「角色id#rp:故事線」（見 EmotionCoordinates.rpScopeMark），一併刪除。
        'OR character_id LIKE ? '
        'OR memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, '$id#rp:%', id],
      );
      batch.rawDelete(
        'DELETE FROM grudge_seals '
        'WHERE character_id = ? '
        // RP 故事線的情緒範圍存成「角色id#rp:故事線」（見 EmotionCoordinates.rpScopeMark），一併刪除。
        'OR character_id LIKE ? '
        'OR memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, '$id#rp:%', id],
      );
      batch.rawDelete(
        'DELETE FROM character_timeline '
        'WHERE character_id = ? '
        'OR source_memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, id],
      );
      batch.delete(
        'rp_character_timeline',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_relationship_events',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_relationships',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_projection_revisions',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_states',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_worldbook_review_items',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_worldbook_sync_state',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_worldbook_entries',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_entity_aliases',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'rp_story_characters',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete('archive', where: 'character_id = ?', whereArgs: [id]);
      batch.delete('backpack_items', where: 'owner_id = ?', whereArgs: [id]);
      batch.delete('sticky_notes', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'character_diaries',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete('usage_logs', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'web_search_usage_logs',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'pending_memory_actions',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'memory_rejection_tombstones',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete('rp_storylines', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'character_persona_bindings',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete('memories', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'context_summaries',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'context_summary_repairs',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'context_keywords',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      batch.delete('characters', where: 'id = ?', whereArgs: [id]);
      await batch.commit(noResult: true);
      return files;
    });
    await AppFileSafety.deleteOwnedFiles(filesToDelete);
  }
}
