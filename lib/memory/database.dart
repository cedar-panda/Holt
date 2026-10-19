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
import '../models/guide_persona_draft.dart';
import '../models/memory.dart';
import '../models/context_mode.dart';
import '../models/chat_diagnostic_event.dart';
import '../models/character_self_note.dart';
import '../utils/app_file_safety.dart';
import '../utils/iso_week.dart';
import '../services/memory_debug_log.dart';

part 'database_characters.dart';
part 'database_context_keywords.dart';
part 'database_context_summaries.dart';
part 'database_conversations.dart';
part 'database_keep_alive.dart';
part 'database_memories.dart';
part 'database_memory_search.dart';
part 'database_message_invalidation.dart';
part 'database_messages.dart';
part 'database_notes_stickers.dart';
part 'database_reply_variants.dart';
part 'database_saved_messages.dart';
part 'database_schema.dart';
part 'database_self_notes.dart';
part 'database_spider_web.dart';
part 'database_usage.dart';
part 'database_voices.dart';

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

class ContextSummarySegmentDraft {
  final int order;
  final String title;
  final String content;
  final List<String> keywords;
  final int tokenCount;

  const ContextSummarySegmentDraft({
    required this.order,
    required this.content,
    required this.tokenCount,
    this.title = '',
    this.keywords = const <String>[],
  });
}

/// 本地數據庫
class DatabaseHelper {
  static Database? _database;
  static Future<Database>? _dbInitFuture;
  static Future<Database> Function() _databaseInitializer = _initDatabase;
  static const String _dbName = 'yanci.db';
  static const int _dbVersion = 82;

  /// The label index stores retrieval phrases, not every archived paragraph.
  /// Keep this shared with ContextCompressor so invalidation recovery and the
  /// normal recycler apply the same budget.
  /// Retained for compatibility with old diagnostics only. Archived summary
  /// labels are no longer evicted by this value; all labels stay searchable
  /// while only matched event segments are injected into prompts.
  static const int contextKeywordIndexTokenCap = 1800;
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
  }) => _KeepAliveGuardStore.tryClaimKeepAlivePing(conversationId: conversationId, characterId: characterId, leaseToken: leaseToken, now: now, claimFor: claimFor);

  /// 將成功的保活請求寫成跨 isolate 可見的下一次允許時間。
  static Future<bool> completeKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime completedAt,
    Duration cooldown = const Duration(minutes: 50),
  }) => _KeepAliveGuardStore.completeKeepAlivePing(conversationId: conversationId, characterId: characterId, leaseToken: leaseToken, completedAt: completedAt, cooldown: cooldown);

  /// 請求失敗或租約失效時釋放 in-flight claim，讓下一個合法執行者可重試。
  static Future<void> releaseKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime releasedAt,
  }) => _KeepAliveGuardStore.releaseKeepAlivePing(conversationId: conversationId, characterId: characterId, leaseToken: leaseToken, releasedAt: releasedAt);

  /// 新租約落地後清掉前一窗口的瞬時 guard。
  static Future<void> resetKeepAlivePingGuard({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime now,
  }) => _KeepAliveGuardStore.resetKeepAlivePingGuard(conversationId: conversationId, characterId: characterId, leaseToken: leaseToken, now: now);

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
    _recallIndexHealedScopes.clear();
  }

  @visibleForTesting
  static void useDatabaseInitializerForTesting(
    Future<Database> Function()? initializer,
  ) {
    _database = null;
    _dbInitFuture = null;
    _databaseInitializer = initializer ?? _initDatabase;
    _recallIndexHealedScopes.clear();
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
    // The RP summary model emits this recall index in the same response as the
    // summary. Retirement therefore needs no second model request.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_summary_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_summary_id INTEGER NOT NULL,
        character_id TEXT NOT NULL,
        context_mode TEXT NOT NULL DEFAULT 'rp'
          CHECK(context_mode IN ('daily', 'rp')),
        continuity_id TEXT NOT NULL DEFAULT 'main'
          CHECK(length(trim(continuity_id)) > 0),
        source_window_id TEXT DEFAULT '',
        source_conversation_id TEXT DEFAULT '',
        segment_order INTEGER NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL,
        keywords TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(source_summary_id, segment_order),
        FOREIGN KEY(source_summary_id) REFERENCES context_summaries(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_segment_scope '
      'ON context_summary_segments('
      'character_id, context_mode, continuity_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_context_summary_segment_source '
      'ON context_summary_segments(source_summary_id, segment_order)',
    );
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
  }) => _VoiceStore.saveVoice(filePath: filePath, name: name, messageId: messageId, sourceConversationId: sourceConversationId, sourceConversationTitle: sourceConversationTitle, characterId: characterId, durationMs: durationMs, fileSize: fileSize);

  /// 根據 messageId 查找已緩存的語音
  static Future<String?> getVoicePathByMessageId(String messageId) => _VoiceStore.getVoicePathByMessageId(messageId);

  /// 獲取所有已保存語音
  static Future<List<Map<String, dynamic>>> getSavedVoices({
    String? characterId,
  }) => _VoiceStore.getSavedVoices(characterId: characterId);

  /// 更新語音名稱
  static Future<void> updateVoiceName(int id, String newName) => _VoiceStore.updateVoiceName(id, newName);

  /// 刪除單條語音
  static Future<void> deleteVoice(int id) => _VoiceStore.deleteVoice(id);

  /// 清除指定角色的語音緩存
  static Future<void> clearAllVoices({required String characterId}) => _VoiceStore.clearAllVoices(characterId: characterId);

  /// 語音總數
  static Future<int> getVoiceCount() => _VoiceStore.getVoiceCount();

  // ═══════════════════════════════════
  // 角色卡操作
  // ═══════════════════════════════════

  /// 後台畫圖完成：更新消息的圖片路徑與記憶日誌
  static Future<void> updateMessageDraw(
    int messageId,
    String? imagePath,
    String memoryLog,
  ) => _MessageStore.updateMessageDraw(messageId, imagePath, memoryLog);

  /// 關鍵詞搜尋歷史消息（模型 `<search_chat>` 工具用）
  /// 先選最新 [limit] 條，再以舊→新返回，讓模型按正確時序閱讀。
  static Future<List<Map<String, dynamic>>> searchMessages({
    required String keyword,
    required String characterId,
    String scope = 'current',
    ContextMode currentMode = ContextMode.daily,
    int limit = 5,
  }) => _MessageStore.searchMessages(keyword: keyword, characterId: characterId, scope: scope, currentMode: currentMode, limit: limit);

  /// 該角色最後一條消息的時間（安全感閒置衰減的錨點）
  static Future<DateTime?> getLastMessageTime(String characterId) => _MessageStore.getLastMessageTime(characterId);

  /// Returns the distinct local dates on which the user spoke to this
  /// character in the requested lane. One or many messages on the same date
  /// still count as one active day. Dates with no user message never appear,
  /// so time spent away from the app cannot age memories.
  static Future<Set<String>> getCharacterActiveDateKeys(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
  }) => _MessageStore.getCharacterActiveDateKeys(characterId, contextMode: contextMode);

  /// 追加角色自我註記（最多保留 12 條，先進先出）。
  ///
  /// 完全相同或正規化後相似度 >= 90% 的條目只保留資訊較完整的一條。
  /// 返回 false 表示 incoming 沒有為註記集合增加任何資訊；即使如此，
  /// transaction 仍會順手清理舊資料中已經存在的重複條目。
  static Future<bool> appendSelfNote(String characterId, String note) => _SelfNoteStore.appendSelfNote(characterId, note);

  static Future<({bool accepted, int? recordId})> appendSelfNoteDetailed(
    String characterId,
    String note, {
    required bool retainLongTerm,
    String provider = '',
    String modelId = '',
    String modelVersion = '',
    String sourceConversationId = '',
    List<int> sourceMessageIds = const <int>[],
  }) => _SelfNoteStore.appendSelfNoteDetailed(characterId, note, retainLongTerm: retainLongTerm, provider: provider, modelId: modelId, modelVersion: modelVersion, sourceConversationId: sourceConversationId, sourceMessageIds: sourceMessageIds);

  /// 刪除一條角色自我註記；不改動任何 conversation 的靜態註記快照。
  static Future<bool> deleteSelfNote(String characterId, String note) => _SelfNoteStore.deleteSelfNote(characterId, note);

  @visibleForTesting
  static String mergeSelfNotes(String existing, String incoming) => _SelfNoteStore.mergeSelfNotes(existing, incoming);







  /// Removes duplicates already present in storage while preserving the first
  /// position of each group. A later, more informative variant replaces the
  /// shorter wording in place, so cleanup never shuffles the character's
  /// self-note chronology.


















  static Future<String> getSelfNotes(String characterId) => _SelfNoteStore.getSelfNotes(characterId);

  static Future<String> getSelfNotesForPrompt(
    String characterId, {
    required int limit,
  }) => _SelfNoteStore.getSelfNotesForPrompt(characterId, limit: limit);

  static Future<List<CharacterSelfNote>> getSelfNoteRecords(
    String characterId,
  ) => _SelfNoteStore.getSelfNoteRecords(characterId);

  static Future<bool> setSelfNoteLocked(int id, bool locked) => _SelfNoteStore.setSelfNoteLocked(id, locked);

  static Future<void> bindSelfNotesToMessage(
    Iterable<int> ids,
    int messageId,
  ) => _SelfNoteStore.bindSelfNotesToMessage(ids, messageId);

  static Future<void> _backfillCharacterSelfNotes(
    DatabaseExecutor db, {
    String? characterId,
  }) => _SelfNoteStore._backfillCharacterSelfNotes(db, characterId: characterId);

  /// One-time/lifecycle cleanup for existing characters. This deliberately
  /// touches only the authoritative character record; conversation-pinned
  /// snapshots remain immutable so an old cache prefix is never rewritten.
  static Future<void> _deduplicateAllStoredSelfNotes(Database db) => _SelfNoteStore._deduplicateAllStoredSelfNotes(db);

  static Future<void> clearSelfNotes(String characterId) => _SelfNoteStore.clearSelfNotes(characterId);

  static Future<void> insertCharacter(Map<String, dynamic> char) => _CharacterStore.insertCharacter(char);

  static Future<void> updateCharacter(
    String id,
    Map<String, dynamic> updates,
  ) => _CharacterStore.updateCharacter(id, updates);

  /// Runtime whisper updates must not reorder the character list by touching
  /// updated_at. Card edits continue to use [updateCharacter].
  static Future<void> updateCharacterWhisper(
    String id, {
    String? userText,
    String? modelText,
    String? source,
    bool? modelOverrideEnabled,
  }) => _CharacterStore.updateCharacterWhisper(id, userText: userText, modelText: modelText, source: source, modelOverrideEnabled: modelOverrideEnabled);

  /// Runtime-generated signatures must not reorder the character carousel.
  static Future<void> updateCharacterSignature(
    String id,
    String signature,
  ) => _CharacterStore.updateCharacterSignature(id, signature);

  /// Builds a partial character update without allowing identity/creation
  /// metadata to be rewritten. Because this map contains only supplied fields,
  /// runtime-managed and future columns omitted by callers stay untouched.
  @visibleForTesting
  static Map<String, dynamic> sanitizeCharacterUpdates(
    Map<String, dynamic> updates, {
    String? updatedAt,
  }) => _CharacterStore.sanitizeCharacterUpdates(updates, updatedAt: updatedAt);

  static Future<List<Map<String, dynamic>>> getCharacters() => _CharacterStore.getCharacters();

  static Future<Map<String, dynamic>?> getCharacter(String id) => _CharacterStore.getCharacter(id);

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

  static Future<void> deleteCharacter(String id) => _CharacterStore.deleteCharacter(id);

  // ═══════════════════════════════════
  // 對話操作（帶角色過濾）
  // ═══════════════════════════════════

  static Future<void> createConversation(Conversation conv) => _ConversationStore.createConversation(conv);



  static Future<List<Map<String, Object?>>> getRpStorylines(
    String characterId, {
    bool includeArchived = false,
  }) => _ConversationStore.getRpStorylines(characterId, includeArchived: includeArchived);

  static Future<void> ensureDefaultRpStoryline(String characterId) => _ConversationStore.ensureDefaultRpStoryline(characterId);

  static Future<String> createRpStoryline({
    required String characterId,
    required String name,
  }) => _ConversationStore.createRpStoryline(characterId: characterId, name: name);

  static Future<void> renameRpStoryline({
    required String characterId,
    required String storylineId,
    required String name,
  }) => _ConversationStore.renameRpStoryline(characterId: characterId, storylineId: storylineId, name: name);

  static Future<void> setRpStorylineArchived({
    required String characterId,
    required String storylineId,
    required bool archived,
  }) => _ConversationStore.setRpStorylineArchived(characterId: characterId, storylineId: storylineId, archived: archived);

  static Future<void> setDefaultRpStoryline({
    required String characterId,
    required String storylineId,
  }) => _ConversationStore.setDefaultRpStoryline(characterId: characterId, storylineId: storylineId);

  static Future<bool> hasConversationHistoryForCharacter({
    required String characterId,
    required ContextMode contextMode,
  }) => _ConversationStore.hasConversationHistoryForCharacter(characterId: characterId, contextMode: contextMode);

  /// Rebinds a newly-created, still-empty RP window to another storyline.
  /// Once any message exists, the immutable window identity is left untouched.
  static Future<bool> rebindEmptyRpConversation({
    required String conversationId,
    required String characterId,
    required String storylineId,
    required String userPersonaId,
    required String userPersonaSnapshot,
  }) => _ConversationStore.rebindEmptyRpConversation(conversationId: conversationId, characterId: characterId, storylineId: storylineId, userPersonaId: userPersonaId, userPersonaSnapshot: userPersonaSnapshot);

  static Future<void> updateConversation(String id, {String? title}) => _ConversationStore.updateConversation(id, title: title);

  /// 修正對話的角色綁定（角色 ID 失效時的恢復路徑）
  static Future<void> updateConversationCharacter(
    String conversationId,
    String characterId,
  ) => _ConversationStore.updateConversationCharacter(conversationId, characterId);

  /// 星標 / 取消星標
  static Future<void> toggleStarConversation(String id, bool starred) => _ConversationStore.toggleStarConversation(id, starred);

  static Future<List<Conversation>> getConversations({
    String? characterId,
  }) => _ConversationStore.getConversations(characterId: characterId);

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
  }) => _ConversationStore.getPreviousConversationTurns(currentConversationId: currentConversationId, characterId: characterId, contextMode: contextMode, continuityId: continuityId, turnCount: turnCount);

  /// 從按時間正序的消息中取得最後 N 組完整 user→assistant 回合。
  /// 續接內容不從半個回合或連續同角色消息開始，避免模型誤判接棒點。


  /// 新窗口可續接的同模式來源窗口。候選依最後一條消息時間排序；
  /// 每個候選只攜帶最後一個完整回合（兩條正文）與該時間點最新一份
  /// 完整滾動摘要。摘要本身已經是替換式卷宗，不再疊加兩份造成重複。
  static Future<List<RpChapterContinuationSource>>
  getRpChapterContinuationSources({
    required String currentConversationId,
    required String characterId,
    required String continuityId,
    ContextMode contextMode = ContextMode.rp,
    int limit = 20,
  }) => _ConversationStore.getRpChapterContinuationSources(currentConversationId: currentConversationId, characterId: characterId, continuityId: continuityId, contextMode: contextMode, limit: limit);

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
  }) => _ConversationStore.getRpChapterContinuationSource(sourceConversationId: sourceConversationId, currentConversationId: currentConversationId, characterId: characterId, continuityId: continuityId, contextMode: contextMode, throughMessageId: throughMessageId, summariesThrough: summariesThrough);

  static Future<Message?> getLatestRpChapterContinuationAction(
    String conversationId,
  ) => _ConversationStore.getLatestRpChapterContinuationAction(conversationId);



  /// 搜索對話（窗口標題或窗口內任一消息模糊匹配）。
  ///
  /// 使用 EXISTS 而不是 JOIN，避免同一窗口命中多條消息時在歷史列表重複
  /// 出現；也不限制消息時間，因此早期窗口仍能被跨窗口關鍵詞找回。
  static Future<List<Conversation>> searchConversations(
    String query, {
    String? characterId,
  }) => _ConversationStore.searchConversations(query, characterId: characterId);

  static Future<Conversation?> getConversation(String id) => _ConversationStore.getConversation(id);

  static Future<String> ensureConversationWindowSummaryId(String id) => _ConversationStore.ensureConversationWindowSummaryId(id);

  /// 產生並強制更新一個新的 window_summary_id 給指定對話
  static Future<String> rotateConversationWindowSummaryId(String id) => _ConversationStore.rotateConversationWindowSummaryId(id);

  static Future<String?> getConversationWindowSummaryId(String id) => _ConversationStore.getConversationWindowSummaryId(id);

  static Future<int> getConversationSummaryCursor(String id) => _ConversationStore.getConversationSummaryCursor(id);

  /// 讀取對話的靜態摘要 pin。null = 從未釘過（含遷移前的既有對話）；
  /// 空字串 = 出生時無前情、已釘為空。兩者要分開，別用 DEFAULT ''。
  static Future<String?> getConversationPinnedSummary(String id) => _ConversationStore.getConversationPinnedSummary(id);

  /// 原子釘死對話的靜態摘要文本。
  ///
  /// 多個 prompt builder 同時首建時，只允許第一個寫入；其餘呼叫端
  /// 讀回資料庫中已釘定的正規值，避免同一 conversation 出現兩份
  /// 不同的 static prefix。空字串也是有效的已釘值。
  static Future<String> setConversationPinnedSummaryIfAbsent(
    String id,
    String text,
  ) => _ConversationStore.setConversationPinnedSummaryIfAbsent(id, text);

  static Future<String?> getConversationPinnedSelfNotes(String id) => _ConversationStore.getConversationPinnedSelfNotes(id);

  /// conversation 出生時只釘一次自我註記全量；之後新註記只走 dynamic。
  static Future<String> setConversationPinnedSelfNotesIfAbsent(
    String id,
    String text,
  ) => _ConversationStore.setConversationPinnedSelfNotesIfAbsent(id, text);

  /// Returns the shell-balance baseline frozen for this conversation window.
  /// A null value means this window has not built its static prompt yet.
  static Future<ConversationCoinSnapshot?> getConversationPinnedCoinSnapshot(
    String id,
  ) => _ConversationStore.getConversationPinnedCoinSnapshot(id);

  /// Atomically freezes the first shell-balance baseline for a conversation.
  /// Later grants, transfers and scratch-card results are request-only deltas.
  static Future<ConversationCoinSnapshot>
  setConversationPinnedCoinSnapshotIfAbsent(
    String id, {
    required int characterCoins,
    required int userCoins,
  }) => _ConversationStore.setConversationPinnedCoinSnapshotIfAbsent(id, characterCoins: characterCoins, userCoins: userCoins);

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

  static Future<void> deleteConversation(String id) => _ConversationStore.deleteConversation(id);

  // ═══════════════════════════════════
  // 訊息操作
  // ═══════════════════════════════════

  static Future<int> insertMessage(Message msg) => _MessageStore.insertMessage(msg);

  /// 從指定 message id（含）起載入對話全部消息——上下文窗口錨點用。
  /// 錨點指向的消息被刪時，自然從下一條 id 開始，不會返回空窗。
  static Future<List<Message>> getMessagesFromId(
    String conversationId,
    int fromId,
  ) => _MessageStore.getMessagesFromId(conversationId, fromId);

  /// Window-summary source after the last successfully persisted cursor.
  /// Message ids are global and monotonic, so the conversation predicate keeps
  /// this query deterministic even when several windows are active together.
  static Future<List<Message>> getMessagesAfterId(
    String conversationId,
    int afterId,
  ) => _MessageStore.getMessagesAfterId(conversationId, afterId);

  static Future<int?> getLatestMessageId(String conversationId) => _MessageStore.getLatestMessageId(conversationId);

  /// Message anchors whose automatic rolling summary has been persisted.
  ///
  /// This UI-only metadata stays on a visible message so it follows backup,
  /// restore, branching, and deletion without ever entering prompt history.
  static Future<Set<int>> getSummaryRecordedMessageIds(
    String conversationId,
  ) => _MessageStore.getSummaryRecordedMessageIds(conversationId);

  /// UI anchors mapped to the exact automatic summary they open.
  ///
  /// New summaries persist this relation directly. For pre-v67 rows, retain a
  /// single best-effort shortcut for the latest automatic summary instead of
  /// losing the entry point entirely.
  static Future<Map<int, int>> getSummaryRecordedAnchors(
    String conversationId,
  ) => _MessageStore.getSummaryRecordedAnchors(conversationId);

  /// 從 [sourceConversationId] 開分支：複製 [beforeMessageId] 之前的
  /// 全部消息到新對話（原對話一字不動），返回新對話 id。
  /// 用途：編輯發送窗之外的老消息時不破壞原時間線，另起爐灶。
  static Future<String> branchConversation({
    required String sourceConversationId,
    required int beforeMessageId,
    String? title,
  }) => _MessageStore.branchConversation(sourceConversationId: sourceConversationId, beforeMessageId: beforeMessageId, title: title);

  /// 取指定 id 之前的最後 [limit] 條（升序返回）——錨點前純顯示分頁用
  static Future<List<Message>> getMessagesBeforeId(
    String conversationId,
    int beforeId, {
    int limit = 50,
  }) => _MessageStore.getMessagesBeforeId(conversationId, beforeId, limit: limit);

  /// 指定 id 之前是否還有消息（「查看更早」按鈕顯示條件）
  static Future<bool> hasMessagesBefore(
    String conversationId,
    int beforeId,
  ) => _MessageStore.hasMessagesBefore(conversationId, beforeId);

  static Future<List<Message>> getMessages(
    String conversationId, {
    int? limit,
    int? offset,
  }) => _MessageStore.getMessages(conversationId, limit: limit, offset: offset);

  /// Latest display page ending at the immutable RP handoff message.
  static Future<List<Message>> getMessagesUpToId(
    String conversationId,
    int throughMessageId, {
    int limit = 50,
  }) => _MessageStore.getMessagesUpToId(conversationId, throughMessageId, limit: limit);

  static Future<int> getMessageCount(String conversationId) => _MessageStore.getMessageCount(conversationId);

  /// Approximate source volume for one RP storyline without loading its full
  /// dialogue into Dart. Character count is sufficient for choosing a soft
  /// dossier ceiling; exact request tokens are still measured at send time.
  static Future<int> getRpStorylineSourceCharacterCount({
    required String characterId,
    required String continuityId,
  }) => _MessageStore.getRpStorylineSourceCharacterCount(characterId: characterId, continuityId: continuityId);

  static Future<Message?> getLastMessage(String conversationId) => _MessageStore.getLastMessage(conversationId);

  static Future<void> deleteMessageById(
    int id, {
    String reason = 'delete',
  }) => _MessageStore.deleteMessageById(id, reason: reason);

  static Future<void> deleteMessageByFingerprint(
    Message msg, {
    String reason = 'delete',
  }) => _MessageStore.deleteMessageByFingerprint(msg, reason: reason);

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

  static Future<Message?> getMessageById(int id) => _MessageStore.getMessageById(id);

  /// Confirms that every source message still exists at the same revision.
  /// Summary/model calls run outside SQLite transactions; this check prevents
  /// an edit or re-roll that happens during the call from persisting a stale
  /// result after the invalidation transaction has already finished.
  static Future<bool> messageSnapshotsStillCurrent(
    Iterable<Message> snapshots,
  ) => _MessageStore.messageSnapshotsStillCurrent(snapshots);

  static Future<List<ChatDiagnosticEvent>> getChatDiagnostics(
    String conversationId,
  ) => _MessageStore.getChatDiagnostics(conversationId);

  static Future<ChatDiagnosticEvent> upsertChatDiagnostic(
    ChatDiagnosticEvent event,
  ) => _MessageStore.upsertChatDiagnostic(event);

  static Future<void> deleteChatDiagnostic(int id) => _MessageStore.deleteChatDiagnostic(id);

  static Future<void> deleteChatDiagnosticsForMessages(
    Iterable<int> messageIds,
  ) => _MessageStore.deleteChatDiagnosticsForMessages(messageIds);

  /// 覆蓋消息文本（不刪除原記錄）
  static Future<void> updateMessageText(int id, String newText) => _MessageStore.updateMessageText(id, newText);

  static Future<bool> updateMessagePersonaCard(
    int messageId,
    PersonaCardState state,
  ) => _MessageStore.updateMessagePersonaCard(messageId, state);

  /// Atomically creates the character and converts its source reply's draft
  /// card into the persistent "added" state. If that reply was removed first,
  /// nothing is created, preventing an orphan character from a stale card tap.
  static Future<bool> addCharacterFromPersonaCard({
    required int messageId,
    required Map<String, Object?> character,
    required PersonaCardState cardState,
  }) => _MessageStore.addCharacterFromPersonaCard(messageId: messageId, character: character, cardState: cardState);

  static Future<void> _archiveMessageRevision(
    DatabaseExecutor db,
    Map<String, Object?> row, {
    required String reason,
  }) => _MessageInvalidation._archiveMessageRevision(db, row, reason: reason);

  /// Invalidates the first summary that consumed [messageId] and every later
  /// summary derived from it. Invalid rows stay in SQLite for audit and repair,
  /// but disappear from injection, labels and user-facing summary lookup.
  static Future<void> _invalidateSummaryChainForMessage(
    DatabaseExecutor db, {
    required String conversationId,
    required int messageId,
    required String reason,
  }) => _MessageInvalidation._invalidateSummaryChainForMessage(db, conversationId: conversationId, messageId: messageId, reason: reason);





  /// Removes RP timeline rows sourced from an invalidated summary chain.
  ///
  /// Timeline rows predate source_summary_id, so the covered message ranges
  /// are the authoritative bridge. This intentionally fails closed: the
  /// replacement summary will recreate valid events, while stale events must
  /// not remain available for recall between edit/re-roll and regeneration.


  static Future<void> updateMessageStatus(int id, String status) => _MessageInvalidation.updateMessageStatus(id, status);

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

  static Future<int> insertMemory(Memory mem) => _MemoryStore.insertMemory(mem);

  static Future<void> insertMemories(List<Memory> memories) => _MemoryStore.insertMemories(memories);

  static Future<List<Memory>> getActiveMemories(
    String mode, {
    String characterId = 'default',
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _MemoryStore.getActiveMemories(mode, characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  /// 取得角色所有模式下的 active 記憶。蛛網分層必須從完整集合規劃，否則
  /// 舊連線的另一端若在不同模式，畫面會誤以為邊不存在。
  static Future<List<Memory>> getAllActiveMemories({
    String characterId = 'default',
    ContextMode? contextMode,
    String continuityId = 'main',
  }) => _MemoryStore.getAllActiveMemories(characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  static Future<List<Memory>> getPermanentMemories(
    String mode, {
    String characterId = 'default',
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _MemoryStore.getPermanentMemories(mode, characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  static Future<List<Memory>> searchMemories(
    String mode,
    String keyword, {
    String characterId = 'default',
    int limit = 10,
  }) => _MemoryStore.searchMemories(mode, keyword, characterId: characterId, limit: limit);

  /// 跨模式搜尋內容、觸發詞與類別。
  /// [limit] 為 null 時回傳全部結果；記憶整理搜尋不與對話召回上限綁定。
  static Future<List<Memory>> searchMemoriesForCharacter(
    String keyword, {
    String characterId = 'default',
    int? limit = 10,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) => _MemoryStore.searchMemoriesForCharacter(keyword, characterId: characterId, limit: limit, contextMode: contextMode, continuityId: continuityId);

  /// 獲取低置信度待審記憶
  static Future<List<Memory>> getLowConfidenceForReview({
    String characterId = 'default',
    int minCount = 3,
  }) => _MemoryStore.getLowConfidenceForReview(characterId: characterId, minCount: minCount);

  /// 記憶被關鍵詞命中注入時 +1（衰減校準的原始數據）
  static Future<void> incrementMention(int memoryId) => _MemoryStore.incrementMention(memoryId);

  /// 低置信度累計 +1
  static Future<void> incrementReviewCount(int memoryId) => _MemoryStore.incrementReviewCount(memoryId);

  static Future<bool> archiveMemory(
    int memoryId,
    String reason, {
    required String characterId,
  }) => _MemoryStore.archiveMemory(memoryId, reason, characterId: characterId);

  /// Atomically moves every matching active memory into the dusty box.
  /// Missing/stale ids are ignored, while all rows that are found commit as
  /// one unit so a failed batch never leaves a half-deleted selection.
  static Future<int> archiveMemories(
    Iterable<int> memoryIds,
    String reason, {
    required String characterId,
  }) => _MemoryStore.archiveMemories(memoryIds, reason, characterId: characterId);



  /// 升級低置信度記憶為中置信度
  static Future<void> promoteMemory(int memoryId) => _MemoryStore.promoteMemory(memoryId);

  static Future<int> getMemoryCount(
    String mode, {
    String characterId = 'default',
  }) => _MemoryStore.getMemoryCount(mode, characterId: characterId);

  // ═══════════════════════════════════
  // 表情包操作
  // ═══════════════════════════════════

  static Future<int> insertSticker(Map<String, dynamic> sticker) => _NoteStickerStore.insertSticker(sticker);

  static Future<List<Map<String, dynamic>>> getStickers({
    String characterId = 'user',
  }) => _NoteStickerStore.getStickers(characterId: characterId);

  static Future<void> deleteSticker(int id) => _NoteStickerStore.deleteSticker(id);

  static Future<void> updateStickerFilePath(int id, String filePath) => _NoteStickerStore.updateStickerFilePath(id, filePath);

  // ═══════════════════════════════════
  // 歸檔操作（積灰小盒子）
  // ═══════════════════════════════════

  /// 獲取歸檔記憶列表
  static Future<List<Map<String, dynamic>>> getArchivedMemories({
    required String characterId,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) => _MemoryStore.getArchivedMemories(characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  /// 歸檔記憶計數
  static Future<int> getArchivedCount({
    required String characterId,
    ContextMode? contextMode,
    String continuityId = 'main',
  }) => _MemoryStore.getArchivedCount(characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  /// 刪除單條歸檔及其原始記憶。保留舊方法名供既有呼叫者使用，
  /// 但不再留下 status=deleted 且無法恢復的孤兒列。
  static Future<bool> deleteArchivedMemory(
    int archiveId, {
    required String characterId,
  }) => _MemoryStore.deleteArchivedMemory(archiveId, characterId: characterId);

  /// 一鍵清空歸檔
  static Future<void> clearAllArchived({required String characterId}) => _MemoryStore.clearAllArchived(characterId: characterId);

  /// 刪除活躍記憶（歸檔到小盒子 — 軟刪除，保留原始記錄可恢復）
  static Future<bool> deleteMemory(
    int memoryId, {
    bool archive = true,
    required String characterId,
  }) => _MemoryStore.deleteMemory(memoryId, archive: archive, characterId: characterId);

  /// 從積灰小盒子恢復記憶到活躍狀態
  static Future<bool> restoreFromArchive(
    int archiveId, {
    required String characterId,
  }) => _MemoryStore.restoreFromArchive(archiveId, characterId: characterId);

  static Future<int> restoreFromArchives(
    Iterable<int> archiveIds, {
    required String characterId,
  }) => _MemoryStore.restoreFromArchives(archiveIds, characterId: characterId);



  static Future<int> permanentlyDeleteArchives(
    Iterable<int> archiveIds, {
    required String characterId,
  }) => _MemoryStore.permanentlyDeleteArchives(archiveIds, characterId: characterId);

  /// 永久刪除（從 archive 和 memories 都移除）
  static Future<bool> permanentlyDelete(
    int archiveId, {
    required String characterId,
  }) => _MemoryStore.permanentlyDelete(archiveId, characterId: characterId);



  // ═══════════════════════════════════
  // 便利貼
  // ═══════════════════════════════════

  static Future<int> addNote(
    String content, {
    String characterId = 'default',
  }) => _NoteStickerStore.addNote(content, characterId: characterId);

  static Future<List<Map<String, dynamic>>> getNotes({
    int limit = 20,
    String? characterId,
  }) => _NoteStickerStore.getNotes(limit: limit, characterId: characterId);

  static Future<Map<String, dynamic>?> getLatestNote({
    String? characterId,
  }) => _NoteStickerStore.getLatestNote(characterId: characterId);

  /// 隨機取 N 條歷史便箋（排除最新一條）
  static Future<List<Map<String, dynamic>>> getRandomNotes(
    String characterId, {
    int count = 10,
  }) => _NoteStickerStore.getRandomNotes(characterId, count: count);

  static Future<void> deleteNote(int id) => _NoteStickerStore.deleteNote(id);

  /// 舊資料庫的防禦性檢查；fresh/v33 schema 已正式包含此欄位。
  static bool _noteColumnEnsured = false;


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
  }) => _UsageStore.reserveWebSearchProviderLaunches(reservationId: reservationId, conversationId: conversationId, characterId: characterId, turnId: turnId, generationSerial: generationSerial, planStrategy: planStrategy, routes: routes, budgetDay: budgetDay, dailyProviderLaunchCap: dailyProviderLaunchCap, reservedAt: reservedAt, expiresAt: expiresAt);

  /// Consumes the durable half of a permission grant by binding it to exactly
  /// one ToolCall id. The handler still has to claim the bound reservation.
  static Future<bool> bindWebSearchReservationToCall({
    required String reservationId,
    required String callId,
    required String now,
  }) => _UsageStore.bindWebSearchReservationToCall(reservationId: reservationId, callId: callId, now: now);

  /// Handler-only transition. It extends the short permission expiry into an
  /// execution lease so another reservation cannot reap an active request.
  static Future<bool> claimWebSearchReservation({
    required String reservationId,
    required String callId,
    required String budgetDay,
    required String claimedAt,
    required String executionExpiresAt,
  }) => _UsageStore.claimWebSearchReservation(reservationId: reservationId, callId: callId, budgetDay: budgetDay, claimedAt: claimedAt, executionExpiresAt: executionExpiresAt);

  /// Must be called immediately before dispatching a provider request.
  static Future<bool> markWebSearchProviderLaunched({
    required String reservationId,
    required String callId,
    required String provider,
    required String providerModel,
    required String providerRoute,
    required String launchedAt,
  }) => _UsageStore.markWebSearchProviderLaunched(reservationId: reservationId, callId: callId, provider: provider, providerModel: providerModel, providerRoute: providerRoute, launchedAt: launchedAt);

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
  }) => _UsageStore.settleWebSearchProviderLaunch(reservationId: reservationId, callId: callId, provider: provider, providerModel: providerModel, providerRoute: providerRoute, outcome: outcome, settledAt: settledAt, searchRequests: searchRequests, promptTokens: promptTokens, completionTokens: completionTokens, actualCostUsd: actualCostUsd, costCertainty: costCertainty);

  /// Releases only routes for which no provider dispatch was recorded.
  static Future<int> releaseUnlaunchedWebSearchReservation({
    required String reservationId,
    String? callId,
    required String settledAt,
  }) => _UsageStore.releaseUnlaunchedWebSearchReservation(reservationId: reservationId, callId: callId, settledAt: settledAt);

  /// Counts provider dispatches, not logical calls and not unused reservations.
  static Future<int> getWebSearchProviderLaunchCount(String budgetDay) => _UsageStore.getWebSearchProviderLaunchCount(budgetDay);

  static Future<void> logUsage({
    required String provider,
    required String model,
    String characterId = 'default',
    String conversationId = '',
    int promptTokens = 0,
    int completionTokens = 0,
    int cacheHitTokens = 0,
    int cacheCreationTokens = 0,
    double estimatedCost = 0.0,
    String requestKind = 'unknown',
    bool costKnown = false,
  }) => _UsageStore.logUsage(provider: provider, model: model, characterId: characterId, conversationId: conversationId, promptTokens: promptTokens, completionTokens: completionTokens, cacheHitTokens: cacheHitTokens, cacheCreationTokens: cacheCreationTokens, estimatedCost: estimatedCost, requestKind: requestKind, costKnown: costKnown);

  /// 獲取某段時間的用量彙總
  static Future<Map<String, dynamic>> getUsageSummary(
    DateTime from,
    DateTime to,
  ) => _UsageStore.getUsageSummary(from, to);

  /// 獲取每日用量（折線圖用）
  static Future<List<Map<String, dynamic>>> getDailyUsage(
    DateTime from,
    DateTime to,
  ) => _UsageStore.getDailyUsage(from, to);

  /// 按模型分組的用量
  static Future<List<Map<String, dynamic>>> getUsageByModel(
    DateTime from,
    DateTime to,
  ) => _UsageStore.getUsageByModel(from, to);

  /// 按功能分類的 API 請求次數。即使供應商沒有回傳 Token 或費用，
  /// 成功完成的請求仍保留一筆，避免摘要與工具調用在用量頁消失。
  static Future<List<Map<String, dynamic>>> getUsageByRequestKind(
    DateTime from,
    DateTime to,
  ) => _UsageStore.getUsageByRequestKind(from, to);

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
  }) => _SavedMessageStore.saveMessage(messageId: messageId, content: content, characterId: characterId, conversationId: conversationId);

  /// 取消收藏
  static Future<void> unsaveMessage(String messageId) => _SavedMessageStore.unsaveMessage(messageId);

  /// 查詢是否已收藏
  static Future<bool> isMessageSaved(String messageId) => _SavedMessageStore.isMessageSaved(messageId);

  /// 獲取角色的收藏消息
  static Future<List<Map<String, dynamic>>> getSavedMessages({
    String characterId = 'default',
    int limit = 50,
  }) => _SavedMessageStore.getSavedMessages(characterId: characterId, limit: limit);

  /// 搜索收藏（關鍵詞匹配內容 + 日期格式如 7/3 匹配 created_at）
  static Future<List<Map<String, dynamic>>> searchSavedMessages(
    String query, {
    String characterId = 'default',
  }) => _SavedMessageStore.searchSavedMessages(query, characterId: characterId);

  /// 刪除收藏
  static Future<void> deleteSavedMessage(int id) => _SavedMessageStore.deleteSavedMessage(id);

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
    List<ContextSummarySegmentDraft> recallSegments =
        const <ContextSummarySegmentDraft>[],
  }) => _ContextSummaryStore.insertContextSummary(characterId: characterId, content: content, tokenCount: tokenCount, sourceWindowId: sourceWindowId, sourceConversationId: sourceConversationId, displayAnchorMessageId: displayAnchorMessageId, sourceMessageStartId: sourceMessageStartId, sourceMessageEndId: sourceMessageEndId, replaceSummaryId: replaceSummaryId, replaceInvalidatedSummary: replaceInvalidatedSummary, storyTimeText: storyTimeText, expectedSourceMessages: expectedSourceMessages, allowPendingRepairs: allowPendingRepairs, contextMode: contextMode, continuityId: continuityId, recallSegments: recallSegments);

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
    List<ContextSummarySegmentDraft> recallSegments =
        const <ContextSummarySegmentDraft>[],
  }) => _ContextSummaryStore.insertContextSummaryAndAdvanceCursor(characterId: characterId, content: content, tokenCount: tokenCount, conversationId: conversationId, cursorMessageId: cursorMessageId, displayAnchorMessageId: displayAnchorMessageId, sourceMessageStartId: sourceMessageStartId, storyTimeText: storyTimeText, sourceWindowId: sourceWindowId, expectedSourceMessages: expectedSourceMessages, allowPendingRepairs: allowPendingRepairs, contextMode: contextMode, continuityId: continuityId, recallSegments: recallSegments);





  static Future<List<Map<String, dynamic>>> getContextSummarySegments(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    bool archivedOnly = false,
  }) => _ContextSummaryStore.getContextSummarySegments(characterId, contextMode: contextMode, continuityId: continuityId, archivedOnly: archivedOnly);

  /// 已在本次 App 生命週期內跑過標籤自修復的 RP 範圍（角色|故事線）。
  /// 修復本身是寫入路徑，不該每輪聊天都跑；歸檔與手動摘要會另外主動呼叫。
  static final Set<String> _recallIndexHealedScopes = <String>{};

  /// 關鍵詞召回的輕量索引：只撈比對需要的欄位，**不撈摘要全文**。
  /// RP：有效 segment ＋ 尚未被 segment 覆蓋的舊版標籤；日常：標籤。
  /// 命中後再用 [fillRecallContents] 只撈候選的全文。
  static Future<List<Map<String, dynamic>>> getRecallIndexRows(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
  }) => _ContextSummaryStore.getRecallIndexRows(characterId, contextMode: contextMode, continuityId: continuityId);

  /// 只替召回候選補上全文（`source_summary_content`），保持傳入順序。
  static Future<List<Map<String, dynamic>>> fillRecallContents(
    List<Map<String, dynamic>> candidates,
  ) => _ContextSummaryStore.fillRecallContents(candidates);







  /// 取得角色的全部摘要塊（舊→新）
  static Future<List<Map<String, dynamic>>> getContextSummaries(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
    bool includeArchived = false,
  }) => _ContextSummaryStore.getContextSummaries(characterId, contextMode: contextMode, continuityId: continuityId, includeArchived: includeArchived);

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
  }) => _ContextSummaryStore.getContextSummaryByExactSourceSpan(characterId: characterId, contextMode: contextMode, continuityId: continuityId, conversationId: conversationId, sourceMessageStartId: sourceMessageStartId, sourceMessageEndId: sourceMessageEndId);

  /// 取得角色最新摘要塊（新→舊），可排除目前窗口
  static Future<List<Map<String, dynamic>>> getLatestContextSummaries(
    String characterId, {
    String? excludeWindowId,
    int limit = 2,
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextSummaryStore.getLatestContextSummaries(characterId, excludeWindowId: excludeWindowId, limit: limit, contextMode: contextMode, continuityId: continuityId);

  static Future<List<Map<String, dynamic>>> getRelevantContextSummaries(
    String characterId, {
    required ContextMode contextMode,
    required String continuityId,
    Iterable<String> sourceConversationIds = const <String>[],
    int limit = 3,
  }) => _ContextSummaryStore.getRelevantContextSummaries(characterId, contextMode: contextMode, continuityId: continuityId, sourceConversationIds: sourceConversationIds, limit: limit);

  static Future<Map<String, dynamic>?> getLatestConversationContextSummary({
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) => _ContextSummaryStore.getLatestConversationContextSummary(conversationId: conversationId, contextMode: contextMode, continuityId: continuityId);

  static Future<Map<String, dynamic>?> getConversationContextSummaryById({
    required int summaryId,
    required String conversationId,
    required ContextMode contextMode,
    required String continuityId,
  }) => _ContextSummaryStore.getConversationContextSummaryById(summaryId: summaryId, conversationId: conversationId, contextMode: contextMode, continuityId: continuityId);

  /// 取得摘要總 token 數
  static Future<int> getContextSummaryTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextSummaryStore.getContextSummaryTokenTotal(characterId, contextMode: contextMode, continuityId: continuityId);

  /// 覆蓋摘要塊
  static Future<void> updateContextSummary({
    required int id,
    required String content,
    required int tokenCount,
  }) => _ContextSummaryStore.updateContextSummary(id: id, content: content, tokenCount: tokenCount);

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
  }) => _ContextSummaryStore.archiveContextSummaryWithKeywords(summaryId: summaryId, characterId: characterId, contextMode: contextMode, continuityId: continuityId, keywords: keywords, keywordTokenCount: keywordTokenCount);

  /// Archives one RP summary using the segment labels emitted alongside that
  /// summary. No follow-up model call is allowed in this path.
  static Future<bool> archiveContextSummaryWithStoredSegments({
    required int summaryId,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) => _ContextSummaryStore.archiveContextSummaryWithStoredSegments(summaryId: summaryId, characterId: characterId, contextMode: contextMode, continuityId: continuityId);

  /// Marks stale repair jobs covered by a successful user-requested summary.
  /// Only exact source spans fully contained by the new summary are closed.
  static Future<int> completeCoveredSummaryRepairs({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
    required String conversationId,
    required int sourceMessageStartId,
    required int sourceMessageEndId,
    required int replacementSummaryId,
  }) => _ContextSummaryStore.completeCoveredSummaryRepairs(characterId: characterId, contextMode: contextMode, continuityId: continuityId, conversationId: conversationId, sourceMessageStartId: sourceMessageStartId, sourceMessageEndId: sourceMessageEndId, replacementSummaryId: replacementSummaryId);

  /// Rebuilds missing active labels from immutable segments of valid archived
  /// summaries. This performs no model call and never revives invalid content.
  static Future<int> restoreArchivedSummaryKeywords({
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) => _ContextSummaryStore.restoreArchivedSummaryKeywords(characterId: characterId, contextMode: contextMode, continuityId: continuityId);





  /// 更新摘要鎖定狀態
  static Future<void> updateSummaryLockState({
    required int id,
    required bool locked,
  }) => _ContextSummaryStore.updateSummaryLockState(id: id, locked: locked);

  /// 刪除指定摘要塊
  static Future<void> deleteContextSummary(int id) => _ContextSummaryStore.deleteContextSummary(id);

  /// 刪除最舊的摘要塊，返回被刪的記錄
  static Future<Map<String, dynamic>?> deleteOldestContextSummary(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextSummaryStore.deleteOldestContextSummary(characterId, contextMode: contextMode, continuityId: continuityId);

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
  }) => _ContextKeywordStore.insertContextKeywords(characterId: characterId, keywords: keywords, tokenCount: tokenCount, sourceSummaryId: sourceSummaryId, sourceSummaryContent: sourceSummaryContent, sourceWindowId: sourceWindowId, sourceConversationId: sourceConversationId, contextMode: contextMode, continuityId: continuityId);

  /// 取得關鍵詞層
  static Future<List<Map<String, dynamic>>> getContextKeywords(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextKeywordStore.getContextKeywords(characterId, contextMode: contextMode, continuityId: continuityId);

  /// 取得關鍵詞總 token 數
  static Future<int> getContextKeywordTokenTotal(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextKeywordStore.getContextKeywordTokenTotal(characterId, contextMode: contextMode, continuityId: continuityId);

  /// 覆蓋關鍵詞塊與其來源摘要快照
  static Future<void> updateContextKeywordBlock({
    required int id,
    required String keywords,
    required int tokenCount,
    required String sourceSummaryContent,
  }) => _ContextKeywordStore.updateContextKeywordBlock(id: id, keywords: keywords, tokenCount: tokenCount, sourceSummaryContent: sourceSummaryContent);

  /// 刪除最舊的關鍵詞塊
  static Future<void> deleteOldestContextKeyword(
    String characterId, {
    ContextMode contextMode = ContextMode.daily,
    String continuityId = 'main',
  }) => _ContextKeywordStore.deleteOldestContextKeyword(characterId, contextMode: contextMode, continuityId: continuityId);

  /// 清空角色的全部摘要和關鍵詞（角色刪除時用）
  static Future<void> clearContextData(String characterId) => _ContextKeywordStore.clearContextData(characterId);

  static Future<List<Map<String, dynamic>>> getSpiderWebLinks(
    String characterId, {
    bool includeRejected = false,
  }) => _SpiderWebStore.getSpiderWebLinks(characterId, includeRejected: includeRejected);

  /// 建立一條經角色、active 狀態與自環檢查的蛛網連線。
  static Future<bool> insertSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) => _SpiderWebStore.insertSpiderWebLink(characterId, firstMemoryId, secondMemoryId);

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
  }) => _SpiderWebStore.upsertSpiderWebRelation(characterId, firstMemoryId, secondMemoryId, relationType: relationType, strength: strength, status: status, source: source, reason: reason);

  static Future<SpiderWebRelationWriteResult> upsertSpiderWebRelationDetailed(
    String characterId,
    int firstMemoryId,
    int secondMemoryId, {
    required String relationType,
    required double strength,
    required String status,
    required String source,
    required String reason,
  }) => _SpiderWebStore.upsertSpiderWebRelationDetailed(characterId, firstMemoryId, secondMemoryId, relationType: relationType, strength: strength, status: status, source: source, reason: reason);

  static Future<bool> resolveSpiderWebRelation(
    String characterId,
    int relationId, {
    required bool confirmed,
  }) => _SpiderWebStore.resolveSpiderWebRelation(characterId, relationId, confirmed: confirmed);

  /// Removes one graph edge without touching either memory. Both endpoints
  /// are normalized exactly like insertion, and character scope is mandatory.
  static Future<bool> deleteSpiderWebLink(
    String characterId,
    int firstMemoryId,
    int secondMemoryId,
  ) => _SpiderWebStore.deleteSpiderWebLink(characterId, firstMemoryId, secondMemoryId);
}
