import '../api_adapter.dart';

/// DeepInfra explicit prompt-retention rules.
///
/// DeepInfra's normal prompt cache is automatic and best-effort. Explicit 1h
/// retention is currently accepted only by the models listed in the provider
/// documentation. Unsupported models must not be advertised as retained.
abstract final class DeepInfraCachePolicy {
  static const Set<String> explicitRetentionModels = <String>{
    'nvidia/nvidia-nemotron-3-ultra-550b-a55b',
    'moonshotai/kimi-k2.7-code',
  };

  static final Map<String, DateTime> _retentionDeadlines = <String, DateTime>{};

  static bool supportsExplicitRetention(String model) =>
      explicitRetentionModels.contains(model.trim().toLowerCase());

  /// Adds a retention key on every request, but sends the paid 1h extension
  /// only when opening a new local window. Variable App Live State is inserted
  /// after this breakpoint by the adapter and therefore never pollutes the
  /// retained prefix.
  static void decorateRequest({
    required Map<String, dynamic> body,
    required List<Map<String, dynamic>> messages,
    required String model,
    required String sessionId,
    required int breakpointIndex,
    required bool enabled,
    DateTime? now,
  }) {
    final normalizedSession = sessionId.trim();
    if (!enabled || normalizedSession.isEmpty) {
      return;
    }

    final key = 'holt:$normalizedSession:${model.trim().toLowerCase()}';
    body['prompt_cache_key'] = key;
    // DeepSeek on DeepInfra uses automatic prefix caching with a session key.
    // It does NOT accept the explicit retention/breakpoint contract below.
    if (!supportsExplicitRetention(model)) return;
    if (breakpointIndex >= 0 && breakpointIndex < messages.length) {
      final blocks = CacheBreakpoint.toBlocks(
        messages[breakpointIndex]['content'],
      );
      if (blocks.isNotEmpty) {
        blocks.last['prompt_cache_breakpoint'] = const <String, String>{
          'mode': 'explicit',
        };
        messages[breakpointIndex]['content'] = blocks;
      }
    }

    final current = now ?? DateTime.now();
    final deadline = _retentionDeadlines[key];
    if (deadline == null || !deadline.isAfter(current)) {
      body['prompt_cache_options'] = const <String, String>{
        'mode': 'explicit',
        'ttl': '1h',
      };
      _retentionDeadlines[key] = current.add(const Duration(hours: 1));
    }
  }

  static void resetForTesting() => _retentionDeadlines.clear();
}
