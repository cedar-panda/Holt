import 'locale_strings.dart';

class ApiErrorDiagnosis {
  const ApiErrorDiagnosis({
    required this.category,
    required this.summary,
    required this.rawLog,
    this.statusCode,
    this.provider,
  });

  final String category;
  final String summary;
  final String rawLog;
  final int? statusCode;
  final String? provider;
}

/// Converts provider/network failures into short, user-facing messages in the
/// language selected inside the app. The original exception remains available
/// to callers for debug logging; provider response bodies are never shown here.
class ApiErrorLocalizer {
  ApiErrorLocalizer._();

  static String userMessage(Object error) => diagnose(error).summary;

  static ApiErrorDiagnosis diagnose(Object error) {
    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final lower = raw.toLowerCase();
    final provider = _providerName(raw);
    final statusCode = _statusCode(raw);

    final detail = _localizedDetail(lower, statusCode);
    return ApiErrorDiagnosis(
      category: _category(lower, statusCode),
      summary: _compose(
        provider: provider,
        statusCode: statusCode,
        detail: detail,
      ),
      rawLog: sanitizeRawLog(raw),
      statusCode: statusCode,
      provider: provider,
    );
  }

  static String sanitizeRawLog(String raw) {
    var clean = raw.replaceAllMapped(
      RegExp(
        r'(authorization\s*[:=]\s*bearer\s+)[^\s,}\]]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    clean = clean.replaceAllMapped(
      RegExp(
        r'''(["']?(?:api[_-]?key|access[_-]?token|secret)["']?\s*[:=]\s*["'])[^"']+''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    clean = clean.replaceAllMapped(
      RegExp(r'([?&](?:key|api_key)=)[^&\s]+', caseSensitive: false),
      (match) => '${match.group(1)}[REDACTED]',
    );
    clean = clean
        .replaceAll(
          RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b', caseSensitive: false),
          '[REDACTED]',
        )
        .replaceAll(RegExp(r'\bAIza[A-Za-z0-9_-]{20,}\b'), '[REDACTED]')
        .replaceAll(RegExp(r'\bAKIA[A-Z0-9]{16}\b'), '[REDACTED]')
        .trim();
    const maxRunes = 12000;
    final runes = clean.runes.toList(growable: false);
    if (runes.length > maxRunes) {
      clean = '${String.fromCharCodes(runes.take(maxRunes))}\n… [truncated]';
    }
    return clean;
  }

  static String _localizedDetail(String text, int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return _pick(
        en: 'The provider server is temporarily unavailable. Please try again later.',
        zhTW: '服務商伺服器暫時異常，請稍後重試',
        zhCN: '服务商服务器暂时异常，请稍后重试',
      );
    }

    if (_containsAny(text, const <String>[
          'context length',
          'context_length',
          'maximum context',
          'max context',
          'token limit',
          'too many tokens',
          'input too long',
          'prompt is too long',
          'request too large',
        ]) ||
        statusCode == 413) {
      return _pick(
        en: 'The conversation is too long for this model. Start a new window or shorten the content, then try again.',
        zhTW: '對話內容超過此模型可接受的長度，請開啟新窗口或縮短內容後重試',
        zhCN: '对话内容超过此模型可接受的长度，请开启新窗口或缩短内容后重试',
      );
    }

    if (_containsAny(text, const <String>[
      'safety',
      'content_filter',
      'content filter',
      'blocked prompt',
      'prompt was blocked',
      'prohibited content',
      'recitation',
    ])) {
      return _pick(
        en: 'The provider blocked this content for safety reasons. Adjust it and try again.',
        zhTW: '內容被服務商的安全機制攔截，請調整內容後重試',
        zhCN: '内容被服务商的安全机制拦截，请调整内容后重试',
      );
    }

    if (_containsAny(text, const <String>[
      'api key is not configured',
      'credentials are not configured',
      'api base url is not configured',
      'no local model is configured',
      'api key 未設定',
      'api key 未设置',
      'api base url 未設定',
      'api base url 未设置',
      '憑證未設定',
      '凭证未设置',
      '本地模型未設定',
      '本地模型未设置',
    ])) {
      return _pick(
        en: 'This API source is not fully configured. Complete its key or endpoint settings first.',
        zhTW: '這個 API 來源尚未完成設定，請先補齊金鑰或節點資訊',
        zhCN: '这个 API 来源尚未完成设置，请先补齐密钥或节点信息',
      );
    }

    if (_containsAny(text, const <String>[
          'invalid api key',
          'api key not valid',
          'incorrect api key',
          'authentication failed',
          'unauthenticated',
          'unauthorized',
        ]) ||
        statusCode == 401) {
      return _pick(
        en: 'The API key is invalid or has expired. Check it in Settings.',
        zhTW: 'API 金鑰無效或已失效，請到設定中檢查',
        zhCN: 'API 密钥无效或已失效，请到设置中检查',
      );
    }

    if (_containsAny(text, const <String>[
          'spending limit',
          'spend limit',
          'budget limit',
          'key limit',
          'usage limit',
          'maximum spend',
          'max spend',
        ]) &&
        statusCode == 403) {
      return _pick(
        en: 'This API key has reached its configured usage or spending limit.',
        zhTW: '此 API 金鑰已達設定的用量或消費上限',
        zhCN: '此 API 密钥已达设置的用量或消费上限',
      );
    }

    if ((_containsAny(text, const <String>['credit', 'quota']) &&
            statusCode == 429) ||
        _containsAny(text, const <String>[
          'insufficient quota',
          'insufficient_quota',
          'quota exceeded',
          'exceeded your current quota',
          'billing',
          'insufficient credits',
          'credit balance',
        ]) ||
        statusCode == 402) {
      return _pick(
        en: 'The account has insufficient quota or requires billing setup. Check the provider account.',
        zhTW: '帳號額度不足或尚未完成計費設定，請檢查服務商帳號',
        zhCN: '账号额度不足或尚未完成计费设置，请检查服务商账号',
      );
    }

    if (_containsAny(text, const <String>[
          'rate limit',
          'rate_limit',
          'too many requests',
          'resource_exhausted',
        ]) ||
        statusCode == 429) {
      return _pick(
        en: 'Requests are too frequent right now. Wait a moment and try again.',
        zhTW: '目前請求過於頻繁，請稍等片刻後重試',
        zhCN: '目前请求过于频繁，请稍等片刻后重试',
      );
    }

    if (_containsAny(text, const <String>[
      'high demand',
      'overloaded',
      'over capacity',
      'capacity is limited',
      'no capacity',
      'temporarily unavailable',
      'service unavailable',
    ])) {
      return _pick(
        en: 'The service is temporarily busy. This usually clears shortly; please try again later.',
        zhTW: '服務目前忙碌，通常只是暫時狀況，請稍後重試',
        zhCN: '服务目前繁忙，通常只是暂时状况，请稍后重试',
      );
    }

    if (_containsAny(text, const <String>[
          'timeout',
          'timed out',
          'deadline exceeded',
        ]) ||
        statusCode == 408) {
      return _pick(
        en: 'The request timed out. Check the connection and try again.',
        zhTW: '請求等候逾時，請檢查網路後重試',
        zhCN: '请求等待超时，请检查网络后重试',
      );
    }

    if (_containsAny(text, const <String>[
      'handshakeexception',
      'certificate_verify_failed',
      'certificate verify failed',
      'tls',
      'ssl',
    ])) {
      return _pick(
        en: 'A secure connection could not be established. Check the network or certificate settings.',
        zhTW: '無法建立安全連線，請檢查網路或憑證設定',
        zhCN: '无法建立安全连接，请检查网络或证书设置',
      );
    }

    if (_containsAny(text, const <String>[
      'socketexception',
      'clientexception',
      'failed host lookup',
      'connection refused',
      'connection reset',
      'connection closed',
      'network is unreachable',
      'network error',
    ])) {
      return _pick(
        en: 'The provider could not be reached. Check the network and try again.',
        zhTW: '目前無法連線到服務商，請檢查網路後重試',
        zhCN: '目前无法连接到服务商，请检查网络后重试',
      );
    }

    if (_containsAny(text, const <String>[
          'model not found',
          'model_not_found',
          'model does not exist',
          'model is not available',
          'unsupported model',
        ]) ||
        statusCode == 404) {
      return _pick(
        en: 'The selected model or API endpoint is unavailable. Check the model setting.',
        zhTW: '找不到或無法使用目前選擇的模型，請檢查模型設定',
        zhCN: '找不到或无法使用目前选择的模型，请检查模型设置',
      );
    }

    if (_containsAny(text, const <String>[
          'permission denied',
          'permission_denied',
          'forbidden',
          'does not have access',
          'not authorized to access',
        ]) ||
        statusCode == 403) {
      return _pick(
        en: 'The API key was rejected, the route is restricted, or the key has reached its limit.',
        zhTW: 'API 金鑰遭拒、目前節點受限，或此 Key 已達使用上限',
        zhCN: 'API 密钥遭拒、当前节点受限，或此 Key 已达使用上限',
      );
    }

    if (statusCode == 400 || statusCode == 409 || statusCode == 422) {
      return _pick(
        en: 'The provider rejected the request or model settings. Check the settings and try again.',
        zhTW: '服務商不接受目前的請求或模型設定，請檢查後重試',
        zhCN: '服务商不接受目前的请求或模型设置，请检查后重试',
      );
    }

    return _pick(
      en: 'The request failed. Please try again; check Debug logs if it keeps happening.',
      zhTW: '請求失敗，請重試；若持續發生，可查看 Debug 日誌',
      zhCN: '请求失败，请重试；若持续发生，可查看 Debug 日志',
    );
  }

  static String _category(String text, int? statusCode) {
    if (_containsAny(text, const <String>[
          'context length',
          'context_length',
          'maximum context',
          'max context',
          'token limit',
          'too many tokens',
          'input too long',
          'prompt is too long',
          'request too large',
        ]) ||
        statusCode == 413) {
      return 'context_too_long';
    }
    if (statusCode == 401) return 'authentication';
    if (_containsAny(text, const <String>['not configured', '未設定', '未设置'])) {
      return 'configuration';
    }
    if (statusCode == 403) {
      return _containsAny(text, const <String>[
            'limit',
            'budget',
            'spend',
            'quota',
            'credit',
            'maximum',
          ])
          ? 'key_limit'
          : 'permission';
    }
    if (statusCode == 402) return 'quota';
    if (statusCode == 429) {
      return _containsAny(text, const <String>['credit', 'quota'])
          ? 'quota'
          : 'rate_limit';
    }
    if (statusCode == 404) return 'not_found';
    if (statusCode == 408) return 'timeout';
    if (statusCode != null && statusCode >= 500) return 'upstream';
    if (_containsAny(text, const <String>[
      'socketexception',
      'clientexception',
      'failed host lookup',
      'connection refused',
      'connection reset',
      'network is unreachable',
      'network error',
    ])) {
      return 'network';
    }
    if (statusCode == 400 || statusCode == 409 || statusCode == 422) {
      return 'invalid_request';
    }
    return 'unknown';
  }

  static String _compose({
    required String? provider,
    required int? statusCode,
    required String detail,
  }) {
    final code = statusCode == null ? '' : 'HTTP $statusCode';
    if (L.locale == 'en') {
      final prefix = provider == null ? '' : '$provider: ';
      final suffix = code.isEmpty ? '' : ' ($code)';
      return '$prefix$detail$suffix';
    }
    final prefix = provider == null ? '' : '$provider：';
    final suffix = code.isEmpty ? '' : '（$code）';
    return '$prefix$detail$suffix';
  }

  static int? _statusCode(String raw) {
    final match = RegExp(
      r'(?:http(?:\s+status)?|status(?:\s*code)?|錯誤|错误|error|code)["\s:=#：]*([1-5]\d{2})',
      caseSensitive: false,
    ).firstMatch(raw);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static String? _providerName(String raw) {
    const providers = <String, String>{
      'thinking machines': 'Thinking Machines',
      'openrouter': 'OpenRouter',
      'deepseek': 'DeepSeek',
      'deepinfra': 'DeepInfra',
      'gemini': 'Gemini',
      'anthropic': 'Anthropic',
      'claude': 'Claude',
      'bedrock': 'Bedrock',
      'openai': 'OpenAI',
      'qwen': 'Qwen',
      'grok': 'Grok',
      'xai': 'xAI',
      'inkling': 'Inkling',
      'elevenlabs': 'ElevenLabs',
    };
    final lower = raw.toLowerCase();
    for (final entry in providers.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }

  static bool _containsAny(String text, List<String> values) {
    for (final value in values) {
      if (text.contains(value)) return true;
    }
    return false;
  }

  static String _pick({
    required String en,
    required String zhTW,
    required String zhCN,
  }) => L.pick(en: en, zhTW: zhTW, zhCN: zhCN);
}
