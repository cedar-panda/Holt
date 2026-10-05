import 'dart:async';

import 'package:project_yanci/services/api_adapter.dart';

/// iOS build variant: no on-device model binaries are linked into the app.
class LocalModelService implements ApiAdapter {
  LocalModelService({required String modelKey});

  static const List<LocalModelInfo> availableModels = [];

  static bool isLocalModelId(String modelId) => modelId.startsWith('local:');

  static String extractKey(String modelId) =>
      isLocalModelId(modelId) ? modelId.substring(6) : modelId;

  static String fallbackDisplayNameForKey(String key) => key;

  static Future<List<Map<String, String>>> downloadedModelEntries() async => [];

  static Future<void> initializeBackgroundDownloads() async {}

  Future<bool> initialize() async => false;

  Future<void> dispose() async {}

  @override
  void cancelActive() {}

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) =>
      Future.error(UnsupportedError('On-device models are unavailable on iOS'));

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) =>
      Stream.error(UnsupportedError('On-device models are unavailable on iOS'));
}

class LocalModelInfo {
  const LocalModelInfo({
    required this.key,
    required this.name,
    required this.nameEn,
  });

  final String key;
  final String name;
  final String nameEn;
}
