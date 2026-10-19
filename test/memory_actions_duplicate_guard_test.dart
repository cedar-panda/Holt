import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/memory.dart';
import 'package:project_yanci/services/locale_strings.dart';
import 'package:project_yanci/services/memory_actions.dart';
import 'package:project_yanci/services/memory_guard_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await L.setLocale('zh_TW');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
  });

  tearDown(() async {
    MemoryActions.releaseWindow('conv-a');
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'model memo waits for confirmation before entering the memory library',
    () async {
      const reply = '<memo>[偏好] 小禾喜歡喝熱牛奶 @熱牛奶</memo>知道了。';
      expect(
        await MemoryActions.processReply(
          reply,
          characterId: 'char-a',
          mode: 'romance',
          windowId: 'conv-a',
        ),
        '知道了。',
      );
      expect(await _activeCount(db), 0);
      final proposalId = MemoryActions.lastProposalIdsFor('conv-a').single;

      await MemoryActions.processReply(
        reply,
        characterId: 'char-a',
        mode: 'romance',
        windowId: 'conv-a',
      );
      expect(await _activeCount(db), 0);
      expect(MemoryActions.lastProposalIdsFor('conv-a'), isEmpty);
      final pending = await db.rawQuery(
        "SELECT COUNT(*) AS count FROM pending_memory_actions WHERE status = 'pending'",
      );
      expect(pending.single['count'], 1);

      expect(
        await MemoryGuardService.execute(
          proposalId,
          'char-a',
          createDecision: MemoryGuardService.createDecisionUseNew,
        ),
        'completed',
      );
      expect(await _activeCount(db), 1);

      await MemoryActions.processReply(
        reply,
        characterId: 'char-a',
        mode: 'romance',
        windowId: 'conv-a',
      );
      expect(
        MemoryActions.lastActionLogFor('conv-a').single,
        contains('已略過重複記憶'),
      );
    },
  );

  test('ambiguous model memo becomes a message-bindable proposal', () async {
    await db.insert(
      'memories',
      Memory(
        characterId: 'char-a',
        mode: 'romance',
        category: '重要事件',
        content: '小禾喜歡下雨天窩在家裡慢慢看電影',
        confidence: 'high',
      ).toMap(),
    );

    await MemoryActions.processReply(
      '<memo>[重要事件] 小禾喜歡下雨天在家裡看電影 @下雨天</memo>',
      characterId: 'char-a',
      mode: 'romance',
      windowId: 'conv-a',
    );

    expect(await _activeCount(db), 1);
    expect(MemoryActions.lastProposalIdsFor('conv-a'), hasLength(1));
    expect(MemoryActions.lastActionLogFor('conv-a').single, contains('提案匣'));
  });

  test('one model reply can create at most two memory proposals', () async {
    const reply = '''
<memo>[偏好] 小禾喜歡雨聲 @雨聲</memo>
<memo>[約定] 小禾答應週末看電影 @週末</memo>
<memo>[重要事件] 小禾搬進新住處 @搬家</memo>
''';

    final visible = await MemoryActions.processReply(
      reply,
      characterId: 'char-a',
      mode: 'romance',
      windowId: 'conv-a',
    );

    expect(visible, isEmpty);
    expect(visible, isNot(contains('<memo>')));
    expect(MemoryActions.lastProposalIdsFor('conv-a'), hasLength(2));
    final pending = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM pending_memory_actions WHERE status = 'pending'",
    );
    expect(pending.single['count'], 2);
  });
}

Future<int> _activeCount(Database db) async {
  final rows = await db.rawQuery(
    "SELECT COUNT(*) AS count FROM memories WHERE status = 'active'",
  );
  return rows.single['count'] as int;
}
