import 'dart:io';

import 'package:path/path.dart' as p;
import '../utils/app_directories.dart';

/// Persists app-owned backgrounds relative to Documents. iOS may give the
/// app's data container a new UUID after an update while keeping its files.
class BackgroundImagePathService {
  BackgroundImagePathService._();

  static const _folder = 'background_images';
  static final _fileName = RegExp(
    r'^bg_(?:slot_(\d+)_)?(home|chat)_[A-Za-z0-9._-]+$',
  );

  static Future<String> resolve(
    String stored, {
    int? slot,
    required String scope,
  }) async {
    if (!_isManaged(stored, slot: slot, scope: scope)) return stored;
    final documents = await getAppDocumentsDirectory();
    return resolveInDocuments(stored, documents.path, slot: slot, scope: scope);
  }

  static Future<String> forStorage(
    String runtime, {
    int? slot,
    required String scope,
  }) async {
    if (!_isManaged(runtime, slot: slot, scope: scope)) return runtime;
    final documents = await getAppDocumentsDirectory();
    return forStorageInDocuments(
      runtime,
      documents.path,
      slot: slot,
      scope: scope,
    );
  }

  /// Keep a missing reference untouched: never silently discard user data.
  static String resolveInDocuments(
    String stored,
    String documentsPath, {
    int? slot,
    required String scope,
  }) {
    if (!_isManaged(stored, slot: slot, scope: scope)) return stored;
    final candidate = p.join(documentsPath, _folder, p.basename(stored));
    return File(candidate).existsSync() ? candidate : stored;
  }

  static String forStorageInDocuments(
    String runtime,
    String documentsPath, {
    int? slot,
    required String scope,
  }) {
    if (!_isManaged(runtime, slot: slot, scope: scope)) return runtime;
    final candidate = p.join(documentsPath, _folder, p.basename(runtime));
    if (!File(candidate).existsSync()) return runtime;
    return p.join(_folder, p.basename(runtime));
  }

  static bool _isManaged(String path, {int? slot, required String scope}) {
    if (path.trim().isEmpty) return false;
    final normalized = p.normalize(path);
    final nameMatch = _fileName.firstMatch(p.basename(normalized));
    if (nameMatch == null || nameMatch.group(2) != scope) return false;
    final namedSlot = int.tryParse(nameMatch.group(1) ?? '1');
    if (slot != null && namedSlot != slot) return false;
    final parent = p.dirname(normalized);
    if (parent == _folder) return true;
    return p.basename(parent) == _folder &&
        p.basename(p.dirname(parent)) == 'Documents';
  }
}
