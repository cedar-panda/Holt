import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CustomFontFailure {
  missingFile,
  unsupportedFormat,
  emptyFile,
  tooLarge,
  invalidFont,
  loadFailed,
}

class CustomFontException implements Exception {
  final CustomFontFailure failure;

  const CustomFontException(this.failure);
}

class CustomFontInfo {
  final String family;
  final String displayName;
  final String filePath;

  const CustomFontInfo({
    required this.family,
    required this.displayName,
    required this.filePath,
  });
}

/// 單一自訂字體槽：導入成功後立即可用，再次導入會替換上一個檔案。
class CustomFontService {
  static const int maxFileBytes = 50 * 1024 * 1024;
  static const String _keyFamily = 'custom_font_family';
  static const String _keyDisplayName = 'custom_font_display_name';
  static const String _keyFilePath = 'custom_font_file_path';
  static const String _keyActive = 'custom_font_active';
  static final Set<String> _loadedFamilies = <String>{};

  static Future<CustomFontInfo?> getSavedFont() async {
    final preferences = await SharedPreferences.getInstance();
    final family = preferences.getString(_keyFamily)?.trim() ?? '';
    final displayName = preferences.getString(_keyDisplayName)?.trim() ?? '';
    final filePath = preferences.getString(_keyFilePath)?.trim() ?? '';
    if (family.isEmpty || displayName.isEmpty || filePath.isEmpty) return null;
    return CustomFontInfo(
      family: family,
      displayName: displayName,
      filePath: filePath,
    );
  }

  static Future<bool> isActive() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_keyActive) ?? false;
  }

  /// App 啟動時恢復目前啟用的自訂字體。缺檔或損壞就停用並回退內置字體。
  static Future<CustomFontInfo?> restoreActiveFont() async {
    if (!await isActive()) return null;
    final info = await getSavedFont();
    if (info == null) {
      await deactivate();
      return null;
    }
    try {
      await _validateAndLoad(info.filePath, info.family);
      return info;
    } catch (_) {
      await _clearInvalidSavedFont();
      return null;
    }
  }

  static Future<CustomFontInfo> importFont({
    required String sourcePath,
    required String originalName,
  }) async {
    final extension = p.extension(originalName).toLowerCase();
    if (extension != '.ttf' && extension != '.otf') {
      throw const CustomFontException(CustomFontFailure.unsupportedFormat);
    }

    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const CustomFontException(CustomFontFailure.missingFile);
    }
    await _validateFile(source);

    final support = await getApplicationSupportDirectory();
    final fontDirectory = Directory(p.join(support.path, 'fonts'));
    await fontDirectory.create(recursive: true);

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final family = 'HoltCustomFont$stamp';
    final target = File(
      p.join(fontDirectory.path, 'custom_font_$stamp$extension'),
    );
    final previous = await getSavedFont();

    try {
      await source.copy(target.path);
      await _loadFont(target.path, family);
      final info = CustomFontInfo(
        family: family,
        displayName: displayNameFromFilename(originalName),
        filePath: target.path,
      );
      await _save(info, active: true);
      await _deletePreviousOwnedFile(previous, fontDirectory, target.path);
      return info;
    } on CustomFontException {
      await _deleteIfPresent(target);
      rethrow;
    } catch (_) {
      await _deleteIfPresent(target);
      throw const CustomFontException(CustomFontFailure.loadFailed);
    }
  }

  static Future<void> activate(CustomFontInfo info) async {
    await _validateAndLoad(info.filePath, info.family);
    await _save(info, active: true);
  }

  static Future<void> deactivate() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_keyActive, false);
  }

  static Future<void> _validateAndLoad(String filePath, String family) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const CustomFontException(CustomFontFailure.missingFile);
    }
    await _validateFile(file);
    await _loadFont(filePath, family);
  }

  static Future<void> _validateFile(File file) async {
    final length = await file.length();
    if (length == 0) {
      throw const CustomFontException(CustomFontFailure.emptyFile);
    }
    if (length > maxFileBytes) {
      throw const CustomFontException(CustomFontFailure.tooLarge);
    }

    final handle = await file.open();
    try {
      final header = await handle.read(4);
      if (!hasSupportedHeader(header)) {
        throw const CustomFontException(CustomFontFailure.invalidFont);
      }
    } finally {
      await handle.close();
    }
  }

  static Future<void> _loadFont(String filePath, String family) async {
    if (_loadedFamilies.contains(family)) return;
    try {
      final loader = FontLoader(family);
      loader.addFont(File(filePath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      _loadedFamilies.add(family);
    } catch (_) {
      throw const CustomFontException(CustomFontFailure.loadFailed);
    }
  }

  static Future<void> _save(CustomFontInfo info, {required bool active}) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyFamily, info.family);
    await preferences.setString(_keyDisplayName, info.displayName);
    await preferences.setString(_keyFilePath, info.filePath);
    await preferences.setBool(_keyActive, active);
  }

  static Future<void> _clearInvalidSavedFont() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_keyFamily);
    await preferences.remove(_keyDisplayName);
    await preferences.remove(_keyFilePath);
    await preferences.setBool(_keyActive, false);
  }

  static Future<void> _deletePreviousOwnedFile(
    CustomFontInfo? previous,
    Directory fontDirectory,
    String currentPath,
  ) async {
    final oldPath = previous?.filePath ?? '';
    if (oldPath.isEmpty || oldPath == currentPath) return;
    final normalizedRoot = p.normalize(fontDirectory.absolute.path);
    final normalizedOld = p.normalize(File(oldPath).absolute.path);
    if (!p.isWithin(normalizedRoot, normalizedOld)) return;
    await _deleteIfPresent(File(normalizedOld));
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 舊字體檔清理失敗不影響新字體使用，下次導入可再清。
    }
  }

  /// TrueType / OpenType 的四位元組 magic number。
  static bool hasSupportedHeader(Uint8List bytes) {
    if (bytes.length < 4) return false;
    final signature = String.fromCharCodes(bytes.take(4));
    final trueTypeNumeric =
        bytes[0] == 0x00 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x00 &&
        bytes[3] == 0x00;
    return trueTypeNumeric ||
        signature == 'OTTO' ||
        signature == 'true' ||
        signature == 'typ1';
  }

  static String displayNameFromFilename(String filename) {
    final raw = p.basenameWithoutExtension(filename).trim();
    final fallback = raw.isEmpty ? 'Custom Font' : raw;
    return String.fromCharCodes(fallback.runes.take(60));
  }
}
