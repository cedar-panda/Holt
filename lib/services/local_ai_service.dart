import 'api_adapter.dart';

/// 本地 AI — 暫時佔位，等確認 flutter_gemma API 再接
class LocalAiService implements ApiAdapter {
  static bool get isReady => false;

  static Future<bool> initialize({String? modelPath}) async {
    return false;
  }

  @override
  Future<String> sendMessage({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
  }) async {
    throw Exception('本地模型尚未接入');
  }

  @override
  Stream<String> sendMessageStream({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
  }) async* {
    throw Exception('本地模型尚未接入');
  }
}
