import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/services/api_adapter.dart';
import 'package:project_yanci/services/thinking_machines_service.dart';
import 'package:project_yanci/services/token_tracker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    ThinkingMachinesService.lastUsage = <String, int>{};
  });

  tearDown(() async {
    ThinkingMachinesService.lastUsage = <String, int>{};
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'Inkling real usage updates tokens without inventing provider cost',
    () async {
      ThinkingMachinesService.lastUsage = <String, int>{
        'prompt_tokens': 9999,
        'completion_tokens': 9999,
      };
      final tracker = TokenTracker();

      await tracker.recordRealUsage(
        provider: 'thinking_machines',
        model: ThinkingMachinesService.defaultModel,
        usage: const ApiUsage(promptTokens: 1200, completionTokens: 300),
        characterId: 'char-test',
      );

      expect(tracker.promptTokens, 1200);
      expect(tracker.completionTokens, 300);
      expect(tracker.totalTokens, 1500);
      expect(tracker.formatTokens(), '1.5k');

      final rows = await db.query('usage_logs');
      expect(rows, hasLength(1));
      expect(rows.single['provider'], 'thinking_machines');
      expect(rows.single['model'], ThinkingMachinesService.defaultModel);
      expect(rows.single['prompt_tokens'], 1200);
      expect(rows.single['completion_tokens'], 300);
      expect((rows.single['estimated_cost'] as num).toDouble(), 0.0);
      expect(rows.single['cost_known'], 0);

      final now = DateTime.now();
      final summary = await DatabaseHelper.getUsageSummary(
        now.subtract(const Duration(minutes: 1)),
        now.add(const Duration(minutes: 1)),
      );
      expect(summary['total_prompt'], 1200);
      expect(summary['total_completion'], 300);
      expect(summary['total_requests'], 1);
    },
  );

  test(
    'missing Inkling usage still records one cost-unknown request',
    () async {
      final tracker = TokenTracker();

      await tracker.recordRealUsage(
        provider: 'thinking_machines',
        model: ThinkingMachinesService.defaultModel,
        usage: const ApiUsage(),
      );

      expect(tracker.totalTokens, 0);
      final rows = await db.query('usage_logs');
      expect(rows, hasLength(1));
      expect(rows.single['request_kind'], 'chat');
      expect(rows.single['cost_known'], 0);
      expect(rows.single['estimated_cost'], 0.0);
    },
  );
}
