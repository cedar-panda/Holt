part of 'database.dart';

class _SelfNoteStore {
  static Future<bool> appendSelfNote(String characterId, String note) async {
    final result = await appendSelfNoteDetailed(
      characterId,
      note,
      retainLongTerm: false,
    );
    return result.accepted;
  }

  static Future<({bool accepted, int? recordId})> appendSelfNoteDetailed(
    String characterId,
    String note, {
    required bool retainLongTerm,
    String provider = '',
    String modelId = '',
    String modelVersion = '',
    String sourceConversationId = '',
    List<int> sourceMessageIds = const <int>[],
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<({bool accepted, int? recordId})>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
      );
      if (rows.isEmpty) return (accepted: false, recordId: null);
      final existing = (rows.first['self_notes'] as String?) ?? '';
      final result = _mergeSelfNotesDetailed(existing, note);
      if (result.text != existing) {
        await txn.update(
          'characters',
          {'self_notes': result.text},
          where: 'id = ?',
          whereArgs: [characterId],
        );
      }
      if (!result.acceptedIncoming) {
        return (accepted: false, recordId: null);
      }
      final clean = _cleanSelfNote(note);
      final now = DateTime.now().toIso8601String();
      final records = await txn.query(
        'character_self_notes',
        where: 'character_id = ?',
        whereArgs: <Object?>[characterId],
      );
      final overlappingRecords = records
          .where(
            (row) => _selfNotesOverlap(row['content']?.toString() ?? '', clean),
          )
          .toList(growable: false);
      final exactRecord = overlappingRecords
          .cast<Map<String, Object?>>()
          .firstWhere(
            (row) => row['content']?.toString() == clean,
            orElse: () => <String, Object?>{},
          );
      final primaryRecord = exactRecord.isNotEmpty
          ? exactRecord
          : overlappingRecords.isEmpty
          ? <String, Object?>{}
          : overlappingRecords.first;
      final preservedMessageIds = <int>{...sourceMessageIds};
      var preservedLocked = false;
      var preservedLongTerm = retainLongTerm;
      for (final row in overlappingRecords) {
        preservedLocked = preservedLocked || row['locked'] == 1;
        preservedLongTerm = preservedLongTerm || row['long_term'] == 1;
        try {
          final decoded = jsonDecode(
            row['source_message_ids_json']?.toString() ?? '[]',
          );
          if (decoded is List) {
            preservedMessageIds.addAll(
              decoded
                  .map((item) => item is int ? item : int.tryParse('$item'))
                  .whereType<int>(),
            );
          }
        } catch (_) {}
      }
      int recordId;
      if (primaryRecord.isEmpty) {
        recordId = await txn.insert('character_self_notes', <String, Object?>{
          'character_id': characterId,
          'content': clean,
          'provider': provider.trim(),
          'model_id': modelId.trim(),
          'model_version': modelVersion.trim(),
          'source_conversation_id': sourceConversationId.trim(),
          'source_message_ids_json': jsonEncode(
            preservedMessageIds.toList()..sort(),
          ),
          'locked': preservedLocked ? 1 : 0,
          'long_term': preservedLongTerm ? 1 : 0,
          'created_at': now,
          'updated_at': now,
        });
      } else {
        recordId = primaryRecord['id'] as int;
        final storedProvider = primaryRecord['provider']?.toString() ?? '';
        final storedModelId = primaryRecord['model_id']?.toString() ?? '';
        final storedModelVersion =
            primaryRecord['model_version']?.toString() ?? '';
        final storedConversationId =
            primaryRecord['source_conversation_id']?.toString() ?? '';
        await txn.update(
          'character_self_notes',
          <String, Object?>{
            'content': clean,
            'provider': provider.trim().isEmpty
                ? storedProvider
                : provider.trim(),
            'model_id': modelId.trim().isEmpty ? storedModelId : modelId.trim(),
            'model_version': modelVersion.trim().isEmpty
                ? storedModelVersion
                : modelVersion.trim(),
            'source_conversation_id': sourceConversationId.trim().isEmpty
                ? storedConversationId
                : sourceConversationId.trim(),
            'source_message_ids_json': jsonEncode(
              preservedMessageIds.toList()..sort(),
            ),
            'locked': preservedLocked ? 1 : 0,
            'long_term': preservedLongTerm ? 1 : 0,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: <Object?>[recordId],
        );
      }
      final redundantIds = overlappingRecords
          .map((row) => row['id'])
          .whereType<int>()
          .where((id) => id != recordId)
          .toList(growable: false);
      for (final id in redundantIds) {
        await txn.delete(
          'character_self_notes',
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      }
      if (!retainLongTerm) {
        await txn.rawDelete(
          '''DELETE FROM character_self_notes
               WHERE character_id = ? AND locked = 0 AND long_term = 0
                 AND id NOT IN (
                   SELECT id FROM character_self_notes
                   WHERE character_id = ?
                   ORDER BY created_at DESC, id DESC LIMIT 12
                 )''',
          <Object?>[characterId, characterId],
        );
      }
      return (accepted: true, recordId: recordId);
    });
  }

  static Future<bool> deleteSelfNote(String characterId, String note) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
        limit: 1,
      );
      if (rows.isEmpty) return false;

      final stored = (rows.first['self_notes'] as String?) ?? '';
      final lines = _selfNoteLines(stored).toList();
      final target = _cleanSelfNote(note);
      final index = lines.indexOf(target);
      if (index < 0) return false;
      lines.removeAt(index);
      await txn.update(
        'characters',
        {'self_notes': _formatSelfNotes(lines)},
        where: 'id = ?',
        whereArgs: [characterId],
      );
      await txn.delete(
        'character_self_notes',
        where: 'character_id = ? AND content = ?',
        whereArgs: <Object?>[characterId, target],
      );
      return true;
    });
  }

  @visibleForTesting
  static String mergeSelfNotes(String existing, String incoming) =>
      _mergeSelfNotesDetailed(existing, incoming).text;

  static ({String text, bool acceptedIncoming}) _mergeSelfNotesDetailed(
    String existing,
    String incoming,
  ) {
    final cleanIncoming = _cleanSelfNote(incoming);
    var lines = _deduplicateSelfNoteLines(_selfNoteLines(existing));
    if (cleanIncoming.isEmpty) {
      return (text: _formatSelfNotes(lines), acceptedIncoming: false);
    }

    for (var index = 0; index < lines.length; index++) {
      final old = lines[index];
      if (!_selfNotesOverlap(old, cleanIncoming)) continue;
      // A strict superset may carry a useful qualifier. Replace in place so
      // deduplication never changes note ordering or consumes another slot.
      if (_selfNoteInformationScore(cleanIncoming) >
          _selfNoteInformationScore(old)) {
        lines[index] = cleanIncoming;
        return (text: _formatSelfNotes(lines), acceptedIncoming: true);
      }
      return (text: _formatSelfNotes(lines), acceptedIncoming: false);
    }

    lines.add(cleanIncoming);
    if (lines.length > 12) lines = lines.sublist(lines.length - 12);
    return (text: _formatSelfNotes(lines), acceptedIncoming: true);
  }

  static List<String> _selfNoteLines(String value) => value
      .split('\n')
      .map(_cleanSelfNote)
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  static String _formatSelfNotes(List<String> lines) =>
      lines.map((line) => '· $line').join('\n');

  static List<String> _deduplicateSelfNoteLines(Iterable<String> source) {
    final kept = <String>[];
    for (final raw in source) {
      final candidate = _cleanSelfNote(raw);
      if (candidate.isEmpty) continue;
      final matching = <int>[
        for (var index = 0; index < kept.length; index++)
          if (_selfNotesOverlap(kept[index], candidate)) index,
      ];
      if (matching.isEmpty) {
        kept.add(candidate);
        continue;
      }

      final first = matching.first;
      var winner = kept[first];
      if (_selfNoteInformationScore(candidate) >
          _selfNoteInformationScore(winner)) {
        winner = candidate;
      }
      for (final index in matching.skip(1)) {
        final current = kept[index];
        if (_selfNoteInformationScore(current) >
            _selfNoteInformationScore(winner)) {
          winner = current;
        }
      }
      kept[first] = winner;
      for (final index in matching.skip(1).toList().reversed) {
        kept.removeAt(index);
      }
    }
    return kept.length <= 12 ? kept : kept.sublist(kept.length - 12);
  }

  static String _cleanSelfNote(String value) =>
      value.trim().replaceFirst(RegExp(r'^[·•*\-]+\s*'), '').trim();

  static bool _selfNotesOverlap(String left, String right) {
    final a = _normalizeSelfNote(left);
    final b = _normalizeSelfNote(right);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (_selfNotesConflict(a, b)) return false;
    return _selfNoteSimilarity(a, b) >= 0.90;
  }

  static bool _selfNotesConflict(String left, String right) {
    const polarityTerms = <String>[
      '不再',
      '不是',
      '不會',
      '不能',
      '不要',
      '沒有',
      '没',
      '不',
      '無',
      '无',
      '拒絕',
      '拒绝',
      '取消',
      '結束',
      '结束',
    ];
    final leftPolarity = {
      for (final term in polarityTerms)
        if (left.contains(term)) term,
    };
    final rightPolarity = {
      for (final term in polarityTerms)
        if (right.contains(term)) term,
    };
    if (!setEquals(leftPolarity, rightPolarity)) return true;

    Set<String> numbers(String value) => RegExp(
      r'\d+(?:\.\d+)?',
    ).allMatches(value).map((match) => match.group(0)!).toSet();
    return !setEquals(numbers(left), numbers(right));
  }

  static double _selfNoteSimilarity(String left, String right) {
    final maxLength = max(left.length, right.length);
    if (maxLength == 0) return 1;
    final editSimilarity = 1 - _levenshtein(left, right) / maxLength;

    final shorter = left.length <= right.length ? left : right;
    final longer = left.length <= right.length ? right : left;
    final containmentSimilarity = longer.contains(shorter)
        ? shorter.length / longer.length
        : 0.0;

    final aPairs = _selfNoteBigrams(left);
    final bPairs = _selfNoteBigrams(right);
    if (aPairs.isEmpty || bPairs.isEmpty) {
      return max(editSimilarity, containmentSimilarity);
    }
    final intersection = aPairs.intersection(bPairs).length;
    final diceSimilarity =
        (2.0 * intersection) / (aPairs.length + bPairs.length);
    return max(editSimilarity, max(containmentSimilarity, diceSimilarity));
  }

  static int _levenshtein(String left, String right) {
    if (left == right) return 0;
    if (left.isEmpty) return right.length;
    if (right.isEmpty) return left.length;
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitutionCost =
            left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
            ? 0
            : 1;
        current[rightIndex] = min(
          min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
          previous[rightIndex - 1] + substitutionCost,
        );
      }
      previous = current;
    }
    return previous[right.length];
  }

  static String _normalizeSelfNote(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      if (rune >= 0xff01 && rune <= 0xff5e) {
        buffer.writeCharCode(rune - 0xfee0);
      } else if (RegExp(
        r'[a-z0-9\u3400-\u9fff]',
      ).hasMatch(String.fromCharCode(rune))) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static Set<String> _selfNoteBigrams(String value) {
    if (value.length < 2) return {value};
    return {
      for (var index = 0; index < value.length - 1; index++)
        value.substring(index, index + 2),
    };
  }

  static int _selfNoteInformationScore(String value) =>
      _normalizeSelfNote(value).length;

  static Future<String> getSelfNotes(String characterId) async {
    final db = await DatabaseHelper.database;
    return db.transaction<String>((txn) async {
      final rows = await txn.query(
        'characters',
        columns: ['self_notes'],
        where: 'id = ?',
        whereArgs: [characterId],
      );
      if (rows.isEmpty) return '';
      final stored = (rows.first['self_notes'] as String?) ?? '';
      final cleaned = _formatSelfNotes(
        _deduplicateSelfNoteLines(_selfNoteLines(stored)),
      );
      if (cleaned != stored) {
        await txn.update(
          'characters',
          {'self_notes': cleaned},
          where: 'id = ?',
          whereArgs: [characterId],
        );
      }
      return cleaned;
    });
  }

  static Future<String> getSelfNotesForPrompt(
    String characterId, {
    required int limit,
  }) async {
    final stored = await getSelfNotes(characterId);
    final lines = _selfNoteLines(stored);
    final bounded = limit.clamp(1, 12);
    final selected = lines.length <= bounded
        ? lines
        : lines.sublist(lines.length - bounded);
    return _formatSelfNotes(selected);
  }

  static Future<List<CharacterSelfNote>> getSelfNoteRecords(
    String characterId,
  ) async {
    final db = await DatabaseHelper.database;
    await _backfillCharacterSelfNotes(db, characterId: characterId);
    final rows = await db.query(
      'character_self_notes',
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(CharacterSelfNote.fromMap).toList(growable: false);
  }

  static Future<bool> setSelfNoteLocked(int id, bool locked) async {
    final db = await DatabaseHelper.database;
    final target = await db.query(
      'character_self_notes',
      columns: const <String>['character_id', 'locked'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (target.isEmpty) return false;
    final currentlyLocked = target.first['locked'] == 1;
    if (currentlyLocked == locked) return true;
    if (locked) {
      final rows = await db.rawQuery(
        '''SELECT COUNT(*) AS total FROM character_self_notes
             WHERE character_id = ? AND locked = 1 AND id <> ?''',
        <Object?>[target.first['character_id'], id],
      );
      final total = (rows.first['total'] as int?) ?? 0;
      if (total >= 10) return false;
    }
    return await db.update(
          'character_self_notes',
          <String, Object?>{
            'locked': locked ? 1 : 0,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[id],
        ) >
        0;
  }

  static Future<void> bindSelfNotesToMessage(
    Iterable<int> ids,
    int messageId,
  ) async {
    final noteIds = ids.toSet().toList(growable: false);
    if (noteIds.isEmpty) return;
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      for (final id in noteIds) {
        final rows = await txn.query(
          'character_self_notes',
          columns: const <String>['source_message_ids_json'],
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final values = <int>{};
        try {
          final decoded = jsonDecode(
            rows.first['source_message_ids_json']?.toString() ?? '[]',
          );
          if (decoded is List) {
            values.addAll(
              decoded
                  .map((item) => item is int ? item : int.tryParse('$item'))
                  .whereType<int>(),
            );
          }
        } catch (_) {}
        values.add(messageId);
        await txn.update(
          'character_self_notes',
          <String, Object?>{
            'source_message_ids_json': jsonEncode(values.toList()..sort()),
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      }
    });
  }

  static Future<void> _backfillCharacterSelfNotes(
    DatabaseExecutor db, {
    String? characterId,
  }) async {
    final characterTables = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'characters' LIMIT 1",
    );
    if (characterTables.isEmpty) return;
    final characterColumns = await db.rawQuery('PRAGMA table_info(characters)');
    if (!characterColumns.any((row) => row['name'] == 'self_notes')) return;
    final rows = await db.query(
      'characters',
      columns: const <String>['id', 'self_notes'],
      where: characterId == null ? null : 'id = ?',
      whereArgs: characterId == null ? null : <Object?>[characterId],
    );
    final now = DateTime.now();
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final notes = _selfNoteLines(
        row['self_notes']?.toString() ?? '',
      ).toList(growable: false);
      final firstStamp = now.subtract(Duration(microseconds: notes.length));
      for (var index = 0; index < notes.length; index++) {
        final stamp = firstStamp
            .add(Duration(microseconds: index))
            .toIso8601String();
        await db.insert('character_self_notes', <String, Object?>{
          'character_id': id,
          'content': notes[index],
          'created_at': stamp,
          'updated_at': stamp,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
  }

  static Future<void> _deduplicateAllStoredSelfNotes(Database db) async {
    final rows = await db.query(
      'characters',
      columns: ['id', 'self_notes'],
      where: "TRIM(COALESCE(self_notes, '')) <> ''",
    );
    final batch = db.batch();
    var changed = false;
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final stored = row['self_notes']?.toString() ?? '';
      final cleaned = _formatSelfNotes(
        _deduplicateSelfNoteLines(_selfNoteLines(stored)),
      );
      if (cleaned == stored) continue;
      changed = true;
      batch.update(
        'characters',
        {'self_notes': cleaned},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    if (changed) await batch.commit(noResult: true);
  }

  static Future<void> clearSelfNotes(String characterId) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'characters',
      {'self_notes': ''},
      where: 'id = ?',
      whereArgs: [characterId],
    );
    await db.delete(
      'character_self_notes',
      where: 'character_id = ?',
      whereArgs: <Object?>[characterId],
    );
  }
}
