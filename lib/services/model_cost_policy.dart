import 'settings/memory_settings.dart';
import 'settings/api_settings.dart';
import 'cache/gemini_cache_policy.dart';
import 'token_estimator.dart';

enum ModelCostPolicyNotice {
  none,
  inklingContextLimitRecommended,
  claudeCacheRecommended,
}

enum ModelCostModeRecommendation { promptCache, contextLimit }

class ModelCostPolicyResult {
  final ModelCostPolicyNotice notice;
  final bool changed;
  final ModelCostModeRecommendation? recommendation;

  const ModelCostPolicyResult({
    this.notice = ModelCostPolicyNotice.none,
    this.changed = false,
    this.recommendation,
  });
}

/// 模型費用設定的可見狀態規則。
///
/// 在用戶切換 provider／模型、保存有效 Inkling Key，以及啟動／還原後
/// 校驗一次；不在發送請求時暗中改寫設定。
class ModelCostPolicy {
  /// Re-applies the same cost rule after startup or a preferences restore.
  static Future<ModelCostPolicyResult> validateCurrentSelection() async {
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    final apiKey = provider == 'thinking_machines'
        ? await ApiSettings.getThinkingMachinesApiKey()
        : '';
    return applySelection(provider: provider, model: model, apiKey: apiKey);
  }

  static Future<void> setPromptCachingEnabled(bool enabled) async {
    await MemorySettings.saveEnablePromptCaching(enabled);

    if (enabled) {
      await MemorySettings.saveContextLimitEnabled(false);
      await MemorySettings.saveContextWindowSummaryEnabled(false);
      await MemorySettings.saveCacheWindowSummaryEnabled(
        await _hasSummaryModel(),
      );
    } else {
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
      await MemorySettings.saveKeepAliveEnabled(false);
    }
  }

  static Future<void> setContextLimitEnabled(bool enabled) async {
    await MemorySettings.saveContextLimitEnabled(enabled);

    if (enabled) {
      await MemorySettings.saveEnablePromptCaching(false);
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
      await MemorySettings.saveKeepAliveEnabled(false);
      await MemorySettings.saveContextWindowSummaryEnabled(
        await _hasSummaryModel(),
      );
    } else {
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    }
  }

  static Future<bool> _hasSummaryModel() async {
    return (await MemorySettings.getSummaryModel()).trim().isNotEmpty;
  }

  static Future<ModelCostModeRecommendation?> recommendationForSelection({
    required String provider,
    required String model,
  }) async {
    final normalizedProvider = provider.trim().toLowerCase();
    if (normalizedProvider == 'local' || model.trim().isEmpty) return null;

    final cacheInfo = TokenEstimator.cacheThresholdInfoForModel(
      provider: normalizedProvider,
      model: model,
    );
    final cacheAvailable =
        cacheInfo.kind == CacheThresholdKind.fixed ||
        cacheInfo.kind == CacheThresholdKind.automaticWithoutPublishedMinimum;
    if (cacheAvailable) {
      return await MemorySettings.getEnablePromptCaching()
          ? null
          : ModelCostModeRecommendation.promptCache;
    }
    return await MemorySettings.getContextLimitEnabled()
        ? null
        : ModelCostModeRecommendation.contextLimit;
  }

  static Future<ModelCostPolicyResult> applySelection({
    required String provider,
    required String model,
    String apiKey = '',
  }) async {
    final normalizedProvider = provider.toLowerCase();

    if (normalizedProvider == 'thinking_machines') {
      if (apiKey.trim().isEmpty) return const ModelCostPolicyResult();

      final cacheEnabled = await MemorySettings.getEnablePromptCaching();
      final cacheSummaryEnabled =
          await MemorySettings.getCacheWindowSummaryEnabled();
      final keepAliveEnabled = await MemorySettings.getKeepAliveEnabled();
      final contextEnabled = await MemorySettings.getContextLimitEnabled();
      final staleContextSummary =
          !contextEnabled &&
          await MemorySettings.getContextWindowSummaryEnabled();

      if (cacheEnabled || cacheSummaryEnabled || keepAliveEnabled) {
        await setPromptCachingEnabled(false);
      }
      if (staleContextSummary) {
        await MemorySettings.saveContextWindowSummaryEnabled(false);
      }

      final changed =
          cacheEnabled ||
          cacheSummaryEnabled ||
          keepAliveEnabled ||
          staleContextSummary;
      return ModelCostPolicyResult(
        notice: contextEnabled
            ? ModelCostPolicyNotice.none
            : ModelCostPolicyNotice.inklingContextLimitRecommended,
        changed: changed,
        recommendation: contextEnabled
            ? null
            : ModelCostModeRecommendation.contextLimit,
      );
    }

    // Gemini 4 Argon only exposes provider-managed implicit caching. It has no
    // client-renewable 1h TTL, so Keep-Alive cannot extend its cache lifetime.
    // Apply this at the shared model-selection layer so Gemini direct,
    // OpenRouter, startup restore, and every model picker behave identically.
    var changed = false;
    if (GeminiCachePolicy.usesImplicitCaching(model) &&
        await MemorySettings.getKeepAliveEnabled()) {
      await MemorySettings.saveKeepAliveEnabled(false);
      changed = true;
    }

    if (TokenEstimator.isClaudePromptCacheModel(
      provider: normalizedProvider,
      model: model,
    )) {
      final cacheEnabled = await MemorySettings.getEnablePromptCaching();
      if (!cacheEnabled) {
        await setPromptCachingEnabled(true);
        return const ModelCostPolicyResult(changed: true);
      }
    }

    return ModelCostPolicyResult(changed: changed);
  }
}
