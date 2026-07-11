import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../memory/emotion_coordinates.dart';
import 'character_timeline_service.dart';

/// JSON 備份和本地資料庫備份。
///
/// JSON v5 是「覆蓋還原」格式：先完整解析、驗證及正規化，然後在一個
/// SQLite transaction 內清空並寫回所有 app 資料表。舊 v1-v4 Holt/Yanci
/// 匯出仍可導入；因舊格式沒有 message id，與訊息 ID 有關的欄位只能盡力
/// 由 conversation + content 重新配對。
class BackupService {
  static const int exportVersion = 5;
  static final _operationLock = _AsyncMutex();

  /// v5 明確列出的 app-owned tables；不包含 sqlite_sequence 等 SQLite 內部表。
  static const List<String> appTables = [
    'characters',
    'conversations',
    'messages',
    'memories',
    'spider_web_links',
    'archive',
    'sticky_notes',
    'shop_items',
    'backpack_items',
    'stickers',
    'saved_messages',
    'context_summaries',
    'context_keywords',
    'usage_logs',
    'emotion_points',
    'grudge_seals',
    'character_timeline',
    'saved_voices',
  ];

  // 父表先寫、子表後寫。清除時使用反向順序。
  static const List<String> _insertOrder = appTables;

  static const Set<String> _integerPrimaryKeyTables = {
    'messages',
    'memories',
    'spider_web_links',
    'archive',
    'sticky_notes',
    'backpack_items',
    'stickers',
    'saved_messages',
    'context_summaries',
    'context_keywords',
    'usage_logs',
    'emotion_points',
    'grudge_seals',
    'character_timeline',
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

  // ════════════════════════════════════
  // 1) JSON v5 導出
  // ════════════════════════════════════

  /// 導出所有 app 資料表及可攜式 SharedPreferences，返回暫存檔路徑。
  static Future<String> exportAllAsJson() {
    return _operationLock.synchronized(_exportAllAsJsonUnlocked);
  }

  static Future<String> _exportAllAsJsonUnlocked() async {
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
    final data = <String, Object?>{
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

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'holt_export_$timestamp.json';
    final dir = await _getExportDir();
    final filePath = p.join(dir.path, fileName);
    await File(filePath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    return filePath;
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

  static Future<String> _importFromJsonUnlocked(
    Map<String, dynamic> data,
  ) async {
    // 第一階段：不動現有資料，完成格式、型別、主鍵及必要關聯驗證。
    final normalized = _normalizeBackup(data);

    await _ensureOptionalTables();
    final db = await DatabaseHelper.database;
    await _verifyTableManifest(db);
    final prepared = await _prepareForCurrentSchema(db, normalized);

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
    if (prepared.isLegacy) {
      parts.add('舊版訊息ID已重建；收藏已盡力配對，刮卡/轉帳舊訊息關聯無法保證');
    }
    return parts.join('、');
  }

  /// 純格式正規化入口，供單元測試驗證 v5 與舊格式，不讀寫 DB/偏好。
  static Map<String, List<Map<String, Object?>>> normalizeForTesting(
    Map<String, dynamic> data,
  ) {
    final normalized = _normalizeBackup(data);
    return {
      for (final entry in normalized.tables.entries)
        entry.key: entry.value
            .map((row) => Map<String, Object?>.from(row))
            .toList(growable: false),
    };
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
    if (!isLegacy) {
      final schema = _stringKeyMap(data['schema'], field: 'schema');
      if (schema['database_version'] is! int ||
          (schema['database_version'] as int) <= 0) {
        throw const FormatException('v5 schema.database_version 必須是正整數');
      }
      final tables = _list(
        schema['tables'],
        field: 'schema.tables',
      ).map((value) => value.toString()).toSet();
      final missing = appTables.where((table) => !tables.contains(table));
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

    if (isLegacy) {
      _normalizeLegacyCore(data, result, fallbackTime);
    } else {
      for (final table in appTables) {
        result[table] = _mapRows(data[table], field: table, required: true);
      }
    }

    // Old and new rows both pass through path sanitisation and safe defaults.
    _normalizeCommonRows(result, fallbackTime, isLegacy: isLegacy);
    _validatePrimaryKeys(result, strict: !isLegacy);
    _validateMessageConversationLinks(result);

    final preferences = _normalizePreferences(data['preferences']);
    return _NormalizedBackup(
      version: version,
      tables: result,
      preferences: preferences,
      isLegacy: isLegacy,
    );
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
          'split_mode': _sqliteBool(legacyMessage['split_mode']),
          'memory_log': legacyMessage['memory_log']?.toString() ?? '',
          'cache_hit': _sqliteBool(legacyMessage['cache_hit']),
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
  }) {
    for (final character in tables['characters']!) {
      character['id'] = _requiredId(character['id'], 'characters.id');
      character['name'] = character['name']?.toString() ?? '';
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
      conversation['window_summary_id'] =
          conversation['window_summary_id']?.toString() ?? '';
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
      message['split_mode'] = _sqliteBool(message['split_mode']);
      message['memory_log'] = message['memory_log']?.toString() ?? '';
      message['cache_hit'] = _sqliteBool(message['cache_hit']);
      message['created_at'] =
          _validIsoString(message['created_at']) ?? fallbackTime;
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

  static void _validateMessageConversationLinks(
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
        print('⚠️ 發現並捨棄孤兒訊息 [ID: ${message['id']}] - 內容: ${message['text']}');
      } else {
        validMessages.add(message);
      }
    }

    final newCount = validMessages.length;
    if (newCount < originalCount) {
      print('Backup import: dropped ${originalCount - newCount} orphaned messages.');
      tables['messages'] = validMessages;
    }
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
        if (table == 'saved_voices') {
          final path = source['file_path'];
          if (path is! String || path.isEmpty || !await File(path).exists()) {
            skippedVoiceCount++;
            continue;
          }
        }
        rows.add(<String, Object?>{
          for (final entry in source.entries)
            if (columns.contains(entry.key)) entry.key: entry.value,
        });
      }
      filtered[table] = rows;
    }

    return _PreparedBackup(
      tables: filtered,
      preferences: normalized.preferences,
      isLegacy: normalized.isLegacy,
      skippedVoiceCount: skippedVoiceCount,
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
  }

  static Future<void> _verifyTableManifest(Database db) async {
    final rows = await db.rawQuery('''
      SELECT name FROM sqlite_master
      WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%'
        AND name != 'android_metadata'
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

  /// 備份 SQLite DB + 可攜式 SharedPreferences 到 app 私有資料夾。
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

    final dbPath = p.join(await getDatabasesPath(), 'yanci.db');
    final dbFile = File(dbPath);
    var dbVersion = 0;

    if (await dbFile.exists()) {
      final db = await DatabaseHelper.database;
      final versionRows = await db.rawQuery('PRAGMA user_version');
      dbVersion = _pragmaInt(versionRows, 'user_version');
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {
        // 個別 SQLite 版本不支援 TRUNCATE；仍會連同 WAL/SHM 備份。
      }

      await dbFile.copy(p.join(stagingDir.path, 'yanci.db'));
      final walFile = File('$dbPath-wal');
      final shmFile = File('$dbPath-shm');
      if (await walFile.exists()) {
        await walFile.copy(p.join(stagingDir.path, 'yanci.db-wal'));
      }
      if (await shmFile.exists()) {
        await shmFile.copy(p.join(stagingDir.path, 'yanci.db-shm'));
      }
    }

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
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        final dir = Directory(p.join(external.path, 'Holt'));
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      }
    }
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(documents.path, 'Holt'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _getBackupDir({bool create = true}) async {
    final documents = await getApplicationDocumentsDirectory();
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
  });

  final int version;
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> preferences;
  final bool isLegacy;
}

class _PreparedBackup {
  const _PreparedBackup({
    required this.tables,
    required this.preferences,
    required this.isLegacy,
    required this.skippedVoiceCount,
  });

  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> preferences;
  final bool isLegacy;
  final int skippedVoiceCount;
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
