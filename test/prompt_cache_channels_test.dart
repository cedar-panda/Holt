import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/prompt_cache_channels.dart';

void main() {
  test('keeps text and call stable runtime snapshots simultaneously', () {
    final channels = PromptCacheChannels();

    final text = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.text,
      liveDynamicPart: 'TEXT RUNTIME 08:00',
    );
    final call = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.call,
      liveDynamicPart: 'CALL RUNTIME 08:05',
    );
    final textAgain = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.text,
      liveDynamicPart: 'TEXT RUNTIME 09:30',
    );
    final callAgain = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.call,
      liveDynamicPart: 'CALL RUNTIME 09:31',
    );

    expect(text, 'TEXT RUNTIME 08:00');
    expect(call, 'CALL RUNTIME 08:05');
    expect(textAgain, text);
    expect(callAgain, call);
    expect(channels.debugSnapshotCount, 2);
  });

  test('clearing call channel does not erase text snapshot', () {
    final channels = PromptCacheChannels();
    for (final channel in [PromptCacheChannel.text, PromptCacheChannel.call]) {
      channels.stableDynamic(
        cacheEnabled: true,
        isClaudeCache: true,
        conversationId: 'conv-1',
        provider: 'openrouter',
        model: 'anthropic/claude-sonnet-4',
        locale: 'zh_TW',
        channel: channel,
        liveDynamicPart: channel,
      );
    }

    channels.clearChannel(
      conversationId: 'conv-1',
      channel: PromptCacheChannel.call,
    );

    expect(channels.debugSnapshotCount, 1);
    expect(
      channels.stableDynamic(
        cacheEnabled: true,
        isClaudeCache: true,
        conversationId: 'conv-1',
        provider: 'openrouter',
        model: 'anthropic/claude-sonnet-4',
        locale: 'zh_TW',
        channel: PromptCacheChannel.text,
        liveDynamicPart: 'new text',
      ),
      PromptCacheChannel.text,
    );
  });

  test('model change refreshes only its own channel snapshot', () {
    final channels = PromptCacheChannels();
    channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.text,
      liveDynamicPart: 'old text',
    );
    final call = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-sonnet-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.call,
      liveDynamicPart: 'stable call',
    );

    final text = channels.stableDynamic(
      cacheEnabled: true,
      isClaudeCache: true,
      conversationId: 'conv-1',
      provider: 'openrouter',
      model: 'anthropic/claude-opus-4',
      locale: 'zh_TW',
      channel: PromptCacheChannel.text,
      liveDynamicPart: 'new text',
    );

    expect(text, 'new text');
    expect(call, 'stable call');
    expect(channels.debugSnapshotCount, 2);
  });
}
