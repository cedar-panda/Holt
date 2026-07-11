import 'package:flutter/foundation.dart' show debugPrint;

import '../memory/database.dart';
import 'locale_strings.dart';

/// ═══════════════════════════════════════════════
/// 角色生活化 Timeline 服務
/// ═══════════════════════════════════════════════
///
/// 兩類事件：
/// - state（狀態變更）：髮型、住所、健康等，key UNIQUE 覆蓋
/// - event（一次性事件）：看電影、吃飯、吵架，7天分段，自動清理
///
/// 數據來源：掃描模型回覆中的關鍵詞（被動），不是模型主動打標籤。
/// 注入方式：每個對話框第一條消息附帶狀態快照。
///
class CharacterTimelineService {
  static bool _tableEnsured = false;

  // ─────────────────────────────────────────────
  // A. 關鍵詞表
  // ─────────────────────────────────────────────

  /// 狀態變更關鍵詞 → (key, 默認 value 提取規則)
  /// 只識別 char 的回覆，不掃 user 的消息
  static const Map<String, String> kStateKeywords = {
    // 外觀 — 髮型
    '剪頭髮': '髮型', '剪髮': '髮型', '理髮': '髮型', '修剪頭髮': '髮型',
    '染了頭髮': '髮型', '染頭髮': '髮型', '染髮': '髮型', '燙髮': '髮型',
    '燙了頭髮': '髮型',
    // 外觀 — 美甲
    '做了美甲': '美甲', '做美甲': '美甲',
    // 外觀 — 鬍子
    '剃了鬍子': '鬍子', '剃鬚': '鬍子',
    // 生活 — 住所
    '搬家': '住所', '搬新家': '住所', '換了間屋子': '住所',
    // 生活 — 工作
    '剛換工作': '工作', '換工作': '工作', '換了工作': '工作',
    // 生活 — 寵物
    '養了動物': '寵物', '養了貓': '寵物', '養了狗': '寵物',
    // 健康（模型自主提及時記錄）
    '感冒': '健康', '發燒': '健康', '頭痛': '健康', '疲勞': '健康',
    '失眠': '健康', '不舒服': '健康', '生病': '健康', '咳嗽': '健康',
    '過敏': '健康', '肚子痛': '健康', '拉肚子': '健康',
  };

  /// 健康好轉關鍵詞（觸發時覆蓋健康 key 為「正常」）
  /// 「好了」已移除——「好了好了別鬧」這種日常語氣誤觸率太高，
  /// 一句撒嬌就把感冒治好了。
  static const List<String> kHealthRecoveryKeywords = [
    '好多了',
    '恢復了',
    '痊癒',
    '不咳了',
    '退燒了',
    '精力旺盛',
    '精神很好',
    '睡得好',
  ];

  /// 一次性事件關鍵詞
  /// 「出門」「回家」已移除——聊天裡出現頻率太高，事件表全是垃圾條目。
  static const List<String> kEventKeywords = [
    '吵架',
    '看電影',
    '去吃飯',
    '商場購物',
    '逛街',
    '約會',
    '旅行',
    '聚餐',
  ];

  // ─────────────────────────────────────────────
  // B. 數據庫
  // ─────────────────────────────────────────────

  static Future<void> _ensureTable() async {
    if (_tableEnsured) return;
    final db = await DatabaseHelper.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS character_timeline (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'state',
        key TEXT,
        value TEXT NOT NULL,
        source_memory_id INTEGER,
        week_group TEXT,
        confirmed INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    // state 類用 character_id + key 做 UNIQUE（新的覆蓋舊的）
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_state
      ON character_timeline (character_id, key)
      WHERE type = 'state'
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_timeline_event_lookup
      ON character_timeline (character_id, type, confirmed, week_group, created_at)
    ''');
    _tableEnsured = true;
  }

  // ─────────────────────────────────────────────
  // C. 掃描模型回覆
  // ─────────────────────────────────────────────

  /// 掃描 char 回覆中的關鍵詞，自動歸檔
  /// 返回新增/更新的條數
  static Future<int> scanReply(String characterId, String charReply) async {
    await _ensureTable();
    int count = 0;

    // 1. 檢查健康好轉——只在「本來就有不正常的健康記錄」時才觸發，
    //    否則健康詞和恢復詞同回覆出現時會互相打架
    bool healthRecovered = false;
    final states = await getStates(characterId);
    final healthRows = states.where((s) => s['key'] == '健康').toList();
    final currentHealth = healthRows.isEmpty
        ? null
        : healthRows.first['value'] as String?;
    if (currentHealth != null && currentHealth != '正常') {
      for (final kw in kHealthRecoveryKeywords) {
        if (charReply.contains(kw)) {
          await upsertState(characterId, '健康', '正常');
          healthRecovered = true;
          count++;
          break;
        }
      }
    }

    // 2. 檢查狀態變更
    // 舊版用 count > 0 判斷「健康已處理」——count 可能來自任何狀態，
    // 會誤吞真正的健康記錄。改用專屬 flag。
    for (final entry in kStateKeywords.entries) {
      if (charReply.contains(entry.key)) {
        if (entry.value == '健康' && healthRecovered) continue;
        await upsertState(
          characterId,
          entry.value,
          _extractValue(entry.key, entry.value, charReply),
        );
        count++;
      }
    }

    // 3. 檢查一次性事件。直接命中關鍵詞先確認，否則現有讀取流程永遠不會展示。
    for (final kw in kEventKeywords) {
      if (charReply.contains(kw)) {
        await addEvent(characterId, kw);
        count++;
      }
    }

    return count;
  }

  /// 從上下文提取更具體的值（簡單啟發式）
  static String _extractValue(String keyword, String key, String text) {
    // 對於健康類，直接用關鍵詞
    if (key == '健康') return keyword;

    // 對於其他類，嘗試提取關鍵詞附近的描述
    // 簡單做法：用關鍵詞本身作為值
    // TODO: 可以用小模型提取更精確的描述
    return keyword;
  }

  // ─────────────────────────────────────────────
  // D. CRUD
  // ─────────────────────────────────────────────

  /// 插入或更新狀態（state 類，key UNIQUE）
  static Future<void> upsertState(
    String characterId,
    String key,
    String value, {
    int? sourceMemoryId,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();

    await db.rawInsert(
      '''
      INSERT INTO character_timeline
        (character_id, type, key, value, source_memory_id, confirmed, created_at, updated_at)
      VALUES (?, 'state', ?, ?, ?, 1, ?, ?)
      ON CONFLICT (character_id, key) WHERE type = 'state'
      DO UPDATE SET value = ?, source_memory_id = ?, updated_at = ?
    ''',
      [
        characterId,
        key,
        value,
        sourceMemoryId,
        now,
        now,
        value,
        sourceMemoryId,
        now,
      ],
    );
  }

  /// 新增一次性事件
  static Future<void> addEvent(
    String characterId,
    String value, {
    bool confirmed = true,
    int? sourceMemoryId,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final now = DateTime.now();
    final weekGroup = _weekGroup(now);

    await db.insert('character_timeline', {
      'character_id': characterId,
      'type': 'event',
      'key': null,
      'value': value,
      'source_memory_id': sourceMemoryId,
      'week_group': weekGroup,
      'confirmed': confirmed ? 1 : 0,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
  }

  /// 確認一次性事件
  static Future<void> confirmEvent(int id) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    await db.update(
      'character_timeline',
      {'confirmed': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 獲取所有狀態（state 類）
  static Future<List<Map<String, dynamic>>> getStates(
    String characterId,
  ) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    return db.query(
      'character_timeline',
      where: "character_id = ? AND type = 'state'",
      whereArgs: [characterId],
      orderBy: 'updated_at DESC',
    );
  }

  /// 獲取一次性事件（按 week_group 分段）
  static Future<List<Map<String, dynamic>>> getEvents(
    String characterId, {
    String? weekGroup,
    int limit = 5,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;

    if (weekGroup != null) {
      return db.query(
        'character_timeline',
        where:
            "character_id = ? AND type = 'event' AND week_group = ? AND confirmed = 1",
        whereArgs: [characterId, weekGroup],
        orderBy: 'created_at DESC',
        limit: limit,
      );
    }
    return db.query(
      'character_timeline',
      where: "character_id = ? AND type = 'event' AND confirmed = 1",
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// 獲取所有 week_group（UI 時間線用）
  static Future<List<String>> getWeekGroups(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT week_group FROM character_timeline
      WHERE character_id = ? AND type = 'event' AND confirmed = 1
      ORDER BY week_group DESC
    ''',
      [characterId],
    );
    return rows.map((r) => r['week_group'] as String).toList();
  }

  // ─────────────────────────────────────────────
  // E. 注入 prompt
  // ─────────────────────────────────────────────

  /// 狀態快照（每個對話框第一條消息注入）
  static Future<String> stateSnapshotPrompt(String characterId) async {
    final states = await getStates(characterId);
    if (states.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln(L.pick(en: '【Your recent life status】', zhTW: '【你的近期生活狀態】'));

    for (final s in states) {
      final key = s['key'] as String;
      final value = s['value'] as String;
      final updated = s['updated_at'] as String;
      final date = updated.substring(0, 10); // YYYY-MM-DD
      buf.writeln(
        '$key${L.pick(en: ': ', zhTW: '：')}$value${L.pick(en: ' (since ', zhTW: '（')}$date${L.pick(en: ')', zhTW: ' 起）')}',
      );
    }

    buf.writeln(
      L.pick(
        en: 'If anything is wrong, use <life_fix>field|new status</life_fix> to correct. No action needed if correct.',
        zhTW: '如有變化用 <life_fix>欄位|新狀態</life_fix> 更正，沒問題就不用動。',
      ),
    );

    return buf.toString().trimRight();
  }

  /// 回憶觸發（user 說「你還記得上次……」時注入相關時間線）
  static Future<String> recallPrompt(
    String characterId,
    String userMessage,
  ) async {
    const recallTriggers = [
      '上次',
      '那次',
      '之前',
      '還記得',
      '記不記得',
      'last time',
      'remember when',
      'do you remember',
    ];

    bool triggered = false;
    for (final t in recallTriggers) {
      if (userMessage.contains(t)) {
        triggered = true;
        break;
      }
    }
    if (!triggered) return '';

    // 搜索匹配的事件
    final events = await getEvents(characterId, limit: 10);
    if (events.isEmpty) return '';

    // 匹配：整詞命中，或事件值的連續雙字片段出現在 user 消息中。
    // 舊版按「單個字符有交集」匹配——幾乎任何消息都算命中，等於沒過濾。
    final matched = <Map<String, dynamic>>[];
    for (final e in events) {
      final value = e['value'] as String;
      bool hit = userMessage.contains(value);
      if (!hit && value.length >= 2) {
        for (int i = 0; i <= value.length - 2; i++) {
          if (userMessage.contains(value.substring(i, i + 2))) {
            hit = true;
            break;
          }
        }
      }
      if (hit) matched.add(e);
    }

    // 如果沒有精確匹配，返回最近的幾條
    final toShow = matched.isNotEmpty ? matched.take(3) : events.take(3);

    final buf = StringBuffer();
    buf.writeln(
      L.pick(en: '【Timeline recall】Related events:', zhTW: '【時間線回憶】相關事件：'),
    );
    for (final e in toShow) {
      final date = (e['created_at'] as String).substring(0, 10);
      buf.writeln('· $date ${e['value']}');
    }
    return buf.toString().trimRight();
  }

  /// 處理模型回覆中的 `<life_fix>` 標籤
  static Future<String> processLifeFix(String characterId, String reply) async {
    final pattern = RegExp(r'<life_fix>(.*?)\|(.*?)</life_fix>');
    final matches = pattern.allMatches(reply);

    for (final m in matches) {
      final key = m.group(1)?.trim() ?? '';
      final value = m.group(2)?.trim() ?? '';
      if (key.isNotEmpty && value.isNotEmpty) {
        await upsertState(characterId, key, value);
      }
    }

    // 剝離標籤
    return reply.replaceAll(pattern, '').trim();
  }

  // ─────────────────────────────────────────────
  // F. 自動清理
  // ─────────────────────────────────────────────

  /// 清理過期的一次性事件（保留 state），默認保留 90 天
  static Future<int> cleanup(String characterId, {int keepDays = 90}) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: keepDays))
        .toIso8601String();

    return db.delete(
      'character_timeline',
      where: "character_id = ? AND type = 'event' AND created_at < ?",
      whereArgs: [characterId, cutoff],
    );
  }

  /// 啟動維護：過期事件清理 + 健康自動回正。
  /// main.dart 啟動時對活躍角色調用（fire-and-forget）。
  static Future<void> startupMaintenance(String characterId) async {
    await _ensureTable();
    // 1. 事件保留 90 天
    final removed = await cleanup(characterId);
    if (removed > 0) {
      debugPrint('時間線維護：清理 $removed 條過期事件');
    }

    // 2. 健康自動回正：非正常健康狀態掛超過 7 天 → 回「正常」。
    //    她照樣會感冒生病——病中這 7 天狀態都在快照裡；
    //    這裡只保證「感冒」不會三個月後還掛在檔案上。
    //    fatiguePrompt（熬夜疲勞提示）是另一層，不受影響。
    final db = await DatabaseHelper.database;
    final healthCutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    final stale = await db.query(
      'character_timeline',
      where:
          "character_id = ? AND type = 'state' AND key = '健康' "
          "AND value != '正常' AND updated_at < ?",
      whereArgs: [characterId, healthCutoff],
    );
    if (stale.isNotEmpty) {
      await upsertState(characterId, '健康', '正常');
      debugPrint('時間線維護：健康狀態超過 7 天未更新，自動回正');
    }
  }

  // ─────────────────────────────────────────────
  // 工具
  // ─────────────────────────────────────────────

  /// 計算 ISO week group（如 2026-W25）
  static String _weekGroup(DateTime dt) {
    // 簡化版 ISO week：用年+週數。
    // 年初幾天可能算出 week 0（如元旦落在週一），鉗到 1。
    final jan1 = DateTime(dt.year, 1, 1);
    final dayOfYear = dt.difference(jan1).inDays;
    final week = ((dayOfYear + jan1.weekday - 1) / 7).ceil().clamp(1, 53);
    return '${dt.year}-W${week.toString().padLeft(2, '0')}';
  }

  /// 導出完整數據
  static Future<List<Map<String, dynamic>>> exportAll(
    String characterId,
  ) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    return db.query(
      'character_timeline',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at DESC',
    );
  }
}
