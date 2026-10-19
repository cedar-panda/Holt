import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/memory.dart';
import 'api_adapter.dart';
import 'app_error_log_service.dart';
import 'openai_compatible_service.dart';
import 'settings/api_settings.dart';
import 'settings/memory_settings.dart';
import 'memory_debug_log.dart';
import 'token_estimator.dart';
import 'token_tracker.dart';

typedef MemoryEmbeddingRequest =
    Future<List<List<double>>> Function(
      String provider,
      String model,
      List<String> texts,
      String characterId,
    );

class MemoryVectorMatch {
  final Memory memory;
  final double score;

  const MemoryVectorMatch(this.memory, this.score);
}

class MemoryVectorPairCandidate {
  final int firstId;
  final int secondId;
  final double score;

  const MemoryVectorPairCandidate({
    required this.firstId,
    required this.secondId,
    required this.score,
  });

  Map<String, Object?> toPayload() => <String, Object?>{
    'memory_id_1': firstId,
    'memory_id_2': secondId,
    'similarity': double.parse(score.toStringAsFixed(4)),
  };
}

class MemoryVectorCurationResult {
  final String provider;
  final String model;
  final int indexedCount;
  final List<MemoryVectorPairCandidate> candidates;

  const MemoryVectorCurationResult({
    required this.provider,
    required this.model,
    required this.indexedCount,
    required this.candidates,
  });
}

/// Optional semantic recall layered after the local trigram index.
///
/// Selecting no embedding model keeps this entire service dormant. Missing or
/// stale vectors are generated in small batches during the next recall, stored
/// as a derived local index, then combined with lexical results by reciprocal
/// rank fusion. Any provider failure fails open to trigram-only recall.
abstract final class MemoryVectorRecallService {
  static const int _indexBatchSize = 24;
  static const double _minimumSimilarity = 0.32;
  static const double _curationSimilarity = 0.72;
  static const int _maxCurationCandidates = 256;
  static MemoryEmbeddingRequest? _requestOverride;

  @visibleForTesting
  static void setEmbeddingRequestForTesting(MemoryEmbeddingRequest? request) {
    _requestOverride = request;
  }

  static Future<List<Memory>> searchHybrid(
    String query, {
    required String mode,
    required String characterId,
    required int limit,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final lexical = await DatabaseHelper.searchMemoriesByText(
      query,
      mode: mode,
      characterId: characterId,
      limit: limit,
      contextMode: contextMode,
      continuityId: continuityId,
    );
    late ({String provider, String model}) selection;
    try {
      selection = await MemorySettings.getEmbeddingSelection();
    } catch (_) {
      // Settings may be unavailable during early startup or isolated tests;
      // lexical recall must remain independent from the optional vector layer.
      return lexical;
    }
    if (selection.model.isEmpty) {
      MemoryDebugLog.record(
        stage: 'hybrid_recall',
        contextMode: contextMode.storageValue,
        continuityId: continuityId,
        inputCount: query.runes.length,
        resultIds: lexical.map((memory) => memory.id).whereType<int>(),
        details: const <String, Object?>{'vector_enabled': false},
      );
      return lexical;
    }

    try {
      final vector = await _searchVector(
        query,
        provider: selection.provider,
        model: selection.model,
        mode: mode,
        characterId: characterId,
        limit: limit,
        contextMode: contextMode,
        continuityId: continuityId,
      );
      final merged = mergeRankedForTesting(lexical, vector, limit: limit);
      MemoryDebugLog.record(
        stage: 'hybrid_recall',
        contextMode: contextMode.storageValue,
        continuityId: continuityId,
        provider: selection.provider,
        model: selection.model,
        inputCount: query.runes.length,
        resultIds: merged.map((memory) => memory.id).whereType<int>(),
        details: <String, Object?>{
          'vector_enabled': true,
          'trigram_hits': lexical.length,
          'vector_hits': vector.length,
        },
      );
      return merged;
    } catch (error, stackTrace) {
      developer.log(
        'Vector recall unavailable; using trigram only',
        error: error,
        stackTrace: stackTrace,
        name: 'MemoryVectorRecall',
      );
      await AppErrorLogService.record(
        error: error,
        trigger: 'functional_vector_model_recall',
        source: 'functional_model',
        provider: selection.provider,
        model: selection.model,
      );
      MemoryDebugLog.record(
        stage: 'hybrid_recall_fallback',
        contextMode: contextMode.storageValue,
        continuityId: continuityId,
        provider: selection.provider,
        model: selection.model,
        inputCount: query.runes.length,
        resultIds: lexical.map((memory) => memory.id).whereType<int>(),
        details: const <String, Object?>{'fallback': 'trigram'},
        error: error,
      );
      return lexical;
    }
  }

  /// Embeds a manual selection and returns similarity candidates only. The
  /// embedding API never decides relation types or writes merged prose.
  static Future<MemoryVectorCurationResult> analyzeSelected({
    required String characterId,
    required List<Memory> memories,
  }) async {
    final selection = await MemorySettings.getEmbeddingSelection();
    if (selection.model.isEmpty) {
      throw StateError('No embedding model selected');
    }
    final unique = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null && memory.characterId == characterId)
          memory.id!: memory,
    }.values.toList(growable: false);
    final groups = <String, List<Memory>>{};
    for (final memory in unique) {
      final key = <String>[
        memory.characterId,
        memory.contextMode.storageValue,
        memory.continuityId,
        memory.mode,
      ].join('\u0000');
      groups.putIfAbsent(key, () => <Memory>[]).add(memory);
    }

    var indexedCount = 0;
    final candidates = <MemoryVectorPairCandidate>[];
    for (final group in groups.values) {
      if (group.length < 2) continue;
      late ({Map<int, List<double>> vectors, int indexedCount}) result;
      try {
        result = await _vectorsForMemories(
          group,
          provider: selection.provider,
          model: selection.model,
          characterId: characterId,
        );
      } catch (error) {
        final scope = group.first;
        await AppErrorLogService.record(
          error: error,
          trigger: 'functional_vector_model_request',
          source: 'functional_model',
          provider: selection.provider,
          model: selection.model,
        );
        MemoryDebugLog.record(
          stage: 'vector_curation_error',
          contextMode: scope.contextMode.storageValue,
          continuityId: scope.continuityId,
          provider: selection.provider,
          model: selection.model,
          inputCount: group.length,
          resultIds: group.map((memory) => memory.id).whereType<int>(),
          error: error,
        );
        rethrow;
      }
      indexedCount += result.indexedCount;
      for (var left = 0; left < group.length; left++) {
        final leftId = group[left].id!;
        final leftVector = result.vectors[leftId];
        if (leftVector == null) continue;
        for (var right = left + 1; right < group.length; right++) {
          final rightId = group[right].id!;
          final rightVector = result.vectors[rightId];
          if (rightVector == null) continue;
          final score = _cosine(leftVector, rightVector);
          if (score < _curationSimilarity) continue;
          candidates.add(
            MemoryVectorPairCandidate(
              firstId: leftId,
              secondId: rightId,
              score: score,
            ),
          );
        }
      }
    }
    candidates.sort((left, right) => right.score.compareTo(left.score));
    final limited = candidates
        .take(_maxCurationCandidates)
        .toList(growable: false);
    final firstScope = unique.isEmpty ? null : unique.first;
    MemoryDebugLog.record(
      stage: 'vector_curation',
      contextMode: firstScope?.contextMode.storageValue ?? 'mixed',
      continuityId: groups.length == 1
          ? (firstScope?.continuityId ?? 'main')
          : 'split:${groups.length}',
      provider: selection.provider,
      model: selection.model,
      inputCount: unique.length,
      resultIds: limited
          .expand((pair) => <int>[pair.firstId, pair.secondId])
          .toSet(),
      details: <String, Object?>{
        'scope_groups': groups.length,
        'indexed': indexedCount,
        'candidate_pairs': limited.length,
        'threshold': _curationSimilarity,
      },
    );
    return MemoryVectorCurationResult(
      provider: selection.provider,
      model: selection.model,
      indexedCount: indexedCount,
      candidates: limited,
    );
  }

  static Future<({Map<int, List<double>> vectors, int indexedCount})>
  _vectorsForMemories(
    List<Memory> memories, {
    required String provider,
    required String model,
    required String characterId,
  }) async {
    final db = await DatabaseHelper.database;
    final ids = memories.map((memory) => memory.id!).toList(growable: false);
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM memory_embeddings WHERE provider = ? AND model = ? '
      'AND memory_id IN ($placeholders)',
      <Object?>[provider, model, ...ids],
    );
    final stored = <int, Map<String, Object?>>{
      for (final row in rows)
        if (row['memory_id'] is int) row['memory_id']! as int: row,
    };
    final vectors = <int, List<double>>{};
    final stale = <Memory>[];
    for (final memory in memories) {
      final row = stored[memory.id];
      if (row != null && row['content_hash'] == _contentHash(memory)) {
        final vector = _decodeVector(row['vector_json']);
        if (vector.isNotEmpty) {
          vectors[memory.id!] = vector;
          continue;
        }
      }
      stale.add(memory);
    }

    for (var offset = 0; offset < stale.length; offset += _indexBatchSize) {
      final end = min(offset + _indexBatchSize, stale.length);
      final batch = stale.sublist(offset, end);
      final generated = await (_requestOverride ?? _requestEmbeddings)(
        provider,
        model,
        batch.map(_embeddingText).toList(growable: false),
        characterId,
      );
      if (generated.length != batch.length) {
        throw const FormatException('Embedding response count mismatch');
      }
      await db.transaction((txn) async {
        for (var index = 0; index < batch.length; index++) {
          final memory = batch[index];
          final vector = generated[index];
          if (vector.isEmpty) continue;
          vectors[memory.id!] = vector;
          await txn.insert('memory_embeddings', <String, Object?>{
            'memory_id': memory.id,
            'provider': provider,
            'model': model,
            'content_hash': _contentHash(memory),
            'dimensions': vector.length,
            'vector_json': jsonEncode(vector),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
    }
    return (vectors: vectors, indexedCount: stale.length);
  }

  @visibleForTesting
  static List<Memory> mergeRankedForTesting(
    List<Memory> lexical,
    List<MemoryVectorMatch> vector, {
    required int limit,
  }) {
    final memories = <int, Memory>{};
    final scores = <int, double>{};
    for (var index = 0; index < lexical.length; index++) {
      final memory = lexical[index];
      final id = memory.id;
      if (id == null) continue;
      memories[id] = memory;
      scores[id] = (scores[id] ?? 0) + (1 / (60 + index + 1));
    }
    for (var index = 0; index < vector.length; index++) {
      final match = vector[index];
      final id = match.memory.id;
      if (id == null) continue;
      memories[id] = match.memory;
      // Similarity remains a light tie-breaker; rank carries most weight so
      // different embedding models cannot destabilize recall ordering.
      scores[id] =
          (scores[id] ?? 0) +
          (1 / (60 + index + 1)) +
          (match.score.clamp(0, 1) * 0.0001);
    }
    final ids = scores.keys.toList()
      ..sort((left, right) {
        final byScore = scores[right]!.compareTo(scores[left]!);
        if (byScore != 0) return byScore;
        return right.compareTo(left);
      });
    return ids.take(limit).map((id) => memories[id]!).toList(growable: false);
  }

  static Future<List<MemoryVectorMatch>> _searchVector(
    String query, {
    required String provider,
    required String model,
    required String mode,
    required String characterId,
    required int limit,
    required ContextMode contextMode,
    required String continuityId,
  }) async {
    final db = await DatabaseHelper.database;
    final memoryRows = await db.query(
      'memories',
      where:
          "status = 'active' AND mode = ? AND character_id = ? "
          'AND context_mode = ? AND continuity_id = ?',
      whereArgs: <Object?>[
        mode,
        characterId,
        contextMode.storageValue,
        continuityId,
      ],
      orderBy: 'updated_at DESC',
      limit: 1000,
    );
    if (memoryRows.isEmpty) return const <MemoryVectorMatch>[];
    final memories = memoryRows.map(Memory.fromMap).toList(growable: false);

    Future<List<Map<String, Object?>>> loadStoredRows() => db.rawQuery(
      '''
      SELECT e.* FROM memory_embeddings e
      JOIN memories m ON m.id = e.memory_id
      WHERE e.provider = ? AND e.model = ?
        AND m.status = 'active' AND m.mode = ? AND m.character_id = ?
        AND m.context_mode = ? AND m.continuity_id = ?
      ''',
      <Object?>[
        provider,
        model,
        mode,
        characterId,
        contextMode.storageValue,
        continuityId,
      ],
    );

    final storedRows = await loadStoredRows();
    final stored = <int, Map<String, Object?>>{
      for (final row in storedRows)
        if (row['memory_id'] is int) row['memory_id']! as int: row,
    };
    final stale = <Memory>[];
    for (final memory in memories) {
      final id = memory.id;
      if (id == null) continue;
      final row = stored[id];
      if (row == null || row['content_hash'] != _contentHash(memory)) {
        stale.add(memory);
        if (stale.length == _indexBatchSize) break;
      }
    }

    final texts = <String>[query, ...stale.map(_embeddingText)];
    final vectors = await (_requestOverride ?? _requestEmbeddings)(
      provider,
      model,
      texts,
      characterId,
    );
    if (vectors.length != texts.length || vectors.first.isEmpty) {
      throw const FormatException('Embedding response count mismatch');
    }
    final queryVector = vectors.first;
    if (stale.isNotEmpty) {
      await db.transaction((txn) async {
        for (var index = 0; index < stale.length; index++) {
          final memory = stale[index];
          final vector = vectors[index + 1];
          if (memory.id == null || vector.isEmpty) continue;
          await txn.insert('memory_embeddings', <String, Object?>{
            'memory_id': memory.id,
            'provider': provider,
            'model': model,
            'content_hash': _contentHash(memory),
            'dimensions': vector.length,
            'vector_json': jsonEncode(vector),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
    }

    final refreshedRows = stale.isEmpty ? storedRows : await loadStoredRows();
    final memoryById = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    final matches = <MemoryVectorMatch>[];
    for (final row in refreshedRows) {
      final id = row['memory_id'];
      if (id is! int) continue;
      final memory = memoryById[id];
      if (memory == null || row['content_hash'] != _contentHash(memory)) {
        continue;
      }
      final vector = _decodeVector(row['vector_json']);
      if (vector.length != queryVector.length) continue;
      final score = _cosine(queryVector, vector);
      if (score >= _minimumSimilarity) {
        matches.add(MemoryVectorMatch(memory, score));
      }
    }
    matches.sort((left, right) => right.score.compareTo(left.score));
    return matches.take(limit).toList(growable: false);
  }

  static Future<List<List<double>>> _requestEmbeddings(
    String provider,
    String model,
    List<String> texts,
    String characterId,
  ) async {
    final key = await ApiSettings.getApiKeyForProvider(provider);
    if (key.trim().isEmpty) throw StateError('Embedding API key is missing');
    final client = http.Client();
    try {
      late http.Response response;
      if (provider == 'gemini') {
        final normalizedModel = model.startsWith('models/')
            ? model.substring('models/'.length)
            : model;
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          '$normalizedModel:batchEmbedContents',
        );
        response = await client
            .post(
              uri,
              headers: <String, String>{
                'Content-Type': 'application/json',
                'x-goog-api-key': key,
              },
              body: jsonEncode(<String, Object?>{
                'requests': <Map<String, Object?>>[
                  for (final text in texts)
                    <String, Object?>{
                      'model': 'models/$normalizedModel',
                      'taskType': 'SEMANTIC_SIMILARITY',
                      'content': <String, Object?>{
                        'parts': <Map<String, String>>[
                          <String, String>{'text': text},
                        ],
                      },
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));
      } else {
        final uri = switch (provider) {
          'openrouter' => Uri.parse('https://openrouter.ai/api/v1/embeddings'),
          'deepinfra' => Uri.parse(
            'https://api.deepinfra.com/v1/openai/embeddings',
          ),
          _ => OpenAICompatibleService.embeddingsUriForBase(
            await ApiSettings.getOaiCompatBaseUrl(),
          ),
        };
        response = await client
            .post(
              uri,
              headers: <String, String>{
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $key',
              },
              body: jsonEncode(<String, Object?>{
                'model': model,
                'input': texts,
              }),
            )
            .timeout(const Duration(seconds: 30));
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Embedding request failed (${response.statusCode})',
          uri: response.request?.url,
        );
      }
      final decoded = jsonDecode(response.body);
      final vectors = provider == 'gemini'
          ? _parseGeminiVectors(decoded)
          : _parseOpenAiVectors(decoded);
      final usage = decoded is Map ? decoded['usage'] : null;
      final promptTokens = usage is Map && usage['prompt_tokens'] is num
          ? (usage['prompt_tokens'] as num).round()
          : texts.fold<int>(
              0,
              (sum, text) => sum + TokenEstimator.estimate(text),
            );
      final actualCost = usage is Map ? usage['cost'] : null;
      await TokenTracker().recordRealUsage(
        provider: provider,
        model: model,
        characterId: characterId,
        usage: ApiUsage(
          promptTokens: promptTokens,
          diagnostics: <String, Object?>{
            if (actualCost is num) 'actual_cost_usd': actualCost.toDouble(),
            'operation': 'memory_embedding',
          },
        ),
        requestKind: ApiRequestKind.embedding,
      );
      return vectors;
    } finally {
      client.close();
    }
  }

  static List<List<double>> _parseOpenAiVectors(Object? decoded) {
    if (decoded is! Map || decoded['data'] is! List) {
      throw const FormatException('Invalid embedding response');
    }
    final rows = (decoded['data'] as List).whereType<Map>().toList()
      ..sort((left, right) {
        final a = (left['index'] as num?)?.toInt() ?? 0;
        final b = (right['index'] as num?)?.toInt() ?? 0;
        return a.compareTo(b);
      });
    return rows.map((row) => _numberList(row['embedding'])).toList();
  }

  static List<List<double>> _parseGeminiVectors(Object? decoded) {
    if (decoded is! Map || decoded['embeddings'] is! List) {
      throw const FormatException('Invalid Gemini embedding response');
    }
    return (decoded['embeddings'] as List).whereType<Map>().map((row) {
      return _numberList(row['values']);
    }).toList();
  }

  static List<double> _numberList(Object? raw) {
    if (raw is! List) return const <double>[];
    return raw.whereType<num>().map((value) => value.toDouble()).toList();
  }

  static List<double> _decodeVector(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <double>[];
    try {
      return _numberList(jsonDecode(raw));
    } catch (_) {
      return const <double>[];
    }
  }

  static String _embeddingText(Memory memory) => <String>[
    memory.category,
    memory.content,
    if (memory.triggers.trim().isNotEmpty) memory.triggers,
  ].join('\n');

  static String _contentHash(Memory memory) =>
      sha256.convert(utf8.encode(_embeddingText(memory))).toString();

  static double _cosine(List<double> left, List<double> right) {
    if (left.isEmpty || left.length != right.length) return -1;
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    final denominator = sqrt(leftNorm) * sqrt(rightNorm);
    return denominator == 0 ? -1 : dot / denominator;
  }
}
