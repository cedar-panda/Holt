import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/message.dart';
import 'package:project_yanci/services/ios_reply_background_task.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory directory;
  late File journal;
  late Message source;
  final calls = <MethodCall>[];
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosReplyBackgroundTask.channel, (call) async {
          calls.add(call);
          return null;
        });
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    final now = DateTime.now().toIso8601String();
    await db.insert('conversations', {
      'id': 'window',
      'character_id': 'char',
      'created_at': now,
      'updated_at': now,
    });
    final id = await DatabaseHelper.insertMessage(
      Message(
        conversationId: 'window',
        characterId: 'char',
        text: 'hello',
        isUser: true,
      ),
    );
    source = (await DatabaseHelper.getMessageById(id))!;
    directory = await Directory.systemTemp.createTemp('holt-reply-test-');
    journal = File('${directory.path}/reply.json');
  });
  tearDown(() async {
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });
  Future<IosReplyBackgroundTask> begin() async =>
      (await IosReplyBackgroundTask.begin(
        source: source,
        onExpire: () {},
        checkpointFile: journal,
      ))!;

  test(
    'interrupted text recovers once without sending another API request',
    () async {
      final task = await begin();
      await task.record('Received partial text');
      await task.finish(discard: false);
      await IosReplyBackgroundTask.recover('window', checkpointFile: journal);
      await IosReplyBackgroundTask.recover('window', checkpointFile: journal);
      final messages = await DatabaseHelper.getMessages('window');
      expect(messages, hasLength(2));
      expect(messages.last.isIncomplete, isTrue);
      expect(messages.last.text, 'Received partial text');
      expect(calls.map((call) => call.method), ['begin', 'progress', 'end']);
    },
  );

  test('edited source invalidates the interrupted reply', () async {
    final task = await begin();
    await task.record('old partial');
    await task.finish(discard: false);
    await DatabaseHelper.updateMessageText(source.id!, 'edited');
    await IosReplyBackgroundTask.recover('window', checkpointFile: journal);
    expect(await DatabaseHelper.getMessages('window'), hasLength(1));
  });

  test('already persisted reply wins over obsolete checkpoint', () async {
    final task = await begin();
    await task.record('partial');
    await task.finish(discard: false);
    await DatabaseHelper.insertMessage(
      Message(
        conversationId: 'window',
        characterId: 'char',
        text: 'complete',
        isUser: false,
      ),
    );
    await IosReplyBackgroundTask.recover('window', checkpointFile: journal);
    expect(await DatabaseHelper.getMessages('window'), hasLength(2));
  });

  test(
    'completed reply removes journal and ends native lease only once',
    () async {
      final task = await begin();
      await task.record('partial');
    await task.finish(discard: true, completed: true);
    await task.finish(discard: true, completed: true);
      expect(await journal.exists(), isFalse);
    expect(calls.where((call) => call.method == 'end'), hasLength(1));
    expect((calls.last.arguments as Map)['success'], isTrue);
    },
  );

  test('active request is not restored by a second screen load', () async {
    final task = await begin();
    await task.record('partial');
    await IosReplyBackgroundTask.recover('window', checkpointFile: journal);
    expect(await DatabaseHelper.getMessages('window'), hasLength(1));
    await task.finish(discard: true);
  });

  test('latest buffered chunk is flushed before expiration', () async {
    var expired = false;
    final task = (await IosReplyBackgroundTask.begin(
      source: source,
      onExpire: () => expired = true,
      checkpointFile: journal,
    ))!;
    await task.record('first');
    await task.record('first plus latest');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'holt/reply_background',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('expired', task.token),
          ),
          (_) {},
        );
    await task.finish(discard: false);
    final saved = jsonDecode(await journal.readAsString()) as Map;
    expect(expired, isTrue);
    expect(saved['text'], 'first plus latest');
  });
}
