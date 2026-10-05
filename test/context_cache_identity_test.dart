import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/models/chat_session_identity.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/api_adapter.dart';

void main() {
  test('StructuredPrompt carries its own immutable cache session identity', () {
    final rp = _identity(ContextMode.rp);
    CacheSession.conversationId = 'unrelated-global-session';

    final prompt = StructuredPrompt(sessionIdentity: rp, staticPart: 'static');

    expect(prompt.cacheSessionId, 'same-conversation');
    expect(prompt.cacheContextMode, 'rp');
    expect(prompt.copyWith(liveStatePart: 'live').sessionIdentity, same(rp));
  });

  test('cache-hit state cannot cross a mismatched context namespace', () {
    final rp = _identity(ContextMode.rp);
    final daily = _identity(ContextMode.daily);

    CacheSession.bind(rp);
    CacheSession.markCacheHit(rp.conversationId);
    expect(CacheSession.hasCacheHitForCurrentConversation, isTrue);

    CacheSession.bind(daily);
    expect(CacheSession.hasCacheHitForCurrentConversation, isFalse);
  });
}

ChatSessionIdentity _identity(ContextMode mode) {
  final conversation = Conversation(
    id: 'same-conversation',
    characterId: 'character-a',
    contextMode: mode,
  );
  return ChatSessionIdentity.fromConversation(
    expectedConversationId: conversation.id,
    conversation: conversation,
  );
}
