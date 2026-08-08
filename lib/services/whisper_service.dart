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
