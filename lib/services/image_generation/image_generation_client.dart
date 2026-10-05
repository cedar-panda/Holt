import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../utils/endpoint_security.dart';
import '../gemini_service.dart';
import '../model_info.dart';
import '../openai_compatible_service.dart';
import 'image_generation_provider.dart';

class ImageGenerationClient {
  ImageGenerationClient({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static const Duration _requestTimeout = Duration(seconds: 240);
  static const Duration _downloadTimeout = Duration(seconds: 60);
  static const int _maxImageBytes = 30 * 1024 * 1024;

  final http.Client _client;
  final bool _ownsClient;

  Future<GeneratedImage> generate({
    required ImageGenerationConfig config,
    required String prompt,
  }) async {
    if (!config.isConfigured) {
      throw Exception('${config.provider.displayName} 畫圖設定不完整');
    }
    if (prompt.trim().isEmpty) throw Exception('空白畫圖描述');

    return switch (config.provider) {
      ImageGenerationProvider.openRouter => _generateOpenRouter(config, prompt),
      ImageGenerationProvider.gemini => _generateGemini(config, prompt),
      ImageGenerationProvider.xai => _generateOpenAIImages(
        config,
        prompt,
        Uri.parse('https://api.x.ai/v1/images/generations'),
        requestBase64: false,
      ),
      ImageGenerationProvider.qwen => _generateQwen(config, prompt),
      ImageGenerationProvider.openAICompatible ||
      ImageGenerationProvider.localApi => _generateOpenAIImages(
        config,
        prompt,
        imagesUriForBase(config.baseUrl),
        requestBase64: true,
      ),
    };
  }

  Future<List<ModelInfo>> fetchModels(ImageGenerationConfig config) async {
    return switch (config.provider) {
      ImageGenerationProvider.openRouter => _fetchOpenRouterModels(
        config.apiKey,
      ),
      ImageGenerationProvider.gemini => _fetchGeminiModels(config.apiKey),
      ImageGenerationProvider.xai => _fetchXaiModels(config.apiKey),
      ImageGenerationProvider.qwen => _qwenModels,
      ImageGenerationProvider.openAICompatible ||
      ImageGenerationProvider.localApi => _fetchCompatibleModels(config),
    };
  }

  Future<GeneratedImage> _generateOpenRouter(
    ImageGenerationConfig config,
    String prompt,
  ) async {
    final response = await _client
        .post(
          Uri.parse('https://openrouter.ai/api/v1/images'),
          headers: _bearerHeaders(config.apiKey),
          body: jsonEncode(<String, Object>{
            'model': config.model,
            'prompt': prompt,
            'n': 1,
          }),
        )
        .timeout(_requestTimeout);
    final decoded = _decodeSuccess(response, 'OpenRouter 畫圖失敗');
    return _imageFromOpenAIData(decoded, config.provider);
  }

  Future<GeneratedImage> _generateOpenAIImages(
    ImageGenerationConfig config,
    String prompt,
    Uri endpoint, {
    required bool requestBase64,
  }) async {
    final response = await _client
        .post(
          endpoint,
          headers: _bearerHeaders(config.apiKey),
          body: jsonEncode(<String, Object>{
            'model': config.model,
            'prompt': prompt,
            'n': 1,
            if (requestBase64) 'response_format': 'b64_json',
          }),
        )
        .timeout(_requestTimeout);
    final decoded = _decodeSuccess(
      response,
      '${config.provider.displayName} 畫圖失敗',
    );
    return _imageFromOpenAIData(decoded, config.provider);
  }

  Future<GeneratedImage> _generateGemini(
    ImageGenerationConfig config,
    String prompt,
  ) async {
    final model = Uri.encodeComponent(config.model.trim());
    final endpoint = Uri.parse(
      'https://generativelanguage.googleapis.com/v1/models/'
      '$model:generateContent',
    );
    final response = await _client
        .post(
          endpoint,
          headers: <String, String>{
            'x-goog-api-key': config.apiKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, Object>{
            'contents': <Object>[
              <String, Object>{
                'parts': <Object>[
                  <String, String>{'text': prompt},
                ],
              },
            ],
            'generationConfig': <String, Object>{
              'responseModalities': <String>['IMAGE'],
            },
          }),
        )
        .timeout(_requestTimeout);
    final decoded = _decodeSuccess(response, 'Gemini 畫圖失敗');
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw Exception('Gemini 模型未返回圖片');
    }
    final first = candidates.first;
    final content = first is Map ? first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) throw Exception('Gemini 圖片格式不可解析');
    for (final rawPart in parts.whereType<Map>()) {
      final inline = rawPart['inlineData'] ?? rawPart['inline_data'];
      if (inline is! Map) continue;
      final data = '${inline['data'] ?? ''}'.trim();
      if (data.isEmpty) continue;
      return _fromBase64(
        data,
        '${inline['mimeType'] ?? inline['mime_type'] ?? 'image/png'}',
      );
    }
    throw Exception('Gemini 模型未返回圖片');
  }

  Future<GeneratedImage> _generateQwen(
    ImageGenerationConfig config,
    String prompt,
  ) async {
    final response = await _client
        .post(
          Uri.parse(
            'https://dashscope.aliyuncs.com/api/v1/services/aigc/'
            'multimodal-generation/generation',
          ),
          headers: _bearerHeaders(config.apiKey),
          body: jsonEncode(<String, Object>{
            'model': config.model,
            'input': <String, Object>{
              'messages': <Object>[
                <String, Object>{
                  'role': 'user',
                  'content': <Object>[
                    <String, String>{'text': prompt},
                  ],
                },
              ],
            },
            'parameters': <String, Object>{'prompt_extend': true},
          }),
        )
        .timeout(_requestTimeout);
    final decoded = _decodeSuccess(response, 'Qwen 畫圖失敗');
    final output = decoded['output'];
    final choices = output is Map ? output['choices'] : null;
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is List) {
      for (final item in content.whereType<Map>()) {
        final url = '${item['image'] ?? ''}'.trim();
        if (url.isNotEmpty) return _downloadImage(url);
      }
    }
    throw Exception('Qwen 模型未返回圖片');
  }

  Future<GeneratedImage> _imageFromOpenAIData(
    Map<String, dynamic> decoded,
    ImageGenerationProvider provider,
  ) async {
    final data = decoded['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw Exception('${provider.displayName} 模型未返回圖片');
    }
    final first = data.first as Map;
    final base64 = '${first['b64_json'] ?? ''}'.trim();
    if (base64.isNotEmpty) {
      return _fromBase64(
        base64,
        '${first['media_type'] ?? first['mime_type'] ?? 'image/png'}',
      );
    }
    final url = '${first['url'] ?? ''}'.trim();
    if (url.isNotEmpty) return _downloadImage(url);
    throw Exception('${provider.displayName} 圖片格式不可解析');
  }

  Future<List<ModelInfo>> _fetchOpenRouterModels(String apiKey) async {
    final response = await _client
        .get(
          Uri.parse('https://openrouter.ai/api/v1/images/models'),
          headers: <String, String>{'Authorization': 'Bearer $apiKey'},
        )
        .timeout(const Duration(seconds: 20));
    final decoded = _decodeSuccess(response, '無法獲取 OpenRouter 畫圖模型');
    return _parseModelList(decoded['data']);
  }

  Future<List<ModelInfo>> _fetchXaiModels(String apiKey) async {
    final response = await _client
        .get(
          Uri.parse('https://api.x.ai/v1/image-generation-models'),
          headers: <String, String>{'Authorization': 'Bearer $apiKey'},
        )
        .timeout(const Duration(seconds: 20));
    final decoded = _decodeSuccess(response, '無法獲取 xAI 畫圖模型');
    return _parseModelList(decoded['models']);
  }

  Future<List<ModelInfo>> _fetchGeminiModels(String apiKey) async {
    final models = await GeminiService.fetchModels(apiKey, client: _client);
    return models.where((model) => looksLikeImageModel(model.id)).toList();
  }

  Future<List<ModelInfo>> _fetchCompatibleModels(
    ImageGenerationConfig config,
  ) async {
    final models = await OpenAICompatibleService.fetchModels(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      client: _client,
    );
    return models.where((model) => looksLikeImageModel(model.id)).toList();
  }

  List<ModelInfo> _parseModelList(Object? raw) {
    if (raw is! List) return const <ModelInfo>[];
    final unique = <String, ModelInfo>{};
    for (final item in raw.whereType<Map>()) {
      final id = '${item['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      final name = '${item['name'] ?? id}'.trim();
      unique[id] = ModelInfo(id: id, name: name.isEmpty ? id : name);
    }
    return unique.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  static bool looksLikeImageModel(String modelId) {
    final value = modelId.toLowerCase();
    return value.contains('image') ||
        value.contains('imagen') ||
        value.contains('imagine') ||
        value.contains('flux') ||
        value.contains('seedream') ||
        value.contains('recraft') ||
        value.contains('dall-e') ||
        value.contains('dalle') ||
        value.contains('stable-diffusion') ||
        value.contains('wan2.') ||
        value.contains('z-image');
  }

  static Uri imagesUriForBase(String baseUrl) {
    final base = EndpointSecurity.parseAndValidate(baseUrl);
    var path = base.path.replaceFirst(RegExp(r'/+$'), '');
    for (final suffix in const <String>[
      '/chat/completions',
      '/images/generations',
      '/images',
    ]) {
      if (path.endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    if (!path.endsWith('/v1')) path = '$path/v1';
    return base.replace(path: '$path/images/generations', query: null);
  }

  Map<String, dynamic> _decodeSuccess(
    http.Response response,
    String operation,
  ) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        OpenAICompatibleService.httpErrorMessage(
          response.statusCode,
          utf8.decode(response.bodyBytes, allowMalformed: true),
          operation: operation,
        ),
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$operation：回應不是 JSON 物件');
    }
    return decoded;
  }

  GeneratedImage _fromBase64(String encoded, String mimeType) {
    final normalizedMime = mimeType.toLowerCase().split(';').first.trim();
    if (normalizedMime == 'image/svg+xml') {
      throw Exception('目前聊天圖片不支援 SVG，請改用 PNG、JPEG 或 WebP 模型');
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      throw Exception('圖片 Base64 格式不可解析');
    }
    _validateBytes(bytes);
    return GeneratedImage(
      bytes: bytes,
      mimeType: _normalizeMimeType(normalizedMime, bytes),
    );
  }

  Future<GeneratedImage> _downloadImage(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !_isSafeRemoteImageUri(uri)) {
      throw Exception('圖片下載網址不安全或格式無效');
    }
    final response = await _client.get(uri).timeout(_downloadTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('圖片下載失敗 ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    _validateBytes(bytes);
    final contentType = response.headers['content-type'] ?? '';
    return GeneratedImage(
      bytes: bytes,
      mimeType: _normalizeMimeType(contentType, bytes),
    );
  }

  bool _isSafeRemoteImageUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local')) {
      return false;
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) return true;
    if (address.isLoopback || address.isLinkLocal) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return !(bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168));
    }
    return !(bytes[0] == 0xfc || bytes[0] == 0xfd);
  }

  void _validateBytes(Uint8List bytes) {
    if (bytes.isEmpty) throw Exception('圖片內容為空');
    if (bytes.length > _maxImageBytes) {
      throw Exception('圖片超過 30 MB 安全上限');
    }
  }

  String _normalizeMimeType(String raw, Uint8List bytes) {
    final value = raw.toLowerCase().split(';').first.trim();
    if (value == 'image/png' ||
        value == 'image/jpeg' ||
        value == 'image/webp') {
      return value;
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    throw Exception('只支援 PNG、JPEG 或 WebP 圖片');
  }

  Map<String, String> _bearerHeaders(String apiKey) => <String, String>{
    if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
    'Content-Type': 'application/json',
  };

  void close() {
    if (_ownsClient) _client.close();
  }

  static const List<ModelInfo> _qwenModels = <ModelInfo>[
    ModelInfo(id: 'qwen-image-3.0-pro', name: 'Qwen Image 3.0 Pro'),
    ModelInfo(id: 'qwen-image-3.0', name: 'Qwen Image 3.0'),
    ModelInfo(id: 'qwen-image-2.0-pro', name: 'Qwen Image 2.0 Pro'),
    ModelInfo(id: 'qwen-image-2.0', name: 'Qwen Image 2.0'),
    ModelInfo(id: 'qwen-image-max', name: 'Qwen Image Max'),
    ModelInfo(id: 'qwen-image-plus', name: 'Qwen Image Plus'),
    ModelInfo(id: 'qwen-image', name: 'Qwen Image'),
  ];
}
