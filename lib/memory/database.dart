// ignore_for_file: unnecessary_string_escapes

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/memory.dart';
import '../models/context_mode.dart';
import '../models/chat_diagnostic_event.dart';
import '../utils/app_file_safety.dart';
import '../utils/iso_week.dart';
import '../services/memory_debug_log.dart';

part 'database_schema.dart';
part 'database_memory_search.dart';

enum WebSearchUsageReservationResult {
  reserved,
  duplicateTurn,
  dailyLimitExceeded,
}

/// Result of writing one relation kind between a pair of memories.
///
/// The pair may have multiple relation kinds, but a given relation kind is
/// unique for that pair. Keeping this result explicit prevents a relation
/// update from being reported as a newly-created edge.
enum SpiderWebRelationWriteResult {
  invalid,
  inserted,
  updated,
  unchanged,
  protected,
}

typedef ConversationCoinSnapshot = ({int characterCoins, int userCoins});

/// 本地數據庫
class DatabaseHelper {
  static Database? _database;
  static Future<Database>? _dbInitFuture;
  static Future<Database> Function() _databaseInitializer = _initDatabase;
  static const String _dbName = 'yanci.db';
  static const int _dbVersion = 77;
  static const String _keepAlivePingGuardTable = 'keepalive_ping_guard';
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
    // Resolve the established mobile database directory before selecting the
    // bundled FFI engine. This preserves the existing yanci.db in-place while
    // guaranteeing an SQLite build compiled with FTS5 on Android/iOS.
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    await _removeLegacyMemoryFtsBeforeBundledOpen(path);
    sqfliteFfiInit();
    return await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: (db) async {
          await _DatabaseSchema._ensureRuntimeSchema(db);
          await _deduplicateAllStoredSelfNotes(db);
        },
      ),
    );
  }

  /// The pre-v66 Android database may contain an FTS4 virtual table created by
  /// the platform SQLite engine. The bundled engine intentionally ships FTS5
  /// only, so it cannot invoke FTS4's module destructor to drop that table.
  /// Let the same platform engine remove this derived index before reopening
  /// the database with bundled SQLite. The authoritative `memories` rows stay
  /// untouched and v66 rebuilds the index as FTS5 trigram immediately after.
  static Future<void> _removeLegacyMemoryFtsBeforeBundledOpen(
    String path,
  ) async {
    if (!await File(path).exists()) return;

    Database? platformDb;
    try {
      platformDb = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final version = await platformDb.getVersion();
      if (version >= _dbVersion) return;

      final rows = await platformDb.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        const <Object?>['memories_fts'],
      );
      if (rows.isEmpty) return;
      final sql = (rows.first['sql']?.toString() ?? '').toLowerCase();
      final alreadyTrigram =
          sql.contains('using fts5') && sql.contains('trigram');
      if (alreadyTrigram) return;

      await platformDb.transaction((txn) async {
        for (final name in const <String>[
          'memories_fts_ai',
          'memories_fts_au_deactivate',
          'memories_fts_au_activate',
          'memories_fts_au_content',
          'memories_fts_ad',
        ]) {
          await txn.execute('DROP TRIGGER IF EXISTS $name');
        }
        await txn.execute('DROP TABLE IF EXISTS memories_fts');
      });
      debugPrint(
        'Removed legacy memory FTS before bundled FTS5 trigram migration.',
      );
    } finally {
      await platformDb?.close();
    }
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

  @visibleForTesting
  static Future<void> ensureRuntimeSchemaForTesting(Database db) {
    return _DatabaseSchema._ensureRuntimeSchema(db);
  }

  /// 跨 isolate 的保活請求閘門。
  ///
  /// SharedPreferences 在主 isolate、WorkManager 和前台服務之間沒有原子
  /// compare-and-set；三個執行者可能同時讀到同一個舊錨點。這個小表只保存
  /// 裝置本地的瞬時鎖，不屬於 appTables 的可攜式 JSON 資料。
  static Future<bool> tryClaimKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime now,
    Duration claimFor = const Duration(minutes: 10),
  }) async {
    final db = await database;
    final nowUtc = now.toUtc();
    final claimUntil = nowUtc.add(claimFor).toIso8601String();

    return db.transaction<bool>((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          conversation_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          lease_token TEXT NOT NULL,
          next_allowed_at TEXT NOT NULL,
          in_flight_until TEXT
        )
      ''');

      final rows = await txn.query(
        _keepAlivePingGuardTable,
        where: 'id = 1',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.first;
        if (row['conversation_id'] != conversationId ||
            row['character_id'] != characterId ||
            row['lease_token'] != leaseToken) {
          // 舊 isolate 不能覆蓋新窗口的 guard。
          return false;
        }

        final inFlightUntil = DateTime.tryParse(
          row['in_flight_until']?.toString() ?? '',
        );
        final nextAllowedAt = DateTime.tryParse(
          row['next_allowed_at']?.toString() ?? '',
        );
        if (inFlightUntil != null && inFlightUntil.isAfter(nowUtc)) {
          return false;
        }
        if (nextAllowedAt != null && nextAllowedAt.isAfter(nowUtc)) {
          return false;
        }
      }

      final values = <String, Object?>{
        'id': 1,
        'conversation_id': conversationId,
        'character_id': characterId,
        'lease_token': leaseToken,
        'next_allowed_at': nowUtc.toIso8601String(),
        'in_flight_until': claimUntil,
      };
      if (rows.isEmpty) {
        await txn.insert(_keepAlivePingGuardTable, values);
      } else {
        final changed = await txn.update(
          _keepAlivePingGuardTable,
          {'in_flight_until': claimUntil},
          where: 'id = 1 AND lease_token = ?',
          whereArgs: [leaseToken],
        );
        if (changed != 1) return false;
      }
      return true;
    });
  }

  /// 將成功的保活請求寫成跨 isolate 可見的下一次允許時間。
  static Future<bool> completeKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime completedAt,
    Duration cooldown = const Duration(minutes: 50),
  }) async {
    final db = await database;
    final nextAllowedAt = completedAt.toUtc().add(cooldown).toIso8601String();
    return db.transaction<bool>((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          conversation_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          lease_token TEXT NOT NULL,
          next_allowed_at TEXT NOT NULL,
          in_flight_until TEXT
        )
      ''');
      final changed = await txn.update(
        _keepAlivePingGuardTable,
        {'next_allowed_at': nextAllowedAt, 'in_flight_until': null},
        where: '''
          id = 1 AND conversation_id = ? AND character_id = ? AND lease_token = ?
        ''',
        whereArgs: [conversationId, characterId, leaseToken],
      );
      return changed == 1;
    });
  }

  /// 請求失敗或租約失效時釋放 in-flight claim，讓下一個合法執行者可重試。
  static Future<void> releaseKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime releasedAt,
  }) async {
    final db = await database;
    await db.transaction<void>((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          conversation_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          lease_token TEXT NOT NULL,
          next_allowed_at TEXT NOT NULL,
          in_flight_until TEXT
        )
      ''');
      await txn.update(
        _keepAlivePingGuardTable,
        {
          'next_allowed_at': releasedAt.toUtc().toIso8601String(),
          'in_flight_until': null,
        },
        where: '''
          id = 1 AND conversation_id = ? AND character_id = ? AND lease_token = ?
        ''',
        whereArgs: [conversationId, characterId, leaseToken],
      );
    });
  }

  /// 新租約落地後清掉前一窗口的瞬時 guard。
  static Future<void> resetKeepAlivePingGuard({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime now,
  }) async {
    final db = await database;
    await db.transaction<void>((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          conversation_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          lease_token TEXT NOT NULL,
          next_allowed_at TEXT NOT NULL,
          in_flight_until TEXT
        )
      ''');
      await txn.insert(_keepAlivePingGuardTable, {
        'id': 1,
        'conversation_id': conversationId,
        'character_id': characterId,
        'lease_token': leaseToken,
        'next_allowed_at': now.toUtc().toIso8601String(),
        'in_flight_until': null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @visibleForTesting
  static double bm25FromFts4MatchInfoForTesting(Uint8List matchInfo) =>
      _MemorySearch.bm25FromMatchInfoForTesting(matchInfo);

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
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        source_window_id TEXT DEFAULT '',
        source_conversation_id TEXT DEFAULT '',
        display_anchor_message_id INTEGER,
        parent_summary_id INTEGER,
        replaces_summary_id INTEGER,
        source_message_start_id INTEGER,
        source_message_end_id INTEGER,
        source_span_status TEXT NOT NULL DEFAULT 'unknown'
          CHECK(source_span_status IN ('exact', 'unknown')),
        revision INTEGER NOT NULL DEFAULT 1,
        revision_status TEXT NOT NULL DEFAULT 'valid'
          CHECK(revision_status IN ('valid', 'invalidated')),
        invalidated_at TEXT,
        invalidation_reason TEXT NOT NULL DEFAULT '',
        story_time_text TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        locked INTEGER DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // 關鍵詞層（舊摘要提煉，上限 900 tokens）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_keywords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
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

  static Future<void> _createCharacterSignatureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_signatures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        phase TEXT NOT NULL CHECK(phase IN ('opening', 'closing')),
        signature TEXT NOT NULL,
        is_selected INTEGER NOT NULL DEFAULT 0 CHECK(is_selected IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(conversation_id, phase),
        FOREIGN KEY(character_id) REFERENCES characters(id) ON DELETE CASCADE,
        FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    await _safeAddColumn(
      db,
      'character_signatures',
      'is_selected',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_character_signature_history '
      'ON character_signatures(character_id, created_at DESC)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_character_signature_selected '
      'ON character_signatures(character_id) WHERE is_selected = 1',
    );
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
    String scope = 'current',
    ContextMode currentMode = ContextMode.daily,
    int limit = 5,
  }) async {
    final db = await database;
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
      ..add(_likeContains(keyword))
      ..add(_likeContains(keyword));
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

  /// Returns the distinct local dates on which the user spoke to this
  /// character in the requested lane. One or many messages on the same date
  /// still count as one active day. Dates with no user message never appear,
  /// so time spent away from the app cannot age memories.
  static Future<Set<String>> getCharacterActiveDateKeys(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
  }) async {
    final db = await database;
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

  /// 刪除一條角色自我註記；不改動任何 conversation 的靜態註記快照。
  static Future<bool> deleteSelfNote(String characterId, String note) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
        limit: 1,
      );
      if (rows.isEmpty) return false;

      final stored = (rows.first['self_notes'] as String?) ?? '';
      final lines = _selfNoteLines(stored).toList();
      final target = _cleanSelfNote(note);
      final index = lines.indexOf(target);
      if (index < 0) return false;
      lines.removeAt(index);
      await txn.update(
        'characters',
        {'self_notes': _formatSelfNotes(lines)},
        where: 'id = ?',
        whereArgs: [characterId],
      );
      return true;
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

  /// Runtime-generated signatures must not reorder the character carousel.
  static Future<void> updateCharacterSignature(
    String id,
    String signature,
  ) async {
    final db = await database;
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
          columns: ['image_path', 'image_paths_json'],
          where: 'conversation_id = ?',
          whereArgs: [cid],
        );
        files.addAll(images.expand(_imagePathsFromRow));
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

  // ═══════════════════════════════════
  // 對話操作（帶角色過濾）
  // ═══════════════════════════════════

  static Future<void> createConversation(Conversation conv) async {
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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

  /// Rebinds a newly-created, still-empty RP window to another storyline.
  /// Once any message exists, the immutable window identity is left untouched.
  static Future<bool> rebindEmptyRpConversation({
    required String conversationId,
    required String characterId,
    required String storylineId,
    required String userPersonaId,
    required String userPersonaSnapshot,
  }) async {
    final db = await database;
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

  /// Returns the last two complete user/assistant turns from the immediately
  /// preceding non-empty window in the same character, mode and story line.
  /// These messages are prompt-only bridge context and are never copied into
  /// the current conversation.
  static Future<List<Message>> getPreviousConversationTurns({
    required String currentConversationId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    int turnCount = 2,
  }) async {
    final db = await database;
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

  /// 從按時間正序的消息中取得最後 N 組完整 user→assistant 回合。
  /// 續接內容不從半個回合或連續同角色消息開始，避免模型誤判接棒點。
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

  /// 新窗口可續接的同模式來源窗口。候選依最後一條消息時間排序；
  /// 每個候選只攜帶最後四條正文與最後兩條摘要。
  static Future<List<RpChapterContinuationSource>>
  getRpChapterContinuationSources({
    required String currentConversationId,
    required String characterId,
    required String continuityId,
    ContextMode contextMode = ContextMode.rp,
    int limit = 20,
  }) async {
    final db = await database;
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

  /// Resolves the exact source persisted by a continuation action. Unlike the
  /// picker query this is not limited to the most recent windows, so reopening
  /// an older manually selected continuation cannot silently switch sources.
  static Future<RpChapterContinuationSource?> getRpChapterContinuationSource({
    required String sourceConversationId,
    required String currentConversationId,
    required String characterId,
    required String continuityId,
    ContextMode contextMode = ContextMode.rp,
    int? throughMessageId,
    DateTime? summariesThrough,
  }) async {
    final db = await database;
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
    final db = await database;
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
      // 多取一些再組成兩個完整回合，避免最後四條剛好含連續同角色消息。
      limit: 12,
    );
    final messageCandidates = messageRows
        .map(Message.fromMap)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    final completeTurns = _latestCompleteConversationTurns(
      messageCandidates,
      2,
    );
    // 很短的新章可能尚未形成完整回合；仍允許續接唯一已有的內容。
    final messages = completeTurns.isNotEmpty
        ? completeTurns
        : messageCandidates
              .skip(max(0, messageCandidates.length - 4))
              .toList(growable: false);
    if (messages.isEmpty) return null;
    final summaryRows = await db.query(
      'context_summaries',
      columns: const <String>['content'],
      where:
          'source_conversation_id = ? AND context_mode = ? '
          "AND continuity_id = ? AND revision_status = 'valid' "
          '${summariesThrough == null ? '' : 'AND created_at <= ?'}',
      whereArgs: <Object?>[
        conversation.id,
        contextMode.storageValue,
        continuityId,
        ?summariesThrough?.toIso8601String(),
      ],
      orderBy: 'created_at DESC, id DESC',
      limit: 2,
    );
    final summaries = summaryRows
        .map((item) => item['content']?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false)
        .reversed
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

  /// 搜索對話（窗口標題或窗口內任一消息模糊匹配）。
  ///
  /// 使用 EXISTS 而不是 JOIN，避免同一窗口命中多條消息時在歷史列表重複
  /// 出現；也不限制消息時間，因此早期窗口仍能被跨窗口關鍵詞找回。
  static Future<List<Conversation>> searchConversations(
    String query, {
    String? characterId,
  }) async {
    final db = await database;
    final pattern = _likeContains(query);
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

  /// Returns the shell-balance baseline frozen for this conversation window.
  /// A null value means this window has not built its static prompt yet.
  static Future<ConversationCoinSnapshot?> getConversationPinnedCoinSnapshot(
    String id,
  ) async {
    final db = await database;
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

  /// Atomically freezes the first shell-balance baseline for a conversation.
  /// Later grants, transfers and scratch-card results are request-only deltas.
  static Future<ConversationCoinSnapshot>
  setConversationPinnedCoinSnapshotIfAbsent(
    String id, {
    required int characterCoins,
    required int userCoins,
  }) async {
    if (characterCoins < 0 || userCoins < 0) {
      throw ArgumentError('Coin snapshots must be non-negative');
    }
    final db = await database;
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
        columns: ['image_path', 'image_paths_json'],
        where: 'conversation_id = ?',
        whereArgs: [id],
      );
      final files = <String>{
        ...voices.map((row) => row['file_path']).whereType<String>(),
        ...images.expand(_imagePathsFromRow),
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

  static Future<int?> getLatestMessageId(String conversationId) async {
    final db = await database;
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

  /// Message anchors whose automatic rolling summary has been persisted.
  ///
  /// This UI-only metadata stays on a visible message so it follows backup,
  /// restore, branching, and deletion without ever entering prompt history.
  static Future<Set<int>> getSummaryRecordedMessageIds(
    String conversationId,
  ) async {
    return (await getSummaryRecordedAnchors(conversationId)).keys.toSet();
  }

  /// UI anchors mapped to the exact automatic summary they open.
  ///
  /// New summaries persist this relation directly. For pre-v67 rows, retain a
  /// single best-effort shortcut for the latest automatic summary instead of
  /// losing the entry point entirely.
  static Future<Map<int, int>> getSummaryRecordedAnchors(
    String conversationId,
  ) async {
    final db = await database;
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

  /// Latest display page ending at the immutable RP handoff message.
  static Future<List<Message>> getMessagesUpToId(
    String conversationId,
    int throughMessageId, {
    int limit = 50,
  }) async {
    final db = await database;
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
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['count'] as int;
  }

  /// Approximate source volume for one RP storyline without loading its full
  /// dialogue into Dart. Character count is sufficient for choosing a soft
  /// dossier ceiling; exact request tokens are still measured at send time.
  static Future<int> getRpStorylineSourceCharacterCount({
    required String characterId,
    required String continuityId,
  }) async {
    final db = await database;
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

  static Future<void> deleteMessageById(
    int id, {
    String reason = 'delete',
  }) async {
    final db = await database;
    final imagePaths = await db.transaction<List<String>>((txn) async {
      final rows = await txn.query(
        'messages',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return const <String>[];
      final row = rows.single;
      await _archiveMessageRevision(txn, row, reason: reason);
      await _invalidateSummaryChainForMessage(
        txn,
        conversationId: row['conversation_id'] as String,
        messageId: id,
        reason: reason,
      );
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      return rows.expand(_imagePathsFromRow).toSet().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  static Future<void> deleteMessageByFingerprint(
    Message msg, {
    String reason = 'delete',
  }) async {
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
      final rows = await txn.query('messages', where: where, whereArgs: args);
      for (final row in rows) {
        final messageId = row['id'] as int?;
        final conversationId = row['conversation_id'] as String?;
        if (messageId == null || conversationId == null) continue;
        await _archiveMessageRevision(txn, row, reason: reason);
        await _invalidateSummaryChainForMessage(
          txn,
          conversationId: conversationId,
          messageId: messageId,
          reason: reason,
        );
      }
      await txn.delete('messages', where: where, whereArgs: args);
      return rows.expand(_imagePathsFromRow).toSet().toList();
    });
    await AppFileSafety.deleteOwnedFiles(imagePaths);
  }

  static Iterable<String> _imagePathsFromRow(Map<String, Object?> row) sync* {
    final paths = <String>{};
    final legacy = row['image_path'];
    if (legacy is String && legacy.trim().isNotEmpty) {
      paths.add(legacy.trim());
    }
    final encoded = row['image_paths_json'];
    if (encoded is String && encoded.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is String && value.trim().isNotEmpty) {
              paths.add(value.trim());
            }
          }
        }
      } catch (_) {
        // A legacy or damaged row is still covered by image_path above.
      }
    }
    yield* paths;
  }

  static Future<Message?> getMessageById(int id) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromMap(rows.first);
  }

  /// Confirms that every source message still exists at the same revision.
  /// Summary/model calls run outside SQLite transactions; this check prevents
  /// an edit or re-roll that happens during the call from persisting a stale
  /// result after the invalidation transaction has already finished.
  static Future<bool> messageSnapshotsStillCurrent(
    Iterable<Message> snapshots,
  ) async {
    final expected = <int, int>{};
    for (final message in snapshots) {
      final id = message.id;
      if (id != null) expected[id] = message.revision;
    }
    if (expected.isEmpty) return true;
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
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
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      'chat_diagnostics',
      where:
          'source_message_id IN ($placeholders) OR '
          'anchor_message_id IN ($placeholders)',
      whereArgs: <Object?>[...ids, ...ids],
    );
  }

  /// 覆蓋消息文本（不刪除原記錄）
  static Future<void> updateMessageText(int id, String newText) async {
    final db = await database;
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
      await _archiveMessageRevision(txn, row, reason: 'edit');
      await _invalidateSummaryChainForMessage(
        txn,
        conversationId: row['conversation_id'] as String,
        messageId: id,
        reason: 'edit',
      );
      await txn.rawUpdate(
        'UPDATE messages SET text = ?, revision = revision + 1, '
        'summary_recorded = 0 WHERE id = ?',
        <Object?>[newText, id],
      );
    });
  }

  static Future<void> _archiveMessageRevision(
    DatabaseExecutor db,
    Map<String, Object?> row, {
    required String reason,
  }) async {
    final messageId = row['id'] as int?;
    final conversationId = row['conversation_id'] as String?;
    if (messageId == null || conversationId == null) return;
    await db.insert('message_revisions', <String, Object?>{
      'message_id': messageId,
      'conversation_id': conversationId,
      'revision': row['revision'] as int? ?? 1,
      'snapshot_json': jsonEncode(row),
      'archive_reason': reason,
      'archived_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Invalidates the first summary that consumed [messageId] and every later
  /// summary derived from it. Invalid rows stay in SQLite for audit and repair,
  /// but disappear from injection, labels and user-facing summary lookup.
  static Future<void> _invalidateSummaryChainForMessage(
    DatabaseExecutor db, {
    required String conversationId,
    required int messageId,
    required String reason,
  }) async {
    final roots = await db.rawQuery(
      '''
      SELECT id
      FROM context_summaries
      WHERE source_conversation_id = ?
        AND revision_status = 'valid'
        AND (
          (
            source_message_start_id IS NOT NULL
            AND source_message_end_id IS NOT NULL
            AND ? BETWEEN source_message_start_id AND source_message_end_id
          )
          OR (
            source_message_start_id IS NULL
            AND source_message_end_id IS NULL
            AND (
              display_anchor_message_id IS NULL
              OR display_anchor_message_id >= ?
            )
          )
        )
      ''',
      <Object?>[conversationId, messageId, messageId],
    );
    final invalidIds = roots
        .map((row) => row['id'] as int?)
        .whereType<int>()
        .toSet();
    if (invalidIds.isEmpty) return;

    var frontier = invalidIds.toList(growable: false);
    while (frontier.isNotEmpty) {
      final placeholders = List.filled(frontier.length, '?').join(',');
      final children = await db.rawQuery(
        'SELECT id FROM context_summaries '
        "WHERE revision_status = 'valid' "
        'AND parent_summary_id IN ($placeholders)',
        <Object?>[...frontier],
      );
      final next = children
          .map((row) => row['id'] as int?)
          .whereType<int>()
          .where(invalidIds.add)
          .toList(growable: false);
      frontier = next;
    }

    final placeholders = List.filled(invalidIds.length, '?').join(',');
    final affected = await db.rawQuery(
      'SELECT id, character_id, context_mode, continuity_id, '
      'source_conversation_id, display_anchor_message_id, '
      'source_message_start_id, source_message_end_id '
      'FROM context_summaries WHERE id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    final now = DateTime.now().toIso8601String();
    await db.rawUpdate(
      'UPDATE context_summaries SET revision_status = ?, invalidated_at = ?, '
      'invalidation_reason = ? WHERE id IN ($placeholders)',
      <Object?>['invalidated', now, reason, ...invalidIds],
    );
    // Queue exact source spans before removing any derived projections. Model
    // work happens later, outside this transaction. Legacy/manual summaries
    // without a reproducible message span stay invalidated and can still be
    // repaired manually; guessing a span here would risk importing unrelated
    // dialogue into the replacement chain.
    for (final summary in affected) {
      final originalSummaryId = summary['id'] as int?;
      final characterId = summary['character_id']?.toString().trim() ?? '';
      final sourceConversationId =
          summary['source_conversation_id']?.toString().trim() ?? '';
      final sourceStart = summary['source_message_start_id'] as int?;
      final sourceEnd = summary['source_message_end_id'] as int?;
      if (originalSummaryId == null ||
          characterId.isEmpty ||
          sourceConversationId.isEmpty ||
          sourceStart == null ||
          sourceEnd == null) {
        continue;
      }
      await db.insert('context_summary_repairs', <String, Object?>{
        'original_summary_id': originalSummaryId,
        'character_id': characterId,
        'context_mode': summary['context_mode']?.toString() ?? 'daily',
        'continuity_id': summary['continuity_id']?.toString() ?? 'main',
        'source_conversation_id': sourceConversationId,
        'source_message_start_id': sourceStart,
        'source_message_end_id': sourceEnd,
        'status': 'pending',
        'attempts': 0,
        'last_error': '',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.rawDelete(
      'DELETE FROM context_keywords WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    // RP mutable state is a projection of one summary revision. Once that
    // revision is invalid, keeping its machine-written state would leak a
    // ghost injury, promise, identity or scene into the next reply. User edits
    // remain authoritative and are never removed by automatic rollback.
    await db.rawDelete(
      'DELETE FROM rp_story_states '
      'WHERE user_edited = 0 AND source_summary_id IN ($placeholders)',
      <Object?>[...invalidIds],
    );
    await _rollbackInvalidatedRpStoryProjections(
      db,
      invalidSummaryIds: invalidIds,
    );
    await _deleteInvalidatedRpTimelineProjection(
      db,
      affectedSummaries: affected,
      editedConversationId: conversationId,
      editedMessageId: messageId,
    );

    final anchorsByConversation = <String, Set<int>>{};
    for (final row in affected) {
      final sourceConversationId =
          row['source_conversation_id']?.toString().trim() ?? '';
      final anchor = row['display_anchor_message_id'] as int?;
      if (sourceConversationId.isEmpty || anchor == null) continue;
      anchorsByConversation
          .putIfAbsent(sourceConversationId, () => <int>{})
          .add(anchor);
    }
    for (final entry in anchorsByConversation.entries) {
      final anchorPlaceholders = List.filled(entry.value.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE messages SET summary_recorded = 0 '
        'WHERE conversation_id = ? AND id IN ($anchorPlaceholders)',
        <Object?>[entry.key, ...entry.value],
      );
    }

    final affectedConversations = <String>{conversationId};
    affectedConversations.addAll(anchorsByConversation.keys);
    for (final sourceConversationId in affectedConversations) {
      final cursorRows = await db.rawQuery(
        'SELECT COALESCE(MAX(COALESCE(source_message_end_id, '
        'display_anchor_message_id, 0)), 0) AS cursor '
        'FROM context_summaries '
        "WHERE source_conversation_id = ? AND revision_status = 'valid'",
        <Object?>[sourceConversationId],
      );
      final cursor = cursorRows.single['cursor'] as int? ?? 0;
      await db.update(
        'conversations',
        <String, Object?>{'summary_cursor_message_id': cursor},
        where: 'id = ?',
        whereArgs: <Object?>[sourceConversationId],
      );
    }
  }

  static Future<void> _rollbackInvalidatedRpStoryProjections(
    DatabaseExecutor db, {
    required Set<int> invalidSummaryIds,
  }) async {
    if (invalidSummaryIds.isEmpty) return;
    final placeholders = List.filled(invalidSummaryIds.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM rp_story_relationship_events '
      'WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidSummaryIds],
    );
    final revisions = await db.rawQuery(
      'SELECT * FROM rp_story_projection_revisions '
      'WHERE source_summary_id IN ($placeholders) ORDER BY id DESC',
      <Object?>[...invalidSummaryIds],
    );
    for (final revision in revisions) {
      final kind = revision['projection_table']?.toString() ?? '';
      final projectionId = revision['projection_id']?.toString() ?? '';
      final table = switch (kind) {
        'character' => 'rp_story_characters',
        'relationship' => 'rp_story_relationships',
        _ => '',
      };
      if (table.isEmpty || projectionId.isEmpty) continue;
      final current = await db.query(
        table,
        where: 'id = ?',
        whereArgs: <Object?>[projectionId],
        limit: 1,
      );
      if (current.isNotEmpty && current.first['user_edited'] == 1) continue;

      if (revision['operation'] == 'create') {
        if (kind == 'relationship') {
          await db.delete(
            'rp_story_relationship_events',
            where: 'relationship_id = ?',
            whereArgs: <Object?>[projectionId],
          );
        } else if (current.isNotEmpty) {
          await db.delete(
            'rp_story_entity_aliases',
            where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
            whereArgs: <Object?>[
              current.first['character_id'],
              current.first['continuity_id'],
              current.first['entity_key'],
            ],
          );
        }
        await db.delete(
          table,
          where: 'id = ?',
          whereArgs: <Object?>[projectionId],
        );
        continue;
      }

      final rawSnapshot = revision['snapshot_json']?.toString() ?? '';
      try {
        final decoded = jsonDecode(rawSnapshot);
        if (decoded is! Map) continue;
        final snapshot = <String, Object?>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
        if (current.isEmpty) {
          await db.insert(table, snapshot);
        } else {
          await db.update(
            table,
            snapshot,
            where: 'id = ?',
            whereArgs: <Object?>[projectionId],
          );
        }
        if (kind == 'character') {
          await _restoreRpStoryCharacterAliases(db, snapshot);
        }
      } catch (_) {
        // A damaged audit snapshot must not replace the current projection.
      }
    }
    await db.rawDelete(
      'DELETE FROM rp_story_projection_revisions '
      'WHERE source_summary_id IN ($placeholders)',
      <Object?>[...invalidSummaryIds],
    );
  }

  static Future<void> _restoreRpStoryCharacterAliases(
    DatabaseExecutor db,
    Map<String, Object?> character,
  ) async {
    final characterId = character['character_id']?.toString() ?? '';
    final continuityId = character['continuity_id']?.toString() ?? '';
    final entityKey = character['entity_key']?.toString() ?? '';
    if (characterId.isEmpty || continuityId.isEmpty || entityKey.isEmpty) {
      return;
    }
    await db.delete(
      'rp_story_entity_aliases',
      where: 'character_id = ? AND continuity_id = ? AND entity_key = ?',
      whereArgs: <Object?>[characterId, continuityId, entityKey],
    );
    final name = character['name']?.toString().trim() ?? '';
    final aliases = <String>{if (name.isNotEmpty) name};
    try {
      final decoded = jsonDecode(character['aliases_json']?.toString() ?? '');
      if (decoded is List) {
        aliases.addAll(
          decoded
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty),
        );
      }
    } catch (_) {
      // The stable name still restores the minimum safe alias map.
    }
    final createdAt =
        character['created_at']?.toString() ?? DateTime.now().toIso8601String();
    final updatedAt =
        character['updated_at']?.toString() ?? DateTime.now().toIso8601String();
    for (final alias in aliases) {
      final normalized = alias.toLowerCase().replaceAll(
        RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
        '',
      );
      if (normalized.isEmpty) continue;
      await db.insert('rp_story_entity_aliases', <String, Object?>{
        'character_id': characterId,
        'continuity_id': continuityId,
        'entity_key': entityKey,
        'normalized_alias': normalized,
        'display_alias': alias,
        'alias_type': alias == name ? 'name' : 'identity',
        'created_at': createdAt,
        'updated_at': updatedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Removes RP timeline rows sourced from an invalidated summary chain.
  ///
  /// Timeline rows predate source_summary_id, so the covered message ranges
  /// are the authoritative bridge. This intentionally fails closed: the
  /// replacement summary will recreate valid events, while stale events must
  /// not remain available for recall between edit/re-roll and regeneration.
  static Future<void> _deleteInvalidatedRpTimelineProjection(
    DatabaseExecutor db, {
    required List<Map<String, Object?>> affectedSummaries,
    required String editedConversationId,
    required int editedMessageId,
  }) async {
    final messageIdsByConversation = <String, Set<int>>{
      editedConversationId: <int>{editedMessageId},
    };
    for (final summary in affectedSummaries) {
      final sourceConversationId =
          summary['source_conversation_id']?.toString().trim() ?? '';
      if (sourceConversationId.isEmpty) continue;
      final ids = messageIdsByConversation.putIfAbsent(
        sourceConversationId,
        () => <int>{},
      );
      final start = summary['source_message_start_id'] as int?;
      final end = summary['source_message_end_id'] as int?;
      if (start != null && end != null) {
        final rows = await db.query(
          'messages',
          columns: const <String>['id'],
          where: 'conversation_id = ? AND id BETWEEN ? AND ?',
          whereArgs: <Object?>[sourceConversationId, start, end],
        );
        ids.addAll(rows.map((row) => row['id']).whereType<int>());
      } else {
        final anchor = summary['display_anchor_message_id'] as int?;
        if (anchor != null) ids.add(anchor);
      }
    }

    for (final entry in messageIdsByConversation.entries) {
      if (entry.value.isEmpty) continue;
      final rows = await db.query(
        'rp_character_timeline',
        columns: const <String>[
          'id',
          'source_message_id',
          'source_message_ids',
        ],
        where: 'source_conversation_id = ?',
        whereArgs: <Object?>[entry.key],
      );
      final staleIds = <int>[];
      for (final row in rows) {
        final sourceIds = <int>{};
        final primary = row['source_message_id'] as int?;
        if (primary != null) sourceIds.add(primary);
        final encoded = row['source_message_ids']?.toString() ?? '';
        if (encoded.isNotEmpty) {
          try {
            final decoded = jsonDecode(encoded);
            if (decoded is List) {
              sourceIds.addAll(decoded.whereType<int>());
            }
          } catch (_) {
            // The legacy primary id still provides a safe fallback.
          }
        }
        if (sourceIds.any(entry.value.contains)) {
          final id = row['id'] as int?;
          if (id != null) staleIds.add(id);
        }
      }
      if (staleIds.isEmpty) continue;
      final stalePlaceholders = List.filled(staleIds.length, '?').join(',');
      await db.rawDelete(
        'DELETE FROM rp_character_timeline '
        'WHERE id IN ($stalePlaceholders)',
        <Object?>[...staleIds],
      );
    }
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

  /// Rebuilds the derived full-text memory index after restore or repair.
  static Future<void> rebuildMemoryFts() => _MemorySearch.rebuildIndex();

  /// Ensures same-version additions and derived indexes exist before export.
  static Future<void> ensureAllSchemaTables() =>
      _MemorySearch.ensureRuntimeSchema();

  /// Searches active memories using platform FTS plus bounded text fallback.
  static Future<List<Memory>> searchMemoriesByText(
    String query, {
    required String mode,
    String characterId = 'default',
    int limit = 20,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _MemorySearch.search(
    query,
    mode: mode,
    characterId: characterId,
    limit: limit,
    contextMode: contextMode,
    continuityId: continuityId,
  );

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
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
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

  /// 取得角色所有模式下的 active 記憶。蛛網分層必須從完整集合規劃，否則
  /// 舊連線的另一端若在不同模式，畫面會誤以為邊不存在。
  static Future<List<Memory>> getAllActiveMemories({
    String characterId = 'default',
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await database;
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
    final db = await database;
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
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return const [];
    final db = await database;
    final pattern = _likeContains(normalized);
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
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await database;
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

  /// 歸檔記憶計數
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
    String requestKind = 'unknown',
    bool costKnown = false,
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
      'request_kind': requestKind,
      'cost_known': costKnown ? 1 : 0,
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
        SUM(CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END) as total_cost,
        SUM(CASE WHEN cost_known = 1 THEN 1 ELSE 0 END) as known_cost_requests,
        COUNT(*) as total_requests
      FROM usage_logs
      WHERE timestamp >= ? AND timestamp < ?
    ''',
      [from.toIso8601String(), to.toIso8601String()],
    );
    final result = rows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(rows.first);
    final searchRows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) AS total_requests,
        SUM(prompt_tokens) AS total_prompt,
        SUM(completion_tokens) AS total_completion,
        SUM(CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
          THEN actual_cost_usd ELSE 0 END) AS total_cost,
        SUM(CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
          THEN 1 ELSE 0 END) AS known_cost_requests
      FROM web_search_usage_logs
      WHERE launched_at >= ? AND launched_at < ?
        AND status NOT IN ('reserved', 'claimed', 'released')
      ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final search = searchRows.isEmpty
        ? const <String, Object?>{}
        : searchRows.first;
    int addInt(String key) =>
        ((result[key] as num?)?.toInt() ?? 0) +
        ((search[key] as num?)?.toInt() ?? 0);
    result['total_requests'] = addInt('total_requests');
    result['total_prompt'] = addInt('total_prompt');
    result['total_completion'] = addInt('total_completion');
    result['known_cost_requests'] = addInt('known_cost_requests');
    result['total_cost'] =
        ((result['total_cost'] as num?)?.toDouble() ?? 0) +
        ((search['total_cost'] as num?)?.toDouble() ?? 0);
    return result;
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
        date,
        SUM(prompt) AS prompt,
        SUM(completion) AS completion,
        SUM(cache_hit) AS cache_hit,
        SUM(cost) AS cost,
        SUM(known_cost_requests) AS known_cost_requests
      FROM (
        SELECT
          SUBSTR(timestamp, 1, 10) AS date,
          prompt_tokens AS prompt,
          completion_tokens AS completion,
          cache_hit_tokens AS cache_hit,
          CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END AS cost,
          CASE WHEN cost_known = 1 THEN 1 ELSE 0 END AS known_cost_requests
        FROM usage_logs
        WHERE timestamp >= ? AND timestamp < ?
        UNION ALL
        SELECT
          SUBSTR(launched_at, 1, 10) AS date,
          prompt_tokens AS prompt,
          completion_tokens AS completion,
          0 AS cache_hit,
          CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN actual_cost_usd ELSE 0 END AS cost,
          CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN 1 ELSE 0 END AS known_cost_requests
        FROM web_search_usage_logs
        WHERE launched_at >= ? AND launched_at < ?
          AND status NOT IN ('reserved', 'claimed', 'released')
      )
      GROUP BY date
      ORDER BY date
    ''',
      <Object?>[
        from.toIso8601String(),
        to.toIso8601String(),
        from.toIso8601String(),
        to.toIso8601String(),
      ],
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
        provider,
        model,
        SUM(total_tokens) AS total_tokens,
        SUM(cost) AS cost,
        SUM(known_cost_requests) AS known_cost_requests,
        SUM(requests) AS requests
      FROM (
        SELECT
          provider,
          model,
          prompt_tokens + completion_tokens AS total_tokens,
          CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END AS cost,
          CASE WHEN cost_known = 1 THEN 1 ELSE 0 END AS known_cost_requests,
          1 AS requests
        FROM usage_logs
        WHERE timestamp >= ? AND timestamp < ?
        UNION ALL
        SELECT
          provider,
          provider_model AS model,
          prompt_tokens + completion_tokens AS total_tokens,
          CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN actual_cost_usd ELSE 0 END AS cost,
          CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN 1 ELSE 0 END AS known_cost_requests,
          1 AS requests
        FROM web_search_usage_logs
        WHERE launched_at >= ? AND launched_at < ?
          AND status NOT IN ('reserved', 'claimed', 'released')
      )
      GROUP BY provider, model
      ORDER BY cost DESC, requests DESC
    ''',
      <Object?>[
        from.toIso8601String(),
        to.toIso8601String(),
        from.toIso8601String(),
        to.toIso8601String(),
      ],
    );
  }

  /// 按功能分類的 API 請求次數。即使供應商沒有回傳 Token 或費用，
  /// 成功完成的請求仍保留一筆，避免摘要與工具調用在用量頁消失。
  static Future<List<Map<String, dynamic>>> getUsageByRequestKind(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT request_kind, COUNT(*) AS requests
      FROM usage_logs
      WHERE timestamp >= ? AND timestamp < ?
      GROUP BY request_kind
      ORDER BY requests DESC, request_kind ASC
      ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final result = rows.map(Map<String, dynamic>.from).toList(growable: true);
    final searchRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS requests
      FROM web_search_usage_logs
      WHERE launched_at >= ? AND launched_at < ?
        AND status NOT IN ('reserved', 'claimed', 'released')
      ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final searchRequests = searchRows.isEmpty
        ? 0
        : (searchRows.first['requests'] as num?)?.toInt() ?? 0;
    if (searchRequests > 0) {
      result.add(<String, dynamic>{
        'request_kind': 'web_search',
        'requests': searchRequests,
      });
    }
    result.sort((left, right) {
      final byCount = ((right['requests'] as num?)?.toInt() ?? 0).compareTo(
        (left['requests'] as num?)?.toInt() ?? 0,
      );
      if (byCount != 0) return byCount;
      return '${left['request_kind']}'.compareTo('${right['request_kind']}');
    });
    return result;
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
    int? displayAnchorMessageId,
    int? sourceMessageStartId,
    int? sourceMessageEndId,
    int? replaceSummaryId,
    bool replaceInvalidatedSummary = false,
    String storyTimeText = '',
    List<Message> expectedSourceMessages = const <Message>[],
    bool allowPendingRepairs = false,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      if (!await _sourceMessagesMatch(
        txn,
        sourceConversationId,
        expectedSourceMessages,
      )) {
        return 0;
      }
      if (replaceSummaryId == null &&
          !allowPendingRepairs &&
          await _hasPendingSummaryRepairs(
            txn,
            characterId,
            contextMode,
            continuityId,
          )) {
        return 0;
      }
      Map<String, Object?>? replacement;
      int? parentId;
      if (replaceSummaryId != null) {
        final replacementRows = await txn.query(
          'context_summaries',
          where:
              'id = ? AND character_id = ? AND context_mode = ? '
              "AND continuity_id = ? AND revision_status = ? "
              'AND (? = 1 OR archived = 0)',
          whereArgs: <Object?>[
            replaceSummaryId,
            characterId,
            contextMode.storageValue,
            continuityId,
            replaceInvalidatedSummary ? 'invalidated' : 'valid',
            replaceInvalidatedSummary ? 1 : 0,
          ],
          limit: 1,
        );
        if (replacementRows.isEmpty) return 0;
        replacement = replacementRows.single;
        final targetConversation =
            replacement['source_conversation_id']?.toString() ?? '';
        if (targetConversation != sourceConversationId ||
            replacement['source_span_status']?.toString() != 'exact' ||
            sourceMessageStartId == null ||
            sourceMessageEndId == null ||
            replacement['source_message_start_id'] != sourceMessageStartId ||
            (!replaceInvalidatedSummary &&
                replacement['source_message_end_id'] != sourceMessageEndId)) {
          return 0;
        }
        final originalParentId = replacement['parent_summary_id'] as int?;
        parentId = originalParentId;
        if (replaceInvalidatedSummary && originalParentId != null) {
          final mappedParent = await txn.query(
            'context_summaries',
            columns: const <String>['id'],
            where:
                'replaces_summary_id = ? AND revision_status = ? '
                'AND character_id = ? AND context_mode = ? '
                'AND continuity_id = ?',
            whereArgs: <Object?>[
              originalParentId,
              'valid',
              characterId,
              contextMode.storageValue,
              continuityId,
            ],
            orderBy: 'revision DESC, id DESC',
            limit: 1,
          );
          if (mappedParent.isNotEmpty) {
            parentId = mappedParent.single['id'] as int?;
          } else {
            final stillValidParent = await txn.query(
              'context_summaries',
              columns: const <String>['id'],
              where: 'id = ? AND revision_status = ?',
              whereArgs: <Object?>[originalParentId, 'valid'],
              limit: 1,
            );
            if (stillValidParent.isEmpty) return 0;
          }
        }
        if (!replaceInvalidatedSummary) {
          await _invalidateSummaryChainForMessage(
            txn,
            conversationId: targetConversation,
            messageId: sourceMessageStartId,
            reason: 'summary_rewrite',
          );
        }
        await txn.update(
          'context_summary_repairs',
          <String, Object?>{
            'status': 'completed',
            'last_error': '',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'original_summary_id = ?',
          whereArgs: <Object?>[replaceSummaryId],
        );
      } else {
        parentId = await _latestValidSummaryId(
          txn,
          characterId: characterId,
          contextMode: contextMode,
          continuityId: continuityId,
        );
      }
      final createdAt =
          replacement?['created_at']?.toString() ??
          DateTime.now().toIso8601String();
      final displayAnchor = replacement?['display_anchor_message_id'] as int?;
      final id = await txn.insert('context_summaries', {
        'character_id': characterId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': sourceConversationId,
        'display_anchor_message_id': displayAnchor ?? displayAnchorMessageId,
        'parent_summary_id': parentId,
        'replaces_summary_id': replaceSummaryId,
        'source_message_start_id': sourceMessageStartId,
        'source_message_end_id': sourceMessageEndId,
        'source_span_status':
            sourceMessageStartId != null && sourceMessageEndId != null
            ? 'exact'
            : 'unknown',
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId,
        'story_time_text': storyTimeText,
        'content': content,
        'token_count': tokenCount,
        'revision': (replacement?['revision'] as int? ?? 0) + 1,
        'created_at': createdAt,
      });
      final anchor = displayAnchor ?? displayAnchorMessageId;
      if (anchor != null && sourceConversationId.isNotEmpty) {
        await txn.update(
          'messages',
          <String, Object?>{'summary_recorded': 1},
          where: 'id = ? AND conversation_id = ?',
          whereArgs: <Object?>[anchor, sourceConversationId],
        );
      }
      return id;
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
    int? displayAnchorMessageId,
    int? sourceMessageStartId,
    String storyTimeText = '',
    String sourceWindowId = '',
    List<Message> expectedSourceMessages = const <Message>[],
    bool allowPendingRepairs = false,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      if (!await _sourceMessagesMatch(
        txn,
        conversationId,
        expectedSourceMessages,
      )) {
        return 0;
      }
      if (!allowPendingRepairs) {
        if (await _hasPendingSummaryRepairs(
          txn,
          characterId,
          contextMode,
          continuityId,
        )) {
          return 0;
        }
      }
      final conversationRows = await txn.query(
        'conversations',
        columns: const <String>['summary_cursor_message_id'],
        where: 'id = ?',
        whereArgs: <Object?>[conversationId],
        limit: 1,
      );
      if (conversationRows.isEmpty) {
        throw StateError('Conversation $conversationId does not exist');
      }
      final previousCursor =
          conversationRows.first['summary_cursor_message_id'] as int? ?? 0;
      final resolvedStartId =
          sourceMessageStartId ??
          await _firstMessageIdInRange(
            txn,
            conversationId: conversationId,
            afterMessageId: previousCursor,
            throughMessageId: cursorMessageId,
          );
      final parentId = await _latestValidSummaryId(
        txn,
        characterId: characterId,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      final displayAnchorId = displayAnchorMessageId ?? cursorMessageId;
      final id = await txn.insert('context_summaries', {
        'character_id': characterId,
        'source_window_id': sourceWindowId,
        'source_conversation_id': conversationId,
        'display_anchor_message_id': displayAnchorId,
        'parent_summary_id': parentId,
        'source_message_start_id': resolvedStartId,
        'source_message_end_id': cursorMessageId,
        'source_span_status': resolvedStartId == null ? 'unknown' : 'exact',
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId,
        'story_time_text': storyTimeText,
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
      final marked = await txn.update(
        'messages',
        <String, Object?>{'summary_recorded': 1},
        where: 'id = ? AND conversation_id = ?',
        whereArgs: <Object?>[displayAnchorId, conversationId],
      );
      if (marked != 1) {
        throw StateError(
          'Summary display anchor $displayAnchorId does not exist in '
          '$conversationId',
        );
      }
      return id;
    });
  }

  static Future<int?> _latestValidSummaryId(
    DatabaseExecutor db, {
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final rows = await db.query(
      'context_summaries',
      columns: const <String>['id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid'",
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  static Future<bool> _sourceMessagesMatch(
    DatabaseExecutor db,
    String conversationId,
    List<Message> snapshots,
  ) async {
    if (snapshots.isEmpty) return true;
    final expected = <int, int>{
      for (final message in snapshots)
        if (message.id != null) message.id!: message.revision,
    };
    if (expected.length != snapshots.length) return false;
    final placeholders = List.filled(expected.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, revision FROM messages WHERE conversation_id = ? '
      'AND id IN ($placeholders)',
      <Object?>[conversationId, ...expected.keys],
    );
    if (rows.length != expected.length) return false;
    return rows.every((row) {
      final id = row['id'] as int?;
      return id != null && (row['revision'] as int? ?? 1) == expected[id];
    });
  }

  static Future<bool> _hasPendingSummaryRepairs(
    DatabaseExecutor db,
    String characterId,
    ContextMode contextMode,
    String continuityId,
  ) async {
    final rows = await db.query(
      'context_summary_repairs',
      columns: const <String>['id'],
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND status != 'completed'",
      whereArgs: <Object?>[characterId, contextMode.storageValue, continuityId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<int?> _firstMessageIdInRange(
    DatabaseExecutor db, {
    required String conversationId,
    required int afterMessageId,
    required int throughMessageId,
  }) async {
    final rows = await db.rawQuery(
      'SELECT MIN(id) AS first_id FROM messages '
      'WHERE conversation_id = ? AND id > ? AND id <= ?',
      <Object?>[conversationId, afterMessageId, throughMessageId],
    );
    return rows.first['first_id'] as int?;
  }

  /// 取得角色的全部摘要塊（舊→新）
  static Future<List<Map<String, dynamic>>> getContextSummaries(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    bool includeArchived = false,
  }) async {
    final db = await database;
    return await db.query(
      'context_summaries',
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ?'
          " AND revision_status = 'valid'"
          '${includeArchived ? '' : ' AND archived = 0'}',
      whereArgs: [characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC, id ASC',
    );
  }

  /// Finds the active summary that covers exactly the same source span as a
  /// selected message range. Unknown legacy spans are never treated as a
  /// rewrite target because their boundaries cannot be proven safe.
  static Future<Map<String, dynamic>?> getContextSummaryByExactSourceSpan({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String conversationId,
    required int sourceMessageStartId,
    required int sourceMessageEndId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'context_summaries',
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND source_conversation_id = ? AND source_message_start_id = ? "
          "AND source_message_end_id = ? AND source_span_status = 'exact' "
          "AND revision_status = 'valid' AND archived = 0",
      whereArgs: <Object?>[
        characterId,
        contextMode.storageValue,
        continuityId,
        conversationId,
        sourceMessageStartId,
        sourceMessageEndId,
      ],
      orderBy: 'revision DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 取得角色最新摘要塊（新→舊），可排除目前窗口
  static Future<List<Map<String, dynamic>>> getLatestContextSummaries(
    String characterId, {
    String? excludeWindowId,
    int limit = 2,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    final where = StringBuffer(
      'character_id = ? AND context_mode = ? AND continuity_id = ? AND archived = 0',
    )..write(" AND revision_status = 'valid'");
    final args = <Object?>[characterId, contextMode.storageValue, continuityId];
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

  static Future<List<Map<String, dynamic>>> getRelevantContextSummaries(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    Iterable<String> sourceConversationIds = const <String>[],
    int limit = 3,
  }) async {
    final db = await database;
    final ids = sourceConversationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final where = StringBuffer(
      "character_id = ? AND context_mode = ? AND continuity_id = ? "
      "AND revision_status = 'valid'",
    );
    final args = <Object?>[characterId, contextMode.storageValue, continuityId];
    if (ids.isNotEmpty) {
      where.write(
        ' AND source_conversation_id IN (${List.filled(ids.length, '?').join(',')})',
      );
      args.addAll(ids);
    }
    final rows = await db.query(
      'context_summaries',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit.clamp(1, 10),
    );
    if (rows.isNotEmpty || ids.isEmpty) return rows;
    return getLatestContextSummaries(
      characterId,
      limit: limit,
      contextMode: contextMode,
      continuityId: continuityId,
    );
  }

  static Future<Map<String, dynamic>?> getLatestConversationContextSummary({
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'context_summaries',
      where:
          'source_conversation_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid'",
      whereArgs: <Object?>[
        conversationId,
        contextMode.storageValue,
        continuityId,
      ],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>?> getConversationContextSummaryById({
    required int summaryId,
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'context_summaries',
      where:
          'id = ? AND source_conversation_id = ? AND context_mode = ? '
          "AND continuity_id = ? AND revision_status = 'valid'",
      whereArgs: <Object?>[
        summaryId,
        conversationId,
        contextMode.storageValue,
        continuityId,
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 取得摘要總 token 數
  static Future<int> getContextSummaryTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_summaries '
      "WHERE character_id = ? AND context_mode = ? AND continuity_id = ? "
      "AND archived = 0 AND revision_status = 'valid'",
      [characterId, contextMode.storageValue, continuityId],
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
    await db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE context_summaries SET content = ?, token_count = ?, '
        'revision = revision + 1 WHERE id = ?',
        <Object?>[content, tokenCount, id],
      );
      // An archived original remains editable through its chat marker.
      await txn.update(
        'context_keywords',
        {'source_summary_content': content},
        where: 'source_summary_id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Retire one superseded snapshot without losing its chat history anchor.
  /// The label and archive marker move together, so a failed write leaves the
  /// original active for the next attempt.
  static Future<bool> archiveContextSummaryWithKeywords({
    required int summaryId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String keywords,
    required int keywordTokenCount,
  }) async {
    final db = await database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'context_summaries',
        where:
            'id = ? AND character_id = ? AND context_mode = ? '
            "AND continuity_id = ? AND archived = 0 "
            "AND revision_status = 'valid' AND COALESCE(locked, 0) = 0",
        whereArgs: [
          summaryId,
          characterId,
          contextMode.storageValue,
          continuityId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final newest = await txn.query(
        'context_summaries',
        columns: const ['id'],
        where:
            'character_id = ? AND context_mode = ? AND continuity_id = ? '
            "AND archived = 0 AND revision_status = 'valid'",
        whereArgs: [characterId, contextMode.storageValue, continuityId],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
      if (newest.isEmpty || newest.first['id'] == summaryId) return false;
      final row = rows.first;
      final existing = await txn.query(
        'context_keywords',
        columns: const ['id'],
        where: 'source_summary_id = ?',
        whereArgs: [summaryId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('context_keywords', {
          'character_id': characterId,
          'source_window_id': row['source_window_id'] as String? ?? '',
          'source_conversation_id':
              row['source_conversation_id'] as String? ?? '',
          'context_mode': contextMode.storageValue,
          'continuity_id': continuityId,
          'keywords': keywords,
          'token_count': keywordTokenCount,
          'source_summary_id': summaryId,
          'source_summary_content': row['content'] as String? ?? '',
          'created_at':
              row['created_at'] as String? ?? DateTime.now().toIso8601String(),
        });
      }
      await txn.update(
        'context_summaries',
        {'archived': 1},
        where: 'id = ?',
        whereArgs: [summaryId],
      );
      return true;
    });
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
    await db.transaction((txn) async {
      await txn.delete(
        'context_keywords',
        where: 'source_summary_id = ?',
        whereArgs: [id],
      );
      await txn.delete('context_summaries', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 刪除最舊的摘要塊，返回被刪的記錄
  static Future<Map<String, dynamic>?> deleteOldestContextSummary(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    final oldest = await db.query(
      'context_summaries',
      where:
          'character_id = ? AND context_mode = ? AND continuity_id = ? '
          "AND revision_status = 'valid' AND (locked IS NULL OR locked = 0)",
      whereArgs: [characterId, contextMode.storageValue, continuityId],
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
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
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

  /// 取得關鍵詞層
  static Future<List<Map<String, dynamic>>> getContextKeywords(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    return await db.query(
      'context_keywords',
      where: 'character_id = ? AND context_mode = ? AND continuity_id = ?',
      whereArgs: [characterId, contextMode.storageValue, continuityId],
      orderBy: 'created_at ASC',
    );
  }

  /// 取得關鍵詞總 token 數
  static Future<int> getContextKeywordTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(token_count),0) as total FROM context_keywords '
      'WHERE character_id = ? AND context_mode = ? AND continuity_id = ?',
      [characterId, contextMode.storageValue, continuityId],
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
  static Future<void> deleteOldestContextKeyword(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) async {
    final db = await database;
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
