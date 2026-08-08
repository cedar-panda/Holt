import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/prompt_cache_channels.dart';

void main() {
  test('control is cacheable while per-turn state remains live', () {
    final first = StructuredPrompt(
      staticPart: 'STATIC',
      profilePart: 'PROFILE',
      windowPart: 'WINDOW',
      controlPart: 'CONTROL',
      liveStatePart: '08:00',
      cacheChannel: PromptCacheChannel.text,
    );
    final second = StructuredPrompt(
      staticPart: 'STATIC',
      profilePart: 'PROFILE',
      windowPart: 'WINDOW',
      controlPart: 'CONTROL',
      liveStatePart: '09:30',
      cacheChannel: PromptCacheChannel.text,
    );

    expect(first.cacheableParts, second.cacheableParts);
    expect(first.cacheableParts.last, contains('CONTROL'));
    expect(first.liveStatePart, '08:00');
    expect(second.liveStatePart, '09:30');
    expect(second.allContextParts.last, '09:30');
  });
}
