import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../utils/text_safety.dart';
import 'api_adapter.dart';
import 'character_signature_prompt.dart';
import 'settings/api_settings.dart';
import 'settings/character_signature_settings.dart';
import 'token_tracker.dart';

/// 在聊天請求之外生成角色簽名，成功後只寫入本地角色資料。
abstract final class CharacterSignatureService {
  static final Map<String, int> _latestRequestByCharacter = <String, int>{};
  static final Map<String, Future<String?>> _latestOperationByCharacter =
      <String, Future<String?>>{};
  static final Map<String, Future<String?>> _windowOperations =
      <String, Future<String?>>{};

  static const String openingPhase = 'opening';
  static const String closingPhase = 'closing';

  /// A window may generate at most one opening and one closing signature.
  /// The existence check happens before building an adapter, so repeated chat
  /// turns do not create hidden provider requests.
  static Future<String?> generateForWindow({
    required String characterId,
    required String conversationId,
    required String phase,
    required ContextMode contextMode,
    required String continuityId,
    required String latestUserMessage,
    required String latestAssistantReply,
    required String model,
    required String provider,
    ApiAdapter? adapterOverride,
  }) async {
    if (phase != openingPhase && phase != closingPhase) {
      throw ArgumentError.value(phase, 'phase');
    }
    if (!await CharacterSignatureSettings.isEnabled()) return null;
    final key = '${conversationId.trim()}::$phase';
    final running = _windowOperations[key];
    if (running != null) return running;
    final operation = _generateForWindow(
      characterId: characterId,
      conversationId: conversationId,
      phase: phase,
      contextMode: contextMode,
      continuityId: continuityId,
      latestUserMessage: latestUserMessage,
      latestAssistantReply: latestAssistantReply,
      model: model,
      provider: provider,
      adapterOverride: adapterOverride,
    );
    _windowOperations[key] = operation;
    _latestOperationByCharacter[characterId] = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_windowOperations[key], operation)) {
            _windowOperations.remove(key);
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_windowOperations[key], operation)) {
            _windowOperations.remove(key);
          }
        },
      ),
    );
    return operation;
  }

  static Future<String?> _generateForWindow({
    required String characterId,
    required String conversationId,
    required String phase,
    required ContextMode contextMode,
    required String continuityId,
    required String latestUserMessage,
    required String latestAssistantReply,
    required String model,
    required String provider,
    ApiAdapter? adapterOverride,
  }) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'character_signatures',
      columns: const <String>['signature'],
      where: 'conversation_id = ? AND phase = ?',
      whereArgs: <Object?>[conversationId, phase],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['signature']?.toString();
    if (latestAssistantReply.trim().isEmpty) return null;

    final signature = await _generateSignature(
      characterId: characterId,
      latestUserMessage: latestUserMessage,
      latestAssistantReply: latestAssistantReply,
      model: model,
      provider: provider,
      adapterOverride: adapterOverride,
    );
    if (signature == null || signature.isEmpty) return null;

    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('character_signatures', <String, Object?>{
        'character_id': characterId,
        'conversation_id': conversationId,
        'context_mode': contextMode.storageValue,
        'continuity_id': continuityId.trim().isEmpty ? 'main' : continuityId,
        'phase': phase,
        'signature': signature,
        'is_selected': 0,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final selected = await txn.query(
        'character_signatures',
        columns: const <String>['id'],
        where: 'character_id = ? AND is_selected = 1',
        whereArgs: <Object?>[characterId],
        limit: 1,
      );
      if (selected.isEmpty) {
        await txn.update(
          'characters',
          <String, Object?>{'signature': signature},
          where: 'id = ?',
          whereArgs: <Object?>[characterId],
        );
      }
    });
    return signature;
  }

  static Future<List<Map<String, dynamic>>> historyForCharacter(
    String characterId,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''SELECT s.*, c.title AS conversation_title,
                CASE WHEN s.is_selected = 1 OR (
                  NOT EXISTS (
                    SELECT 1
                    FROM character_signatures AS pinned
                    WHERE pinned.character_id = s.character_id
                      AND pinned.is_selected = 1
                  )
                  AND s.id = (
                    SELECT latest.id
                    FROM character_signatures AS latest
                    WHERE latest.character_id = s.character_id
                    ORDER BY latest.created_at DESC, latest.id DESC
                    LIMIT 1
                  )
                ) THEN 1 ELSE 0 END AS is_displayed
         FROM character_signatures AS s
         LEFT JOIN conversations AS c ON c.id = s.conversation_id
         WHERE s.character_id = ?
         ORDER BY s.created_at DESC, s.id DESC''',
      <Object?>[characterId],
    );
    return rows;
  }

  /// Selects an existing history entry as the signature shown on character
  /// cards. The ownership check rejects stale or cross-character selections.
  static Future<String> selectDisplayedSignature({
    required String characterId,
    required int signatureId,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'character_signatures',
        columns: const <String>['signature'],
        where: 'id = ? AND character_id = ?',
        whereArgs: <Object?>[signatureId, characterId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Character signature history entry was not found');
      }
      final signature = normalizeResponse(
        rows.single['signature']?.toString() ?? '',
      );
      if (signature.isEmpty) {
        throw const FormatException('Character signature is empty');
      }
      await txn.update(
        'character_signatures',
        const <String, Object?>{'is_selected': 0},
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
      );
      await txn.update(
        'character_signatures',
        const <String, Object?>{'is_selected': 1},
        where: 'id = ? AND character_id = ?',
        whereArgs: <Object?>[signatureId, characterId],
      );
      await txn.update(
        'characters',
        <String, Object?>{'signature': signature},
        where: 'id = ?',
        whereArgs: <Object?>[characterId],
      );
      return signature;
    });
  }

  /// Clears a manual selection and resumes showing the newest signature.
  static Future<String> followLatestSignature(String characterId) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final latest = await txn.query(
        'character_signatures',
        columns: const <String>['signature'],
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
        orderBy: 'created_at DESC, id DESC',
        limit: 1,
      );
      if (latest.isEmpty) {
        throw StateError('Character signature history is empty');
      }
      final signature = normalizeResponse(
        latest.single['signature']?.toString() ?? '',
      );
      if (signature.isEmpty) {
        throw const FormatException('Character signature is empty');
      }
      await txn.update(
        'character_signatures',
        const <String, Object?>{'is_selected': 0},
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
      );
      await txn.update(
        'characters',
        <String, Object?>{'signature': signature},
        where: 'id = ?',
        whereArgs: <Object?>[characterId],
      );
      return signature;
    });
  }

  static Future<String?> generateAndSave({
    required String characterId,
    required String latestUserMessage,
    required String latestAssistantReply,
    required String model,
    required String provider,
    ApiAdapter? adapterOverride,
  }) {
    final operation =
        _generateSignature(
          characterId: characterId,
          latestUserMessage: latestUserMessage,
          latestAssistantReply: latestAssistantReply,
          model: model,
          provider: provider,
          adapterOverride: adapterOverride,
        ).then((signature) async {
          if (signature != null && signature.isNotEmpty) {
            await DatabaseHelper.updateCharacterSignature(
              characterId,
              signature,
            );
          }
          return signature;
        });
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

  static Future<String?> _generateSignature({
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
          thinkingEnabledOverride: false,
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

    await TokenTracker().recordRealUsage(
      provider: provider,
      model: model,
      usage: usage ?? const ApiUsage(),
      characterId: characterId,
      requestKind: ApiRequestKind.signature,
    );

    final finalOnly = ThinkingModePolicy.sanitizeVisibleReply(
      response,
      enabled: false,
    );
    final signature = normalizeResponse(finalOnly);
    if (signature.isEmpty ||
        _latestRequestByCharacter[characterId] != requestSerial) {
      return null;
    }
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
    var value = ThinkingModePolicy.sanitizeVisibleReply(
      raw,
      enabled: false,
    ).trim();
    if (value.startsWith('```')) {
      value = value.replaceFirst(RegExp(r'^```[^\n]*\n?'), '');
      value = value.replaceFirst(RegExp(r'\n?```$'), '').trim();
    }
    value = _extractFinalOnlySignature(value);
    if (value.isEmpty) return '';
    value = value.replaceFirst(
      RegExp(
        r'^(?:\[?final(?: answer)?\]?|signature|個性簽名|个性签名)\s*[:：]?\s*',
        caseSensitive: false,
      ),
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

  static String _extractFinalOnlySignature(String value) {
    final reasoningMarker = RegExp(
      r'(?:^|\n)\s*(?:\[/?(?:analysis|thinking|reasoning)\]|</?(?:analysis|thinking|reasoning)\b[^>]*>|(?:analysis|thinking|reasoning)\s*[:：])',
      caseSensitive: false,
      multiLine: true,
    );
    if (!reasoningMarker.hasMatch(value)) return value;
    final finalMarker = RegExp(
      r'(?:^|\n)\s*(?:\[?final(?: answer)?\]?|signature|個性簽名|个性签名)\s*[:：]\s*([\s\S]+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(value);
    return finalMarker?.group(1)?.trim() ?? '';
  }
}
