import '../actors/actor_state.dart';

/// 日程快照：bio_clock → 「現在他在哪個房間、做什麼」
/// 規劃表 表五：bridge 只讀 service，遊戲不做決策、不碰 DB。
class ScheduleSnapshot {
  final String room;
  final YanciActorState action;

  const ScheduleSnapshot({required this.room, required this.action});
}

class ScheduleBridge {
  /// M2 TODO：讀 BioClockService 的作息，映射成 (房間, 動作)。
  /// M1 先返回默認值——在客廳待機。
  static Future<ScheduleSnapshot> current(String characterId) async {
    return const ScheduleSnapshot(room: 'living', action: YanciActorState.idle);
  }
}
