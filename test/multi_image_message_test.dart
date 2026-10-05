import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/api_adapter.dart';

void main() {
  test('message round-trip keeps a deduplicated multi-image list', () {
    final message = Message(
      conversationId: 'conversation',
      text: '看這幾張',
      isUser: true,
      imagePaths: const <String>['/tmp/a.png', '/tmp/a.png', '/tmp/b.png'],
    );

    final restored = Message.fromMap(
      Map<String, dynamic>.from(message.toMap()),
    );

    expect(restored.imagePaths, <String>['/tmp/a.png', '/tmp/b.png']);
    expect(restored.imagePath, '/tmp/a.png');
  });

  test(
    'adapter media metadata reads multiple data URLs and legacy fallback',
    () {
      const first = 'data:image/png;base64,AAA';
      const second = 'data:image/jpeg;base64,BBB';
      expect(
        ApiMessageMedia.imageDataUrls(<String, String>{
          'image_data_urls': jsonEncode(<String>[first, second]),
          'image_data_url': first,
        }),
        <String>[first, second],
      );
      expect(
        ApiMessageMedia.imageDataUrls(<String, String>{
          'image_data_url': first,
        }),
        <String>[first],
      );
    },
  );
}
