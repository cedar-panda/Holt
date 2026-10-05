import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/avatar_image_path_service.dart';
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

  test('rebases character and persona avatars from an old iOS container', () async {
    final root = await Directory.systemTemp.createTemp('holt-avatar-path-');
    addTearDown(() => root.delete(recursive: true));
    final documents = p.join(root.path, 'Documents');
    final characterAvatar = p.join(
      documents,
      'avatars',
      'avatar_character.png',
    );
    final personaAvatar = p.join(documents, 'HoltImportedMedia', 'persona.png');
    await File(characterAvatar).create(recursive: true);
    await File(personaAvatar).create(recursive: true);
    final now = DateTime.now().toIso8601String();
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': 'A',
      'avatar_path':
          '/var/mobile/Containers/Data/Application/OLD/Documents/avatars/avatar_character.png',
      'created_at': now,
      'updated_at': now,
    });
    await db.update(
      'user_personas',
      <String, Object?>{
        'avatar_path':
            '/var/mobile/Containers/Data/Application/OLD/Documents/HoltImportedMedia/persona.png',
      },
      where: 'id = ?',
      whereArgs: const <Object?>['default'],
    );

    final repaired = await AvatarImagePathService.repairDatabasePaths(
      db,
      documents,
    );

    expect(repaired, 2);
    expect(
      (await db.query(
        'characters',
        where: 'id = ?',
        whereArgs: ['char-a'],
      )).single['avatar_path'],
      characterAvatar,
    );
    expect(
      (await db.query(
        'user_personas',
        where: 'id = ?',
        whereArgs: ['default'],
      )).single['avatar_path'],
      personaAvatar,
    );
  });

  test('leaves external and missing avatar paths untouched', () async {
    final root = await Directory.systemTemp.createTemp('holt-avatar-path-');
    addTearDown(() => root.delete(recursive: true));
    final documents = p.join(root.path, 'Documents');
    await Directory(documents).create(recursive: true);

    const external = '/tmp/external/avatar.png';
    const missing = '/old/Documents/avatars/missing.png';
    expect(
      AvatarImagePathService.resolveInDocuments(external, documents),
      external,
    );
    expect(
      AvatarImagePathService.resolveInDocuments(missing, documents),
      missing,
    );
  });
}
