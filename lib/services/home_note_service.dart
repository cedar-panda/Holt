import '../memory/database.dart';
import '../utils/text_safety.dart';

/// Parses the hidden homepage greeting marker in one place.
///
/// The marker is always removed from visible text. Persistence is controlled
/// by the independent model-greeting switch, so disabling the switch cannot
/// leak a tag into chat while also preventing new notes from being written.
abstract final class HomeNoteService {
  static final RegExp _tag = RegExp(r'<home>([\s\S]*?)</home>');
  static final RegExp _stripTag = RegExp(r'<home>[\s\S]*?</home>');

  static Future<String> processReply(
    String text, {
    required String characterId,
    required bool enabled,
  }) async {
    final match = _tag.firstMatch(text);
    if (match == null) return text;

    if (enabled) {
      final note = truncateGraphemes(match.group(1)!.trim(), 12);
      if (note.isNotEmpty) {
        await DatabaseHelper.addNote(note, characterId: characterId);
      }
    }
    return text.replaceAll(_stripTag, '').trim();
  }

  static String strip(String text) => text.replaceAll(_stripTag, '').trim();
}
