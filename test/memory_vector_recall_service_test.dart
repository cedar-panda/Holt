import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/memory_vector_recall_service.dart';
import 'package:project_yanci/services/settings/memory_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    await MemorySettings.saveEmbeddingSelection(
      provider: 'openrouter',
      model: 'demo-embedding',
    );
    MemoryVectorRecallService.setEmbeddingRequestForTesting(
      (provider, model, texts, characterId) async => texts
          .map((text) {
            if (text.contains('受傷') || text.contains('包紮')) {
              return <double>[1, 0];
            }
            return <double>[0, 1];
          })
          .toList(growable: false),
    );
  });

  tearDown(() async {
    MemoryVectorRecallService.setEmbeddingRequestForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'vector recall adds semantic matches without crossing story lines',
    () async {
      await DatabaseHelper.insertMemories(<Memory>[
        _memory(1, 'route-red', '晏辭替昭昭包紮手臂的傷口'),
        _memory(2, 'route-red', '他們在渡口買了桂花糕'),
        _memory(3, 'route-blue', '藍線也曾有人替主角包紮'),
      ]);

      final results = await MemoryVectorRecallService.searchHybrid(
        '誰在我受傷時照顧我',
        mode: 'story',
        characterId: 'char-a',
        limit: 5,
        contextMode: ContextMode.rp,
        continuityId: 'route-red',
      );

      expect(results.map((memory) => memory.id), contains(1));
      expect(results.map((memory) => memory.id), isNot(contains(3)));
      final embeddings = await db.query('memory_embeddings');
      expect(
        embeddings.map((row) => row['memory_id']),
        containsAll(<int>[1, 2]),
      );
      expect(embeddings.map((row) => row['memory_id']), isNot(contains(3)));
    },
  );

  test('manual vector curation never pairs different story lines', () async {
    final memories = <Memory>[
      _memory(1, 'route-red', '晏辭替昭昭包紮手臂的傷口'),
      _memory(2, 'route-red', '昭昭受傷後由晏辭照顧'),
      _memory(3, 'route-blue', '藍線也曾有人替主角包紮'),
    ];
    await DatabaseHelper.insertMemories(memories);

    final result = await MemoryVectorRecallService.analyzeSelected(
      characterId: 'char-a',
      memories: memories,
    );

    expect(result.candidates, hasLength(1));
    expect(
      <int>{
        result.candidates.single.firstId,
        result.candidates.single.secondId,
      },
      <int>{1, 2},
    );
  });
}

Memory _memory(int id, String continuityId, String content) => Memory(
  id: id,
  characterId: 'char-a',
  contextMode: ContextMode.rp,
  continuityId: continuityId,
  mode: 'story',
  category: '重要事件',
  content: content,
  createdAt: DateTime.utc(2026, 9, 24, 0, id),
  updatedAt: DateTime.utc(2026, 9, 24, 0, id),
);
