import 'dart:convert';

class CharacterSelfNote {
  const CharacterSelfNote({
    required this.id,
    required this.characterId,
    required this.content,
    required this.provider,
    required this.modelId,
    required this.modelVersion,
    required this.sourceConversationId,
    required this.sourceMessageIds,
    required this.locked,
    required this.longTerm,
    required this.createdAt,
  });

  final int id;
  final String characterId;
  final String content;
  final String provider;
  final String modelId;
  final String modelVersion;
  final String sourceConversationId;
  final List<int> sourceMessageIds;
  final bool locked;
  final bool longTerm;
  final DateTime createdAt;

  CharacterSelfNote copyWith({bool? locked}) => CharacterSelfNote(
    id: id,
    characterId: characterId,
    content: content,
    provider: provider,
    modelId: modelId,
    modelVersion: modelVersion,
    sourceConversationId: sourceConversationId,
    sourceMessageIds: sourceMessageIds,
    locked: locked ?? this.locked,
    longTerm: longTerm,
    createdAt: createdAt,
  );

  factory CharacterSelfNote.fromMap(Map<String, Object?> map) {
    final rawIds = map['source_message_ids_json']?.toString() ?? '[]';
    List<int> ids = const <int>[];
    try {
      final decoded = jsonDecode(rawIds);
      if (decoded is List) {
        ids = decoded
            .map((item) => item is int ? item : int.tryParse('$item'))
            .whereType<int>()
            .toList(growable: false);
      }
    } catch (_) {}
    return CharacterSelfNote(
      id: map['id'] as int,
      characterId: map['character_id']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
      provider: map['provider']?.toString() ?? '',
      modelId: map['model_id']?.toString() ?? '',
      modelVersion: map['model_version']?.toString() ?? '',
      sourceConversationId: map['source_conversation_id']?.toString() ?? '',
      sourceMessageIds: ids,
      locked: map['locked'] == 1,
      longTerm: map['long_term'] == 1,
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
