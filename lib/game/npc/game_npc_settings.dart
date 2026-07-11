import 'package:shared_preferences/shared_preferences.dart';

/// 遊戲 NPC 的 AI 設定（遊戲頁右上角齒輪調）。
/// 取值：'' = 不啟用；[followChat] = 跟隨聊天當前模型（API/本地都行，
/// 永遠與 API 設定同步、零額外內存衝突）；否則為本地模型 id。
class GameNpcSettings {
  static const String _keyNpcModel = 'game_npc_model';

  /// 跟隨聊天模型的哨兵值
  static const String followChat = 'follow_chat';

  static Future<String> getNpcModelId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyNpcModel) ?? '';
  }

  static Future<void> setNpcModelId(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyNpcModel, id);
  }
}
