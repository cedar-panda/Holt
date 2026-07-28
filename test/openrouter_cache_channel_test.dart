import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/openrouter_service.dart';
import 'package:project_yanci/services/prompt_cache_channels.dart';

bool _hasCacheControl(dynamic content) {
  return content is List &&
      content.whereType<Map>().any(
        (block) => block.containsKey('cache_control'),
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
    });
    CacheSession.conversationId = 'dual-channel-conversation';
    OpenRouterService.resetCacheStats();
    OpenRouterService.resetCacheChannelCheckpointsForTesting();
  });

  test(
    'text and call share sticky session but keep independent resume caches',
    () async {
      final service = OpenRouterService(apiKey: 'test');
      final staticPrefix = List<String>.filled(
        200,
        'STATIC CHARACTER PREFIX',
      ).join(' ');
      final textPrompt = StructuredPrompt(
        staticPart: staticPrefix,
        dynamicPart: 'LIVE TEXT',
        cacheStableDynamicPart: 'STABLE TEXT',
        cacheChannel: PromptCacheChannel.text,
      );
      final callPrompt = StructuredPrompt(
        staticPart: staticPrefix,
        dynamicPart: 'LIVE CALL',
        cacheStableDynamicPart: 'STABLE CALL',
        cacheChannel: PromptCacheChannel.call,
      );
      final firstTextHistory = <Map<String, String>>[
        {'role': 'user', 'content': 'text user 0'},
        {'role': 'assistant', 'content': 'text assistant checkpoint'},
        {'role': 'user', 'content': 'text user 1'},
      ];

      final firstText = await service.debugBuildBodyForTesting(
        messages: firstTextHistory,
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: textPrompt,
      );
      final textSession = firstText['session_id'];
      expect(textSession, 'yanci_dual-channel-conversation');
      expect(
        OpenRouterService.lastCacheDiagnostics['cache_channel'],
        PromptCacheChannel.text,
      );

      final callHistory = <Map<String, String>>[
        ...firstTextHistory,
        {'role': 'assistant', 'content': 'text assistant 1'},
        {'role': 'user', 'content': '[call_action:dial_to_character]'},
      ];
      final firstCall = await service.debugBuildBodyForTesting(
        messages: callHistory,
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: callPrompt,
      );
      expect(firstCall['session_id'], textSession);
      expect(
        OpenRouterService.lastCacheDiagnostics['cache_channel'],
        PromptCacheChannel.call,
      );
      expect(
        OpenRouterService.lastCacheDiagnostics['channel_resume_indices'],
        isEmpty,
      );

      final longTextReturn = <Map<String, String>>[...firstTextHistory];
      for (var i = 0; i < 12; i++) {
        longTextReturn.add({
          'role': 'assistant',
          'content': 'call assistant $i',
        });
        longTextReturn.add({'role': 'user', 'content': 'call user $i'});
      }
      longTextReturn.add({
        'role': 'assistant',
        'content': 'call ended assistant',
      });
      longTextReturn.add({'role': 'user', 'content': 'back to text'});

      final resumedText = await service.debugBuildBodyForTesting(
        messages: longTextReturn,
        model: 'anthropic/claude-sonnet-4',
        structuredPrompt: textPrompt,
      );
      final diagnostics = OpenRouterService.lastCacheDiagnostics;
      expect(resumedText['session_id'], textSession);
      expect(diagnostics['cache_channel'], PromptCacheChannel.text);
      expect(diagnostics['channel_resume_indices'], contains(1));

      final outgoing = resumedText['messages'] as List;
      // One system message precedes source history, so source index 1 is body 2.
      expect(_hasCacheControl((outgoing[2] as Map)['content']), isTrue);
      final explicitBreakpoints = outgoing
          .whereType<Map>()
          .where((message) => _hasCacheControl(message['content']))
          .length;
      expect(explicitBreakpoints, lessThanOrEqualTo(4));
    },
  );
}
