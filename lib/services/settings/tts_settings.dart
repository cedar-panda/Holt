import 'package:shared_preferences/shared_preferences.dart';
import '../secure_store.dart';
import '../locale_strings.dart';

/// TTS 語音設定（OpenAI / ElevenLabs）
class TtsSettings {
  static const String _keyTtsProvider = 'tts_provider';
  static const String _keyTtsOpenaiKey = 'tts_openai_key';
  static const String _keyTtsVoice = 'tts_voice';
  static const String _keyTtsElevenlabsKey = 'tts_elevenlabs_key';
  static const String _keyTtsElevenlabsVoiceId = 'tts_elevenlabs_voice_id';
  static const String _keyTtsElevenlabsModel = 'tts_elevenlabs_model';
  static const String _keyTtsElevenlabsStability = 'tts_elevenlabs_stability';
  static const String _keyTtsElevenlabsSimilarity = 'tts_elevenlabs_similarity';
  static const String _keySttLocale = 'stt_locale';

  // ═══ STT 語音辨識語言 ═══
  static const sttLocales = [
    ('zh_TW', '繁體中文'),
    ('zh_CN', '简体中文'),
    ('en_US', 'English'),
  ];

  static Future<void> saveSttLocale(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySttLocale, v);
  }

  static Future<String> getSttLocale() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_keySttLocale);
    if (saved != null && sttLocales.any((entry) => entry.$1 == saved)) {
      return saved;
    }
    return switch (L.locale) {
      'zh_CN' => 'zh_CN',
      'zh_TW' => 'zh_TW',
      _ => 'en_US',
    };
  }

  /// 取得語言顯示名稱
  static String sttLocaleName(String localeId) {
    for (final (id, name) in sttLocales) {
      if (id == localeId) return name;
    }
    return localeId;
  }

  /// 循環到下一個語言
  static String nextSttLocale(String current) {
    for (int i = 0; i < sttLocales.length; i++) {
      if (sttLocales[i].$1 == current) {
        return sttLocales[(i + 1) % sttLocales.length].$1;
      }
    }
    return sttLocales[0].$1;
  }

  static Future<void> saveTtsProvider(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyTtsProvider, v);
  }

  static Future<String> getTtsProvider() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyTtsProvider) ?? 'openai';
  }

  static Future<void> saveTtsOpenaiKey(String v) async {
    await SecureStore.write(_keyTtsOpenaiKey, v);
  }

  static Future<String> getTtsOpenaiKey() async {
    return SecureStore.read(_keyTtsOpenaiKey);
  }

  static Future<void> saveTtsVoice(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyTtsVoice, v);
  }

  static Future<String> getTtsVoice() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyTtsVoice) ?? 'nova';
  }

  static Future<void> saveTtsElevenlabsKey(String v) async {
    await SecureStore.write(_keyTtsElevenlabsKey, v);
  }

  static Future<String> getTtsElevenlabsKey() async {
    return SecureStore.read(_keyTtsElevenlabsKey);
  }

  static Future<void> saveTtsElevenlabsVoiceId(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyTtsElevenlabsVoiceId, v);
  }

  static Future<String> getTtsElevenlabsVoiceId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyTtsElevenlabsVoiceId) ?? '';
  }

  // ═══ 多個聲音 ID 管理 ═══
  static const String _keyTtsVoiceIdList = 'tts_elevenlabs_voice_id_list';

  /// 獲取已保存的聲音 ID 列表
  static Future<List<String>> getVoiceIdList() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_keyTtsVoiceIdList) ?? [];
  }

  /// 保存聲音 ID 列表
  static Future<void> saveVoiceIdList(List<String> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyTtsVoiceIdList, list);
  }

  /// 新增一個聲音 ID 到列表
  static Future<void> addVoiceId(String voiceId) async {
    final list = await getVoiceIdList();
    if (!list.contains(voiceId) && voiceId.isNotEmpty) {
      list.add(voiceId);
      await saveVoiceIdList(list);
    }
  }

  /// 從列表移除一個聲音 ID
  static Future<void> removeVoiceId(String voiceId) async {
    final list = await getVoiceIdList();
    list.remove(voiceId);
    await saveVoiceIdList(list);
    // 如果移除的是當前使用的，清空當前
    final current = await getTtsElevenlabsVoiceId();
    if (current == voiceId) {
      await saveTtsElevenlabsVoiceId(list.isNotEmpty ? list.first : '');
    }
  }

  static Future<void> saveTtsElevenlabsModel(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyTtsElevenlabsModel, v);
  }

  static Future<String> getTtsElevenlabsModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyTtsElevenlabsModel) ?? 'eleven_multilingual_v2';
  }

  static Future<void> saveTtsElevenlabsStability(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyTtsElevenlabsStability, v);
  }

  static Future<double> getTtsElevenlabsStability() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_keyTtsElevenlabsStability) ?? 0.5;
  }

  static Future<void> saveTtsElevenlabsSimilarity(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyTtsElevenlabsSimilarity, v);
  }

  static Future<double> getTtsElevenlabsSimilarity() async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(_keyTtsElevenlabsSimilarity) ?? 0.75;
  }

  // ═══ 語音庫：單條下載路徑快照 ═══
  static const String _keyVoiceDownloadDir = 'voice_download_dir';

  static Future<void> saveVoiceDownloadDir(String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyVoiceDownloadDir, path);
  }

  static Future<String> getVoiceDownloadDir() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyVoiceDownloadDir) ?? '';
  }

  // ═══ 通話：麥克風模式 ═══
  // 'hold' = 按住說話｜'auto' = 自動聆聽（停頓自動發送）
  static const String _keyCallMicMode = 'call_mic_mode';

  static Future<void> saveCallMicMode(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyCallMicMode, v);
  }

  static Future<String> getCallMicMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyCallMicMode) ?? 'hold';
  }

  // ═══ 通話：來電鈴聲 ═══
  // 'gentle' | 'classic' | 'vibrate'（僅震動）
  static const String _keyCallRingtone = 'call_ringtone';

  static Future<void> saveCallRingtone(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyCallRingtone, v);
  }

  static Future<String> getCallRingtone() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyCallRingtone) ?? 'gentle';
  }
}
