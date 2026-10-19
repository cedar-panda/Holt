import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/model_action_protocol.dart';
import 'package:project_yanci/services/tool_runner.dart';

void main() {
  test('JSON memory action normalizes to existing processor protocol', () {
    const raw = '''正文
[[HOLT_ACTIONS]]
{"actions":[{"type":"memory.propose","arguments":{"category":"關係","content":"兩人約定同行","triggers":["同行","約定"]}}]}
[[/HOLT_ACTIONS]]''';

    expect(
      ModelActionProtocol.normalizeForLegacyProcessors(raw),
      '正文\n<memo>[關係] 兩人約定同行 @同行,約定</memo>',
    );
  });

  test('malformed JSON action fails closed while prose survives', () {
    const raw = '''正文
[[HOLT_ACTIONS]]
{not-json}
[[/HOLT_ACTIONS]]''';

    expect(ModelActionProtocol.normalizeForLegacyProcessors(raw), '正文');
  });

  test('native tool calls enter the same normalization path', () {
    final call = ToolCall(
      id: 'call_1',
      name: 'whisper.set',
      arguments: const <String, Object?>{'content': '我在這裡'},
    );

    expect(
      ModelActionProtocol.normalizeForLegacyProcessors('', toolCalls: [call]),
      '<whisper>我在這裡</whisper>',
    );
  });

  test('diary action preserves title and body through XML compatibility', () {
    final call = ToolCall(
      id: 'call_diary',
      name: 'diary.write',
      arguments: const <String, Object?>{
        'title': '秋夜 <一>',
        'body': '今天與小禾聊了很久 & 很安心。',
      },
    );

    expect(
      ModelActionProtocol.normalizeForLegacyProcessors('', toolCalls: [call]),
      '<holt_diary version="1"><title>秋夜 &lt;一&gt;</title>'
      '<body>今天與小禾聊了很久 &amp; 很安心。</body></holt_diary>',
    );
  });

  test('call controls share the normalized action path', () {
    final calls = <ToolCall>[
      ToolCall(
        id: 'call_1',
        name: 'call.decline',
        arguments: const <String, Object?>{},
      ),
      ToolCall(
        id: 'call_2',
        name: 'call.hangup',
        arguments: const <String, Object?>{},
      ),
    ];

    expect(
      ModelActionProtocol.normalizeForLegacyProcessors('', toolCalls: calls),
      '<decline_call/>\n<hangup/>',
    );
  });

  test('emotion JSON action reaches the legacy emotion processor', () {
    const raw = '''想就這樣聽著你的聲音睡。
[[HOLT_ACTIONS]]
{"actions":[{"type":"emotion.record","arguments":{"dimension":"愜意","intensity":45,"x":60,"y":-20,"note":""}}]}
[[/HOLT_ACTIONS]]''';

    expect(
      ModelActionProtocol.normalizeForLegacyProcessors(raw),
      '想就這樣聽著你的聲音睡。\n<emo>愜意|60,-20|45|</emo>',
    );
  });

  test('legacy XML remains unchanged as fallback', () {
    const raw = '正文\n<memo>[事件] 已發生 @事件</memo>';
    expect(ModelActionProtocol.normalizeForLegacyProcessors(raw), raw);
  });
}
