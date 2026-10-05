import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/models/background_preset.dart';
import 'package:project_yanci/services/background_preset_service.dart';
import 'package:project_yanci/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy background migrates once into slot 1', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'bg_image_home_path': '/legacy/home.jpg',
      'bg_image_home_scale': 1.25,
      'bg_image_home_offset_x': 0.12,
      'bg_image_home_offset_y': -0.08,
      'bg_image_home_blur': 6.0,
      'bg_image_chat_path': '/legacy/chat.jpg',
      'bg_image_chat_scale': 1.4,
      'bg_image_chat_offset_x': -0.2,
      'bg_image_chat_offset_y': 0.16,
      'bg_image_chat_blur': 9.0,
      'bg_image_chat_ai_bubble_color': 0xFF112233,
      'bg_image_chat_bubble_opacity': 0.65,
    });

    final migrated = await BackgroundPresetService.loadSlot(1);

    expect(migrated.homePath, '/legacy/home.jpg');
    expect(migrated.homeScale, 1.25);
    expect(migrated.homeBlur, 6.0);
    expect(migrated.chatPath, '/legacy/chat.jpg');
    expect(migrated.chatBlur, 9.0);
    expect(migrated.chatAiBubbleColor, 0xFF112233);
    expect(migrated.chatBubbleOpacity, 0.65);

    await BackgroundPresetService.saveAndActivate(
      const BackgroundPreset(slot: 1, chatPath: '/new/chat.jpg'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_image_chat_path', '/legacy/changed-later.jpg');

    expect(
      (await BackgroundPresetService.loadSlot(1)).chatPath,
      '/new/chat.jpg',
      reason: 'legacy keys must not overwrite the six-slot store again',
    );
  });

  test(
    'six slots stay separate and character binding is per character',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await BackgroundPresetService.saveAndActivate(
        const BackgroundPreset(
          slot: 2,
          homePath: '/sets/two-home.jpg',
          chatPath: '/sets/two-chat.jpg',
          chatScale: 1.3,
          homeBlur: 4,
          chatBlur: 11,
          chatAiBubbleColor: 0xFF445566,
        ),
      );
      await BackgroundPresetService.saveAndActivate(
        const BackgroundPreset(
          slot: 6,
          chatPath: '/sets/six-chat.jpg',
          chatOffsetY: 0.2,
        ),
      );

      expect(await BackgroundPresetService.getActiveSlot(), 6);
      expect(
        (await BackgroundPresetService.loadSlot(2)).chatPath,
        '/sets/two-chat.jpg',
      );
      expect(
        (await BackgroundPresetService.loadSlot(6)).chatPath,
        '/sets/six-chat.jpg',
      );
      expect(YanciTheme.chatBackgroundImagePath, '/sets/six-chat.jpg');

      await BackgroundPresetService.setCharacterBinding('char-a', 2);
      await BackgroundPresetService.setCharacterBinding('char-b', 6);

      expect(
        (await BackgroundPresetService.boundPresetForCharacter(
          'char-a',
        ))?.chatPath,
        '/sets/two-chat.jpg',
      );
      expect(
        (await BackgroundPresetService.boundPresetForCharacter(
          'char-a',
        ))?.chatBlur,
        11,
      );
      expect(
        (await BackgroundPresetService.boundPresetForCharacter(
          'char-b',
        ))?.chatPath,
        '/sets/six-chat.jpg',
      );
      expect(
        await BackgroundPresetService.boundPresetForCharacter('char-c'),
        isNull,
      );

      await BackgroundPresetService.setCharacterBinding('char-a', null);
      expect(
        await BackgroundPresetService.boundPresetForCharacter('char-a'),
        isNull,
      );
    },
  );

  test('editing a bound set publishes refresh and keeps the binding', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await BackgroundPresetService.saveAndActivate(
      const BackgroundPreset(slot: 3, homeBlur: 2, chatBlur: 4),
    );
    await BackgroundPresetService.setCharacterBinding('char-bound', 3);
    final before = BackgroundPresetService.revision.value;

    await BackgroundPresetService.saveAndActivate(
      const BackgroundPreset(slot: 3, homeBlur: 8, chatBlur: 12),
    );

    expect(BackgroundPresetService.revision.value, greaterThan(before));
    expect(
      await BackgroundPresetService.getCharacterBindings(),
      containsPair('char-bound', 3),
    );
    final refreshed = await BackgroundPresetService.boundPresetForCharacter(
      'char-bound',
    );
    expect(refreshed?.homeBlur, 8);
    expect(refreshed?.chatBlur, 12);
  });

  test(
    'invalid image clears stale auto palette without removing manual colors',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final originalManual = YanciTheme.chatBackgroundAiBubbleOverride;
      YanciTheme.chatBackgroundAutoAiBubble = const Color(0xFF123456);
      YanciTheme.chatBackgroundAutoInputBarText = const Color(0xFF654321);
      addTearDown(() {
        YanciTheme.chatBackgroundAutoAiBubble = null;
        YanciTheme.chatBackgroundAutoInputBarText = null;
        YanciTheme.chatBackgroundAiBubbleOverride = originalManual;
      });

      await BackgroundPresetService.saveAndActivate(
        const BackgroundPreset(
          slot: 3,
          chatPath: '/missing/holt-image-does-not-exist.png',
          chatAiBubbleColor: 0xFFABCDEF,
        ),
      );
      expect(YanciTheme.chatBackgroundAutoAiBubble, isNull);
      expect(YanciTheme.chatBackgroundAutoInputBarText, isNull);
      expect(
        YanciTheme.chatBackgroundAiBubbleOverride,
        const Color(0xFFABCDEF),
      );
    },
  );

  test('existing iOS slots survive a changed data-container UUID', () async {
    final root = await Directory.systemTemp.createTemp('holt-bg-slots-');
    final documents = Directory(p.join(root.path, 'Documents'))..createSync();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documents.path;
          }
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });

    const oldRoot = '/var/mobile/Containers/Data/Application/OLD/Documents';
    final firstHome = p.join(
      documents.path,
      'background_images',
      'bg_slot_1_home_100.png',
    );
    final secondChat = p.join(
      documents.path,
      'background_images',
      'bg_slot_2_chat_200.png',
    );
    await File(firstHome).create(recursive: true);
    await File(secondChat).create(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'background_presets_schema_v1': 1,
      'background_presets_active_slot_v1': 1,
      'background_preset_slot_1_v1': jsonEncode(
        const BackgroundPreset(
          slot: 1,
          homePath: '$oldRoot/background_images/bg_slot_1_home_100.png',
          homeScale: 1.4,
        ).toJson(),
      ),
      'background_preset_slot_2_v1': jsonEncode(
        const BackgroundPreset(
          slot: 2,
          chatPath: '$oldRoot/background_images/bg_slot_2_chat_200.png',
          chatOffsetY: 0.2,
        ).toJson(),
      ),
      'background_preset_bindings_v1': jsonEncode(<String, int>{'char-a': 2}),
    });

    final first = await BackgroundPresetService.loadActiveIntoTheme();
    final second = await BackgroundPresetService.boundPresetForCharacter(
      'char-a',
    );
    expect(first.homePath, firstHome);
    expect(first.homeScale, 1.4);
    expect(second?.chatPath, secondChat);
    expect(second?.chatOffsetY, 0.2);
    final prefs = await SharedPreferences.getInstance();
    final storedFirst =
        jsonDecode(prefs.getString('background_preset_slot_1_v1')!)
            as Map<String, dynamic>;
    final storedSecond =
        jsonDecode(prefs.getString('background_preset_slot_2_v1')!)
            as Map<String, dynamic>;
    expect(
      storedFirst['home_path'],
      p.join('background_images', p.basename(firstHome)),
    );
    expect(
      storedSecond['chat_path'],
      p.join('background_images', p.basename(secondChat)),
    );
    expect(File(firstHome).existsSync(), isTrue);
    expect(File(secondChat).existsSync(), isTrue);
  });
}
