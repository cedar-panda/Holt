import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/character_timeline_service.dart';
import 'package:project_yanci/services/context_compressor.dart';
import 'package:project_yanci/services/manual_summary_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message message(int id, String text) => Message(
    id: id,
    conversationId: 'conv-a',
    characterId: 'char-a',
    text: text,
    isUser: id.isOdd,
    createdAt: DateTime(2026, 7, 18, 20, id),
  );

  test('token boundary includes the crossing bubble in full', () {
    final first = message(1, List.filled(5800, '甲').join());
    final crossing = message(2, List.filled(700, '乙').join());
    final later = message(3, List.filled(100, '丙').join());

    final selected = ContextCompressor.selectWholeBubbleBatch([
      first,
      crossing,
      later,
    ], 6000);

    expect(selected.map((item) => item.id), [1, 2]);
    expect(selected.last.text, crossing.text);
    expect(selected.last.text.length, 700);
  });

  test('valid JSON separates summary text from timeline candidates', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting('''
{"summary":"兩人回顧前一天的電影。","timeline":[{"type":"event","subject":"relationship","source_message_ids":[12,11,12],"occurred_on":"2026-07-17","date_basis":"relative","value":"兩人一起看電影","evidence":"昨天我們去看了電影"}]}
''');

    expect(decoded['summary'], '兩人回顧前一天的電影。');
    final timeline = decoded['timeline']! as List<TimelineEventCandidate>;
    expect(timeline, hasLength(1));
    expect(timeline.single.sourceMessageIds, [11, 12]);
    expect(timeline.single.occurredOn, '2026-07-17');
    expect(timeline.single.subject, 'relationship');
    expect(timeline.single.type, 'event');
  });

  test('valid state JSON keeps subject and state key', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting('''
{"summary":"晏辭處於生理期。","timeline":[{"type":"state","subject":"character","source_message_ids":[21],"occurred_on":"2026-07-17","date_basis":"relative","key":"生理週期","value":"晏辭處於生理期第二天","evidence":"你昨天是生理期第二天"}]}
''');

    final timeline = decoded['timeline']! as List<TimelineEventCandidate>;
    expect(timeline, hasLength(1));
    expect(timeline.single.type, 'state');
    expect(timeline.single.subject, 'character');
    expect(timeline.single.key, '生理週期');
  });

  test('wrapped JSON and numeric string ids keep timeline candidates', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting('''
以下是結果：
{"summary":"晏辭的生理期已結束。","timeline":[{"type":"event","subject":"character","source_message_ids":["21"],"occurred_on":"2026-07-22","date_basis":"explicit","value":"生理期結束","evidence":"生理期已於2026-07-22結束"}]}
以上。
''');

    expect(decoded['summary'], '晏辭的生理期已結束。');
    final timeline = decoded['timeline']! as List<TimelineEventCandidate>;
    expect(timeline, hasLength(1));
    expect(timeline.single.sourceMessageIds, [21]);
    expect(timeline.single.value, '生理期結束');
  });

  test('timeline candidate without an owner is not accepted', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting('''
{"summary":"保留摘要。","timeline":[{"type":"event","source_message_ids":[1],"occurred_on":"2026-07-18","date_basis":"message_time","value":"稱呼大小姐","evidence":"我稱呼她為大小姐"}]}
''');

    expect(decoded['summary'], '保留摘要。');
    expect(decoded['timeline'], isEmpty);
  });

  test('malformed JSON may recover summary but never guesses timeline', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting(
      '{"summary":"保留這段摘要","timeline":[',
    );

    expect(decoded['summary'], '保留這段摘要');
    expect(decoded['timeline'], isEmpty);
  });

  test('plain model output remains a summary-only fallback', () {
    final decoded = ContextCompressor.decodeCompressionResponseForTesting(
      '這是一段舊模型格式的純文字摘要。',
    );

    expect(decoded['summary'], '這是一段舊模型格式的純文字摘要。');
    expect(decoded['timeline'], isEmpty);
  });

  test(
    'manual summary source keeps real ids, local dates and speaker roles',
    () {
      final excerpt = ManualSummaryService.buildDatedExcerpt([
        message(31, '你今天還是生理期。'),
        message(32, '嗯，還有一點不舒服。'),
      ]);

      expect(
        excerpt,
        contains('[msg:31 | local_time:2026-07-18 20:31 | speaker:user]'),
      );
      expect(
        excerpt,
        contains('[msg:32 | local_time:2026-07-18 20:32 | speaker:char]'),
      );
      expect(excerpt, contains('你今天還是生理期。'));
    },
  );

  test(
    'explicit period status requests recovery when first result omitted it',
    () {
      expect(
        ContextCompressor.needsMenstrualRecoveryForTesting(
          messages: [message(41, '你昨天是生理期第二天。')],
          candidates: const [],
        ),
        isTrue,
      );
      expect(
        ContextCompressor.needsMenstrualRecoveryForTesting(
          messages: [message(43, '你今天還是生理期。')],
          candidates: const [],
        ),
        isTrue,
      );
    },
  );

  test('period discussion alone does not request timeline recovery', () {
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(51, '生理期通常會持續幾天？')],
        candidates: const [],
      ),
      isFalse,
    );
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(53, '你今天還是生理期嗎？')],
        candidates: const [],
      ),
      isFalse,
    );
  });

  test('existing menstrual candidate suppresses the recovery request', () {
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(61, '你今天還是生理期。')],
        candidates: const [
          TimelineEventCandidate(
            type: 'state',
            subject: 'character',
            sourceMessageIds: [61],
            occurredOn: '2026-07-18',
            dateBasis: 'message_time',
            key: '生理週期',
            value: '生理期中',
            evidence: '你今天還是生理期',
          ),
        ],
      ),
      isFalse,
    );
  });

  test('menstrual recovery only considers character-owned statements', () {
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(71, '我今天生理期第二天。')],
        candidates: const [],
      ),
      isFalse,
    );
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(73, '你記得嗎，我今天生理期第一天。')],
        candidates: const [],
      ),
      isFalse,
    );
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(72, '我今天生理期第二天。')],
        candidates: const [],
      ),
      isTrue,
    );
    expect(
      ContextCompressor.needsMenstrualRecoveryForTesting(
        messages: [message(74, '你今天生理期第二天。')],
        candidates: const [],
      ),
      isFalse,
    );
  });
}
