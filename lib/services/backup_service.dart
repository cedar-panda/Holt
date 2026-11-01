import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import '../models/message.dart';
import '../utils/app_file_safety.dart';
import '../utils/iso_week.dart';
import 'character_timeline_service.dart';
import 'encrypted_backup_bundle.dart';
import 'keep_alive_service.dart';
import 'user_persona_service.dart';
import 'model_cost_policy.dart';
import 'portable_backup_bundle.dart';
import '../utils/app_directories.dart';

class LegacyExportStats {
  final int fileCount;
  final int totalBytes;

  const LegacyExportStats({this.fileCount = 0, this.totalBytes = 0});

  bool get isEmpty => fileCount == 0;
}

/// JSON 備份和本地資料庫備份。
///
/// JSON v5 是「覆蓋還原」格式：先完整解析、驗證及正規化，然後在一個
/// SQLite transaction 內清空並寫回所有 app 資料表。舊 v1-v4 Holt/Yanci
/// 匯出仍可導入；因舊格式沒有 message id，與訊息 ID 有關的欄位只能盡力
/// 由 conversation + content 重新配對。
class BackupService {
  static const int exportVersion = 5;
  static const int _contextModeSchemaVersion = 48;
  static const int _personaSchemaVersion = 50;
  static const int _personaModeSchemaVersion = 51;
  static const int _chatDiagnosticsSchemaVersion = 57;
  static const int _rpStorySchemaVersion = 59;
  static const int _rpRevisionSchemaVersion = 69;
  static const int _rpStoryStateSchemaVersion = 70;
  static const int _rpWorldbookSchemaVersion = 71;
  static const int _rpProjectionRevisionSchemaVersion = 73;
  static const int _summaryRepairSchemaVersion = 73;
  static const int _characterDiarySchemaVersion = 77;
  static const int _characterSelfNotesSchemaVersion = 81;
  static const Set<String> _rpRevisionTables = <String>{
    'rp_storylines',
    'message_revisions',
    'memory_rejection_tombstones',
  };
  static const Set<String> _rpStoryStateTables = <String>{
    'rp_story_entity_aliases',
    'rp_story_states',
  };
  static const Set<String> _rpWorldbookTables = <String>{
    'rp_worldbook_entries',
    'rp_worldbook_sync_state',
    'rp_worldbook_review_items',
  };
  static final _operationLock = _AsyncMutex();

  /// v5 明確列出的 app-owned tables；不包含 sqlite_sequence 等 SQLite 內部表。
  static const List<String> appTables = [
    'characters',
    'character_self_notes',
    'rp_storylines',
    'user_personas',
    'user_persona_mode_overrides',
    'character_persona_bindings',
    'conversations',
    'messages',
    'message_revisions',
    'chat_diagnostics',
    'memories',
    'memory_embeddings',
    'spider_web_links',
    'archive',
    'pending_memory_actions',
    'memory_rejection_tombstones',
    'sticky_notes',
    'character_diaries',
    'shop_items',
    'backpack_items',
    'stickers',
    'saved_messages',
    'context_summaries',
    'context_summary_segments',
    'context_summary_repairs',
    'context_keywords',
    'usage_logs',
    'web_search_usage_logs',
    'emotion_points',
    'grudge_seals',
    'character_timeline',
    'rp_character_timeline',
    'rp_story_characters',
    'rp_story_entity_aliases',
    'rp_story_states',
    'rp_story_relationships',
    'rp_story_relationship_events',
    'rp_story_projection_revisions',
    'rp_worldbook_entries',
    'rp_worldbook_sync_state',
    'rp_worldbook_review_items',
    'character_signatures',
    'saved_voices',
  ];

  // 父表先寫、子表後寫。清除時使用反向順序。
  static const List<String> _insertOrder = appTables;

  static const Set<String> _integerPrimaryKeyTables = {
    'character_self_notes',
    'messages',
    'message_revisions',
    'chat_diagnostics',
    'memories',
    'spider_web_links',
    'archive',
    'sticky_notes',
    'character_diaries',
    'backpack_items',
    'stickers',
    'saved_messages',
    'context_summaries',
    'context_summary_segments',
    'context_summary_repairs',
    'context_keywords',
    'usage_logs',
    'web_search_usage_logs',
    'emotion_points',
    'grudge_seals',
    'character_timeline',
    'rp_character_timeline',
    'rp_story_projection_revisions',
    'character_signatures',
    'saved_voices',
  };

  static bool _isSensitivePreferenceKey(String key) {
    final k = key.toLowerCase();
    return k == 'api_key' ||
        k == 'openrouter_api_key' ||
        k.contains('api_key') ||
        k.endsWith('_key') ||
        k.contains('secret_access_key') ||
        k.contains('access_key') ||
        k.contains('access_token') ||
        k.contains('refresh_token') ||
        k.contains('password') ||
        k.contains('passwd') ||
        k.contains('credential') ||
        k.contains('private_key') ||
        k.contains('authorization') ||
        k.contains('bearer');
  }

  static bool _isDeviceLocalPreferenceKey(String key) {
    final k = key.toLowerCase();
    if (k == 'voice_download_dir') return true;
    // 保活運行時狀態整族排除：keepalive_cached_messages /
    // keepalive_cached_static_prompt 等含完整對話與 prompt（人設、記憶、
    // 自我註記）——跟著導出等於把隱私內容明文塞進備份檔；
    // 而且這是設備本地的瞬時狀態，導到另一台設備只會錯亂。
    return k.startsWith('keepalive_');
  }

  /// 導入不接受密鑰、token、裝置路徑或網路端點。
  ///
  /// 否則惡意備份可把 Base URL 指到第三方主機，再讓 app 將 SecureStore
  /// 裡的真實 API key 當 Bearer token 傳出去。
  static bool _isBlockedImportKey(String key) {
    if (_isSensitivePreferenceKey(key) || _isDeviceLocalPreferenceKey(key)) {
      return true;
    }
    final k = key.toLowerCase();
    return k.contains('base_url') ||
        k.contains('endpoint') ||
        k.endsWith('_url') ||
        k.contains('_host');
  }

  static Map<String, Object?> _exportablePreferences(SharedPreferences prefs) {
    final result = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      if (_isSensitivePreferenceKey(key) || _isDeviceLocalPreferenceKey(key)) {
        continue;
      }
      result[key] = prefs.get(key);
    }
    return result;
  }

  static Future<Map<String, Object?>> _buildExportDataUnlocked() async {
    await _ensureOptionalTables();
    final db = await DatabaseHelper.database;
    await _verifyTableManifest(db);

    late Map<String, List<Map<String, Object?>>> tableData;
    late int dbVersion;
    await db.transaction((txn) async {
      final versionRows = await txn.rawQuery('PRAGMA user_version');
      dbVersion = _pragmaInt(versionRows, 'user_version');

      tableData = <String, List<Map<String, Object?>>>{};
      for (final table in appTables) {
        final rows = await txn.query(table);
        tableData[table] = rows
            .map((row) => Map<String, Object?>.from(row))
            .toList(growable: false);
      }
    });

    // 語音檔本體不在 JSON 裡；file_path 只作同裝置還原判斷。名稱欄位必須
    // 使用 schema 中真正的 `name`，不是舊程式誤用的 display_name。
    final voices = tableData['saved_voices']!;
    tableData['saved_voices'] = voices
        .map(
          (voice) => <String, Object?>{
            'id': voice['id'],
            'file_path': voice['file_path'],
            'name': voice['name'],
            'message_id': voice['message_id'],
            'source_conversation_id': voice['source_conversation_id'],
            'source_conversation_title': voice['source_conversation_title'],
            'character_id': voice['character_id'],
            'duration_ms': voice['duration_ms'],
            'file_size': voice['file_size'],
            'created_at': voice['created_at'],
          },
        )
        .toList(growable: false);

    final prefs = await SharedPreferences.getInstance();
    return <String, Object?>{
      'version': exportVersion,
      'type': 'holt_full_export',
      'app': 'Holt',
      'exported_at': DateTime.now().toIso8601String(),
      'schema': <String, Object?>{
        'database_version': dbVersion,
        'tables': appTables,
      },
      for (final table in appTables) table: tableData[table]!,
      'preferences': _exportablePreferences(prefs),
    };
  }

  /// Password-encrypted portable export containing the database and media.
  static Future<String> exportPortableBundle({required String password}) {
    return _operationLock.synchronized(
      () => _exportPortableBundleUnlocked(password),
    );
  }

  static Future<String> _exportPortableBundleUnlocked(String password) async {
    final data = await _buildExportDataUnlocked();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final exportDir = await _prepareExportDir();
    final documents = await getAppDocumentsDirectory();
    final temporary = await getTemporaryDirectory();
    final snapshotDir = Directory(
      p.join(
        temporary.path,
        'holt_portable_db_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await snapshotDir.create(recursive: true);
    final databaseSnapshot = File(p.join(snapshotDir.path, 'yanci.db'));
    final plainBundle = File(p.join(snapshotDir.path, 'portable.holt.zip'));
    final encryptedOutput = File(
      p.join(exportDir.path, 'holt_backup_$timestamp.holt.backup'),
    );
    try {
      final db = await DatabaseHelper.database;
      await db.execute(_vacuumIntoSql(databaseSnapshot.path));
      await PortableBackupBundle.create(
        backupData: data,
        databaseSnapshot: databaseSnapshot,
        ownedRoot: documents,
        extraOwnedRoots: <Directory>[await getApplicationSupportDirectory()],
        workingRoot: temporary,
        outputFile: plainBundle,
      );
      final encrypted = await EncryptedBackupBundle.encrypt(
        source: plainBundle,
        destination: encryptedOutput,
        password: password,
      );
      return encrypted.path;
    } finally {
      if (await snapshotDir.exists()) {
        await snapshotDir.delete(recursive: true);
      }
    }
  }

  /// Removes a generated export after the system picker or share sheet has
  /// completed. Only Holt-named files inside the app cache are eligible.
  static Future<void> discardExportArtifact(String path) {
    return _operationLock.synchronized(() async {
      final exportDir = await _getExportDir();
      final normalizedDir = p.normalize(p.absolute(exportDir.path));
      final normalizedPath = p.normalize(p.absolute(path));
      final name = p.basename(normalizedPath);
      if (!p.isWithin(normalizedDir, normalizedPath) ||
          !_isExportArtifactName(name)) {
        throw ArgumentError.value(path, 'path', 'Not a Holt export artifact');
      }
      final file = File(normalizedPath);
      if (await file.exists()) await file.delete();
    });
  }

  /// Old builds wrote every export attempt into Android/data/.../files/Holt.
  /// Keep those user files until an explicit, confirmed cleanup action.
  static Future<LegacyExportStats> getLegacyExportStats() async {
    try {
      final files = await _legacyExportFiles();
      var totalBytes = 0;
      for (final file in files) {
        totalBytes += await file.length();
      }
      return LegacyExportStats(fileCount: files.length, totalBytes: totalBytes);
    } catch (error) {
      debugPrint('Legacy export scan failed: $error');
      return const LegacyExportStats();
    }
  }

  static Future<LegacyExportStats> deleteLegacyExports() {
    return _operationLock.synchronized(() async {
      final files = await _legacyExportFiles();
      var removedBytes = 0;
      var removedCount = 0;
      for (final file in files) {
        final length = await file.length();
        await file.delete();
        removedBytes += length;
        removedCount++;
      }
      return LegacyExportStats(
        fileCount: removedCount,
        totalBytes: removedBytes,
      );
    });
  }

  @visibleForTesting
  static bool isExportArtifactNameForTesting(String name) {
    return _isExportArtifactName(name);
  }

  // ════════════════════════════════════
  // 1.5) JSON 導入／覆蓋還原
  // ════════════════════════════════════

  /// 導入 JSON。SQLite 內容只會「全數成功」或「完全不變」。
  ///
  /// v1-v4 沒有 message id，因此收藏訊息會按 conversation + content 做最佳
  /// 努力重新配對；刮刮卡／轉帳等以舊 message id 命名的 preference 無法可靠
  /// 推回原訊息，摘要字串會明確提醒使用者。
  static Future<String> importFromJson(Map<String, dynamic> data) {
    return _operationLock.synchronized(() => _importFromJsonUnlocked(data));
  }

  /// Imports a verified portable media bundle. Extracted files are retained
  /// only when the database transaction succeeds.
  static Future<String> importPortableBundle(String path) {
    return _operationLock.synchronized(
      () => _importPortableBundleUnlocked(path),
    );
  }

  static Future<bool> isEncryptedBackup(String path) {
    return EncryptedBackupBundle.isEncrypted(File(path));
  }

  /// Decrypts a Holt backup into app-private temporary storage and imports the
  /// verified portable ZIP. The temporary plaintext is always removed.
  static Future<String> importEncryptedPortableBundle({
    required String path,
    required String password,
  }) {
    return _operationLock.synchronized(() async {
      final temporary = await getTemporaryDirectory();
      final decryptDir = await Directory(
        p.join(
          temporary.path,
          'holt_decrypt_${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      final plainBundle = File(p.join(decryptDir.path, 'portable.holt.zip'));
      try {
        await EncryptedBackupBundle.decrypt(
          source: File(path),
          destination: plainBundle,
          password: password,
        );
        return await _importPortableBundleUnlocked(plainBundle.path);
      } finally {
        if (await decryptDir.exists()) {
          await decryptDir.delete(recursive: true);
        }
      }
    });
  }

  static Future<String> _importPortableBundleUnlocked(String path) async {
    final documents = await getAppDocumentsDirectory();
    final extracted = await PortableBackupBundle.extract(
      bundle: File(path),
      destinationRoot: documents,
    );
    final String summary;
    try {
      summary = await _importFromJsonUnlocked(extracted.data);
    } catch (_) {
      await extracted.discard();
      rethrow;
    }
    await _purgeOlderImportedMedia(keep: extracted.mediaDirectory);
    return summary;
  }

  /// 可攜備份還原是整個覆蓋：成功後資料只指向這次解出的
  /// HoltImportedMedia/<時間戳>/，更早還原留下的資料夾已沒人在用。
  /// 失敗不影響還原結果。
  static Future<void> _purgeOlderImportedMedia({required Directory keep}) async {
    try {
      final root = keep.parent;
      if (p.basename(root.path) != 'HoltImportedMedia' || !await root.exists()) {
        return;
      }
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory && !p.equals(entity.path, keep.path)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (error) {
      debugPrint('Imported media cleanup failed (${error.runtimeType})');
    }
  }

  /// 自動本地備份（最新一份與上一份）的時間；不存在就是 null。
  static Future<({DateTime? current, DateTime? previous})>
  localBackupTimes() async {
    Future<DateTime?> read(Directory dir) async {
      try {
        final meta = File(p.join(dir.path, 'backup_meta.json'));
        if (!await meta.exists() ||
            !await File(p.join(dir.path, 'yanci.db')).exists()) {
          return null;
        }
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is! Map) return null;
        return DateTime.tryParse(decoded['backed_up_at']?.toString() ?? '');
      } catch (_) {
        return null;
      }
    }

    final current = await _getBackupDir(create: false);
    return (
      current: await read(current),
      previous: await read(Directory('${current.path}.prev')),
    );
  }

  /// 從自動本地備份還原。媒體檔一直在本機，所以只還原資料庫內容與偏好；
  /// 走跟匯入備份同一條「先驗證、單一交易整個覆蓋、失敗全數回滾」流程，
  /// 舊 schema 的快照也由同一套升級邏輯處理。
  static Future<String> restoreLocalBackup({bool previous = false}) {
    return _operationLock.synchronized(() async {
      final current = await _getBackupDir(create: false);
      final dir = previous ? Directory('${current.path}.prev') : current;
      final snapshot = File(p.join(dir.path, 'yanci.db'));
      if (!await snapshot.exists()) {
        throw StateError('找不到自動備份');
      }
      final temporary = await getTemporaryDirectory();
      final copy = File(
        p.join(
          temporary.path,
          'holt_local_restore_${DateTime.now().microsecondsSinceEpoch}.db',
        ),
      );
      await snapshot.copy(copy.path);
      Database? source;
      try {
        source = await openDatabase(
          copy.path,
          readOnly: true,
          singleInstance: false,
        );
        final dbVersion = _pragmaInt(
          await source.rawQuery('PRAGMA user_version'),
          'user_version',
        );
        final existingTables = (await source.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        )).map((row) => row['name'].toString()).toSet();
        final data = <String, dynamic>{
          'version': exportVersion,
          'type': 'holt_full_export',
          'app': 'Holt',
          'exported_at': DateTime.now().toIso8601String(),
          'schema': <String, Object?>{
            'database_version': dbVersion,
            'tables': appTables,
          },
        };
        for (final table in appTables) {
          data[table] = existingTables.contains(table)
              ? (await source.query(table))
                    .map((row) => Map<String, Object?>.from(row))
                    .toList(growable: false)
              : <Map<String, Object?>>[];
        }
        final preferencesFile = File(p.join(dir.path, 'preferences.json'));
        data['preferences'] = await preferencesFile.exists()
            ? jsonDecode(await preferencesFile.readAsString())
            : <String, Object?>{};
        await source.close();
        source = null;
        return await _importFromJsonUnlocked(data);
      } finally {
        await source?.close();
        if (await copy.exists()) await copy.delete();
      }
    });
  }

  static Future<String> _importFromJsonUnlocked(
    Map<String, dynamic> data,
  ) async {
    // 第一階段：不動現有資料，完成格式、型別、主鍵及必要關聯驗證。
    final normalized = _normalizeBackup(data);

    await _ensureOptionalTables();
    final db = await DatabaseHelper.database;
    await _verifyTableManifest(db);
    final prepared = await _prepareForCurrentSchema(db, normalized);

    // 覆蓋還原會替換對話與角色。先撤銷舊窗口租約，避免還原完成後舊
    // WorkManager isolate 仍拿著已不存在的對話發付費心跳。
    await KeepAliveService.instance.stop();

    // SharedPreferences 沒有 transaction。先完整寫入並取得 rollback closure：
    // 偏好寫入失敗時 DB 尚未動；SQLite transaction 失敗時則回復舊偏好。
    final rollbackPreferences = await _applyPreferencesWithRollback(
      prepared.preferences,
    );

    // 第二階段：單一 transaction 覆蓋 SQLite。任一列失敗會自動 rollback。
    try {
      await db.transaction((txn) async {
        for (final table in _insertOrder.reversed) {
          await txn.delete(table);
        }

        // 清掉舊 AUTOINCREMENT 高水位；後續顯式插入的 v5 id 會重建正確值。
        for (final table in _integerPrimaryKeyTables) {
          await txn.delete(
            'sqlite_sequence',
            where: 'name = ?',
            whereArgs: [table],
          );
        }

        for (final table in _insertOrder) {
          for (final row in prepared.tables[table]!) {
            await txn.insert(table, row);
          }
        }
      });
    } catch (_) {
      await rollbackPreferences();
      rethrow;
    }

    try {
      await ModelCostPolicy.validateCurrentSelection();
    } catch (error) {
      // The restore is already committed; a policy check must not report the
      // whole restore as failed. Startup/settings will retry the same rule.
      debugPrint('Post-restore model cost policy check failed: $error');
    }

    // 備份還原會清空並重寫 memories 表，但 FTS5 虛擬表不在
    // appTables 清單內、transaction 也不會動它。還原後重建索引。
    try {
      await DatabaseHelper.rebuildMemoryFts();
    } catch (error) {
      debugPrint('Post-restore FTS rebuild failed: $error');
    }
    try {
      await UserPersonaService.ensureDefaultPersona();
    } catch (error) {
      debugPrint('Post-restore default persona hydration failed: $error');
    }

    final charCount = prepared.tables['characters']!.length;
    final convCount = prepared.tables['conversations']!.length;
    final messageCount = prepared.tables['messages']!.length;
    final memoryCount = prepared.tables['memories']!.length;
    final parts = <String>[
      '角色$charCount',
      '對話$convCount',
      '訊息$messageCount',
      '記憶$memoryCount',
    ];
    if (prepared.skippedVoiceCount > 0) {
      parts.add('略過${prepared.skippedVoiceCount}筆缺少音檔的語音');
    }
    if (prepared.droppedOrphanMessageCount > 0) {
      parts.add(_orphanImportSummary(prepared.droppedOrphanMessageCount));
    }
    if (prepared.isLegacy) {
      parts.add('舊版訊息ID已重建；收藏已盡力配對，刮卡/轉帳舊訊息關聯無法保證');
    }
    return parts.join('、');
  }

  /// 純格式正規化入口，供單元測試驗證 v5 與舊格式，不讀寫 DB/偏好。
  static Map<String, List<Map<String, Object?>>> normalizeForTesting(
    Map<String, dynamic> data,
  ) {
    return normalizeWithReportForTesting(data).tables;
  }

  static ({
    Map<String, List<Map<String, Object?>>> tables,
    int droppedOrphanMessageCount,
  })
  normalizeWithReportForTesting(Map<String, dynamic> data) {
    final normalized = _normalizeBackup(data);
    final tables = {
      for (final entry in normalized.tables.entries)
        entry.key: entry.value
            .map((row) => Map<String, Object?>.from(row))
            .toList(growable: false),
    };
    return (
      tables: tables,
      droppedOrphanMessageCount: normalized.droppedOrphanMessageCount,
    );
  }

  static String _orphanImportSummary(int count) => '捨棄$count條孤兒訊息';

  @visibleForTesting
  static String orphanImportSummaryForTesting(int count) {
    return _orphanImportSummary(count);
  }

  static _NormalizedBackup _normalizeBackup(Map<String, dynamic> data) {
    final type = data['type'];
    final version = data['version'];
    if (type != 'holt_full_export' && type != 'yanci_full_export') {
      throw const FormatException('不是有效的 Holt/Yanci 備份檔（type 不符）');
    }
    if (version is! int || version < 1 || version > exportVersion) {
      throw FormatException('不支援的備份版本：$version');
    }

    final isLegacy = version < exportVersion;
    var declaredDatabaseVersion = 0;
    if (!isLegacy) {
      final schema = _stringKeyMap(data['schema'], field: 'schema');
      if (schema['database_version'] is! int ||
          (schema['database_version'] as int) <= 0) {
        throw const FormatException('v5 schema.database_version 必須是正整數');
      }
      declaredDatabaseVersion = schema['database_version'] as int;
      final tables = _list(
        schema['tables'],
        field: 'schema.tables',
      ).map((value) => value.toString()).toSet();
      // These tables were added without changing the v5 container number.
      // Older v5 exports remain valid and restore them empty.
      final missing = appTables.where(
        (table) =>
            table != 'memory_embeddings' &&
            table != 'pending_memory_actions' &&
            table != 'web_search_usage_logs' &&
            (table != 'rp_character_timeline' ||
                declaredDatabaseVersion >= _contextModeSchemaVersion) &&
            (table != 'user_personas' &&
                    table != 'character_persona_bindings' ||
                declaredDatabaseVersion >= _personaSchemaVersion) &&
            (table != 'user_persona_mode_overrides' ||
                declaredDatabaseVersion >= _personaModeSchemaVersion) &&
            (table != 'character_signatures' ||
                declaredDatabaseVersion >= 54) &&
            (table != 'chat_diagnostics' ||
                declaredDatabaseVersion >= _chatDiagnosticsSchemaVersion) &&
            (!const <String>{
                  'rp_story_characters',
                  'rp_story_relationships',
                  'rp_story_relationship_events',
                }.contains(table) ||
                declaredDatabaseVersion >= _rpStorySchemaVersion) &&
            (!_rpRevisionTables.contains(table) ||
                declaredDatabaseVersion >= _rpRevisionSchemaVersion) &&
            (!_rpStoryStateTables.contains(table) ||
                declaredDatabaseVersion >= _rpStoryStateSchemaVersion) &&
            (!_rpWorldbookTables.contains(table) ||
                declaredDatabaseVersion >= _rpWorldbookSchemaVersion) &&
            (table != 'rp_story_projection_revisions' ||
                declaredDatabaseVersion >=
                    _rpProjectionRevisionSchemaVersion) &&
            (table != 'context_summary_repairs' ||
                declaredDatabaseVersion >= _summaryRepairSchemaVersion) &&
            (table != 'character_diaries' ||
                declaredDatabaseVersion >= _characterDiarySchemaVersion) &&
            (table != 'character_self_notes' ||
                declaredDatabaseVersion >= _characterSelfNotesSchemaVersion) &&
            !tables.contains(table),
      );
      if (missing.isNotEmpty) {
        throw FormatException('v5 備份缺少資料表宣告：${missing.join(', ')}');
      }
    }

    final fallbackTime =
        _validIsoString(data['exported_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String();
    final result = <String, List<Map<String, Object?>>>{
      for (final table in appTables) table: <Map<String, Object?>>[],
    };

    final requiresContextMode =
        !isLegacy && declaredDatabaseVersion >= _contextModeSchemaVersion;
    final requiresPersonaSchema =
        !isLegacy && declaredDatabaseVersion >= _personaSchemaVersion;
    if (isLegacy) {
      _normalizeLegacyCore(data, result, fallbackTime);
    } else {
      for (final table in appTables) {
        result[table] = _mapRows(
          data[table],
          field: table,
          required:
              table != 'memory_embeddings' &&
              table != 'pending_memory_actions' &&
              table != 'web_search_usage_logs' &&
              (table != 'rp_character_timeline' || requiresContextMode) &&
              (table != 'user_personas' &&
                      table != 'character_persona_bindings' ||
                  requiresPersonaSchema) &&
              (table != 'user_persona_mode_overrides' ||
                  declaredDatabaseVersion >= _personaModeSchemaVersion) &&
              (table != 'character_signatures' ||
                  declaredDatabaseVersion >= 54) &&
              (table != 'chat_diagnostics' ||
                  declaredDatabaseVersion >= _chatDiagnosticsSchemaVersion) &&
              (!const <String>{
                    'rp_story_characters',
                    'rp_story_relationships',
                    'rp_story_relationship_events',
                  }.contains(table) ||
                  declaredDatabaseVersion >= _rpStorySchemaVersion) &&
              (!_rpRevisionTables.contains(table) ||
                  declaredDatabaseVersion >= _rpRevisionSchemaVersion) &&
              (!_rpStoryStateTables.contains(table) ||
                  declaredDatabaseVersion >= _rpStoryStateSchemaVersion) &&
              (!_rpWorldbookTables.contains(table) ||
                  declaredDatabaseVersion >= _rpWorldbookSchemaVersion) &&
              (table != 'rp_story_projection_revisions' ||
                  declaredDatabaseVersion >=
                      _rpProjectionRevisionSchemaVersion) &&
              (table != 'context_summary_repairs' ||
                  declaredDatabaseVersion >= _summaryRepairSchemaVersion) &&
              (table != 'character_diaries' ||
                  declaredDatabaseVersion >= _characterDiarySchemaVersion) &&
              (table != 'character_self_notes' ||
                  declaredDatabaseVersion >= _characterSelfNotesSchemaVersion),
        );
      }
    }

    if (declaredDatabaseVersion < _rpStorySchemaVersion) {
      result['rp_story_characters'] = <Map<String, Object?>>[];
      result['rp_story_relationships'] = <Map<String, Object?>>[];
      result['rp_story_relationship_events'] = <Map<String, Object?>>[];
    }
    if (declaredDatabaseVersion < _rpStoryStateSchemaVersion) {
      result['rp_story_entity_aliases'] = <Map<String, Object?>>[];
      result['rp_story_states'] = <Map<String, Object?>>[];
    }
    if (declaredDatabaseVersion < _rpWorldbookSchemaVersion) {
      for (final table in _rpWorldbookTables) {
        result[table] = <Map<String, Object?>>[];
      }
    }
    if (declaredDatabaseVersion < _rpProjectionRevisionSchemaVersion) {
      result['rp_story_projection_revisions'] = <Map<String, Object?>>[];
    }
    if (declaredDatabaseVersion < _summaryRepairSchemaVersion) {
      result['context_summary_repairs'] = <Map<String, Object?>>[];
    }
    if (declaredDatabaseVersion < _characterDiarySchemaVersion) {
      result['character_diaries'] = <Map<String, Object?>>[];
    }
    if (declaredDatabaseVersion < _characterSelfNotesSchemaVersion) {
      result['character_self_notes'] = <Map<String, Object?>>[];
    }

    if (declaredDatabaseVersion < _personaModeSchemaVersion) {
      result['user_persona_mode_overrides'] = <Map<String, Object?>>[];
    }

    if (!requiresPersonaSchema) {
      final legacyPersonaIds = <String>{UserPersonaService.defaultPersonaId};
      for (final conversation in result['conversations']!) {
        final id = _normalizedOptionalId(conversation['user_persona_id']);
        if (id != null) legacyPersonaIds.add(id);
      }
      result['user_personas'] = legacyPersonaIds
          .map(
            (id) => <String, Object?>{
              'id': id,
              'display_name': '',
              'pronouns': '',
              'bio': '',
              'avatar_path': '',
              'prompt_content': '',
              'is_default': id == UserPersonaService.defaultPersonaId ? 1 : 0,
              'is_archived': 0,
              'created_at': fallbackTime,
              'updated_at': fallbackTime,
            },
          )
          .toList(growable: false);
      result['character_persona_bindings'] = <Map<String, Object?>>[];
    }

    // Old and new rows both pass through path sanitisation and safe defaults.
    _normalizeCommonRows(
      result,
      fallbackTime,
      isLegacy: isLegacy,
      requiresContextMode: requiresContextMode,
      requiresPersonaSchema: requiresPersonaSchema,
    );
    _normalizeSharedPersonaBindings(result);
    _validateContextScopeLinks(result);
    _normalizeMemoryEmbeddings(result, fallbackTime);
    _normalizeSpiderWebLinks(result);
    _deduplicateSavedMessages(result);
    _normalizeTimelineEvents(result, fallbackTime);
    _validatePrimaryKeys(result, strict: !isLegacy);
    final droppedOrphanMessageCount = _validateMessageConversationLinks(result);

    final preferences = _normalizePreferences(data['preferences']);
    return _NormalizedBackup(
      version: version,
      tables: result,
      preferences: preferences,
      isLegacy: isLegacy,
      droppedOrphanMessageCount: droppedOrphanMessageCount,
    );
  }

  /// v82 keeps Daily/RP persona file content separate but shares one companion
  /// binding. Old exports may contain conflicting mode/continuity rows; retain
  /// the newest one-to-one relationships and rewrite them to the compatibility
  /// scope used by current storage.
  static void _normalizeSharedPersonaBindings(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final rows = tables['character_persona_bindings'];
    if (rows == null || rows.isEmpty) return;
    final sourceOrder = <Map<String, Object?>, int>{};
    for (var index = 0; index < rows.length; index++) {
      sourceOrder[rows[index]] = index;
    }
    final ordered = List<Map<String, Object?>>.from(rows)
      ..sort((left, right) {
        final leftTime = DateTime.tryParse(
          left['updated_at']?.toString() ?? '',
        );
        final rightTime = DateTime.tryParse(
          right['updated_at']?.toString() ?? '',
        );
        final byTime = (rightTime ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(leftTime ?? DateTime.fromMillisecondsSinceEpoch(0));
        if (byTime != 0) return byTime;
        return (sourceOrder[right] ?? 0).compareTo(sourceOrder[left] ?? 0);
      });

    final normalized = <Map<String, Object?>>[];
    final usedCharacters = <String>{};
    final usedPersonas = <String>{};
    for (final row in ordered) {
      final characterId = row['character_id']?.toString() ?? '';
      final personaId = row['user_persona_id']?.toString() ?? '';
      if (characterId.isEmpty ||
          personaId.isEmpty ||
          !usedCharacters.add(characterId) ||
          !usedPersonas.add(personaId)) {
        continue;
      }
      normalized.add(<String, Object?>{
        ...row,
        'context_mode': 'daily',
        'continuity_id': 'main',
      });
    }
    tables['character_persona_bindings'] = normalized;
  }

  static void _normalizeLegacyCore(
    Map<String, dynamic> data,
    Map<String, List<Map<String, Object?>>> result,
    String fallbackTime,
  ) {
    for (final table in appTables) {
      if (table == 'conversations' || table == 'messages') continue;
      result[table] = _mapRows(data[table], field: table, required: false);
    }

    final conversations = _mapRows(
      data['conversations'],
      field: 'conversations',
      required: false,
    );
    var nextMessageId = 1;
    for (final legacyConv in conversations) {
      final convId = (legacyConv['conversation_id'] ?? legacyConv['id'])
          ?.toString()
          .trim();
      if (convId == null || convId.isEmpty) {
        throw const FormatException('舊版對話缺少 conversation_id');
      }
      final conv = <String, Object?>{
        'id': convId,
        'character_id': _nonEmptyString(
          legacyConv['character_id'],
          fallback: 'default',
        ),
        'window_summary_id': legacyConv['window_summary_id']?.toString() ?? '',
        'pinned_static_summary': legacyConv['pinned_static_summary']
            ?.toString(),
        'summary_cursor_message_id': 0,
        'title': legacyConv['title']?.toString() ?? '',
        'is_starred': _sqliteBool(legacyConv['is_starred']),
        'created_at': _validIsoString(legacyConv['created_at']) ?? fallbackTime,
        'updated_at': _validIsoString(legacyConv['updated_at']) ?? fallbackTime,
      };
      result['conversations']!.add(conv);

      final messages = _mapRows(
        legacyConv['messages'],
        field: 'conversations[$convId].messages',
        required: false,
      );
      for (final legacyMessage in messages) {
        result['messages']!.add(<String, Object?>{
          'id': nextMessageId++,
          'conversation_id': convId,
          'character_id': _nonEmptyString(
            legacyMessage['character_id'],
            fallback: conv['character_id']!.toString(),
          ),
          'text': legacyMessage['text']?.toString() ?? '',
          'is_user': _sqliteBool(legacyMessage['is_user'], defaultValue: 1),
          'image_path': _sanitizeImportPath(legacyMessage['image_path']),
          'image_paths_json': _normalizeMessageImagePaths(
            legacyMessage['image_paths_json'],
            legacyMessage['image_path'],
          ),
          'split_mode': _sqliteBool(legacyMessage['split_mode']),
          'memory_log': legacyMessage['memory_log']?.toString() ?? '',
          'cache_hit': _sqliteBool(legacyMessage['cache_hit']),
          'status': Message.statusComplete,
          'created_at':
              _validIsoString(legacyMessage['created_at']) ?? fallbackTime,
        });
      }
    }

    // 有些中間版可能另帶 top-level messages；若有，亦接受並補到尾端。
    final topLevelMessages = _mapRows(
      data['messages'],
      field: 'messages',
      required: false,
    );
    for (final message in topLevelMessages) {
      final row = Map<String, Object?>.from(message);
      row['id'] = nextMessageId++;
      result['messages']!.add(row);
    }

    _remapLegacySavedMessages(result);
  }

  static void _normalizeCommonRows(
    Map<String, List<Map<String, Object?>>> tables,
    String fallbackTime, {
    required bool isLegacy,
    required bool requiresContextMode,
    required bool requiresPersonaSchema,
  }) {
    for (final character in tables['characters']!) {
      character['id'] = _requiredId(character['id'], 'characters.id');
      character['name'] = character['name']?.toString() ?? '';
      character['preferred_context_mode'] = _normalizedContextMode(
        character['preferred_context_mode'],
        field: 'characters.preferred_context_mode',
        required: requiresContextMode,
      );
      character['created_at'] =
          _validIsoString(character['created_at']) ?? fallbackTime;
      character['updated_at'] =
          _validIsoString(character['updated_at']) ?? fallbackTime;
      if (character.containsKey('avatar_path')) {
        character['avatar_path'] = _sanitizeImportPath(
          character['avatar_path'],
        );
      }
    }

    for (final persona in tables['user_personas']!) {
      persona['id'] = _requiredId(persona['id'], 'user_personas.id');
      persona['display_name'] = persona['display_name']?.toString() ?? '';
      persona['pronouns'] = persona['pronouns']?.toString() ?? '';
      persona['bio'] = persona['bio']?.toString() ?? '';
      persona['avatar_path'] =
          _sanitizeImportPath(persona['avatar_path']) ?? '';
      persona['prompt_content'] = persona['prompt_content']?.toString() ?? '';
      persona['is_default'] = _sqliteBool(persona['is_default']);
      persona['is_archived'] = _sqliteBool(persona['is_archived']);
      persona['created_at'] =
          _validIsoString(persona['created_at']) ?? fallbackTime;
      persona['updated_at'] =
          _validIsoString(persona['updated_at']) ?? fallbackTime;
    }

    for (final override in tables['user_persona_mode_overrides']!) {
      override['user_persona_id'] = _requiredId(
        override['user_persona_id'],
        'user_persona_mode_overrides.user_persona_id',
      );
      override['context_mode'] = _normalizedContextMode(
        override['context_mode'],
        field: 'user_persona_mode_overrides.context_mode',
        required: true,
      );
      for (final field in const <String>[
        'display_name',
        'pronouns',
        'bio',
        'prompt_content',
      ]) {
        if (override[field] != null) {
          override[field] = override[field].toString();
        }
      }
      override['created_at'] =
          _validIsoString(override['created_at']) ?? fallbackTime;
      override['updated_at'] =
          _validIsoString(override['updated_at']) ?? fallbackTime;
    }

    for (final binding in tables['character_persona_bindings']!) {
      binding['character_id'] = _requiredId(
        binding['character_id'],
        'character_persona_bindings.character_id',
      );
      binding['context_mode'] = _normalizedContextMode(
        binding['context_mode'],
        field: 'character_persona_bindings.context_mode',
        required: true,
      );
      binding['continuity_id'] = _normalizedContinuityId(
        binding['continuity_id'],
        field: 'character_persona_bindings.continuity_id',
        required: true,
      );
      binding['user_persona_id'] = _requiredId(
        binding['user_persona_id'],
        'character_persona_bindings.user_persona_id',
      );
      binding['created_at'] =
          _validIsoString(binding['created_at']) ?? fallbackTime;
      binding['updated_at'] =
          _validIsoString(binding['updated_at']) ?? fallbackTime;
    }

    for (final conversation in tables['conversations']!) {
      conversation['id'] = _requiredId(
        conversation['id'] ?? conversation['conversation_id'],
        'conversations.id',
      );
      conversation.remove('conversation_id');
      conversation['character_id'] = _nonEmptyString(
        conversation['character_id'],
        fallback: 'default',
      );
      conversation['context_mode'] = _normalizedContextMode(
        conversation['context_mode'],
        field: 'conversations.context_mode',
        required: requiresContextMode,
      );
      conversation['continuity_id'] = _normalizedContinuityId(
        conversation['continuity_id'],
        field: 'conversations.continuity_id',
        required: requiresContextMode,
      );
      conversation['user_persona_id'] = requiresPersonaSchema
          ? _requiredId(
              conversation['user_persona_id'],
              'conversations.user_persona_id',
            )
          : _normalizedOptionalId(conversation['user_persona_id']) ??
                UserPersonaService.defaultPersonaId;
      conversation['user_persona_snapshot'] = requiresPersonaSchema
          ? conversation['user_persona_snapshot']?.toString() ?? ''
          : '';
      conversation['worldbook_set_id'] = _normalizedOptionalId(
        conversation['worldbook_set_id'],
      );
      conversation['window_summary_id'] =
          conversation['window_summary_id']?.toString() ?? '';
      final rawSummaryCursor = conversation['summary_cursor_message_id'];
      conversation['summary_cursor_message_id'] = rawSummaryCursor is int
          ? rawSummaryCursor.clamp(0, 0x7fffffff)
          : 0;
      conversation['pinned_static_self_notes'] =
          conversation.containsKey('pinned_static_self_notes')
          ? conversation['pinned_static_self_notes']?.toString() ?? ''
          : '';
      conversation['title'] = conversation['title']?.toString() ?? '';
      conversation['is_starred'] = _sqliteBool(conversation['is_starred']);
      conversation['created_at'] =
          _validIsoString(conversation['created_at']) ?? fallbackTime;
      conversation['updated_at'] =
          _validIsoString(conversation['updated_at']) ?? fallbackTime;
      final messages = conversation.remove('messages');
      if (!isLegacy && messages != null) {
        throw const FormatException('v5 conversations 不應包含巢狀 messages');
      }
    }

    tables['rp_storylines'] = List<Map<String, Object?>>.from(
      tables['rp_storylines']!,
      growable: true,
    );
    final storylineKeys = <String>{};
    for (final storyline in tables['rp_storylines']!) {
      final characterId = _requiredId(
        storyline['character_id'],
        'rp_storylines.character_id',
      );
      final storylineId = _requiredId(storyline['id'], 'rp_storylines.id');
      storyline['character_id'] = characterId;
      storyline['id'] = storylineId;
      storyline['name'] = storyline['name']?.toString() ?? '';
      storyline['status'] = storyline['status'] == 'archived'
          ? 'archived'
          : 'active';
      storyline['is_default'] = _sqliteBool(
        storyline['is_default'],
        defaultValue: storylineId == 'main' ? 1 : 0,
      );
      storyline['created_at'] =
          _validIsoString(storyline['created_at']) ?? fallbackTime;
      storyline['updated_at'] =
          _validIsoString(storyline['updated_at']) ?? storyline['created_at'];
      storylineKeys.add('$characterId\u0000$storylineId');
    }
    // v68-and-earlier backups have continuity_id but no registry table. Build
    // the registry from their RP windows so restore never detaches a story.
    for (final conversation in tables['conversations']!) {
      if (conversation['context_mode'] != 'rp') continue;
      final characterId = conversation['character_id']!.toString();
      final storylineId = conversation['continuity_id']!.toString();
      final key = '$characterId\u0000$storylineId';
      if (!storylineKeys.add(key)) continue;
      tables['rp_storylines']!.add(<String, Object?>{
        'character_id': characterId,
        'id': storylineId,
        'name': '',
        'status': 'active',
        'is_default': storylineId == 'main' ? 1 : 0,
        'created_at': conversation['created_at'],
        'updated_at': conversation['updated_at'],
      });
    }

    var nextLegacyId = 1;
    for (final message in tables['messages']!) {
      if (isLegacy) {
        final existing = message['id'];
        if (existing is int && existing >= nextLegacyId) {
          nextLegacyId = existing + 1;
        } else {
          message['id'] = nextLegacyId++;
        }
      } else if (message['id'] is! int || (message['id'] as int) <= 0) {
        throw const FormatException('v5 messages.id 必須是正整數');
      }
      message['conversation_id'] = _requiredId(
        message['conversation_id'],
        'messages.conversation_id',
      );
      message['character_id'] = _nonEmptyString(
        message['character_id'],
        fallback: 'default',
      );
      message['text'] = message['text']?.toString() ?? '';
      message['is_user'] = _sqliteBool(message['is_user'], defaultValue: 1);
      message['image_path'] = _sanitizeImportPath(message['image_path']);
      message['image_paths_json'] = _normalizeMessageImagePaths(
        message['image_paths_json'],
        message['image_path'],
      );
      message['split_mode'] = _sqliteBool(message['split_mode']);
      message['memory_log'] = message['memory_log']?.toString() ?? '';
      message['web_search_trace_json'] =
          message['web_search_trace_json']?.toString() ?? '';
      message['cache_hit'] = _sqliteBool(message['cache_hit']);
      message['summary_recorded'] = _sqliteBool(message['summary_recorded']);
      final rawRevision = message['revision'];
      message['revision'] = rawRevision is int && rawRevision > 0
          ? rawRevision
          : 1;
      message['status'] = message['status'] == Message.statusIncomplete
          ? Message.statusIncomplete
          : Message.statusComplete;
      message['created_at'] =
          _validIsoString(message['created_at']) ?? fallbackTime;
    }

    for (final revision in tables['message_revisions']!) {
      if (revision['id'] is! int || (revision['id'] as int) <= 0) {
        throw const FormatException('message_revisions.id 必須是正整數');
      }
      if (revision['message_id'] is! int ||
          (revision['message_id'] as int) <= 0) {
        throw const FormatException('message_revisions.message_id 必須是正整數');
      }
      revision['conversation_id'] = _requiredId(
        revision['conversation_id'],
        'message_revisions.conversation_id',
      );
      final value = revision['revision'];
      revision['revision'] = value is int && value > 0 ? value : 1;
      revision['snapshot_json'] = revision['snapshot_json']?.toString() ?? '{}';
      revision['archive_reason'] =
          revision['archive_reason']?.toString() ?? 'restore';
      revision['archived_at'] =
          _validIsoString(revision['archived_at']) ?? fallbackTime;
    }

    for (final table in const <String>[
      'memories',
      'context_summaries',
      'context_summary_segments',
      'context_keywords',
      'pending_memory_actions',
      'memory_rejection_tombstones',
    ]) {
      for (final row in tables[table]!) {
        row['context_mode'] = _normalizedContextMode(
          row['context_mode'],
          field: '$table.context_mode',
          required: requiresContextMode,
        );
        row['continuity_id'] = _normalizedContinuityId(
          row['continuity_id'],
          field: '$table.continuity_id',
          required: requiresContextMode,
        );
      }
    }

    for (final memory in tables['memories']!) {
      memory['is_pinned'] = memory['is_pinned'] == 1 ? 1 : 0;
    }

    for (final summary in tables['context_summaries']!) {
      final revision = summary['revision'];
      summary['revision'] = revision is int && revision > 0 ? revision : 1;
      summary['revision_status'] = summary['revision_status'] == 'invalidated'
          ? 'invalidated'
          : 'valid';
      summary['invalidation_reason'] =
          summary['invalidation_reason']?.toString() ?? '';
      summary['story_time_text'] = summary['story_time_text']?.toString() ?? '';
    }

    for (final tombstone in tables['memory_rejection_tombstones']!) {
      tombstone['id'] = _requiredId(
        tombstone['id'],
        'memory_rejection_tombstones.id',
      );
      tombstone['fact_key'] = _requiredId(
        tombstone['fact_key'],
        'memory_rejection_tombstones.fact_key',
      );
      tombstone['category'] = tombstone['category']?.toString() ?? '';
      tombstone['candidate_json'] =
          tombstone['candidate_json']?.toString() ?? '{}';
      tombstone['source_proposal_id'] = tombstone['source_proposal_id']
          ?.toString();
      tombstone['created_at'] =
          _validIsoString(tombstone['created_at']) ?? fallbackTime;
    }

    for (final row in tables['rp_character_timeline']!) {
      row['continuity_id'] = _normalizedContinuityId(
        row['continuity_id'],
        field: 'rp_character_timeline.continuity_id',
        required: requiresContextMode,
      );
      final type = row['type']?.toString().trim() ?? 'event';
      if (type != 'state' && type != 'event') {
        throw FormatException('rp_character_timeline.type 不合法：$type');
      }
      row['type'] = type;
      row['event_key'] = row['event_key']?.toString().trim() ?? '';
      final narrativeLayer =
          row['narrative_layer']?.toString().trim() ?? 'main';
      if (!const <String>{
        'main',
        'memory',
        'dream',
        'hypothetical',
        'au',
      }.contains(narrativeLayer)) {
        throw FormatException(
          'rp_character_timeline.narrative_layer 不合法：$narrativeLayer',
        );
      }
      row['narrative_layer'] = narrativeLayer;
      row['subject_entity_ids'] = _normalizeRpEntityKeyJsonList(
        row['subject_entity_ids'],
        field: 'rp_character_timeline.subject_entity_ids',
      );
      row['source_conversation_id'] = _normalizedOptionalId(
        row['source_conversation_id'],
      );
      row['value'] = row['value']?.toString() ?? '';
      row['story_time_text'] = row['story_time_text']?.toString() ?? '';
      row['scene'] = row['scene']?.toString() ?? '';
      row['source_message_ids'] = row['source_message_ids']?.toString() ?? '[]';
      row['source_evidence'] = row['source_evidence']?.toString() ?? '';
      row['confirmed'] = _sqliteBool(row['confirmed'], defaultValue: 1);
      row['sequence_order'] = row['sequence_order'] is int
          ? row['sequence_order']
          : 0;
      row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
      row['updated_at'] =
          _validIsoString(row['updated_at']) ?? row['created_at'];
    }

    final entityOrdinals = <String, int>{};
    for (final row in tables['rp_story_characters']!) {
      row['id'] = _requiredId(row['id'], 'rp_story_characters.id');
      row['character_id'] = _requiredId(
        row['character_id'],
        'rp_story_characters.character_id',
      );
      row['continuity_id'] = _normalizedContinuityId(
        row['continuity_id'],
        field: 'rp_story_characters.continuity_id',
        required: true,
      );
      final scopeKey = '${row['character_id']}\u0000${row['continuity_id']}';
      var entityKey = row['entity_key']?.toString().trim() ?? '';
      if (!RegExp(r'^P-\d{4,}$').hasMatch(entityKey)) {
        final next = (entityOrdinals[scopeKey] ?? 0) + 1;
        entityOrdinals[scopeKey] = next;
        entityKey = 'P-${next.toString().padLeft(4, '0')}';
      }
      row['entity_key'] = entityKey;
      for (final field in const <String>[
        'normalized_name',
        'name',
        'aliases_json',
        'identities_json',
        'gender',
        'identity',
        'relation_to_leads',
        'personality',
        'appearance',
        'first_scene',
        'faction',
        'core_motivation',
        'current_stance',
        'recurrence',
        'tier',
        'source_conversation_id',
        'source_message_ids',
        'evidence',
        'tags_json',
      ]) {
        row[field] = row[field]?.toString() ?? '';
      }
      row['is_important'] = _sqliteBool(row['is_important']);
      row['user_edited'] = _sqliteBool(row['user_edited']);
      row['mention_count'] = row['mention_count'] is int
          ? row['mention_count']
          : 0;
      row['worldbook_entry_id'] = _normalizedOptionalId(
        row['worldbook_entry_id'],
      );
      row['last_seen_at'] =
          _validIsoString(row['last_seen_at']) ?? fallbackTime;
      row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
      row['updated_at'] = _validIsoString(row['updated_at']) ?? fallbackTime;
    }

    if (tables['rp_story_entity_aliases']!.isEmpty) {
      for (final character in tables['rp_story_characters']!) {
        final aliases = <String>{character['name']!.toString()};
        try {
          final decoded = jsonDecode(character['aliases_json']!.toString());
          if (decoded is List) {
            aliases.addAll(decoded.map((value) => value?.toString() ?? ''));
          }
        } catch (_) {
          // Legacy malformed aliases remain non-fatal during restore.
        }
        for (final alias
            in aliases
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)) {
          final normalized = alias.toLowerCase().replaceAll(
            RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
            '',
          );
          if (normalized.isEmpty) continue;
          tables['rp_story_entity_aliases']!.add(<String, Object?>{
            'character_id': character['character_id'],
            'continuity_id': character['continuity_id'],
            'entity_key': character['entity_key'],
            'normalized_alias': normalized,
            'display_alias': alias,
            'alias_type': alias == character['name'] ? 'name' : 'identity',
            'created_at': character['created_at'],
            'updated_at': character['updated_at'],
          });
        }
      }
    }

    for (final alias in tables['rp_story_entity_aliases']!) {
      alias['character_id'] = _requiredId(
        alias['character_id'],
        'rp_story_entity_aliases.character_id',
      );
      alias['continuity_id'] = _normalizedContinuityId(
        alias['continuity_id'],
        field: 'rp_story_entity_aliases.continuity_id',
        required: true,
      );
      alias['entity_key'] = _requiredId(
        alias['entity_key'],
        'rp_story_entity_aliases.entity_key',
      );
      alias['normalized_alias'] = _requiredId(
        alias['normalized_alias'],
        'rp_story_entity_aliases.normalized_alias',
      );
      alias['display_alias'] = _requiredId(
        alias['display_alias'],
        'rp_story_entity_aliases.display_alias',
      );
      alias['alias_type'] =
          const <String>{
            'name',
            'identity',
            'title',
            'other',
          }.contains(alias['alias_type'])
          ? alias['alias_type']
          : 'other';
      alias['created_at'] =
          _validIsoString(alias['created_at']) ?? fallbackTime;
      alias['updated_at'] =
          _validIsoString(alias['updated_at']) ?? fallbackTime;
    }

    const stateTypes = <String>{
      'scene',
      'promise',
      'body',
      'identity',
      'knowledge',
      'plot',
      'item',
    };
    const narrativeLayers = <String>{
      'main',
      'memory',
      'dream',
      'hypothetical',
      'au',
      'ooc',
    };
    for (final state in tables['rp_story_states']!) {
      state['id'] = _requiredId(state['id'], 'rp_story_states.id');
      state['character_id'] = _requiredId(
        state['character_id'],
        'rp_story_states.character_id',
      );
      state['continuity_id'] = _normalizedContinuityId(
        state['continuity_id'],
        field: 'rp_story_states.continuity_id',
        required: true,
      );
      state['state_key'] = _requiredId(
        state['state_key'],
        'rp_story_states.state_key',
      );
      if (!stateTypes.contains(state['state_type'])) {
        throw const FormatException('rp_story_states.state_type 無效');
      }
      state['narrative_layer'] =
          narrativeLayers.contains(state['narrative_layer'])
          ? state['narrative_layer']
          : 'main';
      for (final field in const <String>[
        'subject_entity_key',
        'object_entity_key',
        'value',
        'status',
        'story_time',
        'source_conversation_id',
        'source_message_ids',
        'evidence',
      ]) {
        state[field] = state[field]?.toString() ?? '';
      }
      state['source_summary_id'] = state['source_summary_id'] is int
          ? state['source_summary_id']
          : null;
      state['user_edited'] = _sqliteBool(state['user_edited']);
      state['created_at'] =
          _validIsoString(state['created_at']) ?? fallbackTime;
      state['updated_at'] =
          _validIsoString(state['updated_at']) ?? fallbackTime;
    }

    for (final revision in tables['rp_story_projection_revisions']!) {
      if (revision['id'] is! int || (revision['id'] as int) <= 0) {
        throw const FormatException('rp_story_projection_revisions.id 必須是正整數');
      }
      final projectionTable = revision['projection_table']?.toString() ?? '';
      if (!const <String>{
        'character',
        'relationship',
      }.contains(projectionTable)) {
        throw const FormatException(
          'rp_story_projection_revisions.projection_table 無效',
        );
      }
      revision['projection_table'] = projectionTable;
      revision['projection_id'] = _requiredId(
        revision['projection_id'],
        'rp_story_projection_revisions.projection_id',
      );
      revision['character_id'] = _requiredId(
        revision['character_id'],
        'rp_story_projection_revisions.character_id',
      );
      revision['continuity_id'] = _normalizedContinuityId(
        revision['continuity_id'],
        field: 'rp_story_projection_revisions.continuity_id',
        required: true,
      );
      if (revision['source_summary_id'] is! int ||
          (revision['source_summary_id'] as int) <= 0) {
        throw const FormatException(
          'rp_story_projection_revisions.source_summary_id 無效',
        );
      }
      final operation = revision['operation']?.toString() ?? '';
      if (!const <String>{'create', 'update'}.contains(operation)) {
        throw const FormatException(
          'rp_story_projection_revisions.operation 無效',
        );
      }
      revision['operation'] = operation;
      revision['snapshot_json'] = revision['snapshot_json']?.toString() ?? '';
      if (operation == 'update') {
        try {
          if (jsonDecode(revision['snapshot_json']!.toString()) is! Map) {
            throw const FormatException();
          }
        } catch (_) {
          throw const FormatException(
            'rp_story_projection_revisions.snapshot_json 無效',
          );
        }
      }
      revision['created_at'] =
          _validIsoString(revision['created_at']) ?? fallbackTime;
    }

    const repairStatuses = <String>{
      'pending',
      'running',
      'failed',
      'completed',
    };
    for (final repair in tables['context_summary_repairs']!) {
      if (repair['id'] is! int || (repair['id'] as int) <= 0) {
        throw const FormatException('context_summary_repairs.id 必須是正整數');
      }
      if (repair['original_summary_id'] is! int ||
          (repair['original_summary_id'] as int) <= 0) {
        throw const FormatException(
          'context_summary_repairs.original_summary_id 無效',
        );
      }
      repair['character_id'] = _requiredId(
        repair['character_id'],
        'context_summary_repairs.character_id',
      );
      repair['context_mode'] = _normalizedContextMode(
        repair['context_mode'],
        field: 'context_summary_repairs.context_mode',
        required: true,
      );
      repair['continuity_id'] = _normalizedContinuityId(
        repair['continuity_id'],
        field: 'context_summary_repairs.continuity_id',
        required: true,
      );
      repair['source_conversation_id'] = _requiredId(
        repair['source_conversation_id'],
        'context_summary_repairs.source_conversation_id',
      );
      for (final field in const <String>[
        'source_message_start_id',
        'source_message_end_id',
      ]) {
        if (repair[field] is! int || (repair[field] as int) <= 0) {
          throw FormatException('context_summary_repairs.$field 無效');
        }
      }
      repair['status'] = repairStatuses.contains(repair['status'])
          ? repair['status']
          : 'pending';
      repair['attempts'] = repair['attempts'] is int
          ? (repair['attempts'] as int).clamp(0, 1000000)
          : 0;
      repair['last_error'] = repair['last_error']?.toString() ?? '';
      repair['created_at'] =
          _validIsoString(repair['created_at']) ?? fallbackTime;
      repair['updated_at'] =
          _validIsoString(repair['updated_at']) ?? fallbackTime;
    }

    const worldbookStatuses = <String>{'active', 'archived'};
    const worldbookBindingScopes = <String>{'storyline', 'character_global'};
    const worldbookActivationModes = <String>{'always', 'triggered', 'scene'};
    for (final entry in tables['rp_worldbook_entries']!) {
      entry['id'] = _requiredId(entry['id'], 'rp_worldbook_entries.id');
      entry['entry_key'] = _requiredId(
        entry['entry_key'],
        'rp_worldbook_entries.entry_key',
      );
      entry['character_id'] = _requiredId(
        entry['character_id'],
        'rp_worldbook_entries.character_id',
      );
      entry['continuity_id'] = _normalizedContinuityId(
        entry['continuity_id'],
        field: 'rp_worldbook_entries.continuity_id',
        required: true,
      );
      for (final field in const <String>[
        'name',
        'category',
        'content',
        'scope',
        'visibility',
        'ended_reason',
        'triggers_json',
        'source_summary_ids',
      ]) {
        entry[field] = entry[field]?.toString() ?? '';
      }
      entry['status'] = worldbookStatuses.contains(entry['status'])
          ? entry['status']
          : 'active';
      entry['binding_scope'] =
          worldbookBindingScopes.contains(entry['binding_scope'])
          ? entry['binding_scope']
          : 'storyline';
      final restoredTriggers = entry['triggers_json']?.toString().trim() ?? '';
      entry['activation_mode'] =
          worldbookActivationModes.contains(entry['activation_mode'])
          ? entry['activation_mode']
          : (restoredTriggers.isEmpty || restoredTriggers == '[]'
                ? 'always'
                : 'triggered');
      entry['user_edited'] = _sqliteBool(entry['user_edited']);
      entry['created_at'] =
          _validIsoString(entry['created_at']) ?? fallbackTime;
      entry['updated_at'] =
          _validIsoString(entry['updated_at']) ?? fallbackTime;
    }
    for (final sync in tables['rp_worldbook_sync_state']!) {
      sync['character_id'] = _requiredId(
        sync['character_id'],
        'rp_worldbook_sync_state.character_id',
      );
      sync['continuity_id'] = _normalizedContinuityId(
        sync['continuity_id'],
        field: 'rp_worldbook_sync_state.continuity_id',
        required: true,
      );
      sync['last_processed_summary_id'] =
          sync['last_processed_summary_id'] is int
          ? sync['last_processed_summary_id']
          : 0;
      sync['updated_at'] = _validIsoString(sync['updated_at']) ?? fallbackTime;
    }
    for (final review in tables['rp_worldbook_review_items']!) {
      review['id'] = _requiredId(review['id'], 'rp_worldbook_review_items.id');
      review['character_id'] = _requiredId(
        review['character_id'],
        'rp_worldbook_review_items.character_id',
      );
      review['continuity_id'] = _normalizedContinuityId(
        review['continuity_id'],
        field: 'rp_worldbook_review_items.continuity_id',
        required: true,
      );
      review['kind'] = review['kind'] == 'conflict'
          ? 'conflict'
          : 'possible_duplicate';
      review['payload_json'] = review['payload_json']?.toString() ?? '{}';
      review['status'] =
          const <String>{
            'pending',
            'resolved',
            'dismissed',
          }.contains(review['status'])
          ? review['status']
          : 'pending';
      review['created_at'] =
          _validIsoString(review['created_at']) ?? fallbackTime;
      review['updated_at'] =
          _validIsoString(review['updated_at']) ?? fallbackTime;
    }

    for (final table in const <String>[
      'rp_story_relationships',
      'rp_story_relationship_events',
    ]) {
      for (final row in tables[table]!) {
        row['id'] = _requiredId(row['id'], '$table.id');
        row['character_id'] = _requiredId(
          row['character_id'],
          '$table.character_id',
        );
        row['continuity_id'] = _normalizedContinuityId(
          row['continuity_id'],
          field: '$table.continuity_id',
          required: true,
        );
        for (final field in const <String>[
          'source_conversation_id',
          'source_message_ids',
          'evidence',
          'story_time',
        ]) {
          row[field] = row[field]?.toString() ?? '';
        }
        row['source_summary_id'] = row['source_summary_id'] is int
            ? row['source_summary_id']
            : null;
        row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
        if (table == 'rp_story_relationships') {
          for (final field in const <String>[
            'from_name',
            'to_name',
            'from_entity_key',
            'to_entity_key',
            'normalized_edge',
            'direction',
            'current_relation',
            'origin',
            'closeness_catalyst',
            'forms_of_address_json',
            'shared_secrets_json',
            'conflicts_json',
            'knowledge_scope_json',
            'visibility',
          ]) {
            row[field] = row[field]?.toString() ?? '';
          }
          row['user_edited'] = _sqliteBool(row['user_edited']);
          row['updated_at'] =
              _validIsoString(row['updated_at']) ?? fallbackTime;
        } else {
          row['relationship_id'] = _requiredId(
            row['relationship_id'],
            '$table.relationship_id',
          );
          row['change_text'] = row['change_text']?.toString() ?? '';
        }
      }
    }

    final diaryScopes = <String>{};
    for (final row in tables['character_diaries']!) {
      if (row['id'] is! int || (row['id'] as int) <= 0) {
        throw const FormatException('character_diaries.id 必須是正整數');
      }
      row['character_id'] = _requiredId(
        row['character_id'],
        'character_diaries.character_id',
      );
      final diaryDate = row['diary_date']?.toString().trim() ?? '';
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(diaryDate)) {
        throw const FormatException('character_diaries.diary_date 無效');
      }
      final scope = '${row['character_id']}\u0000$diaryDate';
      if (!diaryScopes.add(scope)) {
        throw const FormatException('同一角色每天只能有一份日記');
      }
      row['diary_date'] = diaryDate;
      row['title'] = String.fromCharCodes(
        (row['title']?.toString().trim() ?? '').runes.take(80),
      );
      final body = String.fromCharCodes(
        (row['body']?.toString().trim() ?? '').runes.take(6000),
      );
      if (body.isEmpty) {
        throw const FormatException('character_diaries.body 不可為空');
      }
      row['body'] = body;
      row['source_conversation_id'] =
          row['source_conversation_id']?.toString() ?? '';
      row['source_message_id'] = row['source_message_id'] is int
          ? row['source_message_id']
          : null;
      row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
      row['updated_at'] =
          _validIsoString(row['updated_at']) ?? row['created_at'];
    }
    for (final row in tables['character_self_notes']!) {
      if (row['id'] is! int || (row['id'] as int) <= 0) {
        throw const FormatException('character_self_notes.id 必須是正整數');
      }
      final characterId = _requiredId(
        row['character_id'],
        'character_self_notes.character_id',
      );
      row['character_id'] = characterId;
      final content = row['content']?.toString().trim() ?? '';
      if (content.isEmpty) {
        throw const FormatException('character_self_notes.content 不可為空');
      }
      row['content'] = content;
      for (final field in const <String>[
        'provider',
        'model_id',
        'model_version',
        'source_conversation_id',
      ]) {
        row[field] = row[field]?.toString() ?? '';
      }
      row['locked'] = _sqliteBool(row['locked']);
      row['long_term'] = _sqliteBool(row['long_term']);
      try {
        final decoded = jsonDecode(
          row['source_message_ids_json']?.toString() ?? '[]',
        );
        if (decoded is! List || decoded.any((item) => item is! int)) {
          throw const FormatException(
            'character_self_notes.source_message_ids_json 無效',
          );
        }
        row['source_message_ids_json'] = jsonEncode(decoded);
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException(
          'character_self_notes.source_message_ids_json 無效',
        );
      }
      row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
      row['updated_at'] =
          _validIsoString(row['updated_at']) ?? row['created_at'];
      final sourceConversationId =
          row['source_conversation_id']?.toString() ?? '';
      if (sourceConversationId.isEmpty) {
        row['source_conversation_id'] = '';
      }
    }

    for (final row in tables['character_signatures']!) {
      row['character_id'] = _requiredId(
        row['character_id'],
        'character_signatures.character_id',
      );
      row['conversation_id'] = _requiredId(
        row['conversation_id'],
        'character_signatures.conversation_id',
      );
      row['context_mode'] = _normalizedContextMode(
        row['context_mode'],
        field: 'character_signatures.context_mode',
        required: true,
      );
      row['continuity_id'] = _normalizedContinuityId(
        row['continuity_id'],
        field: 'character_signatures.continuity_id',
        required: true,
      );
      final phase = row['phase']?.toString().trim() ?? '';
      if (phase != 'opening' && phase != 'closing') {
        throw FormatException('character_signatures.phase 不合法：$phase');
      }
      row['phase'] = phase;
      final signature = row['signature']?.toString().trim() ?? '';
      if (signature.isEmpty) {
        throw const FormatException('character_signatures.signature 不可為空');
      }
      final lines = signature
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .take(4)
          .join('\n');
      if (lines.isEmpty) {
        throw const FormatException('character_signatures.signature 不可為空');
      }
      row['signature'] = String.fromCharCodes(lines.runes.take(64));
      row['is_selected'] = _sqliteBool(row['is_selected'], defaultValue: 0);
      row['created_at'] = _validIsoString(row['created_at']) ?? fallbackTime;
      row['updated_at'] =
          _validIsoString(row['updated_at']) ?? row['created_at'];
    }

    // A forged or stale backup cursor must not skip messages that are present
    // in the restored conversation. Clamp it to that conversation's real id
    // range; old backups naturally remain at zero.
    final maxMessageIdByConversation = <String, int>{};
    final messageConversationById = <int, String>{};
    for (final message in tables['messages']!) {
      final conversationId = message['conversation_id']?.toString() ?? '';
      final id = message['id'];
      if (conversationId.isEmpty || id is! int) continue;
      messageConversationById[id] = conversationId;
      final previous = maxMessageIdByConversation[conversationId] ?? 0;
      if (id > previous) maxMessageIdByConversation[conversationId] = id;
    }
    for (final conversation in tables['conversations']!) {
      final conversationId = conversation['id']?.toString() ?? '';
      final maxId = maxMessageIdByConversation[conversationId] ?? 0;
      final cursor = conversation['summary_cursor_message_id'] as int? ?? 0;
      conversation['summary_cursor_message_id'] = cursor.clamp(0, maxId);
    }
    for (final summary in tables['context_summaries']!) {
      final anchor = summary['display_anchor_message_id'];
      final sourceConversationId =
          summary['source_conversation_id']?.toString() ?? '';
      if (anchor is! int ||
          messageConversationById[anchor] != sourceConversationId) {
        summary['display_anchor_message_id'] = null;
      }
    }

    for (final sticker in tables['stickers']!) {
      if (sticker['character_id'] == 'default') {
        sticker['character_id'] = 'user';
      }
      sticker['file_path'] = _sanitizeImportPath(sticker['file_path']) ?? '';
    }
    for (final item in tables['shop_items']!) {
      if (item.containsKey('image_path')) {
        item['image_path'] = _sanitizeImportPath(item['image_path']) ?? '';
      }
    }
    for (final archived in tables['archive']!) {
      archived['character_id'] = _archiveCharacterId(archived);
    }
    for (final voice in tables['saved_voices']!) {
      // v1-v4 的錯誤欄名仍盡量救回名稱；真正插入時使用 `name`。
      voice['name'] =
          voice['name']?.toString() ??
          voice['display_name']?.toString() ??
          'Voice';
      voice.remove('display_name');
      voice['file_path'] = _sanitizeImportPath(voice['file_path']);
    }
  }

  static String _normalizeMessageImagePaths(Object? raw, Object? legacy) {
    Object? decoded = raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = const <Object?>[];
      }
    }
    final paths = <String>[];
    if (decoded is List) {
      for (final value in decoded) {
        final safePath = _sanitizeImportPath(value);
        if (safePath != null && !paths.contains(safePath)) {
          paths.add(safePath);
        }
      }
    }
    final safeLegacy = _sanitizeImportPath(legacy);
    if (paths.isEmpty && safeLegacy != null) paths.add(safeLegacy);
    return jsonEncode(paths);
  }

  static String _normalizeRpEntityKeyJsonList(
    Object? raw, {
    required String field,
  }) {
    if (raw == null || (raw is String && raw.trim().isEmpty)) return '[]';
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        throw FormatException('$field 必須是合法的 JSON 陣列');
      }
    }
    if (decoded is! List) {
      throw FormatException('$field 必須是 JSON 陣列');
    }
    final normalized = <String>{};
    for (final value in decoded) {
      if (value is! String || !RegExp(r'^P-\d{4,}$').hasMatch(value.trim())) {
        throw FormatException('$field 包含不合法的人物 entity key');
      }
      normalized.add(value.trim());
    }
    return jsonEncode(normalized.toList(growable: false));
  }

  static String _normalizedContextMode(
    Object? raw, {
    required String field,
    required bool required,
  }) {
    final value = raw?.toString().trim() ?? '';
    if (value == 'daily' || value == 'rp') return value;
    if (!required && value.isEmpty) return 'daily';
    throw FormatException('$field 必須是 daily 或 rp');
  }

  static String _normalizedContinuityId(
    Object? raw, {
    required String field,
    required bool required,
  }) {
    final value = raw?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
    if (!required) return 'main';
    throw FormatException('$field 不可為空');
  }

  static String? _normalizedOptionalId(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  static void _remapLegacySavedMessages(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final messagesByConversationAndText =
        <String, List<Map<String, Object?>>>{};
    for (final message in tables['messages']!) {
      final key = '${message['conversation_id']}\u0000${message['text']}';
      messagesByConversationAndText.putIfAbsent(key, () => []).add(message);
    }

    final usedMessageIds = <Object?>{};
    for (final saved in tables['saved_messages']!) {
      final conversationId = saved['conversation_id']?.toString();
      final content = saved['content']?.toString();
      if (conversationId == null || content == null) continue;
      final candidates =
          messagesByConversationAndText['$conversationId\u0000$content'] ??
          const <Map<String, Object?>>[];
      final match = candidates.cast<Map<String, Object?>?>().firstWhere(
        (candidate) => !usedMessageIds.contains(candidate!['id']),
        orElse: () => candidates.isEmpty ? null : candidates.first,
      );
      if (match != null) {
        saved['message_id'] = match['id'].toString();
        usedMessageIds.add(match['id']);
      }
    }
  }

  static void _normalizeSpiderWebLinks(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final normalized = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final link in tables['spider_web_links']!) {
      final first = link['memory_id_1'];
      final second = link['memory_id_2'];
      if (first is! int || second is! int || first == second) continue;
      final low = first < second ? first : second;
      final high = first < second ? second : first;
      final characterId = _nonEmptyString(
        link['character_id'],
        fallback: 'default',
      );
      final relationType =
          const <String>{
            'related',
            'same_event',
            'temporal',
            'duplicate_candidate',
            'conflict_update',
          }.contains(link['relation_type']?.toString())
          ? link['relation_type']!.toString()
          : 'related';
      if (!seen.add('$characterId:$low:$high:$relationType')) continue;
      normalized.add(
        Map<String, Object?>.from(link)
          ..['character_id'] = characterId
          ..['memory_id_1'] = low
          ..['memory_id_2'] = high
          ..['relation_type'] = relationType,
      );
    }
    tables['spider_web_links'] = normalized;
  }

  static void _normalizeMemoryEmbeddings(
    Map<String, List<Map<String, Object?>>> tables,
    String fallbackTime,
  ) {
    final memoryIds = tables['memories']!
        .map((row) => row['id'])
        .whereType<int>()
        .toSet();
    final normalized = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final source in tables['memory_embeddings']!) {
      final memoryId = source['memory_id'];
      final provider = source['provider']?.toString().trim() ?? '';
      final model = source['model']?.toString().trim() ?? '';
      final contentHash = source['content_hash']?.toString().trim() ?? '';
      final dimensions = source['dimensions'];
      final rawVector = source['vector_json']?.toString() ?? '';
      if (memoryId is! int ||
          !memoryIds.contains(memoryId) ||
          provider.isEmpty ||
          model.isEmpty ||
          contentHash.isEmpty ||
          dimensions is! int ||
          dimensions <= 0) {
        throw const FormatException('memory_embeddings 資料無效');
      }
      late final Object? decoded;
      try {
        decoded = jsonDecode(rawVector);
      } catch (_) {
        throw const FormatException('memory_embeddings.vector_json 無效');
      }
      if (decoded is! List ||
          decoded.length != dimensions ||
          decoded.any((value) => value is! num)) {
        throw const FormatException('memory_embeddings 向量維度不一致');
      }
      final key = '$memoryId\u0000$provider\u0000$model';
      if (!seen.add(key)) {
        throw const FormatException('memory_embeddings 含重複索引');
      }
      normalized.add(<String, Object?>{
        'memory_id': memoryId,
        'provider': provider,
        'model': model,
        'content_hash': contentHash,
        'dimensions': dimensions,
        'vector_json': jsonEncode(decoded),
        'updated_at': _validIsoString(source['updated_at']) ?? fallbackTime,
      });
    }
    tables['memory_embeddings'] = normalized;
  }

  static void _validateContextScopeLinks(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final characterIds = tables['characters']!
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();
    final personas = <String, Map<String, Object?>>{
      for (final row in tables['user_personas']!) row['id']!.toString(): row,
    };
    final conversations = <String, Map<String, Object?>>{
      for (final row in tables['conversations']!) row['id']!.toString(): row,
    };

    for (final conversation in conversations.values) {
      final personaId = conversation['user_persona_id']?.toString() ?? '';
      if (!personas.containsKey(personaId)) {
        throw FormatException('conversations 引用了不存在的 user persona：$personaId');
      }
      final snapshot = conversation['user_persona_snapshot']?.toString() ?? '';
      if (snapshot.isEmpty) continue;
      try {
        final decoded = jsonDecode(snapshot);
        if (decoded is! Map || decoded['id']?.toString() != personaId) {
          throw const FormatException('persona snapshot id mismatch');
        }
      } on FormatException {
        throw const FormatException('conversations 的 user persona snapshot 無效');
      } on TypeError {
        throw const FormatException('conversations 的 user persona snapshot 無效');
      }
    }

    final storylineScopes = <String>{};
    for (final storyline in tables['rp_storylines']!) {
      final characterId = storyline['character_id']?.toString() ?? '';
      final storylineId = storyline['id']?.toString() ?? '';
      if (!characterIds.contains(characterId) || storylineId.isEmpty) {
        throw const FormatException('rp_storylines 引用無效');
      }
      if (!storylineScopes.add('$characterId\u0000$storylineId')) {
        throw const FormatException('rp_storylines 含重複故事線');
      }
    }

    final entityKeys = <String>{
      for (final entity in tables['rp_story_characters']!)
        '${entity['character_id']}\u0000${entity['continuity_id']}\u0000${entity['entity_key']}',
    };
    for (final alias in tables['rp_story_entity_aliases']!) {
      final key =
          '${alias['character_id']}\u0000${alias['continuity_id']}\u0000${alias['entity_key']}';
      if (!entityKeys.contains(key)) {
        throw const FormatException('rp_story_entity_aliases 引用了不存在的人物');
      }
    }
    for (final state in tables['rp_story_states']!) {
      final scope = '${state['character_id']}\u0000${state['continuity_id']}';
      if (!storylineScopes.contains(scope)) {
        throw const FormatException('rp_story_states 引用了不存在的故事線');
      }
      for (final field in const <String>[
        'subject_entity_key',
        'object_entity_key',
      ]) {
        final entityKey = state[field]?.toString() ?? '';
        if (entityKey.isNotEmpty &&
            !entityKeys.contains('$scope\u0000$entityKey')) {
          throw const FormatException('rp_story_states 引用了不存在的人物');
        }
      }
    }
    for (final table in const <String>[
      'rp_worldbook_entries',
      'rp_worldbook_sync_state',
      'rp_worldbook_review_items',
    ]) {
      for (final row in tables[table]!) {
        final scope = '${row['character_id']}\u0000${row['continuity_id']}';
        if (!storylineScopes.contains(scope)) {
          throw FormatException('$table 引用了不存在的故事線');
        }
      }
    }

    for (final revision in tables['message_revisions']!) {
      final conversationId = revision['conversation_id']?.toString() ?? '';
      if (!conversations.containsKey(conversationId)) {
        throw const FormatException('message_revisions 引用了不存在的窗口');
      }
      try {
        if (jsonDecode(revision['snapshot_json']!.toString()) is! Map) {
          throw const FormatException('message_revisions.snapshot_json 無效');
        }
      } on FormatException {
        throw const FormatException('message_revisions.snapshot_json 無效');
      }
    }

    for (final tombstone in tables['memory_rejection_tombstones']!) {
      if (!characterIds.contains(tombstone['character_id']?.toString())) {
        throw const FormatException('memory_rejection_tombstones 引用無效');
      }
      try {
        if (jsonDecode(tombstone['candidate_json']!.toString()) is! Map) {
          throw const FormatException(
            'memory_rejection_tombstones.candidate_json 無效',
          );
        }
      } on FormatException {
        throw const FormatException(
          'memory_rejection_tombstones.candidate_json 無效',
        );
      }
    }

    final bindingScopes = <String>{};

    final overrideScopes = <String>{};
    for (final override in tables['user_persona_mode_overrides']!) {
      final personaId = override['user_persona_id']?.toString() ?? '';
      if (!personas.containsKey(personaId)) {
        throw const FormatException(
          'user_persona_mode_overrides 引用了不存在的 user persona',
        );
      }
      final scope = '$personaId\u0000${override['context_mode']}';
      if (!overrideScopes.add(scope)) {
        throw const FormatException('user_persona_mode_overrides 含重複模式資料');
      }
    }

    for (final binding in tables['character_persona_bindings']!) {
      final characterId = binding['character_id']?.toString() ?? '';
      final personaId = binding['user_persona_id']?.toString() ?? '';
      final scope =
          '$characterId\u0000${binding['context_mode']}'
          '\u0000${binding['continuity_id']}';
      if (!bindingScopes.add(scope)) {
        throw const FormatException('character_persona_bindings 含重複綁定');
      }
      if (!characterIds.contains(characterId) ||
          !personas.containsKey(personaId) ||
          personas[personaId]!['is_archived'] == 1) {
        throw const FormatException('character_persona_bindings 引用無效');
      }
    }

    void validateRows(String table) {
      for (final row in tables[table]!) {
        final sourceId = row['source_conversation_id']?.toString().trim() ?? '';
        if (sourceId.isEmpty) continue;
        final conversation = conversations[sourceId];
        if (conversation == null) continue;
        final sameCharacter =
            row['character_id']?.toString() ==
            conversation['character_id']?.toString();
        final sameMode =
            row['context_mode']?.toString() ==
            conversation['context_mode']?.toString();
        final sameContinuity =
            row['continuity_id']?.toString() ==
            conversation['continuity_id']?.toString();
        if (!sameCharacter || !sameMode || !sameContinuity) {
          throw FormatException('$table 的來源窗口 context 不一致');
        }
      }
    }

    for (final table in const <String>[
      'memories',
      'context_summaries',
      'context_summary_segments',
      'context_summary_repairs',
      'context_keywords',
      'pending_memory_actions',
    ]) {
      validateRows(table);
    }

    for (final row in tables['rp_character_timeline']!) {
      final sourceId = row['source_conversation_id']?.toString().trim() ?? '';
      if (sourceId.isEmpty) continue;
      final conversation = conversations[sourceId];
      if (conversation == null) continue;
      final valid =
          conversation['context_mode'] == 'rp' &&
          row['character_id']?.toString() ==
              conversation['character_id']?.toString() &&
          row['continuity_id']?.toString() ==
              conversation['continuity_id']?.toString();
      if (!valid) {
        throw const FormatException('rp_character_timeline 的來源窗口 context 不一致');
      }
    }

    final selectedSignatureCharacters = <String>{};
    for (final row in tables['character_signatures']!) {
      final conversation =
          conversations[row['conversation_id']?.toString() ?? ''];
      if (conversation == null) {
        throw const FormatException('character_signatures 引用了不存在的窗口');
      }
      final valid =
          row['character_id']?.toString() ==
              conversation['character_id']?.toString() &&
          row['context_mode']?.toString() ==
              conversation['context_mode']?.toString() &&
          row['continuity_id']?.toString() ==
              conversation['continuity_id']?.toString();
      if (!valid) {
        throw const FormatException('character_signatures 的窗口 context 不一致');
      }
      if (row['is_selected'] == 1 &&
          !selectedSignatureCharacters.add(
            row['character_id']?.toString() ?? '',
          )) {
        throw const FormatException('同一角色只能選擇一條顯示中的個性簽名');
      }
    }

    for (final row in tables['character_diaries']!) {
      final characterId = row['character_id']?.toString() ?? '';
      if (!characterIds.contains(characterId)) {
        throw const FormatException('character_diaries 引用了不存在的角色');
      }
      final sourceConversationId =
          row['source_conversation_id']?.toString() ?? '';
      if (sourceConversationId.isEmpty) continue;
      final conversation = conversations[sourceConversationId];
      if (conversation == null ||
          conversation['character_id']?.toString() != characterId ||
          conversation['context_mode']?.toString() != 'daily') {
        throw const FormatException('character_diaries 的來源窗口不是該角色的日常窗口');
      }
    }
    for (final row in tables['character_self_notes']!) {
      final characterId = row['character_id']?.toString() ?? '';
      if (!characterIds.contains(characterId)) {
        throw const FormatException('character_self_notes 引用了不存在的角色');
      }
      final sourceConversationId =
          row['source_conversation_id']?.toString() ?? '';
      if (sourceConversationId.isNotEmpty &&
          !conversations.containsKey(sourceConversationId)) {
        throw const FormatException('character_self_notes 引用了不存在的窗口');
      }
    }
  }

  static void _deduplicateSavedMessages(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final seen = <String>{};
    tables['saved_messages'] = tables['saved_messages']!
        .where((row) => seen.add(row['message_id']?.toString() ?? ''))
        .toList(growable: false);
  }

  static void _normalizeTimelineEvents(
    Map<String, List<Map<String, Object?>>> tables,
    String fallbackTime,
  ) {
    final normalized = <Map<String, Object?>>[];
    final eventByDay = <String, Map<String, Object?>>{};
    for (final source in tables['character_timeline']!) {
      final row = Map<String, Object?>.from(source);
      final createdAtString =
          _validIsoString(row['created_at']) ?? fallbackTime;
      final updatedAtString =
          _validIsoString(row['updated_at']) ?? createdAtString;
      row['created_at'] = createdAtString;
      row['updated_at'] = updatedAtString;
      if (row['type']?.toString() != 'event') {
        normalized.add(row);
        continue;
      }

      final value = row['value']?.toString().trim() ?? '';
      if (value.isEmpty) continue;
      final characterId = _nonEmptyString(
        row['character_id'],
        fallback: 'default',
      );
      final createdAt = DateTime.tryParse(createdAtString);
      row['character_id'] = characterId;
      row['value'] = value;
      row['confirmed'] = _sqliteBool(row['confirmed'], defaultValue: 1);
      final sourceIds = <int>{};
      final rawSourceIds = row['source_message_ids'];
      dynamic decodedSourceIds = rawSourceIds;
      if (rawSourceIds is String && rawSourceIds.trim().isNotEmpty) {
        try {
          decodedSourceIds = jsonDecode(rawSourceIds);
        } catch (_) {
          decodedSourceIds = const <dynamic>[];
        }
      }
      if (decodedSourceIds is List) {
        for (final item in decodedSourceIds) {
          if (item is int && item > 0) sourceIds.add(item);
        }
      }
      final primarySourceId = row['source_message_id'];
      if (primarySourceId is int && primarySourceId > 0) {
        sourceIds.add(primarySourceId);
      }
      final sortedSourceIds = sourceIds.toList()..sort();
      row['source_message_id'] = sortedSourceIds.isEmpty
          ? null
          : sortedSourceIds.first;
      row['source_message_ids'] = jsonEncode(sortedSourceIds);
      row['source_evidence'] = row['source_evidence']?.toString() ?? '';
      if (createdAt != null) row['week_group'] = isoWeekGroup(createdAt);

      final key =
          '$characterId\u0000$value\u0000${createdAtString.substring(0, 10)}';
      final existing = eventByDay[key];
      if (existing != null) {
        if (row['confirmed'] == 1) existing['confirmed'] = 1;
        continue;
      }
      eventByDay[key] = row;
      normalized.add(row);
    }
    tables['character_timeline'] = normalized;
  }

  static String _archiveCharacterId(Map<String, Object?> archived) {
    final direct = archived['character_id']?.toString().trim() ?? '';
    if (direct.isNotEmpty) return direct;

    // v1-v4 的 archive 尚未有 character_id，但 content_snapshot 是原始
    // memory JSON，通常仍保留角色鍵；可精確恢復時不要一律掉進 default。
    final snapshot = archived['content_snapshot'];
    try {
      final decoded = snapshot is String ? jsonDecode(snapshot) : snapshot;
      if (decoded is Map) {
        final value = decoded['character_id']?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    } catch (_) {
      // 舊檔可能是損壞前就存在的純文字快照；安全回退 default。
    }
    return 'default';
  }

  static void _validatePrimaryKeys(
    Map<String, List<Map<String, Object?>>> tables, {
    required bool strict,
  }) {
    for (final table in appTables) {
      if (table == 'memory_embeddings' ||
          table == 'character_persona_bindings' ||
          table == 'user_persona_mode_overrides') {
        continue;
      }
      final seen = <Object?>{};
      for (final row in tables[table]!) {
        final id = row['id'];
        if (id == null) {
          // Legacy raw tables occasionally omitted AUTOINCREMENT ids. SQLite can
          // regenerate those safely; v5 must preserve every original id.
          if (strict) throw FormatException('v5 $table 有資料列缺少 id');
          continue;
        }
        if (!seen.add(id)) {
          throw FormatException('$table 含重複主鍵：$id');
        }
      }
    }
  }

  static int _validateMessageConversationLinks(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final conversationIds = tables['conversations']!
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();

    final originalMessages = tables['messages']!;
    final originalCount = originalMessages.length;
    final validMessages = <Map<String, Object?>>[];

    for (final message in originalMessages) {
      final conversationId = message['conversation_id']?.toString();
      final isOrphan = !conversationIds.contains(conversationId);
      if (isOrphan) {
        debugPrint('Backup import: dropped orphan message id=${message['id']}');
      } else {
        validMessages.add(message);
      }
    }

    final newCount = validMessages.length;
    final droppedCount = originalCount - newCount;
    if (droppedCount > 0) {
      debugPrint('Backup import: dropped $droppedCount orphaned messages.');
      tables['messages'] = validMessages;
    }
    return droppedCount;
  }

  static Future<_PreparedBackup> _prepareForCurrentSchema(
    Database db,
    _NormalizedBackup normalized,
  ) async {
    final schemaColumns = <String, Set<String>>{};
    for (final table in appTables) {
      final info = await db.rawQuery("PRAGMA table_info('$table')");
      if (info.isEmpty) {
        throw StateError('目前資料庫缺少必要資料表：$table');
      }
      schemaColumns[table] = info
          .map((row) => row['name']?.toString())
          .whereType<String>()
          .toSet();
    }

    var skippedVoiceCount = 0;
    final filtered = <String, List<Map<String, Object?>>>{};
    for (final table in appTables) {
      final columns = schemaColumns[table]!;
      final rows = <Map<String, Object?>>[];
      for (final source in normalized.tables[table]!) {
        final row = <String, Object?>{
          for (final entry in source.entries)
            if (columns.contains(entry.key)) entry.key: entry.value,
        };
        final pathColumn = switch (table) {
          'characters' || 'messages' || 'shop_items' => 'image_path',
          'user_personas' => 'avatar_path',
          'stickers' || 'saved_voices' => 'file_path',
          _ => null,
        };
        // characters uses avatar_path rather than image_path.
        final effectivePathColumn = table == 'characters'
            ? 'avatar_path'
            : pathColumn;
        if (effectivePathColumn != null &&
            row.containsKey(effectivePathColumn)) {
          final safePath = await AppFileSafety.normalizeOwnedPath(
            row[effectivePathColumn],
          );
          row[effectivePathColumn] = switch (table) {
            'messages' || 'characters' || 'saved_voices' => safePath,
            _ => safePath ?? '',
          };
        }
        if (table == 'saved_voices') {
          final path = row['file_path'];
          if (path is! String || path.isEmpty || !await File(path).exists()) {
            skippedVoiceCount++;
            continue;
          }
        }
        rows.add(row);
      }
      filtered[table] = rows;
    }

    final safePreferences = <String, Object?>{};
    for (final entry in normalized.preferences.entries) {
      final looksLikePath = entry.key.toLowerCase().contains('path');
      if (!looksLikePath || entry.value is! String) {
        safePreferences[entry.key] = entry.value;
        continue;
      }
      safePreferences[entry.key] =
          await AppFileSafety.normalizeOwnedPath(entry.value) ?? '';
    }

    return _PreparedBackup(
      tables: filtered,
      preferences: safePreferences,
      isLegacy: normalized.isLegacy,
      skippedVoiceCount: skippedVoiceCount,
      droppedOrphanMessageCount: normalized.droppedOrphanMessageCount,
    );
  }

  static Map<String, Object?> _normalizePreferences(dynamic raw) {
    if (raw == null) return <String, Object?>{};
    final map = _stringKeyMap(raw, field: 'preferences');
    final result = <String, Object?>{};
    for (final entry in map.entries) {
      if (_isBlockedImportKey(entry.key)) continue;
      final value = entry.value;
      if (value is String || value is int || value is double || value is bool) {
        result[entry.key] = value;
      } else if (value is List && value.every((item) => item is String)) {
        result[entry.key] = value.cast<String>().toList(growable: false);
      } else if (value != null) {
        throw FormatException('preferences.${entry.key} 型別不支援');
      }
    }
    return result;
  }

  static Future<Future<void> Function()> _applyPreferencesWithRollback(
    Map<String, Object?> imported,
  ) async {
    if (imported.isEmpty) return () async {};
    final prefs = await SharedPreferences.getInstance();
    final previous = <String, Object?>{};
    final existed = <String>{};
    for (final key in imported.keys) {
      if (prefs.containsKey(key)) {
        existed.add(key);
        previous[key] = prefs.get(key);
      }
    }

    try {
      for (final entry in imported.entries) {
        final ok = await _setPreference(prefs, entry.key, entry.value);
        if (!ok) throw StateError('偏好設定寫入失敗：${entry.key}');
      }
    } catch (_) {
      await _restorePreferenceSnapshot(prefs, imported.keys, existed, previous);
      rethrow;
    }

    return () =>
        _restorePreferenceSnapshot(prefs, imported.keys, existed, previous);
  }

  static Future<void> _restorePreferenceSnapshot(
    SharedPreferences prefs,
    Iterable<String> importedKeys,
    Set<String> existed,
    Map<String, Object?> previous,
  ) async {
    for (final key in importedKeys) {
      if (existed.contains(key)) {
        await _setPreference(prefs, key, previous[key]);
      } else {
        await prefs.remove(key);
      }
    }
  }

  static Future<bool> _setPreference(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) {
    if (value is String) return prefs.setString(key, value);
    if (value is int) return prefs.setInt(key, value);
    if (value is double) return prefs.setDouble(key, value);
    if (value is bool) return prefs.setBool(key, value);
    if (value is List<String>) return prefs.setStringList(key, value);
    throw FormatException('偏好設定 $key 型別不支援');
  }

  static Future<void> _ensureOptionalTables() async {
    // 這兩組表由功能服務懶建立；先確保存在，才能做完整快照／交易還原。
    await EmotionCoordinates.activePoints('__backup_schema__');
    await CharacterTimelineService.getStates('__backup_schema__');
    // v39 pending_memory_actions、v42 web_search_usage_logs 若在同版本號內
    // 後加入 _onCreate，已有的 DB 不會重跑 migration，必須在這裡補建。
    await DatabaseHelper.ensureAllSchemaTables();
  }

  static Future<void> _verifyTableManifest(Database db) async {
    final rows = await db.rawQuery('''
      SELECT name FROM sqlite_master
      WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%'
        AND name != 'android_metadata'
        AND name NOT LIKE 'memories_fts%'
        AND name != 'keepalive_ping_guard'
    ''');
    final actual = rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
    final declared = appTables.toSet();
    final missing = declared.difference(actual);
    final unexpected = actual.difference(declared);
    if (missing.isNotEmpty || unexpected.isNotEmpty) {
      throw StateError(
        '備份資料表清單與目前 schema 不一致'
        '${missing.isEmpty ? '' : '；缺少：${missing.join(', ')}'}'
        '${unexpected.isEmpty ? '' : '；未列入：${unexpected.join(', ')}'}',
      );
    }
  }

  @visibleForTesting
  static Future<void> verifyTableManifestForTesting(Database db) =>
      _verifyTableManifest(db);

  static String? _sanitizeImportPath(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    if (value.contains('..') || !p.isAbsolute(value)) return null;
    return p.normalize(value);
  }

  static List<dynamic> _list(dynamic value, {required String field}) {
    if (value is! List) throw FormatException('$field 必須是陣列');
    return value;
  }

  static List<Map<String, Object?>> _mapRows(
    dynamic value, {
    required String field,
    required bool required,
  }) {
    if (value == null && !required) return <Map<String, Object?>>[];
    final values = _list(value, field: field);
    return values.indexed
        .map((indexed) {
          final row = indexed.$2;
          if (row is! Map) {
            throw FormatException('$field[${indexed.$1}] 必須是物件');
          }
          return <String, Object?>{
            for (final entry in row.entries) entry.key.toString(): entry.value,
          };
        })
        .toList(growable: false);
  }

  static Map<String, Object?> _stringKeyMap(
    dynamic value, {
    required String field,
  }) {
    if (value is! Map) throw FormatException('$field 必須是物件');
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  static String _requiredId(dynamic value, String field) {
    final result = value?.toString().trim() ?? '';
    if (result.isEmpty) throw FormatException('$field 不可為空');
    return result;
  }

  static String _nonEmptyString(dynamic value, {required String fallback}) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }

  static int _sqliteBool(dynamic value, {int defaultValue = 0}) {
    if (value == true || value == 1 || value == '1') return 1;
    if (value == false || value == 0 || value == '0') return 0;
    return defaultValue;
  }

  static String? _validIsoString(dynamic value) {
    if (value is! String || DateTime.tryParse(value) == null) return null;
    return value;
  }

  static int _pragmaInt(List<Map<String, Object?>> rows, String key) {
    if (rows.isEmpty) return 0;
    final value = rows.first[key] ?? rows.first.values.firstOrNull;
    return value is int ? value : int.tryParse(value.toString()) ?? 0;
  }

  // ════════════════════════════════════
  // 2) 本地全量備份（覆蓋式）
  // ════════════════════════════════════

  /// 備份 SQLite 原子快照 + 可攜式 SharedPreferences 到 app 私有資料夾。
  static Future<String> saveLocalBackup() {
    return _operationLock.synchronized(_saveLocalBackupUnlocked);
  }

  static Future<String> _saveLocalBackupUnlocked() async {
    final backupDir = await _getBackupDir(create: false);
    final stagingDir = Directory('${backupDir.path}.new');
    final prevDir = Directory('${backupDir.path}.prev');

    // 自癒：上次輪替若在「current 已挪走、staging 還沒轉正」之間 crash，
    // current 會缺失但 prev 是完整舊備份——把它接回來。
    if (!await backupDir.exists() && await prevDir.exists()) {
      await prevDir.rename(backupDir.path);
    }

    // 全部先寫進 staging，寫完再原子輪替——直接覆蓋 current 的舊做法
    // 在拷貝中途 crash 時會把唯一一份備份毀掉。
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    await stagingDir.create(recursive: true);

    final db = await DatabaseHelper.database;
    final versionRows = await db.rawQuery('PRAGMA user_version');
    final dbVersion = _pragmaInt(versionRows, 'user_version');
    final snapshotPath = p.join(stagingDir.path, 'yanci.db');
    final snapshotFile = File(snapshotPath);
    if (await snapshotFile.exists()) await snapshotFile.delete();
    // VACUUM INTO is a single consistent SQLite snapshot. No WAL/SHM sidecars
    // are copied, so a chat write cannot produce a mixed-time backup.
    await db.execute(_vacuumIntoSql(snapshotPath));

    final prefs = await SharedPreferences.getInstance();
    await File(p.join(stagingDir.path, 'preferences.json')).writeAsString(
      const JsonEncoder.withIndent(' ').convert(_exportablePreferences(prefs)),
      flush: true,
    );

    await File(p.join(stagingDir.path, 'backup_meta.json')).writeAsString(
      jsonEncode({
        'app': 'Holt',
        'backed_up_at': DateTime.now().toIso8601String(),
        // 直接讀 SQLite 的單一 schema version 來源，不再硬編舊版 18。
        'db_version': dbVersion,
      }),
      flush: true,
    );

    // 原子輪替（rename 同一文件系統內原子）：
    // current → prev（順便保留一個上世代備份），staging → current。
    // 任一時刻磁碟上都至少有一份完整備份。
    if (await prevDir.exists()) await prevDir.delete(recursive: true);
    if (await backupDir.exists()) await backupDir.rename(prevDir.path);
    await stagingDir.rename(backupDir.path);
    return backupDir.path;
  }

  static String _vacuumIntoSql(String path) {
    final escaped = path.replaceAll("'", "''");
    return "VACUUM INTO '$escaped'";
  }

  @visibleForTesting
  static String vacuumIntoSqlForTesting(String path) => _vacuumIntoSql(path);

  static Future<DateTime?> getLastBackupTime() async {
    try {
      final backupDir = await _getBackupDir(create: false);
      final metaFile = File(p.join(backupDir.path, 'backup_meta.json'));
      if (await metaFile.exists()) {
        final meta = jsonDecode(await metaFile.readAsString());
        if (meta is Map) {
          return DateTime.tryParse(meta['backed_up_at']?.toString() ?? '');
        }
      }
    } catch (_) {
      // 狀態顯示不應阻止 App 啟動。
    }
    return null;
  }

  // ════════════════════════════════════
  // 內部目錄
  // ════════════════════════════════════

  static Future<Directory> _getExportDir() async {
    final temporary = await getTemporaryDirectory();
    final dir = Directory(p.join(temporary.path, 'HoltExport'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _prepareExportDir() async {
    final dir = await _getExportDir();
    final staleBefore = DateTime.now().subtract(const Duration(days: 1));
    for (final file in await _exportFilesIn(dir)) {
      if ((await file.lastModified()).isBefore(staleBefore)) {
        await file.delete();
      }
    }
    return dir;
  }

  static Future<List<File>> _legacyExportFiles() async {
    if (!Platform.isAndroid) return const <File>[];
    final external = await getExternalStorageDirectory();
    if (external == null) return const <File>[];
    return _exportFilesIn(Directory(p.join(external.path, 'Holt')));
  }

  static Future<List<File>> _exportFilesIn(Directory dir) async {
    if (!await dir.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && _isExportArtifactName(p.basename(entity.path))) {
        files.add(entity);
      }
    }
    return files;
  }

  static bool _isExportArtifactName(String name) {
    return (name.startsWith('holt_backup_') &&
            (name.endsWith('.holt.backup') || name.endsWith('.holt.zip'))) ||
        (name.startsWith('holt_export_') && name.endsWith('.json'));
  }

  static Future<Directory> _getBackupDir({bool create = true}) async {
    final documents = await getAppDocumentsDirectory();
    final dir = Directory(p.join(documents.path, 'HoltBackup'));
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

class _NormalizedBackup {
  const _NormalizedBackup({
    required this.version,
    required this.tables,
    required this.preferences,
    required this.isLegacy,
    required this.droppedOrphanMessageCount,
  });

  final int version;
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> preferences;
  final bool isLegacy;
  final int droppedOrphanMessageCount;
}

class _PreparedBackup {
  const _PreparedBackup({
    required this.tables,
    required this.preferences,
    required this.isLegacy,
    required this.skippedVoiceCount,
    required this.droppedOrphanMessageCount,
  });

  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> preferences;
  final bool isLegacy;
  final int skippedVoiceCount;
  final int droppedOrphanMessageCount;
}

/// 不依賴額外套件的程序內 async mutex。
///
/// 每個呼叫會先同步排入 tail，前一個操作無論成功或失敗都會釋放下一個。
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;

    return () async {
      try {
        await previous;
        return await action();
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }();
  }
}
