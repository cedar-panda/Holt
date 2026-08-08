import 'dart:convert';

class MemoryActionProposal {
  static const String actionCreate = 'create';
  static const String actionDelete = 'delete';
  static const String actionMerge = 'merge';
  static const String actionLink = 'link';

  static const String statusPending = 'pending';
  static const String statusSnoozed = 'snoozed';
  static const String statusExecuting = 'executing';
  static const String statusCompleted = 'completed';
  static const String statusRejected = 'rejected';
  static const String statusStale = 'stale';
  static const String statusFailed = 'failed';

  final String id;
  final String characterId;
  final String mode;
  final String action;
  final String source;
  final String? sourceConversationId;
  final int? sourceMessageId;
  final List<int> targetIds;
  final Map<String, dynamic> payload;
  final Map<String, dynamic> baseVersions;
  final String fingerprint;
  final String status;
  final DateTime createdAt;
  final DateTime? seenAt;
  final DateTime? resolvedAt;
  final String error;
  final Map<String, dynamic> result;

  const MemoryActionProposal({
    required this.id,
    required this.characterId,
    required this.mode,
    required this.action,
    required this.source,
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.targetIds,
    required this.payload,
    required this.baseVersions,
    required this.fingerprint,
    required this.status,
    required this.createdAt,
    required this.seenAt,
    required this.resolvedAt,
    required this.error,
    required this.result,
  });

  bool get canExecute =>
      status == statusPending ||
      status == statusSnoozed ||
      status == statusFailed;

  bool get isSnoozed => status == statusSnoozed;
  bool get isStale => status == statusStale;

  List<Map<String, dynamic>> get targetSnapshots {
    final raw = payload['targets'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Map<String, dynamic> get mergePreview {
    final raw = payload['result'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  Map<String, dynamic> get candidatePreview {
    final raw = payload['candidate'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  Map<String, dynamic> get linkPreview {
    final raw = payload['link'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  double get duplicateScore {
    final raw = payload['duplicate_score'];
    return raw is num ? raw.toDouble() : 0;
  }

  List<String> get duplicateReasons {
    final raw = payload['reasons'];
    if (raw is! List) return const [];
    return raw.map((item) => item.toString()).toList(growable: false);
  }

  bool get isExistingDuplicateScan =>
      payload['existing_duplicate_scan'] == true;

  factory MemoryActionProposal.fromMap(Map<String, dynamic> map) {
    return MemoryActionProposal(
      id: map['id']?.toString() ?? '',
      characterId: map['character_id']?.toString() ?? 'default',
      mode: map['mode']?.toString() ?? 'romance',
      action: map['action']?.toString() ?? '',
      source: map['source']?.toString() ?? '',
      sourceConversationId: map['source_conversation_id']?.toString(),
      sourceMessageId: map['source_message_id'] as int?,
      targetIds: _decodeIntList(map['target_ids_json']),
      payload: _decodeMap(map['payload_json']),
      baseVersions: _decodeMap(map['base_versions_json']),
      fingerprint: map['fingerprint']?.toString() ?? '',
      status: map['status']?.toString() ?? statusPending,
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      seenAt: DateTime.tryParse(map['seen_at']?.toString() ?? ''),
      resolvedAt: DateTime.tryParse(map['resolved_at']?.toString() ?? ''),
      error: map['error']?.toString() ?? '',
      result: _decodeMap(map['result_json']),
    );
  }

  static List<int> _decodeIntList(Object? raw) {
    final decoded = _decode(raw);
    if (decoded is! List) return const [];
    return decoded
        .map((value) => value is int ? value : int.tryParse('$value'))
        .whereType<int>()
        .toList(growable: false);
  }

  static Map<String, dynamic> _decodeMap(Object? raw) {
    final decoded = _decode(raw);
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
  }

  static Object? _decode(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
