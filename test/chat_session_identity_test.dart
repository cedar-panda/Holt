import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/chat_session_identity.dart';
import 'package:project_yanci/models/message.dart';

void main() {
  test('chat identity always comes from the loaded conversation', () {
    final conversation = Conversation(
      id: 'conversation-a',
      characterId: 'character-from-conversation',
    );

    final identity = ChatSessionIdentity.fromConversation(
      expectedConversationId: 'conversation-a',
      conversation: conversation,
    );

    expect(identity.conversationId, 'conversation-a');
    expect(identity.characterId, 'character-from-conversation');
  });

  test('chat identity rejects a missing conversation', () {
    expect(
      () => ChatSessionIdentity.fromConversation(
        expectedConversationId: 'missing',
        conversation: null,
      ),
      throwsStateError,
    );
  });

  test('chat identity rejects an unrelated conversation result', () {
    final conversation = Conversation(
      id: 'conversation-b',
      characterId: 'character-b',
    );

    expect(
      () => ChatSessionIdentity.fromConversation(
        expectedConversationId: 'conversation-a',
        conversation: conversation,
      ),
      throwsStateError,
    );
  });

  test('chat identity rejects an empty character binding', () {
    final conversation = Conversation(id: 'conversation-a', characterId: '   ');

    expect(
      () => ChatSessionIdentity.fromConversation(
        expectedConversationId: 'conversation-a',
        conversation: conversation,
      ),
      throwsStateError,
    );
  });
}
