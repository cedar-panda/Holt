import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_yanci/services/background_image_path_service.dart';

void main() {
  test(
    'relinks an old iOS container path and stores a portable reference',
    () async {
      final root = await Directory.systemTemp.createTemp('holt-bg-path-');
      addTearDown(() => root.delete(recursive: true));
      final documents = p.join(root.path, 'Documents');
      final current = p.join(
        documents,
        'background_images',
        'bg_slot_2_chat_1790524211387.png',
      );
      await File(current).create(recursive: true);
      const previous =
          '/var/mobile/Containers/Data/Application/OLD/Documents/background_images/bg_slot_2_chat_1790524211387.png';

      expect(
        BackgroundImagePathService.resolveInDocuments(
          previous,
          documents,
          slot: 2,
          scope: 'chat',
        ),
        current,
      );
      final stored = BackgroundImagePathService.forStorageInDocuments(
        current,
        documents,
        slot: 2,
        scope: 'chat',
      );
      expect(stored, p.join('background_images', p.basename(current)));
      expect(
        BackgroundImagePathService.resolveInDocuments(
          stored,
          documents,
          slot: 2,
          scope: 'chat',
        ),
        current,
      );
    },
  );

  test(
    'never substitutes a different slot or overwrites a missing path',
    () async {
      final root = await Directory.systemTemp.createTemp('holt-bg-path-');
      addTearDown(() => root.delete(recursive: true));
      final documents = p.join(root.path, 'Documents');
      const previous =
          '/old/Documents/background_images/bg_slot_2_chat_123.png';
      await File(
        p.join(documents, 'background_images', 'bg_slot_2_chat_123.png'),
      ).create(recursive: true);

      expect(
        BackgroundImagePathService.resolveInDocuments(
          previous,
          documents,
          slot: 1,
          scope: 'chat',
        ),
        previous,
      );
      expect(
        BackgroundImagePathService.resolveInDocuments(
          previous,
          documents,
          slot: 2,
          scope: 'home',
        ),
        previous,
      );
      const missing =
          '/old/Documents/background_images/bg_slot_2_chat_missing.png';
      expect(
        BackgroundImagePathService.resolveInDocuments(
          missing,
          documents,
          slot: 2,
          scope: 'chat',
        ),
        missing,
      );
      expect(
        BackgroundImagePathService.forStorageInDocuments(
          missing,
          documents,
          slot: 2,
          scope: 'chat',
        ),
        missing,
      );
    },
  );
}
