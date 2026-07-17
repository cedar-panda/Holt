import 'settings/memory_settings.dart';
import 'settings/api_settings.dart';
import 'token_estimator.dart';

enum ModelCostPolicyNotice {
  none,
  inklingContextLimitEnabled,
  claudeCacheRecommended,
}

class ModelCostPolicyResult {
  final ModelCostPolicyNotice notice;
  final bool changed;

  const ModelCostPolicyResult({
    this.notice = ModelCostPolicyNotice.none,
    this.changed = false,
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
    final wasEnabled = await MemorySettings.getEnablePromptCaching();

    if (enabled && !wasEnabled) {
      // 母開關重新開啟時，子開關保持關閉，交由用戶明確選擇。
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
    }
    await MemorySettings.saveEnablePromptCaching(enabled);

    if (enabled) {
      await MemorySettings.saveContextLimitEnabled(false);
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    } else {
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
      await MemorySettings.saveKeepAliveEnabled(false);
    }
  }

  static Future<void> setContextLimitEnabled(bool enabled) async {
    final wasEnabled = await MemorySettings.getContextLimitEnabled();

    if (enabled && !wasEnabled) {
      // 母開關重新開啟時，不恢復先前遺留的動態摘要狀態。
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    }
    await MemorySettings.saveContextLimitEnabled(enabled);

    if (enabled) {
      await MemorySettings.saveEnablePromptCaching(false);
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
      await MemorySettings.saveKeepAliveEnabled(false);
    } else {
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    }
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

      await setPromptCachingEnabled(false);
      await setContextLimitEnabled(true);

      final changed =
          cacheEnabled ||
          cacheSummaryEnabled ||
          keepAliveEnabled ||
          !contextEnabled ||
          staleContextSummary;
      return ModelCostPolicyResult(
        notice: changed
            ? ModelCostPolicyNotice.inklingContextLimitEnabled
            : ModelCostPolicyNotice.none,
        changed: changed,
      );
    }

    if (TokenEstimator.isClaudePromptCacheModel(
      provider: normalizedProvider,
      model: model,
    )) {
      final cacheEnabled = await MemorySettings.getEnablePromptCaching();
      if (!cacheEnabled) {
        return const ModelCostPolicyResult(
          notice: ModelCostPolicyNotice.claudeCacheRecommended,
        );
      }
    }

    return const ModelCostPolicyResult();
  }
}
