import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/web_search_turn_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late DateTime now;
  late int tokenSequence;
  late WebSearchTurnCoordinator coordinator;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    now = DateTime(2026, 8, 9, 10);
    tokenSequence = 0;
    coordinator = WebSearchTurnCoordinator(
      clock: () => now,
      randomToken: () => 'test_token_${tokenSequence++}',
    );
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('live grant binds exact plan and can be claimed only once', () async {
    final binding = _binding(
      query: '  Taiwan   weather  ',
      locale: 'zh_TW',
      plan: WebSearchTurnPlan.single(
        WebSearchProviderRoute.openRouterExa('openai/gpt-5-mini'),
      ),
    );
    final grant = await coordinator.issueGrant(binding: binding);

    expect(grant.query, 'Taiwan weather');
    expect(grant.locale, 'zh-TW');
    expect(grant.toContextMetadata(), <String, Object?>{
      WebSearchTurnGrant.metadataKey: grant.id,
    });
    expect(
      () => grant.plan.routes.add(
        WebSearchProviderRoute.geminiGoogleSearch('gemini-2.5-flash'),
      ),
      throwsUnsupportedError,
    );

    expect(
      await coordinator.consumeForPermission(
        grantId: grant.id,
        callId: 'call-1',
        conversationId: binding.conversationId,
        characterId: binding.characterId,
        query: 'Taiwan weather',
        turnId: binding.turnId,
        generationSerial: binding.generationSerial,
      ),
      isTrue,
    );
    expect(
      await coordinator.consumeForPermission(
        grantId: grant.id,
        callId: 'call-2',
        conversationId: binding.conversationId,
        characterId: binding.characterId,
        query: binding.query,
      ),
      isFalse,
    );

    final claim = await coordinator.claimForHandler('call-1');
    expect(claim, isNotNull);
    expect(await coordinator.claimForHandler('call-1'), isNull);
    expect(claim!.query, 'Taiwan weather');
    expect(claim.locale, 'zh-TW');
    expect(claim.maxResults, 3);
    expect(claim.routes.single.providerName, 'openRouter');
    expect(claim.routes.single.model, 'openai/gpt-5-mini');
    expect(
      claim.routes.single.route,
      'openrouter:web_search:exa:zdr-no-fallback',
    );

    final route = claim.routes.single;
    await coordinator.markProviderLaunched(claim: claim, route: route);
    await coordinator.settleProvider(
      claim: claim,
      route: route,
      settlement: WebSearchProviderSettlement(
        outcome: WebSearchProviderLaunchOutcome.success,
        searchRequests: 1,
        promptTokens: 12,
        completionTokens: 34,
        actualCostUsd: 0.002,
        costCertainty: WebSearchLedgerCostCertainty.known,
      ),
    );
    await coordinator.finishExecution(claim);

    final row = (await db.query('web_search_usage_logs')).single;
    expect(row['status'], 'success');
    expect(row['call_id'], 'call-1');
    expect(row['provider'], 'openRouter');
    expect(row['provider_model'], 'openai/gpt-5-mini');
    expect(row['provider_route'], 'openrouter:web_search:exa:zdr-no-fallback');
    expect(row['search_requests'], 1);
    expect(row['prompt_tokens'], 12);
    expect(row['completion_tokens'], 34);
    expect(row['actual_cost_usd'], 0.002);
    expect(
      await DatabaseHelper.getWebSearchProviderLaunchCount('2026-08-09'),
      1,
    );
  });

  test(
    'a mismatched runtime query burns the grant and never authorizes a call',
    () async {
      final binding = _binding(
        plan: WebSearchTurnPlan.single(
          WebSearchProviderRoute.geminiGoogleSearch('gemini-2.5-flash'),
        ),
      );
      final grant = await coordinator.issueGrant(binding: binding);

      expect(
        await coordinator.consumeForPermission(
          grantId: grant.id,
          callId: 'call-drift',
          conversationId: binding.conversationId,
          characterId: binding.characterId,
          query: 'different query',
          turnId: binding.turnId,
          generationSerial: binding.generationSerial,
        ),
        isFalse,
      );
      expect(await coordinator.claimForHandler('call-drift'), isNull);
      expect(
        (await db.query('web_search_usage_logs')).single['status'],
        'released',
      );

      await expectLater(
        coordinator.issueGrant(binding: binding),
        throwsA(
          isA<WebSearchTurnCoordinatorException>().having(
            (error) => error.code,
            'code',
            WebSearchTurnCoordinatorError.duplicateLogicalCall,
          ),
        ),
      );
    },
  );

  test(
    'concurrent permission attempts yield exactly one authorized call',
    () async {
      final binding = _binding();
      final grant = await coordinator.issueGrant(binding: binding);

      final results = await Future.wait(<Future<bool>>[
        _consume(coordinator, grant, binding, 'call-a'),
        _consume(coordinator, grant, binding, 'call-b'),
      ]);

      expect(results.where((value) => value), hasLength(1));
      final winningCall = results.first ? 'call-a' : 'call-b';
      final losingCall = results.first ? 'call-b' : 'call-a';
      expect(await coordinator.claimForHandler(winningCall), isNotNull);
      expect(await coordinator.claimForHandler(losingCall), isNull);
    },
  );

  test(
    'dual reservation is atomic and charges provider-launch capacity',
    () async {
      final dual = _binding(
        plan: WebSearchTurnPlan.dual(
          WebSearchProviderRoute.geminiGoogleSearch('gemini-2.5-flash'),
          WebSearchProviderRoute.openRouterExa('openai/gpt-5-mini'),
        ),
      );
      final grant = await coordinator.issueGrant(
        binding: dual,
        dailyProviderLaunchCap: 2,
      );
      final rows = await db.query(
        'web_search_usage_logs',
        where: 'reservation_id = ?',
        whereArgs: <Object?>[grant.reservationId],
        orderBy: 'id',
      );
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['logical_slot']), <Object?>[1, 0]);
      expect(rows.map((row) => row['provider']), <Object?>[
        'gemini',
        'openRouter',
      ]);

      await expectLater(
        coordinator.issueGrant(
          binding: _binding(turnId: 'turn-2'),
          dailyProviderLaunchCap: 2,
        ),
        throwsA(
          isA<WebSearchTurnCoordinatorException>().having(
            (error) => error.code,
            'code',
            WebSearchTurnCoordinatorError.dailyBudgetExceeded,
          ),
        ),
      );

      expect(await coordinator.revokeGrant(grant.id), isTrue);
      expect(
        await DatabaseHelper.getWebSearchProviderLaunchCount('2026-08-09'),
        0,
      );
      expect(
        await coordinator.issueGrant(
          binding: _binding(turnId: 'turn-3'),
          dailyProviderLaunchCap: 2,
        ),
        isA<WebSearchTurnGrant>(),
      );
    },
  );

  test('replay uses one-shot grants without writing usage rows', () async {
    final binding = _binding();
    final grant = await coordinator.issueGrant(
      binding: binding,
      mode: WebSearchTurnRunMode.replay,
    );
    expect(await _consume(coordinator, grant, binding, 'replay-call'), isTrue);
    final claim = (await coordinator.claimForHandler('replay-call'))!;
    expect(claim.mode, WebSearchTurnRunMode.replay);
    await expectLater(
      coordinator.markProviderLaunched(
        claim: claim,
        route: claim.routes.single,
      ),
      throwsA(
        isA<WebSearchTurnCoordinatorException>().having(
          (error) => error.code,
          'code',
          WebSearchTurnCoordinatorError.routeRejected,
        ),
      ),
    );
    await coordinator.finishExecution(claim);
    expect(await db.query('web_search_usage_logs'), isEmpty);

    await expectLater(
      coordinator.issueGrant(
        binding: binding,
        mode: WebSearchTurnRunMode.replay,
      ),
      throwsA(
        isA<WebSearchTurnCoordinatorException>().having(
          (error) => error.code,
          'code',
          WebSearchTurnCoordinatorError.duplicateLogicalCall,
        ),
      ),
    );
  });

  test('expired permission cannot be claimed and releases capacity', () async {
    final binding = _binding();
    final grant = await coordinator.issueGrant(binding: binding);
    expect(await _consume(coordinator, grant, binding, 'slow-call'), isTrue);
    now = now.add(const Duration(seconds: 46));

    expect(await coordinator.claimForHandler('slow-call'), isNull);
    expect(
      (await db.query('web_search_usage_logs')).single['status'],
      'released',
    );
    expect(
      await DatabaseHelper.getWebSearchProviderLaunchCount('2026-08-09'),
      0,
    );
  });

  test('every launched provider reaches an explicit final state', () async {
    final expected = <WebSearchProviderLaunchOutcome, String>{
      WebSearchProviderLaunchOutcome.failure: 'failure',
      WebSearchProviderLaunchOutcome.cancelled: 'cancelled',
      WebSearchProviderLaunchOutcome.unknown: 'unknown',
    };
    var serial = 0;
    for (final entry in expected.entries) {
      final binding = _binding(
        turnId: 'outcome-${entry.value}',
        generationSerial: serial++,
      );
      final grant = await coordinator.issueGrant(
        binding: binding,
        dailyProviderLaunchCap: 20,
      );
      final callId = 'call-${entry.value}';
      expect(await _consume(coordinator, grant, binding, callId), isTrue);
      final claim = (await coordinator.claimForHandler(callId))!;
      await coordinator.markProviderLaunched(
        claim: claim,
        route: claim.routes.single,
      );
      await coordinator.settleProvider(
        claim: claim,
        route: claim.routes.single,
        settlement: WebSearchProviderSettlement(outcome: entry.key),
      );
      await coordinator.finishExecution(claim);
    }

    final rows = await db.query('web_search_usage_logs', orderBy: 'id');
    expect(rows.map((row) => row['status']), expected.values);
    expect(
      await DatabaseHelper.getWebSearchProviderLaunchCount('2026-08-09'),
      3,
    );
  });

  test(
    'finish marks launched routes unknown and releases unlaunched dual route',
    () async {
      final binding = _binding(
        plan: WebSearchTurnPlan.dual(
          WebSearchProviderRoute.openRouterExa('openai/gpt-5-mini'),
          WebSearchProviderRoute.geminiGoogleSearch('gemini-2.5-flash'),
        ),
      );
      final grant = await coordinator.issueGrant(binding: binding);
      expect(
        await _consume(coordinator, grant, binding, 'partial-dual'),
        isTrue,
      );
      final claim = (await coordinator.claimForHandler('partial-dual'))!;
      await coordinator.markProviderLaunched(
        claim: claim,
        route: claim.routes.first,
      );
      await coordinator.finishExecution(claim);

      final rows = await db.query('web_search_usage_logs', orderBy: 'id');
      expect(rows.map((row) => row['status']), <Object?>[
        'unknown',
        'released',
      ]);
      expect(
        await DatabaseHelper.getWebSearchProviderLaunchCount('2026-08-09'),
        1,
      );
    },
  );

  test(
    'a launched row left by process death settles unknown after lease',
    () async {
      final binding = _binding(turnId: 'crashed-turn');
      final grant = await coordinator.issueGrant(binding: binding);
      expect(
        await coordinator.consumeForPermission(
          grantId: grant.id,
          callId: 'crashed-call',
          conversationId: binding.conversationId,
          characterId: binding.characterId,
          query: binding.query,
        ),
        isTrue,
      );
      final claim = (await coordinator.claimForHandler('crashed-call'))!;
      await coordinator.markProviderLaunched(
        claim: claim,
        route: claim.routes.single,
      );

      // Simulate a process restart: the new coordinator has no in-memory claim,
      // but the durable execution lease is now expired.
      now = now.add(const Duration(days: 1, minutes: 2, seconds: 1));
      final restarted = WebSearchTurnCoordinator(
        clock: () => now,
        randomToken: () => 'restart_token_${tokenSequence++}',
      );
      await restarted.issueGrant(
        binding: _binding(turnId: 'next-turn', generationSerial: 2),
      );

      final crashedRow = (await db.query(
        'web_search_usage_logs',
        where: 'reservation_id = ?',
        whereArgs: <Object?>[grant.reservationId],
      )).single;
      expect(crashedRow['status'], 'unknown');
      expect(crashedRow['cost_certainty'], 'unknown');
      expect(crashedRow['settled_at'], isNotNull);
    },
  );

  test(
    'ledger schema contains no query, source, result, or key columns',
    () async {
      final columns = await db.rawQuery(
        'PRAGMA table_info(web_search_usage_logs)',
      );
      final names = columns
          .map((row) => row['name']!.toString().toLowerCase())
          .toList(growable: false);
      expect(names, isNot(contains('query')));
      expect(names.where((name) => name.contains('source')), isEmpty);
      expect(names.where((name) => name.contains('result')), isEmpty);
      expect(names.where((name) => name.contains('key')), isEmpty);
    },
  );
}

Future<bool> _consume(
  WebSearchTurnCoordinator coordinator,
  WebSearchTurnGrant grant,
  WebSearchTurnBinding binding,
  String callId,
) {
  return coordinator.consumeForPermission(
    grantId: grant.id,
    callId: callId,
    conversationId: binding.conversationId,
    characterId: binding.characterId,
    query: binding.query,
    turnId: binding.turnId,
    generationSerial: binding.generationSerial,
  );
}

WebSearchTurnBinding _binding({
  String conversationId = 'conversation-1',
  String characterId = 'character-1',
  String turnId = 'turn-1',
  int generationSerial = 1,
  String query = 'safe query',
  String locale = 'zh-TW',
  WebSearchTurnPlan? plan,
}) {
  return WebSearchTurnBinding(
    conversationId: conversationId,
    characterId: characterId,
    turnId: turnId,
    generationSerial: generationSerial,
    query: query,
    locale: locale,
    maxResults: 3,
    plan:
        plan ??
        WebSearchTurnPlan.single(
          WebSearchProviderRoute.openRouterExa('openai/gpt-5-mini'),
        ),
  );
}
