import 'locale_strings.dart';

/// RP-only identity boundary placed at the very beginning of the stable
/// system prompt. Keeping this separate from character/persona prose prevents
/// long role cards, summaries, or recalled state from blurring who the model
/// plays and who the user controls.
class RpIdentityLockPrompt {
  const RpIdentityLockPrompt._();

  static String build({
    required String characterName,
    required String userName,
  }) {
    final character = _singleLine(characterName).isEmpty
        ? L.pick(en: 'the character', zhTW: '當前角色', zhCN: '当前角色')
        : _singleLine(characterName);
    final user = _singleLine(userName).isEmpty
        ? L.pick(en: 'the user role', zhTW: '當前 user 角色', zhCN: '当前 user 角色')
        : _singleLine(userName);

    return L.pick(
      en:
          'The model is "$character"; user is "$user". The model only '
          'plays "$character". The user\'s messages, actions, and decisions '
          'belong to "$user"; never swap or merge these identities.',
      zhTW:
          '模型是「$character」，user 是「$user」。模型只扮演「$character」；'
          'user 的訊息、行動與決定均屬於「$user」，不得混淆或互換雙方身分。',
      zhCN:
          '模型是“$character”，user 是“$user”。模型只扮演“$character”；'
          'user 的消息、行动与决定均属于“$user”，不得混淆或互换双方身份。',
    );
  }

  static String _singleLine(String value) =>
      value.trim().replaceAll(RegExp(r'[\r\n]+'), ' ');
}
