import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';

enum AnniversaryPlacement {
  hidden('hidden'),
  avatarLine('avatar_line'),
  belowAvatars('below_avatars'),
  aboveHeartbeat('above_heartbeat');

  const AnniversaryPlacement(this.storageValue);

  final String storageValue;

  static AnniversaryPlacement parse(Object? value) {
    return AnniversaryPlacement.values.firstWhere(
      (item) => item.storageValue == value?.toString(),
      orElse: () => AnniversaryPlacement.hidden,
    );
  }
}

class AnniversaryEntry {
  const AnniversaryEntry({
    required this.id,
    required this.userPersonaId,
    required this.characterId,
    required this.title,
    required this.startDate,
    required this.placement,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userPersonaId;
  final String characterId;
  final String title;
  final DateTime startDate;
  final AnniversaryPlacement placement;
  final DateTime createdAt;
  final DateTime updatedAt;

  AnniversaryEntry copyWith({
    String? title,
    DateTime? startDate,
    AnniversaryPlacement? placement,
    DateTime? updatedAt,
  }) {
    return AnniversaryEntry(
      id: id,
      userPersonaId: userPersonaId,
      characterId: characterId,
      title: title ?? this.title,
      startDate: startDate ?? this.startDate,
      placement: placement ?? this.placement,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'user_persona_id': userPersonaId,
    'character_id': characterId,
    'title': title,
    'start_date': AnniversaryService.storageDate(startDate),
    'placement': placement.storageValue,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  static AnniversaryEntry? tryParse(Object? value) {
    if (value is! Map) return null;
    final map = value.map((key, item) => MapEntry(key.toString(), item));
    final id = map['id']?.toString().trim() ?? '';
    final personaId = map['user_persona_id']?.toString().trim() ?? '';
    final characterId = map['character_id']?.toString().trim() ?? '';
    final title = map['title']?.toString().trim() ?? '';
    final startDate = AnniversaryService.parseStorageDate(
      map['start_date']?.toString(),
    );
    final createdAt = DateTime.tryParse(map['created_at']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(map['updated_at']?.toString() ?? '');
    if (id.isEmpty ||
        personaId.isEmpty ||
        characterId.isEmpty ||
        title.isEmpty ||
        startDate == null ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    return AnniversaryEntry(
      id: id,
      userPersonaId: personaId,
      characterId: characterId,
      title: title,
      startDate: startDate,
      placement: AnniversaryPlacement.parse(map['placement']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class AnniversaryDisplaySettings {
  const AnniversaryDisplaySettings({this.hideUserName = false});

  final bool hideUserName;
}

class AnniversaryService {
  static const String _entriesKey = 'anniversary_entries_v1';
  static const String _settingsKey = 'anniversary_display_settings_v1';

  static DateTime dateOnly(DateTime value) {
    final local = value.isUtc ? value.toLocal() : value;
    return DateTime(local.year, local.month, local.day);
  }

  static String storageDate(DateTime value) {
    final date = dateOnly(value);
    String two(int number) => number.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  static DateTime? parseStorageDate(String? value) {
    final parts = value?.split('-') ?? const <String>[];
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }

  /// Inclusive natural-day count: the selected date is day one. It never
  /// reads keep-alive or memory-decay clocks, so offline time is not frozen.
  static int naturalDayNumber(DateTime startDate, {DateTime? now}) {
    final start = dateOnly(startDate);
    final today = dateOnly(now ?? DateTime.now());
    return today.difference(start).inDays + 1;
  }

  static Future<List<AnniversaryEntry>> list({
    required String userPersonaId,
    required String characterId,
  }) async {
    final all = await _loadAll();
    final result = all
        .where(
          (entry) =>
              entry.userPersonaId == userPersonaId &&
              entry.characterId == characterId,
        )
        .toList();
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  static Future<AnniversaryEntry> create({
    required String userPersonaId,
    required String characterId,
    required String title,
    required DateTime startDate,
  }) async {
    final now = DateTime.now();
    final entry = AnniversaryEntry(
      id: const Uuid().v4(),
      userPersonaId: userPersonaId.trim(),
      characterId: characterId.trim(),
      title: title.trim(),
      startDate: dateOnly(startDate),
      placement: AnniversaryPlacement.hidden,
      createdAt: now,
      updatedAt: now,
    );
    if (entry.userPersonaId.isEmpty ||
        entry.characterId.isEmpty ||
        entry.title.isEmpty) {
      throw ArgumentError('persona, character and title are required');
    }
    final all = await _loadAll();
    all.add(entry);
    await _saveAll(all);
    return entry;
  }

  static Future<void> update(AnniversaryEntry entry) async {
    final all = await _loadAll();
    final index = all.indexWhere((item) => item.id == entry.id);
    if (index < 0) return;
    all[index] = entry.copyWith(updatedAt: DateTime.now());
    await _saveAll(all);
  }

  static Future<void> delete(String id) async {
    final all = await _loadAll();
    all.removeWhere((entry) => entry.id == id);
    await _saveAll(all);
  }

  static Future<void> deleteForPersona(String userPersonaId) async {
    final personaId = userPersonaId.trim();
    if (personaId.isEmpty) return;
    final all = await _loadAll();
    all.removeWhere((entry) => entry.userPersonaId == personaId);
    await _saveAll(all);

    final settings = await _loadSettings();
    final prefix = '${Uri.encodeComponent(personaId)}::';
    settings.removeWhere((key, _) => key.startsWith(prefix));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings));
  }

  static Future<AnniversaryDisplaySettings> settings({
    required String userPersonaId,
    required String characterId,
  }) async {
    final all = await _loadSettings();
    final row = all[_scopeKey(userPersonaId, characterId)];
    return AnniversaryDisplaySettings(
      hideUserName: row?['hide_user_name'] == true,
    );
  }

  static Future<void> setHideUserName({
    required String userPersonaId,
    required String characterId,
    required bool value,
  }) async {
    final all = await _loadSettings();
    all[_scopeKey(userPersonaId, characterId)] = <String, Object?>{
      'hide_user_name': value,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(all));
  }

  static Future<DateTime> defaultStartDate(String characterId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT MIN(created_at) AS first_at FROM conversations '
      'WHERE character_id = ?',
      <Object?>[characterId],
    );
    final firstWindow = rows.isEmpty
        ? null
        : DateTime.tryParse(rows.first['first_at']?.toString() ?? '');
    if (firstWindow != null) return dateOnly(firstWindow);

    // A character can exist before their first chat window is opened. In that
    // case only, use the character creation date as a stable fallback.
    final character = await DatabaseHelper.getCharacter(characterId);
    final created = DateTime.tryParse(
      character?['created_at']?.toString() ?? '',
    );
    return dateOnly(created ?? DateTime.now());
  }

  static String _scopeKey(String personaId, String characterId) {
    return '${Uri.encodeComponent(personaId)}::${Uri.encodeComponent(characterId)}';
  }

  static Future<List<AnniversaryEntry>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_entriesKey);
    if (raw == null || raw.isEmpty) return <AnniversaryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <AnniversaryEntry>[];
      return decoded
          .map(AnniversaryEntry.tryParse)
          .whereType<AnniversaryEntry>()
          .toList();
    } on FormatException {
      return <AnniversaryEntry>[];
    } on TypeError {
      return <AnniversaryEntry>[];
    }
  }

  static Future<void> _saveAll(List<AnniversaryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _entriesKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  static Future<Map<String, Map<String, Object?>>> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) {
      return <String, Map<String, Object?>>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Map<String, Object?>>{};
      final result = <String, Map<String, Object?>>{};
      for (final item in decoded.entries) {
        if (item.value is! Map) continue;
        result[item.key.toString()] = (item.value as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return result;
    } on FormatException {
      return <String, Map<String, Object?>>{};
    } on TypeError {
      return <String, Map<String, Object?>>{};
    }
  }
}
