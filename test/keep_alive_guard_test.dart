import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('only one concurrent keep-alive caller can claim a ping', () async {
    final now = DateTime.utc(2026, 8, 19, 7);

    final claims = await Future.wait([
      DatabaseHelper.tryClaimKeepAlivePing(
        conversationId: 'conversation-a',
        characterId: 'character-a',
        leaseToken: 'conversation-a:1',
        now: now,
      ),
      DatabaseHelper.tryClaimKeepAlivePing(
        conversationId: 'conversation-a',
        characterId: 'character-a',
        leaseToken: 'conversation-a:1',
        now: now,
      ),
    ]);

    expect(claims.where((claimed) => claimed).length, 1);
  });

  test(
    'successful ping keeps stale callers out until the cooldown expires',
    () async {
      final startedAt = DateTime.utc(2026, 8, 19, 7);
      const conversationId = 'conversation-a';
      const characterId = 'character-a';
      const leaseToken = 'conversation-a:1';

      expect(
        await DatabaseHelper.tryClaimKeepAlivePing(
          conversationId: conversationId,
          characterId: characterId,
          leaseToken: leaseToken,
          now: startedAt,
        ),
        isTrue,
      );
      expect(
        await DatabaseHelper.completeKeepAlivePing(
          conversationId: conversationId,
          characterId: characterId,
          leaseToken: leaseToken,
          completedAt: startedAt,
        ),
        isTrue,
      );
      expect(
        await DatabaseHelper.tryClaimKeepAlivePing(
          conversationId: conversationId,
          characterId: characterId,
          leaseToken: leaseToken,
          now: startedAt.add(const Duration(minutes: 49)),
        ),
        isFalse,
      );
      expect(
        await DatabaseHelper.tryClaimKeepAlivePing(
          conversationId: conversationId,
          characterId: characterId,
          leaseToken: leaseToken,
          now: startedAt.add(const Duration(minutes: 51)),
        ),
        isTrue,
      );
    },
  );

  test('a new lease can reset the previous window guard', () async {
    final now = DateTime.utc(2026, 8, 19, 7);
    await DatabaseHelper.resetKeepAlivePingGuard(
      conversationId: 'conversation-a',
      characterId: 'character-a',
      leaseToken: 'conversation-a:2',
      now: now,
    );

    expect(
      await DatabaseHelper.tryClaimKeepAlivePing(
        conversationId: 'conversation-a',
        characterId: 'character-a',
        leaseToken: 'conversation-a:2',
        now: now,
      ),
      isTrue,
    );
    expect(
      await DatabaseHelper.tryClaimKeepAlivePing(
        conversationId: 'conversation-a',
        characterId: 'character-a',
        leaseToken: 'conversation-a:1',
        now: now,
      ),
      isFalse,
    );
  });
}
