import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/chat_session_identity.dart';
import 'package:project_yanci/models/context_mode.dart';
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
    expect(identity.contextMode, ContextMode.daily);
    expect(identity.continuityId, 'main');
  });

  test('chat identity preserves RP cache boundaries from the window', () {
    final conversation = Conversation(
      id: 'conversation-rp',
      characterId: 'character-a',
      contextMode: ContextMode.rp,
      continuityId: 'continuity-2',
      userPersonaId: 'persona-a',
      worldbookSetId: 'world-a',
    );

    final identity = ChatSessionIdentity.fromConversation(
      expectedConversationId: conversation.id,
      conversation: conversation,
    );

    expect(identity.contextMode, ContextMode.rp);
    expect(identity.continuityId, 'continuity-2');
    expect(identity.userPersonaId, 'persona-a');
    expect(identity.worldbookSetId, 'world-a');
    expect(identity.matchesCacheMetadata(identity.cacheMetadata), isTrue);
    expect(
      identity.matchesCacheMetadata(<String, String?>{
        ...identity.cacheMetadata,
        'context_mode': 'daily',
      }),
      isFalse,
    );
    expect(
      identity.matchesCacheMetadata(<String, String?>{
        ...identity.cacheMetadata,
        'user_persona_id': 'persona-b',
      }),
      isFalse,
    );
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

  test('chat identity rejects an empty continuity binding', () {
    final conversation = Conversation(
      id: 'conversation-a',
      characterId: 'character-a',
      continuityId: '   ',
    );

    expect(
      () => ChatSessionIdentity.fromConversation(
        expectedConversationId: 'conversation-a',
        conversation: conversation,
      ),
      throwsStateError,
    );
  });
}
