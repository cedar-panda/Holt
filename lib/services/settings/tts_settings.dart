import 'dart:convert';

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
    ('zh_HK', '粵語'),
    ('zh_TW', '繁中'),
    ('zh_CN', '簡中'),
    ('en_US', 'EN'),
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

  /// 粵語只有 ElevenLabs v3／v4 唸得出來；OpenAI 與其他 ElevenLabs 模型
  /// 會用普通話唸粵語字，所以這些情況下不提供粵語選項。
  static bool supportsCantonese({
    required String provider,
    required String elevenlabsModel,
  }) =>
      provider == 'elevenlabs' &&
      (elevenlabsModel == 'eleven_v3' || elevenlabsModel == 'eleven_v4');

  static List<(String, String)> sttLocalesFor({required bool cantonese}) =>
      cantonese
      ? sttLocales
      : sttLocales.where((entry) => entry.$1 != 'zh_HK').toList();

  /// 存的是粵語、但目前聲音不支援時，暫時改用繁中（不覆寫已存值，
  /// 換回 v3／v4 時自動恢復粵語）。
  static String effectiveSttLocale(String saved, {required bool cantonese}) =>
      saved == 'zh_HK' && !cantonese ? 'zh_TW' : saved;

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
    await p.setString(_keyTtsElevenlabsVoiceId, v.trim());
  }

  static Future<String> getTtsElevenlabsVoiceId() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_keyTtsElevenlabsVoiceId) ?? '').trim();
  }

  // ═══ 多個聲音 ID 管理 ═══
  static const String _keyTtsVoiceIdList = 'tts_elevenlabs_voice_id_list';
  static const String _keyTtsVoiceIdLabels =
      'tts_elevenlabs_voice_id_labels_v1';

  /// 獲取已保存的聲音 ID 列表
  static Future<List<String>> getVoiceIdList() async {
    final p = await SharedPreferences.getInstance();
    return normalizeVoiceIdOptions(
      p.getStringList(_keyTtsVoiceIdList) ?? const <String>[],
    );
  }

  /// 保存聲音 ID 列表
  static Future<void> saveVoiceIdList(List<String> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyTtsVoiceIdList, normalizeVoiceIdOptions(list));
  }

  /// User-facing aliases are keyed by the immutable ElevenLabs Voice ID. The
  /// ID stays visible beside the alias so copied configurations remain
  /// diagnosable and two similarly named voices cannot be confused.
  static Future<Map<String, String>> getVoiceIdLabels() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keyTtsVoiceIdLabels);
    if (raw == null || raw.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final entry in decoded.entries)
          if (entry.key.toString().trim().isNotEmpty &&
              (entry.value?.toString().trim() ?? '').isNotEmpty)
            entry.key.toString().trim(): entry.value!.toString().trim(),
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  static Future<void> saveVoiceIdLabel(String voiceId, String label) async {
    final id = voiceId.trim();
    if (id.isEmpty) return;
    final labels = await getVoiceIdLabels();
    final normalized = label.trim();
    if (normalized.isEmpty) {
      labels.remove(id);
    } else {
      labels[id] = normalized;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyTtsVoiceIdLabels, jsonEncode(labels));
  }

  static String voiceIdDisplayName(
    String voiceId,
    Map<String, String> labels, {
    bool compact = false,
  }) {
    final id = voiceId.trim();
    final label = labels[id]?.trim() ?? '';
    if (label.isEmpty) return id;
    if (!compact) return '$label · $id';
    final shortId = id.length > 10 ? '${id.substring(0, 10)}…' : id;
    return '$label · $shortId';
  }

  /// 清理、去重並保留 Voice ID 的原有順序。
  ///
  /// [boundVoiceId] 讓已綁定角色的舊 ID 即使未出現在全域清單中，仍能在
  /// 角色設定裡安全顯示與重新選取，不會令 Dropdown 的 value 失去對應 item。
  static List<String> normalizeVoiceIdOptions(
    Iterable<String> values, {
    String boundVoiceId = '',
  }) {
    final result = <String>[];
    final seen = <String>{};
    void add(String raw) {
      final value = raw.trim();
      if (value.isNotEmpty && seen.add(value)) result.add(value);
    }

    for (final value in values) {
      add(value);
    }
    add(boundVoiceId);
    return result;
  }

  /// 新增一個聲音 ID 到列表
  static Future<void> addVoiceId(String voiceId) async {
    final normalized = voiceId.trim();
    if (normalized.isEmpty) return;
    final list = normalizeVoiceIdOptions(<String>[
      ...await getVoiceIdList(),
      normalized,
    ]);
    await saveVoiceIdList(list);
  }

  /// 新增 Voice ID 並立即設為全域預設；回傳可直接刷新 UI 的完整清單。
  static Future<List<String>> addAndSelectVoiceId(String voiceId) async {
    final normalized = voiceId.trim();
    if (normalized.isEmpty) return getVoiceIdList();
    await addVoiceId(normalized);
    await saveTtsElevenlabsVoiceId(normalized);
    return getVoiceIdList();
  }

  /// 從列表移除一個聲音 ID
  static Future<void> removeVoiceId(String voiceId) async {
    final list = await getVoiceIdList();
    list.remove(voiceId.trim());
    await saveVoiceIdList(list);
    // 如果移除的是當前使用的，清空當前
    final current = await getTtsElevenlabsVoiceId();
    if (current == voiceId) {
      await saveTtsElevenlabsVoiceId(list.isNotEmpty ? list.first : '');
    }
    await saveVoiceIdLabel(voiceId, '');
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

  // ═══ 通話：自然電話 ═══
  // 開著時每次回覆盡量 1–5 句短句、說完就停，像真的打電話一來一往。預設開。
  static const String _keyCallNaturalMode = 'call_natural_mode';

  static Future<void> saveCallNaturalMode(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyCallNaturalMode, v);
  }

  static Future<bool> getCallNaturalMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_keyCallNaturalMode) ?? true;
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
