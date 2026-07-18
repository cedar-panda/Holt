import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../memory/database.dart';
import '../models/message.dart';
import '../utils/iso_week.dart';
import 'locale_strings.dart';

class TimelineEventCandidate {
  final List<int> sourceMessageIds;
  final String occurredOn;
  final String dateBasis;
  final String value;
  final String evidence;

  const TimelineEventCandidate({
    required this.sourceMessageIds,
    required this.occurredOn,
    required this.dateBasis,
    required this.value,
    required this.evidence,
  });
}

/// ═══════════════════════════════════════════════
/// 角色生活化 Timeline 服務
/// ═══════════════════════════════════════════════
///
/// 兩類事件：
/// - state（狀態變更）：髮型、住所、健康等，key UNIQUE 覆蓋
/// - event（一次性事件）：看電影、吃飯、吵架，7天分段，自動清理
///
/// 事件來源：窗口摘要模型回傳候選，本服務核對來源消息、原文證據與
/// 發生日期後才落庫。舊的回覆關鍵詞掃描已移除，避免只因提到「吵架」
/// 就誤記為真的吵架。
/// 注入方式：每個對話框第一條消息附帶狀態快照。
///
class CharacterTimelineService {
  static bool _tableEnsured = false;

  // ─────────────────────────────────────────────
  // A. 數據庫
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
        source_message_id INTEGER,
        source_message_ids TEXT NOT NULL DEFAULT '[]',
        source_evidence TEXT NOT NULL DEFAULT '',
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
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_timeline_event_daily_unique
      ON character_timeline (character_id, value, substr(created_at, 1, 10))
      WHERE type = 'event'
    ''');
    _tableEnsured = true;
  }

  // ─────────────────────────────────────────────
  // B. 摘要模型候選驗證
  // ─────────────────────────────────────────────

  /// 摘要模型只負責提出候選；本地端仍須逐項通過來源、證據、日期和
  /// 發生語態檢查。任何格式或語義可疑的項目都直接略過，不阻斷摘要。
  static Future<int> storeSummaryCandidates({
    required String characterId,
    required List<TimelineEventCandidate> candidates,
    required List<Message> sourceMessages,
  }) async {
    await _ensureTable();
    if (candidates.isEmpty || sourceMessages.isEmpty) return 0;

    final sourceById = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final validated = <_ValidatedTimelineEvent>[];
    for (final candidate in candidates) {
      final event = _validateCandidate(candidate, sourceById);
      if (event != null) validated.add(event);
    }
    validated.sort((a, b) {
      final dateOrder = a.occurredAt.compareTo(b.occurredAt);
      if (dateOrder != 0) return dateOrder;
      return a.sourceMessageIds.first.compareTo(b.sourceMessageIds.first);
    });
    if (validated.isEmpty) return 0;

    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      int inserted = 0;
      for (final event in validated) {
        final dayStart = DateTime(
          event.occurredAt.year,
          event.occurredAt.month,
          event.occurredAt.day,
        );
        final dayEnd = dayStart.add(const Duration(days: 1));
        final existing = await txn.query(
          'character_timeline',
          where:
              "character_id = ? AND type = 'event' "
              'AND created_at >= ? AND created_at < ?',
          whereArgs: [
            characterId,
            dayStart.toIso8601String(),
            dayEnd.toIso8601String(),
          ],
          orderBy: 'id ASC',
        );
        Map<String, Object?>? duplicate;
        for (final row in existing) {
          if (_sameEventValue(row['value']?.toString() ?? '', event.value)) {
            duplicate = row;
            break;
          }
        }
        if (duplicate != null) {
          final mergedIds = <int>{
            ..._decodeSourceIds(duplicate['source_message_ids']),
            ...event.sourceMessageIds,
          }.toList()..sort();
          await txn.update(
            'character_timeline',
            {
              'source_message_id': mergedIds.first,
              'source_message_ids': jsonEncode(mergedIds),
              if ((duplicate['source_evidence']?.toString() ?? '').isEmpty)
                'source_evidence': event.evidence,
            },
            where: 'id = ?',
            whereArgs: [duplicate['id']],
          );
          continue;
        }

        final now = DateTime.now().toIso8601String();
        final id = await txn.rawInsert(
          '''
          INSERT OR IGNORE INTO character_timeline
            (character_id, type, key, value, source_message_id,
             source_message_ids, source_evidence, week_group, confirmed,
             created_at, updated_at)
          VALUES (?, 'event', NULL, ?, ?, ?, ?, ?, 1, ?, ?)
          ''',
          [
            characterId,
            event.value,
            event.sourceMessageIds.first,
            jsonEncode(event.sourceMessageIds),
            event.evidence,
            isoWeekGroup(event.occurredAt),
            event.occurredAt.toIso8601String(),
            now,
          ],
        );
        if (id != 0) inserted++;
      }
      return inserted;
    });
  }

  static _ValidatedTimelineEvent? _validateCandidate(
    TimelineEventCandidate candidate,
    Map<int, Message> sourceById,
  ) {
    final ids = candidate.sourceMessageIds.toSet().toList()..sort();
    if (ids.isEmpty || ids.any((id) => !sourceById.containsKey(id))) {
      return null;
    }

    final value = candidate.value.trim();
    final evidence = candidate.evidence.trim();
    if (value.length < 2 || value.length > 120 || value.contains('\n')) {
      return null;
    }
    if (evidence.length < 2 ||
        evidence.length > 240 ||
        value.contains('<') ||
        value.contains('>')) {
      return null;
    }

    final evidenceMessages = ids
        .map((id) => sourceById[id]!)
        .where((message) => message.text.contains(evidence))
        .toList();
    if (evidenceMessages.isEmpty) return null;

    final occurredDate = _parseStrictDate(candidate.occurredOn);
    if (occurredDate == null) return null;
    final basis = candidate.dateBasis.trim();
    if (!const {'message_time', 'relative', 'explicit'}.contains(basis)) {
      return null;
    }
    if (_hasNonOccurrenceCue(evidence, basis) ||
        !_valueGroundedInEvidence(value, evidence)) {
      return null;
    }

    DateTime? anchor;
    for (final message in evidenceMessages) {
      final local = message.createdAt.isUtc
          ? message.createdAt.toLocal()
          : message.createdAt;
      final expected = switch (basis) {
        'message_time' => DateTime(local.year, local.month, local.day),
        'relative' => _relativeDateFromEvidence(evidence, local),
        'explicit' => _explicitDateFromEvidence(evidence, local),
        _ => null,
      };
      if (expected != null && _sameDay(expected, occurredDate)) {
        anchor = local;
        break;
      }
    }
    if (anchor == null) return null;

    // The local bubble timestamp is the upper bound for a completed event.
    // This also catches a model turning an upcoming dated plan into history.
    final latestSourceDate = ids
        .map((id) {
          final time = sourceById[id]!.createdAt;
          return time.isUtc ? time.toLocal() : time;
        })
        .reduce((a, b) => a.isAfter(b) ? a : b);
    if (occurredDate.isAfter(
      DateTime(
        latestSourceDate.year,
        latestSourceDate.month,
        latestSourceDate.day,
      ),
    )) {
      return null;
    }

    final occurredAt = basis == 'message_time'
        ? DateTime(
            occurredDate.year,
            occurredDate.month,
            occurredDate.day,
            anchor.hour,
            anchor.minute,
            anchor.second,
          )
        : DateTime(occurredDate.year, occurredDate.month, occurredDate.day, 12);
    return _ValidatedTimelineEvent(
      sourceMessageIds: ids,
      occurredAt: occurredAt,
      value: value,
      evidence: evidence,
    );
  }

  static DateTime? _parseStrictDate(String raw) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day
        ? parsed
        : null;
  }

  static DateTime? _relativeDateFromEvidence(String evidence, DateTime anchor) {
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    if (evidence.contains('前天') ||
        evidence.toLowerCase().contains('day before yesterday')) {
      return day.subtract(const Duration(days: 2));
    }
    if (evidence.contains('昨天') ||
        evidence.toLowerCase().contains('yesterday')) {
      return day.subtract(const Duration(days: 1));
    }
    if (evidence.contains('今天') || evidence.toLowerCase().contains('today')) {
      return day;
    }
    return null;
  }

  static DateTime? _explicitDateFromEvidence(String evidence, DateTime anchor) {
    final full = RegExp(
      r'(\d{4})\s*(?:年|[-/.])\s*(\d{1,2})\s*(?:月|[-/.])\s*(\d{1,2})\s*日?',
    ).firstMatch(evidence);
    if (full != null) {
      return _checkedDate(
        int.parse(full.group(1)!),
        int.parse(full.group(2)!),
        int.parse(full.group(3)!),
      );
    }
    final monthDay = RegExp(
      r'(?<!\d)(\d{1,2})\s*(?:月|[/.-])\s*(\d{1,2})\s*日?',
    ).firstMatch(evidence);
    if (monthDay == null) return null;
    return _checkedDate(
      anchor.year,
      int.parse(monthDay.group(1)!),
      int.parse(monthDay.group(2)!),
    );
  }

  static DateTime? _checkedDate(int year, int month, int day) {
    final parsed = DateTime(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day
        ? parsed
        : null;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _hasNonOccurrenceCue(String evidence, String basis) {
    final normalized = evidence.toLowerCase();
    const cues = [
      '如果',
      '假如',
      '要是',
      '要不要',
      '打算',
      '準備',
      '准备',
      '希望',
      '想要',
      '想去',
      '取消',
      '不要',
      '別',
      '别',
      '沒有',
      '没有',
      '沒',
      '未曾',
      '不是',
      '夢到',
      '梦到',
      '夢見',
      '梦见',
      '明天',
      '後天',
      '后天',
      '下次',
      '改天',
      '將來',
      '将来',
      'if ',
      'would ',
      'plan to',
      'want to',
      'hope to',
      "didn't",
      'did not',
      'do not',
      "don't",
      'never ',
      'dreamed',
      'tomorrow',
      'next time',
    ];
    if (cues.any(normalized.contains)) return true;
    if (basis == 'message_time') {
      const vaguePast = [
        '上次',
        '之前',
        '以前',
        '曾經',
        '曾经',
        '當時',
        '当时',
        'last time',
        'before',
        'used to',
      ];
      if (vaguePast.any(normalized.contains)) return true;
      if (normalized.endsWith('?') || normalized.endsWith('？')) return true;
    }
    return false;
  }

  /// The model may cite a real sentence but attach an unrelated event label.
  /// Require at least one meaningful CJK bigram or Latin word to be shared by
  /// the concise value and its verbatim evidence. The prompt asks the model to
  /// retain the source event's core wording, making this a deterministic guard
  /// against mappings such as evidence="做愛" → value="吵架".
  static bool _valueGroundedInEvidence(String value, String evidence) {
    String compact(String input) => input.toLowerCase().replaceAll(
      RegExp(r'[\s，。！？、,.!?;；:：…「」『』（）()【】\[\]_\-—]'),
      '',
    );
    final compactValue = compact(value);
    final compactEvidence = compact(evidence);
    const genericPairs = {
      '兩人',
      '两人',
      '二人',
      '我們',
      '我们',
      '你們',
      '你们',
      '他們',
      '他们',
      '她們',
      '她们',
      '雙方',
      '双方',
      '彼此',
      '角色',
      '用戶',
      '用户',
      '對方',
      '对方',
      '一起',
      '發生',
      '发生',
      '正式',
      '今天',
      '昨天',
      '前天',
      '剛剛',
      '刚刚',
    };
    for (int i = 0; i + 1 < compactValue.length; i++) {
      final pair = compactValue.substring(i, i + 2);
      if (!genericPairs.contains(pair) &&
          RegExp(r'[\u3400-\u9fff]').hasMatch(pair) &&
          compactEvidence.contains(pair)) {
        return true;
      }
    }

    final valueWords = value
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length >= 4)
        .toSet();
    final evidenceWords = evidence
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length >= 4)
        .toSet();
    return valueWords.intersection(evidenceWords).isNotEmpty;
  }

  static List<int> _decodeSourceIds(Object? raw) {
    dynamic decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    if (decoded is! List) return const [];
    return decoded.whereType<int>().where((id) => id > 0).toList();
  }

  static bool _sameEventValue(String a, String b) {
    String normalize(String value) => value.toLowerCase().replaceAll(
      RegExp(r'[\s，。！？、,.!?;；:：…「」『』（）()【】\[\]_\-—]'),
      '',
    );
    final left = normalize(a);
    final right = normalize(b);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final shorter = left.length <= right.length ? left : right;
    final longer = left.length > right.length ? left : right;
    return shorter.length >= 4 && longer.contains(shorter);
  }

  // ─────────────────────────────────────────────
  // C. CRUD
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
      WHERE character_timeline.value IS NOT excluded.value
         OR character_timeline.source_memory_id IS NOT excluded.source_memory_id
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
  static Future<bool> addEvent(
    String characterId,
    String value, {
    bool confirmed = true,
    int? sourceMemoryId,
    DateTime? occurredAt,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final now = occurredAt ?? DateTime.now();
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) return false;
    final weekGroup = isoWeekGroup(now);

    final id = await db.rawInsert(
      '''
      INSERT OR IGNORE INTO character_timeline
        (character_id, type, key, value, source_memory_id, week_group,
         confirmed, created_at, updated_at)
      VALUES (?, 'event', NULL, ?, ?, ?, ?, ?, ?)
      ''',
      [
        characterId,
        normalizedValue,
        sourceMemoryId,
        weekGroup,
        confirmed ? 1 : 0,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    return id != 0;
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
    DateTime? from,
    DateTime? until,
    int limit = 5,
    bool ascending = false,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;

    final clauses = <String>[
      'character_id = ?',
      "type = 'event'",
      'confirmed = 1',
    ];
    final args = <Object?>[characterId];
    if (weekGroup != null) {
      clauses.add('week_group = ?');
      args.add(weekGroup);
    }
    if (from != null) {
      clauses.add('created_at >= ?');
      args.add(from.toIso8601String());
    }
    if (until != null) {
      clauses.add('created_at < ?');
      args.add(until.toIso8601String());
    }
    return db.query(
      'character_timeline',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: ascending
          ? 'created_at ASC, id ASC'
          : 'created_at DESC, id DESC',
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

class _ValidatedTimelineEvent {
  final List<int> sourceMessageIds;
  final DateTime occurredAt;
  final String value;
  final String evidence;

  const _ValidatedTimelineEvent({
    required this.sourceMessageIds,
    required this.occurredAt,
    required this.value,
    required this.evidence,
  });
}
