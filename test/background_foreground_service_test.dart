import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:project_yanci/services/background_foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double contrast(Color a, Color b) {
    final aLum = a.computeLuminance();
    final bLum = b.computeLuminance();
    final lighter = aLum > bLum ? aLum : bLum;
    final darker = aLum > bLum ? bLum : aLum;
    return (lighter + 0.05) / (darker + 0.05);
  }

  Future<File> solidImage(
    Directory directory,
    String name, {
    required int red,
    required int green,
    required int blue,
  }) async {
    final image = img.Image(width: 12, height: 12);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, red, green, blue, 255);
      }
    }
    final file = File('${directory.path}/$name.png');
    await file.writeAsBytes(img.encodePng(image));
    return file;
  }

  test(
    'derives readable tinted foregrounds from dark and light images',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'holt-background-palette-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final dark = await solidImage(
        directory,
        'dark',
        red: 28,
        green: 42,
        blue: 74,
      );
      final light = await solidImage(
        directory,
        'light',
        red: 238,
        green: 222,
        blue: 176,
      );

      final darkPalette = await BackgroundForegroundService.resolve(dark.path);
      final lightPalette = await BackgroundForegroundService.resolve(
        light.path,
      );

      expect(darkPalette, isNotNull);
      expect(lightPalette, isNotNull);
      expect(darkPalette!.primary.computeLuminance(), greaterThan(0.7));
      expect(lightPalette!.primary.computeLuminance(), lessThan(0.15));
      expect(
        contrast(darkPalette.primary, darkPalette.dominant),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(lightPalette.primary, lightPalette.dominant),
        greaterThanOrEqualTo(4.5),
      );
    },
  );

  test('deleted image does not reuse its cached chat palette', () async {
    final directory = await Directory.systemTemp.createTemp(
      'holt-deleted-chat-palette-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = await solidImage(
      directory,
      'chat',
      red: 30,
      green: 40,
      blue: 70,
    );
    expect(
      await BackgroundForegroundService.resolveChatBubblePalette(image.path),
      isNotNull,
    );
    await image.delete();
    expect(
      await BackgroundForegroundService.resolveChatBubblePalette(image.path),
      isNull,
    );
    expect(
      BackgroundForegroundService.cachedChatBubblePalette(image.path),
      isNull,
    );
  });
}
