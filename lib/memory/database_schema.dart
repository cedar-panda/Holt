part of 'database.dart';

enum _MemoryFtsBackend { fts5Trigram, fts5Unicode, fts4 }

extension on _MemoryFtsBackend {
  bool get isFts5 => this != _MemoryFtsBackend.fts4;
}

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
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        user_persona_id TEXT,
        user_persona_snapshot TEXT NOT NULL DEFAULT '',
        worldbook_set_id TEXT,
        window_summary_id TEXT DEFAULT '',
        summary_cursor_message_id INTEGER NOT NULL DEFAULT 0,
        pinned_static_summary TEXT,
        pinned_static_self_notes TEXT,
        pinned_coin_snapshot_char INTEGER,
        pinned_coin_snapshot_user INTEGER,
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
        image_paths_json TEXT NOT NULL DEFAULT '[]',
        split_mode INTEGER DEFAULT 0,
        memory_log TEXT DEFAULT '',
        web_search_trace_json TEXT DEFAULT '',
        email_draft_json TEXT DEFAULT '',
        persona_card_json TEXT DEFAULT '',
        cache_hit INTEGER DEFAULT 0,
        summary_recorded INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 1,
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
    await _createUserPersonaTables(db);
    await _createNotesTable(db);
    await _createUsageTable(db);
    await _createWebSearchUsageTable(db);
    await _createVoiceTable(db);
    await _createSavedMessagesTable(db);
    await _createContextSummaryTables(db);
    await _createEmotionTables(db);
    await _createCharacterTimelineTable(db);
    await _createRpCharacterTimelineTable(db);
    await _createRpStoryTables(db);
    await _createRpStorylineTables(db);
    await _createRevisionIntegrityTables(db);
    await _createContextSummaryRepairTable(db);
    await _createRpStoryStateTables(db);
    await _createRpStoryProjectionRevisionTable(db);
    await _createRpWorldbookTables(db);
    await _createCharacterDiaryTable(db);
    await _createCharacterSelfNotesTable(db);
    await _createMemoryEmbeddingTable(db);
    await DatabaseHelper._createCharacterSignatureTable(db);
    await _createChatDiagnosticsTable(db);
    await _createKnownIndexes(db);
    await _createContextModeIndexes(db);
    await _createSavedMessageUniqueIndex(db);
    await _createTimelineEventUniqueIndex(db);
    await _createMemoryFts(db);
  }

  /// Repairs schema objects that may be absent even when user_version already
  /// matches the app. This covers same-version additions and backups that
  /// intentionally omit derived FTS tables.
  static Future<void> _ensureRuntimeSchema(Database db) async {
    await _createContextSummaryTables(db);
    await _createPendingMemoryActionsTable(db);
    await _createWebSearchUsageTable(db);
    await _createRpCharacterTimelineTable(db);
    await _createRpStoryTables(db);
    await _createRpStorylineTables(db);
    await _createRevisionIntegrityTables(db);
    await _createContextSummaryRepairTable(db);
    await _createRpStoryStateTables(db);
    await _createRpStoryProjectionRevisionTable(db);
    await _createRpWorldbookTables(db);
    await _createCharacterDiaryTable(db);
    await _createCharacterSelfNotesTable(db);
    await DatabaseHelper._backfillCharacterSelfNotes(db);
    await _createMemoryEmbeddingTable(db);
    await DatabaseHelper._createCharacterSignatureTable(db);
    await _createChatDiagnosticsTable(db);
    await _createUserPersonaTables(db);
    if (await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'web_search_trace_json',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'messages',
        'email_draft_json',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'messages',
        'persona_card_json',
        "TEXT DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'messages',
        'summary_recorded',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _safeAddColumn(
        db,
        'messages',
        'image_paths_json',
        "TEXT NOT NULL DEFAULT '[]'",
      );
      await _safeAddColumn(
        db,
        'messages',
        'revision',
        'INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (await _tableExists(db, 'usage_logs')) {
      await _safeAddColumn(
        db,
        'usage_logs',
        'conversation_id',
        "TEXT NOT NULL DEFAULT ''",
      );
    }
    if (await _tableExists(db, 'rp_story_characters')) {
      await _safeAddColumn(
        db,
        'rp_story_characters',
        'entity_key',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'rp_story_characters',
        'identities_json',
        "TEXT NOT NULL DEFAULT '[]'",
      );
      await _safeAddColumn(
        db,
        'rp_story_characters',
        'core_motivation',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'rp_story_characters',
        'current_stance',
        "TEXT NOT NULL DEFAULT ''",
      );
    }
    if (await _tableExists(db, 'rp_story_relationships')) {
      await _safeAddColumn(
        db,
        'rp_story_relationships',
        'from_entity_key',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'rp_story_relationships',
        'to_entity_key',
        "TEXT NOT NULL DEFAULT ''",
      );
      for (final column in const <(String, String)>[
        ('closeness_catalyst', "TEXT NOT NULL DEFAULT ''"),
        ('forms_of_address_json', "TEXT NOT NULL DEFAULT '[]'"),
        ('shared_secrets_json', "TEXT NOT NULL DEFAULT '[]'"),
        ('conflicts_json', "TEXT NOT NULL DEFAULT '[]'"),
        ('knowledge_scope_json', "TEXT NOT NULL DEFAULT '[]'"),
      ]) {
        await _safeAddColumn(
          db,
          'rp_story_relationships',
          column.$1,
          column.$2,
        );
      }
    }
    if (await _tableExists(db, 'context_summaries')) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'display_anchor_message_id',
        'INTEGER',
      );
      await _safeAddColumn(
        db,
        'context_summaries',
        'archived',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureSummaryRevisionColumns(db);
    }
    if (await _tableExists(db, 'conversations')) {
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_coin_snapshot_char',
        'INTEGER',
      );
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_coin_snapshot_user',
        'INTEGER',
      );
    }
    await _ensureMemoryFts(db);
  }

  static Future<void> _createChatDiagnosticsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_diagnostics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        source_message_id INTEGER NOT NULL,
        anchor_message_id INTEGER NOT NULL,
        category TEXT NOT NULL,
        status_code INTEGER,
        provider TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        raw_log TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
          ON DELETE CASCADE,
        FOREIGN KEY (source_message_id) REFERENCES messages(id)
          ON DELETE CASCADE,
        UNIQUE(conversation_id, source_message_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chat_diagnostic_anchor '
      'ON chat_diagnostics(conversation_id, anchor_message_id)',
    );
  }

  static Future<void> _createCharacterDiaryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_diaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        diary_date TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL,
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_id INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, diary_date),
        FOREIGN KEY(character_id) REFERENCES characters(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_character_diaries_character_date '
      'ON character_diaries(character_id, diary_date DESC)',
    );
  }

  /// Derived vector index. Portable backups may preserve valid rows to avoid
  /// paid re-embedding after restore. Content hashes and the provider/model
  /// keyspace still make stale rows self-invalidating.
  static Future<void> _createMemoryEmbeddingTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_embeddings (
        memory_id INTEGER NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        dimensions INTEGER NOT NULL,
        vector_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(memory_id, provider, model),
        FOREIGN KEY(memory_id) REFERENCES memories(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memory_embeddings_model '
      'ON memory_embeddings(provider, model, memory_id)',
    );
  }

  static Future<void> _createRpStoryTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_characters (
        id TEXT PRIMARY KEY,
        entity_key TEXT NOT NULL DEFAULT '',
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        normalized_name TEXT NOT NULL,
        name TEXT NOT NULL,
        aliases_json TEXT NOT NULL DEFAULT '[]',
        identities_json TEXT NOT NULL DEFAULT '[]',
        gender TEXT NOT NULL DEFAULT '',
        identity TEXT NOT NULL DEFAULT '',
        relation_to_leads TEXT NOT NULL DEFAULT '',
        personality TEXT NOT NULL DEFAULT '',
        appearance TEXT NOT NULL DEFAULT '',
        first_scene TEXT NOT NULL DEFAULT '',
        faction TEXT NOT NULL DEFAULT '',
        core_motivation TEXT NOT NULL DEFAULT '',
        current_stance TEXT NOT NULL DEFAULT '',
        recurrence TEXT NOT NULL DEFAULT 'unknown',
        tier TEXT NOT NULL DEFAULT 'backstage',
        is_important INTEGER NOT NULL DEFAULT 0,
        mention_count INTEGER NOT NULL DEFAULT 0,
        last_seen_at TEXT NOT NULL,
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        evidence TEXT NOT NULL DEFAULT '',
        tags_json TEXT NOT NULL DEFAULT '[]',
        worldbook_entry_id TEXT,
        user_edited INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, continuity_id, normalized_name)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_relationships (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        from_name TEXT NOT NULL,
        to_name TEXT NOT NULL,
        from_entity_key TEXT NOT NULL DEFAULT '',
        to_entity_key TEXT NOT NULL DEFAULT '',
        normalized_edge TEXT NOT NULL,
        direction TEXT NOT NULL DEFAULT 'mutual',
        current_relation TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL DEFAULT '',
        closeness_catalyst TEXT NOT NULL DEFAULT '',
        forms_of_address_json TEXT NOT NULL DEFAULT '[]',
        shared_secrets_json TEXT NOT NULL DEFAULT '[]',
        conflicts_json TEXT NOT NULL DEFAULT '[]',
        knowledge_scope_json TEXT NOT NULL DEFAULT '[]',
        visibility TEXT NOT NULL DEFAULT 'unknown',
        story_time TEXT NOT NULL DEFAULT '',
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_summary_id INTEGER,
        evidence TEXT NOT NULL DEFAULT '',
        user_edited INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, continuity_id, normalized_edge)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_relationship_events (
        id TEXT PRIMARY KEY,
        relationship_id TEXT NOT NULL,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        change_text TEXT NOT NULL,
        story_time TEXT NOT NULL DEFAULT '',
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_summary_id INTEGER,
        evidence TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_character_scope '
      'ON rp_story_characters(character_id, continuity_id, tier, is_important)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_relation_scope '
      'ON rp_story_relationships(character_id, continuity_id, updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_relation_event '
      'ON rp_story_relationship_events(relationship_id, created_at ASC)',
    );
  }

  /// Story-line registry. The established continuity_id remains the stable
  /// storage key during the migration, so old windows and every RP table stay
  /// aligned instead of introducing a second unsynchronised identifier.
  static Future<void> _createRpStorylineTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_storylines (
        character_id TEXT NOT NULL,
        id TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active'
          CHECK(status IN ('active', 'archived')),
        is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(character_id, id),
        FOREIGN KEY(character_id) REFERENCES characters(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_storylines_character_status '
      'ON rp_storylines(character_id, status, updated_at DESC)',
    );
  }

  /// Story-scoped mutable state. This layer is deliberately separate from the
  /// user-authored persona and character cards: an injury, disguise or promise
  /// belongs to one RP storyline and must not mutate the reusable base card.
  static Future<void> _createRpStoryStateTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_entity_aliases (
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        entity_key TEXT NOT NULL,
        normalized_alias TEXT NOT NULL,
        display_alias TEXT NOT NULL,
        alias_type TEXT NOT NULL DEFAULT 'name'
          CHECK(alias_type IN ('name', 'identity', 'title', 'other')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(character_id, continuity_id, entity_key, normalized_alias)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_alias_lookup '
      'ON rp_story_entity_aliases(character_id, continuity_id, normalized_alias)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_states (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        state_key TEXT NOT NULL,
        state_type TEXT NOT NULL
          CHECK(state_type IN ('scene', 'promise', 'body', 'identity',
            'knowledge', 'plot', 'item')),
        subject_entity_key TEXT NOT NULL DEFAULT '',
        object_entity_key TEXT NOT NULL DEFAULT '',
        narrative_layer TEXT NOT NULL DEFAULT 'main'
          CHECK(narrative_layer IN ('main', 'memory', 'dream',
            'hypothetical', 'au', 'ooc')),
        value TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT '',
        story_time TEXT NOT NULL DEFAULT '',
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_summary_id INTEGER,
        evidence TEXT NOT NULL DEFAULT '',
        user_edited INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, continuity_id, state_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_state_scope '
      'ON rp_story_states(character_id, continuity_id, state_type, updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_story_state_entity '
      'ON rp_story_states(character_id, continuity_id, subject_entity_key)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_rp_story_entity_key '
      'ON rp_story_characters(character_id, continuity_id, entity_key) '
      "WHERE entity_key != ''",
    );
  }

  /// Version history for model-written RP character and relationship rows.
  /// It lets an edited or re-rolled message unwind only the invalid summary
  /// revisions without discarding an older valid projection.
  static Future<void> _createRpStoryProjectionRevisionTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_story_projection_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        projection_table TEXT NOT NULL
          CHECK(projection_table IN ('character', 'relationship')),
        projection_id TEXT NOT NULL,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        source_summary_id INTEGER NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN ('create', 'update')),
        snapshot_json TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        UNIQUE(projection_table, projection_id, source_summary_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_projection_revision_summary '
      'ON rp_story_projection_revisions(source_summary_id, id DESC)',
    );
  }

  /// Persistent repair queue for summaries invalidated by editing, deletion,
  /// or re-roll. The old summary row remains the immutable audit checkpoint;
  /// this table records the source span that must be rebuilt outside the
  /// SQLite transaction, where calling the configured summary model is safe.
  static Future<void> _createContextSummaryRepairTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_summary_repairs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        original_summary_id INTEGER NOT NULL UNIQUE,
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main',
        source_conversation_id TEXT NOT NULL,
        source_message_start_id INTEGER NOT NULL,
        source_message_end_id INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'running', 'failed', 'completed')),
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_repair_scope '
      'ON context_summary_repairs('
      'character_id, context_mode, continuity_id, status, original_summary_id)',
    );
  }

  /// Storyline-scoped world knowledge generated by a separate model pass.
  /// Source summary ids are provenance only: later summary recycling or
  /// invalidation does not silently erase an accepted world rule.
  static Future<void> _createRpWorldbookTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_worldbook_entries (
        id TEXT PRIMARY KEY,
        entry_key TEXT NOT NULL,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'other',
        content TEXT NOT NULL,
        scope TEXT NOT NULL DEFAULT 'global',
        visibility TEXT NOT NULL DEFAULT 'public',
        status TEXT NOT NULL DEFAULT 'active'
          CHECK(status IN ('active', 'archived')),
        ended_reason TEXT NOT NULL DEFAULT '',
        triggers_json TEXT NOT NULL DEFAULT '[]',
        source_summary_ids TEXT NOT NULL DEFAULT '[]',
        user_edited INTEGER NOT NULL DEFAULT 0 CHECK(user_edited IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, continuity_id, entry_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_worldbook_scope '
      'ON rp_worldbook_entries(character_id, continuity_id, status, updated_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_worldbook_sync_state (
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        last_processed_summary_id INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(character_id, continuity_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_worldbook_review_items (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main',
        kind TEXT NOT NULL CHECK(kind IN ('possible_duplicate', 'conflict')),
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'resolved', 'dismissed')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rp_worldbook_review_scope '
      'ON rp_worldbook_review_items(character_id, continuity_id, status, created_at DESC)',
    );
  }

  static Future<void> _createRevisionIntegrityTables(Database db) async {
    if (await _tableExists(db, 'messages')) {
      await _safeAddColumn(db, 'messages', 'reply_to_message_id', 'INTEGER');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL,
        conversation_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        snapshot_json TEXT NOT NULL,
        archive_reason TEXT NOT NULL,
        archived_at TEXT NOT NULL,
        UNIQUE(message_id, revision)
      )
    ''');
    await _safeAddColumn(
      db,
      'message_revisions',
      'reply_user_message_id',
      'INTEGER',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reply_revision_user '
      'ON message_revisions(conversation_id, reply_user_message_id, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_message_revisions_message '
      'ON message_revisions(message_id, revision DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_message_revisions_conversation '
      'ON message_revisions(conversation_id, archived_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_rejection_tombstones (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main',
        mode TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT '',
        fact_key TEXT NOT NULL,
        candidate_json TEXT NOT NULL,
        source_proposal_id TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(character_id, context_mode, continuity_id, mode, fact_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_memory_rejection_scope '
      'ON memory_rejection_tombstones('
      'character_id, context_mode, continuity_id, mode, created_at DESC)',
    );
    await _ensureSummaryRevisionColumns(db);
  }

  static Future<void> _ensureSummaryRevisionColumns(Database db) async {
    if (!await _tableExists(db, 'context_summaries')) return;
    await _safeAddColumn(
      db,
      'context_summaries',
      'parent_summary_id',
      'INTEGER',
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'replaces_summary_id',
      'INTEGER',
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'source_message_start_id',
      'INTEGER',
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'source_message_end_id',
      'INTEGER',
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'revision',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'revision_status',
      "TEXT NOT NULL DEFAULT 'valid'",
    );
    await _safeAddColumn(db, 'context_summaries', 'invalidated_at', 'TEXT');
    await _safeAddColumn(
      db,
      'context_summaries',
      'invalidation_reason',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'story_time_text',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'context_summaries',
      'source_span_status',
      "TEXT NOT NULL DEFAULT 'unknown'",
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_parent '
      'ON context_summaries(parent_summary_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_replacement '
      'ON context_summaries(replaces_summary_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_revision_scope '
      'ON context_summaries('
      'character_id, context_mode, continuity_id, revision_status, id)',
    );
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
        conversation_id TEXT NOT NULL DEFAULT '',
        prompt_tokens INTEGER DEFAULT 0,
        completion_tokens INTEGER DEFAULT 0,
        cache_hit_tokens INTEGER DEFAULT 0,
        cache_creation_tokens INTEGER DEFAULT 0,
        estimated_cost REAL DEFAULT 0.0,
        request_kind TEXT NOT NULL DEFAULT 'unknown',
        cost_known INTEGER NOT NULL DEFAULT 0
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
          CHECK(provider IN ('openRouter', 'gemini', 'xai', 'relay')),
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
        signature TEXT DEFAULT '',
        draw_anchor_user TEXT DEFAULT '',
        draw_anchor_char TEXT DEFAULT '',
        draw_style TEXT DEFAULT '',
        is_spider_web_enabled INTEGER DEFAULT 0,
        preferred_context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(preferred_context_mode IN ('daily', 'rp')),
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

  static Future<void> _createUserPersonaTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_personas (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL DEFAULT '',
        pronouns TEXT NOT NULL DEFAULT '',
        bio TEXT NOT NULL DEFAULT '',
        avatar_path TEXT NOT NULL DEFAULT '',
        prompt_content TEXT NOT NULL DEFAULT '',
        is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0, 1)),
        is_archived INTEGER NOT NULL DEFAULT 0 CHECK(is_archived IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO user_personas (
        id, display_name, pronouns, bio, avatar_path, prompt_content,
        is_default, is_archived, created_at, updated_at
      ) VALUES (
        'default', '', '', '', '', '', 1, 0,
        strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_persona_bindings (
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        user_persona_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(character_id, context_mode, continuity_id),
        FOREIGN KEY(character_id) REFERENCES characters(id) ON DELETE CASCADE,
        FOREIGN KEY(user_persona_id) REFERENCES user_personas(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_persona_binding_persona '
      'ON character_persona_bindings(user_persona_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_persona_mode_overrides (
        user_persona_id TEXT NOT NULL,
        context_mode TEXT NOT NULL CHECK(context_mode IN ('daily', 'rp')),
        display_name TEXT,
        pronouns TEXT,
        bio TEXT,
        prompt_content TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(user_persona_id, context_mode),
        FOREIGN KEY(user_persona_id) REFERENCES user_personas(id)
          ON DELETE CASCADE
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

  /// RP chronology is physically separate from the daily timeline so later
  /// candidate and dedupe rules cannot accidentally cross domains.
  static Future<void> _createRpCharacterTimelineTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rp_character_timeline (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        source_conversation_id TEXT,
        type TEXT NOT NULL DEFAULT 'event'
          CHECK(type IN ('state', 'event')),
        key TEXT,
        event_key TEXT NOT NULL DEFAULT '',
        narrative_layer TEXT NOT NULL DEFAULT 'main'
          CHECK(narrative_layer IN ('main', 'memory', 'dream',
            'hypothetical', 'au')),
        subject_entity_ids TEXT NOT NULL DEFAULT '[]',
        value TEXT NOT NULL,
        story_time_text TEXT NOT NULL DEFAULT '',
        sequence_order INTEGER NOT NULL DEFAULT 0,
        scene TEXT NOT NULL DEFAULT '',
        source_message_id INTEGER,
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_evidence TEXT NOT NULL DEFAULT '',
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

  // ═══ 全文搜索索引 ═══
  // 正式執行環境使用 App 內附、啟用 FTS5 的 SQLite。trigram 是記憶文字
  // 搜尋的固定契約，不再依手機系統 SQLite 能力靜默降級。舊 backend 的
  // enum/search 支援只用於 v66 遷移及隔離測試資料庫。
  static Future<_MemoryFtsBackend?> _createMemoryFts(Database db) async {
    final existing = await _detectMemoryFtsBackend(db);
    if (existing != null) {
      await _tryCreateMemoryFtsTriggers(db, existing);
      return existing;
    }

    // DROP TABLE 不會保證移除掛在 memories 上的舊 trigger。先清理後再依
    // 實際 backend 建立，避免 FTS5 delete 指令被錯用到 FTS4。
    await _dropMemoryFtsTriggers(db);

    try {
      await db.execute('''
        CREATE VIRTUAL TABLE memories_fts
        USING fts5(content, triggers, content='', tokenize='trigram')
      ''');
      await _tryCreateMemoryFtsTriggers(db, _MemoryFtsBackend.fts5Trigram);
      return _MemoryFtsBackend.fts5Trigram;
    } catch (error) {
      throw StateError('Bundled SQLite lacks required FTS5 trigram: $error');
    }
  }

  static Future<_MemoryFtsBackend?> _detectMemoryFtsBackend(Database db) async {
    final rows = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['memories_fts'],
    );
    if (rows.isEmpty) return null;
    final sql = (rows.first['sql'] as String? ?? '').toLowerCase();
    if (sql.contains('using fts5') && sql.contains('trigram')) {
      return _MemoryFtsBackend.fts5Trigram;
    }
    if (sql.contains('using fts5')) return _MemoryFtsBackend.fts5Unicode;
    if (sql.contains('using fts4')) return _MemoryFtsBackend.fts4;
    return null;
  }

  static Future<void> _dropMemoryFtsTriggers(Database db) async {
    for (final name in const <String>[
      'memories_fts_ai',
      'memories_fts_au_deactivate',
      'memories_fts_au_activate',
      'memories_fts_au_content',
      'memories_fts_ad',
    ]) {
      await db.execute('DROP TRIGGER IF EXISTS $name');
    }
  }

  static Future<void> _createMemoryFtsTriggers(
    Database db,
    _MemoryFtsBackend backend,
  ) async {
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_fts_ai
      AFTER INSERT ON memories WHEN NEW.status = 'active'
      BEGIN
        INSERT INTO memories_fts(rowid, content, triggers)
        VALUES (NEW.id, NEW.content, NEW.triggers);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_fts_au_activate
      AFTER UPDATE OF status ON memories
      WHEN OLD.status != 'active' AND NEW.status = 'active'
      BEGIN
        INSERT INTO memories_fts(rowid, content, triggers)
        VALUES (NEW.id, NEW.content, NEW.triggers);
      END
    ''');

    if (backend.isFts5) {
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_au_deactivate
        AFTER UPDATE OF status ON memories
        WHEN OLD.status = 'active' AND NEW.status != 'active'
        BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content, triggers)
          VALUES ('delete', OLD.id, OLD.content, OLD.triggers);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_au_content
        AFTER UPDATE OF content, triggers ON memories
        WHEN OLD.status = 'active' AND NEW.status = 'active'
        BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content, triggers)
          VALUES ('delete', OLD.id, OLD.content, OLD.triggers);
          INSERT INTO memories_fts(rowid, content, triggers)
          VALUES (NEW.id, NEW.content, NEW.triggers);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS memories_fts_ad
        AFTER DELETE ON memories WHEN OLD.status = 'active'
        BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, content, triggers)
          VALUES ('delete', OLD.id, OLD.content, OLD.triggers);
        END
      ''');
      return;
    }

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_fts_au_deactivate
      AFTER UPDATE OF status ON memories
      WHEN OLD.status = 'active' AND NEW.status != 'active'
      BEGIN
        DELETE FROM memories_fts WHERE rowid = OLD.id;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_fts_au_content
      AFTER UPDATE OF content, triggers ON memories
      WHEN OLD.status = 'active' AND NEW.status = 'active'
      BEGIN
        DELETE FROM memories_fts WHERE rowid = OLD.id;
        INSERT INTO memories_fts(rowid, content, triggers)
        VALUES (NEW.id, NEW.content, NEW.triggers);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS memories_fts_ad
      AFTER DELETE ON memories WHEN OLD.status = 'active'
      BEGIN
        DELETE FROM memories_fts WHERE rowid = OLD.id;
      END
    ''');
  }

  static Future<void> _tryCreateMemoryFtsTriggers(
    Database db,
    _MemoryFtsBackend backend,
  ) async {
    try {
      await _createMemoryFtsTriggers(db, backend);
    } catch (error) {
      // Some synthetic migration fixtures intentionally begin before the
      // memories table exists. A later runtime repair will install triggers.
      debugPrint('Memory FTS triggers pending schema completion: $error');
    }
  }

  static Future<void> _ensureMemoryFts(Database db) async {
    if (!await _memoryFtsSourceReady(db)) return;
    final existing = await _detectMemoryFtsBackend(db);
    if (existing != null && existing != _MemoryFtsBackend.fts5Trigram) {
      await _dropMemoryFtsTriggers(db);
      await db.execute('DROP TABLE IF EXISTS memories_fts');
    }
    final tableAlreadyExisted =
        await _detectMemoryFtsBackend(db) == _MemoryFtsBackend.fts5Trigram;
    final backend = await _createMemoryFts(db);
    if (backend != _MemoryFtsBackend.fts5Trigram) {
      throw StateError('Memory search requires FTS5 trigram');
    }
    if (tableAlreadyExisted) return;
    await db.execute('''
      INSERT INTO memories_fts(rowid, content, triggers)
      SELECT id, content, triggers FROM memories WHERE status = 'active'
    ''');
  }

  /// 重建全文索引：清空後從 memories 表重新填充所有 active 記憶。
  /// 用於：migration 初始化、備份還原後、手動修復。
  /// App 內附的 SQLite 若不具備 FTS5 trigram，直接回報錯誤而非降級。
  static Future<void> rebuildMemoryFts(Database db) async {
    if (!await _memoryFtsSourceReady(db)) return;
    final existing = await _detectMemoryFtsBackend(db);
    if (existing != null && existing != _MemoryFtsBackend.fts5Trigram) {
      await _dropMemoryFtsTriggers(db);
      await db.execute('DROP TABLE IF EXISTS memories_fts');
    }
    final backend = await _createMemoryFts(db);
    if (backend != _MemoryFtsBackend.fts5Trigram) {
      throw StateError('Memory search requires FTS5 trigram');
    }
    await db.execute(
      "INSERT INTO memories_fts(memories_fts) VALUES ('delete-all')",
    );
    await db.execute('''
      INSERT INTO memories_fts(rowid, content, triggers)
      SELECT id, content, triggers FROM memories WHERE status = 'active'
    ''');
  }

  static Future<bool> _memoryFtsSourceReady(Database db) async {
    if (!await _tableExists(db, 'memories')) return false;
    final columns = await _columnNames(db, 'memories');
    return columns.containsAll(const <String>{
      'id',
      'content',
      'triggers',
      'status',
    });
  }

  /// v61 將舊 unicode61 索引升級為 trigram。先用臨時表探測
  /// SQLite 能力，只有探測成功才會拆掉現有索引；舊 Android 仍保留
  /// 可用的 FTS5 unicode61 / FTS4，並重建 active 記憶。
  static Future<void> _migrateMemoryFtsToTrigram(Database db) async {
    if (!await _tableExists(db, 'memories')) return;
    final columns = await _columnNames(db, 'memories');
    if (!columns.containsAll(const <String>{
      'id',
      'content',
      'triggers',
      'status',
    })) {
      return;
    }
    const probe = 'memories_fts_trigram_probe_v61';
    var supportsTrigram = false;
    try {
      await db.execute('DROP TABLE IF EXISTS $probe');
      await db.execute('''
        CREATE VIRTUAL TABLE $probe
        USING fts5(content, tokenize='trigram')
      ''');
      supportsTrigram = true;
    } catch (error) {
      debugPrint('SQLite trigram tokenizer unavailable: $error');
    } finally {
      try {
        await db.execute('DROP TABLE IF EXISTS $probe');
      } catch (_) {}
    }

    final current = await _detectMemoryFtsBackend(db);
    if (supportsTrigram && current != _MemoryFtsBackend.fts5Trigram) {
      await _dropMemoryFtsTriggers(db);
      await db.execute('DROP TABLE IF EXISTS memories_fts');
    }
    await rebuildMemoryFts(db);
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
      'CREATE INDEX IF NOT EXISTS idx_usage_kind_ts '
          'ON usage_logs(request_kind, timestamp DESC)',
      'CREATE INDEX IF NOT EXISTS idx_usage_conversation_kind '
          'ON usage_logs(conversation_id, request_kind, timestamp DESC)',
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

  static Future<void> _createContextModeIndexes(Database db) async {
    const statements = <String>[
      'CREATE INDEX IF NOT EXISTS idx_mem_char_context_time '
          'ON memories('
          'character_id, context_mode, continuity_id, status, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_context_summary_scope_time '
          'ON context_summaries('
          'character_id, context_mode, continuity_id, created_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_context_keyword_scope_time '
          'ON context_keywords('
          'character_id, context_mode, continuity_id, created_at DESC)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_rp_timeline_state '
          'ON rp_character_timeline(character_id, continuity_id, key) '
          "WHERE type = 'state'",
      'CREATE INDEX IF NOT EXISTS idx_rp_timeline_event_lookup '
          'ON rp_character_timeline('
          'character_id, continuity_id, type, confirmed, sequence_order, '
          'created_at)',
      'CREATE INDEX IF NOT EXISTS idx_rp_timeline_conversation '
          'ON rp_character_timeline('
          'source_conversation_id, source_message_id)',
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
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
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
        UNIQUE(character_id, memory_id_1, memory_id_2, relation_type)
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
    if (oldVersion < 45 && await _tableExists(db, 'web_search_usage_logs')) {
      await _migrateWebSearchUsageProviders(db);
    }
    if (oldVersion < 43) {
      await rebuildMemoryFts(db);
    }
    if (oldVersion < 44 && await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'web_search_trace_json',
        "TEXT DEFAULT ''",
      );
    }
    if (oldVersion < 46 && await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'email_draft_json',
        "TEXT DEFAULT ''",
      );
    }
    if (oldVersion < 47 && await _tableExists(db, 'characters')) {
      await _safeAddColumn(db, 'characters', 'signature', "TEXT DEFAULT ''");
    }
    if (oldVersion < 48) {
      await _migrateToV48(db);
    }
    if (oldVersion < 49) {
      await _migrateToV49(db);
    }
    if (oldVersion < 50) {
      await _migrateToV50(db);
    }
    if (oldVersion < 51) {
      await _createUserPersonaTables(db);
    }
    if (oldVersion < 52) {
      await _migrateToV52(db);
    }
    if (oldVersion < 53 && await _tableExists(db, 'conversations')) {
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_coin_snapshot_char',
        'INTEGER',
      );
      await _safeAddColumn(
        db,
        'conversations',
        'pinned_coin_snapshot_user',
        'INTEGER',
      );
    }
    if (oldVersion < 55) {
      await DatabaseHelper._createCharacterSignatureTable(db);
      await _repairLegacyCharacterSignatureThinking(db);
    }
    if (oldVersion < 56) {
      await DatabaseHelper._createCharacterSignatureTable(db);
      await _backfillLegacyCharacterSignatures(db);
    }
    if (oldVersion < 57) {
      await _createChatDiagnosticsTable(db);
    }
    if (oldVersion < 58 && await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'summary_recorded',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 59) {
      await _createRpStoryTables(db);
    }
    if (oldVersion < 60) {
      await _migrateToV60(db);
    }
    if (oldVersion < 61) {
      await _migrateMemoryFtsToTrigram(db);
    }
    if (oldVersion < 62 && await _tableExists(db, 'memories')) {
      await _createMemoryEmbeddingTable(db);
    }
    if (oldVersion < 63) {
      await _migrateToV63(db);
    }
    if (oldVersion < 64) {
      await _migrateToV64(db);
    }
    if (oldVersion < 65 && await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'image_paths_json',
        "TEXT NOT NULL DEFAULT '[]'",
      );
    }
    if (oldVersion < 66) {
      await _ensureMemoryFts(db);
    }
    if (oldVersion < 67 && await _tableExists(db, 'context_summaries')) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'display_anchor_message_id',
        'INTEGER',
      );
    }
    if (oldVersion < 68 && await _tableExists(db, 'context_summaries')) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'archived',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 69) {
      await _migrateToV69(db);
    }
    if (oldVersion < 70) {
      await _migrateToV70(db);
    }
    if (oldVersion < 71) {
      await _createRpWorldbookTables(db);
    }
    if (oldVersion < 72) {
      // Some isolated legacy fixtures predate the RP timeline entirely. Build
      // the authoritative table first, then add the new metadata columns for
      // real installations where the older table already exists.
      await _createRpCharacterTimelineTable(db);
      await _safeAddColumn(
        db,
        'rp_character_timeline',
        'event_key',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _safeAddColumn(
        db,
        'rp_character_timeline',
        'narrative_layer',
        "TEXT NOT NULL DEFAULT 'main'",
      );
      await _safeAddColumn(
        db,
        'rp_character_timeline',
        'subject_entity_ids',
        "TEXT NOT NULL DEFAULT '[]'",
      );
    }
    if (oldVersion < 73) {
      await _createRpStoryProjectionRevisionTable(db);
      await _createContextSummaryRepairTable(db);
      await _safeAddColumn(
        db,
        'rp_story_relationships',
        'source_summary_id',
        'INTEGER',
      );
      await _safeAddColumn(
        db,
        'rp_story_relationship_events',
        'source_summary_id',
        'INTEGER',
      );
    }
    if (oldVersion < 74) {
      if (await _tableExists(db, 'usage_logs')) {
        await _safeAddColumn(
          db,
          'usage_logs',
          'request_kind',
          "TEXT NOT NULL DEFAULT 'unknown'",
        );
        await _safeAddColumn(
          db,
          'usage_logs',
          'cost_known',
          'INTEGER NOT NULL DEFAULT 0',
        );
      } else {
        await _createUsageTable(db);
      }
    }
    if (oldVersion < 75 && await _tableExists(db, 'context_summaries')) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'source_span_status',
        "TEXT NOT NULL DEFAULT 'unknown'",
      );
      // Legacy rows are only promoted when both endpoints already exist.
      // Missing endpoints remain unknown instead of being guessed from time.
      await db.rawUpdate(
        "UPDATE context_summaries SET source_span_status = 'exact' "
        "WHERE source_message_start_id IS NOT NULL "
        'AND source_message_end_id IS NOT NULL',
      );
    }
    if (oldVersion < 76 && await _tableExists(db, 'context_summaries')) {
      await _safeAddColumn(
        db,
        'context_summaries',
        'replaces_summary_id',
        'INTEGER',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_context_summary_replacement '
        'ON context_summaries(replaces_summary_id)',
      );
    }
    if (oldVersion < 77) {
      await _createCharacterDiaryTable(db);
    }
    if (oldVersion < 78) {
      if (await _tableExists(db, 'usage_logs')) {
        await _safeAddColumn(
          db,
          'usage_logs',
          'conversation_id',
          "TEXT NOT NULL DEFAULT ''",
        );
      } else {
        await _createUsageTable(db);
      }
    }
    if (oldVersion < 79) {
      await _createContextSummaryTables(db);
    }
    if (oldVersion < 80) {
      await _createRevisionIntegrityTables(db);
    }
    if (oldVersion < 81) {
      await _createCharacterSelfNotesTable(db);
      await DatabaseHelper._backfillCharacterSelfNotes(db);
    }
    if (oldVersion < 82) {
      await _migrateToV82SharedPersonaBindings(db);
    }
    // Rebuild shared indexes only after every versioned column migration has
    // completed. _migrateToV36 used to call this helper early; once v38 added
    // an index over source_message_id, a real v35 database tried to create the
    // index before v38 had added the column and the entire database open
    // failed. Keeping this at the end also prevents future indexes from being
    // pulled accidentally into an older migration step.
    if (await _hasAllKnownIndexTables(db)) {
      await _createKnownIndexes(db);
      await _createContextModeIndexes(db);
    }
  }

  /// Persona files remain mode-specific, but the companion relationship is
  /// one shared user-persona <-> character binding. Older builds stored a
  /// separate row for every mode/continuity. Keep the legacy columns for
  /// backup compatibility and collapse their values into one canonical row.
  ///
  /// When old scopes disagree, the most recently edited relationship wins.
  /// The greedy pass also preserves the existing one-companion-per-persona UI
  /// policy without inventing a binding the user never selected.
  static Future<void> _migrateToV82SharedPersonaBindings(Database db) async {
    if (!await _tableExists(db, 'character_persona_bindings')) return;
    final rows = await db.query(
      'character_persona_bindings',
      orderBy: 'updated_at DESC, created_at DESC, rowid DESC',
    );
    if (rows.isEmpty) return;

    final selected = <Map<String, Object?>>[];
    final usedCharacters = <String>{};
    final usedPersonas = <String>{};
    for (final row in rows) {
      final characterId = row['character_id']?.toString().trim() ?? '';
      final personaId = row['user_persona_id']?.toString().trim() ?? '';
      if (characterId.isEmpty ||
          personaId.isEmpty ||
          usedCharacters.contains(characterId) ||
          usedPersonas.contains(personaId)) {
        continue;
      }
      usedCharacters.add(characterId);
      usedPersonas.add(personaId);
      selected.add(<String, Object?>{
        ...row,
        // Compatibility placeholders only; lookup no longer scopes by them.
        'context_mode': 'daily',
        'continuity_id': 'main',
      });
    }

    // onUpgrade already executes transactionally; do not open a nested
    // transaction here.
    await db.delete('character_persona_bindings');
    for (final row in selected) {
      await db.insert('character_persona_bindings', row);
    }
  }

  static Future<void> _createCharacterSelfNotesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_self_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        content TEXT NOT NULL,
        provider TEXT NOT NULL DEFAULT '',
        model_id TEXT NOT NULL DEFAULT '',
        model_version TEXT NOT NULL DEFAULT '',
        source_conversation_id TEXT NOT NULL DEFAULT '',
        source_message_ids_json TEXT NOT NULL DEFAULT '[]',
        locked INTEGER NOT NULL DEFAULT 0 CHECK(locked IN (0, 1)),
        long_term INTEGER NOT NULL DEFAULT 0 CHECK(long_term IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(character_id, content),
        FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_character_self_notes_scope '
      'ON character_self_notes(character_id, created_at DESC, id DESC)',
    );
  }

  static Future<void> _migrateToV69(Database db) async {
    if (await _tableExists(db, 'messages')) {
      await _safeAddColumn(
        db,
        'messages',
        'revision',
        'INTEGER NOT NULL DEFAULT 1',
      );
    }
    await _createRpStorylineTables(db);
    await _createRevisionIntegrityTables(db);

    if (!await _tableExists(db, 'characters')) return;
    final now = DateTime.now().toIso8601String();
    final scopes = <String>{};
    Future<void> collect(
      String table, {
      String? where,
      List<Object?>? whereArgs,
    }) async {
      if (!await _tableExists(db, table)) return;
      final rows = await db.query(
        table,
        columns: const <String>['character_id', 'continuity_id'],
        where: where,
        whereArgs: whereArgs,
      );
      for (final row in rows) {
        final characterId = row['character_id']?.toString().trim() ?? '';
        final continuityId = row['continuity_id']?.toString().trim() ?? '';
        if (characterId.isNotEmpty && continuityId.isNotEmpty) {
          scopes.add('$characterId\u0000$continuityId');
        }
      }
    }

    await collect(
      'conversations',
      where: 'context_mode = ?',
      whereArgs: const <Object?>['rp'],
    );
    await collect(
      'memories',
      where: 'context_mode = ?',
      whereArgs: const <Object?>['rp'],
    );
    await collect(
      'context_summaries',
      where: 'context_mode = ?',
      whereArgs: const <Object?>['rp'],
    );
    await collect('rp_character_timeline');
    await collect('rp_story_characters');
    await collect('rp_story_relationships');

    final characterIds = (await db.query('characters', columns: const ['id']))
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final scope in scopes) {
      final parts = scope.split('\u0000');
      final characterId = parts.first;
      final storylineId = parts.last;
      if (!characterIds.contains(characterId)) continue;
      await db.insert('rp_storylines', <String, Object?>{
        'character_id': characterId,
        'id': storylineId,
        'name': '',
        'status': 'active',
        'is_default': storylineId == 'main' ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> _migrateToV70(Database db) async {
    await _createRpStoryTables(db);
    await _safeAddColumn(
      db,
      'rp_story_characters',
      'entity_key',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'rp_story_characters',
      'identities_json',
      "TEXT NOT NULL DEFAULT '[]'",
    );
    await _safeAddColumn(
      db,
      'rp_story_characters',
      'core_motivation',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'rp_story_characters',
      'current_stance',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'rp_story_relationships',
      'from_entity_key',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _safeAddColumn(
      db,
      'rp_story_relationships',
      'to_entity_key',
      "TEXT NOT NULL DEFAULT ''",
    );
    for (final column in const <(String, String)>[
      ('closeness_catalyst', "TEXT NOT NULL DEFAULT ''"),
      ('forms_of_address_json', "TEXT NOT NULL DEFAULT '[]'"),
      ('shared_secrets_json', "TEXT NOT NULL DEFAULT '[]'"),
      ('conflicts_json', "TEXT NOT NULL DEFAULT '[]'"),
      ('knowledge_scope_json', "TEXT NOT NULL DEFAULT '[]'"),
    ]) {
      await _safeAddColumn(db, 'rp_story_relationships', column.$1, column.$2);
    }
    await _createRpStoryStateTables(db);

    final scopes = await db.rawQuery('''
      SELECT DISTINCT character_id, continuity_id
      FROM rp_story_characters
      ORDER BY character_id, continuity_id
    ''');
    for (final scope in scopes) {
      final characterId = scope['character_id']?.toString() ?? '';
      final continuityId = scope['continuity_id']?.toString() ?? 'main';
      final rows = await db.query(
        'rp_story_characters',
        where: 'character_id = ? AND continuity_id = ?',
        whereArgs: <Object?>[characterId, continuityId],
        orderBy: 'created_at ASC, id ASC',
      );
      var ordinal = 1;
      for (final row in rows) {
        var entityKey = row['entity_key']?.toString().trim() ?? '';
        if (entityKey.isEmpty) {
          entityKey = 'P-${ordinal.toString().padLeft(4, '0')}';
          await db.update(
            'rp_story_characters',
            <String, Object?>{'entity_key': entityKey},
            where: 'id = ?',
            whereArgs: <Object?>[row['id']],
          );
        }
        ordinal += 1;
        final aliases = <String>{row['name']?.toString().trim() ?? ''};
        try {
          final decoded = jsonDecode(row['aliases_json']?.toString() ?? '[]');
          if (decoded is List) {
            aliases.addAll(
              decoded.map((value) => value?.toString().trim() ?? ''),
            );
          }
        } catch (_) {
          // Keep the canonical name even if a legacy aliases payload is bad.
        }
        final now = DateTime.now().toIso8601String();
        for (final alias in aliases.where((value) => value.isNotEmpty)) {
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
            'alias_type': alias == row['name'] ? 'name' : 'identity',
            'created_at': now,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }

    final relationships = await db.query(
      'rp_story_relationships',
      orderBy: 'updated_at DESC, id ASC',
    );
    final removedRelationshipIds = <String>{};
    for (final relationship in relationships) {
      final id = relationship['id']?.toString() ?? '';
      if (id.isEmpty || removedRelationshipIds.contains(id)) continue;
      final characterId = relationship['character_id']?.toString() ?? '';
      final continuityId = relationship['continuity_id']?.toString() ?? 'main';
      final fromName = relationship['from_name']?.toString() ?? '';
      final toName = relationship['to_name']?.toString() ?? '';
      final direction = relationship['direction']?.toString() ?? 'mutual';
      Future<String> resolve(String name) async {
        final normalized = name.trim().toLowerCase().replaceAll(
          RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
          '',
        );
        if (normalized.isEmpty) return '';
        final matches = await db.query(
          'rp_story_entity_aliases',
          columns: const <String>['entity_key'],
          where:
              'character_id = ? AND continuity_id = ? AND normalized_alias = ?',
          whereArgs: <Object?>[characterId, continuityId, normalized],
          distinct: true,
        );
        return matches.length == 1
            ? matches.first['entity_key']!.toString()
            : '';
      }

      final fromEntityKey = await resolve(fromName);
      final toEntityKey = await resolve(toName);
      final parties = <String>[
        fromEntityKey.isNotEmpty ? fromEntityKey : fromName,
        toEntityKey.isNotEmpty ? toEntityKey : toName,
      ];
      if (direction == 'mutual') parties.sort();
      final edge = '${parties[0]}|${parties[1]}|$direction';
      final duplicate = await db.query(
        'rp_story_relationships',
        columns: const <String>['id'],
        where:
            'character_id = ? AND continuity_id = ? AND normalized_edge = ? AND id != ?',
        whereArgs: <Object?>[characterId, continuityId, edge, id],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        final duplicateId = duplicate.first['id']!.toString();
        await db.update(
          'rp_story_relationship_events',
          <String, Object?>{'relationship_id': id},
          where: 'relationship_id = ?',
          whereArgs: <Object?>[duplicateId],
        );
        await db.delete(
          'rp_story_relationships',
          where: 'id = ?',
          whereArgs: <Object?>[duplicateId],
        );
        removedRelationshipIds.add(duplicateId);
      }
      await db.update(
        'rp_story_relationships',
        <String, Object?>{
          'from_entity_key': fromEntityKey,
          'to_entity_key': toEntityKey,
          'normalized_edge': edge,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    }
  }

  static Future<void> _repairLegacyCharacterSignatureThinking(
    Database db,
  ) async {
    if (!await _tableExists(db, 'character_signatures')) return;
    final history = await db.query(
      'character_signatures',
      columns: const <String>['id', 'signature'],
    );
    for (final row in history) {
      final id = row['id'];
      if (id is! int) continue;
      final original = row['signature']?.toString() ?? '';
      final cleaned = _cleanLegacySignature(original);
      if (cleaned.isEmpty) {
        await db.delete(
          'character_signatures',
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      } else if (cleaned != original) {
        await db.update(
          'character_signatures',
          <String, Object?>{
            'signature': cleaned,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      }
    }

    if (!await _tableExists(db, 'characters')) return;
    final columns = await db.rawQuery("PRAGMA table_info('characters')");
    if (!columns.any((row) => row['name'] == 'signature')) return;
    final characters = await db.query(
      'characters',
      columns: const <String>['id', 'signature'],
    );
    for (final row in characters) {
      final characterId = row['id']?.toString() ?? '';
      if (characterId.isEmpty) continue;
      final original = row['signature']?.toString() ?? '';
      var cleaned = _cleanLegacySignature(original);
      if (cleaned.isEmpty && original.trim().isNotEmpty) {
        final latest = await db.query(
          'character_signatures',
          columns: const <String>['signature'],
          where: 'character_id = ?',
          whereArgs: <Object?>[characterId],
          orderBy: 'created_at DESC, id DESC',
          limit: 1,
        );
        cleaned = latest.isEmpty
            ? ''
            : _cleanLegacySignature(
                latest.single['signature']?.toString() ?? '',
              );
      }
      if (cleaned == original) continue;
      await db.update(
        'characters',
        <String, Object?>{'signature': cleaned},
        where: 'id = ?',
        whereArgs: <Object?>[characterId],
      );
    }
  }

  static String _cleanLegacySignature(String raw) {
    var value = raw.trim();
    value = value.replaceAll(
      RegExp(
        r'<(?:think|thinking)\b[^>]*>[\s\S]*?</(?:think|thinking)\s*>',
        caseSensitive: false,
      ),
      '',
    );
    value = value.replaceAll(
      RegExp(r'<(?:think|thinking)\b[^>]*>[\s\S]*$', caseSensitive: false),
      '',
    );
    final reasoningMarker = RegExp(
      r'(?:^|\n)\s*(?:\[/?(?:analysis|thinking|reasoning)\]|</?(?:analysis|thinking|reasoning)\b[^>]*>|(?:analysis|thinking|reasoning)\s*[:：])',
      caseSensitive: false,
      multiLine: true,
    );
    if (reasoningMarker.hasMatch(value)) {
      final finalMarker = RegExp(
        r'(?:^|\n)\s*(?:\[?final(?: answer)?\]?|signature|個性簽名|个性签名)\s*[:：]\s*([\s\S]+)$',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(value);
      value = finalMarker?.group(1)?.trim() ?? '';
    }
    value = value.replaceFirst(
      RegExp(
        r'^(?:\[?final(?: answer)?\]?|signature|個性簽名|个性签名)\s*[:：]?\s*',
        caseSensitive: false,
      ),
      '',
    );
    final lines = value
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(4)
        .join('\n');
    return String.fromCharCodes(lines.runes.take(64)).trim();
  }

  /// v56 preserves the single signature that older builds stored directly on
  /// each character card. The history table did not exist when those values
  /// were written, so without this one-time bridge the card still showed the
  /// signature while its history sheet appeared empty.
  ///
  /// The migration is intentionally conservative: it never rewrites existing
  /// history, never duplicates identical text, and only uses an unoccupied
  /// opening/closing slot from one of the character's existing conversations.
  static Future<void> _backfillLegacyCharacterSignatures(Database db) async {
    if (!await _tableExists(db, 'characters') ||
        !await _tableExists(db, 'conversations') ||
        !await _tableExists(db, 'character_signatures')) {
      return;
    }
    final characterColumns = (await db.rawQuery(
      "PRAGMA table_info('characters')",
    )).map((row) => row['name']?.toString()).whereType<String>().toSet();
    final conversationColumns = (await db.rawQuery(
      "PRAGMA table_info('conversations')",
    )).map((row) => row['name']?.toString()).whereType<String>().toSet();
    if (!characterColumns.containsAll(const <String>{
          'id',
          'signature',
          'updated_at',
        }) ||
        !conversationColumns.containsAll(const <String>{
          'id',
          'character_id',
          'context_mode',
          'continuity_id',
          'created_at',
          'updated_at',
        })) {
      return;
    }

    final characters = await db.query(
      'characters',
      columns: const <String>['id', 'signature', 'updated_at'],
      where: "TRIM(COALESCE(signature, '')) <> ''",
    );
    for (final character in characters) {
      final characterId = character['id']?.toString().trim() ?? '';
      final signature = _cleanLegacySignature(
        character['signature']?.toString() ?? '',
      );
      if (characterId.isEmpty || signature.isEmpty) continue;

      final duplicate = await db.query(
        'character_signatures',
        columns: const <String>['id'],
        where: 'character_id = ? AND signature = ?',
        whereArgs: <Object?>[characterId, signature],
        limit: 1,
      );
      if (duplicate.isNotEmpty) continue;

      final conversations = await db.query(
        'conversations',
        columns: const <String>[
          'id',
          'context_mode',
          'continuity_id',
          'created_at',
          'updated_at',
        ],
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
        orderBy: 'updated_at DESC, created_at DESC',
      );

      Map<String, Object?>? targetConversation;
      String? targetPhase;
      for (final conversation in conversations) {
        final conversationId = conversation['id']?.toString().trim() ?? '';
        if (conversationId.isEmpty) continue;
        final occupied = await db.query(
          'character_signatures',
          columns: const <String>['phase'],
          where: 'conversation_id = ?',
          whereArgs: <Object?>[conversationId],
        );
        final phases = occupied
            .map((row) => row['phase']?.toString())
            .whereType<String>()
            .toSet();
        for (final phase in const <String>['closing', 'opening']) {
          if (!phases.contains(phase)) {
            targetConversation = conversation;
            targetPhase = phase;
            break;
          }
        }
        if (targetConversation != null) break;
      }
      if (targetConversation == null || targetPhase == null) continue;

      final existingHistory = await db.query(
        'character_signatures',
        columns: const <String>['id'],
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
        limit: 1,
      );
      final selectedHistory = await db.query(
        'character_signatures',
        columns: const <String>['id'],
        where: 'character_id = ? AND is_selected = 1',
        whereArgs: <Object?>[characterId],
        limit: 1,
      );
      final mode = targetConversation['context_mode'] == 'rp' ? 'rp' : 'daily';
      final continuity =
          targetConversation['continuity_id']?.toString().trim() ?? '';
      final fallbackTime =
          targetConversation['updated_at']?.toString().trim() ?? '';
      final characterTime = character['updated_at']?.toString().trim() ?? '';
      final timestamp = characterTime.isNotEmpty
          ? characterTime
          : fallbackTime.isNotEmpty
          ? fallbackTime
          : DateTime.now().toIso8601String();

      await db.insert('character_signatures', <String, Object?>{
        'character_id': characterId,
        'conversation_id': targetConversation['id']?.toString(),
        'context_mode': mode,
        'continuity_id': continuity.isEmpty ? 'main' : continuity,
        'phase': targetPhase,
        'signature': signature,
        // If newer history already exists, pin the card's legacy value so
        // migration does not silently change what the user was displaying.
        'is_selected': existingHistory.isNotEmpty && selectedHistory.isEmpty
            ? 1
            : 0,
        'created_at': timestamp,
        'updated_at': timestamp,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> _migrateWebSearchUsageProviders(Database db) async {
    // The v42 indexes belong to the table being replaced. Drop them first so
    // SQLite does not preserve the index names on the temporary table after
    // RENAME, which would make the fresh table silently miss its constraints.
    for (final index in <String>[
      'idx_web_search_turn_once',
      'idx_web_search_call_once',
      'idx_web_search_budget_status',
      'idx_web_search_reservation',
      'idx_web_search_char_time',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $index');
    }
    await db.execute(
      'ALTER TABLE web_search_usage_logs RENAME TO web_search_usage_logs_v45',
    );
    await _createWebSearchUsageTable(db);
    await db.execute('''
      INSERT INTO web_search_usage_logs (
        id, reservation_id, logical_slot, conversation_id, character_id,
        turn_id, generation_serial, budget_day, plan_strategy, provider,
        provider_model, provider_route, call_id, status, reserved_at,
        expires_at, claimed_at, launched_at, settled_at, search_requests,
        prompt_tokens, completion_tokens, actual_cost_usd, cost_certainty
      )
      SELECT
        id, reservation_id, logical_slot, conversation_id, character_id,
        turn_id, generation_serial, budget_day, plan_strategy, provider,
        provider_model, provider_route, call_id, status, reserved_at,
        expires_at, claimed_at, launched_at, settled_at, search_requests,
        prompt_tokens, completion_tokens, actual_cost_usd, cost_certainty
      FROM web_search_usage_logs_v45
      WHERE provider IN ('openRouter', 'gemini', 'xai', 'relay')
    ''');
    await db.execute('DROP TABLE web_search_usage_logs_v45');
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

  /// One-time daily baseline for every row created before RP existed.
  /// Future schema versions must never repeat these updates on existing rows.
  static Future<void> _migrateToV48(Database db) async {
    if (await _tableExists(db, 'conversations')) {
      await _safeAddColumn(
        db,
        'conversations',
        'context_mode',
        "TEXT NOT NULL DEFAULT 'daily' CHECK(context_mode IN ('daily', 'rp'))",
      );
      await _safeAddColumn(
        db,
        'conversations',
        'continuity_id',
        "TEXT NOT NULL DEFAULT 'main' CHECK(length(trim(continuity_id)) > 0)",
      );
      await _safeAddColumn(db, 'conversations', 'user_persona_id', 'TEXT');
      await _safeAddColumn(db, 'conversations', 'worldbook_set_id', 'TEXT');
    }
    if (await _tableExists(db, 'characters')) {
      await _safeAddColumn(
        db,
        'characters',
        'preferred_context_mode',
        "TEXT NOT NULL DEFAULT 'daily' "
            "CHECK(preferred_context_mode IN ('daily', 'rp'))",
      );
    }
    if (await _tableExists(db, 'memories')) {
      await _safeAddColumn(
        db,
        'memories',
        'context_mode',
        "TEXT NOT NULL DEFAULT 'daily' CHECK(context_mode IN ('daily', 'rp'))",
      );
      await _safeAddColumn(
        db,
        'memories',
        'continuity_id',
        "TEXT NOT NULL DEFAULT 'main' CHECK(length(trim(continuity_id)) > 0)",
      );
    }
    for (final table in const <String>[
      'context_summaries',
      'context_keywords',
    ]) {
      if (!await _tableExists(db, table)) continue;
      await _safeAddColumn(
        db,
        table,
        'context_mode',
        "TEXT NOT NULL DEFAULT 'daily' CHECK(context_mode IN ('daily', 'rp'))",
      );
      await _safeAddColumn(
        db,
        table,
        'continuity_id',
        "TEXT NOT NULL DEFAULT 'main' CHECK(length(trim(continuity_id)) > 0)",
      );
    }
    if (await _tableExists(db, 'pending_memory_actions')) {
      await _safeAddColumn(
        db,
        'pending_memory_actions',
        'context_mode',
        "TEXT NOT NULL DEFAULT 'daily' CHECK(context_mode IN ('daily', 'rp'))",
      );
      await _safeAddColumn(
        db,
        'pending_memory_actions',
        'continuity_id',
        "TEXT NOT NULL DEFAULT 'main' CHECK(length(trim(continuity_id)) > 0)",
      );
    }
    await _createRpCharacterTimelineTable(db);
  }

  /// v1.5.0 one-time memory baseline.
  ///
  /// Every pre-v1.5 archived memory is revived once at minimum activation,
  /// and every active daily spider island starts the new active-day clock from
  /// zero. Later schema upgrades must never repeat this reset.
  static Future<void> _migrateToV49(Database db) async {
    if (!await _tableExists(db, 'memories')) return;

    final memoryColumns = (await db.rawQuery(
      "PRAGMA table_info('memories')",
    )).map((row) => row['name']?.toString()).whereType<String>().toSet();
    const resetColumns = <String>{
      'status',
      'mention_count',
      'clarity',
      'last_accessed',
      'updated_at',
    };
    if (!memoryColumns.containsAll(resetColumns)) return;

    final now = DateTime.now().toIso8601String();
    if (await _tableExists(db, 'archive')) {
      final archived = await db.query(
        'archive',
        where: 'original_table = ?',
        whereArgs: const <Object?>['memories'],
        orderBy: 'id ASC',
      );
      for (final row in archived) {
        final archiveId = row['id'] as int?;
        final originalId = row['original_id'] as int?;
        if (archiveId == null || originalId == null) continue;

        var restored = false;
        final existing = await db.query(
          'memories',
          columns: const <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[originalId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          restored =
              await db.update(
                'memories',
                <String, Object?>{
                  'status': 'active',
                  'mention_count': 0,
                  'clarity': 1.0,
                  'last_accessed': now,
                  'updated_at': now,
                },
                where: 'id = ?',
                whereArgs: <Object?>[originalId],
              ) ==
              1;
        } else {
          try {
            final decoded = jsonDecode(row['content_snapshot'] as String);
            if (decoded is Map) {
              final snapshot = <String, Object?>{};
              for (final entry in decoded.entries) {
                final key = entry.key.toString();
                if (memoryColumns.contains(key)) snapshot[key] = entry.value;
              }
              final archivedCharacter =
                  row['character_id']?.toString().trim() ?? '';
              snapshot
                ..['id'] = originalId
                ..['character_id'] = archivedCharacter.isEmpty
                    ? (snapshot['character_id']?.toString().trim().isNotEmpty ==
                              true
                          ? snapshot['character_id']
                          : 'default')
                    : archivedCharacter
                ..['context_mode'] = snapshot['context_mode'] == 'rp'
                    ? 'rp'
                    : 'daily'
                ..['continuity_id'] =
                    snapshot['continuity_id']?.toString().trim().isNotEmpty ==
                        true
                    ? snapshot['continuity_id']
                    : 'main'
                ..['status'] = 'active'
                ..['mention_count'] = 0
                ..['clarity'] = 1.0
                ..['last_accessed'] = now
                ..['updated_at'] = now;
              await db.insert('memories', snapshot);
              restored = true;
            }
          } on FormatException {
            // Preserve malformed legacy archive rows instead of blocking the
            // entire app upgrade or silently discarding the only snapshot.
          } on TypeError {
            // A malformed backup may carry a non-string snapshot. Keep it in
            // the archive for manual recovery instead of failing migration.
          } on DatabaseException {
            // Same safeguard for an incomplete pre-schema snapshot.
          }
        }

        if (restored) {
          await db.delete(
            'archive',
            where: 'id = ?',
            whereArgs: <Object?>[archiveId],
          );
        }
      }
    }

    // A confirmed edge only protects an island when its opposite endpoint is
    // still active. Dead endpoints do not keep a memory artificially alive.
    if (await _tableExists(db, 'spider_web_links') &&
        memoryColumns.contains('context_mode')) {
      await db.rawUpdate(
        '''
        UPDATE memories AS m
        SET mention_count = 0,
            clarity = 1.0,
            last_accessed = ?,
            updated_at = ?
        WHERE m.status = 'active'
          AND m.context_mode = 'daily'
          AND NOT EXISTS (
            SELECT 1
            FROM spider_web_links l
            WHERE l.character_id = m.character_id
              AND l.status = 'confirmed'
              AND (
                (l.memory_id_1 = m.id AND EXISTS (
                  SELECT 1 FROM memories peer
                  WHERE peer.id = l.memory_id_2
                    AND peer.character_id = m.character_id
                    AND peer.status = 'active'
                ))
                OR
                (l.memory_id_2 = m.id AND EXISTS (
                  SELECT 1 FROM memories peer
                  WHERE peer.id = l.memory_id_1
                    AND peer.character_id = m.character_id
                    AND peer.status = 'active'
                ))
              )
          )
        ''',
        <Object?>[now, now],
      );
    }
  }

  /// Adds user-authored personas and pins blank legacy windows to the migrated
  /// default persona. Any non-empty reserved identity is preserved with a
  /// placeholder row so old cache identity never becomes an orphan. Persona
  /// text itself is hydrated from legacy preferences by UserPersonaService
  /// after the database opens.
  static Future<void> _migrateToV50(Database db) async {
    await _createCharacterTables(db);
    await _createUserPersonaTables(db);
    if (!await _tableExists(db, 'conversations')) return;
    await _safeAddColumn(db, 'conversations', 'user_persona_id', 'TEXT');
    await _safeAddColumn(
      db,
      'conversations',
      'user_persona_snapshot',
      "TEXT NOT NULL DEFAULT ''",
    );
    await db.rawInsert('''
      INSERT OR IGNORE INTO user_personas (
        id, display_name, pronouns, bio, avatar_path, prompt_content,
        is_default, is_archived, created_at, updated_at
      )
      SELECT DISTINCT
        trim(user_persona_id), '', '', '', '', '', 0, 0,
        strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      FROM conversations
      WHERE user_persona_id IS NOT NULL
        AND trim(user_persona_id) <> ''
    ''');
    await db.rawUpdate(
      "UPDATE conversations SET user_persona_id = 'default' "
      "WHERE user_persona_id IS NULL OR trim(user_persona_id) = ''",
    );
  }

  /// Repairs memories that were accepted from an RP review proposal before
  /// the proposal lane was copied onto the durable memory row. Only rows with
  /// an unambiguous RP source window are changed; everything else is left as-is.
  static Future<void> _migrateToV52(Database db) async {
    if (!await _tableExists(db, 'memories') ||
        !await _tableExists(db, 'conversations')) {
      return;
    }
    final memoryColumns = (await db.rawQuery(
      "PRAGMA table_info('memories')",
    )).map((row) => row['name']?.toString()).whereType<String>().toSet();
    final conversationColumns = (await db.rawQuery(
      "PRAGMA table_info('conversations')",
    )).map((row) => row['name']?.toString()).whereType<String>().toSet();
    if (!memoryColumns.containsAll(const <String>{
      'context_mode',
      'continuity_id',
    })) {
      return;
    }
    if (await _tableExists(db, 'pending_memory_actions')) {
      final pendingColumns = (await db.rawQuery(
        "PRAGMA table_info('pending_memory_actions')",
      )).map((row) => row['name']?.toString()).whereType<String>().toSet();
      if (pendingColumns.containsAll(const <String>{
        'context_mode',
        'continuity_id',
        'result_json',
        'resolved_at',
      })) {
        await db.rawUpdate('''
        UPDATE memories
        SET context_mode = 'rp',
            continuity_id = COALESCE((
              SELECT NULLIF(trim(p.continuity_id), '')
              FROM pending_memory_actions p
              WHERE p.context_mode = 'rp'
                AND CAST(json_extract(p.result_json, char(36) || '.new_memory_id') AS INTEGER) = memories.id
              ORDER BY p.resolved_at DESC
              LIMIT 1
            ), continuity_id)
        WHERE context_mode = 'daily'
          AND EXISTS (
            SELECT 1
            FROM pending_memory_actions p
            WHERE p.context_mode = 'rp'
              AND CAST(json_extract(p.result_json, char(36) || '.new_memory_id') AS INTEGER) = memories.id
          )
      ''');
      }
    }
    if (memoryColumns.containsAll(const <String>{
          'source_conversation_id',
          'character_id',
        }) &&
        conversationColumns.containsAll(const <String>{
          'character_id',
          'context_mode',
          'continuity_id',
        })) {
      await db.rawUpdate('''
      UPDATE memories
      SET context_mode = 'rp',
          continuity_id = COALESCE((
            SELECT NULLIF(trim(c.continuity_id), '')
            FROM conversations c
            WHERE c.id = memories.source_conversation_id
              AND c.character_id = memories.character_id
              AND c.context_mode = 'rp'
            LIMIT 1
          ), continuity_id)
      WHERE context_mode = 'daily'
        AND source_conversation_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM conversations c
          WHERE c.id = memories.source_conversation_id
            AND c.character_id = memories.character_id
            AND c.context_mode = 'rp'
        )
    ''');
    }
  }

  /// Repairs legacy memory lanes without inferring a mode from the character's
  /// current switch. A conversation is authoritative for directly sourced
  /// rows; a merged memory is repaired only when every archived source memory
  /// agrees on the same context mode and continuity.
  static Future<void> _migrateToV60(Database db) async {
    if (!await _tableExists(db, 'memories')) return;

    final memoryColumns = await _columnNames(db, 'memories');
    if (!memoryColumns.containsAll(const <String>{
      'id',
      'character_id',
      'context_mode',
      'continuity_id',
      'source_conversation_id',
    })) {
      return;
    }

    if (await _tableExists(db, 'conversations')) {
      final conversationColumns = await _columnNames(db, 'conversations');
      if (conversationColumns.containsAll(const <String>{
        'id',
        'character_id',
        'context_mode',
        'continuity_id',
      })) {
        await db.rawUpdate('''
          UPDATE memories
          SET context_mode = (
                SELECT CASE WHEN c.context_mode = 'rp' THEN 'rp' ELSE 'daily' END
                FROM conversations c
                WHERE c.id = memories.source_conversation_id
                  AND c.character_id = memories.character_id
                LIMIT 1
              ),
              continuity_id = COALESCE((
                SELECT NULLIF(trim(c.continuity_id), '')
                FROM conversations c
                WHERE c.id = memories.source_conversation_id
                  AND c.character_id = memories.character_id
                LIMIT 1
              ), continuity_id)
          WHERE NULLIF(trim(source_conversation_id), '') IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM conversations c
              WHERE c.id = memories.source_conversation_id
                AND c.character_id = memories.character_id
            )
        ''');

        if (await _tableExists(db, 'pending_memory_actions')) {
          final pendingColumns = await _columnNames(
            db,
            'pending_memory_actions',
          );
          if (pendingColumns.containsAll(const <String>{
            'character_id',
            'context_mode',
            'continuity_id',
            'source_conversation_id',
          })) {
            await db.rawUpdate('''
              UPDATE pending_memory_actions
              SET context_mode = (
                    SELECT CASE WHEN c.context_mode = 'rp' THEN 'rp' ELSE 'daily' END
                    FROM conversations c
                    WHERE c.id = pending_memory_actions.source_conversation_id
                      AND c.character_id = pending_memory_actions.character_id
                    LIMIT 1
                  ),
                  continuity_id = COALESCE((
                    SELECT NULLIF(trim(c.continuity_id), '')
                    FROM conversations c
                    WHERE c.id = pending_memory_actions.source_conversation_id
                      AND c.character_id = pending_memory_actions.character_id
                    LIMIT 1
                  ), continuity_id)
              WHERE NULLIF(trim(source_conversation_id), '') IS NOT NULL
                AND EXISTS (
                  SELECT 1
                  FROM conversations c
                  WHERE c.id = pending_memory_actions.source_conversation_id
                    AND c.character_id = pending_memory_actions.character_id
                )
            ''');
          }
        }
      }
    }

    await _repairMemoryProposalLanes(db);
    await _repairArchivedMemoryLaneSnapshots(db);
  }

  static Future<void> _repairMemoryProposalLanes(Database db) async {
    if (!await _tableExists(db, 'pending_memory_actions')) return;
    final columns = await _columnNames(db, 'pending_memory_actions');
    if (!columns.containsAll(const <String>{
      'id',
      'character_id',
      'context_mode',
      'continuity_id',
      'target_ids_json',
      'result_json',
    })) {
      return;
    }

    final proposals = await db.query(
      'pending_memory_actions',
      columns: const <String>[
        'id',
        'character_id',
        'target_ids_json',
        'result_json',
      ],
    );
    for (final proposal in proposals) {
      final proposalId = proposal['id']?.toString();
      final characterId = proposal['character_id']?.toString();
      if (proposalId == null || characterId == null) continue;

      final result = _decodeJsonObject(proposal['result_json']);
      final archivedIds = _decodePositiveIds(result?['archived_ids']);
      final targetIds = _decodePositiveIds(proposal['target_ids_json']);
      final evidenceIds = archivedIds.isNotEmpty ? archivedIds : targetIds;
      final lane = await _unanimousMemoryLane(
        db,
        characterId: characterId,
        memoryIds: evidenceIds,
      );
      if (lane == null) continue;

      await db.update(
        'pending_memory_actions',
        <String, Object?>{
          'context_mode': lane.contextMode,
          'continuity_id': lane.continuityId,
        },
        where: 'id = ? AND character_id = ?',
        whereArgs: <Object?>[proposalId, characterId],
      );

      // A durable replacement is linked to its source memories through the
      // completed proposal result. Empty or mixed source sets are deliberately
      // ignored so a user's daily and RP memories can continue to coexist.
      final newMemoryId = _positiveInt(result?['new_memory_id']);
      if (newMemoryId == null || archivedIds.isEmpty) continue;
      await db.update(
        'memories',
        <String, Object?>{
          'context_mode': lane.contextMode,
          'continuity_id': lane.continuityId,
        },
        where: 'id = ? AND character_id = ?',
        whereArgs: <Object?>[newMemoryId, characterId],
      );
    }
  }

  static Future<void> _repairArchivedMemoryLaneSnapshots(Database db) async {
    if (!await _tableExists(db, 'archive')) return;
    final archiveColumns = await _columnNames(db, 'archive');
    if (!archiveColumns.containsAll(const <String>{
      'id',
      'original_id',
      'original_table',
      'content_snapshot',
    })) {
      return;
    }

    final rows = await db.rawQuery('''
      SELECT a.id AS archive_id,
             a.content_snapshot,
             m.context_mode,
             m.continuity_id
      FROM archive a
      JOIN memories m ON m.id = a.original_id
      WHERE a.original_table = 'memories'
    ''');
    for (final row in rows) {
      final archiveId = row['archive_id'];
      final snapshot = _decodeJsonObject(row['content_snapshot']);
      if (archiveId == null || snapshot == null) continue;
      final contextMode = row['context_mode'] == 'rp' ? 'rp' : 'daily';
      final continuity = row['continuity_id']?.toString().trim();
      snapshot['context_mode'] = contextMode;
      snapshot['continuity_id'] = continuity?.isNotEmpty == true
          ? continuity
          : 'main';
      await db.update(
        'archive',
        <String, Object?>{'content_snapshot': jsonEncode(snapshot)},
        where: 'id = ?',
        whereArgs: <Object?>[archiveId],
      );
    }
  }

  static Future<({String contextMode, String continuityId})?>
  _unanimousMemoryLane(
    Database db, {
    required String characterId,
    required List<int> memoryIds,
  }) async {
    final ids = memoryIds.toSet().toList()..sort();
    if (ids.isEmpty) return null;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT id, context_mode, continuity_id FROM memories '
      'WHERE character_id = ? AND id IN ($placeholders)',
      <Object?>[characterId, ...ids],
    );
    if (rows.length != ids.length) return null;

    final modes = rows
        .map((row) => row['context_mode'] == 'rp' ? 'rp' : 'daily')
        .toSet();
    final continuities = rows
        .map((row) => row['continuity_id']?.toString().trim() ?? '')
        .map((value) => value.isEmpty ? 'main' : value)
        .toSet();
    if (modes.length != 1 || continuities.length != 1) return null;
    return (contextMode: modes.single, continuityId: continuities.single);
  }

  static Set<String> _columnNamesFromRows(List<Map<String, Object?>> rows) =>
      rows.map((row) => row['name']?.toString()).whereType<String>().toSet();

  static Future<Set<String>> _columnNames(Database db, String table) async =>
      _columnNamesFromRows(await db.rawQuery("PRAGMA table_info('$table')"));

  static Map<String, Object?>? _decodeJsonObject(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      return decoded.map(
        (key, value) => MapEntry<String, Object?>(key.toString(), value),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static List<int> _decodePositiveIds(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const <int>[];
      }
    }
    if (decoded is! List) return const <int>[];
    return decoded.map(_positiveInt).whereType<int>().toList();
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static Future<void> _createPendingMemoryActionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_memory_actions (
        id TEXT PRIMARY KEY,
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL DEFAULT 'daily'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
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

  /// v1.5.0 relation graph upgrade: one memory pair may carry more than one
  /// relation kind, while the same kind remains unique for that pair.
  static Future<void> _migrateToV63(Database db) async {
    if (!await _tableExists(db, 'spider_web_links')) return;

    // SQLite reparses triggers while renaming a table. Older migration
    // fixtures may intentionally contain an incomplete `memories` table but
    // still have the derived FTS triggers from an earlier step; those invalid
    // triggers can make an unrelated spider-link rename fail. Temporarily
    // remove valid FTS triggers and restore them after the relation migration.
    final memoryColumns = await _columnNames(db, 'memories');
    final canRestoreFtsTriggers = memoryColumns.containsAll(const <String>{
      'id',
      'content',
      'triggers',
      'status',
    });
    final ftsBackend = canRestoreFtsTriggers
        ? await _detectMemoryFtsBackend(db)
        : null;
    await _dropMemoryFtsTriggers(db);

    final columns = await _columnNames(db, 'spider_web_links');
    final relationType = columns.contains('relation_type')
        ? "COALESCE(relation_type, 'related')"
        : "'related'";
    final strength = columns.contains('strength')
        ? 'COALESCE(strength, 1.0)'
        : '1.0';
    final status = columns.contains('status')
        ? "COALESCE(status, 'confirmed')"
        : "'confirmed'";
    final source = columns.contains('source')
        ? "COALESCE(source, 'legacy')"
        : "'legacy'";
    final reason = columns.contains('reason') ? "COALESCE(reason, '')" : "''";
    final updatedAt = columns.contains('updated_at')
        ? "COALESCE(NULLIF(updated_at, ''), created_at)"
        : 'created_at';

    await db.execute('DROP TABLE IF EXISTS spider_web_links_v63');
    await db.execute('''
      CREATE TABLE spider_web_links_v63 (
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
        UNIQUE(character_id, memory_id_1, memory_id_2, relation_type)
      )
    ''');
    await db.execute('''
      INSERT OR IGNORE INTO spider_web_links_v63 (
        id, character_id, memory_id_1, memory_id_2, created_at,
        relation_type, strength, status, source, reason, updated_at
      )
      SELECT
        id,
        character_id,
        CASE WHEN memory_id_1 < memory_id_2 THEN memory_id_1 ELSE memory_id_2 END,
        CASE WHEN memory_id_1 < memory_id_2 THEN memory_id_2 ELSE memory_id_1 END,
        created_at,
        $relationType,
        $strength,
        $status,
        $source,
        $reason,
        $updatedAt
      FROM spider_web_links
      WHERE memory_id_1 != memory_id_2
      ORDER BY id ASC
    ''');
    await db.execute('DROP TABLE spider_web_links');
    await db.execute(
      'ALTER TABLE spider_web_links_v63 RENAME TO spider_web_links',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_char '
      'ON spider_web_links(character_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_spider_web_status '
      'ON spider_web_links(character_id, status, relation_type)',
    );
    if (ftsBackend != null) {
      await _tryCreateMemoryFtsTriggers(db, ftsBackend);
    }
  }

  /// RP memories use continuity-scoped consolidation rather than the daily
  /// spider-web graph. Earlier v1.5 development builds could still write
  /// graph edges for RP memories. Remove only edges touching an RP endpoint;
  /// memory rows and daily-to-daily relations remain unchanged.
  static Future<void> _migrateToV64(Database db) async {
    if (!await _tableExists(db, 'spider_web_links') ||
        !await _tableExists(db, 'memories')) {
      return;
    }
    final memoryColumns = await _columnNames(db, 'memories');
    if (!memoryColumns.contains('context_mode')) return;
    await db.execute('''
      DELETE FROM spider_web_links
      WHERE EXISTS (
        SELECT 1
        FROM memories AS endpoint
        WHERE endpoint.id IN (
          spider_web_links.memory_id_1,
          spider_web_links.memory_id_2
        )
          AND endpoint.context_mode = 'rp'
      )
    ''');
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
      'rp_character_timeline',
      'user_personas',
      'user_persona_mode_overrides',
      'character_persona_bindings',
      'character_signatures',
      'chat_diagnostics',
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
