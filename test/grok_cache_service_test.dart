import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/grok_context_ledger.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/openrouter_service.dart';
import 'package:project_yanci/services/xai_service.dart';

bool _containsCacheControl(dynamic value) {
  if (value is Map) {
    if (value.containsKey('cache_control')) return true;
    return value.values.any(_containsCacheControl);
  }
  if (value is List) return value.any(_containsCacheControl);
  return false;
}

List<String> _userTexts(List messages) => messages
    .whereType<Map>()
    .where((message) => message['role'] == 'user')
    .map((message) {
      final content = message['content'];
      if (content is String) return content;
      if (content is List) {
        return content
            .whereType<Map>()
            .where((block) => block['type'] == 'text')
            .map((block) => '${block['text'] ?? ''}')
            .join();
      }
      return '';
    })
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'enable_prompt_caching': false,
    });
    CacheSession.conversationId = 'grok-cache-test';
    await L.setLocale('en');
    await GrokContextLedger.clearForTesting();
    XaiService.resetDiagnostics();
    OpenRouterService.resetCacheStats();
  });

  StructuredPrompt prompt(String live) => StructuredPrompt(
    staticPart: 'stable character',
    profilePart: 'stable profile',
    liveStatePart: live,
    cacheChannel: 'text',
  );

  test(
    'native xAI keeps runtime append-only and uses a stable affinity',
    () async {
      final service = XaiService(apiKey: 'test');
      final first = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'first real message'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=09:30'),
      );
      final firstMessages = first['messages'] as List;
      final firstAffinity = XaiService.lastDiagnostics['x_grok_conv_id'];

      final retry = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'first real message'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=09:31'),
      );

      expect(retry['messages'], firstMessages);
      expect(XaiService.lastDiagnostics['x_grok_conv_id'], firstAffinity);
      expect(XaiService.lastDiagnostics['runtime_event_reused'], isTrue);
      expect(_userTexts(firstMessages), <String>['first real message']);
      expect(_containsCacheControl(first), isFalse);

      final next = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'first real message'},
          <String, String>{'role': 'assistant', 'content': 'first reply'},
          <String, String>{'role': 'user', 'content': 'second real message'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=09:32'),
      );
      final nextMessages = next['messages'] as List;

      expect(nextMessages.take(firstMessages.length).toList(), firstMessages);
      expect(XaiService.lastDiagnostics['x_grok_conv_id'], firstAffinity);
      expect(_userTexts(nextMessages), <String>[
        'first real message',
        'second real message',
      ]);
    },
  );

  test(
    'native xAI restores hidden reasoning on the next assistant turn',
    () async {
      final service = XaiService(apiKey: 'test');
      await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'reason about this'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=10:00'),
      );
      final anchor = '${XaiService.lastDiagnostics['grok_turn_anchor']}';
      await GrokContextLedger.rememberReasoning(
        providerRoute: 'xai_native',
        model: 'grok-4.5',
        cacheChannel: 'text',
        turnAnchor: anchor,
        payload: const <String, dynamic>{
          'reasoning_content': 'encrypted-reasoning-payload',
        },
      );

      final next = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'reason about this'},
          <String, String>{'role': 'assistant', 'content': 'answer'},
          <String, String>{'role': 'user', 'content': 'continue'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=10:01'),
      );
      final assistant = (next['messages'] as List).whereType<Map>().firstWhere(
        (message) => message['role'] == 'assistant',
      );

      expect(assistant['reasoning_content'], 'encrypted-reasoning-payload');
      expect(XaiService.lastDiagnostics['reasoning_payload_preserved'], isTrue);
    },
  );

  test(
    'changed retained-history root opens a new Grok cache lineage',
    () async {
      final service = XaiService(apiKey: 'test');
      final first = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'old checkpoint'},
          <String, String>{'role': 'assistant', 'content': 'old reply'},
          <String, String>{'role': 'user', 'content': 'continue'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=10:10'),
      );
      final firstAffinity = first['messages'];
      final firstSession = XaiService.lastDiagnostics['x_grok_conv_id'];

      final reanchored = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'new summary checkpoint'},
          <String, String>{'role': 'user', 'content': 'continue'},
        ],
        model: 'grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=10:11'),
      );

      expect(XaiService.lastDiagnostics['x_grok_conv_id'], isNot(firstSession));
      expect(reanchored['messages'], isNot(firstAffinity));
      expect(
        (reanchored['messages'] as List).toString(),
        isNot(contains('old checkpoint')),
      );
    },
  );

  test(
    'OpenRouter Grok uses sticky automatic cache without Claude controls',
    () async {
      final service = OpenRouterService(apiKey: 'test');
      final first = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'hello grok'},
        ],
        model: 'x-ai/grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=11:00'),
      );
      final firstSession = first['session_id'];

      expect(firstSession, isNotEmpty);
      expect(_containsCacheControl(first), isFalse);
      expect(
        OpenRouterService.lastCacheDiagnostics['cache_mode'],
        'xai_implicit_prefix',
      );
      expect(OpenRouterService.lastCacheDiagnostics['enable_cache'], isTrue);
      expect(_userTexts(first['messages'] as List), <String>['hello grok']);

      final next = await service.debugBuildBodyForTesting(
        messages: const <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'hello grok'},
          <String, String>{'role': 'assistant', 'content': 'hello'},
          <String, String>{'role': 'user', 'content': 'continue grok'},
        ],
        model: 'x-ai/grok-4.5',
        structuredPrompt: prompt('CURRENT TIME=11:01'),
      );

      expect(next['session_id'], firstSession);
      expect(
        (next['messages'] as List)
            .take((first['messages'] as List).length)
            .toList(),
        first['messages'],
      );
      expect(_containsCacheControl(next), isFalse);
    },
  );
}
