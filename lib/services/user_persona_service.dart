import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/message.dart';
import 'locale_strings.dart';
import 'settings/api_settings.dart';
import 'settings/user_settings.dart';

/// One user-authored identity that can be bound to a companion.
///
/// This model deliberately lives with its service so the future UI can depend
/// on one narrow API instead of spreading persona SQL through screen files.
@immutable
class UserPersona {
  final String id;
  final String displayName;
  final String pronouns;
  final String bio;
  final String avatarPath;
  final String promptContent;
  final bool isDefault;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UserPersona({
    required this.id,
    this.displayName = '',
    this.pronouns = '',
    this.bio = '',
    this.avatarPath = '',
    this.promptContent = '',
    this.isDefault = false,
    this.isArchived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  UserPersona copyWith({
    String? displayName,
    String? pronouns,
    String? bio,
    String? avatarPath,
    String? promptContent,
  }) => UserPersona(
    id: id,
    displayName: displayName ?? this.displayName,
    pronouns: pronouns ?? this.pronouns,
    bio: bio ?? this.bio,
    avatarPath: avatarPath ?? this.avatarPath,
    promptContent: promptContent ?? this.promptContent,
    isDefault: isDefault,
    isArchived: isArchived,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory UserPersona.fromMap(Map<String, Object?> map) => UserPersona(
    id: map['id']?.toString() ?? '',
    displayName: map['display_name']?.toString() ?? '',
    pronouns: map['pronouns']?.toString() ?? '',
    bio: map['bio']?.toString() ?? '',
    avatarPath: map['avatar_path']?.toString() ?? '',
    promptContent: map['prompt_content']?.toString() ?? '',
    isDefault: (map['is_default'] as int? ?? 0) == 1,
    isArchived: (map['is_archived'] as int? ?? 0) == 1,
    createdAt:
        DateTime.tryParse(map['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt:
        DateTime.tryParse(map['updated_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'display_name': displayName,
    'pronouns': pronouns,
    'bio': bio,
    'avatar_path': avatarPath,
    'prompt_content': promptContent,
    'is_default': isDefault ? 1 : 0,
    'is_archived': isArchived ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// A window stores prompt-bearing identity fields at birth. Avatar remains
  /// on the persona row so portable backup has one canonical media path.
  String toPromptSnapshot() => jsonEncode(<String, Object?>{
    'version': 2,
    'id': id,
    'display_name': displayName,
    'pronouns': pronouns,
    'bio': bio,
    'prompt_content': promptContent,
  });

  factory UserPersona.fromPromptSnapshot(
    String snapshot, {
    String avatarPath = '',
  }) {
    final decoded = jsonDecode(snapshot);
    if (decoded is! Map) {
      throw const FormatException('invalid persona snapshot');
    }
    final now = DateTime.now();
    return UserPersona(
      id: decoded['id']?.toString() ?? '',
      displayName: decoded['display_name']?.toString() ?? '',
      pronouns: decoded['pronouns']?.toString() ?? '',
      bio: decoded['bio']?.toString() ?? '',
      promptContent: decoded['prompt_content']?.toString() ?? '',
      avatarPath: avatarPath,
      createdAt: now,
      updatedAt: now,
    );
  }
}

@immutable
class UserPersonaModeOverride {
  final String personaId;
  final ContextMode contextMode;
  final String? displayName;
  final String? pronouns;
  final String? bio;
  final String? promptContent;

  const UserPersonaModeOverride({
    required this.personaId,
    required this.contextMode,
    this.displayName,
    this.pronouns,
    this.bio,
    this.promptContent,
  });

  factory UserPersonaModeOverride.fromMap(Map<String, Object?> map) =>
      UserPersonaModeOverride(
        personaId: map['user_persona_id']?.toString() ?? '',
        contextMode: ContextMode.fromStorage(map['context_mode']),
        displayName: map['display_name']?.toString(),
        pronouns: map['pronouns']?.toString(),
        bio: map['bio']?.toString(),
        promptContent: map['prompt_content']?.toString(),
      );
}

@immutable
class ResolvedUserPersona {
  final UserPersona persona;
  final String promptSnapshot;

  const ResolvedUserPersona({
    required this.persona,
    required this.promptSnapshot,
  });
}

@immutable
class UserPersonaBinding {
  final String characterId;
  final ContextMode contextMode;
  final String continuityId;
  final String personaId;

  const UserPersonaBinding({
    required this.characterId,
    required this.contextMode,
    required this.continuityId,
    required this.personaId,
  });

  factory UserPersonaBinding.fromMap(Map<String, Object?> map) =>
      UserPersonaBinding(
        characterId: map['character_id']?.toString() ?? '',
        contextMode: ContextMode.fromStorage(map['context_mode']),
        continuityId: map['continuity_id']?.toString() ?? 'main',
        personaId: map['user_persona_id']?.toString() ?? '',
      );
}

/// Storage and binding boundary for user personas.
///
/// Binding changes affect only future windows. Every window pins a prompt
/// snapshot, while its persona id remains part of the existing cache identity.
class UserPersonaService {
  static const String defaultPersonaId = 'default';
  static const String _selectedPersonaKey = 'selected_user_persona_id_v1';
  static const String _starredPersonaKey = 'starred_user_persona_ids_v1';
  static const String _legacyProfileMigrationKey =
      'user_persona_profile_migrated_v1';

  static Future<UserPersona> ensureDefaultPersona() async {
    final db = await DatabaseHelper.database;
    var current = await getPersona(defaultPersonaId, includeArchived: true);
    final nickname = (await UserSettings.getUserName()).trim();
    final pronouns = (await UserSettings.getUserPronouns()).trim();
    final bio = (await UserSettings.getUserBio()).trim();
    final avatarPath = (await UserSettings.getUserAvatarPath()).trim();
    final now = DateTime.now();

    if (current == null) {
      current = UserPersona(
        id: defaultPersonaId,
        displayName: nickname,
        pronouns: pronouns,
        bio: bio,
        avatarPath: avatarPath,
        isDefault: true,
        createdAt: now,
        updatedAt: now,
      );
      await db.insert(
        'user_personas',
        current.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      current = (await getPersona(defaultPersonaId, includeArchived: true))!;
      await _migrateLegacyProfileGuides();
      return current;
    }

    final placeholderIsEmpty =
        current.displayName.isEmpty &&
        current.pronouns.isEmpty &&
        current.bio.isEmpty &&
        current.avatarPath.isEmpty &&
        current.promptContent.isEmpty;
    final legacyHasContent =
        nickname.isNotEmpty ||
        pronouns.isNotEmpty ||
        bio.isNotEmpty ||
        avatarPath.isNotEmpty;
    if (placeholderIsEmpty && legacyHasContent) {
      await db.update(
        'user_personas',
        <String, Object?>{
          'display_name': nickname,
          'pronouns': pronouns,
          'bio': bio,
          'avatar_path': avatarPath,
          'is_default': 1,
          'is_archived': 0,
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: const <Object?>[defaultPersonaId],
      );
      current = (await getPersona(defaultPersonaId, includeArchived: true))!;
    }
    await _migrateLegacyProfileGuides();
    return current;
  }

  static Future<void> _migrateLegacyProfileGuides() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_legacyProfileMigrationKey) == true) {
      final db = await DatabaseHelper.database;
      final existing = await db.query(
        'user_persona_mode_overrides',
        columns: const <String>['user_persona_id'],
        where: 'user_persona_id = ?',
        whereArgs: const <Object?>[defaultPersonaId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
    }
    final daily = (await ApiSettings.getSystemPromptFor(
      ContextMode.daily,
    )).trim();
    final rp = (await ApiSettings.getSystemPromptFor(ContextMode.rp)).trim();
    if (daily.isNotEmpty) {
      await _saveModeOverride(
        personaId: defaultPersonaId,
        contextMode: ContextMode.daily,
        promptContent: daily,
      );
    }
    if (rp.isNotEmpty) {
      await _saveModeOverride(
        personaId: defaultPersonaId,
        contextMode: ContextMode.rp,
        promptContent: rp,
      );
    }
    await prefs.setBool(_legacyProfileMigrationKey, true);
  }

  static Future<UserPersonaModeOverride?> modeOverride(
    String personaId,
    ContextMode contextMode,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'user_persona_mode_overrides',
      where: 'user_persona_id = ? AND context_mode = ?',
      whereArgs: <Object?>[personaId.trim(), contextMode.storageValue],
      limit: 1,
    );
    return rows.isEmpty ? null : UserPersonaModeOverride.fromMap(rows.first);
  }

  static Future<UserPersona?> personaForMode(
    String personaId,
    ContextMode contextMode, {
    bool includeArchived = false,
  }) async {
    final base = await getPersona(personaId, includeArchived: includeArchived);
    if (base == null) return null;
    final dailyOverride = await modeOverride(personaId, ContextMode.daily);
    final dailyPersona = base.copyWith(
      displayName: dailyOverride?.displayName,
      pronouns: dailyOverride?.pronouns,
      bio: dailyOverride?.bio,
      promptContent: dailyOverride?.promptContent,
    );
    if (contextMode == ContextMode.daily) return dailyPersona;

    // RP starts as a live inheritance of Daily. A field becomes independent
    // only after the user explicitly saves an RP override for that field.
    final rpOverride = await modeOverride(personaId, ContextMode.rp);
    return dailyPersona.copyWith(
      displayName: rpOverride?.displayName,
      pronouns: rpOverride?.pronouns,
      bio: rpOverride?.bio,
      promptContent: rpOverride?.promptContent,
    );
  }

  static Future<void> saveModeIdentity({
    required String personaId,
    required ContextMode contextMode,
    required String displayName,
    required String pronouns,
    required String bio,
    String? avatarPath,
  }) async {
    final base = await getPersona(personaId);
    if (base == null) throw StateError('Persona $personaId does not exist');
    final daily = await modeOverride(personaId, ContextMode.daily);
    final rp = await modeOverride(personaId, ContextMode.rp);
    final hasAnyIdentity =
        base.displayName.isNotEmpty ||
        base.pronouns.isNotEmpty ||
        base.bio.isNotEmpty ||
        daily?.displayName != null ||
        daily?.pronouns != null ||
        daily?.bio != null ||
        rp?.displayName != null ||
        rp?.pronouns != null ||
        rp?.bio != null;

    if (!hasAnyIdentity) {
      await updatePersona(
        base.copyWith(
          displayName: displayName.trim(),
          pronouns: pronouns.trim(),
          bio: bio.trim(),
          avatarPath: avatarPath?.trim() ?? base.avatarPath,
        ),
      );
      return;
    }

    if (avatarPath != null && avatarPath.trim() != base.avatarPath) {
      await updatePersona(base.copyWith(avatarPath: avatarPath.trim()));
    }
    final inherited = contextMode == ContextMode.rp
        ? await personaForMode(personaId, ContextMode.daily) ?? base
        : base;
    await _saveModeOverride(
      personaId: personaId,
      contextMode: contextMode,
      displayName: displayName.trim() == inherited.displayName
          ? null
          : displayName.trim(),
      pronouns: pronouns.trim() == inherited.pronouns ? null : pronouns.trim(),
      bio: bio.trim() == inherited.bio ? null : bio.trim(),
      replaceIdentity: true,
    );
  }

  static Future<String> profileGuide(
    String personaId,
    ContextMode contextMode,
  ) async {
    final persona = await personaForMode(personaId, contextMode);
    return persona?.promptContent ?? '';
  }

  static Future<void> saveProfileGuide(
    String personaId,
    ContextMode contextMode,
    String value,
  ) async {
    final cleaned = value.trim();
    String? storedValue = cleaned;
    if (contextMode == ContextMode.rp) {
      final daily = await profileGuide(personaId, ContextMode.daily);
      if (cleaned == daily) storedValue = null;
    }
    await _saveModeOverride(
      personaId: personaId,
      contextMode: contextMode,
      promptContent: storedValue,
      replacePromptContent: true,
    );
  }

  static Future<void> _saveModeOverride({
    required String personaId,
    required ContextMode contextMode,
    String? displayName,
    String? pronouns,
    String? bio,
    String? promptContent,
    bool replaceIdentity = false,
    bool replacePromptContent = false,
  }) async {
    final db = await DatabaseHelper.database;
    final existing = await modeOverride(personaId, contextMode);
    final now = DateTime.now().toIso8601String();
    await db.insert('user_persona_mode_overrides', <String, Object?>{
      'user_persona_id': personaId.trim(),
      'context_mode': contextMode.storageValue,
      'display_name': replaceIdentity
          ? displayName
          : displayName ?? existing?.displayName,
      'pronouns': replaceIdentity ? pronouns : pronouns ?? existing?.pronouns,
      'bio': replaceIdentity ? bio : bio ?? existing?.bio,
      'prompt_content': replacePromptContent
          ? promptContent
          : promptContent ?? existing?.promptContent,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<UserPersona?> getPersona(
    String personaId, {
    bool includeArchived = false,
  }) async {
    final id = personaId.trim();
    if (id.isEmpty) return null;
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'user_personas',
      where: includeArchived ? 'id = ?' : 'id = ? AND is_archived = 0',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : UserPersona.fromMap(rows.first);
  }

  static Future<List<UserPersona>> listPersonas({
    bool includeArchived = false,
  }) async {
    await ensureDefaultPersona();
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'user_personas',
      where: includeArchived ? null : 'is_archived = 0',
      orderBy: 'is_default DESC, updated_at DESC, id ASC',
    );
    return rows.map(UserPersona.fromMap).toList(growable: false);
  }

  static Future<UserPersona> selectedPersona() async {
    final fallback = await ensureDefaultPersona();
    final prefs = await SharedPreferences.getInstance();
    final selectedId = prefs.getString(_selectedPersonaKey)?.trim() ?? '';
    if (selectedId.isNotEmpty) {
      final selected = await getPersona(selectedId);
      if (selected != null) return selected;
    }
    if (!fallback.isArchived) return fallback;
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'user_personas',
      where: 'is_archived = 0',
      orderBy: 'updated_at DESC, id ASC',
      limit: 1,
    );
    if (rows.isEmpty) {
      await restorePersona(defaultPersonaId);
      return (await getPersona(defaultPersonaId))!;
    }
    final active = UserPersona.fromMap(rows.first);
    await prefs.setString(_selectedPersonaKey, active.id);
    return active;
  }

  static Future<void> selectPersona(String personaId) async {
    final persona = await getPersona(personaId);
    if (persona == null) {
      throw StateError('Persona $personaId does not exist or is archived');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedPersonaKey, persona.id);
  }

  static Future<Set<String>> getStarredPersonaIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_starredPersonaKey) ?? const <String>[])
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  static Future<void> setPersonaStarred(String personaId, bool starred) async {
    final id = personaId.trim();
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final ids = await getStarredPersonaIds();
    if (starred) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    await prefs.setStringList(_starredPersonaKey, ids.toList()..sort());
  }

  static Future<UserPersona> createPersona({
    String? id,
    String displayName = '',
    String pronouns = '',
    String bio = '',
    String avatarPath = '',
    String promptContent = '',
  }) async {
    final personaId = (id ?? const Uuid().v4()).trim();
    if (personaId.isEmpty || personaId == defaultPersonaId) {
      throw ArgumentError.value(id, 'id', 'invalid persona id');
    }
    final now = DateTime.now();
    final persona = UserPersona(
      id: personaId,
      displayName: displayName.trim(),
      pronouns: pronouns.trim(),
      bio: bio.trim(),
      avatarPath: avatarPath.trim(),
      promptContent: promptContent.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final db = await DatabaseHelper.database;
    await db.insert('user_personas', persona.toMap());
    return persona;
  }

  static Future<bool> updatePersona(UserPersona persona) async {
    final id = persona.id.trim();
    if (id.isEmpty) return false;
    final db = await DatabaseHelper.database;
    final changed = await db.update(
      'user_personas',
      <String, Object?>{
        'display_name': persona.displayName.trim(),
        'pronouns': persona.pronouns.trim(),
        'bio': persona.bio.trim(),
        'avatar_path': persona.avatarPath.trim(),
        'prompt_content': persona.promptContent.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (changed == 1 && id == defaultPersonaId) {
      await UserSettings.saveUserName(persona.displayName.trim());
      await UserSettings.saveUserPronouns(persona.pronouns.trim());
      await UserSettings.saveUserBio(persona.bio.trim());
      await UserSettings.saveUserAvatarPath(persona.avatarPath.trim());
    }
    return changed == 1;
  }

  /// Soft-archives a persona and removes only future-window bindings. Existing
  /// windows retain their id and immutable prompt snapshot.
  static Future<bool> archivePersona(String personaId) async {
    final id = personaId.trim();
    if (id.isEmpty) return false;
    final db = await DatabaseHelper.database;
    String? fallbackId;
    final archived = await db.transaction<bool>((txn) async {
      final alternatives = await txn.query(
        'user_personas',
        columns: const <String>['id'],
        where: 'id != ? AND is_archived = 0',
        whereArgs: <Object?>[id],
        orderBy: 'is_default DESC, updated_at DESC, id ASC',
        limit: 1,
      );
      if (alternatives.isEmpty) return false;
      fallbackId = alternatives.first['id']?.toString();
      final changed = await txn.update(
        'user_personas',
        <String, Object?>{
          'is_archived': 1,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND is_archived = 0',
        whereArgs: <Object?>[id],
      );
      if (changed != 1) return false;
      await txn.delete(
        'character_persona_bindings',
        where: 'user_persona_id = ?',
        whereArgs: <Object?>[id],
      );
      return true;
    });
    if (archived) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_selectedPersonaKey) == id) {
        await prefs.setString(_selectedPersonaKey, fallbackId!);
      }
    }
    return archived;
  }

  static Future<bool> restorePersona(String personaId) async {
    final db = await DatabaseHelper.database;
    return await db.update(
          'user_personas',
          <String, Object?>{
            'is_archived': 0,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[personaId.trim()],
        ) ==
        1;
  }

  /// Binds one character to one persona globally. [contextMode] and
  /// [continuityId] remain in the API so older callers and backups stay
  /// compatible; only the persona file itself is mode-specific.
  static Future<void> bindPersona({
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
    required String personaId,
  }) async {
    final charId = characterId.trim();
    final userPersonaId = personaId.trim();
    if (charId.isEmpty || userPersonaId.isEmpty) {
      throw ArgumentError('characterId and personaId are required');
    }
    final db = await DatabaseHelper.database;
    final character = await db.query(
      'characters',
      columns: const <String>['id'],
      where: 'id = ?',
      whereArgs: <Object?>[charId],
      limit: 1,
    );
    final persona = await getPersona(userPersonaId);
    if (character.isEmpty) throw StateError('Character $charId does not exist');
    if (persona == null) {
      throw StateError('Persona $userPersonaId does not exist or is archived');
    }
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.delete(
        'character_persona_bindings',
        where: 'character_id = ?',
        whereArgs: <Object?>[charId],
      );
      await txn.insert('character_persona_bindings', <String, Object?>{
        'character_id': charId,
        // Retained as compatibility placeholders for existing backups.
        'context_mode': ContextMode.daily.storageValue,
        'continuity_id': 'main',
        'user_persona_id': userPersonaId,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  /// Current UI policy: one shared companion per persona. Daily and RP keep
  /// separate persona text, but never separate companion relationships.
  static Future<void> bindSingleCompanion({
    required String personaId,
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    await bindPersona(
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
      personaId: personaId,
    );
    final db = await DatabaseHelper.database;
    await db.delete(
      'character_persona_bindings',
      where: 'user_persona_id = ? AND character_id <> ?',
      whereArgs: <Object?>[personaId.trim(), characterId.trim()],
    );
  }

  static Future<void> unbindCompanionForPersona({
    required String personaId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'character_persona_bindings',
      where: 'user_persona_id = ?',
      whereArgs: <Object?>[personaId.trim()],
    );
  }

  static Future<String?> companionIdForPersona({
    required String personaId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    final rows = await bindingsForPersona(
      personaId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    return rows.isEmpty ? null : rows.first.characterId;
  }

  static Future<void> unbindPersona({
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'character_persona_bindings',
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId.trim()],
    );
  }

  static Future<String?> boundPersonaId({
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT b.user_persona_id
      FROM character_persona_bindings b
      INNER JOIN user_personas p ON p.id = b.user_persona_id
      WHERE b.character_id = ?
        AND p.is_archived = 0
      ORDER BY b.updated_at DESC, b.rowid DESC
      LIMIT 1
      ''',
      <Object?>[characterId.trim()],
    );
    return rows.isEmpty ? null : rows.first['user_persona_id']?.toString();
  }

  static Future<List<UserPersonaBinding>> bindingsForPersona(
    String personaId, {
    ContextMode? contextMode,
    String continuityId = 'main',
  }) async {
    final db = await DatabaseHelper.database;
    final conditions = <String>['user_persona_id = ?'];
    final args = <Object?>[personaId.trim()];
    final rows = await db.query(
      'character_persona_bindings',
      where: conditions.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at DESC, rowid DESC',
      limit: 1,
    );
    return rows.map(UserPersonaBinding.fromMap).toList(growable: false);
  }

  static Future<ResolvedUserPersona> resolveForNewWindow({
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    final fallback = await selectedPersona();
    final boundId = await boundPersonaId(
      characterId: characterId,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    final base = boundId == null
        ? fallback
        : await getPersona(boundId) ?? fallback;
    final persona = await personaForMode(base.id, contextMode) ?? fallback;
    return ResolvedUserPersona(
      persona: persona,
      promptSnapshot: persona.toPromptSnapshot(),
    );
  }

  /// Pins a legacy/malformed window exactly once. It intentionally uses the
  /// default persona, never today's binding, so opening an old window cannot
  /// silently rewrite who the user was in that history.
  static Future<Conversation> ensureConversationPersona(
    Conversation conversation,
  ) async {
    final existingId = (conversation.userPersonaId ?? '').trim();
    final existingSnapshot = conversation.userPersonaSnapshot.trim();
    if (existingId.isNotEmpty && existingSnapshot.isNotEmpty) {
      return conversation;
    }

    final fallback = await ensureDefaultPersona();
    String snapshotId = '';
    if (existingId.isEmpty && existingSnapshot.isNotEmpty) {
      try {
        snapshotId = UserPersona.fromPromptSnapshot(existingSnapshot).id.trim();
      } on FormatException {
        snapshotId = '';
      } on TypeError {
        snapshotId = '';
      }
    }
    final requestedId = existingId.isNotEmpty ? existingId : snapshotId;
    final persona = requestedId.isEmpty
        ? fallback
        : await getPersona(requestedId, includeArchived: true) ?? fallback;
    final snapshot = existingSnapshot.isNotEmpty && snapshotId == persona.id
        ? existingSnapshot
        : persona.toPromptSnapshot();
    final db = await DatabaseHelper.database;
    await db.rawUpdate(
      '''
      UPDATE conversations
      SET user_persona_id = CASE
            WHEN user_persona_id IS NULL OR trim(user_persona_id) = ''
              THEN ?
            ELSE user_persona_id
          END,
          user_persona_snapshot = CASE
            WHEN user_persona_snapshot IS NULL OR trim(user_persona_snapshot) = ''
              THEN ?
            ELSE user_persona_snapshot
          END
      WHERE id = ?
        AND (
          user_persona_id IS NULL OR trim(user_persona_id) = '' OR
          user_persona_snapshot IS NULL OR trim(user_persona_snapshot) = ''
        )
      ''',
      <Object?>[persona.id, snapshot, conversation.id],
    );
    return (await DatabaseHelper.getConversation(conversation.id)) ??
        conversation;
  }

  static Future<UserPersona> personaForConversation(
    Conversation conversation,
  ) async {
    final prepared = await ensureConversationPersona(conversation);
    final personaId = (prepared.userPersonaId ?? defaultPersonaId).trim();
    final stored = await getPersona(personaId, includeArchived: true);
    try {
      final decoded = jsonDecode(prepared.userPersonaSnapshot);
      final version = decoded is Map ? decoded['version'] as int? ?? 1 : 1;
      if (version < 2) {
        final modePersona =
            await personaForMode(
              personaId,
              prepared.contextMode,
              includeArchived: true,
            ) ??
            stored ??
            await ensureDefaultPersona();
        final legacySnapshot = UserPersona.fromPromptSnapshot(
          prepared.userPersonaSnapshot,
          avatarPath: stored?.avatarPath ?? '',
        );
        final upgraded = legacySnapshot.copyWith(
          promptContent: legacySnapshot.promptContent.isEmpty
              ? modePersona.promptContent
              : legacySnapshot.promptContent,
        );
        final nextSnapshot = upgraded.toPromptSnapshot();
        final db = await DatabaseHelper.database;
        await db.update(
          'conversations',
          <String, Object?>{'user_persona_snapshot': nextSnapshot},
          where: 'id = ? AND user_persona_snapshot = ?',
          whereArgs: <Object?>[prepared.id, prepared.userPersonaSnapshot],
        );
        return upgraded;
      }
      final snapshot = UserPersona.fromPromptSnapshot(
        prepared.userPersonaSnapshot,
        avatarPath: stored?.avatarPath ?? '',
      );
      if (snapshot.id == personaId) return snapshot;
    } on FormatException {
      // Fall through to the durable row/default rather than injecting a
      // mismatched or malformed snapshot.
    } on TypeError {
      // Same fail-closed behavior for malformed decoded field types.
    }
    return stored ?? ensureDefaultPersona();
  }

  static String buildPrompt(UserPersona persona) {
    final parts = <String>[];
    if (L.locale == 'en') {
      if (persona.displayName.isNotEmpty) {
        parts.add('Name: ${persona.displayName}');
      }
      if (persona.pronouns.isNotEmpty) {
        parts.add('Pronouns: ${persona.pronouns}');
      }
      if (persona.bio.isNotEmpty) {
        parts.add('About: ${persona.bio}');
      }
      if (persona.promptContent.isNotEmpty) {
        parts.add('Persona: ${persona.promptContent}');
      }
      return parts.isEmpty ? '' : '【User Persona】${parts.join(', ')}';
    }

    if (persona.displayName.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: '暱稱：', zhCN: '昵称：')}${persona.displayName}',
      );
    }
    if (persona.pronouns.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: '稱謂：', zhCN: '称谓：')}${persona.pronouns}',
      );
    }
    if (persona.bio.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: '自我介紹：', zhCN: '自我介绍：')}${persona.bio}',
      );
    }
    if (persona.promptContent.isNotEmpty) {
      parts.add(
        '${L.pick(en: '', zhTW: '角色身分：', zhCN: '角色身份：')}${persona.promptContent}',
      );
    }
    return parts.isEmpty
        ? ''
        : '${L.pick(en: '', zhTW: '【用戶角色】', zhCN: '【用户角色】')}'
              '${parts.join(L.pick(en: '', zhTW: '，', zhCN: '，'))}';
  }

  /// Identity fields occupy the existing profile cache part. The separate
  /// communication guide remains in the existing system-prompt part.
  static String buildIdentityPrompt(UserPersona persona) {
    return buildPrompt(persona.copyWith(promptContent: ''));
  }
}
