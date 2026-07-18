import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_yanci/services/portable_backup_bundle.dart';

void main() {
  late Directory root;
  late Directory owned;
  late Directory working;
  late Directory destination;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('holt_bundle_test_');
    owned = await Directory(p.join(root.path, 'owned')).create();
    working = await Directory(p.join(root.path, 'working')).create();
    destination = await Directory(p.join(root.path, 'destination')).create();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'portable bundle embeds owned media and rewrites restored paths',
    () async {
      final image = File(p.join(owned.path, 'chat image.png'));
      await image.writeAsBytes(<int>[1, 2, 3, 4, 5]);
      final outside = File(p.join(root.path, 'outside.png'));
      await outside.writeAsBytes(<int>[9, 9, 9]);
      final database = File(p.join(root.path, 'yanci.db'));
      await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);
      final output = File(p.join(root.path, 'backup.holt.zip'));

      await PortableBackupBundle.create(
        backupData: <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'image_path': image.path},
          ],
          'stickers': <Object?>[
            <String, Object?>{'file_path': image.path},
          ],
          'characters': <Object?>[
            <String, Object?>{'avatar_path': outside.path},
          ],
          'preferences': <String, Object?>{'user_avatar_path': image.path},
        },
        databaseSnapshot: database,
        ownedRoot: owned,
        workingRoot: working,
        outputFile: output,
      );

      final extracted = await PortableBackupBundle.extract(
        bundle: output,
        destinationRoot: destination,
      );
      final messagePath =
          ((extracted.data['messages'] as List).single as Map)['image_path']
              as String;
      final stickerPath =
          ((extracted.data['stickers'] as List).single as Map)['file_path']
              as String;
      final preferencePath =
          (extracted.data['preferences'] as Map)['user_avatar_path'] as String;

      expect(messagePath, stickerPath);
      expect(messagePath, preferencePath);
      expect(p.isWithin(destination.path, messagePath), isTrue);
      expect(await File(messagePath).readAsBytes(), <int>[1, 2, 3, 4, 5]);
      expect(
        ((extracted.data['characters'] as List).single as Map)['avatar_path'],
        isNull,
      );
    },
  );

  test('portable bundle rejects zip traversal entries', () async {
    final output = File(p.join(root.path, 'traversal.holt.zip'));
    final encoder = ZipFileEncoder()..create(output.path);
    encoder.addArchiveFile(
      ArchiveFile.string(
        PortableBackupBundle.manifestEntry,
        jsonEncode(<String, Object?>{
          'type': 'holt_portable_backup',
          'version': PortableBackupBundle.formatVersion,
          'data': PortableBackupBundle.dataEntry,
          'files': <Object?>[],
        }),
      ),
    );
    encoder.addArchiveFile(
      ArchiveFile.string(PortableBackupBundle.dataEntry, '{}'),
    );
    encoder.addArchiveFile(ArchiveFile.string('../escape.txt', 'no'));
    await encoder.close();

    await expectLater(
      PortableBackupBundle.extract(
        bundle: output,
        destinationRoot: destination,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await File(p.join(root.path, 'escape.txt')).exists(), isFalse);
  });

  test('portable bundle verifies media hashes before returning data', () async {
    final bytes = <int>[7, 8, 9];
    final actualHash = sha256.convert(bytes).toString();
    final mediaPath = 'media/$actualHash.bin';
    final output = File(p.join(root.path, 'bad_hash.holt.zip'));
    final encoder = ZipFileEncoder()..create(output.path);
    encoder.addArchiveFile(
      ArchiveFile.string(
        PortableBackupBundle.manifestEntry,
        jsonEncode(<String, Object?>{
          'type': 'holt_portable_backup',
          'version': PortableBackupBundle.formatVersion,
          'data': PortableBackupBundle.dataEntry,
          'files': <Object?>[
            <String, Object?>{
              'path': mediaPath,
              'sha256': List<String>.filled(64, '0').join(),
              'size': bytes.length,
            },
          ],
        }),
      ),
    );
    encoder.addArchiveFile(
      ArchiveFile.string(
        PortableBackupBundle.dataEntry,
        jsonEncode(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'image_path': mediaPath},
          ],
        }),
      ),
    );
    encoder.addArchiveFile(ArchiveFile.bytes(mediaPath, bytes));
    await encoder.close();

    await expectLater(
      PortableBackupBundle.extract(
        bundle: output,
        destinationRoot: destination,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
