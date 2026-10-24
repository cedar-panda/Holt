import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class ExtractedPortableBackup {
  final Map<String, dynamic> data;
  final Directory mediaDirectory;

  const ExtractedPortableBackup({
    required this.data,
    required this.mediaDirectory,
  });

  Future<void> discard() async {
    if (await mediaDirectory.exists()) {
      await mediaDirectory.delete(recursive: true);
    }
  }
}

class _StagedPortableMedia {
  const _StagedPortableMedia({
    required this.files,
    required this.referenceCounts,
    required this.totalBytes,
  });

  final List<Map<String, Object?>> files;
  final Map<String, int> referenceCounts;
  final int totalBytes;
}

/// Creates and validates the portable `.holt.zip` backup container.
///
/// Database JSON never carries an absolute device path inside the archive.
/// Every referenced media file is rewritten to `media/<sha256>.<ext>` and is
/// verified again before an import path is restored under app documents.
class PortableBackupBundle {
  static const int formatVersion = 2;
  static const String manifestEntry = 'manifest.json';
  static const String dataEntry = 'backup.json';
  static const int _maxMetadataBytes = 64 * 1024 * 1024;
  static const int _maxMediaFileBytes = 1024 * 1024 * 1024;
  static const int _maxTotalMediaBytes = 4 * 1024 * 1024 * 1024;

  static const Map<String, String> _tablePathColumns = {
    'characters': 'avatar_path',
    'user_personas': 'avatar_path',
    'messages': 'image_path',
    'shop_items': 'image_path',
    'stickers': 'file_path',
    'saved_voices': 'file_path',
  };

  static const Set<String> _emptyStringPathTables = {'shop_items', 'stickers'};

  static final RegExp _legacyIosDocumentsPath = RegExp(
    r'^/(?:private/)?var/mobile/Containers/Data/Application/'
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/Documents/(.+)$',
  );
  static final RegExp _backgroundPresetPreferenceKey = RegExp(
    r'^background_preset_slot_\d+_v1$',
  );
  static const Set<String> _backgroundPresetPathFields = <String>{
    'home_path',
    'chat_path',
  };

  static Future<File> create({
    required Map<String, Object?> backupData,
    required File databaseSnapshot,
    required Directory ownedRoot,
    required Directory workingRoot,
    required File outputFile,
  }) async {
    final stage = Directory(
      p.join(
        workingRoot.path,
        'holt_bundle_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    if (await stage.exists()) await stage.delete(recursive: true);
    await Directory(p.join(stage.path, 'media')).create(recursive: true);

    try {
      final portableData = _deepCopy(backupData);
      final stagedMedia = await _stageReferencedMedia(
        portableData,
        ownedRoot: ownedRoot,
        stage: stage,
      );
      if (!await databaseSnapshot.exists()) {
        throw StateError('資料庫快照不存在');
      }
      final stagedDatabase = File(p.join(stage.path, 'database', 'yanci.db'));
      await stagedDatabase.parent.create(recursive: true);
      await databaseSnapshot.copy(stagedDatabase.path);
      final databaseSize = await stagedDatabase.length();
      if (databaseSize > _maxMediaFileBytes) {
        throw StateError('資料庫快照超過備份上限');
      }
      final databaseHash = (await sha256.bind(stagedDatabase.openRead()).first)
          .toString();
      await File(p.join(stage.path, dataEntry)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(portableData),
        flush: true,
      );
      await File(p.join(stage.path, manifestEntry)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'type': 'holt_portable_backup',
          'version': formatVersion,
          'created_at': DateTime.now().toIso8601String(),
          'data': dataEntry,
          'database': <String, Object?>{
            'path': 'database/yanci.db',
            'sha256': databaseHash,
            'size': databaseSize,
          },
          'files': stagedMedia.files,
          'media_inventory': <String, Object?>{
            'references': stagedMedia.referenceCounts,
            'unique_files': stagedMedia.files.length,
            'total_bytes': stagedMedia.totalBytes,
          },
        }),
        flush: true,
      );

      await outputFile.parent.create(recursive: true);
      if (await outputFile.exists()) await outputFile.delete();
      try {
        await ZipFileEncoder().zipDirectory(
          stage,
          filename: outputFile.path,
          level: ZipFileEncoder.gzip,
          // archive 4.0.9 writes deflated zero-byte directory placeholders
          // that its own decoder accepts but Info-ZIP reports as invalid.
          // The paths are implicit in the real file entries, so omitting the
          // placeholders keeps Holt bundles compatible with standard ZIP tools.
          filter: (entity, _) => entity is Directory
              ? ZipFileOperation.skip
              : ZipFileOperation.include,
        );
      } catch (_) {
        if (await outputFile.exists()) await outputFile.delete();
        rethrow;
      }
      return outputFile;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static Future<ExtractedPortableBackup> extract({
    required File bundle,
    required Directory destinationRoot,
  }) async {
    if (!await bundle.exists()) throw const FormatException('備份壓縮包不存在');
    await destinationRoot.create(recursive: true);
    final mediaDirectory = Directory(
      p.join(
        destinationRoot.path,
        'HoltImportedMedia',
        DateTime.now().microsecondsSinceEpoch.toString(),
      ),
    );
    await mediaDirectory.create(recursive: true);

    final input = InputFileStream(bundle.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final entries = <String, ArchiveFile>{};
      for (final entry in archive) {
        final name = entry.name;
        if (!_isSafeEntryName(name) || entry.isSymbolicLink) {
          throw FormatException('備份包含不安全路徑：$name');
        }
        if (entries.containsKey(name)) {
          throw FormatException('備份包含重複檔案：$name');
        }
        entries[name] = entry;
      }

      final manifestFile = entries[manifestEntry];
      final backupFile = entries[dataEntry];
      if (manifestFile == null || backupFile == null) {
        throw const FormatException('備份缺少 manifest.json 或 backup.json');
      }
      final manifest = _decodeJsonEntry(manifestFile, field: manifestEntry);
      final data = _decodeJsonEntry(backupFile, field: dataEntry);
      final bundleVersion = manifest['version'];
      if (manifest['type'] != 'holt_portable_backup' ||
          (bundleVersion != 1 && bundleVersion != formatVersion) ||
          manifest['data'] != dataEntry) {
        throw const FormatException('不支援的 Holt 媒體備份格式');
      }

      final rawFiles = manifest['files'];
      if (rawFiles is! List) {
        throw const FormatException('manifest.files 必須是陣列');
      }
      final resolvedPaths = <String, String>{};
      var totalBytes = 0;
      for (final raw in rawFiles) {
        if (raw is! Map) throw const FormatException('manifest.files 項目格式無效');
        final path = raw['path']?.toString() ?? '';
        final expectedHash = raw['sha256']?.toString().toLowerCase() ?? '';
        final expectedSize = raw['size'];
        if (!_isSafeMediaPath(path) ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash) ||
            expectedSize is! int ||
            expectedSize < 0 ||
            expectedSize > _maxMediaFileBytes ||
            resolvedPaths.containsKey(path)) {
          throw FormatException('媒體 manifest 項目無效：$path');
        }
        totalBytes += expectedSize;
        if (totalBytes > _maxTotalMediaBytes) {
          throw const FormatException('備份媒體總大小超過安全上限');
        }
        final entry = entries[path];
        if (entry == null || !entry.isFile || entry.size != expectedSize) {
          throw FormatException('備份媒體缺失或大小不符：$path');
        }

        final fileName = p.posix.basename(path);
        final target = File(p.join(mediaDirectory.path, fileName));
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        if (await target.length() != expectedSize) {
          throw FormatException('備份媒體解壓後大小不符：$path');
        }
        final actualHash = (await sha256.bind(target.openRead()).first)
            .toString();
        if (actualHash != expectedHash) {
          throw FormatException('備份媒體雜湊不符：$path');
        }
        resolvedPaths[path] = target.path;
      }

      if (bundleVersion == formatVersion) {
        final rawInventory = manifest['media_inventory'];
        if (rawInventory is! Map) {
          throw const FormatException('manifest.media_inventory 格式無效');
        }
        final expectedReferences = rawInventory['references'];
        final expectedUniqueFiles = rawInventory['unique_files'];
        final expectedTotalBytes = rawInventory['total_bytes'];
        final normalizedExpectedReferences = expectedReferences is Map
            ? <String, int>{
                for (final entry in expectedReferences.entries)
                  if (entry.value is num)
                    entry.key.toString(): (entry.value as num).toInt(),
              }
            : const <String, int>{};
        if (expectedUniqueFiles != rawFiles.length ||
            expectedTotalBytes != totalBytes ||
            !_sameCounts(
              normalizedExpectedReferences,
              _countPortableReferences(data),
            )) {
          throw const FormatException('備份媒體清單與資料引用不一致');
        }
      }

      final databaseManifest = manifest['database'];
      if (databaseManifest is! Map) {
        throw const FormatException('manifest.database 格式無效');
      }
      const databasePath = 'database/yanci.db';
      final databaseHash =
          databaseManifest['sha256']?.toString().toLowerCase() ?? '';
      final databaseSize = databaseManifest['size'];
      final databaseEntry = entries[databasePath];
      if (databaseManifest['path'] != databasePath ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(databaseHash) ||
          databaseSize is! int ||
          databaseSize < 0 ||
          databaseSize > _maxMediaFileBytes ||
          databaseEntry == null ||
          !databaseEntry.isFile ||
          databaseEntry.size != databaseSize) {
        throw const FormatException('資料庫快照 manifest 無效');
      }
      final databaseCheck = File(
        p.join(mediaDirectory.path, '.database_check'),
      );
      final databaseOutput = OutputFileStream(databaseCheck.path);
      try {
        databaseEntry.writeContent(databaseOutput);
      } finally {
        await databaseOutput.close();
      }
      final databaseActualHash =
          (await sha256.bind(databaseCheck.openRead()).first).toString();
      final databaseActualSize = await databaseCheck.length();
      await databaseCheck.delete();
      if (databaseActualHash != databaseHash ||
          databaseActualSize != databaseSize) {
        throw const FormatException('資料庫快照驗證失敗');
      }

      final allowedEntries = <String>{
        manifestEntry,
        dataEntry,
        databasePath,
        ...resolvedPaths.keys,
      };
      final unexpected = entries.values.where(
        (entry) => entry.isFile && !allowedEntries.contains(entry.name),
      );
      if (unexpected.isNotEmpty) {
        throw FormatException('備份包含未列入 manifest 的檔案：${unexpected.first.name}');
      }

      _rewritePathsForImport(data, resolvedPaths);
      return ExtractedPortableBackup(
        data: data,
        mediaDirectory: mediaDirectory,
      );
    } catch (_) {
      if (await mediaDirectory.exists()) {
        await mediaDirectory.delete(recursive: true);
      }
      rethrow;
    } finally {
      await input.close();
    }
  }

  static Future<_StagedPortableMedia> _stageReferencedMedia(
    Map<String, dynamic> data, {
    required Directory ownedRoot,
    required Directory stage,
  }) async {
    final sourceToPortable = <String, String>{};
    final digestToPortable = <String, String>{};
    final manifest = <Map<String, Object?>>[];
    final resolvedOwnedRoot = await ownedRoot.resolveSymbolicLinks();
    var sequence = 0;
    var totalSize = 0;

    Future<String?> stagePath(
      Object? rawPath, {
      required String owner,
      required bool requiredForBackup,
    }) async {
      if (rawPath is! String || rawPath.trim().isEmpty) return null;
      final normalized = p.normalize(rawPath);
      final safeRoot = p.normalize(ownedRoot.path);
      String? ownedPath;
      if (p.isAbsolute(normalized) &&
          (p.equals(normalized, safeRoot) ||
              p.isWithin(safeRoot, normalized))) {
        ownedPath = normalized;
      } else if (!p.isAbsolute(normalized) && normalized != '.') {
        // App-owned backgrounds are intentionally persisted relative to
        // Documents so an iOS container UUID change does not break them.
        // Resolve only a traversal-safe relative path under the current root.
        final rebased = p.normalize(p.join(safeRoot, normalized));
        if (p.isWithin(safeRoot, rebased)) ownedPath = rebased;
      } else {
        // An in-place iOS upgrade changes the app-container UUID. Older rows
        // can therefore retain a now-stale absolute Documents path even though
        // the same app-owned file survived under the current Documents root.
        // Rebase only that exact container shape; never read from the stale or
        // any other external absolute path.
        final legacyMatch = _legacyIosDocumentsPath.firstMatch(normalized);
        if (legacyMatch != null) {
          final relativePath = p.normalize(legacyMatch.group(1)!);
          final rebased = p.normalize(p.join(safeRoot, relativePath));
          if (relativePath != '.' &&
              !p.isAbsolute(relativePath) &&
              p.isWithin(safeRoot, rebased)) {
            ownedPath = rebased;
          }
        }
      }
      if (ownedPath == null) {
        if (requiredForBackup) {
          throw StateError('備份媒體不在 App 儲存範圍：$owner');
        }
        return null;
      }
      final source = File(ownedPath);
      if (!await source.exists()) {
        if (requiredForBackup) throw StateError('備份媒體遺失：$owner');
        return null;
      }
      final resolvedSource = await source.resolveSymbolicLinks();
      if (!p.equals(resolvedSource, resolvedOwnedRoot) &&
          !p.isWithin(resolvedOwnedRoot, resolvedSource)) {
        if (requiredForBackup) {
          throw StateError('備份媒體指向 App 儲存範圍外：$owner');
        }
        return null;
      }
      final existing = sourceToPortable[resolvedSource];
      if (existing != null) return existing;

      final temporary = File(
        p.join(stage.path, 'media', '.copy_${sequence++}'),
      );
      await File(resolvedSource).copy(temporary.path);
      final size = await temporary.length();
      if (size > _maxMediaFileBytes) {
        await temporary.delete();
        throw StateError('媒體檔案超過備份上限：${p.basename(ownedPath)}');
      }
      final digest = (await sha256.bind(temporary.openRead()).first).toString();
      final duplicate = digestToPortable[digest];
      if (duplicate != null) {
        await temporary.delete();
        sourceToPortable[resolvedSource] = duplicate;
        return duplicate;
      }
      totalSize += size;
      if (totalSize > _maxTotalMediaBytes) {
        await temporary.delete();
        throw StateError('備份媒體總大小超過安全上限');
      }

      final extension = _safeExtension(ownedPath);
      final portablePath = 'media/$digest$extension';
      final staged = File(p.join(stage.path, portablePath));
      await temporary.rename(staged.path);
      digestToPortable[digest] = portablePath;
      sourceToPortable[resolvedSource] = portablePath;
      manifest.add(<String, Object?>{
        'path': portablePath,
        'sha256': digest,
        'size': size,
      });
      return portablePath;
    }

    Future<void> stageMessageImages(Map rawRow, {required String owner}) async {
      final sourcePaths = _decodeImagePaths(rawRow['image_paths_json']);
      final portablePaths = <String>[];
      for (final sourcePath in sourcePaths) {
        final portable = await stagePath(
          sourcePath,
          owner: '$owner.image_paths_json',
          requiredForBackup: true,
        );
        if (portable != null && !portablePaths.contains(portable)) {
          portablePaths.add(portable);
        }
      }
      if (portablePaths.isEmpty) {
        final legacyPortable = await stagePath(
          rawRow['image_path'],
          owner: '$owner.image_path',
          requiredForBackup: true,
        );
        if (legacyPortable != null) portablePaths.add(legacyPortable);
      }
      rawRow['image_paths_json'] = jsonEncode(portablePaths);
      rawRow['image_path'] = portablePaths.isEmpty ? null : portablePaths.first;
    }

    final revisions = data['message_revisions'];
    if (revisions is List) {
      for (final revision in revisions.whereType<Map>()) {
        final snapshot = jsonDecode(revision['snapshot_json'] as String);
        if (snapshot is! Map) throw const FormatException('訊息版本格式無效');
        await stageMessageImages(snapshot, owner: 'message_revisions.snapshot');
        final prompt = snapshot['reply_user_snapshot'];
        if (prompt is Map) {
          await stageMessageImages(
            prompt,
            owner: 'message_revisions.reply_user_snapshot',
          );
        }
        revision['snapshot_json'] = jsonEncode(snapshot);
      }
    }
    for (final entry in _tablePathColumns.entries) {
      final rows = data[entry.key];
      if (rows is! List) continue;
      final validRows = <Object?>[];
      for (final rawRow in rows) {
        if (rawRow is! Map) {
          validRows.add(rawRow);
          continue;
        }
        if (entry.key == 'messages') {
          await stageMessageImages(rawRow, owner: 'messages');
          validRows.add(rawRow);
          continue;
        }
        final portable = await stagePath(
          rawRow[entry.value],
          owner: '${entry.key}.${entry.value}',
          requiredForBackup: entry.key != 'shop_items',
        );
        rawRow[entry.value] =
            portable ??
            (_emptyStringPathTables.contains(entry.key) ? '' : null);
        validRows.add(rawRow);
      }
      data[entry.key] = validRows;
    }
    final preferences = data['preferences'];
    if (preferences is Map) {
      for (final key in preferences.keys.toList()) {
        final keyText = key.toString();
        if (keyText.toLowerCase().contains('path')) {
          preferences[key] =
              await stagePath(
                preferences[key],
                owner: 'preferences.$keyText',
                requiredForBackup: true,
              ) ??
              '';
          continue;
        }
        if (!_backgroundPresetPreferenceKey.hasMatch(keyText)) continue;
        final preset = _decodeBackgroundPresetPreference(preferences[key]);
        if (preset == null) continue;
        for (final field in _backgroundPresetPathFields) {
          preset[field] =
              await stagePath(
                preset[field],
                owner: 'preferences.$keyText.$field',
                requiredForBackup: true,
              ) ??
              '';
        }
        preferences[key] = jsonEncode(preset);
      }
    }
    manifest.sort(
      (a, b) => a['path'].toString().compareTo(b['path'].toString()),
    );
    return _StagedPortableMedia(
      files: manifest,
      referenceCounts: _countPortableReferences(data),
      totalBytes: totalSize,
    );
  }

  static Map<String, int> _countPortableReferences(Map<String, dynamic> data) {
    final counts = <String, int>{};

    void count(String owner, Object? raw) {
      if (raw is String && _isSafeMediaPath(raw)) {
        counts[owner] = (counts[owner] ?? 0) + 1;
      }
    }

    void countMessage(Map row, String owner) {
      final paths = _decodeImagePaths(row['image_paths_json']);
      if (paths.isNotEmpty) {
        for (final path in paths) {
          count('$owner.image_paths_json', path);
        }
      } else {
        count('$owner.image_path', row['image_path']);
      }
    }

    final revisions = data['message_revisions'];
    if (revisions is List) {
      for (final revision in revisions.whereType<Map>()) {
        final raw = revision['snapshot_json'];
        if (raw is! String) continue;
        final snapshot = jsonDecode(raw);
        if (snapshot is! Map) continue;
        countMessage(snapshot, 'message_revisions.snapshot');
        final prompt = snapshot['reply_user_snapshot'];
        if (prompt is Map) {
          countMessage(prompt, 'message_revisions.reply_user_snapshot');
        }
      }
    }
    for (final entry in _tablePathColumns.entries) {
      final rows = data[entry.key];
      if (rows is! List) continue;
      for (final row in rows.whereType<Map>()) {
        if (entry.key == 'messages') {
          countMessage(row, 'messages');
        } else {
          count('${entry.key}.${entry.value}', row[entry.value]);
        }
      }
    }
    final preferences = data['preferences'];
    if (preferences is Map) {
      for (final entry in preferences.entries) {
        final key = entry.key.toString();
        if (key.toLowerCase().contains('path')) {
          count('preferences.$key', entry.value);
          continue;
        }
        if (!_backgroundPresetPreferenceKey.hasMatch(key)) continue;
        final preset = _decodeBackgroundPresetPreference(entry.value);
        if (preset == null) continue;
        for (final field in _backgroundPresetPathFields) {
          count('preferences.$key.$field', preset[field]);
        }
      }
    }
    return Map<String, int>.fromEntries(
      counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  static bool _sameCounts(Map<String, int> first, Map<String, int> second) {
    if (first.length != second.length) return false;
    for (final entry in first.entries) {
      if (second[entry.key] != entry.value) return false;
    }
    return true;
  }

  static void _rewritePathsForImport(
    Map<String, dynamic> data,
    Map<String, String> resolvedPaths,
  ) {
    final revisions = data['message_revisions'];
    if (revisions is List) {
      for (final revision in revisions.whereType<Map>()) {
        final snapshot = jsonDecode(revision['snapshot_json'] as String);
        if (snapshot is! Map) throw const FormatException('訊息版本格式無效');
        _rewritePathsForImport({
          'messages': [
            snapshot,
            if (snapshot['reply_user_snapshot'] is Map)
              snapshot['reply_user_snapshot'],
          ],
        }, resolvedPaths);
        revision['snapshot_json'] = jsonEncode(snapshot);
      }
    }
    String? resolve(Object? raw, {required bool emptyString}) {
      if (raw == null || raw.toString().isEmpty) return emptyString ? '' : null;
      final portable = raw.toString();
      final resolved = resolvedPaths[portable];
      if (resolved == null) throw FormatException('備份引用未驗證媒體：$portable');
      return resolved;
    }

    for (final entry in _tablePathColumns.entries) {
      final rows = data[entry.key];
      if (rows is! List) continue;
      for (final rawRow in rows) {
        if (rawRow is! Map) continue;
        if (entry.key == 'messages') {
          final portablePaths = _decodeImagePaths(rawRow['image_paths_json']);
          final resolvedPaths = <String>[];
          for (final portablePath in portablePaths) {
            final resolved = resolve(portablePath, emptyString: false);
            if (resolved != null) resolvedPaths.add(resolved);
          }
          if (resolvedPaths.isEmpty) {
            final legacyResolved = resolve(
              rawRow[entry.value],
              emptyString: false,
            );
            if (legacyResolved != null) resolvedPaths.add(legacyResolved);
          }
          rawRow['image_paths_json'] = jsonEncode(resolvedPaths);
          rawRow[entry.value] = resolvedPaths.isEmpty
              ? null
              : resolvedPaths.first;
          continue;
        }
        rawRow[entry.value] = resolve(
          rawRow[entry.value],
          emptyString: _emptyStringPathTables.contains(entry.key),
        );
      }
    }
    final preferences = data['preferences'];
    if (preferences is Map) {
      for (final key in preferences.keys.toList()) {
        final keyText = key.toString();
        if (keyText.toLowerCase().contains('path')) {
          preferences[key] = resolve(preferences[key], emptyString: true) ?? '';
          continue;
        }
        if (!_backgroundPresetPreferenceKey.hasMatch(keyText)) continue;
        final preset = _decodeBackgroundPresetPreference(preferences[key]);
        if (preset == null) continue;
        for (final field in _backgroundPresetPathFields) {
          preset[field] = resolve(preset[field], emptyString: true) ?? '';
        }
        preferences[key] = jsonEncode(preset);
      }
    }
  }

  static Map<String, dynamic> _decodeJsonEntry(
    ArchiveFile entry, {
    required String field,
  }) {
    if (!entry.isFile || entry.size > _maxMetadataBytes) {
      throw FormatException('$field 大小或類型無效');
    }
    final bytes = entry.readBytes();
    if (bytes == null) throw FormatException('$field 無法讀取');
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map) throw FormatException('$field 必須是物件');
    return <String, dynamic>{
      for (final item in decoded.entries) item.key.toString(): item.value,
    };
  }

  static Map<String, dynamic> _deepCopy(Map<String, Object?> source) {
    final decoded = jsonDecode(jsonEncode(source));
    return Map<String, dynamic>.from(decoded as Map);
  }

  static Map<String, dynamic>? _decodeBackgroundPresetPreference(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? <String, dynamic>{
              for (final entry in decoded.entries)
                entry.key.toString(): entry.value,
            }
          : null;
    } catch (_) {
      return null;
    }
  }

  static List<String> _decodeImagePaths(Object? raw) {
    Object? decoded = raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = const <Object?>[];
      }
    }
    if (decoded is! List) return const <String>[];
    final paths = <String>[];
    for (final value in decoded) {
      if (value is! String || value.trim().isEmpty) continue;
      final path = value.trim();
      if (!paths.contains(path)) paths.add(path);
    }
    return paths;
  }

  static bool _isSafeEntryName(String name) {
    if (name.isEmpty || name.contains('\\') || p.posix.isAbsolute(name)) {
      return false;
    }
    final candidate = name.endsWith('/')
        ? name.substring(0, name.length - 1)
        : name;
    return candidate.isNotEmpty &&
        p.posix.normalize(candidate) == candidate &&
        !candidate.startsWith('../') &&
        candidate != '..';
  }

  static bool _isSafeMediaPath(String name) {
    return _isSafeEntryName(name) &&
        name.startsWith('media/') &&
        p.posix.dirname(name) == 'media' &&
        p.posix.basename(name).isNotEmpty;
  }

  static String _safeExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension) ? extension : '';
  }
}
