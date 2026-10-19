import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/sticker_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  Future<void> insertSticker(String bucket, String line) async {
    await DatabaseHelper.insertSticker(<String, Object?>{
      'character_id': bucket,
      'file_path': '/tmp/$line.png',
      'line': line,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  test(
    'default and custom user personas keep separate sticker libraries',
    () async {
      final customBucket = StickerService.userBucketForPersona('persona-a');
      await insertSticker(StickerService.userBucket, 'default-user');
      await insertSticker(customBucket, 'persona-a-user');

      final defaultStickers = await StickerService.getUserStickers(
        userPersonaId: 'default',
      );
      final customStickers = await StickerService.getUserStickers(
        userPersonaId: 'persona-a',
      );

      expect(defaultStickers.map((item) => item.line), <String?>[
        'default-user',
      ]);
      expect(customStickers.map((item) => item.line), <String?>[
        'persona-a-user',
      ]);
    },
  );

  test('sticker prompt reads the user persona bound to the window', () async {
    final customBucket = StickerService.userBucketForPersona('persona-a');
    await insertSticker(StickerService.userBucket, 'default-user');
    await insertSticker(customBucket, 'persona-a-user');

    final prompt = await StickerService.buildStickerPrompt(
      characterId: 'char-a',
      userPersonaId: 'persona-a',
    );

    expect(prompt, contains('persona-a-user'));
    expect(prompt, isNot(contains('default-user')));
  });
}
