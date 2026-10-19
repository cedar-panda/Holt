import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/stream_presentation_policy.dart';

void main() {
  test('relay and OpenAI-compatible providers use buffered reveal', () {
    expect(
      StreamPresentationPolicy.forProvider('openrouter'),
      StreamPresentationMode.relayBuffered,
    );
    expect(
      StreamPresentationPolicy.forProvider('openai_compatible'),
      StreamPresentationMode.relayBuffered,
    );
    expect(
      StreamPresentationPolicy.forProvider('local_api'),
      StreamPresentationMode.relayBuffered,
    );
    expect(
      StreamPresentationPolicy.initialDelay(
        StreamPresentationMode.relayBuffered,
      ),
      const Duration(milliseconds: 1200),
    );
    expect(
      StreamPresentationPolicy.characterInterval(
        StreamPresentationMode.relayBuffered,
      ),
      const Duration(milliseconds: 28),
    );
  });

  test('direct providers use a lower-latency character reveal', () {
    for (final provider in <String>[
      'gemini',
      'xai',
      'deepseek',
      'deepinfra',
      'qwen',
      'thinking_machines',
      'bedrock',
      'local',
    ]) {
      expect(
        StreamPresentationPolicy.forProvider(provider),
        StreamPresentationMode.nativeBuffered,
        reason: provider,
      );
    }
    expect(
      StreamPresentationPolicy.initialDelay(
        StreamPresentationMode.nativeBuffered,
      ),
      const Duration(milliseconds: 600),
    );
    expect(
      StreamPresentationPolicy.characterInterval(
        StreamPresentationMode.nativeBuffered,
      ),
      const Duration(milliseconds: 14),
    );
  });
}
