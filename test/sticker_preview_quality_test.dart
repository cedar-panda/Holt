import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/widgets/sticker_preview_quality.dart';

void main() {
  test('sticker previews follow device pixel ratio', () {
    expect(
      StickerPreviewQuality.cacheDimensionFor(
        logicalSize: 100,
        devicePixelRatio: 3,
        previousMinimum: 128,
      ),
      300,
    );
    expect(
      StickerPreviewQuality.cacheDimensionFor(
        logicalSize: 120,
        devicePixelRatio: 3,
        previousMinimum: 160,
      ),
      360,
    );
  });

  test('sticker previews preserve old minimum and cap memory use', () {
    expect(
      StickerPreviewQuality.cacheDimensionFor(
        logicalSize: 48,
        devicePixelRatio: 1,
        previousMinimum: 64,
      ),
      64,
    );
    expect(
      StickerPreviewQuality.cacheDimensionFor(
        logicalSize: 120,
        devicePixelRatio: 4,
        previousMinimum: 160,
      ),
      StickerPreviewQuality.maxCacheDimension,
    );
  });
}
