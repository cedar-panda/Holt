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
      final secondImage = File(p.join(owned.path, 'chat image 2.png'));
      await secondImage.writeAsBytes(<int>[6, 7, 8, 9]);
      final customSendButton = File(
        p.join(owned.path, 'send_button_images', 'custom.png'),
      );
      await customSendButton.parent.create(recursive: true);
      await customSendButton.writeAsBytes(<int>[10, 11, 12, 13]);
      final database = File(p.join(root.path, 'yanci.db'));
      await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);
      final output = File(p.join(root.path, 'backup.holt.zip'));

      await PortableBackupBundle.create(
        backupData: <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{
              'image_path': image.path,
              'image_paths_json': jsonEncode(<String>[
                image.path,
                secondImage.path,
              ]),
            },
          ],
          'stickers': <Object?>[
            <String, Object?>{'file_path': image.path},
          ],
          'message_revisions': [
            {
              'snapshot_json': jsonEncode({
                'text': 'archived reply',
                'image_path': secondImage.path,
                'image_paths_json': jsonEncode([secondImage.path]),
                'reply_user_snapshot': {
                  'text': 'original prompt',
                  'image_path': image.path,
                  'image_paths_json': jsonEncode([image.path]),
                },
              }),
            },
          ],
          'characters': <Object?>[
            <String, Object?>{'avatar_path': secondImage.path},
          ],
          'preferences': <String, Object?>{
            'user_avatar_path': image.path,
            'send_button_custom_path': customSendButton.path,
          },
        },
        databaseSnapshot: database,
        ownedRoot: owned,
        workingRoot: working,
        outputFile: output,
      );

      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      expect(
        archive.where((entry) => !entry.isFile),
        isEmpty,
        reason: 'portable backups must not contain broken directory entries',
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
      final restoredSendButton =
          (extracted.data['preferences'] as Map)['send_button_custom_path']
              as String;

      expect(messagePath, stickerPath);
      expect(messagePath, preferencePath);
      expect(p.isWithin(destination.path, messagePath), isTrue);
      expect(await File(messagePath).readAsBytes(), <int>[1, 2, 3, 4, 5]);
      expect(p.isWithin(destination.path, restoredSendButton), isTrue);
      expect(await File(restoredSendButton).readAsBytes(), <int>[
        10,
        11,
        12,
        13,
      ]);
      final messageRow = (extracted.data['messages'] as List).single as Map;
      final restoredImages =
          jsonDecode(messageRow['image_paths_json'] as String) as List<dynamic>;
      expect(restoredImages, hasLength(2));
      final revision =
          (extracted.data['message_revisions'] as List).single as Map;
      final oldReply = jsonDecode(revision['snapshot_json'] as String) as Map;
      expect(oldReply['image_path'], restoredImages[1]);
      expect(
        (oldReply['reply_user_snapshot'] as Map)['image_path'],
        messagePath,
      );
      expect(await File(restoredImages[1] as String).readAsBytes(), <int>[
        6,
        7,
        8,
        9,
      ]);
      final characterPath =
          ((extracted.data['characters'] as List).single as Map)['avatar_path']
              as String;
      expect(characterPath, restoredImages[1]);
    },
  );

  test(
    'portable bundle refuses to silently drop required user media',
    () async {
      final outside = File(p.join(root.path, 'outside.png'));
      await outside.writeAsBytes(<int>[9, 9, 9]);
      final database = File(p.join(root.path, 'yanci.db'));
      await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);

      await expectLater(
        PortableBackupBundle.create(
          backupData: <String, Object?>{
            'characters': <Object?>[
              <String, Object?>{'avatar_path': outside.path},
            ],
          },
          databaseSnapshot: database,
          ownedRoot: owned,
          workingRoot: working,
          outputFile: File(p.join(root.path, 'should_not_exist.holt.zip')),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'portable bundle rebases stale iOS container media into current documents',
    () async {
      final image = File(p.join(owned.path, 'chat_images', 'survived.png'));
      await image.parent.create(recursive: true);
      await image.writeAsBytes(<int>[4, 3, 2, 1]);
      const stalePath =
          '/var/mobile/Containers/Data/Application/'
          '01234567-89AB-CDEF-0123-456789ABCDEF/'
          'Documents/chat_images/survived.png';
      final database = File(p.join(root.path, 'yanci.db'));
      await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);
      final output = File(p.join(root.path, 'rebased.holt.zip'));

      await PortableBackupBundle.create(
        backupData: <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{
              'image_path': stalePath,
              'image_paths_json': jsonEncode(<String>[stalePath]),
            },
          ],
          'message_revisions': <Object?>[
            <String, Object?>{
              'snapshot_json': jsonEncode(<String, Object?>{
                'image_path': stalePath,
                'image_paths_json': jsonEncode(<String>[stalePath]),
              }),
            },
          ],
          'characters': <Object?>[
            <String, Object?>{'avatar_path': stalePath},
          ],
          'preferences': <String, Object?>{'user_avatar_path': stalePath},
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
      final message = (extracted.data['messages'] as List).single as Map;
      final restoredPath = message['image_path'] as String;
      expect(p.isWithin(destination.path, restoredPath), isTrue);
      expect(await File(restoredPath).readAsBytes(), <int>[4, 3, 2, 1]);
      expect(
        ((extracted.data['characters'] as List).single as Map)['avatar_path'],
        restoredPath,
      );
      expect(
        (extracted.data['preferences'] as Map)['user_avatar_path'],
        restoredPath,
      );
      final revision =
          (extracted.data['message_revisions'] as List).single as Map;
      final snapshot = jsonDecode(revision['snapshot_json'] as String) as Map;
      expect(snapshot['image_path'], restoredPath);
    },
  );

  test(
    'portable bundle includes relative legacy and all preset backgrounds',
    () async {
      final backgroundDirectory = await Directory(
        p.join(owned.path, 'background_images'),
      ).create(recursive: true);
      final activeChat = File(
        p.join(backgroundDirectory.path, 'bg_slot_1_chat_active.png'),
      );
      final inactiveHome = File(
        p.join(backgroundDirectory.path, 'bg_slot_2_home_saved.png'),
      );
      await activeChat.writeAsBytes(<int>[1, 3, 5, 7]);
      await inactiveHome.writeAsBytes(<int>[2, 4, 6, 8]);
      final database = File(p.join(root.path, 'yanci.db'));
      await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);
      final output = File(p.join(root.path, 'backgrounds.holt.zip'));
      final activeRelative = p.join(
        'background_images',
        p.basename(activeChat.path),
      );
      final inactiveRelative = p.join(
        'background_images',
        p.basename(inactiveHome.path),
      );

      await PortableBackupBundle.create(
        backupData: <String, Object?>{
          'preferences': <String, Object?>{
            'bg_image_chat_path': activeRelative,
            'background_preset_slot_1_v1': jsonEncode(<String, Object?>{
              'slot': 1,
              'home_path': '',
              'chat_path': activeRelative,
            }),
            'background_preset_slot_2_v1': jsonEncode(<String, Object?>{
              'slot': 2,
              'home_path': inactiveRelative,
              'chat_path': '',
            }),
          },
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
      final preferences = extracted.data['preferences'] as Map;
      final restoredActive = preferences['bg_image_chat_path'] as String;
      final slotOne =
          jsonDecode(preferences['background_preset_slot_1_v1'] as String)
              as Map;
      final slotTwo =
          jsonDecode(preferences['background_preset_slot_2_v1'] as String)
              as Map;

      expect(slotOne['chat_path'], restoredActive);
      expect(await File(restoredActive).readAsBytes(), <int>[1, 3, 5, 7]);
      expect(await File(slotTwo['home_path'] as String).readAsBytes(), <int>[
        2,
        4,
        6,
        8,
      ]);
    },
  );

  test('portable bundle rejects traversal in stale iOS media path', () async {
    final outside = File(p.join(root.path, 'outside.png'));
    await outside.writeAsBytes(<int>[9, 9, 9]);
    final database = File(p.join(root.path, 'yanci.db'));
    await database.writeAsBytes(<int>[83, 81, 76, 105, 116, 101]);
    const traversalPath =
        '/var/mobile/Containers/Data/Application/'
        '01234567-89AB-CDEF-0123-456789ABCDEF/'
        'Documents/../../../../../../outside.png';

    await expectLater(
      PortableBackupBundle.create(
        backupData: <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{
              'image_path': traversalPath,
              'image_paths_json': jsonEncode(<String>[traversalPath]),
            },
          ],
        },
        databaseSnapshot: database,
        ownedRoot: owned,
        workingRoot: working,
        outputFile: File(p.join(root.path, 'traversal_should_fail.holt.zip')),
      ),
      throwsA(isA<StateError>()),
    );
  });

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
