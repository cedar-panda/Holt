import 'dart:convert';

import '../memory/database.dart';
import '../utils/text_safety.dart';
import 'api_adapter.dart';
import 'character_signature_prompt.dart';
import 'settings/api_settings.dart';
import 'token_tracker.dart';

/// 在聊天請求之外生成角色簽名，成功後只寫入本地角色資料。
abstract final class CharacterSignatureService {
  static final Map<String, int> _latestRequestByCharacter = <String, int>{};
  static final Map<String, Future<String?>> _latestOperationByCharacter =
      <String, Future<String?>>{};

  static Future<String?> generateAndSave({
    required String characterId,
    required String latestUserMessage,
    required String latestAssistantReply,
    required String model,
    required String provider,
    ApiAdapter? adapterOverride,
  }) {
    final operation = _generateAndSave(
      characterId: characterId,
      latestUserMessage: latestUserMessage,
      latestAssistantReply: latestAssistantReply,
      model: model,
      provider: provider,
      adapterOverride: adapterOverride,
    );
    _latestOperationByCharacter[characterId] = operation;
    return operation;
  }

  /// 讓返回角色頁的 UI 能等候已在進行中的背景請求，再重新讀取本地資料。
  static Future<void> waitForPending(String characterId) async {
    final operation = _latestOperationByCharacter[characterId];
    if (operation == null) return;
    try {
      await operation;
    } catch (_) {
      // 簽名失敗不阻擋頁面刷新。
    }
  }

  static Future<String?> _generateAndSave({
    required String characterId,
    required String latestUserMessage,
    required String latestAssistantReply,
    required String model,
    required String provider,
    ApiAdapter? adapterOverride,
  }) async {
    final userText = latestUserMessage.trim();
    final assistantText = latestAssistantReply.trim();
    if (characterId.trim().isEmpty || assistantText.isEmpty) return null;

    final requestSerial = (_latestRequestByCharacter[characterId] ?? 0) + 1;
    _latestRequestByCharacter[characterId] = requestSerial;

    final character = await DatabaseHelper.getCharacter(characterId);
    if (character == null) return null;

    final adapter =
        adapterOverride ??
        await ApiSettings.buildAdapter(
          overrideModel: model,
          overrideProvider: provider,
        );
    ApiUsage? usage;
    final response = await adapter.sendMessage(
      messages: <Map<String, String>>[
        <String, String>{
          'role': 'user',
          'content': jsonEncode(<String, Object?>{
            'character_profile': _characterProfile(character),
            'latest_user_message': userText,
            'latest_assistant_reply': assistantText,
          }),
        },
      ],
      model: model,
      systemPrompt: CharacterSignaturePrompt.generationSystemPrompt(),
      onUsage: (value) => usage = value,
    );

    if (usage != null) {
      await TokenTracker().recordRealUsage(
        provider: provider,
        model: model,
        usage: usage!,
        characterId: characterId,
      );
    }

    final signature = normalizeResponse(response);
    if (signature.isEmpty ||
        _latestRequestByCharacter[characterId] != requestSerial) {
      return null;
    }
    await DatabaseHelper.updateCharacterSignature(characterId, signature);
    return signature;
  }

  static Map<String, String> _characterProfile(Map<String, dynamic> character) {
    const fields = <String>[
      'name',
      'gender',
      'relationship',
      'description',
      'race',
      'skill',
      'age',
      'height',
      'self_notes',
    ];
    return <String, String>{
      for (final field in fields)
        if ((character[field]?.toString().trim() ?? '').isNotEmpty)
          field: character[field].toString().trim(),
    };
  }

  static String normalizeResponse(String raw) {
    var value = raw.trim();
    if (value.startsWith('```')) {
      value = value.replaceFirst(RegExp(r'^```[^\n]*\n?'), '');
      value = value.replaceFirst(RegExp(r'\n?```$'), '').trim();
    }
    value = value.replaceFirst(
      RegExp(r'^(?:signature|個性簽名|个性签名)\s*[:：]\s*', caseSensitive: false),
      '',
    );
    if (value.length >= 2) {
      const quotePairs = <String, String>{
        '"': '"',
        "'": "'",
        '“': '”',
        '「': '」',
        '『': '』',
      };
      final closing = quotePairs[value[0]];
      if (closing != null && value.endsWith(closing)) {
        value = value.substring(1, value.length - 1).trim();
      }
    }
    value = value
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(CharacterSignaturePrompt.maxLines)
        .join('\n');
    return truncateGraphemes(
      value,
      CharacterSignaturePrompt.maxCharacters,
    ).trim();
  }
}
