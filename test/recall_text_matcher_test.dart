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
}
