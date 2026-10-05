import '../memory/database.dart';
import 'api_adapter.dart';
import 'token_estimator.dart';

abstract final class ApiRequestKind {
  static const chat = 'chat';
  static const summary = 'summary';
  static const memory = 'memory';
  static const embedding = 'embedding';
  static const worldbook = 'worldbook';
  static const guide = 'guide';
  static const image = 'image';
  static const signature = 'signature';
  static const call = 'call';
  static const sticker = 'sticker';
  static const conversationTitle = 'conversation_title';
  static const keepAlive = 'keep_alive';
  static const tts = 'tts';
}

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
    required ApiUsage usage,
    String characterId = 'default',
    String requestKind = ApiRequestKind.chat,
  }) async {
    final prompt = usage.promptTokens;
    final completion = usage.completionTokens;
    final cacheHit = usage.cacheReadTokens;
    final cacheCreation = usage.cacheCreationTokens;

    _promptTokens += prompt;
    _completionTokens += completion;
    _cacheHitTokens += cacheHit;

    // Only store money returned by the provider. A guessed local price table
    // becomes incorrect as routes, tiers and model revisions change, and made
    // the dashboard look far more precise than the data really was.
    final actualCost = usage.diagnostics['actual_cost_usd'];
    final hasKnownCost =
        actualCost is num && actualCost.isFinite && actualCost >= 0;
    final cost = hasKnownCost ? actualCost.toDouble() : 0.0;

    await DatabaseHelper.logUsage(
      provider: provider,
      model: model,
      characterId: characterId,
      promptTokens: prompt,
      completionTokens: completion,
      cacheHitTokens: cacheHit,
      cacheCreationTokens: cacheCreation,
      estimatedCost: cost,
      requestKind: requestKind,
      costKnown: hasKnownCost,
    );
  }

  /// 記錄沒有 token 回傳、但確實送出的 API 請求（例如畫圖）。
  ///
  /// 圖片 API 多數只回圖片資料，不回 prompt/completion token。若供應商
  /// 沒有回傳實際費用，仍記錄請求次數，但不把本地估價當成可信費用。
  Future<void> recordBillableOperation({
    required String provider,
    required String model,
    required double estimatedCost,
    String characterId = 'default',
    int promptTokens = 0,
    int completionTokens = 0,
    int cacheHitTokens = 0,
    int cacheCreationTokens = 0,
    String requestKind = ApiRequestKind.image,
    bool costKnown = false,
  }) async {
    _promptTokens += promptTokens;
    _completionTokens += completionTokens;
    _cacheHitTokens += cacheHitTokens;

    await DatabaseHelper.logUsage(
      provider: provider,
      model: model,
      characterId: characterId,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cacheHitTokens: cacheHitTokens,
      cacheCreationTokens: cacheCreationTokens,
      estimatedCost: estimatedCost,
      requestKind: requestKind,
      costKnown: costKnown,
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

  void reset() {
    _promptTokens = 0;
    _completionTokens = 0;
    _cacheHitTokens = 0;
  }
}
