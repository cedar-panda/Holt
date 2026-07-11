import '../../services/api_adapter.dart';
import '../../services/settings/api_settings.dart';
import 'game_npc_settings.dart';

/// NPC 的腦子 —— 按齒輪設定拿到能推理的本地模型 adapter。
///
/// M2+ TODO：NPC 對話迴路（人設 prompt、短上下文、氣泡輸出）。
/// 本輪只鋪通「設定 → adapter」這條路。
///
/// ⚠️ 注意：ApiSettings.buildAdapter 對本地模型有全局單例緩存，
/// NPC 和聊天如果選了**不同**的本地模型，加載 NPC 模型會把聊天正在用的
/// 卸掉（手機內存放不下兩個）。M2 接對話時要做策略：
/// 同 key 復用；不同 key 時 NPC 讓位或提示。
class NpcBrain {
  /// 返回 null = NPC AI 未啟用
  static Future<ApiAdapter?> loadAdapter() async {
    final id = await GameNpcSettings.getNpcModelId();
    if (id.isEmpty) return null;
    if (id == GameNpcSettings.followChat) {
      // 跟隨聊天：API/本地一律復用聊天當前配置——
      // 同模型零衝突，也是讓位策略文檔裡推薦的最優路徑
      return ApiSettings.buildAdapter();
    }
    return ApiSettings.buildAdapter(overrideModel: id);
  }

  static Future<bool> get enabled async =>
      (await GameNpcSettings.getNpcModelId()).isNotEmpty;
}
