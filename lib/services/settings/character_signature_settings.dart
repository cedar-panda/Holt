import 'package:shared_preferences/shared_preferences.dart';

/// Controls the optional character-signature requests.
///
/// The switch is global, while the two-per-window guard is stored by
/// conversation in the signature history table. No per-turn counter is kept
/// here because a window may only produce an opening and a closing entry.
abstract final class CharacterSignatureSettings {
  static const String _enabledKey = 'character_signature_enabled_v1';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }
}
