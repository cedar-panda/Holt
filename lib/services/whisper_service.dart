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
  static const int maxLength = 18;
  static final RegExp _tagPattern = RegExp(
    r'<whisper\b[^>]*>([\s\S]*?)</whisper>',
    caseSensitive: false,
  );
  static final RegExp _openTagPattern = RegExp(
    r'<whisper\b[\s\S]*$',
    caseSensitive: false,
  );

  static String sanitize(String value) {
    final oneLine = value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return truncateGraphemes(oneLine, maxLength);
  }

  /// Request-only nudge. The tag syntax remains in the stable tool prompt;
  /// current text and the decision to refresh it stay dynamic so changing a
  /// whisper never invalidates the provider's static prompt cache.
  static String runtimeInstruction(CharacterWhisperState state) {
    return L.pick(
      en:
          '### Composer Whisper\n'
          'Current line: “${state.displayText}”\n'
          'Independently consider whether a different short line fits the current mood or moment. If it does, append one <whisper>short line</whisper> tag (maximum $maxLength characters). Otherwise leave it unchanged. This changes only the empty composer placeholder and must never overwrite text they already typed.',
      zhTW:
          '### 輸入框悄悄話\n'
          '目前顯示：「${state.displayText}」\n'
          '請自主判斷此刻的氣氛或關係是否適合換一句短話。適合時在回覆末尾附上一組 <whisper>短話</whisper>（最多 $maxLength 字）；不適合就維持原樣。它只會改變空輸入框的提示，不得覆寫對方已輸入的文字。',
      zhCN:
          '### 输入框悄悄话\n'
          '当前显示：“${state.displayText}”\n'
          '请自主判断此刻的气氛或关系是否适合换一句短话。适合时在回复末尾附上一组 <whisper>短话</whisper>（最多 $maxLength 字）；不适合就维持原样。它只会改变空输入框的提示，不得覆盖对方已输入的文字。',
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
