import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../memory/database.dart';
import '../models/character_diary_entry.dart';
import '../models/context_mode.dart';
import 'deferred_prompt.dart';
import 'locale_strings.dart';

class DiaryReplyResult {
  const DiaryReplyResult({required this.visibleText, required this.saved});

  final String visibleText;
  final bool saved;
}

/// Daily-mode diary protocol and storage.
///
/// Diary instructions live only in the request-time dynamic prompt. New
/// replies use the unified private-action protocol; legacy XML remains a local
/// compatibility format and never enters visible chat or either memory lane.
/// A database uniqueness constraint enforces one entry per character and local
/// calendar day.
abstract final class CharacterDiaryService {
  static const double promptChancePerEligibleTurn = 0.28;
  static const int maxTitleRunes = 80;
  static const int maxBodyRunes = 6000;

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final RegExp _completedDiary = RegExp(
    r'<holt_diary\b[^>]*>([\s\S]*?)</holt_diary>',
    caseSensitive: false,
  );
  static final RegExp _title = RegExp(
    r'<title\b[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  );
  static final RegExp _body = RegExp(
    r'<body\b[^>]*>([\s\S]*?)</body>',
    caseSensitive: false,
  );
  static final RegExp _openDiary = RegExp(
    r'<holt_diary\b[\s\S]*$',
    caseSensitive: false,
  );

  static String dateKey(DateTime localTime) {
    final local = localTime.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static bool isNight(DateTime localTime) {
    final hour = localTime.toLocal().hour;
    return hour >= 20 || hour < 4;
  }

  static Future<bool> hasEntryForDate(
    String characterId,
    String diaryDate,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT 1 FROM character_diaries '
      'WHERE character_id = ? AND diary_date = ? LIMIT 1',
      <Object?>[characterId, diaryDate],
    );
    return rows.isNotEmpty;
  }

  static Future<DeferredPrompt> buildNightPrompt({
    required String characterId,
    required String conversationId,
    required int sourceMessageId,
    required String userName,
    required String currentUserContent,
    required ContextMode contextMode,
    required bool enabled,
    DateTime? now,
    double? chanceRoll,
  }) async {
    if (!enabled || contextMode != ContextMode.daily) {
      return DeferredPrompt.empty();
    }
    final localNow = (now ?? DateTime.now()).toLocal();
    if (!isNight(localNow) || currentUserContent.trim().isEmpty) {
      return DeferredPrompt.empty();
    }
    final diaryDate = dateKey(localNow);
    if (await hasEntryForDate(characterId, diaryDate)) {
      return DeferredPrompt.empty();
    }

    final roll =
        chanceRoll ??
        _deterministicRoll(
          '$characterId|$conversationId|$sourceMessageId|$diaryDate',
        );
    if (roll >= promptChancePerEligibleTurn) return DeferredPrompt.empty();

    final safeUserName = _truncate(
      userName.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim(),
      40,
    );
    final visibleName = safeUserName.isEmpty
        ? L.pick(en: 'the user', zhTW: '對方', zhCN: '对方')
        : safeUserName;
    final prompt = L.pick(
      en: '''It is night. Would you like to write a diary entry today? You may decide freely from the user's latest message; this is optional. $visibleName can read the diary.
If you write one, use your own first-person voice and record only what you genuinely want to leave from today. Do not turn it into a summary, instruction, or memory list. Add exactly one private action block at the very end of the reply:
[[HOLT_ACTIONS]]
{"actions":[{"type":"diary.write","arguments":{"title":"optional short title","body":"diary text"}}]}
[[/HOLT_ACTIONS]]
Do not explain the action in the visible reply. If you do not want to write, output no diary.write action.''',
      zhTW:
          '''晚上了，今天妳想寫日記嗎？妳可以依照 user 剛剛帶來的資訊自由決定，這不是必須完成的任務。$visibleName 可以看得到這份日記。
若要寫，請用妳自己的第一人稱，只留下今天真正想記住的內容；不要寫成摘要、指令或記憶清單。僅在回覆最末尾額外輸出一次私有動作區塊：
[[HOLT_ACTIONS]]
{"actions":[{"type":"diary.write","arguments":{"title":"可留空的短標題","body":"日記正文"}}]}
[[/HOLT_ACTIONS]]
可見回覆中不要解釋動作；若今天不想寫，就不要輸出 diary.write 動作。''',
      zhCN:
          '''晚上了，今天你想写日记吗？你可以依照 user 刚刚带来的信息自由决定，这不是必须完成的任务。$visibleName 可以看得到这份日记。
若要写，请用你自己的第一人称，只留下今天真正想记住的内容；不要写成摘要、指令或记忆清单。仅在回复最末尾额外输出一次私有动作区块：
[[HOLT_ACTIONS]]
{"actions":[{"type":"diary.write","arguments":{"title":"可留空的短标题","body":"日记正文"}}]}
[[/HOLT_ACTIONS]]
可见回复中不要解释动作；若今天不想写，就不要输出 diary.write 动作。''',
    );
    return DeferredPrompt(prompt);
  }

  static Future<DiaryReplyResult> processReply({
    required String text,
    required String characterId,
    required String conversationId,
    required int? sourceMessageId,
    required ContextMode contextMode,
    required bool enabled,
    DateTime? now,
  }) async {
    final match = _completedDiary.firstMatch(text);
    final visible = text
        .replaceAll(_completedDiary, '')
        .replaceAll(_openDiary, '')
        .trim();
    if (match == null || !enabled || contextMode != ContextMode.daily) {
      return DiaryReplyResult(visibleText: visible, saved: false);
    }
    final inner = match.group(1) ?? '';
    final bodyMatch = _body.firstMatch(inner);
    if (bodyMatch == null) {
      return DiaryReplyResult(visibleText: visible, saved: false);
    }
    final title = _truncate(
      _plainXmlText(_title.firstMatch(inner)?.group(1) ?? ''),
      maxTitleRunes,
    );
    final body = _truncate(
      _plainXmlText(bodyMatch.group(1) ?? ''),
      maxBodyRunes,
    );
    if (body.isEmpty) {
      return DiaryReplyResult(visibleText: visible, saved: false);
    }

    final localNow = (now ?? DateTime.now()).toLocal();
    final diaryDate = dateKey(localNow);
    final db = await DatabaseHelper.database;
    final timestamp = localNow.toUtc().toIso8601String();
    var saved = false;
    await db.transaction((txn) async {
      final existing = await txn.rawQuery(
        'SELECT 1 FROM character_diaries '
        'WHERE character_id = ? AND diary_date = ? LIMIT 1',
        <Object?>[characterId, diaryDate],
      );
      if (existing.isNotEmpty) return;
      await txn.insert('character_diaries', <String, Object?>{
        'character_id': characterId,
        'diary_date': diaryDate,
        'title': title,
        'body': body,
        'source_conversation_id': conversationId,
        'source_message_id': sourceMessageId,
        'created_at': timestamp,
        'updated_at': timestamp,
      });
      saved = true;
    });
    if (saved) revision.value++;
    return DiaryReplyResult(visibleText: visible, saved: saved);
  }

  static Future<List<CharacterDiaryEntry>> listEntries(
    String characterId, {
    int? limit,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_diaries',
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
      orderBy: 'diary_date DESC, id DESC',
      limit: limit,
    );
    return rows.map(CharacterDiaryEntry.fromRow).toList(growable: false);
  }

  static Future<int> countEntries(String characterId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM character_diaries WHERE character_id = ?',
      <Object?>[characterId],
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  static Future<void> deleteEntry(int id) async {
    final db = await DatabaseHelper.database;
    final changed = await db.delete(
      'character_diaries',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (changed > 0) revision.value++;
  }

  static double _deterministicRoll(String seed) {
    return _stableHash(seed) / 0x7fffffff;
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static String _plainXmlText(String value) {
    final withoutTags = value.replaceAll(RegExp(r'<[^>]*>'), '');
    return withoutTags
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }

  static String _truncate(String value, int maxRunes) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maxRunes) return value;
    return String.fromCharCodes(runes.take(maxRunes));
  }

  @visibleForTesting
  static RegExp get completedDiaryPattern => _completedDiary;
}
