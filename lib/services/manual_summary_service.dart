import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../memory/database.dart';
import '../models/message.dart';
import 'user_persona_service.dart';
import '../models/chat_session_identity.dart';
import '../models/context_mode.dart';
import 'character_timeline_service.dart';
import 'rp_character_timeline_service.dart';
import 'rp_story_service.dart';
import 'rp_story_state_service.dart';
import 'rp_worldbook_service.dart';
import 'context_compressor.dart';
import 'api_adapter.dart';
import 'local_ai_service.dart';
import 'settings/api_settings.dart';
import 'settings/memory_settings.dart';
import 'settings/user_settings.dart';
import 'token_estimator.dart';
import 'token_tracker.dart';
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
    final conversation = await DatabaseHelper.getConversation(conversationId);
    final rawUser = conversation == null
        ? await UserSettings.getUserName()
        : (await UserPersonaService.personaForConversation(
            conversation,
          )).displayName;
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

    final identity = ChatSessionIdentity.fromConversation(
      expectedConversationId: conversationId,
      conversation: await DatabaseHelper.getConversation(conversationId),
    );
    final selectedSourceMessageIds =
        sourceMessages
            .map((message) => message.id)
            .whereType<int>()
            .toList(growable: false)
          ..sort();
    final rewriteTarget = selectedSourceMessageIds.isEmpty
        ? null
        : await DatabaseHelper.getContextSummaryByExactSourceSpan(
            characterId: characterId,
            contextMode: identity.contextMode,
            continuityId: identity.continuityId,
            conversationId: conversationId,
            sourceMessageStartId: selectedSourceMessageIds.first,
            sourceMessageEndId: selectedSourceMessageIds.last,
          );
    final summaries = await DatabaseHelper.getContextSummaries(
      characterId,
      contextMode: identity.contextMode,
      continuityId: identity.continuityId,
    );
    final previousSummary = rewriteTarget != null
        ? (rewriteTarget['content'] as String? ?? '').trim()
        : summaries.isEmpty
        ? ''
        : (summaries.last['content'] as String? ?? '').trim();
    final windowId = await DatabaseHelper.ensureConversationWindowSummaryId(
      conversationId,
    );
    final rawResponse = await _callSummaryModel(
      cleanedExcerpt,
      characterId: characterId,
      userName: userName,
      charName: charName,
      previousSummary: previousSummary,
      fallbackExcerpt: fallbackExcerpt,
      contextMode: identity.contextMode,
      conversationId: conversationId,
      continuityId: identity.continuityId,
      reviseExistingSummary: rewriteTarget != null,
      sourceWindowId: windowId,
      sourceMessageStartId: selectedSourceMessageIds.isEmpty
          ? null
          : selectedSourceMessageIds.first,
      sourceMessageEndId: selectedSourceMessageIds.isEmpty
          ? null
          : selectedSourceMessageIds.last,
    );
    final decoded = ContextCompressor.decodeSummaryEnvelope(rawResponse);
    if (identity.contextMode == ContextMode.rp &&
        decoded.storylineId.isNotEmpty &&
        decoded.storylineId != identity.continuityId) {
      throw Exception('摘要模型返回了錯誤的故事線');
    }
    final content = identity.contextMode == ContextMode.rp
        ? ContextCompressor.normalizeRpSummaryFormat(decoded.summary)
        : ContextCompressor.normalizeSummaryFormat(decoded.summary);
    if (content.isEmpty) {
      throw Exception('摘要模型沒有返回內容');
    }
    if (_looksLikeRefusalContent(content)) {
      throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
    }

    // 手動摘要也要走本地明確生理期掃描；不能只依賴摘要模型輸出
    // timeline，否則「昨天來的生理期」等可驗證句子可能被模型漏掉。
    final explicitMenstrualChanges =
        sourceMessages.isEmpty || identity.contextMode == ContextMode.rp
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
    if (sourceMessages.isNotEmpty &&
        identity.contextMode == ContextMode.daily) {
      timelineCandidates =
          await ContextCompressor.recoverMissingMenstrualCandidates(
            messages: sourceMessages,
            candidates: timelineCandidates,
            characterId: characterId,
          );
    }
    final dailyTimelineChanges =
        sourceMessages.isEmpty || identity.contextMode == ContextMode.rp
        ? 0
        : await CharacterTimelineService.storeSummaryCandidates(
            characterId: characterId,
            candidates: timelineCandidates,
            sourceMessages: sourceMessages,
          );

    final savedContent = content;
    final tokenCount = TokenEstimator.estimate(savedContent);
    final sourceMessageIds =
        sourceMessages
            .map((message) => message.id)
            .whereType<int>()
            .toList(growable: false)
          ..sort();
    final id = await DatabaseHelper.insertContextSummary(
      characterId: characterId,
      content: savedContent,
      tokenCount: tokenCount,
      sourceWindowId: windowId,
      sourceConversationId: conversationId,
      sourceMessageStartId: sourceMessageIds.isEmpty
          ? null
          : sourceMessageIds.first,
      sourceMessageEndId: sourceMessageIds.isEmpty
          ? null
          : sourceMessageIds.last,
      contextMode: identity.contextMode,
      continuityId: identity.continuityId,
      expectedSourceMessages: sourceMessages,
      replaceSummaryId: rewriteTarget?['id'] as int?,
    );
    if (id <= 0) {
      throw StateError('Summary source changed while generating');
    }
    final rpTimelineChanges =
        identity.contextMode == ContextMode.rp && sourceMessages.isNotEmpty
        ? await RpCharacterTimelineService.storeSummaryCandidates(
            characterId: characterId,
            continuityId: identity.continuityId,
            sourceConversationId: conversationId,
            candidates: timelineCandidates,
            sourceMessages: sourceMessages,
            sourceSummaryId: id,
          )
        : 0;
    final modelTimelineChanges = dailyTimelineChanges + rpTimelineChanges;
    final timelineChanges = explicitMenstrualChanges + modelTimelineChanges;
    debugPrint(
      '[TimelineDebug] manual summary stored: char=$characterId '
      'modelChanges=$modelTimelineChanges totalChanges=$timelineChanges',
    );
    if (identity.contextMode == ContextMode.rp) {
      await RpStoryService.storeExtraction(
        characterId: characterId,
        continuityId: identity.continuityId,
        sourceConversationId: conversationId,
        characters: decoded.storyCharacters,
        relationships: decoded.relationships,
        sourceMessages: sourceMessages,
        sourceSummaryId: id,
      );
      await RpStoryStateService.storeExtraction(
        characterId: characterId,
        continuityId: identity.continuityId,
        sourceConversationId: conversationId,
        states: decoded.storyStates,
        sourceMessages: sourceMessages,
        sourceSummaryId: id,
      );
    }
    await ContextCompressor.recycleSupersededSummaries(
      characterId,
      contextMode: identity.contextMode,
      continuityId: identity.continuityId,
    );
    if (identity.contextMode == ContextMode.rp) {
      unawaited(
        RpWorldbookService.maybeProcessAfterSummary(
          characterId: characterId,
          continuityId: identity.continuityId,
        ),
      );
    }

    return ManualSummaryResult(
      id: id,
      content: savedContent,
      tokenCount: tokenCount,
      timelineChanges: timelineChanges,
    );
  }

  static Future<String> _callSummaryModel(
    String excerpt, {
    required String characterId,
    required String userName,
    required String charName,
    required String previousSummary,
    required String fallbackExcerpt,
    required ContextMode contextMode,
    required String conversationId,
    required String continuityId,
    required String sourceWindowId,
    required int? sourceMessageStartId,
    required int? sourceMessageEndId,
    bool reviseExistingSummary = false,
  }) async {
    try {
      final rpMaxChars = contextMode == ContextMode.rp
          ? await ContextCompressor.effectiveRpSummaryMaxChars(
              characterId: characterId,
              continuityId: continuityId,
            )
          : 3000;
      final systemPrompt = _decorateSystemPrompt(
        await ContextCompressor.summaryPromptForRequest(
          contextMode: contextMode,
          characterId: characterId,
          continuityId: continuityId,
        ),
        charName: charName,
        contextMode: contextMode,
      );
      final source = await MemorySettings.getSummarySource();
      final rpArchiveContext = contextMode == ContextMode.rp
          ? await ContextCompressor.buildRpArchiveContext(
              characterId: characterId,
              continuityId: continuityId,
              conversationId: conversationId,
              sourceText: excerpt,
            )
          : '';
      final rpSourceRange = contextMode == ContextMode.rp
          ? jsonEncode(<String, Object?>{
              'storyline_id': continuityId,
              'source_window_id': sourceWindowId,
              'source_conversation_id': conversationId,
              'source_message_start_id': sourceMessageStartId,
              'source_message_end_id': sourceMessageEndId,
            })
          : '';
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
                contextMode,
                reviseExistingSummary: reviseExistingSummary,
                rpArchiveContext: rpArchiveContext,
                rpSourceRange: rpSourceRange,
              ),
            },
          ],
          model: 'local',
          systemPrompt: systemPrompt,
        );
      }

      var model = await MemorySettings.getSummaryModel();
      if (model.isEmpty) {
        model = await ApiSettings.getModel();
      }

      final provider = await ApiSettings.resolveSummaryModelProvider(model);
      if (provider == 'openrouter') {
        return await _callOpenRouter(
          characterId: characterId,
          model: model,
          excerpt: excerpt,
          userName: userName,
          charName: charName,
          previousSummary: previousSummary,
          fallbackExcerpt: fallbackExcerpt,
          contextMode: contextMode,
          rpMaxChars: rpMaxChars,
          systemPrompt: systemPrompt,
          rpArchiveContext: rpArchiveContext,
          rpSourceRange: rpSourceRange,
          reviseExistingSummary: reviseExistingSummary,
        );
      }

      final adapter = await ApiSettings.buildAdapterForSummaryModel(model);
      ApiUsage? usage;
      final response = await adapter.sendMessage(
        messages: [
          {
            'role': 'user',
            'content': _buildUserPrompt(
              excerpt,
              userName,
              charName,
              previousSummary,
              contextMode,
              reviseExistingSummary: reviseExistingSummary,
              rpArchiveContext: rpArchiveContext,
              rpSourceRange: rpSourceRange,
            ),
          },
        ],
        model: model,
        systemPrompt: systemPrompt,
        onUsage: (value) => usage = value,
      );
      await TokenTracker().recordRealUsage(
        provider: provider,
        model: model,
        usage: usage ?? const ApiUsage(),
        characterId: characterId,
        requestKind: ApiRequestKind.summary,
      );
      return response;
    } catch (e) {
      if (e is ManualSummaryPolicyFailure) rethrow;
      if (_looksLikePolicyError(e)) {
        throw ManualSummaryPolicyFailure(excerpt: fallbackExcerpt);
      }
      rethrow;
    }
  }

  static Future<String> _callOpenRouter({
    required String characterId,
    required String model,
    required String excerpt,
    required String userName,
    required String charName,
    required String previousSummary,
    required String fallbackExcerpt,
    required ContextMode contextMode,
    required int rpMaxChars,
    required String systemPrompt,
    required String rpArchiveContext,
    required String rpSourceRange,
    bool reviseExistingSummary = false,
  }) async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    if (apiKey.isEmpty) {
      throw Exception('OpenRouter API Key 未設定');
    }

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
            contextMode,
            reviseExistingSummary: reviseExistingSummary,
            rpArchiveContext: rpArchiveContext,
            rpSourceRange: rpSourceRange,
          ),
        },
      ],
      'stream': false,
      'max_tokens': contextMode == ContextMode.rp
          ? (rpMaxChars * 2).clamp(1800, 24000)
          : 1800,
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

    final usage = _usageFromOpenRouter(data['usage']);
    await TokenTracker().recordRealUsage(
      provider: 'openrouter',
      model: model,
      usage: usage ?? const ApiUsage(),
      characterId: characterId,
      requestKind: ApiRequestKind.summary,
    );

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

  static ApiUsage? _usageFromOpenRouter(Object? raw) {
    if (raw is! Map) return null;
    int number(Object? value) => value is num ? value.toInt() : 0;

    final promptDetails = raw['prompt_tokens_details'];
    final completionDetails =
        raw['completion_tokens_details'] ?? raw['output_tokens_details'];
    final prompt = number(raw['prompt_tokens'] ?? raw['input_tokens']);
    final completion = number(raw['completion_tokens'] ?? raw['output_tokens']);
    final cacheRead = promptDetails is Map
        ? number(promptDetails['cached_tokens'])
        : number(raw['cache_read_input_tokens']);
    final cacheCreation = number(raw['cache_creation_input_tokens']);
    final diagnostics = <String, Object?>{};
    final actualCost = raw['cost'];
    if (actualCost is num) {
      diagnostics['actual_cost_usd'] = actualCost.toDouble();
      diagnostics['actual_cost_source'] = 'openrouter_usage';
    }
    if (prompt == 0 && completion == 0 && diagnostics.isEmpty) return null;
    return ApiUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cacheReadTokens: cacheRead,
      cacheCreationTokens: cacheCreation,
      raw: <String, int>{
        'prompt_tokens': prompt,
        'completion_tokens': completion,
        'cache_read': cacheRead,
        'cache_creation': cacheCreation,
        if (completionDetails is Map)
          'reasoning_tokens': number(completionDetails['reasoning_tokens']),
      },
      diagnostics: diagnostics,
    );
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
    ContextMode contextMode, {
    String rpArchiveContext = '',
    String rpSourceRange = '',
    bool reviseExistingSummary = false,
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
      L.pick(
        en: 'Speaker mapping: user=$userName; char=$charName.',
        zhTW: '發言者對應：user=$userName；char=$charName。',
      ),
    );
    if (contextMode == ContextMode.rp) {
      if (rpArchiveContext.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln(rpArchiveContext);
      }
      buffer
        ..writeln()
        ..writeln(
          L.pick(
            en: reviseExistingSummary
                ? '【Story Dossier Revision Target】'
                : '【Existing Story Dossier】',
            zhTW: reviseExistingSummary ? '【本次要覆蓋的既有劇情摘要】' : '【既有劇情摘要】',
            zhCN: reviseExistingSummary ? '【本次要覆盖的既有剧情摘要】' : '【既有剧情摘要】',
          ),
        )
        ..writeln(previousSummary);
      if (rpSourceRange.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln(
            L.pick(
              en: '【Summary Source Range】',
              zhTW: '【摘要來源範圍】',
              zhCN: '【摘要来源范围】',
            ),
          )
          ..writeln(rpSourceRange);
      }
    } else if (previousSummary.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(L.pick(en: '【Previous Summary】', zhTW: '【前次摘要】'))
        ..writeln(previousSummary);
    }
    buffer
      ..writeln()
      ..writeln(
        contextMode == ContextMode.rp
            ? L.pick(
                en: '【New Dialogue to Archive】',
                zhTW: '【本輪待歸檔對話】',
                zhCN: '【本轮待归档对话】',
              )
            : L.pick(en: '【New Conversation】', zhTW: '【新對話內容】'),
      )
      ..write(excerpt);
    return buffer.toString();
  }

  static String _decorateSystemPrompt(
    String base, {
    required String charName,
    required ContextMode contextMode,
  }) {
    final sensitiveContentRule = L.pick(
      en: '''
For explicit or sensitive source content, summarize its general meaning in abstract, neutral terms while preserving emotions, consent, boundaries, consequences, and relationship changes.
''',
      zhTW: '''
原文包含露骨或敏感內容時，以抽象、中性的方式概括大意，保留對後續有用的情緒、同意、界線、後果與關係變化。
''',
    );
    final prompt = '$base\n\n$sensitiveContentRule';
    if (contextMode == ContextMode.rp) return prompt;
    return '$prompt\n\n${ContextCompressor.characterOnlyTimelineRule(charName, today: DateTime.now())}';
  }
}
