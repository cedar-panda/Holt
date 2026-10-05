import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import 'settings/user_settings.dart';

/// Repairs app-owned avatar paths after iOS assigns a new data-container UUID.
///
/// Avatar files live under Documents, but older rows stored the complete iOS
/// container path. App updates can preserve the files while making that path
/// stale. Only known Holt media folders are rebased, and a stored value is
/// changed only when the corresponding file exists in the current container.
class AvatarImagePathService {
  AvatarImagePathService._();

  static const Set<String> _managedFolders = <String>{
    'avatars',
    'HoltImportedMedia',
  };

  static Future<int> repairStoredPaths() async {
    final documents = await getApplicationDocumentsDirectory();
    final db = await DatabaseHelper.database;
    var repaired = await repairDatabasePaths(db, documents.path);

    final userAvatar = await UserSettings.getUserAvatarPath();
    final resolvedUserAvatar = resolveInDocuments(userAvatar, documents.path);
    if (resolvedUserAvatar != userAvatar) {
      await UserSettings.saveUserAvatarPath(resolvedUserAvatar);
      repaired++;
    }

    final legacyCharacterAvatar = await UserSettings.getAvatarPath();
    final resolvedCharacterAvatar = resolveInDocuments(
      legacyCharacterAvatar,
      documents.path,
    );
    if (resolvedCharacterAvatar != legacyCharacterAvatar) {
      await UserSettings.saveAvatarPath(resolvedCharacterAvatar);
      repaired++;
    }

    return repaired;
  }

  static Future<int> repairDatabasePaths(
    Database db,
    String documentsPath,
  ) async {
    final characterRows = await db.query(
      'characters',
      columns: const <String>['id', 'avatar_path'],
    );
    final personaRows = await db.query(
      'user_personas',
      columns: const <String>['id', 'avatar_path'],
    );
    final updates = <({String table, String id, String path})>[];

    void collect(String table, List<Map<String, Object?>> rows) {
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final stored = row['avatar_path']?.toString() ?? '';
        final resolved = resolveInDocuments(stored, documentsPath);
        if (id.isNotEmpty && resolved != stored) {
          updates.add((table: table, id: id, path: resolved));
        }
      }
    }

    collect('characters', characterRows);
    collect('user_personas', personaRows);
    if (updates.isEmpty) return 0;

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final update in updates) {
        batch.update(
          update.table,
          <String, Object?>{'avatar_path': update.path},
          where: 'id = ?',
          whereArgs: <Object?>[update.id],
        );
      }
      await batch.commit(noResult: true);
    });
    return updates.length;
  }

  /// Returns [stored] untouched when it is external, unsafe, or missing.
  static String resolveInDocuments(String stored, String documentsPath) {
    final original = stored.trim();
    if (original.isEmpty || File(original).existsSync()) return stored;

    final normalized = p.normalize(original);
    String relative;
    if (p.isAbsolute(normalized)) {
      final slashPath = normalized.replaceAll('\\', '/');
      const marker = '/Documents/';
      final markerIndex = slashPath.lastIndexOf(marker);
      if (markerIndex < 0) return stored;
      relative = slashPath.substring(markerIndex + marker.length);
    } else {
      relative = normalized;
    }

    final relativeSegments = p
        .split(p.normalize(relative))
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
    if (relativeSegments.isEmpty ||
        relativeSegments.any((segment) => segment == '..') ||
        !_managedFolders.contains(relativeSegments.first)) {
      return stored;
    }

    final candidate = p.normalize(
      p.joinAll(<String>[documentsPath, ...relativeSegments]),
    );
    final documentsRoot = p.normalize(documentsPath);
    if (!p.isWithin(documentsRoot, candidate) ||
        !File(candidate).existsSync()) {
      return stored;
    }
    return candidate;
  }
}
