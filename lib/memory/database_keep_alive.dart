part of 'database.dart';

class _KeepAliveGuardStore {
  static String get _keepAlivePingGuardTable =>
      DatabaseHelper._keepAlivePingGuardTable;

  static Future<bool> tryClaimKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime now,
    Duration claimFor = const Duration(minutes: 10),
  }) async {
    final db = await DatabaseHelper.database;
    final nowUtc = now.toUtc();
    final claimUntil = nowUtc.add(claimFor).toIso8601String();

    return db.transaction<bool>((txn) async {
      await txn.execute('''
          CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            conversation_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            lease_token TEXT NOT NULL,
            next_allowed_at TEXT NOT NULL,
            in_flight_until TEXT
          )
        ''');

      final rows = await txn.query(
        DatabaseHelper._keepAlivePingGuardTable,
        where: 'id = 1',
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.first;
        if (row['conversation_id'] != conversationId ||
            row['character_id'] != characterId ||
            row['lease_token'] != leaseToken) {
          // 舊 isolate 不能覆蓋新窗口的 guard。
          return false;
        }

        final inFlightUntil = DateTime.tryParse(
          row['in_flight_until']?.toString() ?? '',
        );
        final nextAllowedAt = DateTime.tryParse(
          row['next_allowed_at']?.toString() ?? '',
        );
        if (inFlightUntil != null && inFlightUntil.isAfter(nowUtc)) {
          return false;
        }
        if (nextAllowedAt != null && nextAllowedAt.isAfter(nowUtc)) {
          return false;
        }
      }

      final values = <String, Object?>{
        'id': 1,
        'conversation_id': conversationId,
        'character_id': characterId,
        'lease_token': leaseToken,
        'next_allowed_at': nowUtc.toIso8601String(),
        'in_flight_until': claimUntil,
      };
      if (rows.isEmpty) {
        await txn.insert(DatabaseHelper._keepAlivePingGuardTable, values);
      } else {
        final changed = await txn.update(
          DatabaseHelper._keepAlivePingGuardTable,
          {'in_flight_until': claimUntil},
          where: 'id = 1 AND lease_token = ?',
          whereArgs: [leaseToken],
        );
        if (changed != 1) return false;
      }
      return true;
    });
  }

  static Future<bool> completeKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime completedAt,
    Duration cooldown = const Duration(minutes: 50),
  }) async {
    final db = await DatabaseHelper.database;
    final nextAllowedAt = completedAt.toUtc().add(cooldown).toIso8601String();
    return db.transaction<bool>((txn) async {
      await txn.execute('''
          CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            conversation_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            lease_token TEXT NOT NULL,
            next_allowed_at TEXT NOT NULL,
            in_flight_until TEXT
          )
        ''');
      final changed = await txn.update(
        DatabaseHelper._keepAlivePingGuardTable,
        {'next_allowed_at': nextAllowedAt, 'in_flight_until': null},
        where: '''
            id = 1 AND conversation_id = ? AND character_id = ? AND lease_token = ?
          ''',
        whereArgs: [conversationId, characterId, leaseToken],
      );
      return changed == 1;
    });
  }

  static Future<void> releaseKeepAlivePing({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime releasedAt,
  }) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      await txn.execute('''
          CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            conversation_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            lease_token TEXT NOT NULL,
            next_allowed_at TEXT NOT NULL,
            in_flight_until TEXT
          )
        ''');
      await txn.update(
        DatabaseHelper._keepAlivePingGuardTable,
        {
          'next_allowed_at': releasedAt.toUtc().toIso8601String(),
          'in_flight_until': null,
        },
        where: '''
            id = 1 AND conversation_id = ? AND character_id = ? AND lease_token = ?
          ''',
        whereArgs: [conversationId, characterId, leaseToken],
      );
    });
  }

  static Future<void> resetKeepAlivePingGuard({
    required String conversationId,
    required String characterId,
    required String leaseToken,
    required DateTime now,
  }) async {
    final db = await DatabaseHelper.database;
    await db.transaction<void>((txn) async {
      await txn.execute('''
          CREATE TABLE IF NOT EXISTS $_keepAlivePingGuardTable (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            conversation_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            lease_token TEXT NOT NULL,
            next_allowed_at TEXT NOT NULL,
            in_flight_until TEXT
          )
        ''');
      await txn.insert(
        DatabaseHelper._keepAlivePingGuardTable,
        {
          'id': 1,
          'conversation_id': conversationId,
          'character_id': characterId,
          'lease_token': leaseToken,
          'next_allowed_at': now.toUtc().toIso8601String(),
          'in_flight_until': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }
}
