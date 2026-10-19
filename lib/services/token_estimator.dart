import 'package:shared_preferences/shared_preferences.dart';
import 'settings/api_settings.dart';
import 'sticker_service.dart';
import 'locale_strings.dart';
import '../memory/database.dart';
import 'cache/claude_cache_policy.dart';
import 'cache/deepinfra_cache_policy.dart';
import 'cache/deepseek_cache_policy.dart';
import 'cache/gemini_cache_policy.dart';

enum CacheThresholdKind {
  fixed,
  routeDependent,
  automaticWithoutPublishedMinimum,
  unavailable,
}

/// Provider/model-specific prompt-cache eligibility information.
///
/// A missing [minimumTokens] is intentional: automatic caches such as xAI do
/// not publish a fixed minimum, while custom relays cannot be described
/// truthfully without knowing their upstream route.
class CacheThresholdInfo {
  final CacheThresholdKind kind;
  final int? minimumTokens;

  const CacheThresholdInfo._(this.kind, this.minimumTokens);

  const CacheThresholdInfo.fixed(int minimumTokens)
    : this._(CacheThresholdKind.fixed, minimumTokens);

  const CacheThresholdInfo.routeDependent([int? routeSafeMinimumTokens])
    : this._(CacheThresholdKind.routeDependent, routeSafeMinimumTokens);

  const CacheThresholdInfo.automaticWithoutPublishedMinimum()
    : this._(CacheThresholdKind.automaticWithoutPublishedMinimum, null);

  const CacheThresholdInfo.unavailable()
    : this._(CacheThresholdKind.unavailable, null);

  bool isEligibleAt(int tokenCount) =>
      minimumTokens != null && tokenCount >= minimumTokens!;
}

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

  /// 目前模型的緩存規則。只有官方公開固定門檻時才回傳數字。
  static Future<CacheThresholdInfo> cacheThresholdInfo() async {
    final provider = (await ApiSettings.getApiProvider()).toLowerCase();
    final model = (await currentModelForProvider(provider)).toLowerCase();
    return cacheThresholdInfoForModel(provider: provider, model: model);
  }

  /// 舊呼叫點的相容層。`0` 表示沒有可驗證的固定門檻，不可當成
  /// 「任何內容都已達標」。新 UI 應使用 [cacheThresholdInfo]。
  static Future<int> cacheThreshold() async {
    return (await cacheThresholdInfo()).minimumTokens ?? 0;
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
      case 'deepinfra':
        return ApiSettings.getDeepInfraModel();
      case 'gemini':
        return ApiSettings.getGeminiModel();
      case 'qwen':
        return ApiSettings.getQwenModel();
      case 'openai_compatible':
        return ApiSettings.getOaiCompatModel();
      case 'xai':
        return ApiSettings.getXaiModel();
      case 'thinking_machines':
        return ApiSettings.getThinkingMachinesModel();
      case 'local_api':
        return ApiSettings.getLocalApiModel();
      case 'local':
        return ApiSettings.getModel();
      default:
        return ApiSettings.getModel();
    }
  }

  /// 指定 provider/model 的緩存最低門檻。沒有公開固定值時回傳 0。
  static int cacheThresholdForModel({
    required String provider,
    required String model,
  }) =>
      cacheThresholdInfoForModel(
        provider: provider,
        model: model,
      ).minimumTokens ??
      0;

  /// 官方文件規則表（2026-09）。不用一個虛構的 1024 當全域預設。
  static CacheThresholdInfo cacheThresholdInfoForModel({
    required String provider,
    required String model,
  }) {
    final p = provider.toLowerCase();
    final m = model.toLowerCase();

    // 本地 runtime 沒有可對照的 provider 緩存用量；Inkling 目前也
    // 沒有在 adapter 內送 cache_control 或讀取 cache usage。
    if (p == 'local' || p == 'thinking_machines') {
      return const CacheThresholdInfo.unavailable();
    }
    if (p == 'local_api') {
      return const CacheThresholdInfo.routeDependent();
    }

    // 直連來源先於模型名判定，避免 Qwen/Model Studio 下載入
    // DeepSeek、Kimi 等模型時誤用另一家 API 的規則。
    if (p == 'deepseek') return const CacheThresholdInfo.fixed(64);
    if (p == 'deepinfra') {
      return const CacheThresholdInfo.automaticWithoutPublishedMinimum();
    }
    if (p == 'qwen') return const CacheThresholdInfo.fixed(1024);
    if (p == 'xai') {
      return const CacheThresholdInfo.automaticWithoutPublishedMinimum();
    }

    // ── Gemini ──
    if (p == 'gemini' || m.contains('gemini')) {
      if (m.contains('gemini-4-argon') || m.contains('gemini-4-')) {
        return const CacheThresholdInfo.fixed(4096);
      }
      if (_containsAny(m, [
        '3.8',
        '3-8',
        '3.7',
        '3-7',
        '3.6',
        '3-6',
        '3.5',
        '3-5',
      ])) {
        return const CacheThresholdInfo.fixed(4096);
      }
      if ((m.contains('3.1') || m.contains('3-1')) && m.contains('pro')) {
        return const CacheThresholdInfo.fixed(4096);
      }
      if (m.contains('2.5') || m.contains('2-5')) {
        return const CacheThresholdInfo.fixed(2048);
      }
      // 未列入官方表的 Gemini 模型不猜數字。
      return const CacheThresholdInfo.routeDependent();
    }

    // ── DeepSeek：官方以 64 tokens 為緩存儲存單位。──
    if (m.contains('deepseek')) return const CacheThresholdInfo.fixed(64);

    // ── Anthropic / Claude（OpenRouter、自訂中轉、Bedrock）──
    if (_containsAny(m, ['fable', 'mythos-5', 'mythos_5'])) {
      return const CacheThresholdInfo.fixed(512);
    }
    if (m.contains('mythos') && m.contains('preview')) {
      // Anthropic 直接路由是 2048；Bedrock 為 4096。OpenRouter 可以
      // 在多個上游間路由，所以使用能覆蓋所有路由的安全值。
      if (p == 'bedrock' || p == 'aws_bedrock' || p == 'openrouter') {
        return const CacheThresholdInfo.routeDependent(4096);
      }
      return const CacheThresholdInfo.fixed(2048);
    }
    if (m.contains('opus')) {
      if (_containsVersion(m, '5', '1') || _containsMajorVersion(m, '5')) {
        return const CacheThresholdInfo.fixed(512);
      }
      if (_containsVersion(m, '4', '8')) {
        return const CacheThresholdInfo.fixed(1024);
      }
      if (_containsVersion(m, '4', '7')) {
        if (p == 'bedrock' || p == 'aws_bedrock' || p == 'openrouter') {
          return const CacheThresholdInfo.routeDependent(4096);
        }
        return const CacheThresholdInfo.fixed(2048);
      }
      if (_containsVersion(m, '4', '5') || _containsVersion(m, '4', '6')) {
        return const CacheThresholdInfo.fixed(4096);
      }
      return const CacheThresholdInfo.fixed(1024);
    }
    if (m.contains('haiku')) {
      if (_containsVersion(m, '4', '5') || m.contains('haiku-4')) {
        return const CacheThresholdInfo.fixed(4096);
      }
      if (_containsVersion(m, '3', '5') || m.contains('haiku-3')) {
        return const CacheThresholdInfo.fixed(2048);
      }
      return const CacheThresholdInfo.routeDependent();
    }
    if (m.contains('sonnet')) return const CacheThresholdInfo.fixed(1024);
    if (m.contains('claude')) {
      return const CacheThresholdInfo.routeDependent();
    }

    // OpenAI 在 OpenRouter 的已接入路線最低為 1024。自訂中轉
    // 不保證是 OpenAI 原生後端，所以不宣稱固定門檻。
    if (_isOpenAiModel(m)) {
      if (p == 'openrouter') return const CacheThresholdInfo.fixed(1024);
      return const CacheThresholdInfo.routeDependent();
    }

    // Grok 與 Moonshot/Kimi 在 OpenRouter 是自動緩存，官方沒有公布
    // 固定最低 token 數。
    if (_containsAny(m, ['grok', 'x-ai', 'xai/', 'moonshot', 'kimi'])) {
      return const CacheThresholdInfo.automaticWithoutPublishedMinimum();
    }

    // Qwen 原生來源的門檻是 1024；OpenRouter 的 Alibaba 明確緩存
    // 還取決於路由與模型是否支援 cache_control。
    if (m.contains('qwen')) {
      if (p == 'openrouter') {
        return const CacheThresholdInfo.routeDependent(1024);
      }
      return const CacheThresholdInfo.routeDependent();
    }

    return const CacheThresholdInfo.routeDependent();
  }

  static String localizedCacheThresholdLabel(CacheThresholdInfo info) {
    final minimum = info.minimumTokens;
    switch (info.kind) {
      case CacheThresholdKind.fixed:
        return L.pick(
          en: 'cache min $minimum',
          zhTW: '緩存門檻 $minimum',
          zhCN: '缓存门槛 $minimum',
        );
      case CacheThresholdKind.routeDependent:
        if (minimum != null) {
          return L.pick(
            en: 'route-safe cache min $minimum',
            zhTW: '路由安全緩存門檻 $minimum',
            zhCN: '路由安全缓存门槛 $minimum',
          );
        }
        return L.pick(
          en: 'cache minimum depends on route',
          zhTW: '緩存門檻依實際路由而定',
          zhCN: '缓存门槛依实际路由而定',
        );
      case CacheThresholdKind.automaticWithoutPublishedMinimum:
        return L.pick(
          en: 'automatic cache · no published fixed minimum',
          zhTW: '自動緩存 · 官方未公布固定門檻',
          zhCN: '自动缓存 · 官方未公布固定门槛',
        );
      case CacheThresholdKind.unavailable:
        return L.pick(
          en: 'no verifiable provider-cache threshold',
          zhTW: '沒有可驗證的 provider 緩存門檻',
          zhCN: '没有可验证的 provider 缓存门槛',
        );
    }
  }

  // ═══════════════════════════════════════════════════════
  //  保活資格判斷
  // ═══════════════════════════════════════════════════════

  /// 判斷當前模型是否支持保活（= 已確認有 1 小時 cache TTL）。
  /// Claude 家族走 Anthropic cache_control ttl:1h。
  /// Gemini 舊模型可走 cachedContents ttl:3600s；Gemini 4 的隱式快取
  /// 沒有可由客戶端延續的 TTL，因此不屬於關窗保活。
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
    if (ClaudeCachePolicy.isFamilyModel(m)) {
      return ClaudeCachePolicy.supportsRoute(p);
    }
    if (GeminiCachePolicy.matches(provider: p, model: m) &&
        GeminiCachePolicy.supportsExplicitCaching(m)) {
      return true;
    }
    if (p == 'deepinfra' && DeepInfraCachePolicy.supportsExplicitRetention(m)) {
      return true;
    }
    return false;
  }

  /// 回傳目前模型可用的 cache_control。
  /// 支持 1h 時帶 ttl；不支持 1h 時仍保留普通 ephemeral cache。
  /// 保活資格由 [supportsCloseWindowKeepAlive] 單獨判定，不能反過來關掉 cache。
  static Map<String, String>? promptCacheControl({
    required String provider,
    required String model,
  }) {
    return ClaudeCachePolicy.cacheControl(provider: provider, model: model);
  }

  /// 是否為可使用 Anthropic Prompt Cache 的 Claude 家族模型。
  ///
  /// 這個判斷同時看 provider 與模型名，避免把 Thinking Machines 等
  /// 非 Claude 來源誤綁到 OpenRouter／Anthropic 的快取提示。
  static bool isClaudePromptCacheModel({
    required String provider,
    required String model,
  }) {
    return ClaudeCachePolicy.matches(provider: provider, model: model);
  }

  static bool isDeepSeekAutomaticCacheProvider(String provider) =>
      DeepSeekCachePolicy.isDirectProvider(provider);

  static bool _containsAny(String text, List<String> values) =>
      values.any(text.contains);

  static bool _containsVersion(String text, String major, String minor) {
    final version = RegExp('(?:^|[^0-9])$major[-._]?$minor(?:[^0-9]|\$)');
    return version.hasMatch(text);
  }

  static bool _containsMajorVersion(String text, String major) {
    final version = RegExp('(?:^|[^0-9])$major(?:[^0-9]|\$)');
    return version.hasMatch(text);
  }

  static bool _isOpenAiModel(String model) =>
      model.contains('openai/') ||
      model.contains('chatgpt') ||
      RegExp(r'(?:^|[/_-])gpt[-._]').hasMatch(model) ||
      RegExp(r'(?:^|[/_-])o[134](?:[-._]|$)').hasMatch(model);

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
