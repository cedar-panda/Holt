part of 'database.dart';

class _UsageStore {
  static Future<WebSearchUsageReservationResult>
  reserveWebSearchProviderLaunches({
    required String reservationId,
    required String conversationId,
    required String characterId,
    required String turnId,
    required int generationSerial,
    required String planStrategy,
    required List<({String provider, String model, String route})> routes,
    required String budgetDay,
    required int dailyProviderLaunchCap,
    required String reservedAt,
    required String expiresAt,
  }) async {
    if (routes.isEmpty || routes.length > 2) {
      throw ArgumentError.value(
        routes,
        'routes',
        'Expected one or two routes.',
      );
    }
    if ((planStrategy == 'single' && routes.length != 1) ||
        (planStrategy == 'dual' && routes.length != 2) ||
        (planStrategy != 'single' && planStrategy != 'dual')) {
      throw ArgumentError.value(
        planStrategy,
        'planStrategy',
        'Plan strategy does not match its routes.',
      );
    }
    if (dailyProviderLaunchCap < 1) {
      throw ArgumentError.value(
        dailyProviderLaunchCap,
        'dailyProviderLaunchCap',
        'The daily provider-launch cap must be positive.',
      );
    }
    final db = await DatabaseHelper.database;
    return db.transaction<WebSearchUsageReservationResult>((txn) async {
      // A grant that was never claimed can be released safely. A claimed
      // execution that vanished with the process is uncertain, so both a
      // claimed dispatch window and an already-launched provider settle as
      // unknown instead of silently granting the budget back or remaining in
      // a non-final state forever.
      await txn.rawUpdate(
        "UPDATE web_search_usage_logs SET status = 'released', settled_at = ? "
        "WHERE status = 'reserved' AND expires_at <= ?",
        <Object?>[reservedAt, reservedAt],
      );
      await txn.rawUpdate(
        "UPDATE web_search_usage_logs SET status = 'unknown', settled_at = ?, "
        "cost_certainty = 'unknown' "
        "WHERE status IN ('claimed', 'launched') "
        'AND expires_at <= ?',
        <Object?>[reservedAt, reservedAt],
      );

      final existingTurn = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['id'],
        where:
            'conversation_id = ? AND turn_id = ? AND generation_serial = ? '
            'AND logical_slot = 1',
        whereArgs: <Object?>[conversationId, turnId, generationSerial],
        limit: 1,
      );
      if (existingTurn.isNotEmpty) {
        return WebSearchUsageReservationResult.duplicateTurn;
      }

      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM web_search_usage_logs '
        "WHERE budget_day = ? AND status != 'released'",
        <Object?>[budgetDay],
      );
      final reservedOrUsed = Sqflite.firstIntValue(countRows) ?? 0;
      if (reservedOrUsed + routes.length > dailyProviderLaunchCap) {
        return WebSearchUsageReservationResult.dailyLimitExceeded;
      }

      final batch = txn.batch();
      for (var index = 0; index < routes.length; index++) {
        final route = routes[index];
        batch.insert('web_search_usage_logs', <String, Object?>{
          'reservation_id': reservationId,
          'logical_slot': index == 0 ? 1 : 0,
          'conversation_id': conversationId,
          'character_id': characterId,
          'turn_id': turnId,
          'generation_serial': generationSerial,
          'budget_day': budgetDay,
          'plan_strategy': planStrategy,
          'provider': route.provider,
          'provider_model': route.model,
          'provider_route': route.route,
          'status': 'reserved',
          'reserved_at': reservedAt,
          'expires_at': expiresAt,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
      }
      await batch.commit(noResult: true);
      return WebSearchUsageReservationResult.reserved;
    });
  }

  static Future<bool> bindWebSearchReservationToCall({
    required String reservationId,
    required String callId,
    required String now,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['status', 'call_id', 'expires_at'],
        where: 'reservation_id = ?',
        whereArgs: <Object?>[reservationId],
      );
      if (rows.isEmpty ||
          rows.any(
            (row) =>
                row['status'] != 'reserved' ||
                row['call_id'] != null ||
                (row['expires_at']! as String).compareTo(now) <= 0,
          )) {
        return false;
      }
      final reusedCall = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['id'],
        where: 'call_id = ? AND logical_slot = 1',
        whereArgs: <Object?>[callId],
        limit: 1,
      );
      if (reusedCall.isNotEmpty) return false;
      final changed = await txn.update(
        'web_search_usage_logs',
        <String, Object?>{'call_id': callId},
        where:
            'reservation_id = ? AND status = ? AND call_id IS NULL '
            'AND expires_at > ?',
        whereArgs: <Object?>[reservationId, 'reserved', now],
      );
      return changed == rows.length;
    });
  }

  static Future<bool> claimWebSearchReservation({
    required String reservationId,
    required String callId,
    required String budgetDay,
    required String claimedAt,
    required String executionExpiresAt,
  }) async {
    final db = await DatabaseHelper.database;
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'web_search_usage_logs',
        columns: const <String>['status', 'call_id', 'expires_at'],
        where: 'reservation_id = ? AND budget_day = ?',
        whereArgs: <Object?>[reservationId, budgetDay],
      );
      if (rows.isEmpty ||
          rows.any(
            (row) =>
                row['status'] != 'reserved' ||
                row['call_id'] != callId ||
                (row['expires_at']! as String).compareTo(claimedAt) <= 0,
          )) {
        return false;
      }
      final changed = await txn.update(
        'web_search_usage_logs',
        <String, Object?>{
          'status': 'claimed',
          'claimed_at': claimedAt,
          'expires_at': executionExpiresAt,
        },
        where:
            'reservation_id = ? AND call_id = ? AND budget_day = ? AND status = ? '
            'AND expires_at > ?',
        whereArgs: <Object?>[
          reservationId,
          callId,
          budgetDay,
          'reserved',
          claimedAt,
        ],
      );
      return changed == rows.length;
    });
  }

  static Future<bool> markWebSearchProviderLaunched({
    required String reservationId,
    required String callId,
    required String provider,
    required String providerModel,
    required String providerRoute,
    required String launchedAt,
  }) async {
    final db = await DatabaseHelper.database;
    final changed = await db.update(
      'web_search_usage_logs',
      <String, Object?>{'status': 'launched', 'launched_at': launchedAt},
      where:
          'reservation_id = ? AND call_id = ? AND provider = ? '
          'AND provider_model = ? AND provider_route = ? AND status = ?',
      whereArgs: <Object?>[
        reservationId,
        callId,
        provider,
        providerModel,
        providerRoute,
        'claimed',
      ],
    );
    return changed == 1;
  }

  static Future<bool> settleWebSearchProviderLaunch({
    required String reservationId,
    required String callId,
    required String provider,
    required String providerModel,
    required String providerRoute,
    required String outcome,
    required String settledAt,
    required int searchRequests,
    required int promptTokens,
    required int completionTokens,
    required double? actualCostUsd,
    required String costCertainty,
  }) async {
    if (!const <String>{
      'success',
      'failure',
      'cancelled',
      'unknown',
    }.contains(outcome)) {
      throw ArgumentError.value(outcome, 'outcome', 'Invalid launch outcome.');
    }
    final db = await DatabaseHelper.database;
    final changed = await db.update(
      'web_search_usage_logs',
      <String, Object?>{
        'status': outcome,
        'settled_at': settledAt,
        'search_requests': searchRequests,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'actual_cost_usd': actualCostUsd,
        'cost_certainty': costCertainty,
      },
      where:
          'reservation_id = ? AND call_id = ? AND provider = ? '
          'AND provider_model = ? AND provider_route = ? AND status = ?',
      whereArgs: <Object?>[
        reservationId,
        callId,
        provider,
        providerModel,
        providerRoute,
        'launched',
      ],
    );
    return changed == 1;
  }

  static Future<int> releaseUnlaunchedWebSearchReservation({
    required String reservationId,
    String? callId,
    required String settledAt,
  }) async {
    final db = await DatabaseHelper.database;
    final callClause = callId == null ? '' : ' AND call_id = ?';
    return db.rawUpdate(
      "UPDATE web_search_usage_logs SET status = 'released', settled_at = ? "
      "WHERE reservation_id = ? AND status IN ('reserved', 'claimed')"
      '$callClause',
      <Object?>[settledAt, reservationId, ?callId],
    );
  }

  static Future<int> getWebSearchProviderLaunchCount(String budgetDay) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) FROM web_search_usage_logs '
      "WHERE budget_day = ? AND status NOT IN ('reserved', 'claimed', 'released')",
      <Object?>[budgetDay],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  static Future<void> logUsage({
    required String provider,
    required String model,
    String characterId = 'default',
    String conversationId = '',
    int promptTokens = 0,
    int completionTokens = 0,
    int cacheHitTokens = 0,
    int cacheCreationTokens = 0,
    double estimatedCost = 0.0,
    String requestKind = 'unknown',
    bool costKnown = false,
  }) async {
    final db = await DatabaseHelper.database;
    await db.insert('usage_logs', {
      'timestamp': DateTime.now().toIso8601String(),
      'provider': provider,
      'model': model,
      'character_id': characterId,
      'conversation_id': conversationId,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'cache_hit_tokens': cacheHitTokens,
      'cache_creation_tokens': cacheCreationTokens,
      'estimated_cost': estimatedCost,
      'request_kind': requestKind,
      'cost_known': costKnown ? 1 : 0,
    });
  }

  static Future<Map<String, dynamic>> getUsageSummary(
    DateTime from,
    DateTime to,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT 
          SUM(prompt_tokens) as total_prompt,
          SUM(completion_tokens) as total_completion,
          SUM(cache_hit_tokens) as total_cache_hit,
          SUM(CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END) as total_cost,
          SUM(CASE WHEN cost_known = 1 THEN 1 ELSE 0 END) as known_cost_requests,
          COUNT(*) as total_requests
        FROM usage_logs
        WHERE timestamp >= ? AND timestamp < ?
      ''',
      [from.toIso8601String(), to.toIso8601String()],
    );
    final result = rows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(rows.first);
    final searchRows = await db.rawQuery(
      '''
        SELECT
          COUNT(*) AS total_requests,
          SUM(prompt_tokens) AS total_prompt,
          SUM(completion_tokens) AS total_completion,
          SUM(CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN actual_cost_usd ELSE 0 END) AS total_cost,
          SUM(CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
            THEN 1 ELSE 0 END) AS known_cost_requests
        FROM web_search_usage_logs
        WHERE launched_at >= ? AND launched_at < ?
          AND status NOT IN ('reserved', 'claimed', 'released')
        ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final search = searchRows.isEmpty
        ? const <String, Object?>{}
        : searchRows.first;
    int addInt(String key) =>
        ((result[key] as num?)?.toInt() ?? 0) +
        ((search[key] as num?)?.toInt() ?? 0);
    result['total_requests'] = addInt('total_requests');
    result['total_prompt'] = addInt('total_prompt');
    result['total_completion'] = addInt('total_completion');
    result['known_cost_requests'] = addInt('known_cost_requests');
    result['total_cost'] =
        ((result['total_cost'] as num?)?.toDouble() ?? 0) +
        ((search['total_cost'] as num?)?.toDouble() ?? 0);
    return result;
  }

  static Future<List<Map<String, dynamic>>> getDailyUsage(
    DateTime from,
    DateTime to,
  ) async {
    final db = await DatabaseHelper.database;
    return await db.rawQuery(
      '''
        SELECT
          date,
          SUM(prompt) AS prompt,
          SUM(completion) AS completion,
          SUM(cache_hit) AS cache_hit,
          SUM(cost) AS cost,
          SUM(known_cost_requests) AS known_cost_requests
        FROM (
          SELECT
            SUBSTR(timestamp, 1, 10) AS date,
            prompt_tokens AS prompt,
            completion_tokens AS completion,
            cache_hit_tokens AS cache_hit,
            CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END AS cost,
            CASE WHEN cost_known = 1 THEN 1 ELSE 0 END AS known_cost_requests
          FROM usage_logs
          WHERE timestamp >= ? AND timestamp < ?
          UNION ALL
          SELECT
            SUBSTR(launched_at, 1, 10) AS date,
            prompt_tokens AS prompt,
            completion_tokens AS completion,
            0 AS cache_hit,
            CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
              THEN actual_cost_usd ELSE 0 END AS cost,
            CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
              THEN 1 ELSE 0 END AS known_cost_requests
          FROM web_search_usage_logs
          WHERE launched_at >= ? AND launched_at < ?
            AND status NOT IN ('reserved', 'claimed', 'released')
        )
        GROUP BY date
        ORDER BY date
      ''',
      <Object?>[
        from.toIso8601String(),
        to.toIso8601String(),
        from.toIso8601String(),
        to.toIso8601String(),
      ],
    );
  }

  static Future<List<Map<String, dynamic>>> getUsageByModel(
    DateTime from,
    DateTime to,
  ) async {
    final db = await DatabaseHelper.database;
    return await db.rawQuery(
      '''
        SELECT
          provider,
          model,
          SUM(total_tokens) AS total_tokens,
          SUM(cost) AS cost,
          SUM(known_cost_requests) AS known_cost_requests,
          SUM(requests) AS requests
        FROM (
          SELECT
            provider,
            model,
            prompt_tokens + completion_tokens AS total_tokens,
            CASE WHEN cost_known = 1 THEN estimated_cost ELSE 0 END AS cost,
            CASE WHEN cost_known = 1 THEN 1 ELSE 0 END AS known_cost_requests,
            1 AS requests
          FROM usage_logs
          WHERE timestamp >= ? AND timestamp < ?
          UNION ALL
          SELECT
            provider,
            provider_model AS model,
            prompt_tokens + completion_tokens AS total_tokens,
            CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
              THEN actual_cost_usd ELSE 0 END AS cost,
            CASE WHEN cost_certainty = 'known' AND actual_cost_usd IS NOT NULL
              THEN 1 ELSE 0 END AS known_cost_requests,
            1 AS requests
          FROM web_search_usage_logs
          WHERE launched_at >= ? AND launched_at < ?
            AND status NOT IN ('reserved', 'claimed', 'released')
        )
        GROUP BY provider, model
        ORDER BY cost DESC, requests DESC
      ''',
      <Object?>[
        from.toIso8601String(),
        to.toIso8601String(),
        from.toIso8601String(),
        to.toIso8601String(),
      ],
    );
  }

  static Future<List<Map<String, dynamic>>> getUsageByRequestKind(
    DateTime from,
    DateTime to,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
        SELECT request_kind, COUNT(*) AS requests
        FROM usage_logs
        WHERE timestamp >= ? AND timestamp < ?
        GROUP BY request_kind
        ORDER BY requests DESC, request_kind ASC
        ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final result = rows.map(Map<String, dynamic>.from).toList(growable: true);
    final searchRows = await db.rawQuery(
      '''
        SELECT COUNT(*) AS requests
        FROM web_search_usage_logs
        WHERE launched_at >= ? AND launched_at < ?
          AND status NOT IN ('reserved', 'claimed', 'released')
        ''',
      <Object?>[from.toIso8601String(), to.toIso8601String()],
    );
    final searchRequests = searchRows.isEmpty
        ? 0
        : (searchRows.first['requests'] as num?)?.toInt() ?? 0;
    if (searchRequests > 0) {
      result.add(<String, dynamic>{
        'request_kind': 'web_search',
        'requests': searchRequests,
      });
    }
    result.sort((left, right) {
      final byCount = ((right['requests'] as num?)?.toInt() ?? 0).compareTo(
        (left['requests'] as num?)?.toInt() ?? 0,
      );
      if (byCount != 0) return byCount;
      return '${left['request_kind']}'.compareTo('${right['request_kind']}');
    });
    return result;
  }
}
