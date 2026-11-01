import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/openrouter_service.dart';

bool _containsCacheControl(dynamic value) {
  if (value is Map) {
    if (value.containsKey('cache_control')) return true;
    return value.values.any(_containsCacheControl);
  }
  if (value is List) return value.any(_containsCacheControl);
  return false;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': true,
    });
    CacheSession.conversationId = 'argon-openrouter-window';
    OpenRouterService.resetCacheStats();
  });

  test(
    'OpenRouter Argon uses sticky implicit cache without cache_control',
    () async {
      final service = OpenRouterService(apiKey: 'test');
      final body = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'first turn'},
          <String, String>{'role': 'assistant', 'content': 'first answer'},
          <String, String>{'role': 'user', 'content': 'latest turn'},
        ],
        model: 'google/gemini-4-argon',
        structuredPrompt: StructuredPrompt(
          staticPart: 'stable role and world rules',
          windowPart: 'stable rolling summary',
          liveStatePart: 'current live state',
        ),
      );

      expect(body['session_id'], 'yanci_argon-openrouter-window');
      expect(body['max_tokens'], 32768);
      expect(body.containsKey('reasoning'), isFalse);
      expect(_containsCacheControl(body), isFalse);
      expect(body['messages'], hasLength(greaterThanOrEqualTo(6)));
      expect(
        OpenRouterService.lastCacheDiagnostics['cache_mode'],
        'openrouter_gemini_implicit_prefix',
      );
      expect(OpenRouterService.lastCacheDiagnostics['cache_implicit'], isTrue);
    },
  );

  test(
    'OpenRouter Argon exposes medium reasoning when Thinking is on',
    () async {
      final service = OpenRouterService(apiKey: 'test', thinkingEnabled: true);
      final body = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'hello'},
        ],
        model: 'google/gemini-4-argon',
        structuredPrompt: StructuredPrompt(staticPart: 'stable role'),
      );

      expect(body['reasoning'], <String, dynamic>{
        'effort': 'medium',
        'exclude': false,
      });
    },
  );
}
