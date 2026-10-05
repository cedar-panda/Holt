import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/dream_curation_service.dart';
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

  test('dream batches never cross Daily, RP, or story-line scopes', () async {
    final memories = <Memory>[
      _memory(1, ContextMode.daily, 'main', '日常桂花烏龍約定'),
      _memory(2, ContextMode.daily, 'main', '桂花烏龍是日常喜好'),
      _memory(3, ContextMode.rp, 'route-red', '紅線琥珀吊墜伏筆'),
      _memory(4, ContextMode.rp, 'route-red', '琥珀吊墜藏有紅線線索'),
      _memory(5, ContextMode.rp, 'route-blue', '藍線白鶴印信伏筆'),
      _memory(6, ContextMode.rp, 'route-blue', '白鶴印信屬於藍線書院'),
    ];
    for (final memory in memories) {
      await db.insert('memories', memory.toMap());
    }

    final batches = await DreamCurationService.buildSmartBatchesForTesting(
      newMemories: <Memory>[memories[0], memories[2], memories[4]],
      allMemories: memories,
      characterId: 'char-a',
    );

    expect(batches, hasLength(3));
    for (final batch in batches) {
      expect(batch.length, greaterThanOrEqualTo(2));
      final scopes = batch
          .map(
            (memory) => (memory.contextMode, memory.continuityId, memory.mode),
          )
          .toSet();
      expect(scopes, hasLength(1));
    }
  });

  test('dream prompt is localized and defines every relation type', () {
    for (final locale in <String>['zh_TW', 'zh_CN', 'en']) {
      final prompt = DreamCurationService.dreamSystemPromptForTesting(locale);
      expect(prompt, contains('related'));
      expect(prompt, contains('same_event'));
      expect(prompt, contains('temporal'));
      expect(prompt, contains('duplicate_candidate'));
      expect(prompt, contains('conflict_update'));
    }

    expect(
      DreamCurationService.dreamSystemPromptForTesting('zh_TW'),
      contains('核心事實實質重複'),
    );
    expect(
      DreamCurationService.dreamSystemPromptForTesting('zh_CN'),
      contains('核心事实实质重复'),
    );
    expect(
      DreamCurationService.dreamSystemPromptForTesting('en'),
      contains('same concrete event'),
    );
  });
}

Memory _memory(
  int id,
  ContextMode contextMode,
  String continuityId,
  String content,
) => Memory(
  id: id,
  characterId: 'char-a',
  contextMode: contextMode,
  continuityId: continuityId,
  mode: 'story',
  category: '伏筆',
  content: content,
  triggers: content,
  createdAt: DateTime.utc(2026, 9, 24, 0, id),
  updatedAt: DateTime.utc(2026, 9, 24, 0, id),
);
