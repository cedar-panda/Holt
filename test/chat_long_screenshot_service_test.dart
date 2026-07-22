import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:project_yanci/services/chat_long_screenshot_service.dart';

void main() {
  test('long screenshot stitch keeps chunk order and respects height cap', () {
    final first = img.Image(width: 4, height: 2, numChannels: 4);
    final second = img.Image(width: 4, height: 2, numChannels: 4);
    img.fill(first, color: img.ColorRgba8(255, 0, 0, 255));
    img.fill(second, color: img.ColorRgba8(0, 0, 255, 255));

    final result = stitchLongScreenshotChunksForTesting(<String, Object>{
      'chunks': <Uint8List>[
        Uint8List.fromList(img.encodePng(first)),
        Uint8List.fromList(img.encodePng(second)),
      ],
      'widths': <int>[4, 4],
      'heights': <int>[2, 2],
      'maxHeight': 2,
    });

    expect(result['width'], 2);
    expect(result['height'], 2);
    final stitched = img.decodePng(result['bytes']! as Uint8List)!;
    expect(stitched.getPixel(0, 0).r, 255);
    expect(stitched.getPixel(0, 0).b, 0);
    expect(stitched.getPixel(0, 1).r, 0);
    expect(stitched.getPixel(0, 1).b, 255);
  });
}
