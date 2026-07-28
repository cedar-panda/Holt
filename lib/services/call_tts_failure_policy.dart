/// A TTS request that cannot succeed until the user changes voice settings.
class CallTtsConfigurationException implements Exception {
  final String message;

  const CallTtsConfigurationException(this.message);

  @override
  String toString() => message;
}

/// Separates permanent TTS configuration/authentication failures from
/// transient transport failures that can reasonably be presented as a dropped
/// call.
abstract final class CallTtsFailurePolicy {
  static bool isConfigurationStatus(int statusCode) {
    return statusCode >= 400 &&
        statusCode < 500 &&
        statusCode != 408 &&
        statusCode != 429;
  }
}
