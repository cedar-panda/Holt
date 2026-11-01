import 'package:characters/characters.dart';

import '../memory/database.dart';
import '../utils/text_safety.dart';
import 'locale_strings.dart';

class CharacterWhisperState {
  final String userText;
  final String modelText;
  final String source;
  final bool modelOverrideEnabled;

  const CharacterWhisperState({
    required this.userText,
    required this.modelText,
    required this.source,
    required this.modelOverrideEnabled,
  });

  factory CharacterWhisperState.fromCharacter(Map<String, dynamic>? value) {
    return CharacterWhisperState(
      userText: (value?['whisper_user_text'] as String? ?? '').trim(),
      modelText: (value?['whisper_model_text'] as String? ?? '').trim(),
      source: value?['whisper_source'] as String? ?? 'default',
      modelOverrideEnabled:
          (value?['whisper_model_override'] as int? ?? 1) == 1,
    );
  }

  String get displayText {
    if (!modelOverrideEnabled) {
      if (userText.isNotEmpty) return userText;
      if (modelText.isNotEmpty) return modelText;
      return L.get('input_hint');
    }
    if (source == 'model' && modelText.isNotEmpty) return modelText;
    if (source == 'user' && userText.isNotEmpty) return userText;
    if (userText.isNotEmpty) return userText;
    if (modelText.isNotEmpty) return modelText;
    return L.get('input_hint');
  }
}

class WhisperProcessResult {
  final String text;
  final CharacterWhisperState state;
  final bool updated;

  const WhisperProcessResult({
    required this.text,
    required this.state,
    required this.updated,
  });
}

/// Per-character composer whisper (the sentence shown while the user types).
class WhisperService {
  static const int maxLines = 2;
  static const int maxCjkLength = 24;
  static const int maxLatinLength = 56;
  // Compatibility alias for settings/tests that still display one limit.
  static const int maxLength = maxCjkLength;
  static final RegExp _cjkPattern = RegExp(
    r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]',
  );
  static final RegExp _tagPattern = RegExp(
    r'<whisper\b[^>]*>([\s\S]*?)</whisper>',
    caseSensitive: false,
  );
  static final RegExp _openTagPattern = RegExp(
    r'<whisper\b[\s\S]*$',
    caseSensitive: false,
  );

  static String sanitize(String value) {
    final normalized = value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\t', ' ');
    final compactLines = normalized
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r' {2,}'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .take(maxLines)
        .toList(growable: false);
    final compact = compactLines.join('\n');
    final limit = _cjkPattern.hasMatch(compact) ? maxCjkLength : maxLatinLength;
    var remaining = limit;
    final boundedLines = <String>[];
    for (final line in compactLines) {
      if (remaining <= 0) break;
      final bounded = truncateGraphemes(line, remaining);
      if (bounded.isEmpty) continue;
      boundedLines.add(bounded);
      remaining -= bounded.characters.length;
    }
    return boundedLines.join('\n');
  }

  /// Request-only nudge. The tag syntax remains in the stable tool prompt;
  /// current text and the decision to refresh it stay dynamic so changing a
  /// whisper never invalidates the provider's static prompt cache.
  static String runtimeInstruction(
    CharacterWhisperState state, {
    required String characterName,
    required String userName,
  }) {
    final character = sanitize(characterName).replaceAll('\n', ' ').trim();
    final user = sanitize(userName).replaceAll('\n', ' ').trim();
    final resolvedCharacter = character.isEmpty
        ? L.pick(en: 'the character', zhTW: '角色', zhCN: '角色')
        : character;
    final resolvedUser = user.isEmpty
        ? L.pick(en: 'the user', zhTW: 'user', zhCN: 'user')
        : user;
    return L.pick(
      en:
          '### Composer Whisper\n'
          'Current line: “${state.displayText}”\n'
          'This line is exclusively something $resolvedCharacter says to $resolvedUser in $resolvedCharacter\'s own voice. It is never narration, a system hint, or words spoken by $resolvedUser.\n'
          'Independently consider whether a different short note fits the current mood or moment. If it does, append one <whisper>note</whisper> tag (at most $maxLines lines; CJK text up to $maxCjkLength characters total, English text up to $maxLatinLength characters total). Otherwise leave it unchanged. This changes only the empty composer placeholder and must never overwrite text they already typed.',
      zhTW:
          '### 輸入框悄悄話\n'
          '目前顯示：「${state.displayText}」\n'
          '這句話只可以是「$resolvedCharacter」以自己的口吻對「$resolvedUser」說的短話；不是旁白、系統提示，也不是「$resolvedUser」說的話。\n'
          '請自主判斷此刻的氣氛或關係是否適合換一則短話。適合時在回覆末尾附上一組 <whisper>短話</whisper>（最多 $maxLines 行；中日韓文字合計不超過 $maxCjkLength 字，英文合計不超過 $maxLatinLength 字）；不適合就維持原樣。它只會改變空輸入框的提示，不得覆寫對方已輸入的文字。',
      zhCN:
          '### 输入框悄悄话\n'
          '当前显示：“${state.displayText}”\n'
          '这句话只可以是“$resolvedCharacter”以自己的口吻对“$resolvedUser”说的短话；不是旁白、系统提示，也不是“$resolvedUser”说的话。\n'
          '请自主判断此刻的气氛或关系是否适合换一则短话。适合时在回复末尾附上一组 <whisper>短话</whisper>（最多 $maxLines 行；中日韩文字合计不超过 $maxCjkLength 字，英文合计不超过 $maxLatinLength 字）；不适合就维持原样。它只会改变空输入框的提示，不得覆盖对方已输入的文字。',
    );
  }

  static Future<CharacterWhisperState> load(String characterId) async {
    return CharacterWhisperState.fromCharacter(
      await DatabaseHelper.getCharacter(characterId),
    );
  }

  static Future<CharacterWhisperState> saveUserText(
    String characterId,
    String value,
  ) async {
    final current = await load(characterId);
    final cleaned = sanitize(value);
    await DatabaseHelper.updateCharacterWhisper(
      characterId,
      userText: cleaned,
      source: cleaned.isNotEmpty
          ? 'user'
          : current.modelText.isNotEmpty
          ? 'model'
          : 'default',
    );
    return load(characterId);
  }

  static Future<CharacterWhisperState> setModelOverride(
    String characterId,
    bool enabled,
  ) async {
    await DatabaseHelper.updateCharacterWhisper(
      characterId,
      modelOverrideEnabled: enabled,
    );
    return load(characterId);
  }

  static Future<CharacterWhisperState> reset(String characterId) async {
    await DatabaseHelper.updateCharacterWhisper(
      characterId,
      userText: '',
      modelText: '',
      source: 'default',
    );
    return load(characterId);
  }

  /// Always removes the private tag. It is persisted only while model
  /// override is enabled, so a stale cached response cannot bypass the switch.
  static Future<WhisperProcessResult> processReply(
    String reply, {
    required String characterId,
  }) async {
    final matches = _tagPattern.allMatches(reply).toList();
    var cleanedReply = reply.replaceAll(_tagPattern, '');
    cleanedReply = cleanedReply.replaceAll(_openTagPattern, '').trim();

    var state = await load(characterId);
    if (!state.modelOverrideEnabled || matches.isEmpty) {
      return WhisperProcessResult(
        text: cleanedReply,
        state: state,
        updated: false,
      );
    }

    var candidate = '';
    for (final match in matches) {
      final value = sanitize(match.group(1) ?? '');
      if (value.isNotEmpty) candidate = value;
    }
    if (candidate.isEmpty) {
      return WhisperProcessResult(
        text: cleanedReply,
        state: state,
        updated: false,
      );
    }

    await DatabaseHelper.updateCharacterWhisper(
      characterId,
      modelText: candidate,
      source: 'model',
    );
    state = await load(characterId);
    return WhisperProcessResult(
      text: cleanedReply,
      state: state,
      updated: true,
    );
  }
}
