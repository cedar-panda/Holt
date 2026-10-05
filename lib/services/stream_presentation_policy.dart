enum StreamPresentationMode { nativeBuffered, relayBuffered }

/// Controls only how received stream chunks are revealed in the UI.
/// Network transport, provider parsing, and the final persisted reply remain
/// unchanged.
class StreamPresentationPolicy {
  const StreamPresentationPolicy._();

  static const Set<String> _bufferedProviders = <String>{
    'openrouter',
    'openai_compatible',
    'local_api',
  };

  static StreamPresentationMode forProvider(String provider) {
    final normalized = provider.trim().toLowerCase();
    return _bufferedProviders.contains(normalized)
        ? StreamPresentationMode.relayBuffered
        : StreamPresentationMode.nativeBuffered;
  }

  static Duration initialDelay(StreamPresentationMode mode) => switch (mode) {
    StreamPresentationMode.relayBuffered => const Duration(milliseconds: 1200),
    StreamPresentationMode.nativeBuffered => const Duration(milliseconds: 600),
  };

  static Duration characterInterval(
    StreamPresentationMode mode,
  ) => switch (mode) {
    StreamPresentationMode.relayBuffered => const Duration(milliseconds: 28),
    StreamPresentationMode.nativeBuffered => const Duration(milliseconds: 14),
  };
}
