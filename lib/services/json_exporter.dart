import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../memory/database.dart';

/// JSON 導出 — 對話記錄 + 記憶
class JsonExporter {
  /// 導出單個對話
  static Future<String> exportConversation(String conversationId) async {
    final messages = await DatabaseHelper.getMessages(conversationId);

    final data = {
      'version': 1,
      'type': 'conversation',
      'conversation_id': conversationId,
      'exported_at': DateTime.now().toIso8601String(),
      'messages': messages
          .map(
            (m) => {
              'text': m.text,
              'is_user': m.isUser,
              'character_id': m.characterId,
              'created_at': m.createdAt.toIso8601String(),
            },
          )
          .toList(),
    };

    return _saveToFile('conversation_$conversationId', data);
  }

  /// 導出所有對話
  static Future<String> exportAllConversations({String? characterId}) async {
    final conversations = await DatabaseHelper.getConversations(
      characterId: characterId,
    );
    final allData = <Map<String, dynamic>>[];

    for (final conv in conversations) {
      final messages = await DatabaseHelper.getMessages(conv.id);
      allData.add({
        'conversation_id': conv.id,
        'character_id': conv.characterId,
        'title': conv.title,
        'created_at': conv.createdAt.toIso8601String(),
        'updated_at': conv.updatedAt.toIso8601String(),
        'messages': messages
            .map(
              (m) => {
                'text': m.text,
                'is_user': m.isUser,
                'character_id': m.characterId,
                'created_at': m.createdAt.toIso8601String(),
              },
            )
            .toList(),
      });
    }

    final data = {
      'version': 1,
      'type': 'all_conversations',
      'exported_at': DateTime.now().toIso8601String(),
      'count': allData.length,
      'conversations': allData,
    };

    return _saveToFile('all_conversations', data);
  }

  /// 導出記憶庫
  static Future<String> exportMemories({
    String mode = 'romance',
    String characterId = 'default',
  }) async {
    final memories = await DatabaseHelper.getActiveMemories(
      mode,
      characterId: characterId,
    );

    final data = {
      'version': 1,
      'type': 'memories',
      'mode': mode,
      'character_id': characterId,
      'exported_at': DateTime.now().toIso8601String(),
      'count': memories.length,
      'memories': memories
          .map(
            (m) => {
              'category': m.category,
              'content': m.content,
              'confidence': m.confidence,
              'is_permanent': m.isPermanent,
              'created_at': m.createdAt.toIso8601String(),
            },
          )
          .toList(),
    };

    return _saveToFile('memories_${characterId}_$mode', data);
  }

  /// 導出全部（對話 + 記憶）
  static Future<String> exportAll({String characterId = 'default'}) async {
    final conversations = await DatabaseHelper.getConversations(
      characterId: characterId,
    );
    final convData = <Map<String, dynamic>>[];

    for (final conv in conversations) {
      final messages = await DatabaseHelper.getMessages(conv.id);
      convData.add({
        'conversation_id': conv.id,
        'title': conv.title,
        'messages': messages
            .map(
              (m) => {
                'text': m.text,
                'is_user': m.isUser,
                'created_at': m.createdAt.toIso8601String(),
              },
            )
            .toList(),
      });
    }

    final memories = await DatabaseHelper.getActiveMemories(
      'romance',
      characterId: characterId,
    );

    final data = {
      'version': 1,
      'type': 'full_export',
      'character_id': characterId,
      'exported_at': DateTime.now().toIso8601String(),
      'conversations': convData,
      'memories': memories
          .map(
            (m) => {
              'category': m.category,
              'content': m.content,
              'confidence': m.confidence,
              'is_permanent': m.isPermanent,
              'created_at': m.createdAt.toIso8601String(),
            },
          )
          .toList(),
    };

    return _saveToFile('yanci_export_$characterId', data);
  }

  /// 寫入文件，返回文件路徑
  static Future<String> _saveToFile(
    String name,
    Map<String, dynamic> data,
  ) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = '${name}_$timestamp.json';
    final dir = await _exportDir();
    final filePath = p.join(dir.path, fileName);

    final file = File(filePath);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    await file.writeAsString(jsonStr);

    return filePath;
  }

  /// 導出目錄：一律寫 App 私有文件目錄。
  /// 零權限、全平台（Android／iOS／桌面）一致、絕不失敗。
  /// 之後若要讓使用者在系統「檔案」中取得，接 share_plus 即可。
  static Future<Directory> _exportDir() async {
    return getApplicationDocumentsDirectory();
  }
}
