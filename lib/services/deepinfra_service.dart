import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_info.dart';
import 'openai_compatible_service.dart';

/// DeepInfra direct API through its first-party OpenAI-compatible endpoint.
///
/// Authentication uses one DeepInfra API key. The rich public catalogue is
/// intersected with the authenticated OpenAI model list so chat and embedding
/// pickers only expose models currently available to the account.
class DeepInfraService extends OpenAICompatibleService {
  static const String chatCompletionsUrl =
      'https://api.deepinfra.com/v1/openai/chat/completions';
  static const String modelsUrl = 'https://api.deepinfra.com/v1/openai/models';
  static const String catalogueUrl = 'https://api.deepinfra.com/models/list';
  static const String embeddingsUrl =
      'https://api.deepinfra.com/v1/openai/embeddings';
  static const String defaultModel = 'Qwen/Qwen3.8-Flash';

  DeepInfraService({required super.apiKey, super.thinkingEnabled = false})
    : super(
        baseUrl: chatCompletionsUrl,
        providerId: 'deepinfra',
        providerLabel: 'DeepInfra',
      );

  static Future<List<ModelInfo>> fetchModels(
    String apiKey, {
    http.Client? client,
  }) => _fetchTypedModels(
    apiKey,
    acceptedTypes: const <String>{'text-generation'},
    client: client,
  );

  static Future<List<ModelInfo>> fetchEmbeddingModels(
    String apiKey, {
    http.Client? client,
  }) => _fetchTypedModels(
    apiKey,
    acceptedTypes: const <String>{'embeddings'},
    client: client,
  );

  static Future<List<ModelInfo>> _fetchTypedModels(
    String apiKey, {
    required Set<String> acceptedTypes,
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final responses = await Future.wait<http.Response>([
        activeClient
            .get(
              Uri.parse(modelsUrl),
              headers: <String, String>{
                'Authorization': 'Bearer ${apiKey.trim()}',
              },
            )
            .timeout(const Duration(seconds: 20)),
        activeClient
            .get(Uri.parse(catalogueUrl))
            .timeout(const Duration(seconds: 20)),
      ]);
      final servingResponse = responses[0];
      if (servingResponse.statusCode != 200) {
        throw Exception('無法獲取 DeepInfra 模型列表：${servingResponse.statusCode}');
      }
      final catalogueResponse = responses[1];
      if (catalogueResponse.statusCode != 200) {
        throw Exception('無法獲取 DeepInfra 模型目錄：${catalogueResponse.statusCode}');
      }

      final servingDecoded = jsonDecode(servingResponse.body);
      final servingRows = servingDecoded is Map ? servingDecoded['data'] : null;
      if (servingRows is! List) {
        throw const FormatException('DeepInfra 模型列表格式不正確');
      }
      final servingIds = servingRows
          .whereType<Map>()
          .map((row) => '${row['id'] ?? ''}'.trim())
          .where((id) => id.isNotEmpty)
          .toSet();

      final catalogueDecoded = jsonDecode(catalogueResponse.body);
      if (catalogueDecoded is! List) {
        throw const FormatException('DeepInfra 模型目錄格式不正確');
      }
      final models =
          catalogueDecoded
              .whereType<Map>()
              .where((row) {
                final id = '${row['model_name'] ?? ''}'.trim();
                final type = '${row['type'] ?? row['reported_type'] ?? ''}'
                    .trim()
                    .toLowerCase();
                final tags = row['tags'];
                final supportsOpenAi =
                    tags is List &&
                    tags.any((tag) => '$tag'.toLowerCase() == 'openai');
                return servingIds.contains(id) &&
                    acceptedTypes.contains(type) &&
                    supportsOpenAi;
              })
              .map((row) {
                final id = '${row['model_name'] ?? ''}'.trim();
                return ModelInfo(id: id, name: id);
              })
              .toList(growable: false)
            ..sort((left, right) => left.name.compareTo(right.name));
      return models;
    } finally {
      ownedClient?.close();
    }
  }
}
