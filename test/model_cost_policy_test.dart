import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:project_yanci/services/model_cost_policy.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'Inkling with a key disables cache tree and enables context limit',
    () async {
      await MemorySettings.saveEnablePromptCaching(true);
      await MemorySettings.saveCacheWindowSummaryEnabled(true);
      await MemorySettings.saveKeepAliveEnabled(true);
      await MemorySettings.saveContextLimitEnabled(false);
      await MemorySettings.saveContextWindowSummaryEnabled(true);

      final result = await ModelCostPolicy.applySelection(
        provider: 'thinking_machines',
        model: 'tinker/inkling-high',
        apiKey: 'tk_test',
      );

      expect(result.changed, isTrue);
      expect(result.notice, ModelCostPolicyNotice.inklingContextLimitEnabled);
      expect(await MemorySettings.getEnablePromptCaching(), isFalse);
      expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
      expect(await MemorySettings.getKeepAliveEnabled(), isFalse);
      expect(await MemorySettings.getContextLimitEnabled(), isTrue);
      expect(await MemorySettings.getContextWindowSummaryEnabled(), isFalse);
    },
  );

  test(
    'Inkling preserves context summary when its parent was already on',
    () async {
      await MemorySettings.saveContextLimitEnabled(true);
      await MemorySettings.saveContextWindowSummaryEnabled(true);
      await MemorySettings.saveCacheWindowSummaryEnabled(true);

      await ModelCostPolicy.applySelection(
        provider: 'thinking_machines',
        model: 'tinker/inkling-high',
        apiKey: 'tk_test',
      );

      expect(await MemorySettings.getContextLimitEnabled(), isTrue);
      expect(await MemorySettings.getContextWindowSummaryEnabled(), isTrue);
      expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    },
  );

  test('Inkling without a key does not change settings', () async {
    await MemorySettings.saveEnablePromptCaching(true);
    await MemorySettings.saveCacheWindowSummaryEnabled(true);
    await MemorySettings.saveContextLimitEnabled(false);

    final result = await ModelCostPolicy.applySelection(
      provider: 'thinking_machines',
      model: 'tinker/inkling-high',
    );

    expect(result.notice, ModelCostPolicyNotice.none);
    expect(result.changed, isFalse);
    expect(await MemorySettings.getEnablePromptCaching(), isTrue);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isTrue);
    expect(await MemorySettings.getContextLimitEnabled(), isFalse);
  });

  test('enabling cache disables the context parent and child', () async {
    await MemorySettings.saveContextLimitEnabled(true);
    await MemorySettings.saveContextWindowSummaryEnabled(true);
    await MemorySettings.saveCacheWindowSummaryEnabled(true);

    await ModelCostPolicy.setPromptCachingEnabled(true);

    expect(await MemorySettings.getEnablePromptCaching(), isTrue);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getContextLimitEnabled(), isFalse);
    expect(await MemorySettings.getContextWindowSummaryEnabled(), isFalse);
  });

  test('disabling cache also disables its summary and keep-alive', () async {
    await MemorySettings.saveEnablePromptCaching(true);
    await MemorySettings.saveCacheWindowSummaryEnabled(true);
    await MemorySettings.saveKeepAliveEnabled(true);

    await ModelCostPolicy.setPromptCachingEnabled(false);

    expect(await MemorySettings.getEnablePromptCaching(), isFalse);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getKeepAliveEnabled(), isFalse);
  });

  test('enabling context limit disables the whole cache tree', () async {
    await MemorySettings.saveEnablePromptCaching(true);
    await MemorySettings.saveCacheWindowSummaryEnabled(true);
    await MemorySettings.saveKeepAliveEnabled(true);
    await MemorySettings.saveContextWindowSummaryEnabled(true);

    await ModelCostPolicy.setContextLimitEnabled(true);

    expect(await MemorySettings.getContextLimitEnabled(), isTrue);
    expect(await MemorySettings.getContextWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getEnablePromptCaching(), isFalse);
    expect(await MemorySettings.getCacheWindowSummaryEnabled(), isFalse);
    expect(await MemorySettings.getKeepAliveEnabled(), isFalse);
  });

  test(
    'Claude with cache off returns reminder without changing settings',
    () async {
      await MemorySettings.saveContextLimitEnabled(true);
      await MemorySettings.saveContextWindowSummaryEnabled(true);

      final result = await ModelCostPolicy.applySelection(
        provider: 'openrouter',
        model: 'anthropic/claude-sonnet-4.5',
      );

      expect(result.notice, ModelCostPolicyNotice.claudeCacheRecommended);
      expect(result.changed, isFalse);
      expect(await MemorySettings.getEnablePromptCaching(), isFalse);
      expect(await MemorySettings.getContextLimitEnabled(), isTrue);
      expect(await MemorySettings.getContextWindowSummaryEnabled(), isTrue);
    },
  );

  test('Claude with cache on and non-Claude models need no reminder', () async {
    await MemorySettings.saveEnablePromptCaching(true);

    final claude = await ModelCostPolicy.applySelection(
      provider: 'bedrock',
      model: 'anthropic.claude-opus-4-6-v1:0',
    );
    final other = await ModelCostPolicy.applySelection(
      provider: 'openrouter',
      model: 'openai/gpt-5.5',
    );

    expect(claude.notice, ModelCostPolicyNotice.none);
    expect(other.notice, ModelCostPolicyNotice.none);
  });

  test(
    'custom Claude model without anthropic prefix still gets reminder',
    () async {
      final result = await ModelCostPolicy.applySelection(
        provider: 'openai_compatible',
        model: '[A2-量]claude-sonnet-4-6-thinking',
      );

      expect(result.notice, ModelCostPolicyNotice.claudeCacheRecommended);
    },
  );

  test('current selection validation reuses the same Claude policy', () async {
    SharedPreferences.setMockInitialValues({
      'api_provider': 'openrouter',
      'model': 'anthropic/claude-sonnet-4.5',
    });

    final result = await ModelCostPolicy.validateCurrentSelection();

    expect(result.notice, ModelCostPolicyNotice.claudeCacheRecommended);
    expect(result.changed, isFalse);
  });
}
