part of 'database.dart';

class _NoteStickerStore {
  static Future<int> insertSticker(Map<String, dynamic> sticker) async {
    final db = await DatabaseHelper.database;
    return await db.insert('stickers', sticker);
  }

  static Future<List<Map<String, dynamic>>> getStickers({
    String characterId = 'user',
  }) async {
    final db = await DatabaseHelper.database;
    return await db.query(
      'stickers',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
    );
  }

  static Future<void> deleteSticker(int id) async {
    final db = await DatabaseHelper.database;
    final path = await db.transaction<String?>((txn) async {
      final rows = await txn.query(
        'stickers',
        columns: ['file_path'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      await txn.delete('stickers', where: 'id = ?', whereArgs: [id]);
      return rows.isEmpty ? null : rows.first['file_path'] as String?;
    });
    await AppFileSafety.deleteOwnedFiles([path]);
  }

  static Future<void> updateStickerFilePath(int id, String filePath) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'stickers',
      {'file_path': filePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<int> addNote(
    String content, {
    String characterId = 'default',
  }) async {
    final db = await DatabaseHelper.database;
    await _ensureNoteCharacterColumn(db);
    return await db.insert('sticky_notes', {
      'content': content,
      'character_id': characterId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getNotes({
    int limit = 20,
    String? characterId,
  }) async {
    final db = await DatabaseHelper.database;
    await _ensureNoteCharacterColumn(db);
    if (characterId != null) {
      return await db.query(
        'sticky_notes',
        where: 'character_id = ?',
        whereArgs: [characterId],
        orderBy: 'id DESC',
        limit: limit,
      );
    }
    return await db.query('sticky_notes', orderBy: 'id DESC', limit: limit);
  }

  static Future<Map<String, dynamic>?> getLatestNote({
    String? characterId,
  }) async {
    final db = await DatabaseHelper.database;
    await _ensureNoteCharacterColumn(db);
    List<Map<String, dynamic>> rows;
    if (characterId != null) {
      rows = await db.query(
        'sticky_notes',
        where: 'character_id = ?',
        whereArgs: [characterId],
        orderBy: 'id DESC',
        limit: 1,
      );
    } else {
      rows = await db.query('sticky_notes', orderBy: 'id DESC', limit: 1);
    }
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, dynamic>>> getRandomNotes(
    String characterId, {
    int count = 10,
  }) async {
    final db = await DatabaseHelper.database;
    await _ensureNoteCharacterColumn(db);
    // 取除了最新之外的隨機 N 條
    final latest = await getLatestNote(characterId: characterId);
    final latestId = latest?['id'] as int? ?? -1;
    final rows = await db.rawQuery(
      '''
        SELECT * FROM sticky_notes
        WHERE character_id = ? AND id != ?
        ORDER BY RANDOM()
        LIMIT ?
      ''',
      [characterId, latestId, count],
    );
    return rows;
  }

  static Future<void> deleteNote(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete('sticky_notes', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> _ensureNoteCharacterColumn(Database db) async {
    if (DatabaseHelper._noteColumnEnsured) return;
    await DatabaseHelper._safeAddColumn(
      db,
      'sticky_notes',
      'character_id',
      "TEXT NOT NULL DEFAULT 'default'",
    );
    DatabaseHelper._noteColumnEnsured = true;
  }
}
