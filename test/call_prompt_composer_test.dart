import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/call_prompt_composer.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(const {'app_locale': 'zh_TW'});
    await L.load();
  });

  test('keeps runtime call instructions out of the user message', () {
    final payload = CallPromptComposer.compose(
      history: const [
        {'role': 'user', 'content': '你現在方便講電話嗎？'},
      ],
      dynamicParts: const ['【記憶】剛才正在討論晚餐。'],
      now: DateTime(2026, 7, 28, 13, 5),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(payload.messages, const [
      {'role': 'user', 'content': '你現在方便講電話嗎？'},
    ]);
    expect(payload.messages.single['content'], isNot(contains('系統提示')));
    expect(payload.messages.single['content'], isNot(contains('<hangup/>')));
    expect(payload.controlPart, contains('語音通話模式'));
    expect(payload.controlPart, contains('<hangup/>'));
    expect(payload.controlPart, contains('林澈'));
    expect(payload.controlPart, contains('昭昭'));
    expect(payload.controlPart, contains('至少輸出一句'));
    expect(payload.controlPart, isNot(contains('不要 markdown')));
    expect(
      payload.controlPart,
      contains(CallPromptComposer.dialToCharacterAction),
    );
    expect(
      payload.controlPart,
      contains(CallPromptComposer.acceptCharacterCallAction),
    );
  });

  test('uses a user action only when the message history is empty', () {
    final payload = CallPromptComposer.compose(
      history: const [],
      dynamicParts: const [],
      now: DateTime(2026, 7, 28, 13, 5),
      allowAudioTags: true,
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(payload.messages, const [
      {'role': 'user', 'content': '（開始通話）'},
    ]);
    expect(payload.controlPart, contains('[laughing]'));
    expect(payload.liveStatePart, contains('13:05'));
    expect(payload.liveStatePart, contains('00:00'));
  });

  test('call duration is exact and request-only', () {
    final payload = CallPromptComposer.compose(
      history: const [
        {'role': 'user', 'content': '剛才說到哪裡？'},
      ],
      dynamicParts: const [],
      now: DateTime(2026, 10, 30, 13, 5),
      callElapsed: const Duration(seconds: 31),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(payload.liveStatePart, contains('00:31'));
    expect(payload.liveStatePart, contains('無需刻意報時'));
    expect(payload.controlPart, isNot(contains('00:31')));
    expect(payload.messages.single['content'], isNot(contains('00:31')));
  });

  test('call duration keeps the current second without rounding', () {
    final payload = CallPromptComposer.compose(
      history: const [],
      dynamicParts: const [],
      now: DateTime(2026, 10, 30, 13, 5),
      callElapsed: const Duration(seconds: 29),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(payload.liveStatePart, contains('00:29'));
    expect(payload.liveStatePart, isNot(contains('00:30')));
  });

  test('omits audio tag guidance when tags are unavailable', () {
    final payload = CallPromptComposer.compose(
      history: const [
        {'role': 'user', 'content': '喂？'},
      ],
      dynamicParts: const [],
      now: DateTime(2026, 7, 28, 13, 5),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(payload.controlPart, isNot(contains('[laughing]')));
    expect(payload.controlPart, isNot(contains('[sigh]')));
  });

  test('call language follows the selected recognition locale', () {
    final payload = CallPromptComposer.compose(
      history: const [
        {'role': 'user', 'content': '喂？'},
      ],
      dynamicParts: const [],
      now: DateTime(2026, 10, 27, 21),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
      replyLocale: 'zh_HK',
    );
    final control = payload.controlPart;
    expect(control, contains('語言：你當前應該用粵語'));
    expect(control, contains('除非 user 要求你用其他語言'));
    expect(
      control.indexOf('語言：'),
      lessThan(control.indexOf('模式：')),
      reason: 'language rule sits at the top of the call controls',
    );
    expect(payload.liveStatePart, isNot(contains('語言：')));

    final noLocale = CallPromptComposer.compose(
      history: const [],
      dynamicParts: const [],
      now: DateTime(2026, 10, 27, 21),
      allowAudioTags: false,
      characterName: '林澈',
      userName: '昭昭',
    );
    expect(noLocale.controlPart, isNot(contains('語言：')));
  });

  test('empty reply recovery stays short and keeps both identities', () {
    final instruction = CallPromptComposer.emptyReplyRecoveryInstruction(
      characterName: '林澈',
      userName: '昭昭',
    );

    expect(instruction, contains('林澈'));
    expect(instruction, contains('昭昭'));
    expect(instruction, contains('只補一句'));
    expect(instruction, contains('只輸出口語'));
  });

  test('natural call rule is on by default and can be turned off', () {
    CallTurnPayload build({bool? natural}) => natural == null
        ? CallPromptComposer.compose(
            history: const [],
            dynamicParts: const [],
            now: DateTime(2026, 10, 28, 21),
            allowAudioTags: false,
            characterName: '晏辭',
            userName: '昭昭',
          )
        : CallPromptComposer.compose(
            history: const [],
            dynamicParts: const [],
            now: DateTime(2026, 10, 28, 21),
            allowAudioTags: false,
            characterName: '晏辭',
            userName: '昭昭',
            naturalCall: natural,
          );

    expect(build().controlPart, contains('1–5 句'));
    expect(build(natural: true).controlPart, contains('自然電話'));
    expect(build(natural: false).controlPart, isNot(contains('自然電話')));
  });
}
