import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/utils/split_reply_parser.dart';

void main() {
  group('splitReplyParagraphs', () {
    test('keeps a closed thinking block with the first visible bubble', () {
      final parts = splitReplyParagraphs(
        '<think>internal\n\nreasoning</think>\n\n第一句\n\n第二句',
      );

      expect(parts, hasLength(2));
      expect(parts.first, startsWith('<think>internal'));
      expect(parts.first, endsWith('第一句'));
      expect(parts.last, '第二句');
    });

    test('does not split an unfinished thinking block', () {
      expect(splitReplyParagraphs('<think>still\n\nworking'), [
        '<think>still\n\nworking',
      ]);
    });

    test('uses single newlines only for short plain chat lines', () {
      expect(splitReplyParagraphs('嗯\n我知道了\n等我一下'), ['嗯', '我知道了', '等我一下']);
      expect(splitReplyParagraphs('- 第一項\n- 第二項'), ['- 第一項\n- 第二項']);
    });
  });
}
