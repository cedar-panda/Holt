abstract final class PromptCacheChannel {
  static const String text = 'text';
  static const String call = 'call';
}

/// Window-scoped prompt-cache state.
///
/// OpenRouter keeps one sticky [session_id] per conversation. Text and call
/// requests stay on that same upstream route, while their byte-distinct
/// runtime-system snapshots are retained independently here.
class PromptCacheChannels {
  final Map<String, String> _stableDynamicByKey = <String, String>{};

  String? stableDynamic({
    required bool cacheEnabled,
    required bool isClaudeCache,
    required String conversationId,
    required String provider,
    required String model,
    required String locale,
    required String channel,
    required String liveDynamicPart,
  }) {
    if (!cacheEnabled) {
      clearConversation(conversationId);
      return null;
    }
    if (!isClaudeCache) {
      clearChannel(conversationId: conversationId, channel: channel);
      return null;
    }

    final key = _key(
      conversationId: conversationId,
      provider: provider,
      model: model,
      locale: locale,
      channel: channel,
    );
    if (!_stableDynamicByKey.containsKey(key)) {
      // 每個窗口只保留 text/call 各一份活動快照。該通道切換
      // provider、model 或 locale 時刷新自己，不影響另一通道。
      clearChannel(conversationId: conversationId, channel: channel);
    }
    return _stableDynamicByKey.putIfAbsent(key, () => liveDynamicPart);
  }

  void clearChannel({required String conversationId, required String channel}) {
    final prefix = '${conversationId.trim()}|';
    final suffix = '|${channel.trim()}';
    _stableDynamicByKey.removeWhere(
      (key, _) => key.startsWith(prefix) && key.endsWith(suffix),
    );
  }

  void clearConversation(String conversationId) {
    final prefix = '${conversationId.trim()}|';
    _stableDynamicByKey.removeWhere((key, _) => key.startsWith(prefix));
  }

  int get debugSnapshotCount => _stableDynamicByKey.length;

  static String _key({
    required String conversationId,
    required String provider,
    required String model,
    required String locale,
    required String channel,
  }) {
    return [
      conversationId.trim(),
      provider.trim().toLowerCase(),
      model.trim().toLowerCase(),
      locale.trim(),
      channel.trim(),
    ].join('|');
  }
}
