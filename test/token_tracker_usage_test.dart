import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/token_tracker.dart';
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

  test('counts every request but trusts only provider-reported cost', () async {
    final tracker = TokenTracker();

    await tracker.recordRealUsage(
      provider: 'gemini',
      model: 'summary-model',
      usage: const ApiUsage(),
      requestKind: ApiRequestKind.summary,
    );
    await tracker.recordRealUsage(
      provider: 'openrouter',
      model: 'chat-model',
      usage: const ApiUsage(promptTokens: 100, completionTokens: 50),
      requestKind: ApiRequestKind.chat,
    );
    await tracker.recordRealUsage(
      provider: 'openrouter',
      model: 'chat-model',
      usage: const ApiUsage(
        promptTokens: 30,
        completionTokens: 20,
        diagnostics: <String, Object?>{'actual_cost_usd': 0.012},
      ),
      requestKind: ApiRequestKind.chat,
    );

    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 1));
    final to = now.add(const Duration(days: 1));
    final summary = await DatabaseHelper.getUsageSummary(from, to);
    final kinds = await DatabaseHelper.getUsageByRequestKind(from, to);

    expect(summary['total_requests'], 3);
    expect(summary['total_prompt'], 130);
    expect(summary['total_completion'], 70);
    expect(summary['known_cost_requests'], 1);
    expect((summary['total_cost'] as num).toDouble(), closeTo(0.012, 0.000001));

    final byKind = <String, int>{
      for (final row in kinds)
        row['request_kind'] as String: (row['requests'] as num).toInt(),
    };
    expect(byKind[ApiRequestKind.summary], 1);
    expect(byKind[ApiRequestKind.chat], 2);
  });
}
