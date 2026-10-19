import '../memory/database.dart';

class ChatWindowMemoryRecord {
  const ChatWindowMemoryRecord({
    required this.id,
    required this.category,
    required this.content,
    required this.triggers,
    required this.isPermanent,
    required this.createdAt,
  });

  final int id;
  final String category;
  final String content;
  final String triggers;
  final bool isPermanent;
  final DateTime? createdAt;
}

class ChatWindowStatsSnapshot {
  const ChatWindowStatsSnapshot({
    required this.recordedTokens,
    required this.summaryCount,
    required this.worldbookCount,
    required this.cacheHitCount,
    required this.cacheReportingAvailable,
    required this.memories,
  });

  final int recordedTokens;
  final int summaryCount;
  final int worldbookCount;
  final int cacheHitCount;
  final bool cacheReportingAvailable;
  final List<ChatWindowMemoryRecord> memories;
}

/// Read-only window telemetry plus narrowly scoped memory maintenance.
///
/// Historical usage rows created before schema v78 do not have a window id,
/// so they are deliberately excluded instead of being guessed from character
/// or timestamp. Summary, memory, and cache-hit counts are recovered from
/// their authoritative window-bound tables and therefore include old data.
class ChatWindowStatsService {
  ChatWindowStatsService._();

  static Future<ChatWindowStatsSnapshot> load({
    required String conversationId,
    required String provider,
    required String model,
  }) async {
    final db = await DatabaseHelper.database;
    final usageRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS total_tokens,
        COALESCE(SUM(CASE WHEN request_kind = 'worldbook' THEN 1 ELSE 0 END), 0)
          AS worldbook_count,
        COALESCE(SUM(CASE WHEN cache_hit_tokens > 0 THEN 1 ELSE 0 END), 0)
          AS cache_hit_count
      FROM usage_logs
      WHERE conversation_id = ?
      ''',
      <Object?>[conversationId],
    );
    final summaryRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS count
      FROM context_summaries
      WHERE source_conversation_id = ?
      ''',
      <Object?>[conversationId],
    );
    final cacheRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS count
      FROM messages
      WHERE conversation_id = ? AND is_user = 0 AND cache_hit = 1
      ''',
      <Object?>[conversationId],
    );
    final memoryRows = await db.query(
      'memories',
      columns: const <String>[
        'id',
        'category',
        'content',
        'triggers',
        'is_permanent',
        'created_at',
      ],
      where: 'source_conversation_id = ? AND status = ?',
      whereArgs: <Object?>[conversationId, 'active'],
      orderBy: 'created_at ASC, id ASC',
    );
    final usage = usageRows.isEmpty
        ? const <String, Object?>{}
        : usageRows.first;
    final messageCacheHitCount = cacheRows.isEmpty
        ? 0
        : _asInt(cacheRows.first['count']);
    final usageCacheHitCount = _asInt(usage['cache_hit_count']);
    final cacheHitCount = usageCacheHitCount > messageCacheHitCount
        ? usageCacheHitCount
        : messageCacheHitCount;

    return ChatWindowStatsSnapshot(
      recordedTokens: _asInt(usage['total_tokens']),
      summaryCount: summaryRows.isEmpty
          ? 0
          : _asInt(summaryRows.first['count']),
      worldbookCount: _asInt(usage['worldbook_count']),
      cacheHitCount: cacheHitCount,
      cacheReportingAvailable:
          cacheHitCount > 0 || _providerReportsCacheHits(provider),
      memories: memoryRows
          .map(
            (row) => ChatWindowMemoryRecord(
              id: _asInt(row['id']),
              category: row['category']?.toString() ?? '',
              content: row['content']?.toString() ?? '',
              triggers: row['triggers']?.toString() ?? '',
              isPermanent: _asInt(row['is_permanent']) == 1,
              createdAt: DateTime.tryParse(row['created_at']?.toString() ?? ''),
            ),
          )
          .where((record) => record.id > 0)
          .toList(growable: false),
    );
  }

  static Future<void> updateMemory({
    required int memoryId,
    required String conversationId,
    required String content,
    required String triggers,
  }) async {
    final normalizedContent = content.trim();
    if (normalizedContent.isEmpty) {
      throw ArgumentError.value(content, 'content', 'must not be empty');
    }
    final db = await DatabaseHelper.database;
    final changed = await db.update(
      'memories',
      <String, Object?>{
        'content': normalizedContent,
        'triggers': triggers.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND source_conversation_id = ? AND status = ?',
      whereArgs: <Object?>[memoryId, conversationId, 'active'],
    );
    if (changed != 1) {
      throw StateError('Window memory is no longer active.');
    }
  }

  static Future<bool> archiveMemory({
    required ChatWindowMemoryRecord memory,
    required String characterId,
  }) {
    return DatabaseHelper.archiveMemory(
      memory.id,
      '窗口狀態面板手動移至積灰小盒子',
      characterId: characterId,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Only show a numeric zero for first-party adapters whose response format
  /// exposes cache usage. Custom/OpenAI-compatible routes vary by upstream, so
  /// a missing hit there is shown as an em dash rather than a fabricated zero.
  static bool _providerReportsCacheHits(String provider) {
    return switch (provider.trim().toLowerCase()) {
      'openrouter' ||
      'gemini' ||
      'deepseek' ||
      'qwen' ||
      'xai' ||
      'bedrock' ||
      'aws_bedrock' => true,
      _ => false,
    };
  }
}
