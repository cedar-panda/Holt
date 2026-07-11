/// NPC 基礎動作狀態（規劃表 表四）。
/// M1 只用 idle / walk；sit / sleep / wave 等 M2 接 bio_clock 後啟用。
enum YanciActorState { idle, walk, sit, sleep, wave }
