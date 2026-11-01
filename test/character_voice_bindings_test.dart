import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/tts_synthesizer.dart';

void main() {
  group('CharacterVoiceBindings', () {
    test('per-provider bindings do not leak across providers', () {
      final character = <String, Object?>{
        'tts_voice_ids_json': '{"elevenlabs":"abcDEF123","openai":"shimmer"}',
        'tts_voice_id': 'abcDEF123',
      };
      expect(
        CharacterVoiceBindings.voiceFor(character, TtsProviders.elevenlabs),
        'abcDEF123',
      );
      expect(
        CharacterVoiceBindings.voiceFor(character, TtsProviders.openai),
        'shimmer',
      );
    });

    test('legacy single value is only used by the provider it fits', () {
      final elevenOnly = <String, Object?>{
        'tts_voice_ids_json': '{}',
        'tts_voice_id': 'pNInz6obpgDQGcFmaJgB',
      };
      expect(
        CharacterVoiceBindings.voiceFor(elevenOnly, TtsProviders.elevenlabs),
        'pNInz6obpgDQGcFmaJgB',
      );
      expect(
        CharacterVoiceBindings.voiceFor(elevenOnly, TtsProviders.openai),
        isEmpty,
      );

      final openaiOnly = <String, Object?>{'tts_voice_id': 'nova'};
      expect(
        CharacterVoiceBindings.voiceFor(openaiOnly, TtsProviders.openai),
        'nova',
      );
      expect(
        CharacterVoiceBindings.voiceFor(openaiOnly, TtsProviders.elevenlabs),
        isEmpty,
      );
    });

    test('clearing one provider keeps the others', () {
      final next = CharacterVoiceBindings.withVoice(
        <String, String>{'openai': 'nova', 'elevenlabs': 'abc'},
        TtsProviders.openai,
        '',
      );
      expect(next, <String, String>{'elevenlabs': 'abc'});
      expect(
        CharacterVoiceBindings.decode(CharacterVoiceBindings.encode(next)),
        next,
      );
    });

    test('malformed json falls back to legacy value', () {
      final character = <String, Object?>{
        'tts_voice_ids_json': 'not json',
        'tts_voice_id': 'alloy',
      };
      expect(
        CharacterVoiceBindings.voiceFor(character, TtsProviders.openai),
        'alloy',
      );
    });
  });
}
