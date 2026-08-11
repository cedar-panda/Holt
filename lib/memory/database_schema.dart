part of 'database.dart';

class _DatabaseSchema {
  static Future<void> _createVoiceTable(Database db) =>
      DatabaseHelper._createVoiceTable(db);
  static Future<void> _createSavedMessagesTable(Database db) =>
      DatabaseHelper._createSavedMessagesTable(db);
  static Future<void> _createContextSummaryTables(Database db) =>
      DatabaseHelper._createContextSummaryTables(db);
  static Future<void> _createSavedMessageUniqueIndex(Database db) =>
      DatabaseHelper._createSavedMessageUniqueIndex(db);

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        character_id TEXT DEFAULT 'default',
        window_summary_id TEXT DEFAULT '',
        summary_cursor_message_id INTEGER NOT NULL DEFAULT 0,
        pinned_static_summary TEXT,
        pinned_static_self_notes TEXT,
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
        status TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_msg_char_time ON messages(character_id, created_at)',
    );

    await _createMemoryTables(db);
    await _createStickerTables(db);
    await _createCharacterTables(db);
    await _createNotesTable(db);
    await _createUsageTable(db);
    await _createWebSearchUsageTable(db);
    await _createVoiceTable(db);
    await _createSavedMessagesTable(db);
    await _createContextSummaryTables(db);
    await _createEmotionTables(db);
    await _createCharacterTimelineTable(db);
    await _createKnownIndexes(db);
    await _createSavedMessageUniqueIndex(db);
    await _createTimelineEventUniqueIndex(db);
    await _createMemoryFts(db);
  }

  /// Repairs schema objects that may be absent even when user_version already
  /// matches the app. This covers same-version additions and backups that
  /// intentionally omit derived FTS tables.
  static Future<void> _ensureRuntimeSchema(Database db) async {
    await _createPendingMemoryActionsTable(db);
    await _createWebSearchUsageTable(db);
    await _ensureMemoryFts(db);
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

  /// One row per authorized provider route. The outgoing query, result text,
  /// source URLs, and credentials deliberately never enter this ledger.
  static Future<void> _createWebSearchUsageTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS web_search_usage_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reservation_id TEXT NOT NULL,
        logical_slot INTEGER NOT NULL CHECK(logical_slot IN (0, 1)),
        conversation_id TEXT NOT NULL,
        character_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        generation_serial INTEGER NOT NULL CHECK(generation_serial >= 0),
        budget_day TEXT NOT NULL,
        plan_strategy TEXT NOT NULL
          CHECK(plan_strategy IN ('single', 'dual')),
        provider TEXT NOT NULL
          CHECK(provider IN ('openRouter', 'gemini')),
        provider_model TEXT NOT NULL,
        provider_route TEXT NOT NULL,
        call_id TEXT,
        status TEXT NOT NULL DEFAULT 'reserved'
          CHECK(status IN (
            'reserved', 'claimed', 'launched', 'success', 'failure',
            'cancelled', 'unknown', 'released'
          )),
        reserved_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        claimed_at TEXT,
        launched_at TEXT,
        settled_at TEXT,
        search_requests INTEGER NOT NULL DEFAULT 0
          CHECK(search_requests >= 0),
        prompt_tokens INTEGER NOT NULL DEFAULT 0 CHECK(prompt_tokens >= 0),
        completion_tokens INTEGER NOT NULL DEFAULT 0
          CHECK(completion_tokens >= 0),
        actual_cost_usd REAL CHECK(actual_cost_usd IS NULL OR actual_cost_usd >= 0),
        cost_certainty TEXT NOT NULL DEFAULT 'unknown'
          CHECK(cost_certainty IN ('known', 'unknown')),
        UNIQUE(reservation_id, provider)
      )
    ''');
    await _createWebSearchUsageIndexes(db);
  }

  static Future<void> _createWebSearchUsageIndexes(Database db) async {
    const statements = <String>[
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_web_search_turn_once '
          'ON web_search_usage_logs('
          'conversation_id, turn_id, generation_serial) '
          'WHERE logical_slot = 1',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_web_search_call_once '
          'ON web_search_usage_logs(call_id) '
          'WHERE logical_slot = 1 AND call_id IS NOT NULL',
      'CREATE INDEX IF NOT EXISTS idx_web_search_budget_status '
          'ON web_search_usage_logs(budget_day, status)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_web_search_reservation '
          'ON web_search_usage_logs(reservation_id) WHERE logical_slot = 1',
      'CREATE INDEX IF NOT EXISTS idx_web_search_char_time '
          'ON web_search_usage_logs(character_id, reserved_at DESC)',
    ];
    for (final statement in statements) {
      await db.execute(statement);
    }
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
        whisper_user_text TEXT DEFAULT '',
        whisper_model_text TEXT DEFAULT '',
        whisper_source TEXT DEFAULT 'default',
        whisper_model_override INTEGER DEFAULT 1,
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
        source_message_id INTEGER,
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_evidence TEXT NOT NULL DEFAULT '',
        week_group TEXT,
        confirmed INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
  }

  static Future<void> _createTimelineEventUniqueIndex(Database db) {
    return db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_event_daily_unique '
      'ON character_timeline(character_id, value, substr(created_at, 1, 10)) '
      "WHERE type = 'event'",
    );
  }

  // ═══ FTS5 全文搜索索引 ═══
  // 使用 contentless（content=''）模式：FTS 自存副本，不依賴 content table
  // 的 rebuild 指令。好處是 rebuild 時可以只索引 active 記憶。
  // tokenize=unicode61 對 CJK 逐字拆分——不完美但零依賴。
  /// FTS5 可能在某些 Android 設備的系統 SQLite 中不可用。
  /// 建表失敗時靜默降級——記憶搜尋走 LIKE fallback，不影響核心功能。
  static Future<bool> _createMemoryFts(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
        USING fts5(content, triggers, content='', tokenize='unicode61')
      ''');

      // INSERT trigger：新記憶寫入時自動索引（只索引 active）
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_ai
        AFTER INSERT ON memories WHEN NEW.status = 'active'
        BEGIN
          INSERT INTO memories_fts(rowid, content, triggers)
          VALUES (NEW.id, NEW.content, NEW.triggers);
        END
      ''');

      // 封存/刪除 trigger：status 從 active 變成其他時移除索引
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_au_deactivate
        AFTER UPDATE OF status ON memories
        WHEN OLD.status = 'active' AND NEW.status != 'active'
        BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content, triggers)
          VALUES ('delete', OLD.id, OLD.content, OLD.triggers);
        END
      ''');

      // 恢復 trigger：status 從非 active 變回 active 時重新索引
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_au_activate
        AFTER UPDATE OF status ON memories
        WHEN OLD.status != 'active' AND NEW.status = 'active'
        BEGIN
          INSERT INTO memories_fts(rowid, content, triggers)
          VALUES (NEW.id, NEW.content, NEW.triggers);
        END
      ''');

      // 真正的 DELETE（極少發生，但防禦性加上）
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_ad
        AFTER DELETE ON memories WHEN OLD.status = 'active'
        BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content, triggers)
          VALUES ('delete', OLD.id, OLD.content, OLD.triggers);
        END
      ''');
      return true;
    } catch (e) {
      debugPrint('FTS5 not available on this device, skipping: $e');
      return false;
    }
  }

  static Future<void> _ensureMemoryFts(Database db) async {
    final tableAlreadyExisted = await _tableExists(db, 'memories_fts');
    if (!await _createMemoryFts(db) || tableAlreadyExisted) return;
    try {
      await db.execute('''
        INSERT INTO memories_fts(rowid, content, triggers)
        SELECT id, content, triggers FROM memories WHERE status = 'active'
      ''');
    } catch (e) {
      debugPrint('FTS5 repair failed: $e');
    }
  }

  /// 重建 FTS5 索引：清空後從 memories 表重新填充所有 active 記憶。
  /// 用於：migration 初始化、備份還原後、手動修復。
  /// FTS5 不可用時靜默跳過。
  static Future<void> rebuildMemoryFts(Database db) async {
    // 先確保表和 trigger 存在；FTS5 不可用時直接返回
    if (!await _createMemoryFts(db)) return;
    try {
      // 清空 FTS 索引
      await db.execute(
        "INSERT INTO memories_fts(memories_fts) VALUES ('delete-all')",
      );
      // 重新填充所有 active 記憶
      await db.execute('''
        INSERT INTO memories_fts(rowid, content, triggers)
        SELECT id, content, triggers FROM memories WHERE status = 'active'
      ''');
    } catch (e) {
      debugPrint('FTS5 rebuild failed: $e');
    }
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
      'CREATE INDEX IF NOT EXISTS idx_emo_char_type_time '
          'ON emotion_points(character_id, type, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_grudge_char '
          'ON grudge_seals(character_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_state '
          'ON character_timeline(character_id, key) WHERE type = \'state\'',
      'CREATE INDEX IF NOT EXISTS idx_timeline_event_lookup '
          'ON character_timeline('
          'character_id, type, confirmed, week_group, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_timeline_memory '
          'ON character_timeline(character_id, source_memory_id)',
      'CREATE INDEX IF NOT EXISTS idx_timeline_source_message '
          'ON character_timeline(character_id, source_message_id)',
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
        relation_type TEXT NOT NULL DEFAULT 'related',
        strength REAL NOT NULL DEFAULT 1.0,
        status TEXT NOT NULL DEFAULT 'confirmed',
        source TEXT NOT NULL DEFAULT 'legacy',
        reason TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT '',
        CHECK(memory_id_1 < memory_id_2),
        UNIQUE(character_id, memory_id_1, memory_id_2)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_char ON spider_web_links(character_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_status '
      'ON spider_web_links(character_id, status, relation_type)',
    );

    await _createPendingMemoryActionsTable(db);

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
    if (oldVersion < 34) {
      // 舊 conversation 不能在升級後把「目前全量」自我註記新塞入
      // static prefix。先釘為空，讓它們全部走 dynamic；新建
      // conversation 保持 NULL，首次構建 prompt 時才釘出生快照。
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_static_self_notes',
        'TEXT',
      );
      await db.update('conversations', {
        'pinned_static_self_notes': '',
      }, where: 'pinned_static_self_notes IS NULL');
    }
    if (oldVersion < 35) {
      await _safeAddColumn(
        db,
        'messages',
        'status',
        "TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldVersion < 36) {
      await _migrateToV36(db);
    }
    if (oldVersion < 37) {
      await _migrateToV37(db);
    }
    if (oldVersion < 38) {
      await _migrateToV38(db);
    }
    if (oldVersion < 39) {
      await _createPendingMemoryActionsTable(db);
    }
    if (oldVersion < 40) {
      await _migrateToV40(db);
    }
    if (oldVersion < 41) {
      if (await _tableExists(db, 'characters')) {
        await _safeAddColumn(
          db,
          'characters',
          'whisper_user_text',
          "TEXT DEFAULT ''",
        );
        await _safeAddColumn(
          db,
          'characters',
          'whisper_model_text',
          "TEXT DEFAULT ''",
        );
        await _safeAddColumn(
          db,
          'characters',
          'whisper_source',
          "TEXT DEFAULT 'default'",
        );
        await _safeAddColumn(
          db,
          'characters',
          'whisper_model_override',
          'INTEGER DEFAULT 1',
        );
      }
    }
    if (oldVersion < 42) {
      await _createWebSearchUsageTable(db);
    }
    if (oldVersion < 43) {
      await rebuildMemoryFts(db);
    }

    // Rebuild shared indexes only after every versioned column migration has
    // completed. _migrateToV36 used to call this helper early; once v38 added
    // an index over source_message_id, a real v35 database tried to create the
    // index before v38 had added the column and the entire database open
    // failed. Keeping this at the end also prevents future indexes from being
    // pulled accidentally into an older migration step.
    if (await _hasAllKnownIndexTables(db)) {
      await _createKnownIndexes(db);
    }
  }

  static Future<void> _migrateToV38(Database db) async {
    final hasConversations = await _tableExists(db, 'conversations');
    final hasMessages = await _tableExists(db, 'messages');
    final hasSummaries = await _tableExists(db, 'context_summaries');
    final hasTimeline = await _tableExists(db, 'character_timeline');
    if (hasConversations) {
      await _safeAddColumn(
        db,
        'conversations',
        'summary_cursor_message_id',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (hasTimeline) {
      await _safeAddColumn(
        db,
        'character_timeline',
        'source_message_id',
        'INTEGER',
      );
      await _safeAddColumn(
        db,
        'character_timeline',
        'source_message_ids',
        "TEXT NOT NULL DEFAULT '[]'",
      );
      await _safeAddColumn(
        db,
        'character_timeline',
        'source_evidence',
        "TEXT NOT NULL DEFAULT ''",
      );
    }

    // Existing summary blocks predate the explicit cursor. Recover the last
    // message that was already covered by an automatic window summary. Manual
    // summaries are deliberately excluded because they may cover an arbitrary
    // user-selected excerpt rather than the conversation prefix.
    if (hasConversations && hasMessages && hasSummaries) {
      await db.execute('''
        UPDATE conversations
        SET summary_cursor_message_id = COALESCE((
          SELECT MAX(message.id)
          FROM messages AS message
          WHERE message.conversation_id = conversations.id
            AND message.created_at <= (
              SELECT MAX(summary.created_at)
              FROM context_summaries AS summary
              WHERE summary.source_conversation_id = conversations.id
                AND summary.content NOT LIKE '【手動摘要】%'
                AND summary.content NOT LIKE '[Manual Summary]%'
            )
        ), 0)
        WHERE COALESCE(summary_cursor_message_id, 0) = 0
      ''');
    }

    if (hasTimeline) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_timeline_source_message '
        'ON character_timeline(character_id, source_message_id)',
      );
    }
  }

  static Future<void> _migrateToV40(Database db) async {
    if (!await _tableExists(db, 'spider_web_links')) {
      await _createMemoryTables(db);
      return;
    }
    await _safeAddColumn(
      db,
      'spider_web_links',
      'relation_type',
      "TEXT NOT NULL DEFAULT 'related'",
    );
    await _safeAddColumn(
      db,
      'spider_web_links',
      'strength',
      'REAL NOT NULL DEFAULT 1.0',
    );
    await _safeAddColumn(
      db,
      'spider_web_links',
      'status',
      "TEXT NOT NULL DEFAULT 'confirmed'",
    );
    await _safeAddColumn(
      db,
      'spider_web_links',
      'source',
      "TEXT NOT NULL DEFAULT 'legacy'",
    );
    await _safeAddColumn(
      db,
      'spider_web_links',
      'reason',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'spider_web_links',
      'updated_at',
      "TEXT NOT NULL DEFAULT ''",
    );
    await db.rawUpdate(
      "UPDATE spider_web_links SET updated_at = created_at "
      "WHERE updated_at = ''",
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_status '
      'ON spider_web_links(character_id, status, relation_type)',
    );
  }

  static Future<void> _createPendingMemoryActionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_memory_actions (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        mode TEXT NOT NULL,
        action TEXT NOT NULL,
        source TEXT NOT NULL,
        source_conversation_id TEXT,
        source_message_id INTEGER,
        target_ids_json TEXT NOT NULL DEFAULT '[]',
        payload_json TEXT NOT NULL DEFAULT '{}',
        base_versions_json TEXT NOT NULL DEFAULT '{}',
        fingerprint TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        seen_at TEXT,
        resolved_at TEXT,
        error TEXT NOT NULL DEFAULT '',
        result_json TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_memory_character_status '
      'ON pending_memory_actions(character_id, status, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_memory_source_message '
      'ON pending_memory_actions(source_conversation_id, source_message_id)',
    );
  }

  static Future<void> _migrateToV37(Database db) async {
    if (!await _tableExists(db, 'character_timeline')) return;

    // If any copy was confirmed, retain that state on the oldest row before
    // collapsing same-day duplicates produced by the old keyword scanner.
    await db.execute('''
      UPDATE character_timeline
      SET confirmed = 1
      WHERE type = 'event' AND EXISTS (
        SELECT 1
        FROM character_timeline AS duplicate
        WHERE duplicate.type = 'event'
          AND duplicate.character_id = character_timeline.character_id
          AND duplicate.value = character_timeline.value
          AND substr(duplicate.created_at, 1, 10) =
              substr(character_timeline.created_at, 1, 10)
          AND duplicate.confirmed = 1
      )
    ''');
    await db.execute('''
      DELETE FROM character_timeline
      WHERE type = 'event' AND id NOT IN (
        SELECT MIN(id)
        FROM character_timeline
        WHERE type = 'event'
        GROUP BY character_id, value, substr(created_at, 1, 10)
      )
    ''');

    // Repair the old simplified calendar-week calculation, including dates
    // at ISO week-year boundaries.
    final events = await db.query(
      'character_timeline',
      columns: ['id', 'created_at'],
      where: "type = 'event'",
    );
    final batch = db.batch();
    for (final event in events) {
      final id = event['id'] as int?;
      final createdAt = DateTime.tryParse(
        event['created_at']?.toString() ?? '',
      );
      if (id == null || createdAt == null) continue;
      batch.update(
        'character_timeline',
        {'week_group': isoWeekGroup(createdAt)},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
    await _createTimelineEventUniqueIndex(db);
  }

  static Future<void> _migrateToV36(Database db) async {
    final hadSpiderLinks = await _tableExists(db, 'spider_web_links');
    await db.execute('DROP TABLE IF EXISTS spider_web_links_v36');
    await db.execute('''
      CREATE TABLE spider_web_links_v36 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        memory_id_1 INTEGER NOT NULL,
        memory_id_2 INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        CHECK(memory_id_1 < memory_id_2),
        UNIQUE(character_id, memory_id_1, memory_id_2)
      )
    ''');
    if (hadSpiderLinks) {
      await db.execute('''
        INSERT OR IGNORE INTO spider_web_links_v36
          (id, character_id, memory_id_1, memory_id_2, created_at)
        SELECT
          id,
          character_id,
          CASE WHEN memory_id_1 < memory_id_2 THEN memory_id_1 ELSE memory_id_2 END,
          CASE WHEN memory_id_1 < memory_id_2 THEN memory_id_2 ELSE memory_id_1 END,
          created_at
        FROM spider_web_links
        WHERE memory_id_1 != memory_id_2
        ORDER BY id ASC
      ''');
      await db.execute('DROP TABLE spider_web_links');
    }
    await db.execute(
      'ALTER TABLE spider_web_links_v36 RENAME TO spider_web_links',
    );

    // Keep the oldest saved row when an old database already contains a
    // double-tap duplicate, then let the unique index prevent recurrence.
    if (await _tableExists(db, 'saved_messages')) {
      await db.execute('''
        DELETE FROM saved_messages
        WHERE id NOT IN (
          SELECT MIN(id) FROM saved_messages GROUP BY message_id
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_message_unique '
        'ON saved_messages(message_id)',
      );
    }

    for (final index in const [
      'idx_messages_conv',
      'idx_mem_char_mode',
      'idx_saved_char',
      'idx_conv_char',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $index');
    }
  }

  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: [table],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<bool> _hasAllKnownIndexTables(Database db) async {
    const required = {
      'messages',
      'conversations',
      'memories',
      'spider_web_links',
      'pending_memory_actions',
      'backpack_items',
      'archive',
      'sticky_notes',
      'usage_logs',
      'web_search_usage_logs',
      'saved_voices',
      'saved_messages',
      'context_summaries',
      'context_keywords',
      'emotion_points',
      'grudge_seals',
      'character_timeline',
    };
    final rows = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table'",
    );
    final actual = rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
    return actual.containsAll(required);
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
}
