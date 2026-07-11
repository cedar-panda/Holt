import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../memory/database.dart';
import 'locale_strings.dart';

/// ═══════════════════════════════════════════════════════════════
/// 生物鐘系統
/// ═══════════════════════════════════════════════════════════════
///
/// 讓角色有自己的作息——不是固定時間表，是帶毛邊的生活習慣。
/// 模型用 `<clock>` 標籤記錄，系統在適當時機注入提示，
/// 模型自己決定要不要用、怎麼用。
///
/// ## 區塊
///   A. 數據模型 + 存儲
///   B. 寫入 + 去重
///   C. 觸發（±2h 窗口、冷卻、白名單）
///   D. 校準（頻率遞減）
///   E. 標籤處理（processReply）
///   F. Ability Prompt
///
/// ## Token 成本
///   觸發注入：每 3h 最多一次，一條短句
///   校準：0~15天每3天 / 15~90天每7天 / 90天+每15天
///   去重提問：偶發，一次幾十字
///
/// ## 存儲
///   characters 表 bio_clock TEXT 欄，JSON 格式，懶建欄。
/// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
// A. 數據模型 + 存儲
// ═══════════════════════════════════════════════════════════════

/// 單條習慣
class ClockHabit {
  final int id;
  final int hour;
  final int minute;
  final String content;
  final List<String> keywords;
  final DateTime createdAt;
  DateTime? lastTriggeredAt;

  ClockHabit({
    required this.id,
    required this.hour,
    required this.minute,
    required this.content,
    required this.keywords,
    required this.createdAt,
    this.lastTriggeredAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': hour,
    'minute': minute,
    'content': content,
    'keywords': keywords,
    'created_at': createdAt.toIso8601String(),
    'last_triggered_at': lastTriggeredAt?.toIso8601String(),
  };

  static ClockHabit fromJson(Map<String, dynamic> j) => ClockHabit(
    id: j['id'] as int,
    hour: j['hour'] as int,
    minute: j['minute'] as int? ?? 0,
    content: j['content'] as String,
    keywords: (j['keywords'] as List<dynamic>)
        .map((e) => e.toString())
        .toList(),
    createdAt: DateTime.parse(j['created_at'] as String),
    lastTriggeredAt: j['last_triggered_at'] != null
        ? DateTime.parse(j['last_triggered_at'] as String)
        : null,
  );

  /// 習慣對應的分鐘數（0~1439），用於時間窗口計算
  int get totalMinutes => hour * 60 + minute;
}

/// 待去重項
class PendingDedup {
  final int existingId;
  final ClockHabit newHabit;

  PendingDedup({required this.existingId, required this.newHabit});

  Map<String, dynamic> toJson() => {
    'existing_id': existingId,
    'new_habit': newHabit.toJson(),
  };

  static PendingDedup fromJson(Map<String, dynamic> j) => PendingDedup(
    existingId: j['existing_id'] as int,
    newHabit: ClockHabit.fromJson(j['new_habit'] as Map<String, dynamic>),
  );
}

/// 完整生物鐘數據
class BioClockData {
  List<ClockHabit> habits;
  DateTime? firstClockAt;
  DateTime? lastCalibrateAt;
  DateTime? lastInjectAt;
  int nextId;
  List<PendingDedup> pendingDedup;

  BioClockData({
    List<ClockHabit>? habits,
    this.firstClockAt,
    this.lastCalibrateAt,
    this.lastInjectAt,
    this.nextId = 1,
    List<PendingDedup>? pendingDedup,
  }) : habits = habits ?? [],
       pendingDedup = pendingDedup ?? [];

  Map<String, dynamic> toJson() => {
    'habits': habits.map((h) => h.toJson()).toList(),
    'meta': {
      'first_clock_at': firstClockAt?.toIso8601String(),
      'last_calibrate_at': lastCalibrateAt?.toIso8601String(),
      'last_inject_at': lastInjectAt?.toIso8601String(),
      'next_id': nextId,
    },
    'pending_dedup': pendingDedup.map((d) => d.toJson()).toList(),
  };

  static BioClockData fromJson(Map<String, dynamic> j) {
    final meta = j['meta'] as Map<String, dynamic>? ?? {};
    return BioClockData(
      habits: (j['habits'] as List<dynamic>? ?? [])
          .map((e) => ClockHabit.fromJson(e as Map<String, dynamic>))
          .toList(),
      firstClockAt: meta['first_clock_at'] != null
          ? DateTime.parse(meta['first_clock_at'] as String)
          : null,
      lastCalibrateAt: meta['last_calibrate_at'] != null
          ? DateTime.parse(meta['last_calibrate_at'] as String)
          : null,
      lastInjectAt: meta['last_inject_at'] != null
          ? DateTime.parse(meta['last_inject_at'] as String)
          : null,
      nextId: meta['next_id'] as int? ?? 1,
      pendingDedup: (j['pending_dedup'] as List<dynamic>? ?? [])
          .map((e) => PendingDedup.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 主服務
// ═══════════════════════════════════════════════════════════════

class BioClockService {
  // ─────────────────────────────────────────────
  // 常量
  // ─────────────────────────────────────────────

  /// 習慣上限
  static const int kMaxHabits = 10;

  /// 觸發窗口（小時）：±2h
  static const int kTriggerWindowHours = 2;

  /// 注入冷卻（小時）：3h 內不重複注入
  static const int kInjectCooldownHours = 3;

  /// 單一習慣冷卻（小時）：16h 內同一習慣不重複觸發
  static const int kHabitCooldownHours = 16;

  /// 白名單：免 16h 冷卻（可早晚各一次）
  static const kBidailyKeywords = ['洗澡', '刷牙', '上廁所', '運動'];

  /// 校準頻率遞減：(天數門檻, 間隔天數)
  ///   0~14天：每 3 天
  ///   15~89天：每 7 天
  ///   90天+：每 15 天
  static const _calibrateSchedule = [
    (15, 3),
    (90, 7),
    (-1, 15), // -1 = 之後全部
  ];

  // ─────────────────────────────────────────────
  // A. 存儲（懶建欄）
  // ─────────────────────────────────────────────

  static bool _columnEnsured = false;

  /// 確保 characters 表有 bio_clock 欄
  static Future<void> _ensureColumn() async {
    if (_columnEnsured) return;
    final db = await DatabaseHelper.database;
    try {
      await db.rawQuery("SELECT bio_clock FROM characters LIMIT 1");
    } catch (_) {
      await db.execute(
        "ALTER TABLE characters ADD COLUMN bio_clock TEXT DEFAULT ''",
      );
    }
    _columnEnsured = true;
  }

  /// 讀取角色的生物鐘數據
  static Future<BioClockData> _load(String characterId) async {
    await _ensureColumn();
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'characters',
      columns: ['bio_clock'],
      where: 'id = ?',
      whereArgs: [characterId],
    );
    if (rows.isEmpty) return BioClockData();
    final raw = rows.first['bio_clock'] as String? ?? '';
    if (raw.isEmpty) return BioClockData();
    try {
      return BioClockData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return BioClockData();
    }
  }

  /// 寫回
  static Future<void> _save(String characterId, BioClockData data) async {
    await _ensureColumn();
    final db = await DatabaseHelper.database;
    await db.update(
      'characters',
      {'bio_clock': jsonEncode(data.toJson())},
      where: 'id = ?',
      whereArgs: [characterId],
    );
  }

  // ─────────────────────────────────────────────
  // B. 寫入 + 去重
  // ─────────────────────────────────────────────

  /// 寫入一條新習慣。返回 true 表示寫入成功，false 表示已滿或無效。
  /// 關鍵詞重複時不立即刪除，放入 pendingDedup 等下一輪讓模型選。
  static Future<bool> addHabit(
    String characterId, {
    required int hour,
    required int minute,
    required String content,
    required List<String> keywords,
  }) async {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return false;
    if (content.isEmpty || keywords.isEmpty) return false;

    final data = await _load(characterId);

    // 上限檢查
    if (data.habits.length >= kMaxHabits) return false;

    final now = DateTime.now();
    final habit = ClockHabit(
      id: data.nextId,
      hour: hour,
      minute: minute,
      content: content,
      keywords: keywords,
      createdAt: now,
    );
    data.nextId++;

    // 初次記錄
    data.firstClockAt ??= now;

    // 關鍵詞去重檢測
    final overlap = _findKeywordOverlap(data.habits, keywords);
    if (overlap != null) {
      // 有重複 → 放入待去重，兩條都保留，下一輪讓模型選
      data.habits.add(habit);
      data.pendingDedup.add(
        PendingDedup(existingId: overlap.id, newHabit: habit),
      );
    } else {
      data.habits.add(habit);
    }

    await _save(characterId, data);
    return true;
  }

  /// 找關鍵詞重複的既有習慣
  static ClockHabit? _findKeywordOverlap(
    List<ClockHabit> habits,
    List<String> newKeywords,
  ) {
    for (final h in habits) {
      for (final kw in h.keywords) {
        if (newKeywords.contains(kw)) return h;
      }
    }
    return null;
  }

  /// 去重選擇：保留指定 id 的習慣，刪除 pendingDedup 中的另一條
  static Future<void> resolveDedup(String characterId, int keepId) async {
    final data = await _load(characterId);
    if (data.pendingDedup.isEmpty) return;

    // 找出這次去重涉及的兩個 id
    final pending = data.pendingDedup.firstWhere(
      (d) => d.existingId == keepId || d.newHabit.id == keepId,
      orElse: () => data.pendingDedup.first,
    );

    final removeId = keepId == pending.existingId
        ? pending.newHabit.id
        : pending.existingId;
    data.habits.removeWhere((h) => h.id == removeId);
    data.pendingDedup.removeWhere(
      (d) => d.existingId == keepId || d.newHabit.id == keepId,
    );

    await _save(characterId, data);
  }

  /// 兜底去重：24h 後 app 啟動時調用，概率淘汰未處理的重複
  static Future<void> fallbackDedup(String characterId) async {
    final data = await _load(characterId);
    if (data.pendingDedup.isEmpty) return;

    final rng = Random();
    final toRemove = <int>{};

    for (final d in data.pendingDedup) {
      // 50% 概率留 existing，50% 留 new
      final removeId = rng.nextBool() ? d.newHabit.id : d.existingId;
      toRemove.add(removeId);
    }
    data.habits.removeWhere((h) => toRemove.contains(h.id));
    data.pendingDedup.clear();

    await _save(characterId, data);
  }

  // ─────────────────────────────────────────────
  // C. 觸發（±2h 窗口、冷卻、白名單）
  // ─────────────────────────────────────────────

  /// 檢查是否該注入生物鐘提示。返回提示文本或空字串。
  /// 有副作用：更新 lastInjectAt 和 lastTriggeredAt。
  /// 習慣清單（靜態注入用）。
  /// 模型以前看不到本地已存的習慣 → 反覆記重複條目，dedup 只能事後補救。
  /// 清單放靜態 prompt：模型隨時看得到 ①②③ 全貌，從根上不重複；
  /// 清單變化頻率低，緩存只在真的增刪改時重建一次。
  /// 「此刻時段觸發」的提醒仍走動態（triggerPrompt），職責分開。
  static Future<String> habitListPrompt(String characterId) async {
    final data = await _load(characterId);
    if (data.habits.isEmpty) return '';
    final sorted = [...data.habits]
      ..sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));
    final buf = StringBuffer();
    buf.writeln(
      L.pick(
        en: '【Your bio-clock habits (${data.habits.length}/$kMaxHabits recorded)】',
        zhTW: '【你的生物鐘習慣（已記錄 ${data.habits.length}/$kMaxHabits 條）】',
      ),
    );
    for (final h in sorted) {
      final hh = h.hour.toString().padLeft(2, '0');
      final mm = h.minute.toString().padLeft(2, '0');
      buf.writeln(
        '${_circledNum(h.id)} $hh:$mm ${h.content}'
        '${h.keywords.isNotEmpty ? ' @${h.keywords.join(",")}' : ''}',
      );
    }
    buf.writeln(
      L.pick(
        en: 'Check this list before adding <clock> — no duplicates. Use <clock_update> to modify, <clock_del> to remove.',
        zhTW:
            '新增 <clock> 前先看這份清單，同類習慣不要重複記；要改用 <clock_update>，要刪用 <clock_del>。',
      ),
    );
    return buf.toString().trimRight();
  }

  /// 當前全部習慣的 id 集合（開窗快照用）
  static Future<Set<int>> habitIds(String characterId) async {
    final data = await _load(characterId);
    return data.habits.map((h) => h.id).toSet();
  }

  /// 窗口增量（動態注入）：列出 id 不在快照裡的習慣＝本窗口新記的。
  /// 快照凍結在靜態保緩存穩定，新增走這裡跟著最新消息走，
  /// 下次開窗快照重拍自然合併——增量方案。
  static Future<String> habitDeltaPrompt(
    String characterId,
    Set<int> knownIds,
  ) async {
    final data = await _load(characterId);
    final fresh = data.habits.where((h) => !knownIds.contains(h.id)).toList()
      ..sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));
    if (fresh.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln(
      L.pick(en: '【Habits recorded in this window】', zhTW: '【本窗口新記的習慣】'),
    );
    for (final h in fresh) {
      final hh = h.hour.toString().padLeft(2, '0');
      final mm = h.minute.toString().padLeft(2, '0');
      buf.writeln(
        '${_circledNum(h.id)} $hh:$mm ${h.content}'
        '${h.keywords.isNotEmpty ? ' @${h.keywords.join(",")}' : ''}',
      );
    }
    return buf.toString().trimRight();
  }

  static Future<String> triggerPrompt(String characterId) async {
    final data = await _load(characterId);
    if (data.habits.isEmpty) return '';

    final now = DateTime.now();

    // 3h 注入冷卻
    if (data.lastInjectAt != null) {
      final elapsed = now.difference(data.lastInjectAt!).inHours;
      if (elapsed < kInjectCooldownHours) return '';
    }

    // 查 ±2h 窗口內的習慣
    final nowMinutes = now.hour * 60 + now.minute;
    final matched = <ClockHabit>[];

    for (final h in data.habits) {
      if (!_inWindow(nowMinutes, h.totalMinutes, kTriggerWindowHours * 60)) {
        continue;
      }

      // 冷卻檢查
      if (h.lastTriggeredAt != null) {
        final cooldown = now.difference(h.lastTriggeredAt!).inHours;
        final isBidaily = h.keywords.any(
          (kw) => kBidailyKeywords.any((bk) => kw.contains(bk)),
        );
        if (!isBidaily && cooldown < kHabitCooldownHours) continue;
        if (isBidaily && cooldown < 6) continue; // 早晚至少隔 6h
      }

      matched.add(h);
    }

    if (matched.isEmpty) return '';

    // 取最接近當前時間的那條
    matched.sort((a, b) {
      final dA = _minuteDistance(nowMinutes, a.totalMinutes);
      final dB = _minuteDistance(nowMinutes, b.totalMinutes);
      return dA.compareTo(dB);
    });
    final pick = matched.first;

    // 更新觸發時間
    pick.lastTriggeredAt = now;
    data.lastInjectAt = now;
    await _save(characterId, data);

    final pickTime =
        '${pick.hour.toString().padLeft(2, '0')}:${pick.minute.toString().padLeft(2, '0')}';
    return '${L.pick(en: '【Bio Clock Reminder】You have a habit around ', zhTW: '【生物鐘提醒】你在 ')}$pickTime${L.pick(en: ': ', zhTW: ' 左右有習慣：')}${pick.content}${L.pick(en: ' (This is the habit time, not the current time; follow 【Time】 for the current time.)', zhTW: '（這是習慣時間，不是現在的時間，以【時間】為準）')}';
  }

  /// 時間窗口判定（處理跨午夜）
  static bool _inWindow(int nowMin, int targetMin, int windowMin) {
    final diff = (nowMin - targetMin).abs();
    return diff <= windowMin || (1440 - diff) <= windowMin;
  }

  /// 分鐘距離（跨午夜安全）
  static int _minuteDistance(int a, int b) {
    final diff = (a - b).abs();
    return diff < 720 ? diff : 1440 - diff;
  }

  // ─────────────────────────────────────────────
  // D. 校準（頻率遞減）
  // ─────────────────────────────────────────────

  /// 檢查是否該發校準 prompt。返回校準文本或空字串。
  /// 有副作用：更新 lastCalibrateAt。
  static Future<String> calibratePrompt(String characterId) async {
    final data = await _load(characterId);
    if (data.habits.isEmpty && data.firstClockAt == null) return '';

    final now = DateTime.now();

    // 首次寫入前不校準
    if (data.firstClockAt == null) return '';

    // 計算角色年齡（天）和校準間隔
    final ageDays = now.difference(data.firstClockAt!).inDays;
    int interval = 15; // 預設最長
    for (final (threshold, days) in _calibrateSchedule) {
      if (threshold < 0 || ageDays < threshold) {
        interval = days;
        break;
      }
    }

    // 是否到期
    if (data.lastCalibrateAt != null) {
      final sinceLast = now.difference(data.lastCalibrateAt!).inDays;
      if (sinceLast < interval) return '';
    }

    // 組裝校準 prompt
    final buf = StringBuffer();
    buf.writeln(
      L.pick(
        en: '【Bio Clock Calibration】These are your current routines. Use a tag only if you want to adjust one; otherwise leave them unchanged:',
        zhTW: '【生物鐘校準】以下是你目前的作息習慣，如有想調整的用標籤回覆，沒有就不用動：',
      ),
    );
    for (int i = 0; i < data.habits.length; i++) {
      final h = data.habits[i];
      final timeStr =
          '${h.hour.toString().padLeft(2, '0')}:${h.minute.toString().padLeft(2, '0')}';
      buf.writeln('${_circledNum(i + 1)} $timeStr ${h.content}');
    }
    buf.writeln(
      L.pick(
        en: 'Format: <clock_update>${_circledNum(1)}|HH:MM new content @keywords</clock_update> or <clock_del>${_circledNum(1)}</clock_del>, or add <clock>HH:MM content @keywords</clock>.',
        zhTW:
            '格式：<clock_update>${_circledNum(1)}|HH:MM 新內容 @關鍵詞</clock_update> 或 <clock_del>${_circledNum(1)}</clock_del> 或新增 <clock>HH:MM 內容 @關鍵詞</clock>',
      ),
    );
    buf.writeln(
      L.pick(
        en: 'Change only what you genuinely think should change; no update is required.',
        zhTW: '只改你真的覺得該改的，不需要每次都動。',
      ),
    );
    buf.write(
      L.pick(
        en: 'Put tags directly at the end of the reply. Do not discuss or plan routine adjustments in the thought process.',
        zhTW: '標籤直接打在回覆末尾，不要在思考過程中討論或規劃習慣的調整。',
      ),
    );

    // 更新校準時間
    data.lastCalibrateAt = now;
    await _save(characterId, data);

    return buf.toString();
  }

  /// 去重提問 prompt（pendingDedup 非空時注入）
  static Future<String> dedupPrompt(String characterId) async {
    final data = await _load(characterId);
    if (data.pendingDedup.isEmpty) return '';

    final d = data.pendingDedup.first;
    final existing = data.habits.where((h) => h.id == d.existingId).firstOrNull;
    if (existing == null) {
      // 已被清理，跳過
      data.pendingDedup.removeAt(0);
      await _save(characterId, data);
      return '';
    }

    final tA =
        '${existing.hour.toString().padLeft(2, '0')}:${existing.minute.toString().padLeft(2, '0')}';
    final tB =
        '${d.newHabit.hour.toString().padLeft(2, '0')}:${d.newHabit.minute.toString().padLeft(2, '0')}';

    final header = L.pick(
      en: '【Bio Clock Cleanup】You recorded duplicate routines:',
      zhTW: '【生物鐘整理】你記錄了以下重複的習慣：',
    );
    final instruction = L.pick(
      en: 'Use <clock_keep>①</clock_keep> or <clock_keep>②</clock_keep> to choose which one to keep; the other will be removed.\nPut the tag directly at the end of the reply and do not discuss it in the thought process.',
      zhTW:
          '請用 <clock_keep>①</clock_keep> 或 <clock_keep>②</clock_keep> 選擇保留哪一條，另一條會被移除。\n標籤直接打在回覆末尾，不要在思考過程中討論。',
    );
    return '$header\n① $tA ${existing.content}\n② $tB ${d.newHabit.content}\n$instruction';
  }

  static String _circledNum(int n) {
    const nums = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    return n > 0 && n <= nums.length ? nums[n - 1] : '($n)';
  }

  // ─────────────────────────────────────────────
  // E. 標籤處理（processReply）
  // ─────────────────────────────────────────────

  static final _clockRe = RegExp(r'<clock>([\s\S]*?)</clock>', multiLine: true);
  static final _clockKeepRe = RegExp(
    r'<clock_keep>([\s\S]*?)</clock_keep>',
    multiLine: true,
  );
  static final _clockUpdateRe = RegExp(
    r'<clock_update\b[^>]*>([\s\S]*?)</clock_update>',
    multiLine: true,
  );
  static final _clockDelRe = RegExp(
    r'<clock_del>([\s\S]*?)</clock_del>',
    multiLine: true,
  );
  static final _toolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*?</tool_calls?>',
    multiLine: true,
    caseSensitive: false,
  );

  /// 本輪處理日誌
  static final List<String> lastActionLog = <String>[];

  /// 處理回覆中的 clock 標籤。返回剝離後的文本。
  static Future<String> processReply(
    String text, {
    required String characterId,
  }) async {
    lastActionLog.clear();
    if (!text.contains('<clock') &&
        !text.contains('<clock_keep>') &&
        !text.toLowerCase().contains('<tool_call')) {
      return text;
    }
    var out = text;

    // <clock>HH:MM 內容 @關鍵詞</clock> → 寫入新習慣
    for (final m in _clockRe.allMatches(text)) {
      final raw = m.group(1)!.trim();
      final parsed = _parseClockTag(raw);
      if (parsed == null) continue;
      final ok = await addHabit(
        characterId,
        hour: parsed.hour,
        minute: parsed.minute,
        content: parsed.content,
        keywords: parsed.keywords,
      );
      if (ok) {
        lastActionLog.add(
          '🕐 記錄習慣 ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')} ${parsed.content}',
        );
      }
    }
    out = out.replaceAll(_clockRe, '');

    // <clock_keep>①</clock_keep> → 去重選擇
    for (final m in _clockKeepRe.allMatches(text)) {
      final choice = m.group(1)!.trim();
      final data = await _load(characterId);
      if (data.pendingDedup.isEmpty) continue;

      final d = data.pendingDedup.first;
      final keepId = choice.contains('①') ? d.existingId : d.newHabit.id;
      await resolveDedup(characterId, keepId);
      lastActionLog.add('🕐 去重保留 #$keepId');
    }
    out = out.replaceAll(_clockKeepRe, '');

    // <clock_update>①|HH:MM 新內容 @關鍵詞</clock_update> → 校準更新
    for (final m in _clockUpdateRe.allMatches(text)) {
      final raw = m.group(1)!.trim();
      final pipeIdx = raw.indexOf('|');
      if (pipeIdx < 0) continue;

      final idxStr = raw.substring(0, pipeIdx).trim();
      final idx = _parseCircledIdx(idxStr);
      if (idx == null) continue;

      final newContent = raw.substring(pipeIdx + 1).trim();
      final parsed = _parseClockTag(newContent);
      if (parsed == null) continue;

      final data = await _load(characterId);
      if (idx < 0 || idx >= data.habits.length) continue;
      final old = data.habits[idx];
      data.habits[idx] = ClockHabit(
        id: old.id,
        hour: parsed.hour,
        minute: parsed.minute,
        content: parsed.content,
        keywords: parsed.keywords,
        createdAt: old.createdAt,
        lastTriggeredAt: old.lastTriggeredAt,
      );
      await _save(characterId, data);
      lastActionLog.add('🕐 更新習慣 ${_circledNum(idx + 1)} → ${parsed.content}');
    }
    out = out.replaceAll(_clockUpdateRe, '');

    // <clock_del>①</clock_del> → 校準刪除
    for (final m in _clockDelRe.allMatches(text)) {
      final idxStr = m.group(1)!.trim();
      final idx = _parseCircledIdx(idxStr);
      if (idx == null) continue;

      final data = await _load(characterId);
      if (idx < 0 || idx >= data.habits.length) continue;
      final removed = data.habits.removeAt(idx);
      await _save(characterId, data);
      lastActionLog.add('🕐 刪除習慣 ${removed.content}');
    }
    out = out.replaceAll(_clockDelRe, '');

    for (final m in _toolCallsRe.allMatches(text)) {
      await _processToolCallBlock(characterId, m.group(0)!);
    }
    out = out.replaceAll(_toolCallsRe, '');

    return out.trim();
  }

  /// 解析 `<clock>` 標籤內容：HH:MM 內容 @關鍵詞1,關鍵詞2
  static _ClockParsed? _parseClockTag(String raw) {
    // 格式：20:00 洗澡 @洗澡,浴室
    final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})\s+').firstMatch(raw);
    if (timeMatch == null) return null;

    final hour = int.tryParse(timeMatch.group(1)!);
    final minute = int.tryParse(timeMatch.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    final rest = raw.substring(timeMatch.end);
    final atIdx = rest.indexOf('@');
    String content;
    List<String> keywords;

    if (atIdx >= 0) {
      content = rest.substring(0, atIdx).trim();
      keywords = rest
          .substring(atIdx + 1)
          .split(RegExp(r'[,，]'))
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toList();
    } else {
      content = rest.trim();
      // 沒有 @，用內容本身做關鍵詞
      keywords = [content];
    }

    if (content.isEmpty) return null;
    return _ClockParsed(
      hour: hour,
      minute: minute,
      content: content,
      keywords: keywords,
    );
  }

  static Future<void> _processToolCallBlock(
    String characterId,
    String block,
  ) async {
    final nameMatch = RegExp(
      r'''name\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(block);
    final name = nameMatch?.group(1)?.trim().toLowerCase();
    if (name == null) return;

    String? param(String key) {
      final m = RegExp(
        '<parameter\\s+name\\s*=\\s*["\\\']$key["\\\']\\s*>([\\s\\S]*?)</parameter>',
        caseSensitive: false,
      ).firstMatch(block);
      return m?.group(1)?.trim();
    }

    if (name == 'clock') {
      final time = param('time') ?? param('at') ?? '';
      final content = param('content') ?? param('activity') ?? '';
      final keywordsRaw = param('keywords') ?? param('keyword') ?? content;
      final parsed = _parseClockTag(
        '${time.trim()} ${content.trim()} @${keywordsRaw.trim()}',
      );
      if (parsed == null) return;
      final ok = await addHabit(
        characterId,
        hour: parsed.hour,
        minute: parsed.minute,
        content: parsed.content,
        keywords: parsed.keywords,
      );
      if (ok) {
        lastActionLog.add(
          '🕐 記錄習慣 ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')} ${parsed.content}',
        );
      }
      return;
    }

    if (name == 'clock_keep') {
      final choice = param('choice') ?? param('keep') ?? '';
      final data = await _load(characterId);
      if (data.pendingDedup.isEmpty) return;
      final d = data.pendingDedup.first;
      final keepId = choice.contains('①') || choice == '1'
          ? d.existingId
          : d.newHabit.id;
      await resolveDedup(characterId, keepId);
      lastActionLog.add('🕐 去重保留 #$keepId');
      return;
    }

    if (name == 'clock_update') {
      final idx = _parseCircledIdx(param('index') ?? param('id') ?? '');
      final time = param('time') ?? '';
      final content = param('content') ?? '';
      final keywordsRaw = param('keywords') ?? param('keyword') ?? content;
      final parsed = _parseClockTag('$time $content @$keywordsRaw');
      if (idx == null || parsed == null) return;
      final data = await _load(characterId);
      // 圈號顯示的是 habit.id（habitListPrompt 用 _circledNum(h.id)），
      // 不是列表位置——刪過習慣後 id 與下標錯位，按位置改會改錯條。
      // 一律按 durable id 反查；查不到＝已刪或模型亂編，丟棄。
      final habitId = idx + 1;
      final pos = data.habits.indexWhere((h) => h.id == habitId);
      if (pos == -1) return;
      final old = data.habits[pos];
      data.habits[pos] = ClockHabit(
        id: old.id,
        hour: parsed.hour,
        minute: parsed.minute,
        content: parsed.content,
        keywords: parsed.keywords,
        createdAt: old.createdAt,
        lastTriggeredAt: old.lastTriggeredAt,
      );
      await _save(characterId, data);
      lastActionLog.add('🕐 更新習慣 ${_circledNum(habitId)} → ${parsed.content}');
      return;
    }

    if (name == 'clock_del') {
      final idx = _parseCircledIdx(param('index') ?? param('id') ?? '');
      if (idx == null) return;
      final data = await _load(characterId);
      // 同 clock_update：圈號=durable id，按 id 刪
      final habitId = idx + 1;
      final pos = data.habits.indexWhere((h) => h.id == habitId);
      if (pos == -1) return;
      final removed = data.habits.removeAt(pos);
      await _save(characterId, data);
      lastActionLog.add('🕐 刪除習慣 ${removed.content}');
    }
  }

  /// 解析圈號 ①②③... → 0-based index
  static int? _parseCircledIdx(String s) {
    const map = {
      '①': 0,
      '②': 1,
      '③': 2,
      '④': 3,
      '⑤': 4,
      '⑥': 5,
      '⑦': 6,
      '⑧': 7,
      '⑨': 8,
      '⑩': 9,
    };
    if (map.containsKey(s)) return map[s];
    // fallback: 純數字，或 _circledNum 對 id>10 產生的 "(n)" 括號格式
    // （id 單調遞增不重用，刪 N 條加 N 條後 id 會超過 10）
    final cleaned = s.replaceAll(RegExp(r'[()（）\s]'), '');
    final n = int.tryParse(cleaned);
    return n != null ? n - 1 : null;
  }

  // ─────────────────────────────────────────────
  // F. Ability Prompt
  // ─────────────────────────────────────────────

  /// 教模型使用 `<clock>` 標籤（工具清單式）
  static String abilityPrompt() {
    if (L.locale == 'en') {
      return '''■ Bio Clock
  <clock>HH:MM activity @keyword1,keyword2</clock>
  Record stable routines when they naturally appear: sleep, meals, shower, work, commute, exercise, medicine, recurring care.
  Put tags at the very end. Tags are invisible; never explain them in the normal reply. Up to 10 habits.''';
    }
    return L.pick(
      en: '',
      zhTW: '''■ 生物鐘
  <clock>HH:MM 活動內容 @關鍵詞1,關鍵詞2</clock>
  自然出現穩定作息時記錄：睡覺、吃飯、洗澡、工作、通勤、運動、吃藥、固定照顧等。
  標籤放在回覆末尾，對 user 不可見；正文不要解釋你在記錄。上限 10 條。''',
    );
  }

  // ─────────────────────────────────────────────
  // G. 疲勞追蹤（作息偏差 → 健康影響）
  // ─────────────────────────────────────────────

  /// 疲勞等級閾值
  static const int kFatigueWindowDays = 7;
  static const int kFatigueMinBadDays = 3;
  static const Duration kFatigueDeviationThreshold = Duration(hours: 2);
  static const List<double> kFatigueProbability = [0.10, 0.15, 0.20]; // 低/中/高

  /// 記錄當天最後對話時間（每輪結束後調用）
  static Future<void> recordLastChatTime(String characterId) async {
    final now = DateTime.now();
    final dateKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final prefs = await SharedPreferences.getInstance();
    final key = 'fatigue_log_$characterId';
    final raw = prefs.getString(key) ?? '{}';
    final fatigue = Map<String, String>.from(
      (Map<String, dynamic>.from(
        const JsonDecoder().convert(raw) as Map? ?? {},
      )),
    );
    fatigue[dateKey] = now.toIso8601String();

    // 只保留最近 14 天
    final cutoff = now.subtract(const Duration(days: 14));
    fatigue.removeWhere((k, v) {
      try {
        return DateTime.parse(v).isBefore(cutoff);
      } catch (_) {
        return true;
      }
    });

    await prefs.setString(key, const JsonEncoder().convert(fatigue));
  }

  /// 計算疲勞等級（0=正常, 1=低, 2=中, 3=高），根據作息偏差
  static Future<int> fatigueLevel(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'fatigue_log_$characterId';
    final raw = prefs.getString(key) ?? '{}';
    final fatigue = Map<String, String>.from(
      (Map<String, dynamic>.from(
        const JsonDecoder().convert(raw) as Map? ?? {},
      )),
    );

    final data = await _load(characterId);
    // 找到睡覺習慣
    final sleepHabit = data.habits
        .where(
          (h) => h.keywords.any((k) => k.contains('睡') || k.contains('sleep')),
        )
        .toList();
    if (sleepHabit.isEmpty) return 0; // 沒有睡眠習慣就不算

    final habitTime = sleepHabit.first;
    final habitMinutes = habitTime.hour * 60 + habitTime.minute;

    // 統計最近 7 天有多少天超過習慣時間 2 小時+
    int badDays = 0;
    final now = DateTime.now();
    for (int i = 0; i < kFatigueWindowDays; i++) {
      final date = now.subtract(Duration(days: i));
      final dateKey =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final lastChat = fatigue[dateKey];
      if (lastChat == null) continue;

      try {
        final chatTime = DateTime.parse(lastChat);
        var chatMinutes = chatTime.hour * 60 + chatTime.minute;
        // 處理跨午夜：如果習慣 23:00 但聊到 01:00，chatMinutes 是 60
        if (chatMinutes < habitMinutes - 720) chatMinutes += 1440;
        final deviation = chatMinutes - habitMinutes;
        if (deviation > kFatigueDeviationThreshold.inMinutes) badDays++;
      } catch (_) {}
    }

    if (badDays >= 5) return 3; // 高
    if (badDays >= 4) return 2; // 中
    if (badDays >= kFatigueMinBadDays) return 1; // 低
    return 0;
  }

  /// 疲勞提示（注入用，空字串 = 不注入）
  static Future<String> fatiguePrompt(String characterId) async {
    final level = await fatigueLevel(characterId);
    if (level == 0) return '';

    // 概率判斷
    final prob = kFatigueProbability[(level - 1).clamp(0, 2)];
    final roll = DateTime.now().microsecond / 1000000.0;
    if (roll > prob) return '';

    if (L.locale == 'en') {
      const msgs = [
        '【Body】You haven\'t been sleeping well lately, feeling a bit tired.',
        '【Body】Several days of poor sleep, your head feels heavy.',
        '【Body】Your body is protesting — you feel a slight fever coming on.',
      ];
      return msgs[(level - 1).clamp(0, 2)];
    }
    const msgs = [
      '【身體】你最近睡得不太好，有點累。',
      '【身體】連續好幾天沒睡好，頭有點沉。',
      '【身體】身體在抗議了，你覺得有點發燒。',
    ];
    return L.pick(en: '', zhTW: msgs[(level - 1).clamp(0, 2)]);
  }

  // ─────────────────────────────────────────────
  // H. 前 7 天生物鐘構建提示
  // ─────────────────────────────────────────────

  /// 生物鐘構建期提示（角色建立後前 7 天，每天第一輪對話發送）
  /// 返回空字串表示不在構建期或本時段不需要提示
  static Future<String> setupPrompt(String characterId) async {
    final data = await _load(characterId);
    if (data.habits.length >= 3) return ''; // 已有 3+ 習慣，不再提示

    // 用第一條習慣的時間判斷是否超過 7 天
    if (data.firstClockAt != null &&
        DateTime.now().difference(data.firstClockAt!).inDays > 7) {
      return ''; // 超過 7 天不再提示
    }

    final now = DateTime.now();
    final hour = now.hour;

    if (L.locale == 'en') {
      if (hour >= 6 && hour < 9) {
        return '【Bio Clock Setup】Good morning! What time do you usually have breakfast? Record with <clock> if you want.';
      } else if (hour >= 11 && hour < 13) {
        return '【Bio Clock Setup】It\'s lunchtime. Hungry? Eating or skipping is fine.';
      } else if (hour >= 17 && hour < 19) {
        return '【Bio Clock Setup】Around dinner time. Do you usually eat around now?';
      } else if (hour >= 22 || hour < 2) {
        return '【Bio Clock Setup】Getting late. What time do you usually sleep?';
      }
      return '【Bio Clock Setup】If this conversation naturally reveals a stable routine, record it silently with <clock>HH:MM activity @keywords</clock>. Do not mention the tag.';
    }

    if (hour >= 6 && hour < 9) {
      return L.pick(en: '', zhTW: '【生物鐘構建】早安，平常幾點吃早餐？想記的話用 <clock> 記下來。');
    } else if (hour >= 11 && hour < 13) {
      return L.pick(en: '', zhTW: '【生物鐘構建】飯點了，肚子有些餓嗎？吃不吃都行。');
    } else if (hour >= 17 && hour < 19) {
      return L.pick(en: '', zhTW: '【生物鐘構建】快到晚餐時間了，平常這時候吃嗎？');
    } else if (hour >= 22 || hour < 2) {
      return L.pick(en: '', zhTW: '【生物鐘構建】晚了，記得休息。幾點想睡？');
    }
    return L.pick(
      en: '',
      zhTW:
          '【生物鐘構建】如果這輪自然出現固定作息線索，請在回覆末尾用 <clock>HH:MM 活動內容 @關鍵詞</clock> 靜默記錄；正文不要說你在記錄。',
    );
  }

  // ─────────────────────────────────────────────
  // 工具：導出
  // ─────────────────────────────────────────────

  /// 導出完整數據（研究用）
  static Future<String> exportJson(String characterId) async {
    final data = await _load(characterId);
    return const JsonEncoder.withIndent('  ').convert(data.toJson());
  }
}

/// 內部解析結果
class _ClockParsed {
  final int hour;
  final int minute;
  final String content;
  final List<String> keywords;

  _ClockParsed({
    required this.hour,
    required this.minute,
    required this.content,
    required this.keywords,
  });
}
