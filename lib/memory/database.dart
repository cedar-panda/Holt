// ignore_for_file: unnecessary_string_escapes

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/memory.dart';
import '../utils/app_file_safety.dart';
import '../utils/iso_week.dart';

part 'database_schema.dart';

enum WebSearchUsageReservationResult {
  reserved,
  duplicateTurn,
  dailyLimitExceeded,
}

/// 本地數據庫
class DatabaseHelper {
  static Database? _database;
  static Future<Database>? _dbInitFuture;
  static Future<Database> Function() _databaseInitializer = _initDatabase;
  static const String _dbName = 'yanci.db';
  static const int _dbVersion = 43;
  static final Random _windowIdRandom = Random.secure();

  static Future<Database> get database async {
    if (_database != null) return _database!;
    final initFuture = _dbInitFuture ??= _databaseInitializer();
    try {
      final db = await initFuture;
      _database = db;
      return db;
    } catch (_) {
      // A failed Future must not poison every later database access until the
      // process restarts. Only clear the Future that this caller awaited: a
      // later retry may already have installed a new one.
      if (identical(_dbInitFuture, initFuture)) {
        _dbInitFuture = null;
      }
      rethrow;
    }
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    return await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _deduplicateAllStoredSelfNotes,
    );
  }

  static Future<void> _onCreate(Database db, int version) =>
      _DatabaseSchema._onCreate(db, version);

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) =>
      _DatabaseSchema._onUpgrade(db, oldVersion, newVersion);

  static Future<void> _safeAddColumn(
    Database db,
    String table,
    String colName,
    String def,
  ) => _DatabaseSchema._safeAddColumn(db, table, colName, def);

  @visibleForTesting
  static int get schemaVersionForTesting => _dbVersion;

  @visibleForTesting
  static Future<void> createSchemaForTesting(Database db) {
    return _onCreate(db, _dbVersion);
  }

  @visibleForTesting
  static Future<void> upgradeSchemaForTesting(Database db, int oldVersion) {
    return _onUpgrade(db, oldVersion, _dbVersion);
  }

  /// Installs an isolated database for repository tests. Production code never
  /// calls this; keeping it here lets tests exercise the public archive APIs
  /// rather than duplicating their SQL.
  @visibleForTesting
  static void useDatabaseForTesting(Database? db) {
    _database = db;
    _dbInitFuture = db == null ? null : Future<Database>.value(db);
    _noteColumnEnsured = false;
  }

  @visibleForTesting
  static void useDatabaseInitializerForTesting(
    Future<Database> Function()? initializer,
  ) {
    _database = null;
    _dbInitFuture = null;
    _databaseInitializer = initializer ?? _initDatabase;
  }

  // ═══ 上下文壓縮表 ═══
  static Future<void> _createContextSummaryTables(Database db) async {
    // 摘要塊（滾動上限 1200 tokens）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        source_window_id TEXT DEFAULT '',
        source_conversation_id TEXT DEFAULT '',
        content TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        locked INTEGER DEFAULT 0
      )
    ''');
    // 關鍵詞層（舊摘要提煉，上限 900 tokens）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_keywords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        source_window_id TEXT DEFAULT '',
        source_conversation_id TEXT DEFAULT '',
        keywords TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        source_summary_id INTEGER,
        source_summary_content TEXT DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
  }

  /// 語音庫表
  static Future<void> _createVoiceTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_voices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL,
        name TEXT NOT NULL,
        message_id TEXT,
        source_conversation_id TEXT,
        source_conversation_title TEXT,
        character_id TEXT DEFAULT 'default',
        duration_ms INTEGER DEFAULT 0,
        file_size INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_voice_msg ON saved_voices(message_id)',
    );
  }

  // ═══════════════════════════════════
  // 語音庫操作
  // ═══════════════════════════════════

  /// 保存語音
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
    final db = await database;
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

  /// 根據 messageId 查找已緩存的語音
  static Future<String?> getVoicePathByMessageId(String messageId) async {
    final db = await database;
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

  /// 獲取所有已保存語音
  static Future<List<Map<String, dynamic>>> getSavedVoices({
    String? characterId,
  }) async {
    final db = await database;
    final where = characterId != null ? 'character_id = ?' : null;
    final args = characterId != null ? [characterId] : null;
    return await db.query(
      'saved_voices',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
  }

  /// 更新語音名稱
  static Future<void> updateVoiceName(int id, String newName) async {
    final db = await database;
    await db.update(
      'saved_voices',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 刪除單條語音
  static Future<void> deleteVoice(int id) async {
    final db = await database;
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

  /// 清除指定角色的語音緩存
  static Future<void> clearAllVoices({required String characterId}) async {
    final db = await database;
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

  /// 語音總數
  static Future<int> getVoiceCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM saved_voices',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ═══════════════════════════════════
  // 角色卡操作
  // ═══════════════════════════════════

  /// 後台畫圖完成：更新消息的圖片路徑與記憶日誌
  static Future<void> updateMessageDraw(
    int messageId,
    String? imagePath,
    String memoryLog,
  ) async {
    final db = await database;
    await db.update(
      'messages',
      {'image_path': ?imagePath, 'memory_log': memoryLog},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 關鍵詞搜尋歷史消息（模型 `<search_chat>` 工具用）
  /// 先選最新 [limit] 條，再以舊→新返回，讓模型按正確時序閱讀。
  static Future<List<Map<String, dynamic>>> searchMessages({
    required String keyword,
    required String characterId,
    int limit = 5,
  }) async {
    final db = await database;
    return db.rawQuery(
      """
      SELECT recent.id, recent.text, recent.is_user, recent.created_at, recent.title
      FROM (
        SELECT m.id, m.text, m.is_user, m.created_at, c.title
        FROM messages m
        LEFT JOIN conversations c ON m.conversation_id = c.id
        WHERE m.character_id = ? AND m.text LIKE ? ESCAPE '\'
        ORDER BY m.created_at DESC, m.id DESC
        LIMIT ?
      ) AS recent
      ORDER BY recent.created_at ASC, recent.id ASC
    """,
      [characterId, _likeContains(keyword), limit],
    );
  }

  /// 該角色最後一條消息的時間（安全感閒置衰減的錨點）
  static Future<DateTime?> getLastMessageTime(String characterId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT MAX(created_at) AS last FROM messages WHERE character_id = ?',
      [characterId],
    );
    final v = rows.isEmpty ? null : rows.first['last'] as String?;
    return v == null ? null : DateTime.tryParse(v);
  }

  /// 追加角色自我註記（最多保留 12 條，先進先出）。
  ///
  /// 完全相同或正規化後相似度 >= 90% 的條目只保留資訊較完整的一條。
  /// 返回 false 表示 incoming 沒有為註記集合增加任何資訊；即使如此，
  /// transaction 仍會順手清理舊資料中已經存在的重複條目。
  static Future<bool> appendSelfNote(String characterId, String note) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
      );
      if (rows.isEmpty) return false;
      final existing = (rows.first['self_notes'] as String?) ?? '';
      final result = _mergeSelfNotesDetailed(existing, note);
      if (result.text != existing) {
        await txn.update(
          'characters',
          {'self_notes': result.text},
          where: 'id = ?',
          whereArgs: [characterId],
        );
      }
      return result.acceptedIncoming;
    });
  }

  @visibleForTesting
  static String mergeSelfNotes(String existing, String incoming) =>
      _mergeSelfNotesDetailed(existing, incoming).text;

  static ({String text, bool acceptedIncoming}) _mergeSelfNotesDetailed(
    String existing,
    String incoming,
  ) {
    final cleanIncoming = _cleanSelfNote(incoming);
    var lines = _deduplicateSelfNoteLines(_selfNoteLines(existing));
    if (cleanIncoming.isEmpty) {
      return (text: _formatSelfNotes(lines), acceptedIncoming: false);
    }

    for (var index = 0; index < lines.length; index++) {
      final old = lines[index];
      if (!_selfNotesOverlap(old, cleanIncoming)) continue;
      // A strict superset may carry a useful qualifier. Replace in place so
      // deduplication never changes note ordering or consumes another slot.
      if (_selfNoteInformationScore(cleanIncoming) >
          _selfNoteInformationScore(old)) {
        lines[index] = cleanIncoming;
        return (text: _formatSelfNotes(lines), acceptedIncoming: true);
      }
      return (text: _formatSelfNotes(lines), acceptedIncoming: false);
    }

    lines.add(cleanIncoming);
    if (lines.length > 12) lines = lines.sublist(lines.length - 12);
    return (text: _formatSelfNotes(lines), acceptedIncoming: true);
  }

  static List<String> _selfNoteLines(String value) => value
      .split('\n')
      .map(_cleanSelfNote)
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  static String _formatSelfNotes(List<String> lines) =>
      lines.map((line) => '· $line').join('\n');

  /// Removes duplicates already present in storage while preserving the first
  /// position of each group. A later, more informative variant replaces the
  /// shorter wording in place, so cleanup never shuffles the character's
  /// self-note chronology.
  static List<String> _deduplicateSelfNoteLines(Iterable<String> source) {
    final kept = <String>[];
    for (final raw in source) {
      final candidate = _cleanSelfNote(raw);
      if (candidate.isEmpty) continue;
      final matching = <int>[
        for (var index = 0; index < kept.length; index++)
          if (_selfNotesOverlap(kept[index], candidate)) index,
      ];
      if (matching.isEmpty) {
        kept.add(candidate);
        continue;
      }

      final first = matching.first;
      var winner = kept[first];
      if (_selfNoteInformationScore(candidate) >
          _selfNoteInformationScore(winner)) {
        winner = candidate;
      }
      for (final index in matching.skip(1)) {
        final current = kept[index];
        if (_selfNoteInformationScore(current) >
            _selfNoteInformationScore(winner)) {
          winner = current;
        }
      }
      kept[first] = winner;
      for (final index in matching.skip(1).toList().reversed) {
        kept.removeAt(index);
      }
    }
    return kept.length <= 12 ? kept : kept.sublist(kept.length - 12);
  }

  static String _cleanSelfNote(String value) =>
      value.trim().replaceFirst(RegExp(r'^[·•*\-]+\s*'), '').trim();

  static bool _selfNotesOverlap(String left, String right) {
    final a = _normalizeSelfNote(left);
    final b = _normalizeSelfNote(right);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (_selfNotesConflict(a, b)) return false;
    return _selfNoteSimilarity(a, b) >= 0.90;
  }

  static bool _selfNotesConflict(String left, String right) {
    const polarityTerms = <String>[
      '不再',
      '不是',
      '不會',
      '不能',
      '不要',
      '沒有',
      '没',
      '不',
      '無',
      '无',
      '拒絕',
      '拒绝',
      '取消',
      '結束',
      '结束',
    ];
    final leftPolarity = {
      for (final term in polarityTerms)
        if (left.contains(term)) term,
    };
    final rightPolarity = {
      for (final term in polarityTerms)
        if (right.contains(term)) term,
    };
    if (!setEquals(leftPolarity, rightPolarity)) return true;

    Set<String> numbers(String value) => RegExp(
      r'\d+(?:\.\d+)?',
    ).allMatches(value).map((match) => match.group(0)!).toSet();
    return !setEquals(numbers(left), numbers(right));
  }

  static double _selfNoteSimilarity(String left, String right) {
    final maxLength = max(left.length, right.length);
    if (maxLength == 0) return 1;
    final editSimilarity = 1 - _levenshtein(left, right) / maxLength;

    final shorter = left.length <= right.length ? left : right;
    final longer = left.length <= right.length ? right : left;
    final containmentSimilarity = longer.contains(shorter)
        ? shorter.length / longer.length
        : 0.0;

    final aPairs = _selfNoteBigrams(left);
    final bPairs = _selfNoteBigrams(right);
    if (aPairs.isEmpty || bPairs.isEmpty) {
      return max(editSimilarity, containmentSimilarity);
    }
    final intersection = aPairs.intersection(bPairs).length;
    final diceSimilarity =
        (2.0 * intersection) / (aPairs.length + bPairs.length);
    return max(editSimilarity, max(containmentSimilarity, diceSimilarity));
  }

  static int _levenshtein(String left, String right) {
    if (left == right) return 0;
    if (left.isEmpty) return right.length;
    if (right.isEmpty) return left.length;
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitutionCost =
            left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
            ? 0
            : 1;
        current[rightIndex] = min(
          min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
          previous[rightIndex - 1] + substitutionCost,
        );
      }
      previous = current;
    }
    return previous[right.length];
  }

  static String _normalizeSelfNote(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      if (rune >= 0xff01 && rune <= 0xff5e) {
        buffer.writeCharCode(rune - 0xfee0);
      } else if (RegExp(
        r'[a-z0-9\u3400-\u9fff]',
      ).hasMatch(String.fromCharCode(rune))) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static Set<String> _selfNoteBigrams(String value) {
    if (value.length < 2) return {value};
    return {
      for (var index = 0; index < value.length - 1; index++)
        value.substring(index, index + 2),
    };
  }

  static int _selfNoteInformationScore(String value) =>
      _normalizeSelfNote(value).length;

  static Future<String> getSelfNotes(String characterId) async {
    final db = await database;
    return db.transaction<String>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
      );
      if (rows.isEmpty) return '';
      final stored = (rows.first['self_notes'] as String?) ?? '';
      final cleaned = _formatSelfNotes(
        _deduplicateSelfNoteLines(_selfNoteLines(stored)),
      );
      if (cleaned != stored) {
        await txn.update(
          'characters',
          {'self_notes': cleaned},
          where: 'id = ?',
          whereArgs: [characterId],
        );
      }
      return cleaned;
    });
  }

  /// One-time/lifecycle cleanup for existing characters. This deliberately
  /// touches only the authoritative character record; conversation-pinned
  /// snapshots remain immutable so an old cache prefix is never rewritten.
  static Future<void> _deduplicateAllStoredSelfNotes(Database db) async {
    final rows = await db.query(
      'characters',
      columns: ['id', 'self_notes'],
      where: "TRIM(COALESCE(self_notes, '')) <> ''",
    );
    final batch = db.batch();
    var changed = false;
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final stored = row['self_notes']?.toString() ?? '';
      final cleaned = _formatSelfNotes(
        _deduplicateSelfNoteLines(_selfNoteLines(stored)),
      );
      if (cleaned == stored) continue;
      changed = true;
      batch.update(
        'characters',
        {'self_notes': cleaned},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    if (changed) await batch.commit(noResult: true);
  }

  static Future<void> clearSelfNotes(String characterId) async {
    final db = await database;
    await db.update(
      'characters',
      {'self_notes': ''},
      where: 'id = ?',
      whereArgs: [characterId],
    );
  }

  static Future<void> insertCharacter(Map<String, dynamic> char) async {
    final db = await database;
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
    final db = await database;
    final safeUpdates = sanitizeCharacterUpdates(updates);
    await db.update(
      'characters',
      safeUpdates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Runtime whisper updates must not reorder the character list by touching
  /// updated_at. Card edits continue to use [updateCharacter].
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
    final db = await database;
    await db.update('characters', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Builds a partial character update without allowing identity/creation
  /// metadata to be rewritten. Because this map contains only supplied fields,
  /// runtime-managed and future columns omitted by callers stay untouched.
  @visibleForTesting
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
    final db = await database;
    return await db.query('characters', orderBy: 'updated_at DESC');
  }

  static Future<Map<String, dynamic>?> getCharacter(String id) async {
    final db = await database;
    final maps = await db.query(
      'characters',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : maps.first;
  }

  /// 取得角色的畫畫錨點（user + char + style）
  static Future<({String user, String char, String style})> getDrawAnchors(
    String characterId,
  ) async {
    final char = await getCharacter(characterId);
    return (
      user: (char?['draw_anchor_user'] as String?) ?? '',
      char: (char?['draw_anchor_char'] as String?) ?? '',
      style: (char?['draw_style'] as String?) ?? '',
    );
  }

  static Future<void> deleteCharacter(String id) async {
    final db = await database;
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
          columns: ['image_path'],
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        files.addAll(
          images.map((row) => row['image_path']).whereType<String>(),
        );
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
          'saved_messages',
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
        'OR memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, id],
      );
      batch.rawDelete(
        'DELETE FROM grudge_seals '
        'WHERE character_id = ? '
        'OR memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, id],
      );
      batch.rawDelete(
        'DELETE FROM character_timeline '
        'WHERE character_id = ? '
        'OR source_memory_id IN '
        '(SELECT id FROM memories WHERE character_id = ?)',
        [id, id],
      );
      batch.delete('archive', where: 'character_id = ?', whereArgs: [id]);
      batch.delete('backpack_items', where: 'owner_id = ?', whereArgs: [id]);
      batch.delete('sticky_notes', where: 'character_id = ?', whereArgs: [id]);
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
      batch.delete('memories', where: 'character_id = ?', whereArgs: [id]);
      batch.delete(
        'context_summaries',
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

  // ═══════════════════════════════════
  // 對話操作（帶角色過濾）
  // ═══════════════════════════════════

  static Future<void> createConversation(Conversation conv) async {
    final db = await database;
    await db.insert(
      'conversations',
      conv.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> updateConversation(String id, {String? title}) async {
    final db = await database;
    final updates = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (title != null) updates['title'] = title;
    await db.update('conversations', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// 修正對話的角色綁定（角色 ID 失效時的恢復路徑）
  static Future<void> updateConversationCharacter(
    String conversationId,
    String characterId,
  ) async {
    final db = await database;
    await db.update(
      'conversations',
      {'character_id': characterId},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 星標 / 取消星標
  static Future<void> toggleStarConversation(String id, bool starred) async {
    final db = await database;
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
    final db = await database;
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

  /// 搜索對話（標題模糊匹配）
  static Future<List<Conversation>> searchConversations(
    String query, {
    String? characterId,
  }) async {
    final db = await database;
    String where = "title LIKE ? ESCAPE '\\'";
    List<dynamic> args = [_likeContains(query)];
    if (characterId != null) {
      where += ' AND character_id = ?';
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
    final db = await database;
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
    final db = await database;
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

      final generated = await _generateWindowSummaryId(txn);
      await txn.update(
        'conversations',
        {'window_summary_id': generated},
        where: 'id = ?',
        whereArgs: [id],
      );
      return generated;
    });
  }

  /// 產生並強制更新一個新的 window_summary_id 給指定對話
  static Future<String> rotateConversationWindowSummaryId(String id) async {
    final db = await database;
    return db.transaction((txn) async {
      final generated = await _generateWindowSummaryId(txn);
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
    final db = await database;
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
    final db = await database;
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

  /// 讀取對話的靜態摘要 pin。null = 從未釘過（含遷移前的既有對話）；
  /// 空字串 = 出生時無前情、已釘為空。兩者要分開，別用 DEFAULT ''。
  static Future<String?> getConversationPinnedSummary(String id) async {
    final db = await database;
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

  /// 原子釘死對話的靜態摘要文本。
  ///
  /// 多個 prompt builder 同時首建時，只允許第一個寫入；其餘呼叫端
  /// 讀回資料庫中已釘定的正規值，避免同一 conversation 出現兩份
  /// 不同的 static prefix。空字串也是有效的已釘值。
  static Future<String> setConversationPinnedSummaryIfAbsent(
    String id,
    String text,
  ) async {
    final db = await database;
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
    final db = await database;
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

  /// conversation 出生時只釘一次自我註記全量；之後新註記只走 dynamic。
  static Future<String> setConversationPinnedSelfNotesIfAbsent(
    String id,
    String text,
  ) async {
    final db = await database;
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

  static Future<String> _generateWindowSummaryId(DatabaseExecutor db) async {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const digits = '23456789';
    const any = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    for (int attempt = 0; attempt < 64; attempt++) {
      final chars = <String>[
        letters[_windowIdRandom.nextInt(letters.length)],
        digits[_windowIdRandom.nextInt(digits.length)],
        any[_windowIdRandom.nextInt(any.length)],
      ]..shuffle(_windowIdRandom);
      final candidate = chars.join();
      final collision = await db.query(
        'conversations',
        columns: ['id'],
        where: 'window_summary_id = ?',
        whereArgs: [candidate],
        limit: 1,
      );
      if (collision.isEmpty) return candidate;
    }

    final fallback = DateTime.now().microsecondsSinceEpoch
        .toRadixString(36)
        .toUpperCase();
    return 'A${fallback.substring(fallback.length - 2)}';
  }

  static Future<void> deleteConversation(String id) async {
    final db = await database;
    final filesToDelete = await db.transaction<Set<String>>((txn) async {
      final voices = await txn.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'source_conversation_id = ?',
        whereArgs: [id],
      );
      final images = await txn.query(
        'messages',
        columns: ['image_path'],
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      final files = <String>{
        ...voices.map((row) => row['file_path']).whereType<String>(),
        ...images.map((row) => row['image_path']).whereType<String>(),
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
      await txn.delete(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
      return files;
    });
    await AppFileSafety.deleteOwnedFiles(filesToDelete);
  }

  // ═══════════════════════════════════
  // 訊息操作
  // ═══════════════════════════════════

  static Future<int> insertMessage(Message msg) async {
    final db = await database;
    final id = await db.insert('messages', msg.toMap());
    await updateConversation(msg.conversationId);
    return id;
  }

  /// 從指定 message id（含）起載入對話全部消息——上下文窗口錨點用。
  /// 錨點指向的消息被刪時，自然從下一條 id 開始，不會返回空窗。
  static Future<List<Message>> getMessagesFromId(
    String conversationId,
    int fromId,
  ) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id >= ?',
      whereArgs: [conversationId, fromId],
      orderBy: 'created_at ASC, id ASC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  /// Window-summary source after the last successfully persisted cursor.
  /// Message ids are global and monotonic, so the conversation predicate keeps
  /// this query deterministic even when several windows are active together.
  static Future<List<Message>> getMessagesAfterId(
    String conversationId,
    int afterId,
  ) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id > ?',
      whereArgs: [conversationId, afterId],
      orderBy: 'id ASC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  /// 從 [sourceConversationId] 開分支：複製 [beforeMessageId] 之前的
  /// 全部消息到新對話（原對話一字不動），返回新對話 id。
  /// 用途：編輯發送窗之外的老消息時不破壞原時間線，另起爐灶。
  static Future<String> branchConversation({
    required String sourceConversationId,
    required int beforeMessageId,
    String? title,
  }) async {
    final db = await database;
    final src = await getConversation(sourceConversationId);
    final newId = const Uuid().v4();
    final branchTitle =
        title ??
        ((src?.title?.isNotEmpty ?? false) ? '⑂ ${src!.title}' : '⑂ 分支對話');

    await db.transaction((txn) async {
      await txn.insert(
        'conversations',
        Conversation(
          id: newId,
          characterId: src?.characterId ?? 'default',
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

  /// 取指定 id 之前的最後 [limit] 條（升序返回）——錨點前純顯示分頁用
  static Future<List<Message>> getMessagesBeforeId(
    String conversationId,
    int beforeId, {
    int limit = 50,
  }) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'conversation_id = ? AND id < ?',
      whereArgs: [conversationId, beforeId],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return maps.map((m) => Message.fromMap(m)).toList().reversed.toList();
  }

  /// 指定 id 之前是否還有消息（「查看更早」按鈕顯示條件）
  static Future<bool> hasMessagesBefore(
    String conversationId,
    int beforeId,
  ) async {
    final db = await database;
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
    final db = await database;
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

  static Future<int> getMessageCount(String conversationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['count'] as int;
  }

  static Future<Message?> getLastMessage(String conversationId) async {
    final db = await database;
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

  static Future<void> deleteMessageById(int id) async {
    final db = await database;
    final imagePaths = await db.transaction<List<String>>((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['image_path'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      return rows.map((row) => row['image_path']).whereType<String>().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  static Future<void> deleteMessageByFingerprint(Message msg) async {
    final db = await database;
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
      final rows = await txn.query(
        'messages',
        columns: ['image_path'],
        where: where,
        whereArgs: args,
      );
      await txn.delete('messages', where: where, whereArgs: args);
      return rows.map((row) => row['image_path']).whereType<String>().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  /// 覆蓋消息文本（不刪除原記錄）
  static Future<void> updateMessageText(int id, String newText) async {
    final db = await database;
    await db.update(
      'messages',
      {'text': newText},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateMessageStatus(int id, String status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ═══════════════════════════════════
  // ═══ FTS5 全文搜索 ═══

  /// 重建 FTS5 全文索引。備份還原後必須呼叫。
  static Future<void> rebuildMemoryFts() async {
    final db = await database;
    await _DatabaseSchema.rebuildMemoryFts(db);
  }

  /// 確保所有 late-added schema 表存在。
  ///
  /// v39 加了 pending_memory_actions、v42 加了 web_search_usage_logs，
  /// 但若 DB 已經是 v43 且表是在同版本號內後加的，migration 不會重跑。
  /// 備份 export/import 前呼叫此方法，避免 _verifyTableManifest 因缺表而拒絕操作。
  static Future<void> ensureAllSchemaTables() async {
    final db = await database;
    await _DatabaseSchema._createPendingMemoryActionsTable(db);
    await _DatabaseSchema._createWebSearchUsageTable(db);
  }

  /// BM25 全文搜索記憶。返回按相關度排序的 Memory 列表。
  /// [query] 為用戶輸入的原始文本，會被拆成搜索詞。
  /// 只搜索指定角色 + 模式的 active 記憶。
  static Future<List<Memory>> searchMemoriesByText(
    String query, {
    required String mode,
    String characterId = 'default',
    int limit = 20,
  }) async {
    if (query.trim().isEmpty) return [];
    final db = await database;

    // 將用戶輸入拆成獨立搜索詞，用 OR 連接（任一詞命中即可）。
    // FTS5 的 unicode61 tokenizer 會把 CJK 逐字拆分。
    final terms = _buildFtsQuery(query);
    if (terms.isEmpty) return [];

    try {
      final rows = await db.rawQuery(
        '''
        SELECT m.*, bm25(memories_fts, 1.0, 0.5) AS _rank
        FROM memories_fts
        JOIN memories m ON m.id = memories_fts.rowid
        WHERE memories_fts MATCH ?
          AND m.status = 'active'
          AND m.mode = ?
          AND m.character_id = ?
        ORDER BY _rank
        LIMIT ?
        ''',
        [terms, mode, characterId, limit],
      );
      return rows.map(Memory.fromMap).toList();
    } catch (e) {
      // FTS5 不可用時（極罕見）靜默降級，不阻塞主流程
      developer.log('FTS5 search failed', error: e, name: 'DatabaseHelper');
      return [];
    }
  }

  /// 把用戶輸入轉成 FTS5 MATCH 表達式。
  /// CJK 字符逐字拆開，其他按空白分詞，用 OR 連接。
  /// 過濾掉太短的非 CJK token 和 FTS5 保留字元。
  static String _buildFtsQuery(String input) {
    final cjkRe = RegExp(r'[　-ヿ一-鿿＀-￯]');
    final tokens = <String>{};

    for (final char in input.runes) {
      final s = String.fromCharCode(char);
      if (cjkRe.hasMatch(s)) {
        tokens.add(s);
      }
    }

    // 非 CJK 部分按空白拆詞
    final nonCjk = input.replaceAll(cjkRe, ' ').trim();
    if (nonCjk.isNotEmpty) {
      for (final word in nonCjk.split(RegExp(r'\s+'))) {
        final cleaned = word.replaceAll(RegExp(r'["\*\(\)\{\}\[\]:^~]'), '');
        if (cleaned.length >= 2) tokens.add(cleaned);
      }
    }

    if (tokens.isEmpty) return '';
    return tokens.map((t) => '"$t"').join(' OR ');
  }

  // 記憶操作（帶角色過濾）
  // ═══════════════════════════════════

  static Future<int> insertMemory(Memory mem) async {
    final db = await database;
    return await db.insert('memories', mem.toMap());
  }

  static Future<void> insertMemories(List<Memory> memories) async {
    final db = await database;
    final batch = db.batch();
    for (final mem in memories) {
      batch.insert('memories', mem.toMap());
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Memory>> getActiveMemories(
    String mode, {
    String characterId = 'default',
  }) async {
    final db = await database;
    final maps = await db.query(
      'memories',
      where: 'mode = ? AND status = ? AND character_id = ?',
      whereArgs: [mode, 'active', characterId],
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  /// 取得角色所有模式下的 active 記憶。蛛網分層必須從完整集合規劃，否則
  /// 舊連線的另一端若在不同模式，畫面會誤以為邊不存在。
  static Future<List<Memory>> getAllActiveMemories({
    String characterId = 'default',
  }) async {
    final db = await database;
    final maps = await db.query(
      'memories',
      where: 'status = ? AND character_id = ?',
      whereArgs: ['active', characterId],
      orderBy: 'created_at DESC',
    );
    return maps.map(Memory.fromMap).toList();
  }

  static Future<List<Memory>> getPermanentMemories(
    String mode, {
    String characterId = 'default',
  }) async {
    final db = await database;
    final maps = await db.query(
      'memories',
      where:
          'mode = ? AND is_permanent = 1 AND status = ? AND character_id = ?',
      whereArgs: [mode, 'active', characterId],
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
    final db = await database;
    final maps = await db.query(
      'memories',
      where:
          "mode = ? AND status = ? AND character_id = ? "
          "AND content LIKE ? ESCAPE '\\'",
      whereArgs: [mode, 'active', characterId, _likeContains(keyword)],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  /// 跨模式搜尋內容、觸發詞與類別。
  /// [limit] 為 null 時回傳全部結果；記憶整理搜尋不與對話召回上限綁定。
  static Future<List<Memory>> searchMemoriesForCharacter(
    String keyword, {
    String characterId = 'default',
    int? limit = 10,
  }) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return const [];
    final db = await database;
    final pattern = _likeContains(normalized);
    final maps = await db.query(
      'memories',
      where:
          "status = ? AND character_id = ? AND "
          "(content LIKE ? ESCAPE '\\' OR triggers LIKE ? ESCAPE '\\' "
          "OR category LIKE ? ESCAPE '\\')",
      whereArgs: ['active', characterId, pattern, pattern, pattern],
      orderBy: 'mention_count DESC, updated_at DESC',
      limit: limit?.clamp(1, 500),
    );
    return maps.map(Memory.fromMap).toList();
  }

  /// 獲取低置信度待審記憶
  static Future<List<Memory>> getLowConfidenceForReview({
    String characterId = 'default',
    int minCount = 3,
  }) async {
    final db = await database;
    final maps = await db.query(
      'memories',
      where:
          'confidence = ? AND status = ? AND character_id = ? AND review_count >= ?',
      whereArgs: ['low', 'active', characterId, minCount],
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
  }

  /// 記憶被關鍵詞命中注入時 +1（衰減校準的原始數據）
  static Future<void> incrementMention(int memoryId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE memories SET mention_count = mention_count + 1 WHERE id = ?',
      [memoryId],
    );
  }

  /// 低置信度累計 +1
  static Future<void> incrementReviewCount(int memoryId) async {
    final db = await database;
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
    final db = await database;
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

  /// Atomically moves every matching active memory into the dusty box.
  /// Missing/stale ids are ignored, while all rows that are found commit as
  /// one unit so a failed batch never leaves a half-deleted selection.
  static Future<int> archiveMemories(
    Iterable<int> memoryIds,
    String reason, {
    required String characterId,
  }) async {
    final ids = memoryIds.where((id) => id > 0).toSet().toList()..sort();
    if (ids.isEmpty) return 0;
    final db = await database;
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

  /// 升級低置信度記憶為中置信度
  static Future<void> promoteMemory(int memoryId) async {
    final db = await database;
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
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM memories WHERE mode = ? AND status = ? AND character_id = ?',
      [mode, 'active', characterId],
    );
    return result.first['count'] as int;
  }

  // ═══════════════════════════════════
  // 表情包操作
  // ═══════════════════════════════════

  static Future<int> insertSticker(Map<String, dynamic> sticker) async {
    final db = await database;
    return await db.insert('stickers', sticker);
  }

  static Future<List<Map<String, dynamic>>> getStickers({
    String characterId = 'user',
  }) async {
    final db = await database;
    return await db.query(
      'stickers',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
    );
  }

  static Future<void> deleteSticker(int id) async {
    final db = await database;
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
    final db = await database;
    await db.update(
      'stickers',
      {'file_path': filePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ═══════════════════════════════════
  // 歸檔操作（積灰小盒子）
  // ═══════════════════════════════════

  /// 獲取歸檔記憶列表
  static Future<List<Map<String, dynamic>>> getArchivedMemories({
    required String characterId,
  }) async {
    final db = await database;
    return await db.query(
      'archive',
      where: 'character_id = ? AND original_table = ?',
      whereArgs: [characterId, 'memories'],
      orderBy: 'archived_at DESC, id DESC',
    );
  }

  /// 歸檔記憶計數
  static Future<int> getArchivedCount({required String characterId}) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM archive '
      'WHERE character_id = ? AND original_table = ?',
      [characterId, 'memories'],
    );
    return result.first['count'] as int;
  }

  /// 刪除單條歸檔及其原始記憶。保留舊方法名供既有呼叫者使用，
  /// 但不再留下 status=deleted 且無法恢復的孤兒列。
  static Future<bool> deleteArchivedMemory(
    int archiveId, {
    required String characterId,
  }) {
    return permanentlyDelete(archiveId, characterId: characterId);
  }

  /// 一鍵清空歸檔
  static Future<void> clearAllArchived({required String characterId}) async {
    final db = await database;
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

  /// 刪除活躍記憶（歸檔到小盒子 — 軟刪除，保留原始記錄可恢復）
  static Future<bool> deleteMemory(
    int memoryId, {
    bool archive = true,
    required String characterId,
  }) async {
    final db = await database;
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

  /// 從積灰小盒子恢復記憶到活躍狀態
  static Future<bool> restoreFromArchive(
    int archiveId, {
    required String characterId,
  }) async {
    final db = await database;
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
    final db = await database;
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
      final changed = await txn.update(
        'memories',
        {'status': 'active', 'updated_at': DateTime.now().toIso8601String()},
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
      snapshot['updated_at'] = DateTime.now().toIso8601String();
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
    final db = await database;
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

  /// 永久刪除（從 archive 和 memories 都移除）
  static Future<bool> permanentlyDelete(
    int archiveId, {
    required String characterId,
  }) async {
    final db = await database;
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
      where: 'character_id = ? AND memory_id = ?',
      whereArgs: [characterId, memoryId],
    );
    await txn.delete(
      'grudge_seals',
      where: 'character_id = ? AND memory_id = ?',
      whereArgs: [characterId, memoryId],
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

  // ═══════════════════════════════════
  // 便利貼
  // ═══════════════════════════════════

  static Future<int> addNote(
    String content, {
    String characterId = 'default',
  }) async {
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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

  /// 隨機取 N 條歷史便箋（排除最新一條）
  static Future<List<Map<String, dynamic>>> getRandomNotes(
    String characterId, {
    int count = 10,
  }) async {
    final db = await database;
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
    final db = await database;
    await db.delete('sticky_notes', where: 'id = ?', whereArgs: [id]);
  }

  /// 舊資料庫的防禦性檢查；fresh/v33 schema 已正式包含此欄位。
  static bool _noteColumnEnsured = false;
  static Future<void> _ensureNoteCharacterColumn(Database db) async {
    if (_noteColumnEnsured) return;
    await _safeAddColumn(
      db,
      'sticky_notes',
      'character_id',
      "TEXT NOT NULL DEFAULT 'default'",
    );
    _noteColumnEnsured = true;
  }

  // ═══════════════════════════════════
  // 用量記錄
  // ═══════════════════════════════════

  /// Atomically reserves every provider route in one logical web-search plan.
  ///
  /// Reserved rows consume capacity to prevent concurrent turns from racing
  /// past the cap. Only rows that reach `launched` (or a final launch outcome)
  /// are reported as provider launches; unlaunched rows are released.
  static Future<WebSearchUsageReservationResult>
  reserveWebSearchProviderLaunches({
    required String reservationId,
    required String conversationId,
    required String characterId,
    required String turnId,
    required int generationSerial,
    required String planStrategy,
    required List<({String provider, String model, String route})> routes,
    required String budgetDay,
    required int dailyProviderLaunchCap,
    required String reservedAt,
    required String expiresAt,
  }) async {
    if (routes.isEmpty || routes.length > 2) {
      throw ArgumentError.value(
        routes,
        'routes',
        'Expected one or two routes.',
      );
    }
    if ((planStrategy == 'single' && routes.length != 1) ||
        (planStrategy == 'dual' && routes.length != 2) ||
        (planStrategy != 'single' && planStrategy != 'dual')) {
      throw ArgumentError.value(
        planStrategy,
        'planStrategy',
        'Plan strategy does not match its routes.',
      );
    }
    if (dailyProviderLaunchCap < 1) {
      throw ArgumentError.value(
        dailyProviderLaunchCap,
        'dailyProviderLaunchCap',
        'The daily provider-launch cap must be positive.',
      );
    }
    final db = await database;
    return db.transaction<WebSearchUsageReservationResult>((txn) async {
      // A grant that was never claimed can be released safely. A claimed
      // execution that vanished with the process is uncertain, so both a
      // claimed dispatch window and an already-launched provider settle as
      // unknown instead of silently granting the budget back or remaining in
      // a non-final state forever.
      await txn.rawUpdate(
        "UPDATE web_search_usage_logs SET status = 'released', settled_at = ? "
        "WHERE status = 'reserved' AND expires_at <= ?",
        <Object?>[reservedAt, reservedAt],
      );
      await txn.rawUpdate(
        "UPDATE web_search_usage_logs SET status = 'unknown', settled_at = ?, "
        "cost_certainty = 'unknown' "
        "WHERE status IN ('claimed', 'launched') "
        'AND expires_at <= ?',
        <Object?>[reservedAt, reservedAt],
      );

      final existingTurn = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['id'],
        where:
            'conversation_id = ? AND turn_id = ? AND generation_serial = ? '
            'AND logical_slot = 1',
        whereArgs: <Object?>[conversationId, turnId, generationSerial],
        limit: 1,
      );
      if (existingTurn.isNotEmpty) {
        return WebSearchUsageReservationResult.duplicateTurn;
      }

      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM web_search_usage_logs '
        "WHERE budget_day = ? AND status != 'released'",
        <Object?>[budgetDay],
      );
      final reservedOrUsed = Sqflite.firstIntValue(countRows) ?? 0;
      if (reservedOrUsed + routes.length > dailyProviderLaunchCap) {
        return WebSearchUsageReservationResult.dailyLimitExceeded;
      }

      final batch = txn.batch();
      for (var index = 0; index < routes.length; index++) {
        final route = routes[index];
        batch.insert('web_search_usage_logs', <String, Object?>{
          'reservation_id': reservationId,
          'logical_slot': index == 0 ? 1 : 0,
          'conversation_id': conversationId,
          'character_id': characterId,
          'turn_id': turnId,
          'generation_serial': generationSerial,
          'budget_day': budgetDay,
          'plan_strategy': planStrategy,
          'provider': route.provider,
          'provider_model': route.model,
          'provider_route': route.route,
          'status': 'reserved',
          'reserved_at': reservedAt,
          'expires_at': expiresAt,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
      }
      await batch.commit(noResult: true);
      return WebSearchUsageReservationResult.reserved;
    });
  }

  /// Consumes the durable half of a permission grant by binding it to exactly
  /// one ToolCall id. The handler still has to claim the bound reservation.
  static Future<bool> bindWebSearchReservationToCall({
    required String reservationId,
    required String callId,
    required String now,
  }) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['status', 'call_id', 'expires_at'],
        where: 'reservation_id = ?',
        whereArgs: <Object?>[reservationId],
      );
      if (rows.isEmpty ||
          rows.any(
            (row) =>
                row['status'] != 'reserved' ||
                row['call_id'] != null ||
                (row['expires_at']! as String).compareTo(now) <= 0,
          )) {
        return false;
      }
      final reusedCall = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['id'],
        where: 'call_id = ? AND logical_slot = 1',
        whereArgs: <Object?>[callId],
        limit: 1,
      );
      if (reusedCall.isNotEmpty) return false;
      final changed = await txn.update(
        'web_search_usage_logs',
        <String, Object?>{'call_id': callId},
        where:
            'reservation_id = ? AND status = ? AND call_id IS NULL '
            'AND expires_at > ?',
        whereArgs: <Object?>[reservationId, 'reserved', now],
      );
      return changed == rows.length;
    });
  }

  /// Handler-only transition. It extends the short permission expiry into an
  /// execution lease so another reservation cannot reap an active request.
  static Future<bool> claimWebSearchReservation({
    required String reservationId,
    required String callId,
    required String budgetDay,
    required String claimedAt,
    required String executionExpiresAt,
  }) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['status', 'call_id', 'expires_at'],
        where: 'reservation_id = ? AND budget_day = ?',
        whereArgs: <Object?>[reservationId, budgetDay],
      );
      if (rows.isEmpty ||
          rows.any(
            (row) =>
                row['status'] != 'reserved' ||
                row['call_id'] != callId ||
                (row['expires_at']! as String).compareTo(claimedAt) <= 0,
          )) {
        return false;
      }
      final changed = await txn.update(
        'web_search_usage_logs',
        <String, Object?>{
          'status': 'claimed',
          'claimed_at': claimedAt,
          'expires_at': executionExpiresAt,
        },
        where:
            'reservation_id = ? AND call_id = ? AND budget_day = ? AND status = ? '
            'AND expires_at > ?',
        whereArgs: <Object?>[
          reservationId,
          callId,
          budgetDay,
          'reserved',
          claimedAt,
        ],
      );
      return changed == rows.length;
    });
  }

  /// Must be called immediately before dispatching a provider request.
  static Future<bool> markWebSearchProviderLaunched({
    required String reservationId,
    required String callId,
    required String provider,
    required String providerModel,
    required String providerRoute,
    required String launchedAt,
  }) async {
    final db = await database;
    final changed = await db.update(
      'web_search_usage_logs',
      <String, Object?>{'status': 'launched', 'launched_at': launchedAt},
      where:
          'reservation_id = ? AND call_id = ? AND provider = ? '
          'AND provider_model = ? AND provider_route = ? AND status = ?',
      whereArgs: <Object?>[
        reservationId,
        callId,
        provider,
        providerModel,
        providerRoute,
        'claimed',
      ],
    );
    return changed == 1;
  }

  static Future<bool> settleWebSearchProviderLaunch({
    required String reservationId,
    required String callId,
    required String provider,
    required String providerModel,
    required String providerRoute,
    required String outcome,
    required String settledAt,
    required int searchRequests,
    required int promptTokens,
    required int completionTokens,
    required double? actualCostUsd,
    required String costCertainty,
  }) async {
    if (!const <String>{
      'success',
      'failure',
      'cancelled',
      'unknown',
    }.contains(outcome)) {
      throw ArgumentError.value(outcome, 'outcome', 'Invalid launch outcome.');
    }
    final db = await database;
    final changed = await db.update(
      'web_search_usage_logs',
      <String, Object?>{
        'status': outcome,
        'settled_at': settledAt,
        'search_requests': searchRequests,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'actual_cost_usd': actualCostUsd,
        'cost_certainty': costCertainty,
      },
      where:
          'reservation_id = ? AND call_id = ? AND provider = ? '
          'AND provider_model = ? AND provider_route = ? AND status = ?',
      whereArgs: <Object?>[
        reservationId,
        callId,
        provider,
        providerModel,
        providerRoute,
        'launched',
      ],
    );
    return changed == 1;
  }

  /// Releases only routes for which no provider dispatch was recorded.
  static Future<int> releaseUnlaunchedWebSearchReservation({
    required String reservationId,
    String? callId,
    required String settledAt,
  }) async {
    final db = await database;
    final callClause = callId == null ? '' : ' AND call_id = ?';
    return db.rawUpdate(
      "UPDATE web_search_usage_logs SET status = 'released', settled_at = ? "
      "WHERE reservation_id = ? AND status IN ('reserved', 'claimed')"
      '$callClause',
      <Object?>[settledAt, reservationId, ?callId],
    );
  }

  /// Counts provider dispatches, not logical calls and not unused reservations.
  static Future<int> getWebSearchProviderLaunchCount(String budgetDay) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) FROM web_search_usage_logs '
      "WHERE budget_day = ? AND status NOT IN ('reserved', 'claimed', 'released')",
      <Object?>[budgetDay],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  static Future<void> logUsage({
    required String provider,
    required String model,
    String characterId = 'default',
    int promptTokens = 0,
    int completionTokens = 0,
    int cacheHitTokens = 0,
    int cacheCreationTokens = 0,
    double estimatedCost = 0.0,
  }) async {
    final db = await database;
    await db.insert('usage_logs', {
      'timestamp': DateTime.now().toIso8601String(),
      'provider': provider,
      'model': model,
      'character_id': characterId,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'cache_hit_tokens': cacheHitTokens,
      'cache_creation_tokens': cacheCreationTokens,
      'estimated_cost': estimatedCost,
    });
  }

  /// 獲取某段時間的用量彙總
  static Future<Map<String, dynamic>> getUsageSummary(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT 
        SUM(prompt_tokens) as total_prompt,
        SUM(completion_tokens) as total_completion,
        SUM(cache_hit_tokens) as total_cache_hit,
        SUM(estimated_cost) as total_cost,
        COUNT(*) as total_requests
      FROM usage_logs
      WHERE timestamp >= ? AND timestamp < ?
    ''',
      [from.toIso8601String(), to.toIso8601String()],
    );
    return rows.isEmpty ? {} : rows.first;
  }

  /// 獲取每日用量（折線圖用）
  static Future<List<Map<String, dynamic>>> getDailyUsage(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT 
        SUBSTR(timestamp, 1, 10) as date,
        SUM(prompt_tokens) as prompt,
        SUM(completion_tokens) as completion,
        SUM(cache_hit_tokens) as cache_hit,
        SUM(estimated_cost) as cost
      FROM usage_logs
      WHERE timestamp >= ? AND timestamp < ?
      GROUP BY SUBSTR(timestamp, 1, 10)
      ORDER BY date
    ''',
      [from.toIso8601String(), to.toIso8601String()],
    );
  }

  /// 按模型分組的用量
  static Future<List<Map<String, dynamic>>> getUsageByModel(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT 
        model,
        SUM(prompt_tokens + completion_tokens) as total_tokens,
        SUM(estimated_cost) as cost,
        COUNT(*) as requests
      FROM usage_logs
      WHERE timestamp >= ? AND timestamp < ?
      GROUP BY model
      ORDER BY cost DESC
    ''',
      [from.toIso8601String(), to.toIso8601String()],
    );
  }

  // ═══════════════════════════════════
  // 收藏消息
  // ═══════════════════════════════════

  /// 收藏消息表
  static Future<void> _createSavedMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT NOT NULL,
        content TEXT NOT NULL,
        character_id TEXT DEFAULT 'default',
        conversation_id TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_saved_char_time '
      'ON saved_messages(character_id, created_at DESC)',
    );
  }

  static Future<void> _createSavedMessageUniqueIndex(Database db) {
    return db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_message_unique '
      'ON saved_messages(message_id)',
    );
  }

  /// 收藏一條消息
  static Future<int> saveMessage({
    required String messageId,
    required String content,
    String characterId = 'default',
    String? conversationId,
  }) async {
    try {
      final db = await database;
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
        final db = await database;
        await _createSavedMessagesTable(db);
        await _createSavedMessageUniqueIndex(db);
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

  /// 取消收藏
  static Future<void> unsaveMessage(String messageId) async {
    final db = await database;
    await db.delete(
      'saved_messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// 查詢是否已收藏
  static Future<bool> isMessageSaved(String messageId) async {
    try {
      final db = await database;
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

  /// 獲取角色的收藏消息
  static Future<List<Map<String, dynamic>>> getSavedMessages({
    String characterId = 'default',
    int limit = 50,
  }) async {
    final db = await database;
    return await db.query(
      'saved_messages',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// 搜索收藏（關鍵詞匹配內容 + 日期格式如 7/3 匹配 created_at）
  static Future<List<Map<String, dynamic>>> searchSavedMessages(
    String query, {
    String characterId = 'default',
  }) async {
    final db = await database;
    return await db.query(
      'saved_messages',
      where:
          "character_id = ? AND "
          "(content LIKE ? ESCAPE '\\' OR created_at LIKE ? ESCAPE '\\')",
      whereArgs: [characterId, _likeContains(query), _likeContains(query)],
      orderBy: 'created_at DESC',
    );
  }

  /// 刪除收藏
  static Future<void> deleteSavedMessage(int id) async {
    final db = await database;
    await db.delete('saved_messages', where: 'id = ?', whereArgs: [id]);
  }

  static String _likeContains(String value) {
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return '%$escaped%';
  }

  @visibleForTesting
  static String likeContainsForTesting(String value) => _likeContains(value);

  // ═══════════════════════════════════
  // 上下文壓縮 CRUD
  // ═══════════════════════════════════

  /// 插入摘要塊
  static Future<int> insertContextSummary({
    required String characterId,
    required String content,
    required int tokenCount,
    String sourceWindowId = '',
    String sourceConversationId = '',
  }) async {
    final db = await database;
    return await db.insert('context_summaries', {
      'character_id': characterId,
      'source_window_id': sourceWindowId,
      'source_conversation_id': sourceConversationId,
      'content': content,
      'token_count': tokenCount,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Persist one automatic summary and its covered-message cursor atomically.
  /// A crash can therefore neither save a summary without advancing the
  /// cursor nor advance the cursor without saving its summary.
  static Future<int> insertContextSummaryAndAdvanceCursor({
    required String characterId,
    required String content,
    required int tokenCount,
    required String conversationId,
    required int cursorMessageId,
    String sourceWindowId = '',
  }) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      final id = await txn.insert('context_summaries', {
        'character_id': characterId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': conversationId,
        'content': content,
        'token_count': tokenCount,
        'created_at': DateTime.now().toIso8601String(),
      });
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
      return id;
    });
  }

  /// 取得角色的全部摘要塊（舊→新）
  static Future<List<Map<String, dynamic>>> getContextSummaries(
    String characterId,
  ) async {
    final db = await database;
    return await db.query(
      'context_summaries',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at ASC',
    );
  }

  /// 取得角色最新摘要塊（新→舊），可排除目前窗口
  static Future<List<Map<String, dynamic>>> getLatestContextSummaries(
    String characterId, {
    String? excludeWindowId,
    int limit = 2,
  }) async {
    final db = await database;
    final where = StringBuffer('character_id = ?');
    final args = <Object?>[characterId];
    final excluded = (excludeWindowId ?? '').trim();
    if (excluded.isNotEmpty) {
      where.write(
        " AND (source_window_id IS NULL OR source_window_id = '' OR source_window_id != ?)",
      );
      args.add(excluded);
    }
    return await db.query(
      'context_summaries',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
  }

  /// 取得摘要總 token 數
  static Future<int> getContextSummaryTokenTotal(String characterId) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_summaries WHERE character_id = ?',
      [characterId],
    );
    return r.first['total'] as int;
  }

  /// 覆蓋摘要塊
  static Future<void> updateContextSummary({
    required int id,
    required String content,
    required int tokenCount,
  }) async {
    final db = await database;
    await db.update(
      'context_summaries',
      {'content': content, 'token_count': tokenCount},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新摘要鎖定狀態
  static Future<void> updateSummaryLockState({
    required int id,
    required bool locked,
  }) async {
    final db = await database;
    await db.update(
      'context_summaries',
      {'locked': locked ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 刪除指定摘要塊
  static Future<void> deleteContextSummary(int id) async {
    final db = await database;
    await db.delete('context_summaries', where: 'id = ?', whereArgs: [id]);
  }

  /// 刪除最舊的摘要塊，返回被刪的記錄
  static Future<Map<String, dynamic>?> deleteOldestContextSummary(
    String characterId,
  ) async {
    final db = await database;
    final oldest = await db.query(
      'context_summaries',
      where: 'character_id = ? AND (locked IS NULL OR locked = 0)',
      whereArgs: [characterId],
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

  /// 插入關鍵詞塊
  static Future<int> insertContextKeywords({
    required String characterId,
    required String keywords,
    required int tokenCount,
    int? sourceSummaryId,
    String sourceSummaryContent = '',
    String sourceWindowId = '',
    String sourceConversationId = '',
  }) async {
    final db = await database;
    return await db.insert('context_keywords', {
      'character_id': characterId,
      'source_window_id': sourceWindowId,
      'source_conversation_id': sourceConversationId,
      'keywords': keywords,
      'token_count': tokenCount,
      'source_summary_id': sourceSummaryId,
      'source_summary_content': sourceSummaryContent,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 取得關鍵詞層
  static Future<List<Map<String, dynamic>>> getContextKeywords(
    String characterId,
  ) async {
    final db = await database;
    return await db.query(
      'context_keywords',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at ASC',
    );
  }

  /// 取得關鍵詞總 token 數
  static Future<int> getContextKeywordTokenTotal(String characterId) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_keywords WHERE character_id = ?',
      [characterId],
    );
    return r.first['total'] as int;
  }

  /// 覆蓋關鍵詞塊與其來源摘要快照
  static Future<void> updateContextKeywordBlock({
    required int id,
    required String keywords,
    required int tokenCount,
    required String sourceSummaryContent,
  }) async {
    final db = await database;
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

  /// 刪除最舊的關鍵詞塊
  static Future<void> deleteOldestContextKeyword(String characterId) async {
    final db = await database;
    final oldest = await db.query(
      'context_keywords',
      where: 'character_id = ?',
      whereArgs: [characterId],
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

  /// 清空角色的全部摘要和關鍵詞（角色刪除時用）
  static Future<void> clearContextData(String characterId) async {
    final db = await database;
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
  }

  static Future<List<Map<String, dynamic>>> getSpiderWebLinks(
    String characterId, {
    bool includeRejected = false,
  }) async {
    final db = await database;
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

  /// 建立一條經角色、active 狀態與自環檢查的蛛網連線。
  static Future<bool> insertSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) async {
    return upsertSpiderWebRelation(
      characterId,
      firstMemoryId,
      secondMemoryId,
      relationType: 'related',
      strength: 1,
      status: 'confirmed',
      source: 'model',
      reason: '',
    );
  }

  /// Inserts or updates one explainable relation without allowing a scanner
  /// to overwrite a user's confirmed or rejected decision.
  static Future<bool> upsertSpiderWebRelation(
    String characterId,
    int firstMemoryId,
    int secondMemoryId, {
    required String relationType,
    required double strength,
    required String status,
    required String source,
    required String reason,
  }) async {
    if (firstMemoryId == secondMemoryId) return false;
    final db = await database;
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
      if (valid.length != 2) return false;
      final existing = await txn.query(
        'spider_web_links',
        where: 'character_id = ? AND memory_id_1 = ? AND memory_id_2 = ?',
        whereArgs: [characterId, first, second],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final currentStatus =
            existing.first['status']?.toString() ?? 'confirmed';
        if (safeStatus == 'suggested' &&
            (currentStatus == 'confirmed' || currentStatus == 'rejected')) {
          return false;
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
          whereArgs: [existing.first['id']],
        );
        return changed == 1;
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
      return inserted > 0;
    });
  }

  static Future<bool> resolveSpiderWebRelation(
    String characterId,
    int relationId, {
    required bool confirmed,
  }) async {
    final db = await database;
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

  /// Removes one graph edge without touching either memory. Both endpoints
  /// are normalized exactly like insertion, and character scope is mandatory.
  static Future<bool> deleteSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) async {
    if (firstMemoryId == secondMemoryId) return false;
    final db = await database;
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
