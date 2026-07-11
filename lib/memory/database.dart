import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/memory.dart';

/// 本地數據庫
class DatabaseHelper {
  static Database? _database;
  static Future<Database>? _dbInitFuture;
  static Future<Database> Function() _databaseInitializer = _initDatabase;
  static const String _dbName = 'yanci.db';
  static const int _dbVersion = 33;
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
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        character_id TEXT DEFAULT 'default',
        window_summary_id TEXT DEFAULT '',
        pinned_static_summary TEXT,
        title TEXT,
        is_starred INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        character_id TEXT DEFAULT 'default',
        text TEXT NOT NULL,
        is_user INTEGER NOT NULL,
        image_path TEXT,
        split_mode INTEGER DEFAULT 0,
        memory_log TEXT DEFAULT '',
        cache_hit INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_conv ON messages(conversation_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_msg_char_time ON messages(character_id, created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_conv_char ON conversations(character_id)',
    );

    await _createMemoryTables(db);
    await _createStickerTables(db);
    await _createCharacterTables(db);
    await _createNotesTable(db);
    await _createUsageTable(db);
    await _createVoiceTable(db);
    await _createSavedMessagesTable(db);
    await _createContextSummaryTables(db);
    await _createEmotionTables(db);
    await _createCharacterTimelineTable(db);
    await _createKnownIndexes(db);
  }

  /// 用量記錄表
  static Future<void> _createUsageTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS usage_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        character_id TEXT DEFAULT 'default',
        prompt_tokens INTEGER DEFAULT 0,
        completion_tokens INTEGER DEFAULT 0,
        cache_hit_tokens INTEGER DEFAULT 0,
        cache_creation_tokens INTEGER DEFAULT 0,
        estimated_cost REAL DEFAULT 0.0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_logs(timestamp)
    ''');
  }

  /// 便利貼
  static Future<void> _createNotesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sticky_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL DEFAULT 'default',
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createCharacterTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS characters (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        gender TEXT DEFAULT '',
        relationship TEXT DEFAULT '',
        description TEXT,
        race TEXT,
        skill TEXT,
        age TEXT,
        height TEXT,
        avatar_path TEXT,
        tts_voice_id TEXT DEFAULT '',
        self_notes TEXT DEFAULT '',
        draw_anchor_user TEXT DEFAULT '',
        draw_anchor_char TEXT DEFAULT '',
        draw_style TEXT DEFAULT '',
        is_spider_web_enabled INTEGER DEFAULT 0,
        bio_clock TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// 情緒座標與怨念封印原先由功能首次開啟時懶建。正式放入 schema，
  /// 避免 fresh install 與曾使用過功能的資料庫結構不同。
  static Future<void> _createEmotionTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS emotion_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        type TEXT NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        concentration REAL NOT NULL,
        memory_id INTEGER,
        note TEXT DEFAULT '',
        status TEXT DEFAULT 'active',
        confirmed INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS grudge_seals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        memory_id INTEGER NOT NULL,
        negative_concentration REAL NOT NULL,
        event_summary TEXT DEFAULT '',
        sealed_at TEXT NOT NULL,
        surfaced_at TEXT,
        UNIQUE(character_id, memory_id)
      )
    ''');
  }

  /// 角色時間線原先也是使用時才建表；v33 起成為正式 schema。
  static Future<void> _createCharacterTimelineTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_timeline (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'state',
        key TEXT,
        value TEXT NOT NULL,
        source_memory_id INTEGER,
        week_group TEXT,
        confirmed INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
  }

  /// 所有 fresh install 與 migration 最終都會走到這裡，確保查詢規劃一致。
  static Future<void> _createKnownIndexes(Database db) async {
    const statements = <String>[
      'CREATE INDEX IF NOT EXISTS idx_messages_conv_time '
          'ON messages(conversation_id, created_at DESC, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_conv_char_updated '
          'ON conversations(character_id, is_starred DESC, updated_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_mem_char_mode_time '
          'ON memories(character_id, mode, status, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_spider_web_char '
          'ON spider_web_links(character_id)',
      'CREATE INDEX IF NOT EXISTS idx_spider_web_memory_1 '
          'ON spider_web_links(character_id, memory_id_1)',
      'CREATE INDEX IF NOT EXISTS idx_spider_web_memory_2 '
          'ON spider_web_links(character_id, memory_id_2)',
      'CREATE INDEX IF NOT EXISTS idx_backpack_item '
          'ON backpack_items(item_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_archive_original_unique '
          'ON archive(original_table, original_id)',
      'CREATE INDEX IF NOT EXISTS idx_archive_char_time '
          'ON archive(character_id, archived_at DESC, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_notes_char_time '
          'ON sticky_notes(character_id, id DESC)',
      'CREATE INDEX IF NOT EXISTS idx_usage_char_ts '
          'ON usage_logs(character_id, timestamp DESC)',
      'CREATE INDEX IF NOT EXISTS idx_voice_char_time '
          'ON saved_voices(character_id, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_voice_conversation '
          'ON saved_voices(source_conversation_id)',
      'CREATE INDEX IF NOT EXISTS idx_saved_char_time '
          'ON saved_messages(character_id, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_context_summary_char_time '
          'ON context_summaries(character_id, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_context_keyword_char_time '
          'ON context_keywords(character_id, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_emo_char '
          'ON emotion_points(character_id, status)',
      'CREATE INDEX IF NOT EXISTS idx_emo_memory '
          'ON emotion_points(character_id, memory_id)',
      'CREATE INDEX IF NOT EXISTS idx_grudge_char '
          'ON grudge_seals(character_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_state '
          'ON character_timeline(character_id, key) WHERE type = \'state\'',
      'CREATE INDEX IF NOT EXISTS idx_timeline_event_lookup '
          'ON character_timeline('
          'character_id, type, confirmed, week_group, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_timeline_memory '
          'ON character_timeline(character_id, source_memory_id)',
    ];
    for (final statement in statements) {
      await db.execute(statement);
    }
  }

  static Future<void> _createMemoryTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT DEFAULT 'default',
        mode TEXT NOT NULL,
        category TEXT NOT NULL,
        content TEXT NOT NULL,
        confidence TEXT,
        narrative_weight TEXT,
        is_permanent INTEGER DEFAULT 0,
        source_conversation_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        mention_count INTEGER DEFAULT 0,
        status TEXT DEFAULT 'active',
        review_count INTEGER DEFAULT 0,
        triggers TEXT DEFAULT '',
        clarity REAL DEFAULT 1.0,
        last_linked_at TEXT DEFAULT '',
        emotion_x INTEGER,
        emotion_y INTEGER,
        emotion_resonance INTEGER,
        last_accessed TEXT DEFAULT ''
      )
    ''');

    // 蜘蛛網記憶系統：連線圖譜
    await db.execute('''
      CREATE TABLE IF NOT EXISTS spider_web_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        memory_id_1 INTEGER NOT NULL,
        memory_id_2 INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(memory_id_1, memory_id_2)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_char ON spider_web_links(character_id)',
    );

    // 貝殼商店物品庫
    await db.execute('''
      CREATE TABLE IF NOT EXISTS shop_items (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        price INTEGER NOT NULL,
        type TEXT NOT NULL,
        category TEXT DEFAULT '',
        sort_order INTEGER DEFAULT 0,
        image_path TEXT DEFAULT ''
      )
    ''');

    // 背包物品
    await db.execute('''
      CREATE TABLE IF NOT EXISTS backpack_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        quantity INTEGER DEFAULT 1,
        given_by TEXT DEFAULT '',
        starred INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(owner_id, item_id, given_by)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS archive (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL DEFAULT 'default',
        original_id INTEGER NOT NULL,
        original_table TEXT NOT NULL,
        content_snapshot TEXT NOT NULL,
        archived_at TEXT NOT NULL,
        reason TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mem_char_mode 
      ON memories(character_id, mode, status)
    ''');
  }

  static Future<void> _createStickerTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stickers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT DEFAULT 'user',
        file_path TEXT NOT NULL,
        line TEXT,
        scene TEXT,
        mood TEXT,
        tags TEXT,
        description_method TEXT DEFAULT 'label',
        created_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createMemoryTables(db);
    }
    if (oldVersion < 3) {
      try {
        await db.execute(
          'ALTER TABLE conversations ADD COLUMN character_id TEXT DEFAULT \'default\'',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN character_id TEXT DEFAULT \'default\'',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE memories ADD COLUMN character_id TEXT DEFAULT \'default\'',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE memories ADD COLUMN review_count INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 4) {
      try {
        await db.execute('DROP TABLE IF EXISTS stickers');
      } catch (_) {}
      await _createStickerTables(db);
    }
    if (oldVersion < 5) {
      await _createCharacterTables(db);
    }
    if (oldVersion < 6) {
      await _createNotesTable(db);
    }
    if (oldVersion < 7) {
      await _createUsageTable(db);
    }
    if (oldVersion < 8) {
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN image_path TEXT');
      } catch (_) {}
    }
    if (oldVersion < 9) {
      try {
        await db.execute(
          'ALTER TABLE conversations ADD COLUMN is_starred INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 10) {
      await _createVoiceTable(db);
    }
    if (oldVersion < 11) {
      await _createSavedMessagesTable(db);
    }
    if (oldVersion < 12) {
      try {
        await db.execute(
          "ALTER TABLE characters ADD COLUMN tts_voice_id TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 13) {
      try {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN split_mode INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 14) {
      // 治癒 v0.1.0 新裝用戶的破庫：
      // 當時 onCreate 漏建 split_mode 列，這裡防禦性補上
      // （已有此列的庫 ALTER 會拋錯，catch 吞掉即可）
      try {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN split_mode INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 15) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conv_char ON conversations(character_id)',
      );
    }
    if (oldVersion < 16) {
      // 條件反射觸發詞列
      try {
        await db.execute(
          "ALTER TABLE memories ADD COLUMN triggers TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 17) {
      // 角色自我註記（模型 persona_note 累積）
      try {
        await db.execute(
          "ALTER TABLE characters ADD COLUMN self_notes TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 18) {
      // 記憶過程日誌（思考鏈式的記憶操作顯示）
      try {
        await db.execute(
          "ALTER TABLE messages ADD COLUMN memory_log TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 19) {
      // 畫畫角色錨點（自動注入畫圖 prompt）
      try {
        await db.execute(
          "ALTER TABLE characters ADD COLUMN draw_anchor_user TEXT DEFAULT ''",
        );
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE characters ADD COLUMN draw_anchor_char TEXT DEFAULT ''",
        );
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE characters ADD COLUMN draw_style TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 20) {
      // v19 migration 可能被 catch 吃掉，再試一次確保列存在
      for (final col in [
        'draw_anchor_user',
        'draw_anchor_char',
        'draw_style',
      ]) {
        try {
          await db.execute(
            "ALTER TABLE characters ADD COLUMN $col TEXT DEFAULT ''",
          );
        } catch (_) {} // 已存在則忽略
      }
    }
    if (oldVersion < 21) {
      await _createContextSummaryTables(db);
    }
    if (oldVersion < 22) {
      try {
        await db.execute(
          "ALTER TABLE context_keywords ADD COLUMN source_summary_content TEXT DEFAULT ''",
        );
      } catch (_) {}
    }
    if (oldVersion < 23) {
      await _safeAddColumn(db, 'messages', 'cache_hit', 'INTEGER DEFAULT 0');
    }
    if (oldVersion < 24) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_msg_char_time ON messages(character_id, created_at)',
      );
    }
    if (oldVersion < 25) {
      await _safeAddColumn(
        db,
        'conversations',
        'window_summary_id',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'context_summaries',
        'source_window_id',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'context_summaries',
        'source_conversation_id',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'context_keywords',
        'source_window_id',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'context_keywords',
        'source_conversation_id',
        "TEXT DEFAULT ''",
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_context_summary_char_time ON context_summaries(character_id, created_at)',
      );
    }
    if (oldVersion < 26) {
      await _safeAddColumn(
        db,
        'characters',
        'is_spider_web_enabled',
        'INTEGER DEFAULT 0',
      );
      await _safeAddColumn(db, 'memories', 'clarity', 'REAL DEFAULT 1.0');
      await _safeAddColumn(db, 'memories', 'last_linked_at', "TEXT DEFAULT ''");
      await _safeAddColumn(db, 'memories', 'emotion_x', 'INTEGER');
      await _safeAddColumn(db, 'memories', 'emotion_y', 'INTEGER');
      await _safeAddColumn(db, 'memories', 'emotion_resonance', 'INTEGER');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS spider_web_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_id TEXT NOT NULL,
          memory_id_1 INTEGER NOT NULL,
          memory_id_2 INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          UNIQUE(memory_id_1, memory_id_2)
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_spider_web_char ON spider_web_links(character_id)',
      );
    }

    if (oldVersion < 27) {
      await _safeAddColumn(db, 'memories', 'last_accessed', "TEXT DEFAULT ''");
    }

    if (oldVersion < 28) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS shop_items (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT,
          price INTEGER NOT NULL,
          type TEXT NOT NULL,
          category TEXT DEFAULT '',
          sort_order INTEGER DEFAULT 0,
          image_path TEXT DEFAULT ''
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS backpack_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          owner_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          quantity INTEGER DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(owner_id, item_id)
        )
      ''');
    }

    if (oldVersion < 29) {
      // 背包 v2：given_by（''=自己買）+ starred（模型標記重要）。
      // UNIQUE 擴為三鍵——「自己買的杯子」和「昭昭送的杯子」是兩條記錄，
      // 只在同來源內堆疊。SQLite 改約束需重建表。
      await db.execute(
        'ALTER TABLE backpack_items RENAME TO backpack_items_old',
      );
      await db.execute('''
        CREATE TABLE backpack_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          owner_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          quantity INTEGER DEFAULT 1,
          given_by TEXT DEFAULT '',
          starred INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(owner_id, item_id, given_by)
        )
      ''');
      await db.execute('''
        INSERT INTO backpack_items (id, owner_id, item_id, quantity, created_at, updated_at)
        SELECT id, owner_id, item_id, quantity, created_at, updated_at FROM backpack_items_old
      ''');
      await db.execute('DROP TABLE backpack_items_old');
    }

    if (oldVersion < 30) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'locked',
        'INTEGER DEFAULT 0',
      );
    }
    if (oldVersion < 31) {
      // 靜態摘要 pin：綁對話、出生釘死。nullable → NULL = 尚未釘
      //（含遷移前的既有對話，首次重建時補釘一次，僅此一次全量重寫）。
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_static_summary',
        'TEXT',
      );
    }
    if (oldVersion < 32) {
      // 舊版把「我的表情」前身存成 default；現在統一歸到 user 桶。
      try {
        await db.update(
          'stickers',
          {'character_id': 'user'},
          where: 'character_id = ?',
          whereArgs: ['default'],
        );
      } catch (_) {}
    }
    if (oldVersion < 33) {
      await _migrateToV33(db);
    }
  }

  /// v33 是修復性 migration：把先前的懶建 schema 收回主資料庫版本，
  /// 並重新驗證幾個曾由寬泛 catch 保護的關鍵欄位。
  static Future<void> _migrateToV33(Database db) async {
    // CREATE IF NOT EXISTS 先保證各功能表存在，隨後再補既有表缺少的欄。
    await _createMemoryTables(db);
    await _createStickerTables(db);
    await _createCharacterTables(db);
    await _createNotesTable(db);
    await _createUsageTable(db);
    await _createVoiceTable(db);
    await _createSavedMessagesTable(db);
    await _createContextSummaryTables(db);
    await _createEmotionTables(db);
    await _createCharacterTimelineTable(db);

    await _safeAddColumn(
      db,
      'sticky_notes',
      'character_id',
      "TEXT NOT NULL DEFAULT 'default'",
    );
    await _safeAddColumn(db, 'characters', 'bio_clock', "TEXT DEFAULT ''");
    await _safeAddColumn(
      db,
      'characters',
      'is_spider_web_enabled',
      'INTEGER DEFAULT 0',
    );
    await _safeAddColumn(db, 'messages', 'split_mode', 'INTEGER DEFAULT 0');
    await _safeAddColumn(db, 'messages', 'memory_log', "TEXT DEFAULT ''");
    await _safeAddColumn(db, 'messages', 'cache_hit', 'INTEGER DEFAULT 0');
    await _safeAddColumn(
      db,
      'conversations',
      'window_summary_id',
      "TEXT DEFAULT ''",
    );
    await _safeAddColumn(db, 'conversations', 'pinned_static_summary', 'TEXT');
    await _safeAddColumn(
      db,
      'context_summaries',
      'source_window_id',
      "TEXT DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'source_conversation_id',
      "TEXT DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'locked',
      'INTEGER DEFAULT 0',
    );
    await _safeAddColumn(
      db,
      'context_keywords',
      'source_window_id',
      "TEXT DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_keywords',
      'source_conversation_id',
      "TEXT DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_keywords',
      'source_summary_content',
      "TEXT DEFAULT ''",
    );

    await _safeAddColumn(
      db,
      'archive',
      'character_id',
      "TEXT NOT NULL DEFAULT 'default'",
    );
    await _backfillAndDeduplicateArchive(db);
    await _createKnownIndexes(db);
  }

  static Future<void> _backfillAndDeduplicateArchive(Database db) async {
    final rows = await db.query('archive', orderBy: 'id ASC');
    for (final row in rows) {
      final archiveId = row['id'] as int;
      final originalId = row['original_id'] as int;
      var characterId = '';

      if (row['original_table'] == 'memories') {
        final memoryRows = await db.query(
          'memories',
          columns: ['character_id'],
          where: 'id = ?',
          whereArgs: [originalId],
          limit: 1,
        );
        if (memoryRows.isNotEmpty) {
          characterId = (memoryRows.first['character_id'] as String? ?? '')
              .trim();
        }
      }

      if (characterId.isEmpty) {
        try {
          final decoded = jsonDecode(row['content_snapshot'] as String);
          if (decoded is Map) {
            characterId = (decoded['character_id']?.toString() ?? '').trim();
          }
        } on FormatException {
          // Very old archives may contain a plain-text snapshot. They remain
          // recoverable only through their original row and stay in default.
        }
      }

      await db.update(
        'archive',
        {'character_id': characterId.isEmpty ? 'default' : characterId},
        where: 'id = ?',
        whereArgs: [archiveId],
      );
    }

    // Historical code could archive the same row repeatedly. Keep the newest
    // snapshot/reason before installing the uniqueness invariant.
    await db.rawDelete('''
      DELETE FROM archive
      WHERE id NOT IN (
        SELECT MAX(id)
        FROM archive
        GROUP BY original_table, original_id
      )
    ''');
  }

  /// 安全新增欄位，避免吞噬其他 SQL 錯誤
  static Future<void> _safeAddColumn(
    Database db,
    String table,
    String colName,
    String def,
  ) async {
    final res = await db.rawQuery("PRAGMA table_info('$table')");
    final exists = res.any((row) => row['name'] == colName);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $colName $def');
    }
  }

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
    await db.delete('saved_voices', where: 'id = ?', whereArgs: [id]);
  }

  /// 清除指定角色的語音緩存
  static Future<void> clearAllVoices({required String characterId}) async {
    final db = await database;
    await db.delete(
      'saved_voices',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
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
      '''
      SELECT recent.id, recent.text, recent.is_user, recent.created_at, recent.title
      FROM (
        SELECT m.id, m.text, m.is_user, m.created_at, c.title
        FROM messages m
        LEFT JOIN conversations c ON m.conversation_id = c.id
        WHERE m.character_id = ? AND m.text LIKE ?
        ORDER BY m.created_at DESC, m.id DESC
        LIMIT ?
      ) AS recent
      ORDER BY recent.created_at ASC, recent.id ASC
    ''',
      [characterId, '%$keyword%', limit],
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

  /// 追加角色自我註記（最多保留 12 條，先進先出）
  static Future<void> appendSelfNote(String characterId, String note) async {
    final db = await database;
    final rows = await db.query(
      'characters',
      columns: ['self_notes'],
      where: 'id = ?',
      whereArgs: [characterId],
    );
    if (rows.isEmpty) return;
    final existing = (rows.first['self_notes'] as String?) ?? '';
    var lines = existing.isEmpty ? <String>[] : existing.split('\n');
    lines.add('· $note');
    if (lines.length > 12) lines = lines.sublist(lines.length - 12);
    await db.update(
      'characters',
      {'self_notes': lines.join('\n')},
      where: 'id = ?',
      whereArgs: [characterId],
    );
  }

  static Future<String> getSelfNotes(String characterId) async {
    final db = await database;
    final rows = await db.query(
      'characters',
      columns: ['self_notes'],
      where: 'id = ?',
      whereArgs: [characterId],
    );
    if (rows.isEmpty) return '';
    return (rows.first['self_notes'] as String?) ?? '';
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
    // ═══ 級聯清理：對話（含其語音/收藏）、記憶、貼圖（含文件）═══
    final convs = await db.query(
      'conversations',
      columns: ['id'],
      where: 'character_id = ?',
      whereArgs: [id],
    );
    final convIds = convs.map((c) => c['id'] as String).toList();

    // 收集所有要刪除的語音文件
    final voices = <Map<String, Object?>>[];
    for (final cid in convIds) {
      voices.addAll(
        await db.query(
          'saved_voices',
          columns: ['file_path'],
          where: 'source_conversation_id = ?',
          whereArgs: [cid],
        ),
      );
    }
    voices.addAll(
      await db.query(
        'saved_voices',
        columns: ['file_path'],
        where: 'character_id = ?',
        whereArgs: [id],
      ),
    );

    for (final v in voices) {
      try {
        final f = File(v['file_path'] as String);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('Failed to delete voice file: $e');
      }
    }

    // 貼圖文件
    final stickers = await db.query(
      'stickers',
      columns: ['file_path'],
      where: 'character_id = ?',
      whereArgs: [id],
    );
    for (final st in stickers) {
      try {
        final f = File(st['file_path'] as String);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('Failed to delete sticker file: $e');
      }
    }

    // 批量執行資料庫刪除
    final batch = db.batch();
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
      batch.delete('messages', where: 'conversation_id = ?', whereArgs: [cid]);
      batch.delete('conversations', where: 'id = ?', whereArgs: [cid]);
    }
    batch.delete('stickers', where: 'character_id = ?', whereArgs: [id]);
    batch.delete('saved_voices', where: 'character_id = ?', whereArgs: [id]);
    batch.delete('saved_messages', where: 'character_id = ?', whereArgs: [id]);
    // These tables used to be lazily created and were omitted from character
    // deletion, leaving cross-feature references behind indefinitely.
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
    String where = 'title LIKE ?';
    List<dynamic> args = ['%$query%'];
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

  /// 釘死對話的靜態摘要文本。出生一次、之後永不改（空字串也算已釘）。
  static Future<void> setConversationPinnedSummary(
    String id,
    String text,
  ) async {
    final db = await database;
    await db.update(
      'conversations',
      {'pinned_static_summary': text},
      where: 'id = ?',
      whereArgs: [id],
    );
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
    // ═══ 級聯清理：語音（含文件）、收藏 ═══
    // 語音文件不刪會永久佔磁盤
    final voices = await db.query(
      'saved_voices',
      columns: ['id', 'file_path'],
      where: 'source_conversation_id = ?',
      whereArgs: [id],
    );
    for (final v in voices) {
      try {
        final f = File(v['file_path'] as String);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('Failed to delete voice file: $e');
      }
    }
    await db.delete(
      'saved_voices',
      where: 'source_conversation_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'saved_messages',
      where: 'conversation_id = ?',
      whereArgs: [id],
    );
    // 記憶刻意不刪：記憶的設計就是要活得比對話久
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
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
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Message.fromMap(maps.first);
  }

  static Future<void> deleteMessageById(int id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteMessageByFingerprint(Message msg) async {
    final db = await database;
    await db.delete(
      'messages',
      where:
          'conversation_id = ? AND character_id = ? AND text = ? AND is_user = ? AND created_at = ?',
      whereArgs: [
        msg.conversationId,
        msg.characterId,
        msg.text,
        msg.isUser ? 1 : 0,
        msg.createdAt.toIso8601String(),
      ],
    );
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

  // ═══════════════════════════════════
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
      where: 'mode = ? AND status = ? AND character_id = ? AND content LIKE ?',
      whereArgs: [mode, 'active', characterId, '%$keyword%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return maps.map((m) => Memory.fromMap(m)).toList();
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
    return db.transaction((txn) async {
      final maps = await txn.query(
        'memories',
        where: 'id = ? AND character_id = ?',
        whereArgs: [memoryId, requestedCharacter],
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
        where: 'id = ? AND character_id = ?',
        whereArgs: [memoryId, scopedCharacter],
      );
      return changed == 1;
    });
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
    await db.delete('stickers', where: 'id = ?', whereArgs: [id]);
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
    return db.transaction((txn) async {
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
      'CREATE INDEX IF NOT EXISTS idx_saved_char ON saved_messages(character_id)',
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
      return await db.insert('saved_messages', {
        'message_id': messageId,
        'content': content,
        'character_id': characterId,
        'conversation_id': conversationId,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // 嘗試建表後重試
      try {
        final db = await database;
        await _createSavedMessagesTable(db);
        return await db.insert('saved_messages', {
          'message_id': messageId,
          'content': content,
          'character_id': characterId,
          'conversation_id': conversationId,
          'created_at': DateTime.now().toIso8601String(),
        });
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
      where: 'character_id = ? AND (content LIKE ? OR created_at LIKE ?)',
      whereArgs: [characterId, '%$query%', '%$query%'],
      orderBy: 'created_at DESC',
    );
  }

  /// 刪除收藏
  static Future<void> deleteSavedMessage(int id) async {
    final db = await database;
    await db.delete('saved_messages', where: 'id = ?', whereArgs: [id]);
  }

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
    String characterId,
  ) async {
    final db = await database;
    return await db.query(
      'spider_web_links',
      where: 'character_id = ?',
      whereArgs: [characterId],
    );
  }
}
