part of 'database.dart';

class _VoiceStore {
  static Future<int> saveVoice({
    required String filePath,
    required String name,
    String? messageId,
    String? sourceConversationId,
    String? sourceConversationTitle,
    String characterId = 'default',
    int durationMs = 0,
    int fileSize = 0,
  }) async {
    final db = await DatabaseHelper.database;
    return await db.insert('saved_voices', {
      'file_path': filePath,
      'name': name,
      'message_id': messageId,
      'source_conversation_id': sourceConversationId,
      'source_conversation_title': sourceConversationTitle,
      'character_id': characterId,
      'duration_ms': durationMs,
      'file_size': fileSize,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<String?> getVoicePathByMessageId(String messageId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'saved_voices',
      columns: ['file_path'],
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String;
    // 確認文件存在
    if (await File(path).exists()) return path;
    // 文件已被清理，移除過期記錄
    await db.delete(
      'saved_voices',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return null;
  }

  static Future<List<Map<String, dynamic>>> getSavedVoices({
    String? characterId,
  }) async {
    final db = await DatabaseHelper.database;
    final where = characterId != null ? 'character_id = ?' : null;
    final args = characterId != null ? [characterId] : null;
    return await db.query(
      'saved_voices',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
  }

  static Future<void> updateVoiceName(int id, String newName) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'saved_voices',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteVoice(int id) async {
    final db = await DatabaseHelper.database;
    final path = await db.transaction<String?>((txn) async {
      final rows = await txn.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      await txn.delete('saved_voices', where: 'id = ?', whereArgs: [id]);
      return rows.isEmpty ? null : rows.first['file_path'] as String?;
    });
    await AppFileSafety.deleteOwnedFiles([path]);
  }

  static Future<void> clearAllVoices({required String characterId}) async {
    final db = await DatabaseHelper.database;
    final paths = await db.transaction<List<String>>((txn) async {
      final rows = await txn.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'character_id = ?',
        whereArgs: [characterId],
      );
      await txn.delete(
        'saved_voices',
        where: 'character_id = ?',
        whereArgs: [characterId],
      );
      return rows.map((row) => row['file_path']).whereType<String>().toList();
    });
    await AppFileSafety.deleteOwnedFiles(paths);
  }

  static Future<int> getVoiceCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM saved_voices',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
