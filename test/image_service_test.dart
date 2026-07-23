import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:project_yanci/services/image_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('yanci_image_service_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('uses JPEG MIME when Android keeps a PNG file name', () async {
    final jpegBytes = img.encodeJpg(img.Image(width: 4, height: 4));
    final disguisedPng = File('${tempDir.path}/picked_image.png');
    await disguisedPng.writeAsBytes(jpegBytes);

    final firstAttempt = await ImageService.toBase64DataUrl(disguisedPng.path);
    final retryAttempt = await ImageService.toBase64DataUrl(disguisedPng.path);

    expect(firstAttempt, startsWith('data:image/jpeg;base64,'));
    expect(retryAttempt, startsWith('data:image/jpeg;base64,'));
    expect(
      base64Decode(firstAttempt!.split(',').last),
      orderedEquals(jpegBytes),
    );
  });

  test('keeps a genuine PNG as PNG regardless of its file name', () async {
    final pngImage = img.Image(width: 4, height: 4, numChannels: 4);
    final pngBytes = img.encodePng(pngImage);
    final misleadingName = File('${tempDir.path}/transparent_photo.jpg');
    await misleadingName.writeAsBytes(pngBytes);

    final dataUrl = await ImageService.toBase64DataUrl(misleadingName.path);

    expect(dataUrl, startsWith('data:image/png;base64,'));
    expect(base64Decode(dataUrl!.split(',').last), orderedEquals(pngBytes));
  });

  test('rejects undecodable bytes before an API request is built', () async {
    final invalidImage = File('${tempDir.path}/broken.png');
    await invalidImage.writeAsBytes(const [1, 2, 3, 4, 5]);

    expect(
      () => ImageService.toBase64DataUrl(invalidImage.path),
      throwsA(isA<FormatException>()),
    );
  });
}
