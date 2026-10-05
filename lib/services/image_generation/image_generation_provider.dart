import 'dart:typed_data';

enum ImageGenerationProvider {
  openRouter('openrouter'),
  gemini('gemini'),
  xai('xai'),
  qwen('qwen'),
  openAICompatible('openai_compatible'),
  localApi('local_api');

  const ImageGenerationProvider(this.id);

  final String id;

  static ImageGenerationProvider fromId(String value) {
    return ImageGenerationProvider.values.firstWhere(
      (provider) => provider.id == value.trim(),
      orElse: () => ImageGenerationProvider.openRouter,
    );
  }

  String get displayName => switch (this) {
    ImageGenerationProvider.openRouter => 'OpenRouter',
    ImageGenerationProvider.gemini => 'Gemini',
    ImageGenerationProvider.xai => 'xAI',
    ImageGenerationProvider.qwen => 'Qwen / DashScope',
    ImageGenerationProvider.openAICompatible => 'API 中轉站',
    ImageGenerationProvider.localApi => '本地 API',
  };

  String get defaultModel => switch (this) {
    ImageGenerationProvider.openRouter => 'openai/gpt-5.4-image-2',
    ImageGenerationProvider.gemini => 'gemini-3.1-flash-image',
    ImageGenerationProvider.xai => 'grok-imagine-image-2.0',
    ImageGenerationProvider.qwen => 'qwen-image-3.0-pro',
    ImageGenerationProvider.openAICompatible ||
    ImageGenerationProvider.localApi => 'gpt-image-1',
  };

  bool get needsBaseUrl =>
      this == ImageGenerationProvider.openAICompatible ||
      this == ImageGenerationProvider.localApi;
}

class ImageGenerationConfig {
  const ImageGenerationConfig({
    required this.provider,
    required this.model,
    required this.apiKey,
    this.baseUrl = '',
  });

  final ImageGenerationProvider provider;
  final String model;
  final String apiKey;
  final String baseUrl;

  bool get isConfigured {
    if (model.trim().isEmpty) return false;
    if (provider.needsBaseUrl && baseUrl.trim().isEmpty) return false;
    if (provider == ImageGenerationProvider.localApi) return true;
    return apiKey.trim().isNotEmpty;
  }
}

class GeneratedImage {
  const GeneratedImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;

  String get fileExtension => switch (mimeType.toLowerCase()) {
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/webp' => 'webp',
    _ => 'png',
  };
}

/// 圖片 API 通常不返回 token 或實際費用，先以單張圖片的保守估算寫入
/// 用量表；若日後 provider 回傳實際費用，可在這裡集中替換，不影響呼叫端。
abstract final class ImageGenerationPricing {
  static double estimateUsd(ImageGenerationConfig config) {
    final model = config.model.toLowerCase();
    if (model.contains('gpt-image') || model.contains('dall-e')) return 0.04;
    if (model.contains('imagen') || model.contains('gemini')) return 0.04;
    if (model.contains('grok') || model.contains('imagine')) return 0.02;
    if (model.contains('qwen-image') || model.contains('seedream')) {
      return 0.03;
    }
    return 0.04;
  }
}
