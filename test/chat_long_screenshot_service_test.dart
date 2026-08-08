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
    expect(result['downscaled'], isTrue);
    final stitched = img.decodePng(result['bytes']! as Uint8List)!;
    expect(stitched.getPixel(0, 0).r, 255);
    expect(stitched.getPixel(0, 0).b, 0);
    expect(stitched.getPixel(0, 1).r, 0);
    expect(stitched.getPixel(0, 1).b, 255);
  });

  test('selected range under the height cap keeps native pixels', () {
    final source = img.Image(width: 6, height: 4, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(32, 64, 128, 255));

    final result = stitchLongScreenshotChunksForTesting(<String, Object>{
      'chunks': <Uint8List>[Uint8List.fromList(img.encodePng(source))],
      'widths': <int>[6],
      'heights': <int>[4],
      'maxHeight': 20,
    });

    expect(result['width'], 6);
    expect(result['height'], 4);
    expect(result['downscaled'], isFalse);
    final stitched = img.decodePng(result['bytes']! as Uint8List)!;
    expect(stitched.getPixel(5, 3).r, 32);
    expect(stitched.getPixel(5, 3).g, 64);
    expect(stitched.getPixel(5, 3).b, 128);
  });

  test('small selections supersample while long captures stay bounded', () {
    expect(
      resolveLongScreenshotPixelRatioForTesting(
        devicePixelRatio: 2.625,
        selectionCount: 1,
      ),
      3.5,
    );
    expect(
      resolveLongScreenshotPixelRatioForTesting(
        devicePixelRatio: 2.625,
        selectionCount: 4,
      ),
      3.5,
    );
    expect(
      resolveLongScreenshotPixelRatioForTesting(
        devicePixelRatio: 2.625,
        selectionCount: 5,
      ),
      2.625,
    );
    expect(
      resolveLongScreenshotPixelRatioForTesting(
        devicePixelRatio: 1,
        selectionCount: 5,
      ),
      2,
    );
    expect(
      resolveLongScreenshotPixelRatioForTesting(
        devicePixelRatio: 3,
        selectionCount: 1,
        requestedPixelRatio: 2,
      ),
      2,
    );
  });
}
