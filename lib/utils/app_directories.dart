import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App 自己的「文件」資料夾：頭像、圖片、貼圖、本機模型、備份都放這裡。
///
/// 手機與 macOS 沿用系統給 App 的 Documents（沙盒內，既有資料原地不動）。
/// Windows 的 Documents 是使用者自己的「文件」，常開 OneDrive 同步——
/// 把幾 GB 的模型和私人圖片丟進去會被上傳雲端，所以改放
/// %APPDATA%\\<公司>\\Holt\\documents。用子資料夾，避免和
/// Application Support（字體、ASR、錯誤紀錄）同一層互相重疊。
Future<Directory> getAppDocumentsDirectory() async {
  if (!kIsWeb && Platform.isWindows) {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'documents'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
  return getApplicationDocumentsDirectory();
}

/// SQLite 資料庫所在資料夾。手機沿用 sqflite 的既有位置（yanci.db 原地保留）；
/// Windows 上 sqflite 的手機外掛沒有實作，改用 App 資料夾下的 databases。
Future<String> getAppDatabasesPath(Future<String> Function() mobilePath) async {
  if (!kIsWeb && Platform.isWindows) {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'databases'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }
  return mobilePath();
}
