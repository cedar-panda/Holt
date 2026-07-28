import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/call_prompt_composer.dart';

void main() {
  test('keeps runtime call instructions out of the user message', () {
    final payload = CallPromptComposer.compose(
      history: const [
        {'role': 'user', 'content': '你現在方便講電話嗎？'},
      ],
      dynamicParts: const ['【記憶】剛才正在討論晚餐。'],
      now: DateTime(2026, 7, 28, 13, 5),
      allowAudioTags: false,
    );

    expect(payload.messages, const [
      {'role': 'user', 'content': '你現在方便講電話嗎？'},
    ]);
    expect(payload.messages.single['content'], isNot(contains('系統提示')));
    expect(payload.messages.single['content'], isNot(contains('<hangup/>')));
    expect(payload.dynamicPart, contains('【系統提示】'));
    expect(payload.dynamicPart, contains('<hangup/>'));
    expect(payload.dynamicPart, contains('「（撥打電話給你）」表示對方正在打給你'));
    expect(payload.dynamicPart, contains('「（接聽電話）」表示對方已接聽'));
  });

  test('uses a user action only when the message history is empty', () {
    final payload = CallPromptComposer.compose(
      history: const [],
      dynamicParts: const [],
      now: DateTime(2026, 7, 28, 13, 5),
      allowAudioTags: true,
    );

    expect(payload.messages, const [
      {'role': 'user', 'content': '（開始通話）'},
    ]);
    expect(payload.dynamicPart, contains('[laughing]'));
  });
}
