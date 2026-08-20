import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/sticker_service.dart';

void main() {
  group('StickerService.parseResponse', () {
    test('oversized sticker id never throws and stays plain text', () {
      const response = '看這個 [sticker:99999999999999999999] 好笑吧';

      final segments = StickerService.parseResponse(response);

      expect(segments.whereType<StickerSegment>(), isEmpty);
      expect(segments, hasLength(1));
      expect((segments.single as TextSegment).text, response);
    });

    test('valid id survives alongside an oversized id', () {
      const response = '前面 [sticker:7] 中間 [sticker:99999999999999999999] 後面';

      final segments = StickerService.parseResponse(response);

      final stickers = segments.whereType<StickerSegment>().toList();
      expect(stickers, hasLength(1));
      expect(stickers.single.stickerId, 7);

      final text = segments
          .whereType<TextSegment>()
          .map((segment) => segment.text)
          .join();
      expect(text, contains('[sticker:99999999999999999999]'));
      expect(text, isNot(contains('[sticker:7]')));
    });

    test('plain text, ID variant and consecutive stickers are unchanged', () {
      final plain = StickerService.parseResponse('沒有貼圖');
      expect(plain, hasLength(1));
      expect((plain.single as TextSegment).text, '沒有貼圖');

      final variant = StickerService.parseResponse('a[sticker:ID:12]b');
      expect(variant, hasLength(3));
      expect((variant[0] as TextSegment).text, 'a');
      expect((variant[1] as StickerSegment).stickerId, 12);
      expect((variant[2] as TextSegment).text, 'b');

      final consecutive = StickerService.parseResponse(
        '[sticker:1][sticker:2]',
      );
      expect(consecutive, hasLength(2));
      expect(consecutive.whereType<StickerSegment>().map((s) => s.stickerId), [
        1,
        2,
      ]);
    });

    test('largest parseable id is still treated as a sticker', () {
      final segments = StickerService.parseResponse(
        '[sticker:9223372036854775807]',
      );

      expect(segments, hasLength(1));
      expect(
        (segments.single as StickerSegment).stickerId,
        9223372036854775807,
      );
    });
  });
}
