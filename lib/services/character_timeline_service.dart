import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart' show Transaction;

import '../memory/database.dart';
import '../models/message.dart';
import '../utils/iso_week.dart';
import 'locale_strings.dart';

class TimelineEventCandidate {
  final String type;

  /// 模型 JSON contract 裡的候選分類欄位。
  ///
  /// 注意：這**不是**經過驗證的歸屬，也不會被寫進 character_timeline
  /// （表裡沒有 subject 欄位），驗證器不讀它。真正的主體判斷靠
  /// [_menstrualBelongsToCharacter]，依據是來源訊息的 isUser 加上生理期
  /// 分句的局部人稱。不要把這個欄位當成可信的 owner。
  final String subject;
  final List<int> sourceMessageIds;
  final String occurredOn;
  final String dateBasis;
  final String? key;
  final String value;
  final String evidence;

  /// RP-only metadata. Daily extraction leaves these fields at their defaults.
  /// Keeping them on the decoded candidate prevents the RP JSON contract from
  /// being flattened before the dedicated RP timeline validator sees it.
  final String eventKey;
  final String narrativeLayer;
  final List<String> subjectEntityIds;

  const TimelineEventCandidate({
    required this.type,
    required this.subject,
    required this.sourceMessageIds,
    required this.occurredOn,
    required this.dateBasis,
    this.key,
    required this.value,
    required this.evidence,
    this.eventKey = '',
    this.narrativeLayer = 'mainline',
    this.subjectEntityIds = const <String>[],
  });
}

/// 生理週期所在小分句裡最靠近關鍵詞的人稱。
enum _MenstrualPerson { none, first, second, third }

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

  /// 摘要模型只負責提出候選；本地端仍須逐項通過來源、主體、證據、
  /// 日期和發生語態檢查。任何格式或語義可疑的項目都直接略過，
  /// 不阻斷摘要。明確的「生理期第 N 天」會同時產生開始事件與當前狀態。
  static Future<int> storeSummaryCandidates({
    required String characterId,
    required List<TimelineEventCandidate> candidates,
    required List<Message> sourceMessages,
  }) async {
    await _ensureTable();
    debugPrint(
      '[TimelineDebug] summary candidates: char=$characterId '
      'candidates=${candidates.length} sourceMessages=${sourceMessages.length} '
      'userMessages=${sourceMessages.where((message) => message.isUser).length}',
    );
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      debugPrint(
        '[TimelineDebug] candidate[$i] type=${candidate.type} '
        'subject=${candidate.subject} key=${candidate.key ?? ''} '
        'value=${candidate.value} evidence=${candidate.evidence}',
      );
    }
    if (candidates.isEmpty || sourceMessages.isEmpty) return 0;

    final sourceById = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final validated = <_ValidatedTimelineEntry>[];
    for (final candidate in candidates) {
      final entry = _validateCandidate(candidate, sourceById);
      if (entry != null) validated.add(entry);
    }
    validated.sort((a, b) {
      final dateOrder = a.occurredAt.compareTo(b.occurredAt);
      if (dateOrder != 0) return dateOrder;
      return a.sourceMessageIds.first.compareTo(b.sourceMessageIds.first);
    });
    debugPrint(
      '[TimelineDebug] validated=${validated.length} rejected='
      '${candidates.length - validated.length} char=$characterId',
    );
    if (validated.isEmpty) return 0;

    final db = await DatabaseHelper.database;
    return db.transaction<int>((txn) async {
      int inserted = 0;
      for (final entry in validated) {
        if (entry.clearStateKey != null) {
          inserted += await txn.delete(
            'character_timeline',
            where: "character_id = ? AND type = 'state' AND key = ?",
            whereArgs: [characterId, entry.clearStateKey],
          );
        }
        if (entry.type == 'state') {
          if (await _storeValidatedState(txn, characterId, entry)) inserted++;
          if (entry.derivedEventAt != null &&
              entry.derivedEventValue != null &&
              await _storeValidatedEvent(
                txn,
                characterId,
                occurredAt: entry.derivedEventAt!,
                value: entry.derivedEventValue!,
                sourceMessageIds: entry.sourceMessageIds,
                evidence: entry.evidence,
              )) {
            inserted++;
          }
          continue;
        }
        if (await _storeValidatedEvent(
          txn,
          characterId,
          occurredAt: entry.occurredAt,
          value: entry.value,
          sourceMessageIds: entry.sourceMessageIds,
          evidence: entry.evidence,
        )) {
          inserted++;
        }
      }
      return inserted;
    });
  }

  /// 即時記錄明確的生理週期語句，不等待窗口摘要達到 token 門檻。
  /// 只處理可由原文和消息時間直接驗證的句子，仍共用摘要候選的本地
  /// 驗證、日期推算、狀態覆蓋與事件去重；不發起額外模型請求。
  static Future<int> storeExplicitMenstrualMessages({
    required String characterId,
    required List<Message> messages,
  }) async {
    final candidates = <TimelineEventCandidate>[];
    for (final message in messages) {
      if (message.id == null) continue;
      final evidence = _extractMenstrualEvidence(message.text);
      if (evidence == null) continue;
      // 使用者說自己的生理期，不能記成角色的。驗證器還會再擋一次，
      // 這裡提早退出只是不做白工，也讓 debug 計數反映實際收錄量。
      if (!_menstrualBelongsToCharacter(
        evidence: evidence,
        speakerIsUser: message.isUser,
      )) {
        continue;
      }

      final day = _menstrualDayFromText(evidence);
      final ended = _hasMenstrualEndCue(evidence);
      final active = _hasCurrentMenstrualCue(evidence);
      final started = _hasMenstrualStartCue(evidence);
      if (day == null && !ended && !active && !started) continue;

      final basis = _dateBasisFromEvidence(evidence) ?? 'message_time';
      final local = message.createdAt.isUtc
          ? message.createdAt.toLocal()
          : message.createdAt;
      final date = switch (basis) {
        'relative' => _relativeDateFromEvidence(evidence, local),
        'explicit' => _explicitDateFromEvidence(evidence, local),
        _ => DateTime(local.year, local.month, local.day),
      };
      if (date == null) continue;

      final value = day != null
          ? '生理期第$day天'
          : ended
          ? '生理期結束'
          : started
          ? '生理期開始'
          : '生理期中';
      candidates.add(
        TimelineEventCandidate(
          type: ended ? 'event' : 'state',
          subject: 'character',
          sourceMessageIds: [message.id!],
          occurredOn: _dateOnly(date),
          dateBasis: basis,
          key: ended ? null : '生理週期',
          value: value,
          evidence: evidence,
        ),
      );
    }
    debugPrint(
      '[TimelineDebug] explicit scan: char=$characterId messages=${messages.length} '
      'candidates=${candidates.length}',
    );
    if (candidates.isEmpty) return 0;
    final changed = await storeSummaryCandidates(
      characterId: characterId,
      candidates: candidates,
      sourceMessages: messages,
    );
    debugPrint(
      '[TimelineDebug] explicit scan stored=$changed char=$characterId',
    );
    return changed;
  }

  static String? _extractMenstrualEvidence(String text) {
    if (!_hasExplicitMenstrualCue(text)) return null;
    final segments = text
        .split(RegExp(r'(?<=[。！？!?；;\n])'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty);
    for (final segment in segments) {
      if (_hasExplicitMenstrualCue(segment)) {
        return segment.length <= 240
            ? segment
            : segment.substring(0, 240).trim();
      }
    }
    final term = RegExp(
      r'生理期|生理週期|生理周期|經期|经期|月經|月经|'
      r'\bperiod\b|\bmenstrual\b|\bmenstruation\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (term == null) return null;
    final start = text.lastIndexOf(RegExp(r'[。！？!?；;\n]'), term.start);
    final endMatch = RegExp(
      r'[。！？!?；;\n]',
    ).firstMatch(text.substring(term.end));
    final end = endMatch == null ? text.length : term.end + endMatch.start;
    final evidence = text.substring(start < 0 ? 0 : start + 1, end).trim();
    return evidence.length <= 240
        ? evidence
        : evidence.substring(0, 240).trim();
  }

  static final RegExp _menstrualTermPattern = RegExp(
    r'生理期|生理週期|生理周期|經期|经期|月經|月经|'
    r'\bperiod\b|\bmenstrual\b|\bmenstruation\b',
    caseSensitive: false,
  );

  /// 比句號更細的斷點；用來切出緊鄰生理期關鍵詞的那一小段。
  static final RegExp _menstrualClauseBreak = RegExp(r'[，,、。！？!?；;：:\n]');

  // 撇號寫法（i'm、you're）不必單獨列：撇號是非單字字元，\bi\b 與
  // \byou\b 已經會命中。
  static final RegExp _menstrualFirstPerson = RegExp(
    r'我|咱|俺|\bi\b|\bim\b|\bmy\b|\bme\b|\bmine\b',
    caseSensitive: false,
  );

  static final RegExp _menstrualSecondPerson = RegExp(
    r'你|妳|您|\byou\b|\byour\b|\byours\b',
    caseSensitive: false,
  );

  static final RegExp _menstrualThirdPerson = RegExp(
    r'她|他|牠|它|\bshe\b|\bher\b|\bhers\b|\bhe\b|\bhis\b',
    caseSensitive: false,
  );

  /// 取生理期關鍵詞前後、同一小分句內最靠近它的人稱。
  ///
  /// 只看那一小段是刻意的：「你記得嗎，我今天生理期第一天」裡，前面的
  /// 「你」不能覆蓋後面分句的「我」。
  static _MenstrualPerson _menstrualSubjectPerson(String evidence) {
    final term = _menstrualTermPattern.firstMatch(evidence);
    if (term == null) return _MenstrualPerson.none;

    final before = evidence.substring(0, term.start);
    final priorBreaks = _menstrualClauseBreak.allMatches(before).toList();
    final clauseStart = priorBreaks.isEmpty ? 0 : priorBreaks.last.end;
    final after = evidence.substring(term.end);
    final nextBreak = _menstrualClauseBreak.firstMatch(after);
    final clauseEnd = nextBreak == null
        ? evidence.length
        : term.end + nextBreak.start;
    final clause = evidence.substring(clauseStart, clauseEnd);
    final termStart = term.start - clauseStart;
    final termEnd = term.end - clauseStart;

    var person = _MenstrualPerson.none;
    var nearestDistance = 1 << 30;
    void scan(RegExp pattern, _MenstrualPerson value) {
      for (final match in pattern.allMatches(clause)) {
        final distance = match.end <= termStart
            ? termStart - match.end
            : match.start >= termEnd
            ? match.start - termEnd
            : 0;
        if (distance < nearestDistance) {
          nearestDistance = distance;
          person = value;
        }
      }
    }

    scan(_menstrualFirstPerson, _MenstrualPerson.first);
    scan(_menstrualSecondPerson, _MenstrualPerson.second);
    scan(_menstrualThirdPerson, _MenstrualPerson.third);
    return person;
  }

  /// 這段生理週期敘述講的是不是角色自己。
  ///
  /// 同一句「我今天生理期第二天」，出現在誰的訊息裡決定了「我」是誰，
  /// 純文字判不出來——必須帶上來源訊息的 isUser。
  ///
  /// 範圍限制：目前只認人稱代詞，不認角色名／使用者名。名字出現而沒有
  /// 代詞時落在 none，視同說話者本人；這個限制可能造成名字句誤拒，角色
  /// 消息以名字談別人時也可能誤收，後續若要支援名字須把雙方名稱帶進來。
  static bool _menstrualBelongsToCharacter({
    required String evidence,
    required bool speakerIsUser,
  }) {
    return switch (_menstrualSubjectPerson(evidence)) {
      // 第二人稱指向對話的另一方。
      _MenstrualPerson.second => speakerIsUser,
      // 第一人稱與無主詞都算說話者本人。
      _MenstrualPerson.first || _MenstrualPerson.none => !speakerIsUser,
      // 第三人稱既不是角色也不是使用者，寧可漏收。
      _MenstrualPerson.third => false,
    };
  }

  /// 摘要 recovery 路徑用：這條訊息裡的生理週期敘述是否屬於角色。
  static bool menstrualStatementBelongsToCharacter(Message message) {
    final evidence = _extractMenstrualEvidence(message.text);
    if (evidence == null) return false;
    return _menstrualBelongsToCharacter(
      evidence: evidence,
      speakerIsUser: message.isUser,
    );
  }

  /// 決定這段 evidence 是誰說的。來源混合雙方且無法歸屬時回傳 null，
  /// 由呼叫端當成「判不出來」處理。
  static bool? _menstrualSpeakerIsUser(
    String evidence,
    List<Message> evidenceMessages,
  ) {
    if (evidenceMessages.isEmpty) return null;
    final speakers = evidenceMessages.map((m) => m.isUser).toSet();
    if (speakers.length == 1) return speakers.single;

    final normalized = _normalizeEvidence(evidence);
    if (normalized.isEmpty) return null;
    final owners = evidenceMessages
        .where((m) => _normalizeEvidence(m.text).contains(normalized))
        .map((m) => m.isUser)
        .toSet();
    return owners.length == 1 ? owners.single : null;
  }

  static _ValidatedTimelineEntry? _validateCandidate(
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
    if (value.contains('<') || value.contains('>')) {
      return null;
    }

    // Keep source-message provenance, but do not require the model's evidence
    // to be one exact contiguous substring of the source bubble.
    final evidenceMessages = ids.map((id) => sourceById[id]!).toList();
    if (evidenceMessages.every(
          (message) => _isMenstrualQuestion(message.text),
        ) ||
        _isMenstrualQuestion(evidence)) {
      return null;
    }
    // 生理週期的主體無法只從文字判定。本地 explicit 掃描與摘要候選兩條
    // 寫入路徑都會經過這裡，守門放在這個匯流點才不會有繞過的路。
    final menstrualCandidate =
        _hasMenstrualTerm(evidence) ||
        _hasMenstrualTerm(value) ||
        _hasMenstrualTerm(candidate.key ?? '');
    if (menstrualCandidate) {
      // value/key 不能替代來源證據；模型憑空填入生理週期時必須拒絕。
      if (!_hasMenstrualTerm(evidence)) return null;
      final speakerIsUser = _menstrualSpeakerIsUser(evidence, evidenceMessages);
      if (speakerIsUser == null ||
          !_menstrualBelongsToCharacter(
            evidence: evidence,
            speakerIsUser: speakerIsUser,
          )) {
        return null;
      }
    }
    final hasDeclarativeMenstrualEvidence = evidenceMessages.any(
      (message) => !_isMenstrualQuestion(message.text),
    );
    final sourceCorpus = evidenceMessages
        .map((message) => _normalizeEvidence(message.text))
        .join();
    final valueMenstrualDay = _menstrualDayFromText(value);
    final evidenceDay = hasDeclarativeMenstrualEvidence
        ? (_menstrualDayFromText(evidence) ??
              valueMenstrualDay ??
              _menstrualDayFromText(sourceCorpus))
        : null;
    final menstrualDay =
        evidenceDay ??
        (hasDeclarativeMenstrualEvidence && _hasMenstrualStartCue(evidence)
            ? 1
            : null);
    final menstrualEnded =
        hasDeclarativeMenstrualEvidence &&
        (_hasMenstrualEndCue(evidence) || _hasMenstrualEndCue(value));
    final menstrualActive =
        hasDeclarativeMenstrualEvidence &&
        (_hasCurrentMenstrualCue(evidence) ||
            _hasCurrentMenstrualCue(value) ||
            _hasCurrentMenstrualCue(sourceCorpus));
    // Keep menstrual semantics consistent: an explicit end candidate cannot
    // be accepted when the source says the period has not ended.
    if (_hasMenstrualTerm(value) &&
        value.contains('結束') &&
        !_hasMenstrualEndCue(evidence) &&
        !_hasMenstrualEndCue(sourceCorpus)) {
      return null;
    }
    // 生理週期有明確、可驗證的角色主體；模型偶爾誤標 relationship 時，
    // 不應在證據驗證前把正確候選丟掉。
    if (_isLowValueAddressAction(evidence)) {
      return null;
    }

    if (valueMenstrualDay != null && valueMenstrualDay != menstrualDay) {
      return null;
    }
    final normalizedType = menstrualDay != null || menstrualActive
        ? 'state'
        : (candidate.type == 'state' ? 'state' : 'event');
    var stateKey = normalizedType == 'state'
        ? (_canonicalStateKey(candidate.key ?? '') ??
              (candidate.key?.trim().isNotEmpty == true
                  ? candidate.key!.trim()
                  : '健康'))
        : null;
    if (menstrualDay != null || menstrualActive) stateKey = '生理週期';

    var occurredDate = _parseStrictDate(candidate.occurredOn);
    if (occurredDate == null) return null;
    final modelBasis = candidate.dateBasis.trim();
    final evidenceBasis = _dateBasisFromEvidence(evidence);
    final basis =
        evidenceBasis ??
        (const {'message_time', 'relative', 'explicit'}.contains(modelBasis)
            ? modelBasis
            : 'message_time');

    DateTime? anchor;
    DateTime? evidenceResolvedDate;
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
      if (evidenceBasis != null && expected != null) {
        if (evidenceResolvedDate != null &&
            !_sameDay(evidenceResolvedDate, expected)) {
          return null;
        }
        evidenceResolvedDate = expected;
        anchor ??= local;
        continue;
      }
      if (expected != null && _sameDay(expected, occurredDate)) {
        anchor = local;
        break;
      }
    }
    anchor ??= evidenceMessages.first.createdAt.toLocal();
    if (evidenceResolvedDate != null) occurredDate = evidenceResolvedDate;
    // The local bubble timestamp is the upper bound for a completed event.
    // This also catches a model turning an upcoming dated plan into history.
    final latestSourceDate = evidenceMessages
        .map((message) {
          final time = message.createdAt;
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

    var occurredAt = basis == 'message_time'
        ? DateTime(
            occurredDate.year,
            occurredDate.month,
            occurredDate.day,
            anchor.hour,
            anchor.minute,
            anchor.second,
          )
        : DateTime(occurredDate.year, occurredDate.month, occurredDate.day, 12);
    var normalizedValue = value;
    var storedType = normalizedType;
    var storedKey = stateKey;
    String? clearStateKey;
    DateTime? derivedEventAt;
    String? derivedEventValue;
    if (menstrualDay != null) {
      if (menstrualDay < 1 || menstrualDay > 14) return null;
      final startAt = DateTime(
        occurredDate.year,
        occurredDate.month,
        occurredDate.day,
        12,
      ).subtract(Duration(days: menstrualDay - 1));
      final observedDate = DateTime(
        latestSourceDate.year,
        latestSourceDate.month,
        latestSourceDate.day,
      );
      final elapsed = observedDate.difference(
        DateTime(occurredDate.year, occurredDate.month, occurredDate.day),
      );
      final observedDay = menstrualDay + elapsed.inDays;
      if (observedDay < menstrualDay || observedDay > 14) return null;
      occurredAt = startAt;
      normalizedValue = '生理期第$observedDay天（推算；開始於${_dateOnly(startAt)}）';
      derivedEventAt = startAt;
      derivedEventValue = '生理期開始（推算）';
    } else if (menstrualActive) {
      normalizedValue = '生理期中（紀錄於${_dateOnly(occurredAt)}）';
    } else if (menstrualEnded) {
      // 結束是一個有日期的歷史事件，不是會永久留在 prompt 裡的當前
      // 狀態；同時移除先前的「第 N 天」快照。
      storedType = 'event';
      storedKey = null;
      clearStateKey = '生理週期';
      normalizedValue = '生理期結束';
    }

    return _ValidatedTimelineEntry(
      type: storedType,
      key: storedKey,
      sourceMessageIds: ids,
      occurredAt: occurredAt,
      observedAt: latestSourceDate,
      value: normalizedValue,
      evidence: evidence,
      clearStateKey: clearStateKey,
      derivedEventAt: derivedEventAt,
      derivedEventValue: derivedEventValue,
    );
  }

  static Future<bool> _storeValidatedEvent(
    Transaction txn,
    String characterId, {
    required DateTime occurredAt,
    required String value,
    required List<int> sourceMessageIds,
    required String evidence,
  }) async {
    final dayStart = DateTime(
      occurredAt.year,
      occurredAt.month,
      occurredAt.day,
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
      if (_sameEventValue(row['value']?.toString() ?? '', value)) {
        duplicate = Map<String, Object?>.from(row);
        break;
      }
    }
    if (duplicate != null) {
      final mergedIds = <int>{
        ..._decodeSourceIds(duplicate['source_message_ids']),
        ...sourceMessageIds,
      }.toList()..sort();
      await txn.update(
        'character_timeline',
        {
          'source_message_id': mergedIds.first,
          'source_message_ids': jsonEncode(mergedIds),
          if ((duplicate['source_evidence']?.toString() ?? '').isEmpty)
            'source_evidence': evidence,
        },
        where: 'id = ?',
        whereArgs: [duplicate['id']],
      );
      return false;
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
        value,
        sourceMessageIds.first,
        jsonEncode(sourceMessageIds),
        evidence,
        isoWeekGroup(occurredAt),
        occurredAt.toIso8601String(),
        now,
      ],
    );
    return id != 0;
  }

  static Future<bool> _storeValidatedState(
    Transaction txn,
    String characterId,
    _ValidatedTimelineEntry entry,
  ) async {
    final key = entry.key!;
    final rows = await txn.query(
      'character_timeline',
      where: "character_id = ? AND type = 'state' AND key = ?",
      whereArgs: [characterId, key],
      limit: 1,
    );
    if (rows.isEmpty) {
      final id = await txn.insert('character_timeline', {
        'character_id': characterId,
        'type': 'state',
        'key': key,
        'value': entry.value,
        'source_message_id': entry.sourceMessageIds.first,
        'source_message_ids': jsonEncode(entry.sourceMessageIds),
        'source_evidence': entry.evidence,
        'confirmed': 1,
        'created_at': entry.occurredAt.toIso8601String(),
        'updated_at': entry.observedAt.toIso8601String(),
      });
      return id != 0;
    }

    final existing = Map<String, Object?>.from(rows.single);
    final sameValue = existing['value']?.toString() == entry.value;
    final existingUpdatedAt = DateTime.tryParse(
      existing['updated_at']?.toString() ?? '',
    );
    if (!sameValue &&
        existingUpdatedAt != null &&
        entry.observedAt.isBefore(existingUpdatedAt)) {
      // A late summary from an older window must never roll a newer current
      // state backwards. Its derived historical event is still stored.
      return false;
    }
    final mergedIds = <int>{
      ..._decodeSourceIds(existing['source_message_ids']),
      ...entry.sourceMessageIds,
    }.toList()..sort();
    await txn.update(
      'character_timeline',
      {
        'value': entry.value,
        'source_message_id': mergedIds.first,
        'source_message_ids': jsonEncode(mergedIds),
        'source_evidence': entry.evidence,
        if (!sameValue ||
            entry.occurredAt.isBefore(
              DateTime.tryParse(existing['created_at']?.toString() ?? '') ??
                  entry.occurredAt,
            ))
          'created_at': entry.occurredAt.toIso8601String(),
        if (existingUpdatedAt == null ||
            !entry.observedAt.isBefore(existingUpdatedAt))
          'updated_at': entry.observedAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [existing['id']],
    );
    return !sameValue;
  }

  static String? _canonicalStateKey(String raw) {
    const aliases = <String, String>{
      '髮型': '髮型',
      '发型': '髮型',
      'hairstyle': '髮型',
      '美甲': '美甲',
      'nails': '美甲',
      '鬍子': '鬍子',
      '胡子': '鬍子',
      'beard': '鬍子',
      '住所': '住所',
      '住址': '住所',
      'residence': '住所',
      '工作': '工作',
      'work': '工作',
      '寵物': '寵物',
      '宠物': '寵物',
      'pet': '寵物',
      '健康': '健康',
      'health': '健康',
      '關係狀態': '關係狀態',
      '关系状态': '關係狀態',
      'relationship status': '關係狀態',
      '生理週期': '生理週期',
      '生理周期': '生理週期',
      '生理期': '生理週期',
      '經期': '生理週期',
      '经期': '生理週期',
      '月經': '生理週期',
      '月经': '生理週期',
      'menstrual cycle': '生理週期',
      'period': '生理週期',
    };
    return aliases[raw.trim().toLowerCase()];
  }

  static bool _isLowValueAddressAction(String evidence) {
    final normalized = evidence.toLowerCase();
    if (normalized.contains('改名') || normalized.contains('名字改')) {
      return false;
    }
    const addressCues = [
      '稱呼',
      '称呼',
      '叫作',
      '叫做',
      '喊作',
      '喚作',
      '唤作',
      '暱稱',
      '昵称',
      'call you',
      'called you',
      'nickname',
    ];
    return addressCues.any(normalized.contains);
  }

  // ignore: unused_element
  static bool _hasRelationshipGrounding(String evidence) {
    final normalized = evidence.toLowerCase();
    const relationshipCues = [
      '我們',
      '我们',
      '咱們',
      '咱们',
      '兩人',
      '两人',
      '雙方',
      '双方',
      '彼此',
      '一起',
      '交往',
      '告白',
      '和好',
      '分手',
      '結婚',
      '结婚',
      '離婚',
      '离婚',
      '約會',
      '约会',
      '關係',
      '关系',
      'we ',
      'both ',
      'together',
      'relationship',
      'dating',
      'married',
      'broke up',
      'made up',
    ];
    return relationshipCues.any(normalized.contains);
  }

  // ignore: unused_element
  static bool _hasCharacterMenstrualCue(String evidence) {
    final normalized = evidence.toLowerCase();
    final characterCue = RegExp(
      r'你|妳|您|your|her|她|角色',
      caseSensitive: false,
    ).hasMatch(normalized);
    if (characterCue) return true;
    final period = RegExp(
      r'生理期|經期|经期|月經|月经|period|menstrual|menstruation',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (period == null) return true;
    final beforePeriod = normalized.substring(0, period.start).trim();
    if (RegExp(
      r'(?:^|[，,。！？!?；;\s])(?:我|我的|自己)'
      r'(?:今天|昨天|現在|目前|仍在|正在)?\s*$',
    ).hasMatch(beforePeriod)) {
      return false;
    }
    return !RegExp(
      r'\b(?:i\s*am|i\x27m|my|me)\b',
      caseSensitive: false,
    ).hasMatch(beforePeriod);
  }

  static int? _menstrualDayFromText(String text) {
    final zh = RegExp(
      r'(?:生理期|經期|经期|月經|月经)\s*(?:的)?\s*第?\s*([0-9一二三四五六七八九十兩两]+)\s*天',
    ).firstMatch(text);
    if (zh != null) return _parseDayNumber(zh.group(1)!);

    final normalized = text.toLowerCase();
    final enAfter = RegExp(
      r'(?:period|menstrual)[^\d]{0,20}day\s*(\d{1,2})',
    ).firstMatch(normalized);
    final enBefore = RegExp(
      r'day\s*(\d{1,2})[^\d]{0,20}(?:period|menstrual)',
    ).firstMatch(normalized);
    final digits = enAfter?.group(1) ?? enBefore?.group(1);
    return digits == null ? null : int.tryParse(digits);
  }

  static bool _hasMenstrualStartCue(String text) {
    final normalized = text.toLowerCase();
    const cues = [
      '生理期開始',
      '生理期开始',
      '來生理期',
      '来生理期',
      '來的生理期',
      '来的生理期',
      '月經來了',
      '月经来了',
      '經期開始',
      '经期开始',
      'period started',
      'period began',
      'menstruation started',
    ];
    return cues.any(normalized.contains);
  }

  static bool _hasExplicitMenstrualCue(String text) {
    final normalized = text.toLowerCase();
    if (!_hasMenstrualTerm(normalized) || _isMenstrualQuestion(normalized)) {
      return false;
    }
    return RegExp(
      r'第?\s*[0-9一二三四五六七八九十兩两]+\s*天|'
      r'開始|开始|來了|来了|來生理期|来生理期|來的生理期|来的生理期|'
      r'結束|结束|完了|已完|沒了|没了|停了|'
      r'今天.{0,8}(?:還是|还是|仍是|仍在|還在|还在|正在)?\s*(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'(?:還是|还是|仍是|仍在|還在|还在|正在).{0,8}(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'\bday\s*\d{1,2}\b|\bstarted\b|\bbegan\b|'
      r'\bended\b|\bfinished\b|\bis over\b|'
      r'\b(?:still|currently)\s+(?:on\s+)?(?:her\s+|your\s+)?period\b',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  static bool _hasMenstrualTerm(String text) => RegExp(
    r'生理期|生理週期|生理周期|經期|经期|月經|月经|'
    r'\bperiod\b|\bmenstrual\b|\bmenstruation\b',
    caseSensitive: false,
  ).hasMatch(text);

  static bool _hasMenstrualEndCue(String text) {
    final normalized = text.toLowerCase();
    const unresolvedCues = [
      '還沒結束',
      '还没结束',
      '尚未結束',
      '尚未结束',
      '沒有結束',
      '没有结束',
      '沒結束',
      '没结束',
      '快結束',
      '快结束',
      '要結束',
      '要结束',
      '是否結束',
      '是否结束',
      '結束了嗎',
      '结束了吗',
      'not over',
      'has not ended',
      "hasn't ended",
      'not finished',
      'about to end',
    ];
    if (unresolvedCues.any(normalized.contains) ||
        normalized.endsWith('?') ||
        normalized.endsWith('？')) {
      return false;
    }
    const periodTerms = [
      '生理期',
      '經期',
      '经期',
      '月經',
      '月经',
      'period',
      'menstrual',
      'menstruation',
    ];
    const endTerms = [
      '結束',
      '结束',
      '完了',
      '已完',
      '沒了',
      '没了',
      '停了',
      'ended',
      'finished',
      'is over',
      'was over',
    ];
    return periodTerms.any(normalized.contains) &&
        endTerms.any(normalized.contains);
  }

  static bool _hasCurrentMenstrualCue(String text) {
    final normalized = text.toLowerCase();
    if (_hasMenstrualEndCue(normalized) || _isMenstrualQuestion(normalized)) {
      return false;
    }
    final periodTerm = RegExp(
      r'生理期|生理週期|生理周期|經期|经期|月經|月经|'
      r'\bperiod\b|\bmenstrual\b|\bmenstruation\b',
      caseSensitive: false,
    );
    if (!periodTerm.hasMatch(normalized)) return false;
    return RegExp(
      r'今天.{0,8}(?:還是|还是|仍是|仍在|還在|还在|正在)?\s*(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'(?:還是|还是|仍是|仍在|還在|还在|正在).{0,8}(?:生理期|生理週期|生理周期|經期|经期|月經|月经)|'
      r'\b(?:still|currently)\s+(?:on\s+)?(?:her\s+|your\s+)?period\b',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  static bool _isMenstrualQuestion(String text) {
    final normalized = text.toLowerCase();
    return RegExp(
      r'(?:生理期|生理週期|生理周期|經期|经期|月經|月经|period|menstrual|menstruation)'
      r'[^。.!！?？]{0,18}(?:嗎|吗|嘛|是否|是不是|[?？])',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  static String _normalizeEvidence(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s“”‘’「」『』]'), '').trim();

  static int? _parseDayNumber(String raw) {
    final digits = int.tryParse(raw);
    if (digits != null) return digits;
    const units = <String, int>{
      '一': 1,
      '二': 2,
      '兩': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    if (units.containsKey(raw)) return units[raw];
    if (raw.startsWith('十') && raw.length == 2) {
      final tail = units[raw.substring(1)];
      return tail == null ? null : 10 + tail;
    }
    return null;
  }

  static String _dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

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

  static String? _dateBasisFromEvidence(String evidence) {
    if (RegExp(
      r'(?:\d{4}\s*(?:年|[-/.])\s*)?\d{1,2}\s*(?:月|[/.-])\s*\d{1,2}\s*日?',
    ).hasMatch(evidence)) {
      return 'explicit';
    }
    final normalized = evidence.toLowerCase();
    const relativeCues = [
      '今天',
      '昨天',
      '前天',
      'today',
      'yesterday',
      'day before yesterday',
    ];
    return relativeCues.any(normalized.contains) ? 'relative' : null;
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

  // ignore: unused_element
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
  // ignore: unused_element
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

  static Future<bool> deleteEntry({
    required String characterId,
    required int id,
  }) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final deleted = await db.delete(
      'character_timeline',
      where: 'id = ? AND character_id = ?',
      whereArgs: [id, characterId],
    );
    return deleted > 0;
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
  static Future<String> stateSnapshotPrompt(
    String characterId, {
    DateTime? now,
  }) async {
    final states = await getStates(characterId);
    if (states.isEmpty) return '';

    final lines = <String>[];
    for (final s in states) {
      final key = s['key'] as String;
      final storedValue = s['value'] as String;
      final value = _stateValueForDate(key, storedValue, now ?? DateTime.now());
      if (value == null) continue;
      final dateSource = key == '生理週期'
          ? s['created_at'] as String
          : s['updated_at'] as String;
      final date = dateSource.substring(0, 10); // YYYY-MM-DD
      lines.add(
        '$key${L.pick(en: ': ', zhTW: '：')}$value${L.pick(en: ' (since ', zhTW: '（')}$date${L.pick(en: ')', zhTW: ' 起）')}',
      );
    }
    if (lines.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln(L.pick(en: '【Your recent life status】', zhTW: '【你的近期生活狀態】'));
    for (final line in lines) {
      buf.writeln(line);
    }

    buf.writeln(
      L.pick(
        en: 'If anything is wrong, use <life_fix>field|new status</life_fix> to correct. No action needed if correct.',
        zhTW: '如有變化用 <life_fix>欄位|新狀態</life_fix> 更正，沒問題就不用動。',
      ),
    );

    return buf.toString().trimRight();
  }

  static String? _stateValueForDate(String key, String value, DateTime now) {
    if (key != '生理週期') return value;
    final match = RegExp(
      r'^生理期第\d+天（推算；開始於(\d{4}-\d{2}-\d{2})）$',
    ).firstMatch(value);
    if (match == null) return value;
    final start = _parseStrictDate(match.group(1)!);
    if (start == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    final day = today.difference(start).inDays + 1;
    if (day < 1 || day > 14) return null;
    return '生理期第$day天（推算；開始於${_dateOnly(start)}）';
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

    return stripLifeFix(reply);
  }

  /// RP 不擁有日常生活狀態，但仍需把模型意外輸出的協議標籤從正文剝離，
  /// 避免跨模式寫入 `character_timeline` 或把內部標籤顯示給使用者。
  static String stripLifeFix(String reply) =>
      reply.replaceAll(RegExp(r'<life_fix>(.*?)\|(.*?)</life_fix>'), '').trim();

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

  /// 啟動維護：過期事件清理 + 健康自動回正 + 推算經期狀態到期。
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

    // 摘要只能根據最近一次明確的「第 N 天」向消息當天推算，不能把
    // 這個推算永久當成事實。超過 10 天沒有新證據時移除快照，
    // 但保留「生理期開始（推算）」歷史事件供時間線查看。
    final periodCutoff = DateTime.now()
        .subtract(const Duration(days: 10))
        .toIso8601String();
    final expiredPeriods = await db.delete(
      'character_timeline',
      where:
          "character_id = ? AND type = 'state' AND key = '生理週期' "
          "AND value LIKE '生理期第%（推算；開始於%' AND updated_at < ?",
      whereArgs: [characterId, periodCutoff],
    );
    if (expiredPeriods > 0) {
      debugPrint('時間線維護：移除過期的推算經期狀態');
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

class _ValidatedTimelineEntry {
  final String type;
  final String? key;
  final List<int> sourceMessageIds;
  final DateTime occurredAt;
  final DateTime observedAt;
  final String value;
  final String evidence;
  final String? clearStateKey;
  final DateTime? derivedEventAt;
  final String? derivedEventValue;

  const _ValidatedTimelineEntry({
    required this.type,
    required this.key,
    required this.sourceMessageIds,
    required this.occurredAt,
    required this.observedAt,
    required this.value,
    required this.evidence,
    required this.clearStateKey,
    required this.derivedEventAt,
    required this.derivedEventValue,
  });
}
