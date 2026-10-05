import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/database.dart';
import 'package:project_yanci/models/context_mode.dart';
import 'package:project_yanci/services/external_chat_import_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    DatabaseHelper.useDatabaseForTesting(db);
    await DatabaseHelper.createSchemaForTesting(db);
    const now = '2026-10-04T00:00:00.000Z';
    await db.insert('characters', <String, Object?>{
      'id': 'char-a',
      'name': '測試角色',
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    DatabaseHelper.useDatabaseInitializerForTesting(null);
    DatabaseHelper.useDatabaseForTesting(null);
    await db.close();
  });

  test('parses the active ChatGPT branch in chronological order', () {
    final preview = ExternalChatImportService.parseText(
      jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'chat-1',
          'title': '雨夜',
          'current_node': 'a2',
          'mapping': <String, Object?>{
            'root': <String, Object?>{'parent': null, 'message': null},
            'u1': <String, Object?>{
              'parent': 'root',
              'message': <String, Object?>{
                'author': <String, Object?>{'role': 'user'},
                'content': <String, Object?>{
                  'parts': <String>['你來了。'],
                },
                'create_time': 100,
              },
            },
            'a2': <String, Object?>{
              'parent': 'u1',
              'message': <String, Object?>{
                'author': <String, Object?>{'role': 'assistant'},
                'content': <String, Object?>{
                  'parts': <String>['我來了。'],
                },
                'create_time': 101,
              },
            },
            'discarded': <String, Object?>{
              'parent': 'u1',
              'message': <String, Object?>{
                'author': <String, Object?>{'role': 'assistant'},
                'content': <String, Object?>{
                  'parts': <String>['舊的重 roll。'],
                },
                'create_time': 102,
              },
            },
          },
        },
      ]),
      fileName: 'conversations.json',
    );

    expect(preview.source, ExternalChatSource.chatGpt);
    expect(preview.conversations, hasLength(1));
    expect(
      preview.conversations.single.messages.map((message) => message.text),
      <String>['你來了。', '我來了。'],
    );
  });

  test('parses Claude chat_messages and mixed content blocks', () {
    final preview = ExternalChatImportService.parseText(
      jsonEncode(<Object?>[
        <String, Object?>{
          'uuid': 'claude-1',
          'name': '書院',
          'chat_messages': <Object?>[
            <String, Object?>{'sender': 'human', 'text': '開門。'},
            <String, Object?>{
              'sender': 'assistant',
              'content': <Object?>[
                <String, Object?>{'text': '門開了。'},
              ],
            },
          ],
        },
      ]),
      fileName: 'claude.json',
    );

    expect(preview.source, ExternalChatSource.claude);
    expect(preview.messageCount, 2);
    expect(preview.conversations.single.messages.last.isUser, isFalse);
  });

  test('labels Gemini and Grok generic message exports by provider', () {
    ExternalImportPreview parse(String provider) =>
        ExternalChatImportService.parseText(
          jsonEncode(<String, Object?>{
            'provider': provider,
            'conversations': <Object?>[
              <String, Object?>{
                'id': '$provider-1',
                'messages': <Object?>[
                  <String, Object?>{'role': 'user', 'text': '第一句'},
                  <String, Object?>{
                    'role': provider == 'xAI Grok' ? 'grok' : 'model',
                    'text': '第二句',
                  },
                ],
              },
            ],
          }),
          fileName: 'export.json',
        );

    expect(parse('Google Gemini').source, ExternalChatSource.gemini);
    expect(parse('Google Gemini').messageCount, 2);
    expect(parse('xAI Grok').source, ExternalChatSource.grok);
    expect(parse('xAI Grok').messageCount, 2);
  });

  test('markdown without speaker headings remains reference-only', () {
    final preview = ExternalChatImportService.parseText(
      '# Memory\nThis is a project note, not a transcript.',
      fileName: 'memory.md',
    );

    expect(preview.source, ExternalChatSource.markdown);
    expect(preview.canImport, isFalse);
    expect(preview.referenceDocument, isNotEmpty);
  });

  test('markdown with speaker headings becomes one conversation', () {
    final preview = ExternalChatImportService.parseText(
      '## User\n第一句\n\n## Assistant\n第二句',
      fileName: 'chat.md',
    );

    expect(preview.canImport, isTrue);
    expect(preview.messageCount, 2);
    expect(preview.conversations.single.messages.first.isUser, isTrue);
  });

  test('file parsing runs off the UI isolate and returns a preview', () async {
    final directory = await Directory.systemTemp.createTemp('holt-import-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/chat.md');
    await file.writeAsString('## User\n在嗎\n\n## Assistant\n在。');

    final preview = await ExternalChatImportService.parseFile(file.path);

    expect(preview.source, ExternalChatSource.markdown);
    expect(preview.messageCount, 2);
  });

  test(
    'additive import is idempotent and does not create RP projections',
    () async {
      final preview = ExternalChatImportService.parseText(
        jsonEncode(<String, Object?>{
          'conversations': <Object?>[
            <String, Object?>{
              'id': 'generic-1',
              'title': 'Imported story',
              'messages': <Object?>[
                <String, Object?>{'role': 'user', 'content': '你好'},
                <String, Object?>{'role': 'assistant', 'content': '你好。'},
              ],
            },
          ],
        }),
        fileName: 'export.json',
      );

      final first = await ExternalChatImportService.importPreview(
        preview: preview,
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      );
      final second = await ExternalChatImportService.importPreview(
        preview: preview,
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      );

      expect(first.importedConversations, 1);
      expect(first.importedMessages, 2);
      expect(second.importedConversations, 0);
      expect(second.skippedDuplicates, 1);
      expect(await db.query('conversations'), hasLength(1));
      expect(await db.query('messages'), hasLength(2));
      expect(await db.query('context_summaries'), isEmpty);
      expect(await db.query('memories'), isEmpty);
      expect(await db.query('rp_story_states'), isEmpty);
    },
  );

  test(
    're-import appends only a clean extension of the same source window',
    () async {
      ExternalImportPreview preview(String last) =>
          ExternalChatImportService.parseText(
            jsonEncode(<String, Object?>{
              'conversations': <Object?>[
                <String, Object?>{
                  'id': 'growing-1',
                  'title': 'Growing story',
                  'messages': <Object?>[
                    <String, Object?>{'role': 'user', 'content': '第一句'},
                    <String, Object?>{'role': 'assistant', 'content': '第二句'},
                    if (last.isNotEmpty)
                      <String, Object?>{'role': 'user', 'content': last},
                  ],
                },
              ],
            }),
            fileName: 'export.json',
          );

      await ExternalChatImportService.importPreview(
        preview: preview(''),
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      );
      final result = await ExternalChatImportService.importPreview(
        preview: preview('第三句'),
        characterId: 'char-a',
        contextMode: ContextMode.daily,
      );

      expect(result.importedConversations, 0);
      expect(result.updatedConversations, 1);
      expect(result.importedMessages, 1);
      expect(await db.query('conversations'), hasLength(1));
      expect(await db.query('messages'), hasLength(3));
    },
  );
}
