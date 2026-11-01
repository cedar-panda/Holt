import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/openrouter_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CacheSession.conversationId = 'mandatory-reasoning-window';
    OpenRouterService.resetCacheStats();
  });

  Future<Map<String, dynamic>> buildFor(
    String model, {
    required bool thinking,
    String effort = 'medium',
  }) {
    final service = OpenRouterService(
      apiKey: 'test',
      thinkingEnabled: thinking,
      reasoningEffort: effort,
    );
    return service.debugBuildBodyForTesting(
      messages: const <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'hello'},
      ],
      model: model,
      structuredPrompt: StructuredPrompt(staticPart: 'stable role'),
    );
  }

  test(
    'Claude Sonnet 5.5 keeps provider default when reasoning is automatic',
    () async {
      final body = await buildFor(
        'anthropic/claude-sonnet-5.5',
        thinking: false,
      );
      expect(body.containsKey('reasoning'), isFalse);
      expect(body['max_tokens'], 8192);
    },
  );

  test(
    'Sonnet and Opus 5.5 keep native defaults when switch is off even with high strength',
    () async {
      for (final model in <String>[
        'anthropic/claude-sonnet-5.5',
        'anthropic/claude-opus-5.5',
      ]) {
        final body = await buildFor(model, thinking: false, effort: 'high');
        expect(body.containsKey('reasoning'), isFalse);
        expect(body['max_tokens'], 8192);
      }
    },
  );

  test(
    'Claude Opus 5.5 exposes medium reasoning when Thinking is on',
    () async {
      final body = await buildFor('anthropic/claude-opus-5.5', thinking: true);
      expect(body['reasoning'], <String, dynamic>{
        'effort': 'medium',
        'exclude': false,
      });
    },
  );

  test(
    'Optional reasoning models also omit the field in automatic mode',
    () async {
      final body = await buildFor(
        'anthropic/claude-sonnet-4.5',
        thinking: false,
      );
      expect(body.containsKey('reasoning'), isFalse);
      expect(body['max_tokens'], 4096);
    },
  );

  test('selected high effort reaches optional OpenRouter reasoning', () async {
    final body = await buildFor(
      'openai/gpt-reasoning',
      thinking: true,
      effort: 'high',
    );
    expect(body['reasoning'], <String, dynamic>{'effort': 'high'});
  });
}
