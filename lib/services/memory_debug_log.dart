import 'package:flutter/foundation.dart';
import 'api_error_localizer.dart';

const bool _memoryDebugEnabled = bool.fromEnvironment(
  'HOLT_ENABLE_DEVELOPER_DIAGNOSTICS',
  defaultValue: kDebugMode,
);

class MemoryDebugEvent {
  const MemoryDebugEvent({
    required this.at,
    required this.stage,
    required this.contextMode,
    required this.continuityId,
    this.provider = '',
    this.model = '',
    this.inputCount = 0,
    this.resultIds = const <int>[],
    this.details = const <String, Object?>{},
    this.errorCode = '',
  });

  final DateTime at;
  final String stage;
  final String contextMode;
  final String continuityId;
  final String provider;
  final String model;
  final int inputCount;
  final List<int> resultIds;
  final Map<String, Object?> details;
  final String errorCode;

  String get scope =>
      '$contextMode/${continuityId.isEmpty ? 'main' : continuityId}';

  String report() => <String>[
    '${at.toIso8601String()}  $stage',
    'scope: $scope',
    if (provider.isNotEmpty || model.isNotEmpty)
      'api: ${provider.isEmpty ? '—' : provider} / ${model.isEmpty ? '—' : model}',
    'input: $inputCount · results: ${resultIds.length}',
    if (resultIds.isNotEmpty) 'ids: ${resultIds.join(',')}',
    for (final entry in details.entries) '${entry.key}: ${entry.value}',
    if (errorCode.isNotEmpty) 'error: $errorCode',
  ].join('\n');
}

/// In-memory diagnostics for memory retrieval and curation. It intentionally
/// stores metadata only: never queries, memory text, summaries, prompts or API
/// credentials.
abstract final class MemoryDebugLog {
  static const int _maxEntries = 80;
  static final ValueNotifier<List<MemoryDebugEvent>> events =
      ValueNotifier<List<MemoryDebugEvent>>(const <MemoryDebugEvent>[]);

  static void clear() => events.value = const <MemoryDebugEvent>[];

  static void record({
    required String stage,
    required String contextMode,
    required String continuityId,
    String provider = '',
    String model = '',
    int inputCount = 0,
    Iterable<int> resultIds = const <int>[],
    Map<String, Object?> details = const <String, Object?>{},
    Object? error,
  }) {
    if (!_memoryDebugEnabled) return;
    final event = MemoryDebugEvent(
      at: DateTime.now(),
      stage: stage,
      contextMode: contextMode,
      continuityId: continuityId,
      provider: provider,
      model: model,
      inputCount: inputCount,
      resultIds: List<int>.unmodifiable(resultIds),
      details: Map<String, Object?>.unmodifiable(details),
      errorCode: error == null ? '' : _safeErrorCode(error),
    );
    events.value = <MemoryDebugEvent>[
      event,
      ...events.value.take(_maxEntries - 1),
    ];
  }

  static String _safeErrorCode(Object error) {
    final text = error.toString().toLowerCase();
    if (error is StateError && text.contains('embedding model')) {
      return 'StateError/embedding_model_missing';
    }
    final diagnosis = ApiErrorLocalizer.diagnose(error);
    final status = diagnosis.statusCode == null
        ? ''
        : '/http_${diagnosis.statusCode}';
    return '${error.runtimeType}/${diagnosis.category}$status';
  }
}
