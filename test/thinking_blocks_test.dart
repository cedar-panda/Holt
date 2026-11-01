import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/utils/split_reply_parser.dart';
import 'package:project_yanci/utils/thinking_blocks.dart';

void main() {
  group('collapseRepeatedThinking', () {
    test('leaves a single thinking block untouched', () {
      const raw = '<think>A</think>\n\n回覆';
      expect(collapseRepeatedThinking(raw), raw);
      expect(collapseRepeatedThinking('純文字'), '純文字');
      expect(collapseRepeatedThinking('<think>still'), '<think>still');
    });

    test('merges two rounds and keeps only the last reply', () {
      final out = collapseRepeatedThinking(
        '<think>A</think>\n\n回覆v1\n\n第二段<think>B</think>回覆v2',
      );
      expect(out, '<think>A\n\nB</think>\n\n回覆v2');
    });

    test('treats text before an orphan close tag as thinking', () {
      final out = collapseRepeatedThinking('想法尾巴。</think>"男老婆"是什麼鬼稱呼');
      expect(out, '<think>想法尾巴。</think>\n\n"男老婆"是什麼鬼稱呼');
    });

    test('keeps a still-open second round as unfinished thinking', () {
      final out = collapseRepeatedThinking('<think>A</think>v1<think>B');
      expect(out, '<think>A\n\nB');
    });

    test('falls back to the previous reply when the last round is empty', () {
      final out = collapseRepeatedThinking('<think>A</think>v1<think>B</think>');
      expect(out, '<think>A\n\nB</think>\n\nv1');
    });
  });

  test('split bubbles never show a raw closing tag', () {
    final parts = splitReplyParagraphs(
      '<think>A\n\nmore</think>\n\n一個單詞\n\n男老婆\n\n<think>B\n\nC</think>"男老婆"\n\n我是incubus',
    );
    expect(parts, hasLength(2));
    expect(parts.first, startsWith('<think>A'));
    expect(parts.first, endsWith('"男老婆"'));
    expect(parts.last, '我是incubus');
    expect(parts.join(), isNot(contains('一個單詞')));
  });

  test('finalOnly drops earlier reply versions and orphan thinking', () {
    expect(
      VisibleModelOutput.finalOnly('<think>A</think>v1<think>B</think>v2'),
      'v2',
    );
    expect(VisibleModelOutput.finalOnly('想法</think>正文'), '正文');
  });
}
