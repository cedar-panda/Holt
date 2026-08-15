import 'package:shared_preferences/shared_preferences.dart';

/// 用戶檔案、角色設定、雜項偏好
class UserSettings {
  static const int currentFirstLaunchLanguageVersion = 1;
  static const int currentInitialSetupVersion = 1;

  // ═══ 用戶檔案 ═══
  static const String _keyUserName = 'user_profile_nickname';
  static const String _keyUserAvatarPath = 'user_profile_avatar';
  static const String _keyUserBio = 'user_profile_bio';
  static const String _keyUserPronouns = 'user_profile_pronouns';
  static const String _keyNamePromptCompleted = 'name_prompt_completed';
  static const String _keyFirstLaunchLanguageVersion =
      'first_launch_language_version';
  static const String _keyInitialSetupVersion = 'initial_setup_version';
  static const String _keyInitialSetupStep = 'initial_setup_step';
  static const String _keyInitialSetupMode = 'initial_setup_mode';
  static const String _keyWeakGuidanceOptOut = 'weak_guidance_opt_out';
  static const String _keyLegacyOnboardingVersion = 'onboarding_version';
  static const String _keyAppLocale = 'app_locale';
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

  /// 只在真正的新安裝顯示首次語言選擇。
  ///
  /// 舊版本已經完成暱稱提示、保存過語言，或在開發版完成過舊引導的使用者
  /// 都就地遷移，避免升級後突然被當成全新安裝。
  static Future<bool> shouldShowFirstLaunchLanguage() async {
    final p = await SharedPreferences.getInstance();
    final savedVersion = p.getInt(_keyFirstLaunchLanguageVersion);
    if (savedVersion != null) {
      return savedVersion < currentFirstLaunchLanguageVersion;
    }

    final legacyCompleted = p.getBool(_keyNamePromptCompleted) ?? false;
    final completedDevelopmentOnboarding =
        (p.getInt(_keyLegacyOnboardingVersion) ?? 0) > 0;
    final hasSavedLocale = p.getString(_keyAppLocale)?.isNotEmpty ?? false;
    final hasLegacyName =
        (p.getString(_keyUserName) ?? '').isNotEmpty ||
        (p.getString(_keyLegacyUserName) ?? '').isNotEmpty;
    if (legacyCompleted ||
        completedDevelopmentOnboarding ||
        hasSavedLocale ||
        hasLegacyName) {
      await p.setInt(
        _keyFirstLaunchLanguageVersion,
        currentFirstLaunchLanguageVersion,
      );
      // 這套三步引導只屬於新安裝。升級使用者不被重新攔住，也不突然
      // 收到原本沒有的弱提示。
      await p.setInt(_keyInitialSetupVersion, currentInitialSetupVersion);
      await p.setBool(_keyWeakGuidanceOptOut, true);
      return false;
    }
    return true;
  }

  static Future<void> completeFirstLaunchLanguage() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _keyFirstLaunchLanguageVersion,
      currentFirstLaunchLanguageVersion,
    );
    // 舊暱稱彈窗會破壞新的畫面內弱引導；首次語言選擇後不再顯示它。
    await p.setBool(_keyNamePromptCompleted, true);
  }

  static Future<int> getFirstLaunchLanguageVersion() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyFirstLaunchLanguageVersion) ?? 0;
  }

  /// 語言選擇後的新安裝流程：使用者稱呼與精簡 TA 人設卡。
  ///
  /// 第一版語言閘門曾單獨落地，因此「已選語言但沒有 setup 版本」應繼續
  /// 顯示這兩步；真正的舊使用者會在語言遷移時一併補上 setup 版本。
  static Future<bool> shouldShowInitialSetup() async {
    final p = await SharedPreferences.getInstance();
    final savedVersion = p.getInt(_keyInitialSetupVersion);
    if (savedVersion != null) {
      return savedVersion < currentInitialSetupVersion;
    }

    final languageSelected =
        (p.getInt(_keyFirstLaunchLanguageVersion) ?? 0) >=
        currentFirstLaunchLanguageVersion;
    if (languageSelected) return true;

    final hasLegacyEvidence =
        (p.getBool(_keyNamePromptCompleted) ?? false) ||
        (p.getInt(_keyLegacyOnboardingVersion) ?? 0) > 0 ||
        (p.getString(_keyAppLocale)?.isNotEmpty ?? false) ||
        (p.getString(_keyUserName)?.isNotEmpty ?? false) ||
        (p.getString(_keyLegacyUserName)?.isNotEmpty ?? false);
    if (hasLegacyEvidence) {
      await p.setInt(_keyInitialSetupVersion, currentInitialSetupVersion);
      await p.setBool(_keyWeakGuidanceOptOut, true);
      return false;
    }
    return true;
  }

  static Future<void> completeInitialSetup({
    bool skipAllGuidance = false,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyInitialSetupVersion, currentInitialSetupVersion);
    await p.setBool(_keyWeakGuidanceOptOut, skipAllGuidance);
    await p.setBool(_keyNamePromptCompleted, true);
    await p.remove(_keyInitialSetupStep);
  }

  static Future<void> saveInitialSetupMode(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyInitialSetupMode, mode);
  }

  static Future<String> getInitialSetupMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyInitialSetupMode) ?? '';
  }

  /// 從「我的 → 設定」重新開啟一次方案引導；不清除既有角色或對話資料。
  static Future<void> restartInitialSetup() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyInitialSetupVersion, 0);
    await p.setInt(_keyInitialSetupStep, 0);
    await p.remove(_keyInitialSetupMode);
  }

  static Future<void> saveInitialSetupStep(int step) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyInitialSetupStep, step.clamp(0, 3));
  }

  static Future<int> getInitialSetupStep() async {
    final p = await SharedPreferences.getInstance();
    return (p.getInt(_keyInitialSetupStep) ?? 0).clamp(0, 3);
  }

  static Future<int> getInitialSetupVersion() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_keyInitialSetupVersion) ?? 0;
  }

  /// 後續 API、摘要模型、新視窗等畫面內提示共用這個總開關。
  static Future<bool> isWeakGuidanceEnabled() async {
    final p = await SharedPreferences.getInstance();
    return !(p.getBool(_keyWeakGuidanceOptOut) ?? false);
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
