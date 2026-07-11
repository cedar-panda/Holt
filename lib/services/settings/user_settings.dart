import 'package:shared_preferences/shared_preferences.dart';

/// 用戶檔案、角色設定、雜項偏好
class UserSettings {
  // ═══ 用戶檔案 ═══
  static const String _keyUserName = 'user_profile_nickname';
  static const String _keyUserAvatarPath = 'user_profile_avatar';
  static const String _keyUserBio = 'user_profile_bio';
  static const String _keyUserPronouns = 'user_profile_pronouns';
  static const String _keyNamePromptCompleted = 'name_prompt_completed';
  static const String _keyLegacyUserName = 'user_name';
  static const String _keyLegacyUserAvatarPath = 'user_avatar_path';
  static const String _keyLegacyUserBio = 'user_bio';
  static const String _keyUserGender = 'user_gender';

  static Future<void> _saveWithLegacy(
    String key,
    String legacyKey,
    String value,
  ) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
    await p.setString(legacyKey, value);
  }

  static Future<String> _getWithLegacy(String key, String legacyKey) async {
    final p = await SharedPreferences.getInstance();
    final value = p.getString(key) ?? '';
    if (value.isNotEmpty) return value;

    final legacy = p.getString(legacyKey) ?? '';
    if (legacy.isNotEmpty) {
      await p.setString(key, legacy);
    }
    return legacy;
  }

  static Future<void> saveUserName(String v) async {
    await _saveWithLegacy(_keyUserName, _keyLegacyUserName, v);
  }

  static Future<String> getUserName() async {
    return _getWithLegacy(_keyUserName, _keyLegacyUserName);
  }

  static Future<void> saveNamePromptCompleted(bool completed) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyNamePromptCompleted, completed);
  }

  static Future<bool> getNamePromptCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyNamePromptCompleted) ?? false;
  }

  static Future<void> saveUserAvatarPath(String v) async {
    await _saveWithLegacy(_keyUserAvatarPath, _keyLegacyUserAvatarPath, v);
  }

  static Future<String> getUserAvatarPath() async {
    return _getWithLegacy(_keyUserAvatarPath, _keyLegacyUserAvatarPath);
  }

  static Future<void> saveUserBio(String v) async {
    await _saveWithLegacy(_keyUserBio, _keyLegacyUserBio, v);
  }

  static Future<String> getUserBio() async {
    return _getWithLegacy(_keyUserBio, _keyLegacyUserBio);
  }

  static Future<void> saveUserPronouns(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyUserPronouns, v);
  }

  static Future<String> getUserPronouns() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyUserPronouns) ?? '';
  }

  static Future<void> saveUserGender(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyUserGender, v);
  }

  static Future<String> getUserGender() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyUserGender) ?? '';
  }

  // ═══ 角色設定 ═══
  static const String _keyCharacterName = 'character_name';
  static const String _keyAvatarPath = 'avatar_path';
  static const String _keyActiveCharacterId = 'active_character_id';

  static Future<void> saveCharacterName(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyCharacterName, name);
  }

  static Future<String> getCharacterName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyCharacterName) ?? '';
  }

  static Future<void> saveAvatarPath(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyAvatarPath, path);
  }

  static Future<String> getAvatarPath() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyAvatarPath) ?? '';
  }

  static Future<void> saveActiveCharacterId(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyActiveCharacterId, id);
  }

  static Future<String> getActiveCharacterId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyActiveCharacterId) ?? 'default';
  }

  // ═══ 雜項 ═══
  static const String _keySendStyle = 'send_style';
  static const String _keyLocalModelPath = 'local_model_path';
  static const String _keyEnableVibration = 'enable_vibration';
  static const String _keyStickerVisionModel = 'sticker_vision_model';
  static const String _keyShowChatAvatar = 'show_chat_avatar';

  static Future<void> saveSendStyle(String style) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySendStyle, style);
  }

  static Future<String> getSendStyle() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keySendStyle) ?? 'leaf';
  }

  static Future<void> saveLocalModelPath(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyLocalModelPath, path);
  }

  static Future<String> getLocalModelPath() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyLocalModelPath) ??
        '/sdcard/Download/gemma-4-E2B-Q4_K_M.gguf';
  }

  static Future<void> saveEnableVibration(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyEnableVibration, v);
  }

  static Future<bool> getEnableVibration() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyEnableVibration) ?? true;
  }

  static Future<void> saveStickerVisionModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyStickerVisionModel, v);
  }

  static Future<String> getStickerVisionModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyStickerVisionModel) ?? '';
  }

  static Future<void> saveShowChatAvatar(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyShowChatAvatar, v);
  }

  static Future<bool> getShowChatAvatar() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyShowChatAvatar) ?? false;
  }
}
