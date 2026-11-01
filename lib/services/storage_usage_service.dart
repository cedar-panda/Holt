import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../memory/database.dart';
import 'local_model_service.dart';
import '../utils/app_directories.dart';

/// 可清理的儲存類別。「其他」（資料庫、頭像、背景、表情包、字體、
/// 語音辨識模型）只統計不提供刪除，刪了會壞功能。
enum StorageCategory {
  chatImages,
  importedMedia,
  voices,
  localModels,
  backups,
  cache,
}

class StorageItem {
  const StorageItem({
    required this.id,
    required this.label,
    required this.bytes,
    this.path,
    this.date,
    this.inUse = true,
  });

  /// 類別內唯一：圖片／暫存用路徑，語音用 DB id，模型用 key。
  final String id;
  final String label;
  final int bytes;
  final String? path;
  final DateTime? date;

  /// 聊天圖片：還有消息在引用。false = 對話已刪、沒人用的孤兒檔。
  final bool inUse;
}

class StorageSnapshot {
  const StorageSnapshot({required this.items, required this.otherParts});

  final Map<StorageCategory, List<StorageItem>> items;

  /// 「其他」按頂層資料夾／檔案拆開，大的在前（只看不刪）。
  final List<StorageItem> otherParts;

  int get otherBytes => otherParts.fold(0, (sum, item) => sum + item.bytes);

  int bytesOf(StorageCategory category) =>
      (items[category] ?? const <StorageItem>[]).fold(
        0,
        (sum, item) => sum + item.bytes,
      );

  int get totalBytes =>
      StorageCategory.values.fold(otherBytes, (sum, c) => sum + bytesOf(c));
}

abstract final class StorageUsageService {
  static Future<StorageSnapshot> scan() async {
    final documents = await getAppDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final temporary = await getTemporaryDirectory();

    final images = await _chatImages(documents);
    final imported = await _importedMedia(documents);
    final backups = await _backupFiles(documents);
    final voices = await _voices(documents);
    final models = await _localModels();
    final cacheBytes = await _dirBytes(temporary);
    final items = <StorageCategory, List<StorageItem>>{
      StorageCategory.chatImages: images,
      StorageCategory.importedMedia: imported,
      StorageCategory.voices: voices,
      StorageCategory.localModels: models,
      StorageCategory.backups: backups,
      StorageCategory.cache: <StorageItem>[
        if (cacheBytes > 0)
          StorageItem(
            id: temporary.path,
            label: '',
            bytes: cacheBytes,
            path: temporary.path,
          ),
      ],
    };

    final roots = <Directory>[
      documents,
      if (!p.equals(support.path, documents.path) &&
          !p.isWithin(documents.path, support.path))
        support,
    ];
    final otherParts = <StorageItem>[];
    for (final root in roots) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (_listedFolders.contains(name) || _isBackupFileName(name)) continue;
        final bytes = entity is File
            ? await entity.length()
            : entity is Directory
            ? await _dirBytes(entity)
            : 0;
        if (bytes <= 0) continue;
        otherParts.add(
          StorageItem(id: entity.path, label: name, bytes: bytes),
        );
      }
    }
    otherParts.sort((a, b) => b.bytes.compareTo(a.bytes));
    return StorageSnapshot(items: items, otherParts: otherParts);
  }

  /// 已在上面分類列出的資料夾，「其他」不重複算。
  static const Set<String> _listedFolders = <String>{
    'chat_images',
    'voices',
    'local_models',
    _importedMediaFolder,
  };

  static const String _importedMediaFolder = 'HoltImportedMedia';

  /// 使用者自己存進 Holt 資料夾的備份／匯出檔（「檔案」App 可見）。
  static bool _isBackupFileName(String name) =>
      RegExp(r'^holt_(backup|export)_').hasMatch(name) &&
      (name.endsWith('.holt.backup') ||
          name.endsWith('.holt.zip') ||
          name.endsWith('.json'));

  static Future<void> delete(
    StorageCategory category,
    Iterable<StorageItem> items,
  ) async {
    for (final item in items) {
      try {
        switch (category) {
          case StorageCategory.chatImages:
          case StorageCategory.importedMedia:
          case StorageCategory.backups:
            await _deleteFile(item.path);
          case StorageCategory.voices:
            final id = int.tryParse(item.id);
            if (id != null) {
              await DatabaseHelper.deleteVoice(id);
            } else {
              await _deleteFile(item.path);
            }
          case StorageCategory.localModels:
            await LocalModelService.deleteModel(item.id);
          case StorageCategory.cache:
            await _clearDirectory(Directory(item.path!));
        }
      } catch (_) {
        // 單項失敗不中斷其他項；重新掃描時會如實顯示。
      }
    }
  }

  static Future<List<StorageItem>> _chatImages(Directory documents) async {
    final dir = Directory(p.join(documents.path, 'chat_images'));
    if (!await dir.exists()) return const <StorageItem>[];
    final referenced = await _referencedImagePaths();
    final items = <StorageItem>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      items.add(
        StorageItem(
          id: entity.path,
          label: p.basename(entity.path),
          bytes: stat.size,
          path: entity.path,
          date: stat.modified,
          inUse: referenced.contains(p.basename(entity.path)),
        ),
      );
    }
    items.sort((a, b) => b.date!.compareTo(a.date!));
    return items;
  }

  /// 用檔名比對：iOS 重裝後 App 容器路徑會變，完整路徑對不上。
  static Future<Set<String>> _referencedImagePaths() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'messages',
      columns: const <String>['image_path', 'image_paths_json'],
      where: "(image_path IS NOT NULL AND image_path != '') "
          "OR image_paths_json != '[]'",
    );
    final names = <String>{};
    for (final row in rows) {
      final single = row['image_path']?.toString() ?? '';
      if (single.isNotEmpty) names.add(p.basename(single));
      try {
        final list = jsonDecode(row['image_paths_json']?.toString() ?? '[]');
        if (list is List) {
          for (final value in list) {
            if (value is String && value.isNotEmpty) {
              names.add(p.basename(value));
            }
          }
        }
      } catch (_) {}
    }
    return names;
  }

  static Future<List<StorageItem>> _backupFiles(Directory documents) async {
    final items = <StorageItem>[];
    await for (final entity in documents.list(followLinks: false)) {
      if (entity is! File || !_isBackupFileName(p.basename(entity.path))) {
        continue;
      }
      final stat = await entity.stat();
      items.add(
        StorageItem(
          id: entity.path,
          label: p.basename(entity.path),
          bytes: stat.size,
          path: entity.path,
          date: stat.modified,
        ),
      );
    }
    items.sort((a, b) => b.date!.compareTo(a.date!));
    return items;
  }

  /// 每次從備份還原，媒體會解到 HoltImportedMedia/<時間戳>/。還原多次就會
  /// 留下沒人再用的舊份。用檔名比對所有資料表的文字欄位與偏好設定，
  /// 找得到就算「在用」（寧可多標在用，也不要誤標可刪）。
  static Future<List<StorageItem>> _importedMedia(Directory documents) async {
    final root = Directory(p.join(documents.path, _importedMediaFolder));
    if (!await root.exists()) return const <StorageItem>[];
    final referenced = await _importedMediaReferences();
    final items = <StorageItem>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      items.add(
        StorageItem(
          id: entity.path,
          label: p.basename(entity.path),
          bytes: stat.size,
          path: entity.path,
          date: stat.modified,
          inUse: referenced.contains(p.basename(entity.path)),
        ),
      );
    }
    items.sort((a, b) => b.date!.compareTo(a.date!));
    return items;
  }

  static final RegExp _importedRef = RegExp(
    '$_importedMediaFolder/[^"\'\\s,\\[\\]]+',
  );

  static Future<Set<String>> _importedMediaReferences() async {
    final names = <String>{};
    void collect(Object? value) {
      if (value is! String || !value.contains(_importedMediaFolder)) return;
      for (final match in _importedRef.allMatches(value)) {
        names.add(p.basename(match.group(0)!));
      }
    }

    final db = await DatabaseHelper.database;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    for (final table in tables) {
      final name = table['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final columns = await db.rawQuery('PRAGMA table_info("$name")');
      for (final column in columns) {
        final type = column['type']?.toString().toUpperCase() ?? '';
        if (!type.contains('TEXT')) continue;
        final col = column['name']?.toString() ?? '';
        final rows = await db.rawQuery(
          'SELECT "$col" AS v FROM "$name" WHERE "$col" LIKE ?',
          <Object?>['%$_importedMediaFolder%'],
        );
        for (final row in rows) {
          collect(row['v']);
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value is List) {
        value.forEach(collect);
      } else {
        collect(value?.toString());
      }
    }
    return names;
  }

  static Future<List<StorageItem>> _voices(Directory documents) async {
    final rows = await DatabaseHelper.getSavedVoices();
    final items = <StorageItem>[];
    final known = <String>{};
    for (final row in rows) {
      final path = row['file_path']?.toString() ?? '';
      final file = File(path);
      final exists = path.isNotEmpty && await file.exists();
      if (exists) known.add(p.basename(path));
      items.add(
        StorageItem(
          id: row['id'].toString(),
          label: row['name']?.toString() ?? '',
          bytes: exists ? await file.length() : 0,
          path: path,
          date: DateTime.tryParse(row['created_at']?.toString() ?? ''),
        ),
      );
    }
    // 語音庫沒有登記的殘檔（舊版刪記錄沒刪檔）也列出來。
    final dir = Directory(p.join(documents.path, 'voices'));
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || known.contains(p.basename(entity.path))) {
          continue;
        }
        final stat = await entity.stat();
        items.add(
          StorageItem(
            id: 'file:${entity.path}',
            label: '',
            bytes: stat.size,
            path: entity.path,
            date: stat.modified,
            inUse: false,
          ),
        );
      }
    }
    return items;
  }

  static Future<List<StorageItem>> _localModels() async {
    final items = <StorageItem>[];
    for (final model in await LocalModelService.getAllModels()) {
      if (!await LocalModelService.isDownloadedFast(model.key)) continue;
      final path = await LocalModelService.modelPath(model.key);
      final file = File(path);
      items.add(
        StorageItem(
          id: model.key,
          label: model.name,
          bytes: await file.exists() ? await file.length() : 0,
          path: path,
        ),
      );
    }
    return items;
  }

  static Future<int> _dirBytes(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  static Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  static Future<void> _clearDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }
}
