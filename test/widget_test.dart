import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/context_compressor.dart';
import 'package:project_yanci/services/openrouter_service.dart';
import 'package:project_yanci/services/marriage_service.dart';
import 'package:project_yanci/services/scratch_service.dart';
import 'package:project_yanci/services/token_estimator.dart';
import 'package:project_yanci/services/tool_prompts.dart';
import 'package:project_yanci/main.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/widgets/chat_bubble.dart';

void main() {
  test('YanciApp can be constructed', () {
    expect(const YanciApp(), isA<YanciApp>());
  });

  test('reply style switches do not duplicate concise instructions', () {
    final both = ToolPrompts.selectedReplyStyle(
      conciseOn: true,
      freeformOn: true,
      emotionEnabled: true,
      maxLines: 12,
    );
    final freeformOnly = ToolPrompts.selectedReplyStyle(
      conciseOn: false,
      freeformOn: true,
      emotionEnabled: true,
      maxLines: 12,
    );

    expect(both, freeformOnly);
    expect(both, contains('12'));
  });

  test('marriage certificate system note is never visible', () {
    const raw = '我想和你說件事\n[marriage_cert]（系統說明：這段對方看不到）';
    expect(MarriageService.stripHiddenCertMetadata(raw), '我想和你說件事');
  });

  test('character edits preserve creation and runtime-managed fields', () {
    final input = <String, dynamic>{
      'id': 'replacement-id',
      'name': 'Holt',
      'created_at': 'replacement-created-at',
    };

    final update = DatabaseHelper.sanitizeCharacterUpdates(
      input,
      updatedAt: 'new-updated-at',
    );

    expect(update, {'name': 'Holt', 'updated_at': 'new-updated-at'});
    expect(update.containsKey('self_notes'), isFalse);
    expect(update.containsKey('bio_clock'), isFalse);
    expect(update.containsKey('is_spider_web_enabled'), isFalse);
    expect(
      input,
      containsPair('created_at', 'replacement-created-at'),
      reason: 'sanitizing an edit must not mutate the caller payload',
    );
  });

  test('rolling cache breakpoints stop before the latest user message', () {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': [
          {'type': 'text', 'text': 'static'},
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'old user'},
        ],
      },
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'old assistant'},
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'latest user'},
        ],
      },
    ];

    final latestUserIndex = CacheBreakpoint.latestUserIndex(messages);
    CacheBreakpoint.applyRolling(
      messages,
      minIndex: 1,
      maxIndexExclusive: latestUserIndex,
      cacheControl: const {'type': 'ephemeral'},
    );

    final previousAssistant = messages[2]['content'] as List;
    final latestUser = messages[3]['content'] as List;

    expect(
      (previousAssistant.last as Map<String, dynamic>)['cache_control'],
      const {'type': 'ephemeral'},
    );
    expect(
      (latestUser.last as Map<String, dynamic>).containsKey('cache_control'),
      isFalse,
    );
  });

  test('OpenRouter Claude cache control uses one hour TTL', () {
    expect(
      TokenEstimator.promptCacheControl(
        provider: 'openrouter',
        model: 'anthropic/claude-sonnet-4',
      ),
      const {'type': 'ephemeral', 'ttl': '1h'},
    );
  });

  test('custom Claude model keeps one-hour cache renewal support', () {
    expect(
      TokenEstimator.supportsCloseWindowKeepAlive(
        provider: 'openai_compatible',
        model: '[A2-量]claude-sonnet-4-6-thinking',
      ),
      isTrue,
    );
  });

  test('window summary retention keeps several prompt blocks', () {
    expect(ContextCompressor.summaryCapTokens, greaterThanOrEqualTo(3600));
    expect(ContextCompressor.keywordCapTokens, greaterThanOrEqualTo(1800));
    expect(ContextCompressor.latestSummaryBlocksForPrompt, 4);
  });

  test(
    'OpenRouter cache body keeps dynamic prompt outside cached prefix',
    () async {
      SharedPreferences.setMockInitialValues({'enable_prompt_caching': true});
      CacheSession.conversationId = 'conv-test';
      OpenRouterService.resetCacheStats();

      final service = OpenRouterService(apiKey: 'test');
      final body = await service.debugBuildBodyForTesting(
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: StructuredPrompt(
          staticPart: 'static rules',
          profilePart: 'stable profile',
          liveStatePart: 'fresh dynamic CURRENT TIME=09:30',
        ),
        messages: const [
          {'role': 'user', 'content': 'old user'},
          {'role': 'assistant', 'content': 'old assistant'},
          {'role': 'user', 'content': 'latest user'},
        ],
      );

      expect(body['session_id'], 'yanci_conv-test');
      expect(body.containsKey('cache_control'), isFalse);

      final messages = body['messages'] as List;
      final system = messages.first as Map<String, dynamic>;
      final systemBlocks = system['content'] as List;
      expect(system['role'], 'system');
      expect(systemBlocks.length, 3);
      expect((systemBlocks[2] as Map<String, dynamic>)['cache_control'], const {
        'type': 'ephemeral',
        'ttl': '1h',
      });
      expect(
        systemBlocks.map((block) => (block as Map)['text']).join('\n'),
        isNot(contains('fresh dynamic')),
      );

      final previousAssistant = messages[2] as Map<String, dynamic>;
      final previousAssistantBlocks = previousAssistant['content'] as List;
      expect(
        (previousAssistantBlocks.first
            as Map<String, dynamic>)['cache_control'],
        const {'type': 'ephemeral', 'ttl': '1h'},
      );
      expect(
        (previousAssistantBlocks.last as Map<String, dynamic>)['text'],
        contains('fresh dynamic'),
      );
      expect(
        (previousAssistantBlocks.last as Map<String, dynamic>)['text'],
        contains('answer this first'),
      );

      final latestUser = messages[3] as Map<String, dynamic>;
      final latestUserBlocks = latestUser['content'] as List;
      expect(latestUserBlocks, hasLength(1));
      expect(
        (latestUserBlocks.single as Map<String, dynamic>)['text'],
        'latest user',
      );
      expect(
        (latestUserBlocks.single as Map<String, dynamic>).containsKey(
          'cache_control',
        ),
        isFalse,
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['latest_user_has_cache_control'],
        isFalse,
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['latest_user_focus'],
        isTrue,
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['roles_tail'],
        'user > assistant > user',
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['latest_user_preview'],
        'latest user',
      );
    },
  );

  test(
    'OpenRouter cache disabled still uses a separate runtime sidecar',
    () async {
      SharedPreferences.setMockInitialValues({'enable_prompt_caching': false});
      CacheSession.conversationId = 'conv-test';
      OpenRouterService.resetCacheStats();

      final service = OpenRouterService(apiKey: 'test');
      final body = await service.debugBuildBodyForTesting(
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: StructuredPrompt(
          staticPart: 'static rules',
          profilePart: 'stable profile',
          liveStatePart: 'fresh dynamic CURRENT TIME=09:30',
        ),
        messages: const [
          {'role': 'user', 'content': 'latest user'},
        ],
      );

      expect(body.containsKey('session_id'), isFalse);

      final messages = body['messages'] as List;
      final systems = messages
          .cast<Map<String, dynamic>>()
          .where((message) => message['role'] == 'system')
          .toList();
      expect(systems.first['content'], 'static rules');
      expect(
        ((systems.last['content'] as List).last
            as Map<String, dynamic>)['text'],
        contains('fresh dynamic'),
      );
      expect(
        ((systems.last['content'] as List).last
            as Map<String, dynamic>)['text'],
        contains('answer this first'),
      );
      expect(
        (messages[1] as Map<String, dynamic>)['content'],
        'stable profile',
      );
      final latestUser = messages[3] as Map<String, dynamic>;
      expect(latestUser['role'], 'user');
      expect(latestUser['content'], 'latest user');
      expect(OpenRouterService.lastCacheDiagnostics['enable_cache'], isFalse);
      expect(
        OpenRouterService.lastCacheDiagnostics['latest_user_focus'],
        isTrue,
      );
    },
  );

  test(
    'OpenRouter cache sends live turn context after cached window',
    () async {
      SharedPreferences.setMockInitialValues({'enable_prompt_caching': true});
      CacheSession.conversationId = 'conv-stable-runtime';
      OpenRouterService.resetCacheStats();

      final service = OpenRouterService(apiKey: 'test');
      final body = await service.debugBuildBodyForTesting(
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: StructuredPrompt(
          staticPart: 'static rules',
          windowPart: 'window memory at 08:00',
          liveStatePart: 'live memory at 09:30',
        ),
        messages: const [
          {'role': 'assistant', 'content': 'previous reply'},
          {'role': 'user', 'content': 'actual latest message'},
        ],
      );

      final messages = body['messages'] as List;
      final systemBlocks =
          (messages.first as Map<String, dynamic>)['content'] as List;
      expect(
        (systemBlocks[1] as Map<String, dynamic>)['text'],
        'window memory at 08:00',
      );
      expect(
        systemBlocks.map((block) => (block as Map)['text']).join('\n'),
        isNot(contains('live memory at 09:30')),
      );
      final previousAssistant = messages[1] as Map<String, dynamic>;
      expect(
        (previousAssistant['content'] as List)
            .map((block) => (block as Map)['text'])
            .join('\n'),
        contains('live memory at 09:30'),
      );
      final latestUser = messages.last as Map<String, dynamic>;
      final latestBlocks = latestUser['content'] as List;
      expect(latestBlocks, hasLength(1));
      expect(
        (latestBlocks.single as Map<String, dynamic>)['text'],
        'actual latest message',
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['dynamic_snapshot_active'],
        isFalse,
      );
    },
  );

  test('OpenRouter non-Claude models use the same runtime sidecar', () async {
    SharedPreferences.setMockInitialValues({'enable_prompt_caching': false});
    OpenRouterService.resetCacheStats();

    final service = OpenRouterService(apiKey: 'test');
    final body = await service.debugBuildBodyForTesting(
      model: 'google/gemini-2.5-flash',
      structuredPrompt: StructuredPrompt(
        staticPart: 'static rules',
        liveStatePart: 'fresh dynamic CURRENT TIME=09:30',
      ),
      messages: const [
        {'role': 'user', 'content': 'latest user'},
      ],
    );

    final messages = body['messages'] as List;
    final latestUser = messages.last as Map<String, dynamic>;
    expect(latestUser['content'], 'latest user');
    final runtimeSystem = messages[messages.length - 2] as Map<String, dynamic>;
    expect(runtimeSystem['role'], 'system');
    expect(runtimeSystem['content'], contains('fresh dynamic'));
    expect(
      OpenRouterService.lastCacheDiagnostics['latest_user_focus'],
      isFalse,
    );
  });

  test(
    'OpenRouter does not add focus markers without dynamic context',
    () async {
      SharedPreferences.setMockInitialValues({'enable_prompt_caching': true});
      OpenRouterService.resetCacheStats();

      final service = OpenRouterService(apiKey: 'test');
      final body = await service.debugBuildBodyForTesting(
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: StructuredPrompt(staticPart: 'static rules'),
        messages: const [
          {'role': 'user', 'content': 'latest user'},
        ],
      );

      final messages = body['messages'] as List;
      final latestUser = messages.last as Map<String, dynamic>;
      final blocks = latestUser['content'] as List;
      expect(blocks, hasLength(1));
      expect((blocks.single as Map<String, dynamic>)['text'], 'latest user');
      expect(
        OpenRouterService.lastCacheDiagnostics['latest_user_focus'],
        isFalse,
      );
    },
  );

  test('scratch card replay happens at most once then pays shells', () {
    for (var i = 0; i < 1000; i++) {
      final prizes = ScratchService.rollPrizes();
      final replayCount = prizes.where((p) => p.label == '再來一張').length;

      expect(replayCount, lessThanOrEqualTo(1));
      if (replayCount == 1) {
        expect(prizes.length, 2);
        expect(prizes.last.coins, greaterThan(0));
      }
    }
  });

  testWidgets('character chat bubbles expose a selection area', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatBubble(
            text: '可以選中的角色訊息',
            isUser: false,
            showToolbar: false,
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('user chat bubbles keep the long-press bubble menu path', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatBubble(text: '使用者訊息', isUser: true)),
      ),
    );

    expect(find.byType(SelectionArea), findsNothing);
    expect(find.byType(GestureDetector), findsWidgets);
  });
}
