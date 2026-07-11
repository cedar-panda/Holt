import 'dart:convert';

import 'package:http/http.dart' as http;

import '../memory/database.dart';
import '../models/message.dart';
import 'local_ai_service.dart';
import 'settings/api_settings.dart';
import 'settings/memory_settings.dart';
import 'settings/user_settings.dart';
import 'token_estimator.dart';
import 'locale_strings.dart';

class ManualSummaryPolicyFailure implements Exception {
  final String excerpt;
  final String message;

  const ManualSummaryPolicyFailure({
    required this.excerpt,
    this.message = '摘要失敗，請手動摘要。',
  });

  @override
  String toString() => message;
}

class ManualSummaryResult {
  final int id;
  final String content;
  final int tokenCount;

  const ManualSummaryResult({
    required this.id,
    required this.content,
    required this.tokenCount,
  });
}

class ManualSummaryService {
  static const String _openRouterUrl =
      'https://openrouter.ai/api/v1/chat/completions';

  static String buildExcerpt(
    List<Message> messages, {
    String userName = 'user',
    String charName = 'char',
  }) {
    final lines = <String>[];
    for (final message in messages) {
      final text = message.text.trim();
      final imageHint = (message.imagePath ?? '').isNotEmpty
          ? L.pick(en: '(includes an image) ', zhTW: '（含圖片）')
          : '';
      if (text.isEmpty && imageHint.isEmpty) continue;

      final role = message.isUser ? userName : charName;
      final content = text.isEmpty ? imageHint : '$imageHint$text'.trim();
      lines.add('[$role] $content');
    }
    return lines.join('\n\n');
  }

  static Future<ManualSummaryResult> summarizeMessages({
    required String conversationId,
    required String characterId,
    required List<Message> messages,
  }) async {
    final char = await DatabaseHelper.getCharacter(characterId);
    final rawCharName = char?['name'] as String?;
    final charName = (rawCharName != null && rawCharName.isNotEmpty)
        ? rawCharName
        : 'char';
    final rawUser = await UserSettings.getUserName();
    final userName = rawUser.isNotEmpty ? rawUser : 'user';

    final excerpt = buildExcerpt(
      messages,
      userName: userName,
      charName: charName,
    );
    return summarizeExcerpt(
      conversationId: conversationId,
      characterId: characterId,
      excerpt: excerpt,
      userName: userName,
      charName: charName,
    );
  }

  static Future<ManualSummaryResult> summarizeExcerpt({
    required String conversationId,
    required String characterId,
    required String excerpt,
    String userName = 'user',
    String charName = 'char',
  }) async {
    final cleanedExcerpt = excerpt.trim();
    if (cleanedExcerpt.isEmpty) {
      throw Exception('沒有可摘要的內容');
    }

    final summary = await _callSummaryModel(
      cleanedExcerpt,
      userName: userName,
      charName: charName,
    );
    final content = _normalizeSummary(summary);
    if (content.isEmpty) {
      throw Exception('摘要模型沒有返回內容');
    }
    if (_looksLikeRefusalContent(content)) {
      throw ManualSummaryPolicyFailure(excerpt: cleanedExcerpt);
    }

    final savedContent =
        '${L.pick(en: '【Manual Summary】', zhTW: '【手動摘要】')}\n$content';
    final windowId = await DatabaseHelper.ensureConversationWindowSummaryId(
      conversationId,
    );
    final tokenCount = TokenEstimator.estimate(savedContent);
    final id = await DatabaseHelper.insertContextSummary(
      characterId: characterId,
      content: savedContent,
      tokenCount: tokenCount,
      sourceWindowId: windowId,
      sourceConversationId: conversationId,
    );

    return ManualSummaryResult(
      id: id,
      content: savedContent,
      tokenCount: tokenCount,
    );
  }

  static Future<String> _callSummaryModel(
    String excerpt, {
    required String userName,
    required String charName,
  }) async {
    try {
      final source = await MemorySettings.getSummarySource();
      if (source == 'local' && LocalAiService.isReady) {
        final local = LocalAiService();
        return await local.sendMessage(
          messages: [
            {
              'role': 'user',
              'content': _buildUserPrompt(excerpt, userName, charName),
            },
          ],
          model: 'local',
          systemPrompt: _systemPrompt,
        );
      }

      var model = await MemorySettings.getSummaryModel();
      if (model.isEmpty) {
        model = await ApiSettings.getModel();
      }

      final provider = await ApiSettings.getApiProvider();
      if (provider == 'openrouter') {
        return await _callOpenRouter(
          model: model,
          excerpt: excerpt,
          userName: userName,
          charName: charName,
        );
      }

      final adapter = await ApiSettings.buildAdapter();
      return await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content': _buildUserPrompt(excerpt, userName, charName),
          },
        ],
        model: model,
        systemPrompt: _systemPrompt,
      );
    } catch (e) {
      if (e is ManualSummaryPolicyFailure) rethrow;
      if (_looksLikePolicyError(e)) {
        throw ManualSummaryPolicyFailure(excerpt: excerpt);
      }
      rethrow;
    }
  }

  static Future<String> _callOpenRouter({
    required String model,
    required String excerpt,
    required String userName,
    required String charName,
  }) async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    if (apiKey.isEmpty) {
      throw Exception('OpenRouter API Key 未設定');
    }

    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': _buildUserPrompt(excerpt, userName, charName),
        },
      ],
      'stream': false,
      'max_tokens': 1800,
      'temperature': 0.2,
    };

    final response = await http
        .post(
          Uri.parse(_openRouterUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
            'HTTP-Referer': 'https://project-yanci.app',
            'X-Title': 'Project Yanci',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 180));

    final decoded = _tryDecodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (_payloadHasPolicySignal(decoded ?? response.body)) {
        throw ManualSummaryPolicyFailure(excerpt: excerpt);
      }
      throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = decoded;
    if (data is! Map<String, dynamic>) {
      throw Exception('摘要模型返回格式不正確');
    }

    if (_payloadHasPolicySignal(data['error'])) {
      throw ManualSummaryPolicyFailure(excerpt: excerpt);
    }

    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      if (_payloadHasPolicySignal(data)) {
        throw ManualSummaryPolicyFailure(excerpt: excerpt);
      }
      throw Exception('摘要模型沒有返回 choices');
    }

    final choice = choices.first;
    if (choice is Map<String, dynamic>) {
      if (_payloadHasPolicySignal(choice['error'])) {
        throw ManualSummaryPolicyFailure(excerpt: excerpt);
      }
      if (choice['finish_reason'] == 'error') {
        if (_payloadHasPolicySignal(choice)) {
          throw ManualSummaryPolicyFailure(excerpt: excerpt);
        }
        throw Exception('摘要模型回覆中斷');
      }
      final message = choice['message'];
      if (message is Map<String, dynamic>) {
        return '${message['content'] ?? ''}';
      }
      return '${choice['text'] ?? ''}';
    }

    throw Exception('摘要模型返回格式不正確');
  }

  static Object? _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static bool _payloadHasPolicySignal(Object? payload) {
    if (payload == null) return false;
    final text = _stringify(payload).toLowerCase();
    return text.contains('content_policy_violation') ||
        text.contains('policy_violation') ||
        text.contains('refusal') ||
        text.contains('moderation') ||
        text.contains('guardrail') ||
        text.contains('safety') ||
        text.contains('content policy') ||
        text.contains('blocked by') ||
        text.contains('flagged_input') ||
        text.contains('拒絕') ||
        text.contains('內容政策') ||
        text.contains('安全策略') ||
        text.contains('審核') ||
        text.contains('攔截');
  }

  static bool _looksLikePolicyError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('content_policy_violation') ||
        text.contains('policy_violation') ||
        text.contains('refusal') ||
        text.contains('moderation') ||
        text.contains('guardrail') ||
        text.contains('content policy') ||
        text.contains('blocked by') ||
        text.contains('safety') ||
        text.contains('拒絕') ||
        text.contains('內容政策') ||
        text.contains('安全策略') ||
        text.contains('審核') ||
        text.contains('攔截');
  }

  static bool _looksLikeRefusalContent(String content) {
    final text = content.trim().toLowerCase();
    final startsLikeRefusal =
        text.startsWith("i can't") ||
        text.startsWith('i cannot') ||
        text.startsWith("i'm sorry") ||
        text.startsWith('i am sorry') ||
        text.startsWith("i'm unable") ||
        text.startsWith('i am unable') ||
        text.startsWith('sorry,') ||
        text.startsWith('抱歉') ||
        text.startsWith('對不起') ||
        text.startsWith('我不能') ||
        text.startsWith('我無法');
    if (!startsLikeRefusal) return false;
    return text.contains('summar') ||
        text.contains('assist') ||
        text.contains('comply') ||
        text.contains('policy') ||
        text.contains('safety') ||
        text.contains('content') ||
        text.contains('摘要') ||
        text.contains('協助') ||
        text.contains('政策') ||
        text.contains('安全') ||
        text.contains('內容');
  }

  static String _stringify(Object payload) {
    if (payload is String) return payload;
    try {
      return jsonEncode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  static String _normalizeSummary(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('```')) {
      return trimmed
          .replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    return trimmed;
  }

  static String _buildUserPrompt(
    String excerpt,
    String userName,
    String charName,
  ) {
    if (L.locale == 'en') {
      return '''
Summarize the following chat excerpt. It uses exactly two speaker labels:
- [$userName] user
- [$charName] character

Preserve:
1. Important events and decisions.
2. Emotional changes, relationship state, preferences, and boundaries between $userName and $charName.
3. Promises, unfinished matters, and threads that can be continued next time.

If the source contains adult, explicit, violent, or sensitive content:
- Do not repeat it verbatim or describe specific body or procedural details.
- Describe only the general meaning in abstract, neutral terms, such as intimate interaction, conflict, comfort, or testing boundaries.
- Preserve emotions, consent, boundaries, consequences, and relationship changes that matter to future conversation.

Write concise bullet points in English.

Chat excerpt:
$excerpt
''';
    }

    final lang = L.locale == 'zh_CN' ? '简体中文' : '繁體中文';
    final template = L.pick(
      en: '',
      zhTW: '''
請摘要以下聊天摘錄。摘錄中的角色標籤只有兩種：
- [\u{E000}] 使用者
- [\u{E001}] 角色

請保留：
1. 重要事件與決定。
2. \u{E000} 與 \u{E001} 的情緒變化、關係狀態、偏好、界線。
3. 承諾、未完成事項、下次可以接續的線索。

如果原文包含限制級、露骨、暴力或敏感內容：
- 不要逐字重述，不要描寫具體身體細節或操作細節。
- 只用抽象、概括、中性的方式描述「發生了親密互動 / 衝突 / 安撫 / 試探界線」等大意。
- 保留對後續對話有用的情緒、同意、界線、後果與關係變化。

請使用\u{E002}，輸出精簡條列。

聊天摘錄：
\u{E003}
''',
    );
    return template
        .replaceAll('\u{E000}', userName)
        .replaceAll('\u{E001}', charName)
        .replaceAll('\u{E002}', lang)
        .replaceAll('\u{E003}', excerpt);
  }

  static String get _systemPrompt => L.pick(
    en: '''
You are a chat-memory summarizer. Compress chat content into memory that supports continuity in later role-play.
Do not judge, continue the story, or invent new events.
For explicit or sensitive content, use an abstract summary instead of repeating graphic details.
''',
    zhTW: '''
你是聊天記憶摘要器。你的任務是把聊天內容壓縮成可供後續角色扮演連續使用的記憶。
你不需要審判、延伸創作或加入新事件。
遇到露骨或敏感內容時，用抽象概括替代細節，不要重述具體露骨描寫。
''',
  );
}
