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

enum EffectiveCostMode { none, promptCache, contextLimit }

class EffectiveCostStrategy {
  final EffectiveCostMode mode;
  final bool cacheSummaryEnabled;
  final bool contextSummaryEnabled;

  const EffectiveCostStrategy({
    required this.mode,
    this.cacheSummaryEnabled = false,
    this.contextSummaryEnabled = false,
  });

  bool get promptCacheEnabled => mode == EffectiveCostMode.promptCache;
  bool get contextLimitEnabled => mode == EffectiveCostMode.contextLimit;
}

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
  /// Resolves restored or legacy contradictory settings without rewriting
  /// preferences during a request. All request-building paths should consume
  /// this result rather than interpreting the two switches independently.
  static Future<EffectiveCostStrategy> resolveEffectiveStrategy({
    required String provider,
    required String model,
  }) async {
    final cacheRequested = await MemorySettings.getEnablePromptCaching();
    final contextRequested = await MemorySettings.getContextLimitEnabled();
    final cacheInfo = TokenEstimator.cacheThresholdInfoForModel(
      provider: provider.trim().toLowerCase(),
      model: model,
    );
    final cacheSupported = cacheInfo.kind != CacheThresholdKind.unavailable;

    if (cacheRequested && cacheSupported) {
      return EffectiveCostStrategy(
        mode: EffectiveCostMode.promptCache,
        cacheSummaryEnabled:
            await MemorySettings.getCacheWindowSummaryEnabled(),
      );
    }
    if (contextRequested) {
      return EffectiveCostStrategy(
        mode: EffectiveCostMode.contextLimit,
        contextSummaryEnabled:
            await MemorySettings.getContextWindowSummaryEnabled(),
      );
    }
    return const EffectiveCostStrategy(mode: EffectiveCostMode.none);
  }

  static Future<EffectiveCostStrategy> resolveCurrentStrategy() async {
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    return resolveEffectiveStrategy(provider: provider, model: model);
  }

  /// Re-applies the same cost rule after startup or a preferences restore.
  static Future<ModelCostPolicyResult> validateCurrentSelection() async {
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    final apiKey = provider == 'thinking_machines'
        ? await ApiSettings.getThinkingMachinesApiKey()
        : '';
    final normalized = await normalizePersistedStrategy(
      provider: provider,
      model: model,
    );
    final result = await applySelection(
      provider: provider,
      model: model,
      apiKey: apiKey,
    );
    return ModelCostPolicyResult(
      notice: result.notice,
      recommendation: result.recommendation,
      changed: normalized || result.changed,
    );
  }

  /// Repairs legacy or restored preferences where both mutually exclusive
  /// strategies are enabled. This runs only at startup/restore validation;
  /// request building remains read-only and still resolves defensively.
  static Future<bool> normalizePersistedStrategy({
    required String provider,
    required String model,
  }) async {
    final cacheRequested = await MemorySettings.getEnablePromptCaching();
    final contextRequested = await MemorySettings.getContextLimitEnabled();
    if (!cacheRequested || !contextRequested) return false;

    final cacheInfo = TokenEstimator.cacheThresholdInfoForModel(
      provider: provider.trim().toLowerCase(),
      model: model,
    );
    final cacheSupported = cacheInfo.kind != CacheThresholdKind.unavailable;
    if (cacheSupported) {
      await MemorySettings.saveContextLimitEnabled(false);
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    } else {
      await MemorySettings.saveEnablePromptCaching(false);
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
      await MemorySettings.saveKeepAliveEnabled(false);
    }
    return true;
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
