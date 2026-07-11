import 'message.dart';

/// Immutable identity for one chat window.
///
/// A chat window belongs to the character stored on its conversation. Global
/// UI selection is deliberately not accepted here, because it can change while
/// an older conversation is being opened.
class ChatSessionIdentity {
  final String conversationId;
  final String characterId;

  const ChatSessionIdentity._({
    required this.conversationId,
    required this.characterId,
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

    return ChatSessionIdentity._(
      conversationId: conversation.id,
      characterId: conversation.characterId,
    );
  }
}
