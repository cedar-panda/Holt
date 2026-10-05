part of 'database.dart';

/// Full-text memory search kept outside the already-large database facade.
///
/// FTS5 provides SQLite's native BM25 ranking. Android system SQLite commonly
/// ships without FTS5, so the runtime schema falls back to FTS4 and this class
/// calculates the same BM25 family score from FTS4 `matchinfo` statistics.
class _MemorySearch {
  @visibleForTesting
  static double bm25FromMatchInfoForTesting(Uint8List matchInfo) =>
      _bm25FromMatchInfo(matchInfo);

  static Future<void> rebuildIndex() async {
    final db = await DatabaseHelper.database;
    await _DatabaseSchema.rebuildMemoryFts(db);
  }

  static Future<void> ensureRuntimeSchema() async {
    final db = await DatabaseHelper.database;
    await _DatabaseSchema._ensureRuntimeSchema(db);
  }

  static Future<List<Memory>> search(
    String query, {
    required String mode,
    required String characterId,
    required int limit,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    if (query.trim().isEmpty) return [];
    final db = await DatabaseHelper.database;
    final boundedLimit = limit.clamp(1, 100);
    final backend = await _DatabaseSchema._detectMemoryFtsBackend(db);
    final terms = _buildFtsQuery(query, backend);
    final results = <Memory>[];
    final seenIds = <int>{};
    var usedTextFallback = false;

    if (terms.isNotEmpty) {
      final rows = switch (backend) {
        _MemoryFtsBackend.fts5Trigram ||
        _MemoryFtsBackend.fts5Unicode => await _searchFts5(
          db,
          terms: terms,
          mode: mode,
          characterId: characterId,
          limit: boundedLimit,
          contextMode: contextMode,
          continuityId: continuityId,
        ),
        _MemoryFtsBackend.fts4 => await _searchFts4(
          db,
          terms: terms,
          mode: mode,
          characterId: characterId,
          limit: boundedLimit,
          contextMode: contextMode,
          continuityId: continuityId,
        ),
        null => const <Map<String, Object?>>[],
      };
      for (final row in rows) {
        final memory = Memory.fromMap(row);
        if (memory.id == null || seenIds.add(memory.id!)) {
          results.add(memory);
        }
      }
    }

    if (results.length < boundedLimit) {
      usedTextFallback = true;
      await _appendTextFallback(
        db,
        query: query,
        mode: mode,
        characterId: characterId,
        limit: boundedLimit,
        results: results,
        seenIds: seenIds,
        contextMode: contextMode,
        continuityId: continuityId,
      );
    }
    MemoryDebugLog.record(
      stage: 'trigram_search',
      contextMode: contextMode.storageValue,
      continuityId: continuityId,
      inputCount: query.runes.length,
      resultIds: results.map((memory) => memory.id).whereType<int>(),
      details: <String, Object?>{
        'backend': backend?.name ?? 'text_fallback',
        'fts_query': terms.isNotEmpty,
        'text_fallback': usedTextFallback,
        'limit': boundedLimit,
      },
    );
    return results;
  }

  static Future<List<Map<String, Object?>>> _searchFts5(
    Database db, {
    required String terms,
    required String mode,
    required String characterId,
    required int limit,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    try {
      return await db.rawQuery(
        '''
        SELECT m.*, bm25(memories_fts, 1.0, 0.5) AS _rank
        FROM memories_fts
        JOIN memories m ON m.id = memories_fts.rowid
        WHERE memories_fts MATCH ?
          AND m.status = 'active'
          AND m.mode = ?
          AND m.character_id = ?
          AND m.context_mode = ? AND m.continuity_id = ?
        ORDER BY _rank
        LIMIT ?
        ''',
        [
          terms,
          mode,
          characterId,
          contextMode.storageValue,
          continuityId,
          limit,
        ],
      );
    } catch (error) {
      developer.log(
        'FTS5 BM25 search failed',
        error: error,
        name: 'DatabaseHelper',
      );
      return const [];
    }
  }

  static Future<List<Map<String, Object?>>> _searchFts4(
    Database db, {
    required String terms,
    required String mode,
    required String characterId,
    required int limit,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    try {
      final rows = await db.rawQuery(
        '''
        SELECT m.*, matchinfo(memories_fts, 'pcnalx') AS _match_info
        FROM memories_fts
        JOIN memories m ON m.id = memories_fts.docid
        WHERE memories_fts MATCH ?
          AND m.status = 'active'
          AND m.mode = ?
          AND m.character_id = ?
          AND m.context_mode = ? AND m.continuity_id = ?
        ''',
        [terms, mode, characterId, contextMode.storageValue, continuityId],
      );
      final ranked =
          rows
              .map(
                (row) =>
                    (row: row, score: _bm25FromMatchInfo(row['_match_info'])),
              )
              .toList()
            ..sort((left, right) => right.score.compareTo(left.score));
      return ranked.take(limit).map((entry) => entry.row).toList();
    } catch (error) {
      developer.log(
        'FTS4 BM25 search failed',
        error: error,
        name: 'DatabaseHelper',
      );
      return const [];
    }
  }

  static double _bm25FromMatchInfo(Object? raw) {
    if (raw is! Uint8List || raw.lengthInBytes < 12) return 0;
    final bytes = ByteData.sublistView(raw);
    if (bytes.lengthInBytes % 4 != 0) return 0;
    final values = List<int>.generate(
      bytes.lengthInBytes ~/ 4,
      (index) => bytes.getUint32(index * 4, Endian.host),
      growable: false,
    );
    final phraseCount = values[0];
    final columnCount = values[1];
    final documentCount = values[2];
    final expected = 3 + (2 * columnCount) + (3 * phraseCount * columnCount);
    if (phraseCount <= 0 ||
        columnCount <= 0 ||
        documentCount <= 0 ||
        values.length < expected) {
      return 0;
    }

    const k1 = 1.2;
    const b = 0.75;
    const columnWeights = <double>[1.0, 0.5];
    final averageLengthStart = 3;
    final rowLengthStart = averageLengthStart + columnCount;
    final phraseStatsStart = rowLengthStart + columnCount;
    var score = 0.0;

    for (var phrase = 0; phrase < phraseCount; phrase++) {
      for (var column = 0; column < columnCount; column++) {
        final statsIndex =
            phraseStatsStart + (3 * ((phrase * columnCount) + column));
        final termFrequency = values[statsIndex].toDouble();
        final documentsWithTerm = values[statsIndex + 2].toDouble();
        if (termFrequency <= 0 || documentsWithTerm <= 0) continue;

        final averageLength = max(
          1.0,
          values[averageLengthStart + column].toDouble(),
        );
        final documentLength = values[rowLengthStart + column].toDouble();
        final inverseDocumentFrequency = log(
          1 +
              ((documentCount - documentsWithTerm + 0.5) /
                  (documentsWithTerm + 0.5)),
        );
        final normalization =
            termFrequency +
            (k1 * (1 - b + (b * documentLength / averageLength)));
        final weight = column < columnWeights.length
            ? columnWeights[column]
            : 1.0;
        score +=
            weight *
            inverseDocumentFrequency *
            ((termFrequency * (k1 + 1)) / normalization);
      }
    }
    return score;
  }

  static Future<void> _appendTextFallback(
    Database db, {
    required String query,
    required String mode,
    required String characterId,
    required int limit,
    required List<Memory> results,
    required Set<int> seenIds,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final fragments = _buildLikeSearchFragments(query);
    if (fragments.isEmpty) return;
    final clauses = List.filled(
      fragments.length,
      "(content LIKE ? ESCAPE '\\' OR triggers LIKE ? ESCAPE '\\')",
    ).join(' OR ');
    final args = <Object?>[
      mode,
      characterId,
      contextMode.storageValue,
      continuityId,
    ];
    for (final fragment in fragments) {
      final pattern = DatabaseHelper._likeContains(fragment);
      args
        ..add(pattern)
        ..add(pattern);
    }
    args.add(limit * 3);
    final rows = await db.rawQuery('''
      SELECT * FROM memories
      WHERE mode = ? AND character_id = ? AND context_mode = ?
        AND continuity_id = ? AND status = 'active'
        AND ($clauses)
      LIMIT ?
      ''', args);
    final ranked =
        rows.map((row) {
          final haystack = '${row['content'] ?? ''} ${row['triggers'] ?? ''}'
              .toLowerCase();
          final lexicalHits = fragments
              .where((fragment) => haystack.contains(fragment.toLowerCase()))
              .length;
          return (
            row: row,
            lexicalHits: lexicalHits,
            mentionCount: (row['mention_count'] as int?) ?? 0,
            updatedAt: row['updated_at']?.toString() ?? '',
          );
        }).toList()..sort((left, right) {
          final lexical = right.lexicalHits.compareTo(left.lexicalHits);
          if (lexical != 0) return lexical;
          final mentions = right.mentionCount.compareTo(left.mentionCount);
          if (mentions != 0) return mentions;
          return right.updatedAt.compareTo(left.updatedAt);
        });
    for (final entry in ranked) {
      final row = entry.row;
      final memory = Memory.fromMap(row);
      if (memory.id == null || seenIds.add(memory.id!)) {
        results.add(memory);
        if (results.length == limit) break;
      }
    }
  }

  static String _buildFtsQuery(String input, _MemoryFtsBackend? backend) {
    if (backend == _MemoryFtsBackend.fts5Trigram) {
      return _buildLikeSearchFragments(
        input,
      ).map((fragment) => '"${fragment.replaceAll('"', '""')}"').join(' OR ');
    }
    final cjkRe = RegExp(r'[　-ヿ一-鿿＀-￯]');
    final tokens = <String>{};
    final nonCjk = input.replaceAll(cjkRe, ' ').trim();
    if (nonCjk.isNotEmpty) {
      for (final word in nonCjk.split(RegExp(r'\s+'))) {
        final cleaned = word.replaceAll(RegExp(r'["\*\(\)\{\}\[\]:^~]'), '');
        if (cleaned.length >= 2) tokens.add(cleaned);
      }
    }
    if (tokens.isEmpty) return '';
    return tokens.map((token) => '"$token"').join(' OR ');
  }

  static List<String> _buildLikeSearchFragments(String input) {
    const maxFragments = 48;
    final cjkChar = RegExp(r'[　-ヿ一-鿿＀-￯]');
    final candidates = <String>[];
    final seen = <String>{};
    var cjkRun = <String>[];

    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    void flushCjkRun() {
      if (cjkRun.isEmpty) return;
      if (cjkRun.length <= 3) {
        addCandidate(cjkRun.join());
      } else {
        for (var index = 0; index <= cjkRun.length - 3; index++) {
          addCandidate(cjkRun.sublist(index, index + 3).join());
        }
      }
      cjkRun = <String>[];
    }

    for (final rune in input.runes) {
      final character = String.fromCharCode(rune);
      if (cjkChar.hasMatch(character)) {
        cjkRun.add(character);
      } else {
        flushCjkRun();
      }
    }
    flushCjkRun();

    final nonCjk = input.replaceAll(cjkChar, ' ');
    for (final rawWord in nonCjk.split(RegExp(r'\s+'))) {
      final word = rawWord
          .replaceAll(RegExp(r'["\*\(\)\{\}\[\]:\^~]'), '')
          .trim();
      if (word.length >= 3) addCandidate(word);
    }

    if (candidates.length <= maxFragments) return candidates;
    // 長句均勻抽樣，避免只索引前半句，丟掉中後段關鍵詞。
    final sampled = <String>[];
    final sampledSeen = <String>{};
    for (var i = 0; i < maxFragments; i++) {
      final index = (i * (candidates.length - 1) / (maxFragments - 1)).round();
      final candidate = candidates[index];
      if (sampledSeen.add(candidate)) sampled.add(candidate);
    }
    return sampled;
  }
}
