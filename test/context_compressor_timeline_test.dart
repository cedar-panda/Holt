import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/character_timeline_service.dart';
import 'package:project_yanci/services/context_compressor.dart';

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
}
