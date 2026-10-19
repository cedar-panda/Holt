import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/model_action_protocol.dart';
import 'package:project_yanci/services/rp_story_correction_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-14T00:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '顧遠',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('rp_storylines', <String, Object?>{
      'character_id': 'char-a',
      'id': 'story-a',
      'name': '第一線',
      'status': 'active',
      'is_default': 1,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('conversations', <String, Object?>{
      'id': 'conv-a',
      'character_id': 'char-a',
      'context_mode': 'rp',
      'continuity_id': 'story-a',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('rp_character_timeline', <String, Object?>{
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'source_conversation_id': 'conv-a',
      'type': 'event',
      'event_key': 'inn_raid',
      'narrative_layer': 'main',
      'value': '眾人正準備前往客棧抄查',
      'story_time_text': '正月初一',
      'sequence_order': 10,
      'source_message_ids': '[10]',
      'source_evidence': '準備前往客棧',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('rp_story_states', <String, Object?>{
      'id': 'state-a',
      'character_id': 'char-a',
      'continuity_id': 'story-a',
      'state_key': 'plot.inn_raid',
      'state_type': 'plot',
      'narrative_layer': 'main',
      'value': '客棧抄查尚未開始',
      'status': 'active',
      'source_message_ids': '[10]',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test(
    'latest user evidence can correct existing timeline and plot state',
    () async {
      final messageId = await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '不對，客棧抄查早已結束，人贓已押進大牢。',
          isUser: true,
        ),
      );
      final reply =
          '''收到，我會沿用修正後的事實。
${ModelActionProtocol.jsonStart}
{"actions":[
  {"type":"rp.timeline.correct","arguments":{"event_key":"inn_raid","value":"客棧抄查已結束，人贓已押進大牢","story_time":"正月初一","evidence":"客棧抄查早已結束，人贓已押進大牢"}},
  {"type":"rp.state.correct","arguments":{"state_key":"plot.inn_raid","value":"客棧抄查已結案","status":"resolved","evidence":"客棧抄查早已結束，人贓已押進大牢"}}
]}
${ModelActionProtocol.jsonEnd}''';

      final logs = await RpStoryCorrectionService.applyReplyActions(
        reply,
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        sourceMessageId: messageId,
      );

      expect(logs, hasLength(2));
      final timeline = (await db.query('rp_character_timeline')).single;
      expect(timeline['value'], '客棧抄查已結束，人贓已押進大牢');
      expect(timeline['scene'], 'model_user_correction');
      expect(timeline['sequence_order'], 10);
      final state = (await db.query('rp_story_states')).single;
      expect(state['value'], '客棧抄查已結案');
      expect(state['status'], 'resolved');
      expect(state['user_edited'], 1);
    },
  );

  test(
    'missing exact evidence or invented key cannot modify story records',
    () async {
      final messageId = await DatabaseHelper.insertMessage(
        Message(
          conversationId: 'conv-a',
          characterId: 'char-a',
          text: '請繼續。',
          isUser: true,
        ),
      );
      final reply =
          '''
${ModelActionProtocol.jsonStart}
{"actions":[{"type":"rp.timeline.correct","arguments":{"event_key":"invented","value":"被改寫","evidence":"請繼續"}}]}
${ModelActionProtocol.jsonEnd}''';

      final logs = await RpStoryCorrectionService.applyReplyActions(
        reply,
        characterId: 'char-a',
        continuityId: 'story-a',
        sourceConversationId: 'conv-a',
        sourceMessageId: messageId,
      );

      expect(logs, isEmpty);
      expect(
        (await db.query('rp_character_timeline')).single['value'],
        '眾人正準備前往客棧抄查',
      );
    },
  );
}
