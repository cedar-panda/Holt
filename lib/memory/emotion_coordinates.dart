import 'dart:convert';
import 'dart:math';
import '../services/locale_strings.dart';

import 'database.dart';

/// ═══════════════════════════════════════════════════════════════
/// 情緒座標系統 V2
/// ═══════════════════════════════════════════════════════════════
///
/// V1 → V2 核心變更：
///   維度：9核心+8動態 → 5常駐（安全感/慾望/愜意/負面情緒/戲謔），全跨窗口
///   持久門檻：90 → 85
///   長期進度條：安全感+負面情緒 用 7 天滑動均值（不是單次打點直接拉）
///   交互衰減：安全感 ↔ 負面情緒 雙向影響
///   慾望：每開新窗口 ÷2
///   翻舊帳：grudge_sealed 機制——
///     同輪負面情緒 ≥70 且有具體事件記憶 → 自動掛 grudge_sealed
///     負面情緒 bar 30/60/90 三檔概率 roll（15%/45%/80%）
///     roll 到 → 注入記憶+情緒提示，說不說由模型自己判斷
///     6h 冷卻，不給 100%——真人也有氣到頂了但就是不說的時候
///
/// 保留：circumplex 平面、混亂計算（數據仍有用）
///
/// ## 座標約定（同 V1）
///   x = 效價 valence：-100 ~ +100（不愉快 → 愉快）
///   y = 喚醒 arousal：-100 ~ +100（平靜 → 激動）
///
/// ## 衰減規則（V2）
///   < 10 → 自然消散
///   10~84 → 標準衰減（濃度高掉慢）
///   ≥ 85 → 不自然衰減，需事件消解
///   慾望特殊：每開新窗口先 ÷2；窗口內 90min 線性歸零
///
/// ## 交互衰減
///   安全感 > 60 → 負面衰減加速 ×1.3
///   安全感 < 30 → 負面衰減減速 ×0.7
///   負面 > 70 持續 48h → 安全感每 tick -2
///   負面 < 20 → 安全感每 tick +1
///
/// ## 測量與後果分離（同 V1，重要）
///   門檻規則只存在於本地，模型不知道分數的系統後果。
/// ═══════════════════════════════════════════════════════════════

/// V2 五個常駐維度（全跨窗口）
const kV2Dimensions = <String>['安全感', '慾望', '愜意', '負面情緒', '戲謔'];

/// 長期進度條維度（用 7 天滑動均值，不是當前最高濃度）
const kLongTermDimensions = <String>['安全感', '負面情緒'];

/// 單個情緒點（同 V1 結構，保持向後相容）
String _normalizeEnDimension(String raw) {
  final lower = raw.trim().toLowerCase();
  switch (lower) {
    case 'security':
      return '安全感';
    case 'desire':
    case '欲望':
      return '慾望';
    case 'comfort':
    case '惬意':
      return '愜意';
    case 'negative':
    case 'negative emotion':
    case 'negativeemotion':
    case '负面情绪':
      return '負面情緒';
    case 'banter':
    case '戏谑':
      return '戲謔';
    default:
      return raw.trim();
  }
}

class EmotionPoint {
  final int? id;
  final String characterId;

  /// 維度名（五維之一；模型也可打自由標籤，自由標籤不入進度條）
  final String type;

  /// 效價 -100 ~ +100
  final double x;

  /// 喚醒 -100 ~ +100
  final double y;

  /// 濃度 0~100
  final double concentration;

  /// 綁定的記憶 id（可空）
  final int? memoryId;

  /// 模型打點時的隨手備註
  final String note;

  /// active | dissipated | resolved
  final String status;

  /// V1 遺留：持久確認。V2 不再需要——≥85 直接持久，不需二次印證
  final int confirmed;

  final DateTime createdAt;
  final DateTime updatedAt;

  EmotionPoint({
    this.id,
    required this.characterId,
    required this.type,
    required this.x,
    required this.y,
    required this.concentration,
    this.memoryId,
    this.note = '',
    this.status = 'active',
    this.confirmed = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'character_id': characterId,
    'type': type,
    'x': x,
    'y': y,
    'concentration': concentration,
    'memory_id': memoryId,
    'note': note,
    'status': status,
    'confirmed': confirmed,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  static EmotionPoint fromMap(Map<String, dynamic> m) => EmotionPoint(
    id: m['id'] as int?,
    characterId: m['character_id'] as String,
    type: _normalizeEnDimension(m['type'] as String),
    x: (m['x'] as num).toDouble(),
    y: (m['y'] as num).toDouble(),
    concentration: (m['concentration'] as num).toDouble(),
    memoryId: m['memory_id'] as int?,
    note: m['note'] as String? ?? '',
    status: m['status'] as String? ?? 'active',
    confirmed: m['confirmed'] as int? ?? 0,
    createdAt: DateTime.parse(m['created_at'] as String),
    updatedAt: DateTime.parse(m['updated_at'] as String),
  );
}

class EmotionCoordinates {
  // ─────────────────────────────────────────────
  // 可調參數
  // ─────────────────────────────────────────────

  /// 自然消散線
  static const double kDissipateBelow = 10;

  /// 持久門檻（V2：85，V1 was 90）：濃度達此值不自然衰減
  static const double kPersistThreshold = 85;

  /// 進度條門檻：非長期維度用（長期維度用滑動均值）
  static const double kBarThreshold = 60;

  /// 混亂計算窗口（小時）
  static const int kChaosWindowHours = 24;

  /// 混亂值權重
  static const double kChaosSpreadWeight = 0.5;
  static const double kChaosDispersionWeight = 0.5;

  /// 同型併點窗口（小時）
  static const int kMergeWindowHours = 6;

  /// 慾望完全消退時長（分鐘）
  static const double kDesireFadeMinutes = 90;

  /// 長期進度條滑動窗口（天）
  static const int kSlidingWindowDays = 7;

  // ── 交互衰減 ──

  /// 安全感高於此值 → 負面衰減加速
  static const double kSafetyHighLine = 60;

  /// 安全感低於此值 → 負面衰減減速
  static const double kSafetyLowLine = 30;

  /// 負面情緒持續高於此值超過 48h → 安全感 tick -2
  static const double kNegativeSustainedLine = 70;

  /// 負面情緒低於此值 → 安全感 tick +1
  static const double kNegativeLowLine = 20;

  /// 持續判定窗口（小時）
  static const int kSustainedHours = 48;

  // ── 安全感閒置衰減 ──
  // 安全感不走標準衰減：聊天活躍期只受負面情緒侵蝕/回暖；
  // 「長時間不聊天」本身才是它的衰減事件——
  // 1 天不聊沒事，滿 48 小時開始緩慢下降（≥85 也不豁免）。

  /// 閒置寬限（小時）：超過才開始掉
  static const int kSafetyIdleGraceHours = 48;

  /// 閒置衰減速度（每天）
  static const double kSafetyIdleDecayPerDay = 2.0;

  /// 負面侵蝕/回暖調整的最小間隔——
  /// 舊版每條消息都調一次還重置衰減時鐘，快聊時掉得跟打字速度掛鉤
  static const Duration kSafetyAdjCooldown = Duration(hours: 1);

  /// 戲謔→愜意聯動 tick 的最小間隔（舊版按消息條數觸發，刷屏即刷滿）
  static const Duration kComfortLinkCooldown = Duration(hours: 1);

  /// 各安全感點上次被負面調整的時間（內存級，重啟歸零無傷）
  static final Map<int, DateTime> _lastSafetyAdjAt = {};

  /// 各角色上次觸發戲謔→愜意聯動的時間
  static final Map<String, DateTime> _lastComfortLinkAt = {};

  // ── 翻舊帳 ──

  /// grudge_sealed 寫入門檻：同輪負面情緒濃度 ≥ 此值
  static const double kGrudgeSealThreshold = 70;

  /// 概率 roll 三檔：(bar_level, probability)
  /// 30 → 15%，60 → 45%，90 → 80%
  /// 低於 30 不觸發，不給 100%
  static const double kGrudgeTriggerLow = 30;
  static const double kGrudgeTriggerMid = 60;
  static const double kGrudgeTriggerHigh = 90;
  static const double kGrudgeProbLow = 0.15;
  static const double kGrudgeProbMid = 0.45;
  static const double kGrudgeProbHigh = 0.80;

  /// 翻舊帳冷卻（小時）
  static const int kGrudgeCooldownHours = 6;

  /// 翻舊帳最多拉幾筆
  static const int kGrudgeMaxItems = 3;

  // ── 維度上限 ──

  /// 慾望上限（不是 100，壓到 80）
  static const double kDesireCap = 80;

  /// 依戀上限（動態標籤，上限 50）
  static const double kAttachmentCap = 50;

  /// 維度上限表（不在表裡的 = 默認 100）
  static const kDimensionCaps = <String, double>{
    '慾望': kDesireCap,
    '依戀': kAttachmentCap,
    '戲謔': 60,
  };

  // ─────────────────────────────────────────────
  // 衰減策略
  // ─────────────────────────────────────────────

  /// 刷新間隔（天）：濃度 10 → 1 天；濃度 84 → 約 3 天，線性
  static double _refreshIntervalDays(double c) {
    final t = ((c - kDissipateBelow) / (kPersistThreshold - kDissipateBelow))
        .clamp(0.0, 1.0);
    return 1 + 2 * t;
  }

  /// 單次衰減量：濃度越高掉得越少
  /// 濃度 10 → -12；濃度 84 → -4
  static double _decayStep(double c) {
    final t = ((c - kDissipateBelow) / (kPersistThreshold - kDissipateBelow))
        .clamp(0.0, 1.0);
    return 12 - 8 * t;
  }

  // ─────────────────────────────────────────────
  // 存儲
  // ─────────────────────────────────────────────

  static bool _tableEnsured = false;

  static Future<void> _ensureTable() async {
    if (_tableEnsured) return;
    final db = await DatabaseHelper.database;

    // 情緒點表（同 V1）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS emotion_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        type TEXT NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        concentration REAL NOT NULL,
        memory_id INTEGER,
        note TEXT DEFAULT '',
        status TEXT DEFAULT 'active',
        confirmed INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_emo_char '
      'ON emotion_points(character_id, status)',
    );

    // V2 新增：grudge_sealed 表（不動主 memories schema）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS grudge_seals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id TEXT NOT NULL,
        memory_id INTEGER NOT NULL,
        negative_concentration REAL NOT NULL,
        event_summary TEXT DEFAULT '',
        sealed_at TEXT NOT NULL,
        surfaced_at TEXT,
        UNIQUE(character_id, memory_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_grudge_char '
      'ON grudge_seals(character_id)',
    );

    _tableEnsured = true;
  }

  // ── 交叉影響常數 ──

  /// 愜意高於此值 → 戲謔打點 ×1.2
  static const double kComfortBoostLine = 50;
  static const double kPlayfulBoostMult = 1.2;

  /// 負面高於此值 → 慾望上限從 80 壓到 50
  static const double kNegativeSuppressLine = 50;
  static const double kDesireSuppressedCap = 50;

  /// 戲謔高於此值 → 每 tick 愜意 +1
  static const double kPlayfulComfortLine = 40;

  /// 戲謔 tick 推愜意的上限（低於 kComfortBoostLine，斷開正反饋環）
  static const double kComfortTickCap = 45;

  // ─────────────────────────────────────────────
  // 打點
  // ─────────────────────────────────────────────

  /// 打一個點。同型併點邏輯同 V1。
  /// 含交叉影響：愜意高→戲謔放大、負面高→慾望壓制。
  static Future<int> addPoint(EmotionPoint p) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;

    // ═══ 交叉影響：動態調整 cap 和濃度 ═══
    var cap = kDimensionCaps[p.type] ?? 100.0;
    var adjustedConc = p.concentration;

    if (p.type == '戲謔') {
      // 愜意高 → 戲謔打點 ×1.2
      final comfortAvg = await slidingAverage(
        p.characterId,
        '愜意',
        const Duration(days: kSlidingWindowDays),
      );
      if (comfortAvg > kComfortBoostLine) {
        adjustedConc = (adjustedConc * kPlayfulBoostMult);
      }
    } else if (p.type == '慾望') {
      // 負面高 → 慾望上限壓到 50
      final negAvg = await slidingAverage(
        p.characterId,
        '負面情緒',
        const Duration(days: kSlidingWindowDays),
      );
      if (negAvg > kNegativeSuppressLine) {
        cap = kDesireSuppressedCap;
      }
    }

    final clampedConc = adjustedConc.clamp(0.0, cap);

    final cutoff = DateTime.now()
        .subtract(const Duration(hours: kMergeWindowHours))
        .toIso8601String();
    final rows = await db.query(
      'emotion_points',
      where:
          "character_id = ? AND type = ? AND status = 'active' "
          'AND created_at > ?',
      whereArgs: [p.characterId, p.type, cutoff],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final old = EmotionPoint.fromMap(rows.first);
      final wOld = old.concentration;
      final wNew = clampedConc;
      final wSum = (wOld + wNew) == 0 ? 1.0 : (wOld + wNew);
      final mergedConc = (wNew > wOld ? wNew : wOld).clamp(0.0, cap);
      await db.update(
        'emotion_points',
        {
          'x': (old.x * wOld + p.x * wNew) / wSum,
          'y': (old.y * wOld + p.y * wNew) / wSum,
          'concentration': mergedConc,
          'note': p.note.isNotEmpty ? p.note : old.note,
          if (p.memoryId != null) 'memory_id': p.memoryId,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [old.id],
      );
      return old.id!;
    }

    // 新點也用 clamp 後的濃度
    final clampedMap = p.toMap();
    clampedMap['concentration'] = clampedConc;
    return db.insert('emotion_points', clampedMap);
  }

  /// 當前 active 的點
  static Future<List<EmotionPoint>> activePoints(
    String characterId, {
    String? type,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'emotion_points',
      where: type == null
          ? "character_id = ? AND status = 'active'"
          : "character_id = ? AND status = 'active' AND type = ?",
      whereArgs: type == null ? [characterId] : [characterId, type],
      orderBy: 'created_at DESC',
    );
    return rows.map(EmotionPoint.fromMap).toList();
  }

  /// 事件消解：模型判定「真的過了」時調用
  static Future<void> resolvePoint(int id) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    await db.update(
      'emotion_points',
      {'status': 'resolved', 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ─────────────────────────────────────────────
  // 新窗口：慾望 ÷2
  // ─────────────────────────────────────────────

  /// 開新窗口時調用。將所有 active 慾望點濃度減半，
  /// 低於消散線的直接散。
  static Future<void> onNewWindow(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'emotion_points',
      where: "character_id = ? AND type = '慾望' AND status = 'active'",
      whereArgs: [characterId],
    );
    final now = DateTime.now().toIso8601String();
    for (final row in rows) {
      final id = row['id'] as int;
      final c = (row['concentration'] as num).toDouble();
      final halved = c / 2;
      if (halved < kDissipateBelow) {
        await db.update(
          'emotion_points',
          {'status': 'dissipated', 'concentration': halved, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        await db.update(
          'emotion_points',
          {'concentration': halved, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  // ─────────────────────────────────────────────
  // 滑動均值
  // ─────────────────────────────────────────────

  /// 指定維度在 [window] 內所有點（含已散/已消解）的平均濃度。
  /// 長期進度條的數據來源——7天均值，不是瞬時峰值。
  static Future<double> slidingAverage(
    String characterId,
    String type,
    Duration window,
  ) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final cutoff = DateTime.now().subtract(window).toIso8601String();
    final rows = await db.query(
      'emotion_points',
      columns: ['concentration'],
      where: 'character_id = ? AND type = ? AND created_at > ?',
      whereArgs: [characterId, type, cutoff],
    );
    if (rows.isEmpty) return 0;
    final sum = rows.fold<double>(
      0,
      (s, r) => s + (r['concentration'] as num).toDouble(),
    );
    return sum / rows.length;
  }

  // ─────────────────────────────────────────────
  // 衰減 tick
  // ─────────────────────────────────────────────

  /// V2 衰減 tick，含交互衰減邏輯。
  /// 建議調用時機：發消息前 / App 回前台。
  static Future<int> tickDecay(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final points = await activePoints(characterId);
    final now = DateTime.now();
    int touched = 0;

    // 安全感閒置衰減的錨點：最後一次真的聊過的時間
    final lastChatAt = await DatabaseHelper.getLastMessageTime(characterId);

    // ── 預計算交互衰減參數 ──
    final safetyAvg = await slidingAverage(
      characterId,
      '安全感',
      const Duration(days: kSlidingWindowDays),
    );
    final negativeAvg = await slidingAverage(
      characterId,
      '負面情緒',
      const Duration(days: kSlidingWindowDays),
    );
    final negative48h = await slidingAverage(
      characterId,
      '負面情緒',
      const Duration(hours: kSustainedHours),
    );

    // 交互倍率
    final double negativeDecayMult;
    if (safetyAvg > kSafetyHighLine) {
      negativeDecayMult = 1.3; // 安全感高 → 負面散得快
    } else if (safetyAvg < kSafetyLowLine) {
      negativeDecayMult = 0.7; // 安全感低 → 負面散得慢
    } else {
      negativeDecayMult = 1.0;
    }

    for (final p in points) {
      // ═══ 慾望專屬衰減：90min 線性歸零 ═══
      if (p.type == '慾望') {
        final mins = now.difference(p.updatedAt).inMinutes;
        if (mins <= 0) continue;
        final next = p.concentration - (100 / kDesireFadeMinutes) * mins;
        await db.update(
          'emotion_points',
          next < kDissipateBelow
              ? {
                  'status': 'dissipated',
                  'concentration': next.clamp(0, 100),
                  'updated_at': now.toIso8601String(),
                }
              : {'concentration': next, 'updated_at': now.toIso8601String()},
          where: 'id = ?',
          whereArgs: [p.id],
        );
        touched++;
        continue;
      }

      // ═══ 安全感：不走標準衰減 ═══
      // 活躍期只受負面情緒侵蝕/回暖；「長時間不聊天」才是它的衰減事件——
      // 1 天不聊沒事，滿 48h 開始每天緩掉 kSafetyIdleDecayPerDay。
      // 舊版的問題：微調每條消息觸發一次且順手重置 updated_at，
      // 衰減時鐘永遠到不了期 → 安全感實際上從不自然衰減。
      if (p.type == '安全感') {
        // ── 閒置衰減（≥85 不豁免：一直不來，本身就是事件）──
        if (lastChatAt != null) {
          final idleStart = lastChatAt.add(
            const Duration(hours: kSafetyIdleGraceHours),
          );
          if (now.isAfter(idleStart)) {
            final from = p.updatedAt.isAfter(idleStart)
                ? p.updatedAt
                : idleStart;
            final hours = now.difference(from).inMinutes / 60.0;
            if (hours >= 1) {
              final next =
                  p.concentration - hours / 24.0 * kSafetyIdleDecayPerDay;
              await db.update(
                'emotion_points',
                next < kDissipateBelow
                    ? {
                        'status': 'dissipated',
                        'concentration': next.clamp(0, 100),
                        'updated_at': now.toIso8601String(),
                      }
                    : {
                        'concentration': next,
                        'updated_at': now.toIso8601String(),
                      },
                where: 'id = ?',
                whereArgs: [p.id],
              );
              touched++;
            }
            continue; // 閒置期不疊加其他調整
          }
        }

        // ── 活躍期：負面侵蝕 / 回暖，每點最多一小時一次 ──
        final pid = p.id;
        if (pid == null) continue;
        final lastAdj = _lastSafetyAdjAt[pid];
        if (lastAdj != null && now.difference(lastAdj) < kSafetyAdjCooldown) {
          continue;
        }
        double adj = 0;
        if (negative48h > kNegativeSustainedLine) adj -= 2;
        if (negativeAvg < kNegativeLowLine) adj += 1;
        // ≥85 的持久區只允許被侵蝕，不被 buff 繼續推高
        if (p.concentration >= kPersistThreshold && adj > 0) adj = 0;
        if (adj != 0) {
          final next = (p.concentration + adj).clamp(0.0, 100.0);
          await db.update(
            'emotion_points',
            next < kDissipateBelow
                ? {
                    'status': 'dissipated',
                    'concentration': next,
                    'updated_at': now.toIso8601String(),
                  }
                : {'concentration': next, 'updated_at': now.toIso8601String()},
            where: 'id = ?',
            whereArgs: [pid],
          );
          _lastSafetyAdjAt[pid] = now;
          touched++;
        }
        continue;
      }

      // ═══ ≥85：不自然衰減，只能事件消解 ═══
      if (p.concentration >= kPersistThreshold) {
        continue;
      }

      // ═══ <10：自然消散 ═══
      if (p.concentration < kDissipateBelow) {
        await db.update(
          'emotion_points',
          {'status': 'dissipated', 'updated_at': now.toIso8601String()},
          where: 'id = ?',
          whereArgs: [p.id],
        );
        touched++;
        continue;
      }

      // ═══ 10~84：標準衰減（安全感已在上面獨立分支處理）═══
      final dueDays = _refreshIntervalDays(p.concentration);
      final elapsedDays = now.difference(p.updatedAt).inHours / 24.0;
      if (elapsedDays < dueDays) {
        continue;
      }

      // 到了刷新間隔，計算衰減量
      var step = _decayStep(p.concentration);

      // 交互倍率：負面情緒的衰減受安全感影響
      if (p.type == '負面情緒') {
        step *= negativeDecayMult;
      }

      final next = p.concentration - step;
      await db.update(
        'emotion_points',
        next < kDissipateBelow
            ? {
                'status': 'dissipated',
                'concentration': next.clamp(0, 100),
                'updated_at': now.toIso8601String(),
              }
            : {'concentration': next, 'updated_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: [p.id],
      );
      touched++;
    }

    // ═══ 交叉影響：戲謔高 → 愜意 tick +1，cap 45 ═══
    // 每小時最多一次。舊版按 tickDecay 調用次數觸發（= 每條消息一次），
    // 快聊 45 條就把愜意從 0 刷滿——漲愜意的應該是相處的時間，不是打字速度。
    final lastLink = _lastComfortLinkAt[characterId];
    final comfortLinkReady =
        lastLink == null || now.difference(lastLink) >= kComfortLinkCooldown;
    final playfulPoints = points
        .where((p) => p.type == '戲謔' && p.status == 'active')
        .toList();
    if (comfortLinkReady && playfulPoints.isNotEmpty) {
      final maxPlayful = playfulPoints
          .map((p) => p.concentration)
          .reduce((a, b) => a > b ? a : b);
      if (maxPlayful > kPlayfulComfortLine) {
        // 找愜意的 active 點
        final comfortPoints = points
            .where((p) => p.type == '愜意' && p.status == 'active')
            .toList();
        if (comfortPoints.isNotEmpty) {
          final cp = comfortPoints.first;
          if (cp.concentration < kComfortTickCap) {
            final next = (cp.concentration + 1).clamp(0.0, kComfortTickCap);
            await db.update(
              'emotion_points',
              {'concentration': next, 'updated_at': now.toIso8601String()},
              where: 'id = ?',
              whereArgs: [cp.id],
            );
            _lastComfortLinkAt[characterId] = now;
            touched++;
          }
        } else {
          // 愜意沒有 active 點，創建一個低濃度的
          await db.insert(
            'emotion_points',
            EmotionPoint(
              characterId: characterId,
              type: '愜意',
              x: 40,
              y: -20,
              concentration: 1,
              note: 'tick:戲謔聯動',
            ).toMap(),
          );
          _lastComfortLinkAt[characterId] = now;
          touched++;
        }
      }
    }

    return touched;
  }

  // ─────────────────────────────────────────────
  // 進度條
  // ─────────────────────────────────────────────

  /// V2 進度條：
  /// - 長期維度（安全感、負面情緒）：7 天滑動均值
  /// - 其他維度（慾望、愜意、戲謔）：當前 active 且 ≥ kBarThreshold 的最高濃度
  static Future<Map<String, double>> bars(String characterId) async {
    final result = {for (final d in kV2Dimensions) d: 0.0};

    // 長期維度：滑動均值
    for (final d in kLongTermDimensions) {
      result[d] = await slidingAverage(
        characterId,
        d,
        const Duration(days: kSlidingWindowDays),
      );
    }

    // 瞬時維度：當前最高濃度（≥ barThreshold）
    final points = await activePoints(characterId);
    for (final p in points) {
      if (!result.containsKey(p.type)) continue;
      if (kLongTermDimensions.contains(p.type)) continue; // 長期的已算過
      if (p.concentration < kBarThreshold) continue;
      if (p.concentration > result[p.type]!) {
        result[p.type] = p.concentration;
      }
    }

    return result;
  }

  /// 重置所有情緒座標（全部標記 dissipated）
  static Future<int> resetAll(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final count = await db.update(
      'emotion_points',
      {'status': 'dissipated', 'updated_at': DateTime.now().toIso8601String()},
      where: "character_id = ? AND status = 'active'",
      whereArgs: [characterId],
    );
    return count;
  }

  /// 混亂值 0~1。同 V1 邏輯。
  static double chaos(List<EmotionPoint> points) {
    final pts = points.where((p) => p.status == 'active').toList();
    if (pts.length < 2) return 0;

    const maxDist = 282.84271;
    double sumDist = 0;
    int pairs = 0;
    for (int i = 0; i < pts.length; i++) {
      for (int j = i + 1; j < pts.length; j++) {
        final dx = pts[i].x - pts[j].x;
        final dy = pts[i].y - pts[j].y;
        sumDist += sqrt(dx * dx + dy * dy);
        pairs++;
      }
    }
    final spread = pairs > 0 ? (sumDist / pairs) / maxDist : 0.0;

    double sx = 0, sy = 0, wSum = 0;
    for (final p in pts) {
      final len = sqrt(p.x * p.x + p.y * p.y);
      if (len < 1e-6) continue;
      final w = p.concentration / 100;
      sx += w * (p.x / len);
      sy += w * (p.y / len);
      wSum += w;
    }
    final dispersion = wSum < 1e-6 ? 0.0 : 1 - sqrt(sx * sx + sy * sy) / wSum;

    final value =
        sqrt(spread) * kChaosSpreadWeight + dispersion * kChaosDispersionWeight;
    return value.clamp(0.0, 1.0);
  }

  /// 當前混亂值
  static Future<double> currentChaos(String characterId) async {
    final cutoff = DateTime.now().subtract(
      const Duration(hours: kChaosWindowHours),
    );
    final points = (await activePoints(
      characterId,
    )).where((p) => p.createdAt.isAfter(cutoff)).toList();
    return chaos(points);
  }

  // ─────────────────────────────────────────────
  // 翻舊帳：grudge_sealed 機制
  // ─────────────────────────────────────────────

  /// 掛 grudge_sealed 標記。
  /// 由 [processReply] 在同輪負面情緒 ≥70 且有具體事件記憶時自動調用。
  static Future<void> _sealGrudge(
    String characterId,
    int memoryId,
    double negativeConcentration,
    String eventSummary,
  ) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    // INSERT OR IGNORE：同一記憶不重複掛標記
    await db.rawInsert(
      '''
      INSERT OR IGNORE INTO grudge_seals
        (character_id, memory_id, negative_concentration, event_summary, sealed_at)
      VALUES (?, ?, ?, ?, ?)
    ''',
      [
        characterId,
        memoryId,
        negativeConcentration,
        eventSummary,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  /// 概率計算：負面情緒 bar level → roll 概率
  /// 30 → 15%，60 → 45%，90 → 80%；<30 → 0%；不給 100%
  static double _grudgeProbability(double barLevel) {
    if (barLevel < kGrudgeTriggerLow) return 0;
    if (barLevel < kGrudgeTriggerMid) {
      return kGrudgeProbLow +
          (barLevel - kGrudgeTriggerLow) /
              (kGrudgeTriggerMid - kGrudgeTriggerLow) *
              (kGrudgeProbMid - kGrudgeProbLow);
    }
    if (barLevel < kGrudgeTriggerHigh) {
      return kGrudgeProbMid +
          (barLevel - kGrudgeTriggerMid) /
              (kGrudgeTriggerHigh - kGrudgeTriggerMid) *
              (kGrudgeProbHigh - kGrudgeProbMid);
    }
    return kGrudgeProbHigh; // 永不 100%
  }

  /// 情緒提示語：根據 bar level 給不同強度的注入語
  /// 行為由模型自己判斷——這裡只描述內在狀態，不指令
  static String _grudgePromptTone(double barLevel) {
    if (barLevel >= kGrudgeTriggerHigh) {
      return L.pick(
        en: 'You can barely control your tone now… this is not an act; it has genuinely reached that point.',
        zhTW: '你現在很難控制語氣……這不是表演，是真的到了',
      );
    } else if (barLevel >= kGrudgeTriggerMid) {
      return L.pick(
        en: 'Some unresolved hurt is weighing on you… it can still be soothed.',
        zhTW: '你心裡壓著一些不舒服的事……哄得回來的程度',
      );
    } else {
      return L.pick(
        en: 'Something unresolved is still weighing on you…',
        zhTW: '你心裡有些壓著的事……',
      );
    }
  }

  /// 嘗試觸發翻舊帳。返回注入 prompt 的文本（空字串 = 沒觸發）。
  ///
  /// 流程：
  /// 1. 取負面情緒 bar level
  /// 2. 計算概率，roll
  /// 3. 檢查冷卻（6h）
  /// 4. 成功 → 拉 grudge_sealed 記憶，組裝提示語
  /// 5. 記錄 surfaced_at
  ///
  /// 注意：此函數有副作用（更新 surfaced_at）。
  static Future<String> _tryGrudgeSurface(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final b = await bars(characterId);
    final negBar = b['負面情緒'] ?? 0;

    // 低於觸發線 → 不翻
    final prob = _grudgeProbability(negBar);
    if (prob <= 0) return '';

    // 概率 roll
    final rng = Random();
    if (rng.nextDouble() >= prob) return '';

    // 冷卻檢查：6h 內翻過就不再翻
    final cooldownCutoff = DateTime.now()
        .subtract(const Duration(hours: kGrudgeCooldownHours))
        .toIso8601String();
    final recentSurface = await db.query(
      'grudge_seals',
      where: 'character_id = ? AND surfaced_at > ?',
      whereArgs: [characterId, cooldownCutoff],
      limit: 1,
    );
    if (recentSurface.isNotEmpty) return '';

    // 拉 grudge_sealed 記憶（按負面濃度排序，最痛的先翻）
    final grudges = await db.query(
      'grudge_seals',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'negative_concentration DESC',
      limit: kGrudgeMaxItems,
    );
    if (grudges.isEmpty) return '';

    // 組裝：拉綁定的記憶原文
    final items = <String>[];
    final now = DateTime.now().toIso8601String();
    for (final g in grudges) {
      final memId = g['memory_id'] as int;
      final summary = g['event_summary'] as String? ?? '';

      // 嘗試拉記憶原文
      String? memContent;
      try {
        final mems = await db.query(
          'memories',
          columns: ['content'],
          where: 'id = ?',
          whereArgs: [memId],
        );
        if (mems.isNotEmpty) {
          memContent = mems.first['content'] as String?;
        }
      } catch (_) {}

      final display = memContent ?? summary;
      if (display.isNotEmpty) items.add('「$display」');

      // 記錄 surfaced_at
      await db.update(
        'grudge_seals',
        {'surfaced_at': now},
        where: 'id = ?',
        whereArgs: [g['id']],
      );
    }

    if (items.isEmpty) return '';

    final tone = _grudgePromptTone(negBar);
    final label = L.pick(en: 'Old hurt resurfacing: ', zhTW: '浮上來的舊帳：');
    return '$tone\n$label${items.join(L.pick(en: '; ', zhTW: '；'))}';
  }

  // ─────────────────────────────────────────────
  // 打點協議（模型側）
  // ─────────────────────────────────────────────

  static final _emoRe = RegExp(r'<emo>([\s\S]*?)</emo>', multiLine: true);
  static final _resolveRe = RegExp(
    r'<emo_resolve>([\s\S]*?)</emo_resolve>',
    multiLine: true,
  );
  static final _toolCallsRe = RegExp(
    r'<tool_calls?>[\s\S]*?</tool_calls?>',
    multiLine: true,
    caseSensitive: false,
  );
  static final _functionCallRe = RegExp(
    r'<function\b[\s\S]*?</function>',
    multiLine: true,
    caseSensitive: false,
  );

  /// 本輪打點日誌
  static final List<String> lastPointLog = <String>[];

  /// V2 座標約定 prompt（工具清單式）
  ///
  /// 語言分支鐵律（docs/cache完整攻略指南）：zh_TW 分支文本逐字節不動；
  /// 維度名是解析端要匹配的枚舉值，英文版也必須讓模型輸出中文維度名。
  static String abilityPrompt() {
    if (L.locale == 'en') {
      return '''■ Emotion
  <emo>dimension|x,y|intensity|note</emo>
  Log your inner shifts whenever this turn touched you — not just major events. Emotion points are not long-term memory; don't wait for something memo-worthy.
  Dimensions (write these Chinese labels verbatim): 安全感／慾望／愜意／負面情緒／戲謔
  X: -100 to +100 (unpleasant → pleasant), Y: -100 to +100 (calm → aroused)
  Intensity 0~100: small ripple 15~35, noticeable 35~60, strongly moved 60~84, only bone-deep moments reach 85+. Rate honestly, no exaggeration.
  Note rules: 85+ write the triggering context, 60~84 at most two keywords, below 60 may be empty.
  慾望 caps at 80. Multiple coexisting emotions may take multiple tags, usually 1~2. If stable, skip.

  <emo_resolve>dimension</emo_resolve>
  Use when an emotion is truly resolved (it passed, you made up, it released). Dimension in Chinese as above.''';
    }
    return L.pick(
      en: '',
      zhTW: '''■ 情緒
  <emo>維度|x,y|濃度|備註</emo>
  用來記錄你這一輪被觸動後的內在波動，不只重大事件。情緒打點不是長期記憶，不需要等到值得寫 memo 才用。
  維度：安全感／慾望／愜意／負面情緒／戲謔
  X：-100 到 +100（不愉快 → 愉快），Y：-100 到 +100（平靜 → 激動）
  濃度 0~100：小波動 15~35，日常明顯 35~60，明顯上頭 60~84，刻骨的才 85+。按真實強度打，不誇張。
  備註規則：85+ 寫觸發語境，60~84 最多兩個關鍵詞，60 以下可以留空。
  慾望上限 80。多情緒並存可打多個，通常 1~2 個就夠。穩定沒變就不打。

  <emo_resolve>維度</emo_resolve>
  當一份情緒被真實化解（事過了、和好了、釋放了）時使用。''',
    );
  }

  /// 處理回覆中的 `<emo>` 標籤：入庫、掛 grudge_sealed、剝離。
  static Future<String> processReply(
    String text, {
    required String characterId,
    int? memoryId,
  }) async {
    lastPointLog.clear();
    if (!text.contains('<emo>') &&
        !text.contains('<emo_resolve>') &&
        !text.toLowerCase().contains('<tool_call')) {
      return text;
    }

    // 收集本輪打點（用於 grudge 判定）
    final turnPoints = <EmotionPoint>[];
    int count = 0;

    for (final m in _emoRe.allMatches(text)) {
      if (count >= 5) break;
      final parsed = _parseEmoPayload(m.group(1)!.trim());
      if (parsed == null) continue;
      final point = await _recordEmotionPoint(
        parsed,
        characterId: characterId,
        memoryId: memoryId,
      );
      if (point == null) continue;
      turnPoints.add(point);
      count++;
    }

    var out = text.replaceAll(_emoRe, '');

    // <emo_resolve>
    for (final m in _resolveRe.allMatches(text)) {
      final type = m.group(1)!.trim();
      if (type.isEmpty) continue;
      await _resolveEmotionType(characterId, _normalizeEnDimension(type));
    }
    out = out.replaceAll(_resolveRe, '');

    // DeepSeek / Qwen / OpenAI-compatible 模板常把工具寫成文字 tool_call。
    for (final m in _toolCallsRe.allMatches(text)) {
      for (final unit in _toolCallUnits(m.group(0)!)) {
        final name = _toolName(unit);
        if (_isEmotionPointTool(name)) {
          if (count >= 5) continue;
          final parsed = _parseToolEmotionPoint(unit);
          if (parsed == null) continue;
          final point = await _recordEmotionPoint(
            parsed,
            characterId: characterId,
            memoryId: memoryId,
          );
          if (point == null) continue;
          turnPoints.add(point);
          count++;
        } else if (_isEmotionResolveTool(name)) {
          final type = _toolParam(unit, [
            'type',
            'dimension',
            'emotion',
            'emotion_type',
          ]);
          if (type != null && type.trim().isNotEmpty) {
            await _resolveEmotionType(characterId, _normalizeEnDimension(type));
          }
        }
      }
    }
    out = out.replaceAllMapped(
      _toolCallsRe,
      (m) => _stripEmotionToolCalls(m.group(0)!),
    );

    // ═══ V2 grudge_sealed：同輪有負面情緒 ≥70 且有具體事件記憶 → 掛標記 ═══
    if (memoryId != null) {
      final highNeg = turnPoints
          .where(
            (p) => p.type == '負面情緒' && p.concentration >= kGrudgeSealThreshold,
          )
          .toList();
      if (highNeg.isNotEmpty) {
        final worst = highNeg.reduce(
          (a, b) => a.concentration > b.concentration ? a : b,
        );
        await _sealGrudge(
          characterId,
          memoryId,
          worst.concentration,
          worst.note,
        );
        lastPointLog.add(
          '🔒 grudge_sealed #$memoryId（負面${worst.concentration.round()}%）',
        );
      }
    }

    return out.trim();
  }

  static _ParsedEmotionPoint? _parseEmoPayload(String raw) {
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final type = _normalizeEnDimension(parts[0]);
    final xy = parts[1].split(RegExp(r'[,，]'));
    if (xy.length != 2) return null;
    final x = double.tryParse(xy[0].trim());
    final y = double.tryParse(xy[1].trim());
    final concentration = double.tryParse(parts[2].replaceAll('%', '').trim());
    if (type.isEmpty || x == null || y == null || concentration == null) {
      return null;
    }
    return _ParsedEmotionPoint(
      type: type,
      x: x,
      y: y,
      concentration: concentration,
      note: parts.length > 3 ? parts.sublist(3).join('|').trim() : '',
    );
  }

  static _ParsedEmotionPoint? _parseToolEmotionPoint(String block) {
    final typeRaw = _toolParam(block, [
      'type',
      'dimension',
      'emotion',
      'emotion_type',
    ]);
    final type = typeRaw != null ? _normalizeEnDimension(typeRaw) : null;
    var xRaw = _toolParam(block, ['x', 'valence']);
    var yRaw = _toolParam(block, ['y', 'arousal']);
    final xyRaw = _toolParam(block, ['xy', 'coord', 'coords', 'coordinates']);
    if ((xRaw == null || yRaw == null) && xyRaw != null) {
      final xyMatch = RegExp(
        r'(-?\d+(?:\.\d+)?)\s*[,，]\s*(-?\d+(?:\.\d+)?)',
      ).firstMatch(xyRaw);
      xRaw ??= xyMatch?.group(1);
      yRaw ??= xyMatch?.group(2);
    }
    final concentrationRaw = _toolParam(block, [
      'concentration',
      'intensity',
      'strength',
      'level',
      'percent',
      'value',
    ]);
    final note =
        _toolParam(block, ['note', 'remark', 'context', 'reason', 'memo']) ??
        '';
    final x = double.tryParse((xRaw ?? '').replaceAll('%', '').trim());
    final y = double.tryParse((yRaw ?? '').replaceAll('%', '').trim());
    final concentration = double.tryParse(
      (concentrationRaw ?? '').replaceAll('%', '').trim(),
    );
    if (type == null ||
        type.trim().isEmpty ||
        x == null ||
        y == null ||
        concentration == null) {
      return null;
    }
    return _ParsedEmotionPoint(
      type: type.trim(),
      x: x,
      y: y,
      concentration: concentration,
      note: note.trim(),
    );
  }

  static Future<EmotionPoint?> _recordEmotionPoint(
    _ParsedEmotionPoint parsed, {
    required String characterId,
    int? memoryId,
  }) async {
    final point = EmotionPoint(
      characterId: characterId,
      type: parsed.type,
      x: parsed.x.clamp(-100, 100),
      y: parsed.y.clamp(-100, 100),
      concentration: parsed.concentration.clamp(0, 100),
      memoryId: memoryId,
      note: parsed.note,
    );

    await addPoint(point);
    // 顯示 clamp 後的值（依戀上限50，慾望上限80）
    final cap = kDimensionCaps[parsed.type] ?? 100.0;
    final displayC = parsed.concentration.clamp(0, cap).round();
    lastPointLog.add(
      '📍 打點 ${parsed.type}(${parsed.x.round()},${parsed.y.round()}) $displayC%'
      '${parsed.concentration > cap ? ' (cap${cap.round()})' : ''}'
      '${memoryId != null ? ' ⇢#$memoryId' : ''}',
    );
    return point;
  }

  static Future<void> _resolveEmotionType(
    String characterId,
    String type,
  ) async {
    final db = await DatabaseHelper.database;

    if (type == '慾望') {
      // 慾望特殊：消解 80%，留 20%
      final activeDesire = await db.query(
        'emotion_points',
        where: "character_id = ? AND type = '慾望' AND status = 'active'",
        whereArgs: [characterId],
      );
      var resolvedCount = 0;
      for (final row in activeDesire) {
        final id = row['id'] as int;
        final c = (row['concentration'] as num).toDouble();
        final remaining = c * 0.2; // 留 20%
        if (remaining < kDissipateBelow) {
          await db.update(
            'emotion_points',
            {
              'status': 'dissipated',
              'concentration': remaining,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        } else {
          await db.update(
            'emotion_points',
            {
              'concentration': remaining,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        resolvedCount++;
      }
      if (resolvedCount > 0) {
        lastPointLog.add('🌊 消解 慾望 80%（$resolvedCount 點，留 20%）');
      }
      return;
    }

    // 其他維度：完全消解
    final n = await db.update(
      'emotion_points',
      {'status': 'resolved', 'updated_at': DateTime.now().toIso8601String()},
      where: "character_id = ? AND type = ? AND status = 'active'",
      whereArgs: [characterId, type],
    );
    if (n > 0) lastPointLog.add('🌊 消解 $type（$n 點）');
  }

  static Iterable<String> _toolCallUnits(String block) {
    final functions = _functionCallRe.allMatches(block).map((m) => m.group(0)!);
    final list = functions.toList();
    return list.isEmpty ? [block] : list;
  }

  static String? _toolName(String block) {
    final attr = RegExp(
      r'''<(?:function|tool|tool_call)\b[^>]*\bname\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(block);
    if (attr != null) return _normalizeToolName(attr.group(1)!);

    final nameTag = RegExp(
      r'<name>\s*([^<]+)\s*</name>',
      caseSensitive: false,
    ).firstMatch(block);
    if (nameTag != null) return _normalizeToolName(nameTag.group(1)!);

    final jsonName = _lookupJsonValue(_decodeToolJson(block), ['name']);
    if (jsonName != null) return _normalizeToolName(jsonName.toString());

    return null;
  }

  static String _normalizeToolName(String name) =>
      name.trim().toLowerCase().replaceAll('-', '_');

  static bool _isEmotionPointTool(String? name) {
    return const {
      'emo',
      'emotion',
      'emotion_point',
      'emotion_coordinates',
      'add_emotion',
      'record_emotion',
      'set_emotion',
      '情緒',
    }.contains(name);
  }

  static bool _isEmotionResolveTool(String? name) {
    return const {
      'emo_resolve',
      'emotion_resolve',
      'resolve_emotion',
      'clear_emotion',
      '消解情緒',
    }.contains(name);
  }

  static String? _toolParam(String block, List<String> keys) {
    for (final key in keys) {
      final escaped = RegExp.escape(key);
      final xml = RegExp(
        '<parameter\\s+name\\s*=\\s*["\\\']$escaped["\\\']\\s*>([\\s\\S]*?)</parameter>',
        caseSensitive: false,
      ).firstMatch(block);
      if (xml != null) {
        final value = xml.group(1)!.trim();
        if (value.isNotEmpty) return value;
      }
    }

    final jsonValue = _lookupJsonValue(_decodeToolJson(block), keys);
    if (jsonValue != null) {
      final value = jsonValue.toString().trim();
      if (value.isNotEmpty) return value;
    }

    for (final key in keys) {
      final escaped = RegExp.escape(key);
      final quoted = RegExp(
        '["\\\']$escaped["\\\']\\s*:\\s*["\\\']([^"\\\']*)["\\\']',
        caseSensitive: false,
      ).firstMatch(block);
      if (quoted != null) {
        final value = quoted.group(1)!.trim();
        if (value.isNotEmpty) return value;
      }
      final bare = RegExp(
        '["\\\']$escaped["\\\']\\s*:\\s*([^,}\\]\\n]+)',
        caseSensitive: false,
      ).firstMatch(block);
      if (bare != null) {
        final value = bare.group(1)!.trim();
        if (value.isNotEmpty) return value;
      }
    }

    return null;
  }

  static Object? _decodeToolJson(String block) {
    final start = block.indexOf('{');
    final end = block.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final raw = block.substring(start, end + 1);
    try {
      return jsonDecode(raw);
    } catch (_) {
      try {
        return jsonDecode(raw.replaceAll(r'\"', '"'));
      } catch (_) {
        return null;
      }
    }
  }

  static Object? _lookupJsonValue(Object? node, List<String> keys) {
    if (node is Map) {
      final lowerKeys = keys.map((k) => k.toLowerCase()).toSet();
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        if (lowerKeys.contains(key)) return entry.value;
        if (key == 'arguments' && entry.value is String) {
          try {
            final nested = jsonDecode(entry.value as String);
            final found = _lookupJsonValue(nested, keys);
            if (found != null) return found;
          } catch (_) {}
        }
      }
      for (final value in node.values) {
        final found = _lookupJsonValue(value, keys);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _lookupJsonValue(value, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String _stripEmotionToolCalls(String block) {
    var out = block;
    for (final unit in _toolCallUnits(block)) {
      final name = _toolName(unit);
      if (_isEmotionPointTool(name) || _isEmotionResolveTool(name)) {
        out = out.replaceFirst(unit, '');
      }
    }
    return out
        .replaceAll(
          RegExp(
            r'<tool_calls?>\s*</tool_calls?>',
            multiLine: true,
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  // ─────────────────────────────────────────────
  // 狀態回饋（動態注入）
  // ─────────────────────────────────────────────

  /// V2 狀態 prompt。餵狀態，不餵機制。
  /// 含翻舊帳概率 roll（有副作用）。
  static Future<String> statePrompt(String characterId) async {
    final points = await activePoints(characterId);
    if (points.isEmpty) return '';

    final lines = <String>[];

    // ── 底色：五維進度條 ──
    final b = await bars(characterId);
    final tones = <String>[];
    for (final d in kV2Dimensions) {
      final v = b[d] ?? 0;
      if (v <= 0) continue;
      final word = v >= kPersistThreshold
          ? L.pick(en: 'deeply etched', zhTW: '刻骨')
          : (v >= 65
                ? L.pick(en: 'strong', zhTW: '強烈')
                : (v >= 30
                      ? L.pick(en: 'noticeable', zhTW: '明顯')
                      : L.pick(en: 'faint', zhTW: '微弱')));
      tones.add('${_displayDimension(d)} $word');
    }
    if (tones.isNotEmpty) {
      lines.add(
        L.pick(
          en: 'Undertone: ${tones.join(', ')}',
          zhTW: '底色：${tones.join('、')}',
        ),
      );
    }

    // ── 近期波動 ──
    final cutoff = DateTime.now().subtract(
      const Duration(hours: kChaosWindowHours),
    );
    final recent = points
        .where((p) => p.createdAt.isAfter(cutoff))
        .take(6)
        .map((p) => '${_displayDimension(p.type)} ${p.concentration.round()}')
        .toList();
    if (recent.isNotEmpty) {
      lines.add(
        L.pick(
          en: 'Recent shifts: ${recent.join(', ')}',
          zhTW: '近期波動：${recent.join('、')}',
        ),
      );
    }

    // ── 共振 / 拉扯 ──
    final c = await currentChaos(characterId);
    final windowCount = points.where((p) => p.createdAt.isAfter(cutoff)).length;
    if (windowCount >= 2) {
      lines.add(
        c < 0.35
            ? L.pick(
                en: 'Your feelings are resonating in the same direction right now.',
                zhTW: '此刻內在各種感受同向共振',
              )
            : (c > 0.6
                  ? L.pick(
                      en: 'There is a clear inner conflict right now.',
                      zhTW: '此刻內在有明顯拉扯',
                    )
                  : L.pick(
                      en: 'There is a slight inner conflict right now.',
                      zhTW: '此刻內在略有拉扯',
                    )),
      );
    }

    // ── 翻舊帳（概率 roll，有副作用）──
    final grudgeText = await _tryGrudgeSurface(characterId);
    if (grudgeText.isNotEmpty) {
      lines.add(grudgeText);
    }

    if (lines.isEmpty) return '';
    final header = L.pick(
      en: '【Your Current Emotional State (previously recorded by you)】',
      zhTW: '【你當下的情緒狀態（你自己先前記下的）】',
    );
    final footer = L.pick(
      en: '(Use this as behavioral guidance. Express it through tone and actions; do not describe the emotional process in the reply.)',
      zhTW: '（這些是行為參照，用語氣和行動體現，不要在正文中描述情緒過程）',
    );
    return '$header\n${lines.join('\n')}\n$footer';
  }

  /// Prompt-only display name. Persistence and parsing always use the
  /// canonical Traditional Chinese dimension keys above.
  static String _displayDimension(String canonical) {
    return switch (canonical) {
      '安全感' => L.pick(en: 'Security', zhTW: '安全感'),
      '慾望' => L.pick(en: 'Desire', zhTW: '慾望'),
      '愜意' => L.pick(en: 'Comfort', zhTW: '愜意'),
      '負面情緒' => L.pick(en: 'Negative emotion', zhTW: '負面情緒'),
      '戲謔' => L.pick(en: 'Banter', zhTW: '戲謔'),
      _ => canonical,
    };
  }

  // ─────────────────────────────────────────────
  // 時間戳格式（V2 簡化）
  // ─────────────────────────────────────────────

  /// 簡化時間戳：「18日，20點」
  static String shortTimestamp(DateTime dt) => '${dt.day}日，${dt.hour}點';

  // ─────────────────────────────────────────────
  // 研究用導出
  // ─────────────────────────────────────────────

  /// 全量導出（含已消散/已消解），JSON 字串。
  static Future<String> exportJson(String characterId) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final points = await db.query(
      'emotion_points',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'created_at ASC',
    );
    final grudges = await db.query(
      'grudge_seals',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'sealed_at ASC',
    );
    return const JsonEncoder.withIndent(
      '  ',
    ).convert({'emotion_points': points, 'grudge_seals': grudges});
  }
}

class _ParsedEmotionPoint {
  final String type;
  final double x;
  final double y;
  final double concentration;
  final String note;

  const _ParsedEmotionPoint({
    required this.type,
    required this.x,
    required this.y,
    required this.concentration,
    required this.note,
  });
}
