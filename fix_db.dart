import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';

void main() async {
  sqfliteFfiInit();
  var databaseFactory = databaseFactoryFfi;
  final dbPath = join(Directory.current.path, '.dart_tool', 'sqflite_common_ffi', 'databases', 'yanci_memory.db');
  // Wait, on macOS the default path for getDatabasesPath() is not in .dart_tool unless it's a test.
  // Actually, for macOS desktop app, it's typically in Documents or Library.
  print('Need to find db path');
}
