import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../memory/database.dart';
import '../models/message.dart';
import 'character_timeline_service.dart';
import 'context_compressor.dart';
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
  final int timelineChanges;

  const ManualSummaryResult({
    required this.id,
    required this.content,
    required this.tokenCount,
    this.timelineChanges = 0,
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

  static String buildDatedExcerpt(List<Message> messages) {
    return messages
        .map((message) {
          final time = message.createdAt.isUtc
              ? message.createdAt.toLocal()
              : message.createdAt;
          final localTime =
              '${time.year.toString().padLeft(4, '0')}-'
              '${time.month.toString().padLeft(2, '0')}-'
              '${time.day.toString().padLeft(2, '0')} '
              '${time.hour.toString().padLeft(2, '0')}:'
              '${time.minute.toString().padLeft(2, '0')}';
          final speaker = message.isUser ? 'user' : 'char';
          return '[msg:${message.id ?? 0} | local_time:$localTime | '
              'speaker:$speaker]\n${message.text}';
        })
        .join('\n\n');
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
    return _summarize(
      conversationId: conversationId,
      characterId: characterId,
      modelExcerpt: buildDatedExcerpt(messages),
      fallbackExcerpt: excerpt,
      userName: userName,
      charName: charName,
      sourceMessages: messages,
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
    return _summarize(
      conversationId: conversationId,
      characterId: characterId,
      modelExcerpt: cleanedExcerpt,
      fallbackExcerpt: cleanedExcerpt,
      userName: userName,
      charName: charName,
      sourceMessages: const [],
    );
  }

  static Future<ManualSummaryResult> _summarize({
    required String conversationId,
    required String characterId,
    required String modelExcerpt,
    required String fallbackExcerpt,
    required String userName,
    required String charName,
    required List<Message> sourceMessages,
  }) async {
    final cleanedExcerpt = modelExcerpt.trim();
    if (cleanedExcerpt.isEmpty) {
      throw Exception('沒有可摘要的內容');
    }

    final summaries = await DatabaseHelper.getContextSummaries(characterId);
    final previousSummary = summaries.isEmpty
        ? ''
        : (summaries.last['content'] as String? ?? '').trim();
    final rawResponse = await _callSummaryModel(
      cleanedExcerpt,
      userName: userName,
      charName: charName,
      previousSummary: previousSummary,
      fallbackExcerpt: fallbackExcerpt,
    );
    final decoded = ContextCompressor.decodeSummaryEnvelope(rawResponse);
    final content = ContextCompressor.normalizeSummaryFormat(decoded.summary);
    if (content.isEmpty) {
      throw Exception('摘要模型沒有返回內容');
    }
    if (_looksLikeRefusalContent(content)) {
      throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
    }

    // 手動摘要也要走本地明確生理期掃描；不能只依賴摘要模型輸出
    // timeline，否則「昨天來的生理期」等可驗證句子可能被模型漏掉。
    final explicitMenstrualChanges = sourceMessages.isEmpty
        ? 0
        : await CharacterTimelineService.storeExplicitMenstrualMessages(
            characterId: characterId,
            messages: sourceMessages,
          );
    debugPrint(
      '[TimelineDebug] manual summary: char=$characterId '
      'sourceMessages=${sourceMessages.length} modelTimeline=${decoded.timeline.length} '
      'explicitChanges=$explicitMenstrualChanges',
    );

    var timelineCandidates = decoded.timeline;
    if (sourceMessages.isNotEmpty) {
      timelineCandidates =
          await ContextCompressor.recoverMissingMenstrualCandidates(
            messages: sourceMessages,
            candidates: timelineCandidates,
          );
    }
    final modelTimelineChanges = sourceMessages.isEmpty
        ? 0
        : await CharacterTimelineService.storeSummaryCandidates(
            characterId: characterId,
            candidates: timelineCandidates,
            sourceMessages: sourceMessages,
          );
    final timelineChanges = explicitMenstrualChanges + modelTimelineChanges;
    debugPrint(
      '[TimelineDebug] manual summary stored: char=$characterId '
      'modelChanges=$modelTimelineChanges totalChanges=$timelineChanges',
    );

    final savedContent = content;
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
      timelineChanges: timelineChanges,
    );
  }

  static Future<String> _callSummaryModel(
    String excerpt, {
    required String userName,
    required String charName,
    required String previousSummary,
    required String fallbackExcerpt,
  }) async {
    try {
      final source = await MemorySettings.getSummarySource();
      if (source == 'local' && LocalAiService.isReady) {
        final local = LocalAiService();
        return await local.sendMessage(
          messages: [
            {
              'role': 'user',
              'content': _buildUserPrompt(
                excerpt,
                userName,
                charName,
                previousSummary,
              ),
            },
          ],
          model: 'local',
          systemPrompt: await _systemPromptForCharacter(charName),
        );
      }

      var model = await MemorySettings.getSummaryModel();
      if (model.isEmpty) {
        model = await ApiSettings.getModel();
      }

      final provider = await ApiSettings.resolveSummaryModelProvider(model);
      if (provider == 'openrouter') {
        return await _callOpenRouter(
          model: model,
          excerpt: excerpt,
          userName: userName,
          charName: charName,
          previousSummary: previousSummary,
          fallbackExcerpt: fallbackExcerpt,
        );
      }

      final adapter = await ApiSettings.buildAdapterForSummaryModel(model);
      return await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content': _buildUserPrompt(
              excerpt,
              userName,
              charName,
              previousSummary,
            ),
          },
        ],
        model: model,
        systemPrompt: await _systemPromptForCharacter(charName),
      );
    } catch (e) {
      if (e is ManualSummaryPolicyFailure) rethrow;
      if (_looksLikePolicyError(e)) {
        throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
      }
      rethrow;
    }
  }

  static Future<String> _callOpenRouter({
    required String model,
    required String excerpt,
    required String userName,
    required String charName,
    required String previousSummary,
    required String fallbackExcerpt,
  }) async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    if (apiKey.isEmpty) {
      throw Exception('OpenRouter API Key 未設定');
    }

    final systemPrompt = await _systemPromptForCharacter(charName);
    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': _buildUserPrompt(
            excerpt,
            userName,
            charName,
            previousSummary,
          ),
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
        throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
      }
      throw Exception('API 錯誤 ${response.statusCode}: ${response.body}');
    }

    final data = decoded;
    if (data is! Map<String, dynamic>) {
      throw Exception('摘要模型返回格式不正確');
    }

    if (_payloadHasPolicySignal(data['error'])) {
      throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
    }

    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      if (_payloadHasPolicySignal(data)) {
        throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
      }
      throw Exception('摘要模型沒有返回 choices');
    }

    final choice = choices.first;
    if (choice is Map<String, dynamic>) {
      if (_payloadHasPolicySignal(choice['error'])) {
        throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
      }
      if (choice['finish_reason'] == 'error') {
        if (_payloadHasPolicySignal(choice)) {
          throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
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

  static String _buildUserPrompt(
    String excerpt,
    String userName,
    String charName,
    String previousSummary,
  ) {
    final buffer = StringBuffer();
    buffer.writeln(
      L.pick(
        en: 'Speaker mapping: user=$userName; char=$charName.',
        zhTW: '發言者對應：user=$userName；char=$charName。',
      ),
    );
    if (previousSummary.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(L.pick(en: '【Previous Summary】', zhTW: '【前次摘要】'))
        ..writeln(previousSummary);
    }
    buffer
      ..writeln()
      ..writeln(L.pick(en: '【New Conversation】', zhTW: '【新對話內容】'))
      ..write(excerpt);
    return buffer.toString();
  }

  static Future<String> get _systemPrompt async {
    final sensitiveContentRule = L.pick(
      en: '''
For explicit or sensitive source content, summarize its general meaning in abstract, neutral terms while preserving emotions, consent, boundaries, consequences, and relationship changes.
''',
      zhTW: '''
原文包含露骨或敏感內容時，以抽象、中性的方式概括大意，保留對後續有用的情緒、同意、界線、後果與關係變化。
''',
    );
    return '${await ContextCompressor.compressionPromptForCurrentMode()}\n\n'
        '$sensitiveContentRule';
  }

  static Future<String> _systemPromptForCharacter(String charName) async =>
      '${await _systemPrompt}\n\n${ContextCompressor.characterOnlyTimelineRule(charName, today: DateTime.now())}';
}
