import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/token_estimator.dart';

void main() {
  group('provider cache thresholds', () {
    CacheThresholdInfo info(String provider, String model) =>
        TokenEstimator.cacheThresholdInfoForModel(
          provider: provider,
          model: model,
        );

    test('Gemini current models use Google published minimums', () {
      expect(info('gemini', 'gemini-4-argon').minimumTokens, 4096);
      expect(info('gemini', 'gemini-3.8-flash').minimumTokens, 4096);
      expect(info('gemini', 'gemini-3.7-flash').minimumTokens, 4096);
      expect(info('gemini', 'gemini-3.6-flash').minimumTokens, 4096);
      expect(info('gemini', 'gemini-3.5-flash').minimumTokens, 4096);
      expect(info('gemini', 'gemini-3.1-pro-preview').minimumTokens, 4096);
      expect(info('gemini', 'gemini-2.5-flash').minimumTokens, 2048);
      expect(info('gemini', 'gemini-2.5-pro').minimumTokens, 2048);
      expect(
        TokenEstimator.supportsCloseWindowKeepAlive(
          provider: 'gemini',
          model: 'gemini-4-argon',
        ),
        isFalse,
      );
      expect(
        TokenEstimator.supportsCloseWindowKeepAlive(
          provider: 'openrouter',
          model: 'google/gemini-4-argon',
        ),
        isFalse,
      );
      expect(
        TokenEstimator.supportsCloseWindowKeepAlive(
          provider: 'gemini',
          model: 'gemini-3.8-flash',
        ),
        isTrue,
      );
    });

    test('Claude thresholds track the current per-model table', () {
      expect(info('openrouter', 'anthropic/claude-opus-5').minimumTokens, 512);
      expect(
        info('openrouter', 'anthropic/claude-opus-4.8').minimumTokens,
        1024,
      );
      expect(
        info('openrouter', 'anthropic/claude-opus-4.7').minimumTokens,
        4096,
      );
      expect(
        info('openrouter', 'anthropic/claude-opus-4.6').minimumTokens,
        4096,
      );
      expect(
        info('openrouter', 'anthropic/claude-sonnet-4.6').minimumTokens,
        1024,
      );
      expect(
        info('openrouter', 'anthropic/claude-haiku-4.5').minimumTokens,
        4096,
      );
      expect(
        info('openrouter', 'anthropic/claude-haiku-3.5').minimumTokens,
        2048,
      );
    });

    test('automatic and routed caches do not invent a fixed minimum', () {
      expect(info('deepseek', 'deepseek-chat').minimumTokens, 64);
      expect(info('qwen', 'qwen-plus').minimumTokens, 1024);
      expect(
        info('xai', 'grok-4.6').kind,
        CacheThresholdKind.automaticWithoutPublishedMinimum,
      );
      expect(info('xai', 'grok-4.6').minimumTokens, isNull);
      expect(
        info('deepinfra', 'Qwen/Qwen3.8-Flash').kind,
        CacheThresholdKind.automaticWithoutPublishedMinimum,
      );
      expect(
        info('openai_compatible', 'private-model').kind,
        CacheThresholdKind.routeDependent,
      );
      expect(info('openai_compatible', 'private-model').minimumTokens, isNull);
      expect(
        info('thinking_machines', 'tinker/inkling').kind,
        CacheThresholdKind.unavailable,
      );
    });

    test('OpenAI models routed by OpenRouter use its documented minimum', () {
      expect(info('openrouter', 'openai/gpt-5.6').minimumTokens, 1024);
    });
  });
}
