import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/recall_text_matcher.dart';

void main() {
  test('recall is insensitive to case, full-width forms, and punctuation', () {
    expect(
      RecallTextMatcher.bestKeywordMatch('最近又在用ＧＰＴ－５', 'gpt-5')?.keyword,
      'gpt-5',
    );
    expect(
      RecallTextMatcher.bestKeywordMatch('說起那間小橘貓咖啡店', '小橘貓')?.keyword,
      '小橘貓',
    );
  });

  test(
    'stored aliases and additional separators are independently recalled',
    () {
      final match = RecallTextMatcher.bestKeywordMatch(
        'GPT 最近換了摘要格式',
        'g哥=GPT；clawd／小章魚',
      );
      expect(match?.keyword.toLowerCase(), 'gpt');
    },
  );

  test('short generic latin fragments do not trigger memories', () {
    expect(RecallTextMatcher.bestKeywordMatch('today is nice', 'is'), isNull);
  });

  test('batch matching preserves single-row scoring and order', () {
    const query = '想起渡口交換青鸞印信，之後去書院會合';
    const rows = <String>[
      '渡口交換信物, 青鸞印信交付',
      '翌日書院會合',
      '完全無關事件',
    ];

    final batch = RecallTextMatcher.bestKeywordMatches(query, rows);

    expect(batch, hasLength(rows.length));
    for (var index = 0; index < rows.length; index++) {
      final single = RecallTextMatcher.bestKeywordMatch(query, rows[index]);
      expect(batch[index]?.keyword, single?.keyword);
      expect(batch[index]?.score, single?.score);
    }
  });
}
