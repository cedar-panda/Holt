import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/conversation_time_context.dart';

void main() {
  group('daily conversation gap prompt', () {
    final previous = DateTime(2026, 10, 30, 12);

    test('stays empty before five minutes', () {
      expect(
        ConversationTimeContext.buildGapPrompt(
          previousMessageAt: previous,
          currentMessageAt: previous.add(
            const Duration(minutes: 4, seconds: 59),
          ),
          locale: 'zh_TW',
        ),
        isEmpty,
      );
    });

    test('appears at five minutes without asking the model to report time', () {
      final prompt = ConversationTimeContext.buildGapPrompt(
        previousMessageAt: previous,
        currentMessageAt: previous.add(const Duration(minutes: 5)),
        locale: 'zh_TW',
      );

      expect(prompt, contains('距離上一條可見消息約5 分鐘'));
      expect(prompt, contains('無需刻意報時'));
    });

    test('uses compact hour and minute wording', () {
      final prompt = ConversationTimeContext.buildGapPrompt(
        previousMessageAt: previous,
        currentMessageAt: previous.add(const Duration(hours: 2, minutes: 7)),
        locale: 'zh_CN',
      );

      expect(prompt, contains('2 小时 7 分钟'));
    });

    test('ignores reversed timestamps', () {
      expect(
        ConversationTimeContext.buildGapPrompt(
          previousMessageAt: previous,
          currentMessageAt: previous.subtract(const Duration(minutes: 10)),
          locale: 'en',
        ),
        isEmpty,
      );
    });

    test('stays in request-only live state instead of the cache prefix', () {
      final gap = ConversationTimeContext.buildGapPrompt(
        previousMessageAt: previous,
        currentMessageAt: previous.add(const Duration(minutes: 8)),
        locale: 'zh_TW',
      );
      final prompt = StructuredPrompt(
        staticPart: 'stable character prefix',
        liveStatePart: gap,
      );

      expect(prompt.cacheableParts.join('\n'), isNot(contains('對話間隔')));
      expect(prompt.requestOnlyPart, contains('距離上一條可見消息'));
    });
  });

  group('absolute search timestamp', () {
    final thursday = DateTime(2026, 10, 29, 23, 52);

    test('traditional Chinese includes year, weekday, and time', () {
      expect(
        ConversationTimeContext.formatAbsoluteTimestamp(
          thursday,
          locale: 'zh_TW',
        ),
        '2026/10/29 週四 23:52',
      );
    });

    test('simplified Chinese includes year, weekday, and time', () {
      expect(
        ConversationTimeContext.formatAbsoluteTimestamp(
          thursday,
          locale: 'zh_CN',
        ),
        '2026/10/29 周四 23:52',
      );
    });

    test('English includes year, weekday, and time', () {
      expect(
        ConversationTimeContext.formatAbsoluteTimestamp(thursday, locale: 'en'),
        '2026/10/29 Thursday 23:52',
      );
    });
  });
}
