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
  }) {
    final service = OpenRouterService(apiKey: 'test', thinkingEnabled: thinking);
    return service.debugBuildBodyForTesting(
      messages: const <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'hello'},
      ],
      model: model,
      structuredPrompt: StructuredPrompt(staticPart: 'stable role'),
    );
  }

  test('Claude Sonnet 5.5 never sends enabled:false when Thinking is off',
      () async {
    final body = await buildFor('anthropic/claude-sonnet-5.5', thinking: false);
    expect(body['reasoning'], <String, dynamic>{
      'effort': 'low',
      'exclude': true,
    });
    expect(body['max_tokens'], 8192);
  });

  test('Claude Opus 5.5 exposes medium reasoning when Thinking is on',
      () async {
    final body = await buildFor('anthropic/claude-opus-5.5', thinking: true);
    expect(body['reasoning'], <String, dynamic>{
      'effort': 'medium',
      'exclude': false,
    });
  });

  test('Models without mandatory reasoning keep the explicit off switch',
      () async {
    final body = await buildFor('anthropic/claude-sonnet-4.5', thinking: false);
    expect(body['reasoning'], <String, dynamic>{
      'enabled': false,
      'exclude': true,
    });
    expect(body['max_tokens'], 4096);
  });
}
