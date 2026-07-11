import 'package:shared_preferences/shared_preferences.dart';
import 'settings/api_settings.dart';
import 'sticker_service.dart';
import 'locale_strings.dart';
import '../memory/database.dart';

/// Token 估算（保守方向：寧可估低，避免「以為夠門檻其實沒緩存」）
/// CJK ≈ 1 token/字（Anthropic 實際多在 1.2~1.8），其他 ≈ 4 字符/token
class TokenEstimator {
  static final _cjk = RegExp(r'[\u3000-\u30ff\u4e00-\u9fff\uff00-\uffef]');

  static int estimate(String text) {
    if (text.isEmpty) return 0;
    final cjk = _cjk.allMatches(text).length;
    final other = text.length - cjk;
    return (cjk + other / 4).ceil();
  }

  /// 當前模型的緩存最低門檻
  /// ── Anthropic ──
  ///   Fable/Mythos 5 → 512；Opus 4.7 → 2048；Opus 4.6/4.5 → 4096
  ///   Opus 4.8 / Sonnet / Opus 4.1/4 → 1024；Haiku 4.5 → 4096；Haiku 3.5 → 2048
  /// ── Gemini ──
  ///   3.5 Flash / 3.1 Pro → 4096；2.5 Pro / 2.5 Flash → 2048
  /// ── DeepSeek ──
  ///   全模型 → 64（64-token 自動分塊）
  /// ── 其他 ──
  ///   預設 1024
  static Future<int> cacheThreshold() async {
    final provider = (await ApiSettings.getApiProvider()).toLowerCase();
    final model = (await currentModelForProvider(provider)).toLowerCase();

    return cacheThresholdForModel(provider: provider, model: model);
  }

  /// 取得目前 provider 真正會送出的模型名。
  /// Bedrock / DeepSeek 等 provider 不一定使用通用 model key。
  static Future<String> currentModelForProvider([String? provider]) async {
    final p = (provider ?? await ApiSettings.getApiProvider()).toLowerCase();
    switch (p) {
      case 'bedrock':
        return ApiSettings.getAwsModelId();
      case 'deepseek':
        return ApiSettings.getDeepseekModel();
      case 'gemini':
        return ApiSettings.getGeminiModel();
      case 'qwen':
        return ApiSettings.getQwenModel();
      case 'openai_compatible':
        return ApiSettings.getOaiCompatModel();
      default:
        return ApiSettings.getModel();
    }
  }

  /// 指定 provider/model 的緩存最低門檻。
  static int cacheThresholdForModel({
    required String provider,
    required String model,
  }) {
    final p = provider.toLowerCase();
    final m = model.toLowerCase();

    // ── DeepSeek（官方 or OpenRouter 都是 64t 分塊）──
    if (p == 'deepseek' || m.contains('deepseek')) return 64;

    // ── Gemini ──
    if (p == 'gemini' || m.contains('gemini')) {
      if (m.contains('3.5') || m.contains('3-5')) return 4096;
      if ((m.contains('3.1') || m.contains('3-1')) && m.contains('pro')) {
        return 4096;
      }
      if (m.contains('2.5') || m.contains('2-5')) return 2048;
      if (m.contains('pro')) return 4096;
      return 2048;
    }

    // ── Anthropic / Claude（官方、OpenRouter、Bedrock）──
    if (_containsAny(m, ['fable', 'mythos-5', 'mythos_5'])) return 512;
    if (m.contains('mythos') && m.contains('preview')) return 2048;
    if (m.contains('opus')) {
      // OpenRouter 官方：Opus 4.5-4.8 門檻一律 4096
      //（舊代碼 4.7 給 2048、4.8 落到 1024——UI 以為達標，provider 實際不建）
      if (_containsVersion(m, '4', '5') ||
          _containsVersion(m, '4', '6') ||
          _containsVersion(m, '4', '7') ||
          _containsVersion(m, '4', '8')) {
        return 4096;
      }
      return 1024;
    }
    if (m.contains('haiku')) {
      if (_containsVersion(m, '4', '5') || m.contains('haiku-4')) return 4096;
      if (_containsVersion(m, '3', '5') || m.contains('haiku-3')) return 2048;
      return 1024;
    }
    if (m.contains('claude') || m.contains('sonnet')) return 1024;

    // ── 其他模型 ──
    return 1024;
  }

  // ═══════════════════════════════════════════════════════
  //  保活資格判斷
  // ═══════════════════════════════════════════════════════

  /// 關鍵字列表：不同網站模型 ID 格式不同，只要含關鍵系列名就能判斷。
  static const _claudeFamilyKeywords = [
    'claude',
    'anthropic',
    'opus',
    'sonnet',
    'haiku',
    'fable',
    'mythos',
  ];

  /// 判斷當前模型是否支持保活（= 已確認有 1 小時 cache TTL）。
  /// Claude 家族走 Anthropic cache_control ttl:1h。
  /// Gemini 官方 API 走 cachedContents ttl:3600s。
  /// 其它模型即使有自動 cache，也不做關窗保活。
  static Future<bool> supportsKeepAlive() async {
    final provider = (await ApiSettings.getApiProvider()).toLowerCase();
    final model = await currentModelForProvider(provider);
    return supportsCloseWindowKeepAlive(provider: provider, model: model);
  }

  /// 是否支持關窗保活。
  /// 只收已確認 1h TTL 的路線：Claude cache_control / Gemini cachedContents。
  static bool supportsCloseWindowKeepAlive({
    required String provider,
    required String model,
  }) {
    final p = provider.toLowerCase();
    final m = model.toLowerCase();
    if (_isClaudeFamilyModel(m)) return _isClaudeCacheProvider(p);
    if (_isGeminiFamilyModel(m)) return _isGeminiCacheProvider(p);
    return false;
  }

  /// 回傳目前模型可用的 cache_control。
  /// 支持 1h 時帶 ttl；不支持 1h 時仍保留普通 ephemeral cache。
  /// 保活資格由 [supportsCloseWindowKeepAlive] 單獨判定，不能反過來關掉 cache。
  static Map<String, String>? promptCacheControl({
    required String provider,
    required String model,
  }) {
    final p = provider.toLowerCase();
    final m = model.toLowerCase();
    if (!_isClaudeCacheProvider(p)) return null;
    if (!_isClaudeFamilyModel(m)) return null;

    // 所有支援 Anthropic Cache 的路徑都預設帶上 1 小時 TTL
    return {'type': 'ephemeral', 'ttl': '1h'};
  }

  static bool _isClaudeFamilyModel(String model) =>
      _claudeFamilyKeywords.any((kw) => model.contains(kw));

  static bool _isGeminiFamilyModel(String model) => model.contains('gemini');

  static bool _isClaudeCacheProvider(String provider) {
    final p = provider.toLowerCase();
    return p == 'openrouter' ||
        p == 'openai_compatible' ||
        p == 'bedrock' ||
        p == 'aws_bedrock' ||
        p == 'anthropic' ||
        p == 'claude';
  }

  static bool _isGeminiCacheProvider(String provider) =>
      provider.toLowerCase() == 'gemini';

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);

  static bool _containsVersion(String text, String major, String minor) {
    final version = RegExp('(?:^|[^0-9])$major[-._]?$minor(?:[^0-9]|\$)');
    return version.hasMatch(text);
  }

  /// 用戶檔案 prompt（與 chat_screen._buildUserProfilePrompt 同構，
  /// 可用 override 參數帶入編輯中的即時值）
  static Future<String> buildProfilePrompt({
    String? nickname,
    String? pronouns,
    String? bio,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final nick = nickname ?? prefs.getString('user_profile_nickname') ?? '';
    final pron = pronouns ?? prefs.getString('user_profile_pronouns') ?? '';
    final about = bio ?? prefs.getString('user_profile_bio') ?? '';
    if (nick.isEmpty && pron.isEmpty && about.isEmpty) return '';
    final parts = <String>[];
    if (L.locale == 'en') {
      if (nick.isNotEmpty) parts.add('Name: $nick');
      if (pron.isNotEmpty) parts.add('Pronouns: $pron');
      if (about.isNotEmpty) parts.add('About: $about');
      return '【User Profile】${parts.join(', ')}';
    } else {
      if (nick.isNotEmpty) parts.add('${L.pick(en: '', zhTW: '暱稱：')}$nick');
      if (pron.isNotEmpty) parts.add('${L.pick(en: '', zhTW: '稱謂：')}$pron');
      if (about.isNotEmpty) {
        parts.add('${L.pick(en: '', zhTW: '自我介紹：')}$about');
      }
      return '${L.pick(en: '', zhTW: '【用戶檔案】')}${parts.join(L.pick(en: '', zhTW: '，'))}';
    }
  }

  /// 估算可緩存的靜態 prompt 總量：人設卡 + 用戶檔案 + 表情包
  /// （記憶與時間走動態注入，不算在內）
  /// 可用 override 帶入編輯中的即時值
  static Future<int> staticTotal({
    String? cardDescription,
    String? profileNickname,
    String? profilePronouns,
    String? profileBio,
    String? characterId,
  }) async {
    final sysPrompt = await ApiSettings.getSystemPrompt();
    final charData = await DatabaseHelper.getCharacter(
      characterId ?? 'default',
    );
    final charDesc = charData?['description'] as String? ?? '';
    final combinedDesc =
        (sysPrompt.isNotEmpty ? '$sysPrompt\n\n' : '') +
        (charDesc.isNotEmpty
            ? '${L.pick(en: '【Character Profile】', zhTW: '【角色設定】')}\n$charDesc'
            : '');
    final desc = cardDescription ?? combinedDesc;
    final profile = await buildProfilePrompt(
      nickname: profileNickname,
      pronouns: profilePronouns,
      bio: profileBio,
    );
    String sticker = '';
    try {
      sticker = await StickerService.buildStickerPrompt(
        characterId: characterId ?? 'default',
      );
    } catch (_) {}

    final parts = <String>[desc];
    if (profile.isNotEmpty) parts.add(profile);
    if (sticker.isNotEmpty) parts.add(sticker);
    return estimate(parts.join('\n\n'));
  }
}
