import 'context_mode.dart';
import 'message.dart';

/// Immutable identity for one chat window.
///
/// A chat window belongs to the character stored on its conversation. Global
/// UI selection is deliberately not accepted here, because it can change while
/// an older conversation is being opened.
class ChatSessionIdentity {
  final String conversationId;
  final String characterId;
  final ContextMode contextMode;
  final String continuityId;
  final String? userPersonaId;
  final String? worldbookSetId;

  const ChatSessionIdentity._({
    required this.conversationId,
    required this.characterId,
    required this.contextMode,
    required this.continuityId,
    required this.userPersonaId,
    required this.worldbookSetId,
  });

  factory ChatSessionIdentity.fromConversation({
    required String expectedConversationId,
    required Conversation? conversation,
  }) {
    if (conversation == null) {
      throw StateError('Conversation $expectedConversationId does not exist');
    }
    if (conversation.id != expectedConversationId) {
      throw StateError(
        'Loaded conversation ${conversation.id} does not match '
        '$expectedConversationId',
      );
    }
    if (conversation.characterId.trim().isEmpty) {
      throw StateError(
        'Conversation $expectedConversationId has no character binding',
      );
    }
    if (conversation.continuityId.trim().isEmpty) {
      throw StateError(
        'Conversation $expectedConversationId has no continuity binding',
      );
    }

    return ChatSessionIdentity._(
      conversationId: conversation.id,
      characterId: conversation.characterId,
      contextMode: conversation.contextMode,
      continuityId: conversation.continuityId,
      userPersonaId: conversation.userPersonaId,
      worldbookSetId: conversation.worldbookSetId,
    );
  }

  /// Metadata persisted beside a cached prompt. Empty optional ids are
  /// canonicalized so null and an empty legacy preference cannot diverge.
  Map<String, String> get cacheMetadata => <String, String>{
    'conversation_id': conversationId,
    'character_id': characterId,
    'context_mode': contextMode.storageValue,
    'continuity_id': continuityId,
    'user_persona_id': userPersonaId ?? '',
    'worldbook_set_id': worldbookSetId ?? '',
  };

  bool matchesCacheMetadata(Map<String, String?> metadata) {
    final expected = cacheMetadata;
    return expected.entries.every(
      (entry) => (metadata[entry.key] ?? '') == entry.value,
    );
  }

  String get cacheNamespace => <String>[
    conversationId,
    characterId,
    contextMode.storageValue,
    continuityId,
    userPersonaId ?? '',
    worldbookSetId ?? '',
  ].join('\u0000');
}
