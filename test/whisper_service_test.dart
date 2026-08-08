import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/whisper_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('characters', {
      'id': 'char-a',
      'name': 'TA',
      'created_at': '2026-08-08T00:00:00.000',
      'updated_at': '2026-08-08T00:00:00.000',
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('enabled model overwrite saves and strips whisper tags', () async {
    final result = await WhisperService.processReply(
      '正文<whisper>慢慢說，我在聽</whisper>',
      characterId: 'char-a',
    );

    expect(result.text, '正文');
    expect(result.updated, isTrue);
    expect(result.state.displayText, '慢慢說，我在聽');
    final row = (await db.query('characters')).single;
    expect(row['whisper_model_text'], '慢慢說，我在聽');
    expect(row['whisper_source'], 'model');
  });

  test('disabled model overwrite strips but never persists the tag', () async {
    await WhisperService.saveUserText('char-a', '照你的步調來');
    await WhisperService.setModelOverride('char-a', false);

    final result = await WhisperService.processReply(
      '正文<whisper>模型想改掉</whisper>',
      characterId: 'char-a',
    );

    expect(result.text, '正文');
    expect(result.updated, isFalse);
    expect(result.state.displayText, '照你的步調來');
    final row = (await db.query('characters')).single;
    expect(row['whisper_model_text'], '');
  });

  test(
    'turning override off falls back to user text, then latest model text',
    () {
      const withUser = CharacterWhisperState(
        userText: '使用者寫的',
        modelText: '模型寫的',
        source: 'model',
        modelOverrideEnabled: false,
      );
      const withoutUser = CharacterWhisperState(
        userText: '',
        modelText: '模型最後一句',
        source: 'model',
        modelOverrideEnabled: false,
      );

      expect(withUser.displayText, '使用者寫的');
      expect(withoutUser.displayText, '模型最後一句');
    },
  );
}
