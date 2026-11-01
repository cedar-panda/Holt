import 'dart:io';


import 'image_generation/image_generation_client.dart';
import 'image_generation/image_generation_provider.dart';
import 'locale_strings.dart';
import 'model_info.dart';
import 'settings/api_settings.dart';
import 'token_estimator.dart';
import 'token_tracker.dart';
import '../utils/app_directories.dart';

/// 模型畫畫：`<draw>prompt</draw>` 標籤 → 使用者獨立選定的圖片來源。
/// 生成的圖片落到本地，掛在角色消息的 imagePath 上，與普通圖片同渠道渲染。
class ImageGenService {
  /// 注入靜態 prompt 的能力說明（工具清單式）
  ///
  /// 語言分支鐵律（docs/cache完整攻略指南）：zh_TW 分支文本逐字節不動。
  static String abilityPrompt() {
    if (L.locale == 'en') {
      return '''■ Drawing
  {"type":"image.draw","arguments":{"prompt":"English image description: subject, style, lighting, composition"}}
  Only when the user asks for it. If the user gives a full description, use their prompt as-is.
  At most one image per turn.''';
    }
    return L.pick(
      en: '',
      zhTW: '''■ 畫畫
  {"type":"image.draw","arguments":{"prompt":"英文圖像描述，寫清主體、風格、光線、構圖"}}
  僅在對方要求時使用。對方給出完整描述時，完全使用對方的 prompt。
  一次至多一張。''',
    );
  }

  /// 生成圖片，返回本地文件路徑；失敗拋異常（調用方自行吞）
  /// [userAnchor] / [charAnchor] 為角色卡綁定的外觀描述，自動注入 prompt
  static Future<String> generate(
    String prompt, {
    String userAnchor = '',
    String charAnchor = '',
    String style = '',
    String characterId = 'default',
    String conversationId = '',
  }) async {
    if (prompt.isEmpty) throw Exception('空白畫圖描述');
    final config = await loadConfig();
    if (!config.isConfigured) {
      throw Exception('${config.provider.displayName} 畫圖設定不完整');
    }
    final client = ImageGenerationClient();
    final composedPrompt = _composePrompt(
      prompt,
      userAnchor: userAnchor,
      charAnchor: charAnchor,
      style: style,
    );
    late final GeneratedImage image;
    try {
      image = await client.generate(config: config, prompt: composedPrompt);
    } finally {
      client.close();
    }
    await TokenTracker().recordBillableOperation(
      provider: config.provider.id,
      model: config.model,
      characterId: characterId,
      conversationId: conversationId,
      promptTokens: TokenEstimator.estimate(composedPrompt),
      estimatedCost: ImageGenerationPricing.estimateUsd(config),
      requestKind: ApiRequestKind.image,
    );
    final dir = await getAppDocumentsDirectory();
    final genDir = Directory('${dir.path}/generated_images');
    if (!await genDir.exists()) await genDir.create(recursive: true);
    final path =
        '${genDir.path}/gen_${DateTime.now().millisecondsSinceEpoch}.${image.fileExtension}';
    await File(path).writeAsBytes(image.bytes, flush: true);
    return path;
  }

  static Future<bool> isConfigured() async => (await loadConfig()).isConfigured;

  static Future<ImageGenerationConfig> loadConfig({String? provider}) async {
    final source = ImageGenerationProvider.fromId(
      provider ?? await ApiSettings.getImageGenProvider(),
    );
    final model = await ApiSettings.getImageGenModel(provider: source.id);
    final apiKey = await ApiSettings.getApiKeyForProvider(source.id);
    final baseUrl = switch (source) {
      ImageGenerationProvider.openAICompatible =>
        await ApiSettings.getOaiCompatBaseUrl(),
      ImageGenerationProvider.localApi =>
        await ApiSettings.getLocalApiBaseUrl(),
      _ => '',
    };
    return ImageGenerationConfig(
      provider: source,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
  }

  static Future<List<ModelInfo>> fetchModels(String provider) async {
    final config = await loadConfig(provider: provider);
    final client = ImageGenerationClient();
    try {
      return await client.fetchModels(config);
    } finally {
      client.close();
    }
  }

  static String _composePrompt(
    String prompt, {
    required String userAnchor,
    required String charAnchor,
    required String style,
  }) {
    if (userAnchor.isEmpty && charAnchor.isEmpty && style.isEmpty) {
      return prompt;
    }
    final buffer = StringBuffer();
    if (userAnchor.isNotEmpty || charAnchor.isNotEmpty) {
      buffer.writeln('Characters in this scene:');
      if (userAnchor.isNotEmpty) {
        buffer.writeln('- Person A (user): $userAnchor');
      }
      if (charAnchor.isNotEmpty) {
        buffer.writeln('- Person B (character): $charAnchor');
      }
      buffer.writeln();
    }
    if (style.isNotEmpty) {
      buffer.writeln('Art style: $style');
      buffer.writeln();
    }
    buffer.writeln('Scene: $prompt');
    return buffer.toString();
  }
}
