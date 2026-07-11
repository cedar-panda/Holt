import '../memory/database.dart';
import 'token_estimator.dart';
import 'openrouter_service.dart';
import 'deepseek_service.dart';
import 'gemini_service.dart';
import 'aws_bedrock_service.dart';

/// Token 用量追蹤器（真實 API 用量 + 持久化）
class TokenTracker {
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cacheHitTokens = 0;

  int get promptTokens => _promptTokens;
  int get completionTokens => _completionTokens;
  int get totalTokens => _promptTokens + _completionTokens;
  int get cacheHitTokens => _cacheHitTokens;

  /// 從 API 回覆讀取真實用量並記錄到 DB
  Future<void> recordRealUsage({
    required String provider,
    required String model,
    String characterId = 'default',
  }) async {
    int prompt = 0, completion = 0, cacheHit = 0, cacheCreation = 0;

    // 讀取各 provider 的真實統計
    if (provider == 'openrouter') {
      final stats = OpenRouterService.lastCacheStats;
      prompt = stats['prompt_tokens'] ?? 0;
      completion = stats['completion_tokens'] ?? 0;
      cacheHit = stats['cache_read'] ?? 0;
      cacheCreation = stats['cache_creation'] ?? 0;
    } else if (provider == 'bedrock') {
      final stats = BedrockService.lastCacheStats;
      prompt = stats['prompt_tokens'] ?? 0;
      completion = stats['completion_tokens'] ?? 0;
      cacheHit = stats['cache_read'] ?? 0;
      cacheCreation = stats['cache_creation'] ?? 0;
    } else if (provider == 'deepseek') {
      final stats = DeepSeekService.lastCacheStats;
      prompt = stats['prompt_tokens'] ?? 0;
      completion = stats['completion_tokens'] ?? 0;
      cacheHit = stats['cache_hit'] ?? 0;
    } else if (provider == 'gemini') {
      final stats = GeminiService.lastCacheStats;
      prompt = stats['prompt_tokens'] ?? 0;
      completion = stats['completion_tokens'] ?? 0;
      cacheHit = stats['cached_tokens'] ?? 0;
    }

    // 如果 API 沒返回真實值，不記錄（避免寫入 0）
    if (prompt == 0 && completion == 0) return;

    _promptTokens += prompt;
    _completionTokens += completion;
    _cacheHitTokens += cacheHit;

    final cost = _estimateCost(
      model,
      prompt,
      completion,
      cacheHit,
      cacheCreation,
    );

    await DatabaseHelper.logUsage(
      provider: provider,
      model: model,
      characterId: characterId,
      promptTokens: prompt,
      completionTokens: completion,
      cacheHitTokens: cacheHit,
      cacheCreationTokens: cacheCreation,
      estimatedCost: cost,
    );
  }

  /// 用估算方式記錄（fallback）
  void addEstimated({String? prompt, String? completion}) {
    if (prompt != null) _promptTokens += estimateTokens(prompt);
    if (completion != null) {
      _completionTokens += estimateTokens(completion);
    }
  }

  // B6：估算統一走 TokenEstimator
  static int estimateTokens(String text) => TokenEstimator.estimate(text);

  String formatTokens() {
    if (totalTokens < 1000) return '$totalTokens';
    return '${(totalTokens / 1000).toStringAsFixed(1)}k';
  }

  String formatCost(String model) {
    final cost = _estimateCost(
      model,
      _promptTokens,
      _completionTokens,
      _cacheHitTokens,
    );
    if (cost < 0.001) return '< \$0.001';
    if (cost < 0.01) return '\$${cost.toStringAsFixed(4)}';
    return '\$${cost.toStringAsFixed(3)}';
  }

  void reset() {
    _promptTokens = 0;
    _completionTokens = 0;
    _cacheHitTokens = 0;
  }

  /// 計算費用（含緩存折扣與寫入加價）
  static double _estimateCost(
    String model,
    int prompt,
    int completion,
    int cacheHit, [
    int cacheCreation = 0,
  ]) {
    final prices = _getModelPrices(model);
    // 命中 0.1x；寫入 2x（1h TTL；5m 是 1.25x，按當前配置取 2x）
    var normalInput = prompt - cacheHit - cacheCreation;
    if (normalInput < 0) normalInput = 0;
    final inputCost =
        (normalInput * prices['input']! +
            cacheHit * prices['input']! * 0.1 +
            cacheCreation * prices['input']! * 2.0) /
        1000000;
    final outputCost = completion * prices['output']! / 1000000;
    return inputCost + outputCost;
  }

  static Map<String, double> _getModelPrices(String model) {
    final m = model.toLowerCase();

    if (m.contains('opus')) return {'input': 15.0, 'output': 75.0};
    if (m.contains('sonnet')) return {'input': 3.0, 'output': 15.0};
    if (m.contains('haiku')) return {'input': 0.25, 'output': 1.25};
    if (m.contains('gpt-4o')) return {'input': 2.5, 'output': 10.0};
    if (m.contains('gpt-4')) return {'input': 30.0, 'output': 60.0};
    if (m.contains('gemini') && m.contains('flash')) {
      return {'input': 0.075, 'output': 0.3};
    }
    if (m.contains('gemini') && m.contains('pro')) {
      return {'input': 1.25, 'output': 5.0};
    }
    if (m.contains('deepseek')) return {'input': 0.27, 'output': 1.1};
    if (m.contains('qwen')) return {'input': 0.3, 'output': 0.6};
    if (m.contains('mistral-large')) return {'input': 2.0, 'output': 6.0};

    return {'input': 1.0, 'output': 3.0};
  }
}
