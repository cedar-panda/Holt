/// API model metadata shared by provider-specific model-list endpoints.
class ModelInfo {
  final String id;
  final String name;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final List<String> supportedParameters;

  const ModelInfo({
    required this.id,
    required this.name,
    this.inputModalities = const [],
    this.outputModalities = const [],
    this.supportedParameters = const [],
  });

  bool get supportsImageOutput {
    final outputs = outputModalities.map((m) => m.toLowerCase()).toSet();
    if (outputs.contains('image')) return true;

    final haystack = '$id $name ${supportedParameters.join(' ')}'.toLowerCase();
    return haystack.contains('image') ||
        haystack.contains('img') ||
        haystack.contains('gpt-image') ||
        haystack.contains('flux') ||
        haystack.contains('dall-e') ||
        haystack.contains('stable-diffusion') ||
        haystack.contains('imagen');
  }
}
