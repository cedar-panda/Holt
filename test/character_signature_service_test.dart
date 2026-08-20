import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/character_signature_prompt.dart';
import 'package:project_yanci/services/character_signature_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    await db.insert('characters', {
      'id': 'char-signature',
      'name': '小澈',
      'description': '安靜但有自己的幽默感',
      'created_at': '2026-08-20T00:00:00.000',
      'updated_at': '2026-08-20T00:00:00.000',
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('independent request normalizes and saves the signature', () async {
    final adapter = _SignatureAdapter('個性簽名：「雨停了，等燕子回來。」');

    final result = await CharacterSignatureService.generateAndSave(
      characterId: 'char-signature',
      latestUserMessage: '今天雨停了',
      latestAssistantReply: '那就出去走走吧。',
      model: 'test-model',
      provider: 'test-provider',
      adapterOverride: adapter,
    );

    expect(result, '雨停了，等燕子回來。');
    final row = await DatabaseHelper.getCharacter('char-signature');
    expect(row?['signature'], result);
    expect(row?['updated_at'], '2026-08-20T00:00:00.000');
    expect(adapter.systemPrompt, contains('latest_user_message'));
    final payload = jsonDecode(adapter.userContent!) as Map<String, dynamic>;
    expect(payload['latest_user_message'], '今天雨停了');
    expect(
      (payload['character_profile'] as Map<String, dynamic>)['name'],
      '小澈',
    );
  });

  test('normalizer enforces four lines and the character cap', () {
    final raw = List<String>.generate(
      8,
      (index) => '第${index + 1}行內容很長',
    ).join('\n');

    final normalized = CharacterSignatureService.normalizeResponse(raw);

    expect(normalized.split('\n'), hasLength(4));
    expect(
      normalized.characters.length,
      lessThanOrEqualTo(CharacterSignaturePrompt.maxCharacters),
    );
  });
}

class _SignatureAdapter implements ApiAdapter {
  _SignatureAdapter(this.response);

  final String response;
  String? systemPrompt;
  String? userContent;

  @override
  void cancelActive() {}

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) async {
    this.systemPrompt = systemPrompt;
    userContent = messages.single['content'];
    return response;
  }

  @override
  Stream<String> sendMessageStream({
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    ApiUsageCallback? onUsage,
  }) => const Stream<String>.empty();
}
