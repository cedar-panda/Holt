import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'locale_strings.dart';
import 'settings/api_settings.dart';

/// 模型畫畫：`<draw>prompt</draw>` 標籤 → OpenRouter 圖像輸出模型
///
/// 僅 OpenRouter 路線可用（chat_screen 注入能力說明時按 provider 把關）。
/// 默認模型 google/gemini-2.5-flash-image，可在 API 進階設定修改。
/// 生成的圖片落到本地，掛在角色消息的 imagePath 上，與普通圖片同渠道渲染。
class ImageGenService {
  /// 注入靜態 prompt 的能力說明（工具清單式）
  ///
  /// 語言分支鐵律（docs/cache完整攻略指南）：zh_TW 分支文本逐字節不動。
  static String abilityPrompt() {
    if (L.locale == 'en') {
      return '''■ Drawing
  <draw>English image description: subject, style, lighting, composition</draw>
  Only when the user asks for it. If the user gives a full description, use their prompt as-is.
  At most one image per turn.''';
    }
    return L.pick(
      en: '',
      zhTW: '''■ 畫畫
  <draw>英文圖像描述，寫清主體、風格、光線、構圖</draw>
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
  }) async {
    final apiKey = await ApiSettings.getOpenRouterApiKey();
    final model = await ApiSettings.getImageGenModel();
    if (apiKey.isEmpty) throw Exception('缺少 OpenRouter API Key');
    if (prompt.isEmpty) throw Exception('空白畫圖描述');

    // ═══ 拼接角色錨點 + 畫風 ═══
    final buf = StringBuffer();
    if (userAnchor.isNotEmpty || charAnchor.isNotEmpty || style.isNotEmpty) {
      if (userAnchor.isNotEmpty || charAnchor.isNotEmpty) {
        buf.writeln('Characters in this scene:');
        if (userAnchor.isNotEmpty) {
          buf.writeln('- Person A (user): $userAnchor');
        }
        if (charAnchor.isNotEmpty) {
          buf.writeln('- Person B (character): $charAnchor');
        }
        buf.writeln();
      }
      if (style.isNotEmpty) {
        buf.writeln('Art style: $style');
        buf.writeln();
      }
      buf.writeln('Scene: $prompt');
    } else {
      buf.write(prompt);
    }
    final finalPrompt = buf.toString();

    final resp = await http
        .post(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': finalPrompt},
            ],
            // OpenRouter 圖像輸出協議：聲明期望的輸出模態
            'modalities': ['image', 'text'],
          }),
        )
        .timeout(const Duration(seconds: 240)); // 後台生成，不阻塞回覆

    if (resp.statusCode != 200) {
      throw Exception('畫圖請求失敗 ${resp.statusCode}: ${resp.body}');
    }

    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    final message = data['choices']?[0]?['message'];
    final images = message?['images'] as List?;
    if (images == null || images.isEmpty) {
      throw Exception('模型未返回圖片');
    }
    final dataUrl = images.first['image_url']?['url'] as String? ?? '';
    final commaIdx = dataUrl.indexOf(',');
    if (!dataUrl.startsWith('data:') || commaIdx < 0) {
      throw Exception('圖片格式不可解析');
    }

    final bytes = base64Decode(dataUrl.substring(commaIdx + 1));
    final isPng = dataUrl.contains('image/png');
    final dir = await getApplicationDocumentsDirectory();
    final genDir = Directory('${dir.path}/generated_images');
    if (!await genDir.exists()) await genDir.create(recursive: true);
    final path =
        '${genDir.path}/gen_${DateTime.now().millisecondsSinceEpoch}.${isPng ? 'png' : 'jpg'}';
    await File(path).writeAsBytes(bytes);
    return path;
  }
}
