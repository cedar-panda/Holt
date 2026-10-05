import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../memory/database.dart';
import '../../models/context_mode.dart';
import '../../models/message.dart';

enum ConversationHistoryFilter { all, daily, rp }

/// User-facing mode preferences. These values select the identity of a new
/// window only; an existing conversation always uses its persisted identity.
abstract final class ContextModeSettings {
  static const _globalRpKey = 'context_mode_global_rp_enabled_v1';
  static const _historyPrefix = 'context_mode_history_filter_v1:';
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void _notifyChanged() => revision.value++;

  static Future<bool> getGlobalRpEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_globalRpKey) ?? false;
  }

  static Future<void> setGlobalRpEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_globalRpKey, enabled);
    _notifyChanged();
  }

  static ContextMode preferredModeFromCharacter(Map<String, dynamic>? row) =>
      ContextMode.fromStorage(row?['preferred_context_mode'] ?? 'daily');

  static Future<ContextMode> effectiveMode(String characterId) async {
    if (await getGlobalRpEnabled()) return ContextMode.rp;
    final row = await DatabaseHelper.getCharacter(characterId);
    return preferredModeFromCharacter(row);
  }

  static Future<void> setCharacterPreferredMode(
    String characterId,
    ContextMode mode,
  ) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'characters',
      <String, Object?>{'preferred_context_mode': mode.storageValue},
      where: 'id = ?',
      whereArgs: <Object?>[characterId],
    );
    _notifyChanged();
  }

  static Future<ConversationHistoryFilter> historyFilter(
    String characterId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_historyPrefix$characterId');
    return ConversationHistoryFilter.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => ConversationHistoryFilter.all,
    );
  }

  static Future<void> setHistoryFilter(
    String characterId,
    ConversationHistoryFilter filter,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_historyPrefix$characterId', filter.name);
  }

  static List<Conversation> filterConversations(
    Iterable<Conversation> conversations,
    ConversationHistoryFilter filter,
  ) {
    if (filter == ConversationHistoryFilter.all) return conversations.toList();
    final mode = filter == ConversationHistoryFilter.rp
        ? ContextMode.rp
        : ContextMode.daily;
    return conversations.where((item) => item.contextMode == mode).toList();
  }

  static Future<bool> latestWindowDiffers(
    String characterId,
    ContextMode mode,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'conversations',
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isNotEmpty &&
        Conversation.fromMap(rows.first).contextMode != mode;
  }
}
