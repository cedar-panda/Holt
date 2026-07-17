import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/sticker_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory root;
  late Directory documents;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    root = await Directory.systemTemp.createTemp('holt-sticker-test-');
    documents = Directory('${root.path}/documents')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documents.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'new sticker is copied into app storage and deleted with its row',
    () async {
      final pickerTemp = File('${root.path}/picker-temp.png')
        ..writeAsStringSync('image');

      final id = await StickerService.addSticker(
        filePath: pickerTemp.path,
        characterId: 'char-a',
        line: 'hello',
      );
      final row = (await db.query(
        'stickers',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      final stored = File(row['file_path'] as String);

      expect(stored.path.startsWith('${documents.path}/stickers/'), isTrue);
      expect(await stored.exists(), isTrue);
      expect(stored.path, isNot(pickerTemp.path));

      await StickerService.deleteSticker(id);
      expect(await stored.exists(), isFalse);
      expect(await pickerTemp.exists(), isTrue);
    },
  );
}
