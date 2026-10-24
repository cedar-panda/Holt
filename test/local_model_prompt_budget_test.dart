import 'package:flutter_test/flutter_test.dart';

import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/local_model_service.dart';

void main() {
  test('Gemma prompt budget keeps system head and newest conversation', () {
    final service = LocalModelService(modelKey: 'gemma-test');
    final payload = service.debugBuildGemmaPromptForTesting(
      structuredPrompt: StructuredPrompt(
        staticPart: 'IDENTITY LOCK\n${List.filled(1200, 'A').join()}',
        profilePart: 'PROFILE\n${List.filled(800, 'B').join()}',
        liveStatePart: 'CURRENT LIVE STATE\n${List.filled(300, 'C').join()}',
      ),
      messages: <Map<String, String>>[
        <String, String>{
          'role': 'user',
          'content': 'OLD USER ${List.filled(700, 'x').join()}',
        },
        <String, String>{
          'role': 'assistant',
          'content': 'OLD ASSISTANT ${List.filled(700, 'y').join()}',
        },
        const <String, String>{
          'role': 'user',
          'content': 'LATEST USER MUST SURVIVE',
        },
      ],
      maxPromptTokens: 420,
    );

    expect(payload['system'], startsWith('IDENTITY LOCK'));
    final messages = payload['messages']! as List<Map<String, String>>;
    expect(messages.last['content'], contains('LATEST USER MUST SURVIVE'));
    expect(
      messages.any((message) => message['content']!.contains('OLD USER')),
      isFalse,
    );
  });
}
