import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'app_directories.dart';

/// Restricts imported and deleted media to the app-owned documents directory.
class AppFileSafety {
  static bool isWithinRoot(String candidate, String root) {
    if (candidate.trim().isEmpty || !p.isAbsolute(candidate)) return false;
    final normalizedRoot = p.normalize(root);
    final normalizedCandidate = p.normalize(candidate);
    return p.isWithin(normalizedRoot, normalizedCandidate);
  }

  static Future<String?> normalizeOwnedPath(dynamic value) async {
    if (value is! String || value.trim().isEmpty) return null;
    final documents = await getAppDocumentsDirectory();
    final normalized = p.normalize(value);
    return isWithinRoot(normalized, documents.path) ? normalized : null;
  }

  static Future<void> deleteOwnedFiles(Iterable<String?> paths) async {
    final candidates = paths
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toSet();
    if (candidates.isEmpty) return;
    final documents = await getAppDocumentsDirectory();
    final uniquePaths = candidates
        .map(p.normalize)
        .where((path) => isWithinRoot(path, documents.path))
        .toSet();
    for (final path in uniquePaths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint('App media cleanup failed: $error');
      }
    }
  }
}
