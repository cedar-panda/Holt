part of 'database.dart';

class _SavedMessageStore {
  static Future<int> saveMessage({
    required String messageId,
    required String content,
    String characterId = 'default',
    String? conversationId,
  }) async {
    try {
      final db = await DatabaseHelper.database;
      final inserted = await db.insert('saved_messages', {
        'message_id': messageId,
        'content': content,
        'character_id': characterId,
        'conversation_id': conversationId,
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (inserted > 0) return inserted;
      final existing = await db.query(
        'saved_messages',
        columns: ['id'],
        where: 'message_id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      return existing.isEmpty ? -1 : existing.first['id'] as int;
    } catch (e) {
      // 嘗試建表後重試
      try {
        final db = await DatabaseHelper.database;
        await DatabaseHelper._createSavedMessagesTable(db);
        await DatabaseHelper._createSavedMessageUniqueIndex(db);
        final inserted = await db.insert('saved_messages', {
          'message_id': messageId,
          'content': content,
          'character_id': characterId,
          'conversation_id': conversationId,
          'created_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (inserted > 0) return inserted;
        final existing = await db.query(
          'saved_messages',
          columns: ['id'],
          where: 'message_id = ?',
          whereArgs: [messageId],
          limit: 1,
        );
        return existing.isEmpty ? -1 : existing.first['id'] as int;
      } catch (_) {
        return -1;
      }
    }
  }

  static Future<void> unsaveMessage(String messageId) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'saved_messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  static Future<bool> isMessageSaved(String messageId) async {
    try {
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'saved_messages',
        where: 'message_id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getSavedMessages({
    String characterId = 'default',
    int limit = 50,
  }) async {
    final db = await DatabaseHelper.database;
    return await db.query(
      'saved_messages',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  static Future<List<Map<String, dynamic>>> searchSavedMessages(
    String query, {
    String characterId = 'default',
  }) async {
    final db = await DatabaseHelper.database;
    return await db.query(
      'saved_messages',
      where:
          "character_id = ? AND "
          "(content LIKE ? ESCAPE '\\' OR created_at LIKE ? ESCAPE '\\')",
      whereArgs: [
        characterId,
        DatabaseHelper._likeContains(query),
        DatabaseHelper._likeContains(query),
      ],
      orderBy: 'created_at DESC',
    );
  }

  static Future<void> deleteSavedMessage(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete('saved_messages', where: 'id = ?', whereArgs: [id]);
  }
}
