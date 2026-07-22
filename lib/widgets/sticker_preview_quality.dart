import 'package:flutter/widgets.dart';

/// 表情包只調整本地解碼尺寸，不重寫原檔，也不改送往 Vision API 的圖片。
class StickerPreviewQuality {
  static const int maxCacheDimension = 384;

  static int cacheDimension(
    BuildContext context, {
    required double logicalSize,
    required int previousMinimum,
  }) {
    return cacheDimensionFor(
      logicalSize: logicalSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      previousMinimum: previousMinimum,
    );
  }

  @visibleForTesting
  static int cacheDimensionFor({
    required double logicalSize,
    required double devicePixelRatio,
    required int previousMinimum,
  }) {
    final safeMinimum = previousMinimum.clamp(1, maxCacheDimension);
    final safeLogicalSize = logicalSize.isFinite && logicalSize > 0
        ? logicalSize
        : safeMinimum.toDouble();
    final safePixelRatio = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    final target = (safeLogicalSize * safePixelRatio).ceil();
    return target.clamp(safeMinimum, maxCacheDimension);
  }
}
