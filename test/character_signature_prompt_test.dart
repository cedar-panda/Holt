import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/services/character_signature_prompt.dart';

void main() {
  test('keeps the signature instruction bounded for the four-line panel', () {
    final prompt = CharacterSignaturePrompt.generationSystemPrompt();

    expect(CharacterSignaturePrompt.maxLines, 4);
    expect(CharacterSignaturePrompt.maxCharacters, 64);
    expect(prompt, contains('4 lines'));
    expect(prompt, contains('64 characters'));
    expect(prompt, contains('latest_user_message'));
    expect(prompt, contains('signature text only'));
  });
}
